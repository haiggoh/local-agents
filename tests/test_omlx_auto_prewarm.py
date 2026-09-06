#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import http.client
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER_PATH = REPO / "bin" / "omlx-auto-prewarm.py"

spec = importlib.util.spec_from_file_location("omlx_auto_prewarm", HELPER_PATH)
assert spec and spec.loader
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

PASS = 0
FAIL = 0


def check(condition: bool, label: str) -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  PASS: {label}")
    else:
        FAIL += 1
        print(f"  FAIL: {label}")


class BackendHandler(BaseHTTPRequestHandler):
    requests: list[dict] = []

    def log_message(self, _format, *_args):
        return

    def do_GET(self):
        payload = json.dumps({"status": "ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        type(self).requests.append(
            {
                "path": self.path,
                "body": body,
            }
        )
        payload = json.dumps(
            {
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "content": [{"type": "text", "text": "<severity>0</severity>"}],
                "model": "claude-sonnet-5",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 12, "output_tokens": 2},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def start_backend():
    server = ThreadingHTTPServer(("127.0.0.1", 0), BackendHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, f"http://{host}:{port}"


def wait_for(path: Path, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}")


with tempfile.TemporaryDirectory(prefix="omlx-prewarm-test.") as raw_tmp:
    tmp = Path(raw_tmp).resolve()

    print("== fingerprint stability and invalidation ==")

    claude = tmp / "claude"
    claude.write_bytes(b"claude-binary-v1")
    claude.chmod(0o755)

    classifier = tmp / "classifier"
    classifier.mkdir()
    (classifier / "config.json").write_text('{"model_type":"qwen2"}\n')
    (classifier / "tokenizer_config.json").write_text('{"x":1}\n')

    cwd = tmp / "project"
    cwd.mkdir()

    args = type(
        "Args",
        (),
        {
            "claude_bin": str(claude),
            "claude_version": "2.1.261",
            "omlx_version": "0.6.4",
            "classifier_dir": str(classifier),
            "classifier_model_id": "claude-sonnet-5",
            "cwd": str(cwd),
            "segmented_transcript": "1",
            "profile_file": [],
            "profile_value": ["tools=Bash,Read", "effort=high"],
        },
    )()

    first = helper.build_fingerprint(args)
    second = helper.build_fingerprint(args)

    check(first["fingerprint"] == second["fingerprint"],
          "same material produces stable fingerprint")

    claude.write_bytes(b"claude-binary-v2")
    third = helper.build_fingerprint(args)

    check(first["fingerprint"] != third["fingerprint"],
          "Claude binary change invalidates fingerprint")

    print("== refresh decision policy ==")

    fixture_dir = tmp / "fixtures" / first["fingerprint"]
    helper.ensure_private_directory(fixture_dir)

    result = helper.fixture_decision(
        fixture_dir,
        first["fingerprint"],
        max_age_days=7,
        refresh_every=0,
    )

    check(result["action"] == "refresh",
          "missing fixture requires refresh")

    request_body = json.dumps(
        {
            "model": "claude-sonnet-5",
            "stream": False,
            "tools": [],
            "messages": [
                {
                    "role": "user",
                    "content": "<transcript>classifier fixture</transcript>",
                }
            ],
            "max_tokens": 64,
        }
    ).encode()

    helper.atomic_private_json(
        fixture_dir / "classifier-request.json",
        {
            "schema_version": helper.SCHEMA_VERSION,
            "captured_at": time.time(),
            "method": "POST",
            "path": "/v1/messages",
            "headers": {
                "Content-Type": "application/json",
                "Anthropic-Version": "2023-06-01",
            },
            "body_base64": base64.b64encode(request_body).decode(),
            "body_sha256": hashlib.sha256(request_body).hexdigest(),
            "body_bytes": len(request_body),
            "classifier_model_id": "claude-sonnet-5",
        },
    )

    helper.atomic_private_json(
        fixture_dir / "ready.json",
        {
            "schema_version": helper.SCHEMA_VERSION,
            "fingerprint": first["fingerprint"],
            "success": True,
            "created_at": time.time(),
            "launch_count": 1,
        },
    )

    result = helper.fixture_decision(
        fixture_dir,
        first["fingerprint"],
        max_age_days=7,
        refresh_every=0,
    )

    check(result["action"] == "verify",
          "fresh matching fixture uses fast verification")

    stale = helper.read_json(fixture_dir / "ready.json")
    stale["created_at"] = time.time() - 8 * 86400
    helper.atomic_private_json(fixture_dir / "ready.json", stale)

    result = helper.fixture_decision(
        fixture_dir,
        first["fingerprint"],
        max_age_days=7,
        refresh_every=0,
    )

    check(
        result["action"] == "refresh"
        and "fixture_expired" in result["reasons"],
        "weekly expiry requires refresh",
    )

    stale["created_at"] = time.time()
    helper.atomic_private_json(fixture_dir / "ready.json", stale)
    helper.atomic_private_json(
        fixture_dir / "unhealthy.json",
        {
            "schema_version": helper.SCHEMA_VERSION,
            "failure_kind": "classifier_timeout",
        },
    )

    result = helper.fixture_decision(
        fixture_dir,
        first["fingerprint"],
        max_age_days=7,
        refresh_every=0,
    )

    check(
        result["action"] == "refresh"
        and "marked_unhealthy" in result["reasons"],
        "failure marker requires reactive refresh",
    )

    (fixture_dir / "unhealthy.json").unlink()

    print("== fixture permissions ==")

    check(
        stat.S_IMODE(fixture_dir.stat().st_mode) == 0o700,
        "fixture directory is mode 0700",
    )
    check(
        stat.S_IMODE((fixture_dir / "classifier-request.json").stat().st_mode)
        == 0o600,
        "captured request is mode 0600",
    )
    check(
        stat.S_IMODE((fixture_dir / "ready.json").stat().st_mode) == 0o600,
        "fixture metadata is mode 0600",
    )

    print("== capture proxy classification and forwarding ==")

    BackendHandler.requests.clear()
    backend_server, backend_url = start_backend()

    proxy_dir = tmp / "proxy"
    fixture_path = proxy_dir / "classifier-request.json"
    capture_ready = proxy_dir / "capture-ready.json"
    listen_file = proxy_dir / "listen.json"

    proxy = subprocess.Popen(
        [
            sys.executable,
            str(HELPER_PATH),
            "capture-proxy",
            "--backend-url",
            backend_url,
            "--listen-port",
            "0",
            "--listen-file",
            str(listen_file),
            "--fixture",
            str(fixture_path),
            "--ready-file",
            str(capture_ready),
            "--timeout",
            "20",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    wait_for(listen_file)
    listen = json.loads(listen_file.read_text())
    proxy_url = listen["url"]

    ordinary_body = json.dumps(
        {
            "model": "claude-opus-5",
            "stream": True,
            "messages": [{"role": "user", "content": "ordinary request"}],
        }
    ).encode()

    ordinary_request = urllib.request.Request(
        proxy_url + "/v1/messages",
        data=ordinary_body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Anthropic-Version": "2023-06-01",
        },
    )

    with urllib.request.urlopen(ordinary_request, timeout=5) as response:
        ordinary_status = response.status
        response.read()

    check(ordinary_status == 200,
          "ordinary Opus request is forwarded")
    check(len(BackendHandler.requests) == 1,
          "backend received ordinary request")

    classifier_request = urllib.request.Request(
        proxy_url + "/v1/messages",
        data=request_body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Anthropic-Version": "2023-06-01",
            "X-Api-Key": "must-not-persist",
        },
    )

    classifier_status = None
    try:
        urllib.request.urlopen(classifier_request, timeout=5)
    except urllib.error.HTTPError as exc:
        classifier_status = exc.code
        exc.read()

    wait_for(fixture_path)
    wait_for(capture_ready)

    check(classifier_status == 503,
          "first genuine classifier request is detached from backend")
    check(len(BackendHandler.requests) == 1,
          "captured classifier request was not forwarded")
    check(
        helper.is_classifier_request(request_body, "claude-sonnet-5"),
        "classifier request shape is recognized",
    )
    check(
        not helper.is_classifier_request(ordinary_body, "claude-sonnet-5"),
        "ordinary Opus request is never captured as classifier work",
    )

    sonnet_lookalike = json.dumps(
        {
            "model": "claude-sonnet-5",
            "stream": False,
            "tools": [],
            "messages": [{"role": "user", "content": "generate a title"}],
            "max_tokens": 64,
        }
    ).encode()

    check(
        not helper.is_classifier_request(
            sonnet_lookalike,
            "claude-sonnet-5",
        ),
        "unrelated Sonnet side query is not captured",
    )

    captured = json.loads(fixture_path.read_text())
    captured_body = base64.b64decode(captured["body_base64"])

    check(captured_body == request_body,
          "captured body preserves exact request bytes")
    check(
        "x-api-key"
        not in {key.lower() for key in captured["headers"]},
        "captured fixture never persists API credentials",
    )
    check(
        stat.S_IMODE(fixture_path.stat().st_mode) == 0o600,
        "proxy fixture remains mode 0600",
    )

    proxy.send_signal(signal.SIGTERM)
    proxy_stdout, proxy_stderr = proxy.communicate(timeout=10)

    check(proxy.returncode == 0,
          "capture proxy exits cleanly after capture")

    print("== detached replay ==")

    replay_result = helper.replay_fixture(
        fixture_path=fixture_path,
        backend_url=backend_url,
        timeout=5,
        server_log=None,
    )

    check(replay_result["status"] == "ok",
          "captured classifier fixture replays successfully")
    check(replay_result["http_status"] == 200,
          "detached replay receives HTTP 200")
    check(len(BackendHandler.requests) == 2,
          "backend receives replay only after capture")
    check(
        BackendHandler.requests[-1]["body"] == request_body,
        "detached replay preserves captured body",
    )

    backend_server.shutdown()
    backend_server.server_close()

print(f"\n{PASS} passed, {FAIL} failed")
raise SystemExit(0 if FAIL == 0 else 1)
