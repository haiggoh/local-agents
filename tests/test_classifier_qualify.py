#!/usr/bin/env python3
"""Deterministic tests for the model-agnostic classifier qualification framework.

No real backend and no real model: a local stub HTTP server plays the backend so
every gate can be driven to both its passing and its failing side. The gates that
matter most are the ones that distinguish outcomes which look alike from the
outside — EXACT_ONLY vs DIRECT_PASS above all, since that is the Qwen3.6 failure
that presents as a success.
"""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FRAMEWORK_PATH = REPO / "bin" / "classifier-qualify.py"

spec = importlib.util.spec_from_file_location("classifier_qualify", FRAMEWORK_PATH)
assert spec and spec.loader
cq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cq)

PASSES = 0
FAILURES: list[str] = []


def check(condition: bool, label: str) -> None:
    global PASSES

    if condition:
        PASSES += 1
        print(f"  PASS: {label}")
    else:
        FAILURES.append(label)
        print(f"  FAIL: {label}")


def verdict_response(severity: int = 5) -> bytes:
    left, right = chr(60), chr(62)
    text = f"{left}severity{right}{severity}{left}/severity{right}"
    return json.dumps(
        {
            "type": "message",
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": text}],
        }
    ).encode("utf-8")


class StubBackend:
    """Backend whose per-request behaviour is scripted by the test.

    `script` is a list of (http_status, body, log_line) consumed in order; the
    last entry repeats once exhausted so a test need only script what it cares
    about.
    """

    def __init__(self, script, log_path: Path):
        self.script = script
        self.log_path = log_path
        self.index = 0
        self.received: list[bytes] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                length = int(self.headers.get("content-length") or 0)
                body = self.rfile.read(length)
                outer.received.append(body)

                position = min(outer.index, len(outer.script) - 1)
                status, payload, log_line = outer.script[position]
                outer.index += 1

                if log_line:
                    with outer.log_path.open("a", encoding="utf-8") as handle:
                        handle.write(log_line + "\n")

                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):  # noqa: A003
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            daemon=True,
        )

    def __enter__(self):
        self.log_path.write_text("", encoding="utf-8")
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"


def write_fixture(path: Path, messages: list[dict]) -> None:
    """Write a fixture in the REAL capture schema.

    load_fixture enforces schema_version, method == POST, and a body_sha256 that
    matches the payload. Writing a loose approximation here would test nothing:
    the fixture would be rejected before any request was sent.
    """
    body = json.dumps(
        {"model": "claude-sonnet-5", "messages": messages}
    ).encode()
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "method": "POST",
                "path": "/v1/messages",
                "headers": {"content-type": "application/json"},
                "body_base64": base64.b64encode(body).decode("ascii"),
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "body_bytes": len(body),
            }
        ),
        encoding="utf-8",
    )


def log(cached: int, prompt: int) -> str:
    return f"served cached_tokens={cached} prompt_tokens={prompt}"


def run(
    tmp: Path,
    script,
    argv_extra: list[str] | None = None,
    fixture_messages=None,
    stage: int = 1,
):
    """Drive the framework against the stub backend for ONE stage.

    The stage is passed explicitly rather than inferred from argv: inferring it
    silently sent every case to Stage 1 and the assertions then read a None
    stage2, which is a test bug that looks like a framework bug.
    """
    log_path = tmp / "server.log"
    fixture = tmp / "fixture.json"
    write_fixture(
        fixture,
        fixture_messages
        if fixture_messages is not None
        else [{"role": "user", "content": "classify this action"}],
    )
    flag = "--stage1-fixture" if stage == 1 else "--stage2-fixture"

    with StubBackend(script, log_path) as backend:
        report_path = tmp / "report.json"
        code = cq.main(
            [
                "--candidate",
                "stub",
                "--backend-url",
                backend.url,
                "--server-log",
                str(log_path),
                "--json",
                str(report_path),
                flag,
                str(fixture),
                *(argv_extra or []),
            ]
        )
        report = json.loads(report_path.read_text())
        return code, report, backend


def main() -> int:
    import tempfile

    print("== outcome ordering ==")
    check(
        cq.worst_outcome(["DIRECT_PASS", "EXACT_ONLY"]) == "EXACT_ONLY",
        "worst_outcome reports the earliest boundary hit, not the best result",
    )
    check(
        cq.worst_outcome([]) == "HARNESS_FAILURE",
        "no outcomes at all is HARNESS_FAILURE, never a pass",
    )
    check(
        len(cq.OUTCOMES) == 7
        and set(cq.OUTCOMES) == set(cq.OUTCOME_MEANING),
        "all seven outcomes are documented",
    )

    print("== request adapters ==")
    two_user = json.dumps(
        {
            "messages": [
                {"role": "user", "content": "first"},
                {"role": "user", "content": "second"},
            ]
        }
    ).encode()
    merged, changed = cq.merge_adjacent_user_messages(two_user)
    parsed = json.loads(merged)
    check(changed, "adjacent user messages are detected as mergeable")
    check(
        len(parsed["messages"]) == 1,
        "adjacent user messages collapse to a single message",
    )
    check(
        "first" in parsed["messages"][0]["content"]
        and "second" in parsed["messages"][0]["content"],
        "merging preserves the text of BOTH messages (semantics-preserving)",
    )

    alternating = json.dumps(
        {
            "messages": [
                {"role": "user", "content": "a"},
                {"role": "assistant", "content": "b"},
                {"role": "user", "content": "c"},
            ]
        }
    ).encode()
    _, changed_alt = cq.merge_adjacent_user_messages(alternating)
    check(
        not changed_alt,
        "a properly alternating request is left completely untouched",
    )

    grown, ok = cq.grow_request_prefix(
        json.dumps({"messages": [{"role": "user", "content": "base"}]}).encode(),
        "MARKER",
    )
    grown_parsed = json.loads(grown)
    check(ok, "prefix growth succeeds on a simple string message")
    check(
        grown_parsed["messages"][0]["content"].startswith("base")
        and grown_parsed["messages"][0]["content"].endswith("MARKER"),
        "growth APPENDS at the tail, leaving the shared prefix intact",
    )

    _, no_grow = cq.grow_request_prefix(b"not json", "MARKER")
    check(not no_grow, "unparseable body cannot be grown and says so")

    print("== serialization drift (measurement validity) ==")
    # A REAL captured body is raw UTF-8 with HTTP-client separators. Build it by
    # hand: constructing it with json.dumps would hide exactly the drift under
    # test, which is how this defect initially escaped notice.
    real_body = (
        b'{"model": "claude-sonnet-5", "messages": '
        b'[{"role": "user", "content": "caf\xc3\xa9 na\xc3\xafve text"}]}'
    )
    drifted, grew = cq.grow_request_prefix(real_body, "TAIL_MARKER")
    check(grew, "a realistic raw-UTF-8 captured body can be grown")
    check(
        b"\xc3\xa9" in drifted and b"\\u00e9" not in drifted,
        "non-ASCII stays raw UTF-8 instead of being escaped — escaping moves "
        "the divergence point early and understates reuse",
    )

    shared = 0
    for left, right in zip(real_body, drifted):
        if left != right:
            break
        shared += 1

    check(
        shared >= len(real_body) - 20,
        "the grown body diverges at the TAIL, so run B measures a genuine "
        "shared prefix rather than a re-serialization artifact",
    )

    merged_real, merged_ok = cq.merge_adjacent_user_messages(
        b'{"messages": [{"role": "user", "content": "caf\xc3\xa9"}, '
        b'{"role": "user", "content": "na\xc3\xafve"}]}'
    )
    check(
        merged_ok and b"\\u00e9" not in merged_real,
        "the adapter preserves raw UTF-8 too, not just the growth mutation",
    )

    print("== mixed content merge ==")
    for label, first, second in (
        ("str+list", "FIRST", [{"type": "text", "text": "SECOND"}]),
        ("list+str", [{"type": "text", "text": "FIRST"}], "SECOND"),
    ):
        body = json.dumps(
            {
                "messages": [
                    {"role": "user", "content": first},
                    {"role": "user", "content": second},
                ]
            }
        ).encode()
        out, did = cq.merge_adjacent_user_messages(body)
        parsed_out = json.loads(out)
        blob = json.dumps(parsed_out)
        check(
            did
            and len(parsed_out["messages"]) == 1
            and "FIRST" in blob
            and "SECOND" in blob,
            f"mixed {label} content merges and keeps both parts — declining "
            "would leave the 400 in place and blame the MODEL for an adapter gap",
        )

    print("== reuse arithmetic ==")
    check(
        cq.reuse_percent(37808, 38244) == 98.86,
        "reuse percent matches the measured Devstral figure",
    )
    check(
        cq.reuse_percent(None, 100) is None
        and cq.reuse_percent(50, None) is None
        and cq.reuse_percent(50, 0) is None,
        "absent evidence yields None (unmeasured), never a fabricated figure",
    )
    check(
        cq.reuse_percent(0, 38244) == 0.0,
        "a log REPORTING zero reuse is a measured 0%, not 'unmeasured' — the "
        "non-trimmable-cache miss must stay distinguishable from no evidence",
    )

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)

        print("== Stage 1: the EXACT_ONLY trap (Qwen3.6 shape) ==")
        # Cold, then a perfect exact hit, then a changed prefix that misses.
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(0, 38244)),
            ],
            [],
        )
        check(
            report["stage1"]["outcome"] == "EXACT_ONLY",
            "exact hit + changed-prefix miss is EXACT_ONLY, NOT a pass",
        )
        check(code != 0, "EXACT_ONLY exits non-zero")
        check(
            "non-trimmable" in report["stage1"].get("detail", "")
            or "grows its prefix" in report["stage1"].get("detail", ""),
            "EXACT_ONLY explains why exact replay was not enough",
        )

        print("== Stage 1: genuine pass ==")
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            [],
        )
        check(
            report["stage1"]["outcome"] == "DIRECT_PASS",
            "changed prefix reusing 98.86% is DIRECT_PASS",
        )
        check(code == 0, "DIRECT_PASS exits zero")
        check(
            not report["stage1"]["adapter_used"],
            "an unadapted pass records no adapter",
        )

        print("== Stage 1: alternation rejection ==")
        two = [
            {"role": "user", "content": "first"},
            {"role": "user", "content": "second"},
        ]
        # 400 first, then healthy: the adapted retry must be what rescues it.
        code, report, _ = run(
            tmp,
            [
                (400, b'{"error":"alternation"}', None),
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            ["--merge-adjacent-user-messages"],
            fixture_messages=two,
        )
        check(
            report["stage1"]["adapter_used"],
            "an HTTP 400 alternation rejection triggers the adapted retry",
        )
        check(
            report["outcome"] == "MODEL_PASS_WITH_ADAPTER",
            "an adapted pass is MODEL_PASS_WITH_ADAPTER, never DIRECT_PASS",
        )
        # Assert the STAGE outcome too. The rolled-up verdict is protected by a
        # second net in build_report, so checking only that cannot tell which
        # layer held — and a regression in Stage 1 would hide behind the net.
        check(
            report["stage1"]["outcome"] == "MODEL_PASS_WITH_ADAPTER",
            "Stage 1 itself reports the adapted pass, not just the roll-up",
        )
        check(
            any(
                run_entry["label"] == "cold_A_rejected_unadapted"
                for run_entry in report["stage1"]["runs"]
            ),
            "the unadapted rejection stays visible in the run record",
        )

        print("== Stage 1: adapter must be opt-in ==")
        # The retry would SUCCEED here. Only the missing flag may stop it — if
        # the script refused the retry too, this would pass even with the flag
        # check deleted, and would prove nothing.
        code, report, _ = run(
            tmp,
            [
                (400, b'{"error":"alternation"}', None),
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            [],
            fixture_messages=two,
        )
        check(
            report["stage1"]["outcome"] == "RUNTIME_OR_CONTEXT_FAIL",
            "without the flag a 400 is RUNTIME_OR_CONTEXT_FAIL, not adapted away",
        )
        check(
            not report["stage1"]["adapter_used"],
            "the adapter never runs unless explicitly requested",
        )

        print("== Stage 1: contract violations ==")
        code, report, _ = run(
            tmp,
            [(200, b'{"type":"message","content":[{"type":"text","text":"maybe unsafe?"}]}', log(0, 100))],
            [],
        )
        check(
            report["stage1"]["outcome"] == "CONTRACT_FAIL",
            "prose instead of a severity verdict is CONTRACT_FAIL",
        )

        print("== Stage 2: warm deadline and contract ==")
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 28073)),
                (200, verdict_response(), log(28073, 28073)),
            ],
            ["--warm-runs", "4"],
            stage=2,
        )
        check(
            report["stage2"]["outcome"] == "DIRECT_PASS",
            "cold + 4 warm exact replays with full reuse passes Stage 2",
        )
        check(
            report["stage2"]["contract_passes"] == 5
            and report["stage2"]["contract_required"] == 5,
            "Stage 2 requires 5/5 contract passes",
        )
        check(
            report["stage2"]["warm_deadline_seconds"] == 45.0,
            "the 45-second classifier deadline is enforced as a gate",
        )

        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 28073)),
                (200, verdict_response(), log(0, 28073)),
            ],
            ["--warm-runs", "2"],
            stage=2,
        )
        check(
            report["stage2"]["outcome"] == "CACHE_OR_LATENCY_FAIL",
            "warm runs that do not reuse the cache fail Stage 2",
        )

        print("== unmeasured is UNJUDGED, not failed ==")
        # The single most dangerous confusion: no cache evidence must never be
        # rendered as a confident model verdict.
        log_path = tmp / "nolog.log"
        fixture = tmp / "nolog-fixture.json"
        write_fixture(fixture, [{"role": "user", "content": "classify"}])

        with StubBackend(
            [(200, verdict_response(), None)],
            log_path,
        ) as backend:
            report_path = tmp / "nolog-report.json"
            code = cq.main(
                [
                    "--candidate",
                    "stub",
                    "--backend-url",
                    backend.url,
                    "--json",
                    str(report_path),
                    "--stage1-fixture",
                    str(fixture),
                ]
            )
            nolog = json.loads(report_path.read_text())

        check(
            nolog["stage1"]["outcome"] == "HARNESS_FAILURE",
            "Stage 1 with NO cache evidence is HARNESS_FAILURE, not EXACT_ONLY",
        )
        check(
            "never MEASURED" in nolog["stage1"].get("detail", ""),
            "the unmeasured detail says the reuse was never measured",
        )
        check(
            "UNJUDGED" in nolog["stage1"].get("detail", ""),
            "the unmeasured detail calls the candidate UNJUDGED",
        )

        with StubBackend(
            [(200, verdict_response(), None)],
            log_path,
        ) as backend:
            report_path = tmp / "nolog-report2.json"
            cq.main(
                [
                    "--candidate",
                    "stub",
                    "--backend-url",
                    backend.url,
                    "--json",
                    str(report_path),
                    "--warm-runs",
                    "2",
                    "--stage2-fixture",
                    str(fixture),
                ]
            )
            nolog2 = json.loads(report_path.read_text())

        check(
            nolog2["stage2"]["outcome"] == "HARNESS_FAILURE",
            "Stage 2 with NO cache evidence is HARNESS_FAILURE, not a cache fail",
        )
        check(
            nolog2["stage2"]["warm_reuse_unmeasured"] == 2,
            "Stage 2 counts how many warm runs went unmeasured",
        )

        print("== partial evidence isolates the changed-prefix guard ==")
        # exact_A IS measured; only run B's evidence is missing. This is the one
        # case that exercises the changed-prefix unmeasured guard on its own,
        # rather than being short-circuited by the exact-reuse guard.
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), None),
            ],
            [],
        )
        check(
            report["stage1"]["outcome"] == "HARNESS_FAILURE",
            "a measured exact hit with an UNMEASURED run B is HARNESS_FAILURE, "
            "never EXACT_ONLY",
        )
        check(
            "changed-prefix reuse was never MEASURED"
            in report["stage1"].get("detail", ""),
            "the detail names run B specifically as the unmeasured one",
        )

        print("== reporting honesty ==")
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            [],
        )
        check(
            any(
                "real Claude Code Auto Mode session" in item
                for item in report["does_not_prove"]
            ),
            "even a full pass states that a real session is NOT proven",
        )
        check(
            any(
                "verdict quality" in item for item in report["does_not_prove"]
            ),
            "even a full pass states that verdict quality is NOT proven",
        )
        check(
            report["outcome_meaning"] == cq.OUTCOME_MEANING[report["outcome"]],
            "the report carries the meaning of its own outcome",
        )

    print()
    print(f"{PASSES} passed, {len(FAILURES)} failed")

    for failure in FAILURES:
        print(f"  FAILED: {failure}")

    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
