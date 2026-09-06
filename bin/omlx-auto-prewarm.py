#!/usr/bin/env python3
"""Private Auto Mode classifier fixture capture and replay support.

This helper deliberately separates four concerns:

1. fingerprint:
   Bind a fixture to the exact Claude binary, oMLX version, classifier assets,
   launch profile, working directory, and helper schema.

2. decision:
   Decide whether an existing fixture may use the fast verification path or
   requires a genuine refresh.

3. capture-proxy:
   Forward ordinary requests to oMLX while capturing the first genuine
   claude-sonnet-5 request. The captured request is stored privately and is
   not forwarded on this first pass, so Claude Code cannot cancel the detached
   replay when its own classifier deadline expires.

4. replay:
   Replay a captured request independently of Claude Code and report elapsed
   time plus cache evidence from an oMLX debug log.

Request bodies are sensitive: they may contain system prompts, project
instructions, transcript material, paths, and tool arguments. Fixture
directories are mode 0700 and fixture files mode 0600. Bodies are never
printed by this helper.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import signal
import socket
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
HELPER_VERSION = "omlx-auto-prewarm-v1"
CLASSIFIER_MODEL_DEFAULT = "claude-sonnet-5"

SAFE_FORWARD_HEADERS = {
    "accept",
    "anthropic-beta",
    "anthropic-version",
    "content-type",
    "user-agent",
}

CACHE_HIT_PATTERNS = (
    re.compile(r"paged cache hit,\s*(\d+)\s*tokens", re.IGNORECASE),
    re.compile(r"served cached_tokens=(\d+)", re.IGNORECASE),
    re.compile(r"cached[=_ :]+(\d+)", re.IGNORECASE),
)

PROMPT_PATTERNS = (
    re.compile(r"prompt[=_ :]+(\d+)", re.IGNORECASE),
    re.compile(r"prompt_tokens[=_ :]+(\d+)", re.IGNORECASE),
)


def canonical(path: str | Path) -> Path:
    return Path(path).expanduser().resolve()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o700:
        raise RuntimeError(f"private directory mode is {mode:o}, expected 700: {path}")


def atomic_private_json(path: Path, payload: Any) -> None:
    ensure_private_directory(path.parent)
    encoded = (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )

    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())

        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise

    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise RuntimeError(f"private file mode is {mode:o}, expected 600: {path}")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def relevant_model_files(model_dir: Path) -> list[Path]:
    names = {
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "chat_template.jinja",
        "preprocessor_config.json",
        "processor_config.json",
    }

    return sorted(
        path
        for path in model_dir.iterdir()
        if path.is_file() and path.name in names
    )


def build_fingerprint(args: argparse.Namespace) -> dict[str, Any]:
    claude = canonical(args.claude_bin)
    classifier = canonical(args.classifier_dir)
    cwd = canonical(args.cwd)

    if not claude.is_file():
        raise RuntimeError(f"Claude executable missing: {claude}")
    if not classifier.is_dir():
        raise RuntimeError(f"classifier directory missing: {classifier}")
    if not (classifier / "config.json").is_file():
        raise RuntimeError(f"classifier config missing: {classifier / 'config.json'}")
    if not cwd.is_dir():
        raise RuntimeError(f"working directory missing: {cwd}")

    profile_files = []
    for raw in args.profile_file:
        path = canonical(raw)
        if not path.is_file():
            raise RuntimeError(f"profile file missing: {path}")
        profile_files.append(
            {
                "path": str(path),
                "sha256": sha256_file(path),
            }
        )

    classifier_files = [
        {
            "name": path.name,
            "sha256": sha256_file(path),
        }
        for path in relevant_model_files(classifier)
    ]

    material = {
        "schema_version": SCHEMA_VERSION,
        "helper_version": HELPER_VERSION,
        "claude_path": str(claude),
        "claude_sha256": sha256_file(claude),
        "claude_version": args.claude_version,
        "omlx_version": args.omlx_version,
        "classifier_model_id": args.classifier_model_id,
        "classifier_dir": str(classifier),
        "classifier_files": classifier_files,
        "segmented_transcript": args.segmented_transcript,
        "cwd": str(cwd),
        "profile_files": profile_files,
        "profile_values": sorted(args.profile_value),
    }

    encoded = json.dumps(
        material,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    return {
        "fingerprint": sha256_bytes(encoded),
        "material": material,
    }


def command_fingerprint(args: argparse.Namespace) -> int:
    result = build_fingerprint(args)

    if args.output:
        atomic_private_json(canonical(args.output), result)

    print(result["fingerprint"])
    return 0


def fixture_decision(
    fixture_dir: Path,
    fingerprint: str,
    max_age_days: int,
    refresh_every: int,
) -> dict[str, Any]:
    fixture_path = fixture_dir / "classifier-request.json"
    ready_path = fixture_dir / "ready.json"
    failure_path = fixture_dir / "unhealthy.json"

    reasons: list[str] = []

    if not fixture_path.is_file():
        reasons.append("fixture_missing")
    if not ready_path.is_file():
        reasons.append("ready_metadata_missing")
    if failure_path.exists():
        reasons.append("marked_unhealthy")

    ready: dict[str, Any] = {}
    if ready_path.is_file():
        try:
            ready = read_json(ready_path)
        except Exception:
            reasons.append("ready_metadata_invalid")

    if ready:
        if ready.get("schema_version") != SCHEMA_VERSION:
            reasons.append("schema_changed")
        if ready.get("fingerprint") != fingerprint:
            reasons.append("fingerprint_changed")
        if ready.get("success") is not True:
            reasons.append("last_refresh_not_successful")

        created_at = ready.get("created_at")
        if isinstance(created_at, (int, float)):
            max_age_seconds = max_age_days * 86400
            if max_age_days >= 0 and time.time() - created_at > max_age_seconds:
                reasons.append("fixture_expired")
        else:
            reasons.append("created_at_missing")

        launch_count = ready.get("launch_count", 0)
        if (
            refresh_every > 0
            and isinstance(launch_count, int)
            and launch_count > 0
            and launch_count % refresh_every == 0
        ):
            reasons.append("periodic_launch_refresh")

    action = "refresh" if reasons else "verify"

    return {
        "schema_version": SCHEMA_VERSION,
        "action": action,
        "reasons": reasons,
        "fixture": str(fixture_path),
        "ready": str(ready_path),
    }


def command_decision(args: argparse.Namespace) -> int:
    fixture_dir = canonical(args.fixture_dir)
    result = fixture_decision(
        fixture_dir,
        args.fingerprint,
        args.max_age_days,
        args.refresh_every,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


def capture_headers(handler: BaseHTTPRequestHandler) -> dict[str, str]:
    headers = {}
    for key, value in handler.headers.items():
        if key.lower() in SAFE_FORWARD_HEADERS:
            headers[key] = value
    return headers


def is_classifier_request(body: bytes, model_id: str) -> bool:
    try:
        payload = json.loads(body)
    except Exception:
        return False

    if payload.get("model") != model_id:
        return False

    # Auto Mode classifier calls observed in Claude Code use non-streaming
    # Anthropic Messages requests and carry no ordinary tools.
    if payload.get("stream") not in (False, None):
        return False

    tools = payload.get("tools")
    if tools not in (None, []):
        return False

    # Capture only the observed Stage-1 Auto Mode contract. Other Sonnet side
    # queries may also be non-streaming and tool-free, so model name alone is
    # not a sufficient safety boundary.
    if payload.get("max_tokens") != 64:
        return False

    try:
        serialized = body.decode("utf-8")
    except UnicodeDecodeError:
        return False

    if "<transcript>" not in serialized:
        return False
    if "</transcript>" not in serialized:
        return False

    return True


class CaptureState:
    def __init__(
        self,
        *,
        backend: urllib.parse.ParseResult,
        fixture_path: Path,
        ready_path: Path,
        classifier_model_id: str,
        max_body_bytes: int,
    ) -> None:
        self.backend = backend
        self.fixture_path = fixture_path
        self.ready_path = ready_path
        self.classifier_model_id = classifier_model_id
        self.max_body_bytes = max_body_bytes
        self.captured = threading.Event()
        self.error: str | None = None
        self.lock = threading.Lock()


def write_capture_fixture(
    state: CaptureState,
    *,
    path: str,
    headers: dict[str, str],
    body: bytes,
) -> None:
    with state.lock:
        if state.captured.is_set():
            return

        fixture = {
            "schema_version": SCHEMA_VERSION,
            "captured_at": time.time(),
            "method": "POST",
            "path": path,
            "headers": headers,
            "body_base64": base64.b64encode(body).decode("ascii"),
            "body_sha256": sha256_bytes(body),
            "body_bytes": len(body),
            "classifier_model_id": state.classifier_model_id,
        }

        atomic_private_json(state.fixture_path, fixture)
        atomic_private_json(
            state.ready_path,
            {
                "schema_version": SCHEMA_VERSION,
                "captured": True,
                "fixture": str(state.fixture_path),
                "body_sha256": fixture["body_sha256"],
                "body_bytes": fixture["body_bytes"],
                "captured_at": fixture["captured_at"],
            },
        )
        state.captured.set()


def forward_request(
    state: CaptureState,
    handler: BaseHTTPRequestHandler,
    body: bytes,
) -> tuple[int, list[tuple[str, str]], bytes]:
    backend = state.backend
    connection_class = (
        http.client.HTTPSConnection
        if backend.scheme == "https"
        else http.client.HTTPConnection
    )

    port = backend.port
    connection = connection_class(
        backend.hostname,
        port=port,
        timeout=600,
    )

    base_path = backend.path.rstrip("/")
    target_path = base_path + handler.path

    headers = capture_headers(handler)
    headers["Host"] = backend.netloc
    headers["Content-Length"] = str(len(body))

    try:
        connection.request(
            handler.command,
            target_path,
            body=body if body else None,
            headers=headers,
        )
        response = connection.getresponse()
        response_body = response.read()
        response_headers = [
            (key, value)
            for key, value in response.getheaders()
            if key.lower()
            not in {"connection", "content-length", "transfer-encoding"}
        ]
        return response.status, response_headers, response_body
    finally:
        connection.close()


def make_handler(state: CaptureState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "local-agents-prewarm-capture/1"

        def log_message(self, _format: str, *_args: Any) -> None:
            return

        def do_GET(self) -> None:
            self._handle()

        def do_POST(self) -> None:
            self._handle()

        def _handle(self) -> None:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.send_error(400, "invalid content length")
                return

            if length > state.max_body_bytes:
                self.send_error(413, "request body exceeds capture limit")
                return

            body = self.rfile.read(length) if length else b""

            if (
                self.command == "POST"
                and self.path.endswith("/v1/messages")
                and is_classifier_request(body, state.classifier_model_id)
                and not state.captured.is_set()
            ):
                try:
                    write_capture_fixture(
                        state,
                        path=self.path,
                        headers=capture_headers(self),
                        body=body,
                    )
                except Exception as exc:
                    state.error = f"{type(exc).__name__}: {exc}"
                    self.send_error(500, "classifier fixture capture failed")
                    return

                # The first genuine classifier call is deliberately not tied to
                # the oMLX prefill. The launcher will terminate the sacrificial
                # Claude process and replay this fixture independently.
                payload = json.dumps(
                    {
                        "type": "error",
                        "error": {
                            "type": "overloaded_error",
                            "message": "classifier fixture captured for detached replay",
                        },
                    }
                ).encode("utf-8")

                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            try:
                status, headers, response_body = forward_request(
                    state,
                    self,
                    body,
                )
            except Exception as exc:
                payload = json.dumps(
                    {
                        "type": "error",
                        "error": {
                            "type": "api_error",
                            "message": f"capture proxy forwarding failed: {type(exc).__name__}",
                        },
                    }
                ).encode("utf-8")
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            self.send_response(status)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

    return Handler


def command_capture_proxy(args: argparse.Namespace) -> int:
    backend = urllib.parse.urlparse(args.backend_url)
    if backend.scheme not in {"http", "https"} or not backend.hostname:
        raise RuntimeError("backend URL must be http:// or https://")

    fixture_path = canonical(args.fixture)
    ready_path = canonical(args.ready_file)

    ensure_private_directory(fixture_path.parent)
    ensure_private_directory(ready_path.parent)

    state = CaptureState(
        backend=backend,
        fixture_path=fixture_path,
        ready_path=ready_path,
        classifier_model_id=args.classifier_model_id,
        max_body_bytes=args.max_body_bytes,
    )

    server = ThreadingHTTPServer(
        (args.listen_host, args.listen_port),
        make_handler(state),
    )
    server.daemon_threads = True

    actual_host, actual_port = server.server_address[:2]

    atomic_private_json(
        canonical(args.listen_file),
        {
            "schema_version": SCHEMA_VERSION,
            "host": actual_host,
            "port": actual_port,
            "url": f"http://{actual_host}:{actual_port}",
            "pid": os.getpid(),
        },
    )

    stop_requested = threading.Event()

    def stop_handler(_signum: int, _frame: Any) -> None:
        stop_requested.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    timeout_thread: threading.Thread | None = None
    if args.timeout > 0:
        def timeout_worker() -> None:
            if not state.captured.wait(args.timeout):
                state.error = "capture_timeout"
                server.shutdown()

        timeout_thread = threading.Thread(target=timeout_worker, daemon=True)
        timeout_thread.start()

    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()

    if state.error:
        print(
            json.dumps(
                {
                    "status": "error",
                    "error": state.error,
                }
            )
        )
        return 1

    if not state.captured.is_set():
        print(
            json.dumps(
                {
                    "status": "error",
                    "error": "capture_ended_without_fixture",
                }
            )
        )
        return 1

    print(
        json.dumps(
            {
                "status": "captured",
                "fixture": str(fixture_path),
            }
        )
    )
    return 0


def load_fixture(path: Path) -> tuple[str, dict[str, str], bytes]:
    fixture = read_json(path)

    if fixture.get("schema_version") != SCHEMA_VERSION:
        raise RuntimeError("fixture schema mismatch")
    if fixture.get("method") != "POST":
        raise RuntimeError("fixture method must be POST")

    body = base64.b64decode(fixture["body_base64"], validate=True)
    if sha256_bytes(body) != fixture.get("body_sha256"):
        raise RuntimeError("fixture body hash mismatch")

    headers = {
        str(key): str(value)
        for key, value in (fixture.get("headers") or {}).items()
        if str(key).lower() in SAFE_FORWARD_HEADERS
    }
    headers["Content-Type"] = "application/json"

    return str(fixture["path"]), headers, body


def read_log_evidence(path: Path, offset: int) -> dict[str, int | None]:
    if not path.is_file():
        return {
            "cached_tokens": None,
            "prompt_tokens": None,
        }

    with path.open("rb") as handle:
        handle.seek(max(0, offset))
        text = handle.read().decode("utf-8", errors="replace")

    cached_values = [
        int(match.group(1))
        for pattern in CACHE_HIT_PATTERNS
        for match in pattern.finditer(text)
    ]
    prompt_values = [
        int(match.group(1))
        for pattern in PROMPT_PATTERNS
        for match in pattern.finditer(text)
    ]

    return {
        "cached_tokens": max(cached_values) if cached_values else None,
        "prompt_tokens": max(prompt_values) if prompt_values else None,
    }


def replay_fixture(
    *,
    fixture_path: Path,
    backend_url: str,
    timeout: float,
    server_log: Path | None,
) -> dict[str, Any]:
    request_path, headers, body = load_fixture(fixture_path)
    backend = urllib.parse.urlparse(backend_url)
    url = backend_url.rstrip("/") + request_path

    log_offset = 0
    if server_log and server_log.is_file():
        log_offset = server_log.stat().st_size

    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers=headers,
    )

    started = time.monotonic()
    response_status: int | None = None
    response_body = b""

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_status = response.status
            response_body = response.read()
    except urllib.error.HTTPError as exc:
        response_status = exc.code
        response_body = exc.read()
    elapsed = time.monotonic() - started

    evidence = (
        read_log_evidence(server_log, log_offset)
        if server_log
        else {"cached_tokens": None, "prompt_tokens": None}
    )

    valid_json = False
    response_type = None
    try:
        parsed = json.loads(response_body)
        valid_json = True
        response_type = parsed.get("type") if isinstance(parsed, dict) else None
    except Exception:
        pass

    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok" if response_status and 200 <= response_status < 300 else "error",
        "http_status": response_status,
        "elapsed_seconds": round(elapsed, 3),
        "fixture_body_bytes": len(body),
        "fixture_body_sha256": sha256_bytes(body),
        "response_json": valid_json,
        "response_type": response_type,
        **evidence,
    }


def command_replay(args: argparse.Namespace) -> int:
    result = replay_fixture(
        fixture_path=canonical(args.fixture),
        backend_url=args.backend_url,
        timeout=args.timeout,
        server_log=canonical(args.server_log) if args.server_log else None,
    )

    if args.output:
        atomic_private_json(canonical(args.output), result)

    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "ok" else 1


def command_mark_ready(args: argparse.Namespace) -> int:
    fixture_dir = canonical(args.fixture_dir)
    fixture = fixture_dir / "classifier-request.json"

    if not fixture.is_file():
        raise RuntimeError(f"fixture missing: {fixture}")

    _path, _headers, body = load_fixture(fixture)

    ready = {
        "schema_version": SCHEMA_VERSION,
        "fingerprint": args.fingerprint,
        "success": True,
        "created_at": time.time(),
        "last_full_refresh": time.time(),
        "last_fast_verification": time.time(),
        "launch_count": args.launch_count,
        "fixture_body_sha256": sha256_bytes(body),
        "fixture_body_bytes": len(body),
    }

    atomic_private_json(fixture_dir / "ready.json", ready)

    unhealthy = fixture_dir / "unhealthy.json"
    try:
        unhealthy.unlink()
    except FileNotFoundError:
        pass

    print(json.dumps({"status": "ready", "fingerprint": args.fingerprint}))
    return 0


def command_mark_unhealthy(args: argparse.Namespace) -> int:
    fixture_dir = canonical(args.fixture_dir)
    atomic_private_json(
        fixture_dir / "unhealthy.json",
        {
            "schema_version": SCHEMA_VERSION,
            "recorded_at": time.time(),
            "failure_kind": args.failure_kind,
        },
    )
    print(json.dumps({"status": "unhealthy", "failure_kind": args.failure_kind}))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subparsers = root.add_subparsers(dest="command", required=True)

    fingerprint = subparsers.add_parser("fingerprint")
    fingerprint.add_argument("--claude-bin", required=True)
    fingerprint.add_argument("--claude-version", required=True)
    fingerprint.add_argument("--omlx-version", required=True)
    fingerprint.add_argument("--classifier-dir", required=True)
    fingerprint.add_argument(
        "--classifier-model-id",
        default=CLASSIFIER_MODEL_DEFAULT,
    )
    fingerprint.add_argument("--cwd", required=True)
    fingerprint.add_argument("--segmented-transcript", default="1")
    fingerprint.add_argument("--profile-file", action="append", default=[])
    fingerprint.add_argument("--profile-value", action="append", default=[])
    fingerprint.add_argument("--output")
    fingerprint.set_defaults(function=command_fingerprint)

    decision = subparsers.add_parser("decision")
    decision.add_argument("--fixture-dir", required=True)
    decision.add_argument("--fingerprint", required=True)
    decision.add_argument("--max-age-days", type=int, default=7)
    decision.add_argument("--refresh-every", type=int, default=0)
    decision.set_defaults(function=command_decision)

    capture = subparsers.add_parser("capture-proxy")
    capture.add_argument("--backend-url", required=True)
    capture.add_argument("--listen-host", default="127.0.0.1")
    capture.add_argument("--listen-port", type=int, default=0)
    capture.add_argument("--listen-file", required=True)
    capture.add_argument("--fixture", required=True)
    capture.add_argument("--ready-file", required=True)
    capture.add_argument(
        "--classifier-model-id",
        default=CLASSIFIER_MODEL_DEFAULT,
    )
    capture.add_argument("--timeout", type=float, default=120)
    capture.add_argument("--max-body-bytes", type=int, default=32 * 1024 * 1024)
    capture.set_defaults(function=command_capture_proxy)

    replay = subparsers.add_parser("replay")
    replay.add_argument("--fixture", required=True)
    replay.add_argument("--backend-url", required=True)
    replay.add_argument("--timeout", type=float, default=300)
    replay.add_argument("--server-log")
    replay.add_argument("--output")
    replay.set_defaults(function=command_replay)

    ready = subparsers.add_parser("mark-ready")
    ready.add_argument("--fixture-dir", required=True)
    ready.add_argument("--fingerprint", required=True)
    ready.add_argument("--launch-count", type=int, default=0)
    ready.set_defaults(function=command_mark_ready)

    unhealthy = subparsers.add_parser("mark-unhealthy")
    unhealthy.add_argument("--fixture-dir", required=True)
    unhealthy.add_argument("--failure-kind", required=True)
    unhealthy.set_defaults(function=command_mark_unhealthy)

    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.function(args))
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(
            json.dumps(
                {
                    "status": "error",
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                }
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
