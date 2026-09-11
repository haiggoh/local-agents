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


def write_fixture(
    path: Path,
    messages: list[dict],
    *,
    stage: int = 1,
    extra: dict | None = None,
) -> bytes:
    """Write a stage-identifiable fixture in the real capture schema."""
    request = {
        "model": "claude-sonnet-5",
        "messages": messages,
        "max_tokens": 64 if stage == 1 else 8192,
    }

    if stage == 1:
        request["stop_sequences"] = [
            f"{chr(60)}/severity{chr(62)}"
        ]

    if extra:
        request.update(extra)

    body = json.dumps(request).encode()
    fixture = {
        "schema_version": 1,
        "method": "POST",
        "path": "/v1/messages",
        "headers": {"content-type": "application/json"},
        "body_base64": base64.b64encode(body).decode("ascii"),
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "body_bytes": len(body),
    }
    path.write_text(json.dumps(fixture), encoding="utf-8")
    return body


def log(cached: int, prompt: int) -> str:
    return f"served cached_tokens={cached} prompt_tokens={prompt}"


def run(
    tmp: Path,
    script,
    argv_extra: list[str] | None = None,
    fixture_messages=None,
    stage: int = 1,
):
    """Drive the framework against the stub backend for one stage."""
    log_path = tmp / "server.log"
    fixture = tmp / "fixture.json"
    messages = fixture_messages

    if messages is None:
        if stage == 1:
            messages = [
                {"role": "assistant", "content": "classifier context"},
                {"role": "user", "content": "classify this action"},
            ]
        else:
            messages = [
                {"role": "user", "content": "classify this action"}
            ]

    write_fixture(fixture, messages, stage=stage)
    flag = "--stage1-fixture" if stage == 1 else "--stage2-fixture"
    extras = list(argv_extra or [])

    if stage == 1 and not any(
        item in {"--stage1-fixture-b", "--stage1-synthetic-b"}
        for item in extras
    ):
        extras.append("--stage1-synthetic-b")

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
                *extras,
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
            [
                (
                    200,
                    b'{"type":"message","content":'
                    b'[{"type":"text","text":"maybe unsafe?"}]}',
                    log(0, 100),
                )
            ],
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
        write_fixture(
            fixture,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "classify"},
            ],
            stage=1,
        )

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
                    "--stage1-synthetic-b",
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

        write_fixture(
            fixture,
            [{"role": "user", "content": "classify"}],
            stage=2,
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

        print("== an HTTP fault is a RUNTIME fault, not a model verdict ==")
        # Regression for a defect found on REAL hardware 2026-09-10: a Metal
        # out-of-memory returned 500 on warm_4 and Stage 2 reported
        # CONTRACT_FAIL, blaming the model for the machine running out of GPU
        # memory. Script four healthy runs then a 500, exactly as measured.
        code, report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(28073, 28073)),
                (200, verdict_response(), log(28073, 28073)),
                (200, verdict_response(), log(28073, 28073)),
                (200, verdict_response(), log(28073, 28073)),
                (200, verdict_response(), log(28073, 28073)),
                (500, b'{"error":"Metal out of memory"}', log(28073, 28073)),
            ],
            ["--warm-runs", "5"],
            stage=2,
        )
        check(
            report["stage2"]["outcome"] == "RUNTIME_OR_CONTEXT_FAIL",
            "a mid-suite HTTP 500 is RUNTIME_OR_CONTEXT_FAIL, never CONTRACT_FAIL",
        )
        check(
            report["stage2"]["http_failures"]
            and report["stage2"]["http_failures"][0]["http_status"] == 500,
            "the failing run and its status are recorded for diagnosis",
        )
        check(
            "not a model verdict" in report["stage2"].get("detail", ""),
            "the detail states explicitly that the candidate is not judged on it",
        )

        print("== exit codes distinguish judged-fail from unjudged ==")
        # 0 = pass, 1 = JUDGED and failed, 3 = UNJUDGED. Automation that treats
        # any non-zero as "model rejected" would misread a harness failure as a
        # verdict, so the two must not collapse. (Note when checking by hand: a
        # shell pipeline reports the LAST command's status, so `cmd | head`
        # shows head's 0 and hides this entirely.)
        code_unjudged = cq.main(
            [
                "--candidate",
                "stub",
                "--backend-url",
                "http://127.0.0.1:9",
                "--timeout",
                "1",
                "--json",
                str(tmp / "unjudged.json"),
                "--stage1-fixture",
                str(tmp / "missing-fixture.json"),
                "--stage1-synthetic-b",
            ]
        )
        check(
            code_unjudged == 3,
            "an UNJUDGED run exits 3, never 0 and never 1",
        )

        code_judged, judged_report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(0, 38244)),
            ],
            [],
        )
        check(
            judged_report["stage1"]["outcome"] == "EXACT_ONLY"
            and code_judged == 1,
            "a JUDGED failure exits 1, distinct from the unjudged 3",
        )

        print("== explicit Stage-1 B mode is mandatory and exclusive ==")
        mode_fixture_a = tmp / "mode-a.json"
        mode_fixture_b = tmp / "mode-b.json"
        write_fixture(
            mode_fixture_a,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "A"},
            ],
            stage=1,
        )
        write_fixture(
            mode_fixture_b,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "B"},
            ],
            stage=1,
        )

        for label, mode_args in (
            ("missing", []),
            (
                "both",
                [
                    "--stage1-fixture-b",
                    str(mode_fixture_b),
                    "--stage1-synthetic-b",
                ],
            ),
        ):
            mode_log = tmp / f"mode-{label}.log"

            with StubBackend(
                [(200, verdict_response(), log(0, 1))],
                mode_log,
            ) as backend:
                try:
                    cq.main(
                        [
                            "--candidate",
                            "stub",
                            "--backend-url",
                            backend.url,
                            "--stage1-fixture",
                            str(mode_fixture_a),
                            *mode_args,
                        ]
                    )
                except SystemExit as exc:
                    mode_code = exc.code
                else:
                    mode_code = 0

                mode_requests = len(backend.received)

            check(
                mode_code == 2 and mode_requests == 0,
                f"{label} B mode is rejected before backend contact",
            )

        print("== strict fixture stage identity: zero backend contact ==")
        stage1_fixture = tmp / "identity-stage1.json"
        stage2_fixture = tmp / "identity-stage2.json"
        write_fixture(
            stage1_fixture,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "classify"},
            ],
            stage=1,
        )
        write_fixture(
            stage2_fixture,
            [{"role": "user", "content": "classify"}],
            stage=2,
        )

        for label, flag, fixture_path, extra in (
            (
                "Stage-1 fixture supplied as Stage 2",
                "--stage2-fixture",
                stage1_fixture,
                [],
            ),
            (
                "Stage-2 fixture supplied as Stage 1",
                "--stage1-fixture",
                stage2_fixture,
                ["--stage1-synthetic-b"],
            ),
        ):
            slug = label.replace(" ", "-")
            mismatch_log = tmp / f"{slug}.log"
            mismatch_report = tmp / f"{slug}.json"

            with StubBackend(
                [(200, verdict_response(), log(0, 1))],
                mismatch_log,
            ) as backend:
                mismatch_code = cq.main(
                    [
                        "--candidate",
                        "stub",
                        "--backend-url",
                        backend.url,
                        "--json",
                        str(mismatch_report),
                        flag,
                        str(fixture_path),
                        *extra,
                    ]
                )
                mismatch_requests = len(backend.received)

            mismatch = json.loads(mismatch_report.read_text())
            check(
                mismatch_code == 3
                and mismatch["outcome"] == "HARNESS_FAILURE",
                f"{label} is an unjudged harness failure",
            )
            check(
                mismatch_requests == 0,
                f"{label} makes zero backend requests",
            )

        malformed_fixture = tmp / "identity-malformed-stage1.json"
        write_fixture(
            malformed_fixture,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "classify"},
            ],
            stage=1,
            extra={"max_tokens": 65},
        )
        malformed_log = tmp / "identity-malformed.log"
        malformed_report = tmp / "identity-malformed.json"

        with StubBackend(
            [(200, verdict_response(), log(0, 1))],
            malformed_log,
        ) as backend:
            malformed_code = cq.main(
                [
                    "--candidate",
                    "stub",
                    "--backend-url",
                    backend.url,
                    "--json",
                    str(malformed_report),
                    "--stage1-fixture",
                    str(malformed_fixture),
                    "--stage1-synthetic-b",
                ]
            )
            malformed_requests = len(backend.received)

        check(
            malformed_code == 3 and malformed_requests == 0,
            "malformed stage metadata fails with zero backend contact",
        )

        print("== genuine Stage-1 A/B provenance and exact replay ==")
        genuine_a = tmp / "genuine-a.json"
        genuine_b = tmp / "genuine-b.json"
        body_a = write_fixture(
            genuine_a,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "classify A"},
            ],
            stage=1,
        )
        body_b = write_fixture(
            genuine_b,
            [
                {"role": "assistant", "content": "context"},
                {"role": "user", "content": "classify changed B"},
            ],
            stage=1,
        )
        genuine_log = tmp / "genuine.log"
        genuine_report = tmp / "genuine.json"

        with StubBackend(
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            genuine_log,
        ) as backend:
            genuine_code = cq.main(
                [
                    "--candidate",
                    "stub",
                    "--backend-url",
                    backend.url,
                    "--server-log",
                    str(genuine_log),
                    "--json",
                    str(genuine_report),
                    "--stage1-fixture",
                    str(genuine_a),
                    "--stage1-fixture-b",
                    str(genuine_b),
                ]
            )
            genuine_received = list(backend.received)

        genuine = json.loads(genuine_report.read_text())
        check(
            genuine_code == 0
            and genuine_received == [body_a, body_a, body_b],
            "genuine A/B sends exact A, exact A, then exact B bytes",
        )
        check(
            genuine["stage1"]["changed_request_source"]
            == "genuine_fixture_b"
            and genuine["stage1"]["synthetic_b"] is False
            and genuine["stage1"]["fixture_a_sha256"]
            == hashlib.sha256(body_a).hexdigest()
            and genuine["stage1"]["fixture_b_sha256"]
            == hashlib.sha256(body_b).hexdigest(),
            "genuine B provenance and both fixture hashes are reported",
        )
        check(
            any(
                "captured fixture B" in item
                for item in genuine["proves"]
            )
            and not any(
                "changed B was synthesized" in item
                for item in genuine["does_not_prove"]
            ),
            "genuine A/B reporting claims only captured-B evidence",
        )

        print("== genuine B receives the opt-in adapter independently ==")
        adapted_a = tmp / "adapted-a.json"
        adapted_b = tmp / "adapted-b.json"
        adapted_a_body = write_fixture(
            adapted_a,
            [
                {"role": "user", "content": "A1"},
                {"role": "user", "content": "A2"},
            ],
            stage=1,
        )
        adapted_b_body = write_fixture(
            adapted_b,
            [
                {"role": "user", "content": "B1"},
                {"role": "user", "content": "B2"},
            ],
            stage=1,
        )
        expected_a, expected_a_changed = (
            cq.merge_adjacent_user_messages(adapted_a_body)
        )
        expected_b, expected_b_changed = (
            cq.merge_adjacent_user_messages(adapted_b_body)
        )
        adapted_log = tmp / "adapted-genuine.log"
        adapted_report = tmp / "adapted-genuine.json"

        with StubBackend(
            [
                (400, b'{"error":"alternation"}', None),
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            adapted_log,
        ) as backend:
            adapted_code = cq.main(
                [
                    "--candidate",
                    "stub",
                    "--backend-url",
                    backend.url,
                    "--server-log",
                    str(adapted_log),
                    "--json",
                    str(adapted_report),
                    "--stage1-fixture",
                    str(adapted_a),
                    "--stage1-fixture-b",
                    str(adapted_b),
                    "--merge-adjacent-user-messages",
                ]
            )
            adapted_received = list(backend.received)

        check(
            expected_a_changed
            and expected_b_changed
            and adapted_code == 0
            and adapted_received
            == [adapted_a_body, expected_a, expected_a, expected_b],
            "adapter sends exact independently adapted genuine A and B bytes",
        )

        print("== synthetic-B reporting honesty ==")
        synthetic_code, synthetic_report, _ = run(
            tmp,
            [
                (200, verdict_response(), log(0, 38244)),
                (200, verdict_response(), log(38244, 38244)),
                (200, verdict_response(), log(37808, 38244)),
            ],
            ["--stage1-synthetic-b"],
        )
        check(
            synthetic_code == 0
            and synthetic_report["stage1"]["changed_request_source"]
            == "synthetic_tail_growth"
            and synthetic_report["stage1"]["synthetic_b"] is True
            and synthetic_report["stage1"]["fixture_b_sha256"] is None,
            "synthetic B is explicit and truthfully labeled",
        )
        check(
            any(
                "changed B was synthesized" in item
                for item in synthetic_report["does_not_prove"]
            )
            and not any(
                "captured fixture B" in item
                for item in synthetic_report["proves"]
            ),
            "synthetic B cannot be reported as genuine A/B evidence",
        )
        check(
            "genuine request unmodified"
            not in synthetic_report["outcome_meaning"],
            "synthetic DIRECT_PASS wording does not claim unmodified evidence",
        )

        print("== evidence-driven proves reporting ==")
        no_stage_report = cq.build_report(
            candidate="stub",
            stage1=None,
            stage2=None,
        )
        check(
            no_stage_report["proves"] == [],
            "a preflight HARNESS_FAILURE proves nothing",
        )
        check(
            "  (none)" in cq.render_text(no_stage_report),
            "an empty proves list renders explicitly as none",
        )

        contract_fail_report = cq.build_report(
            candidate="stub",
            stage1={
                "outcome": "CONTRACT_FAIL",
                "runs": [
                    {
                        "label": "cold_A",
                        "http_status": 200,
                        "contract_valid": False,
                    }
                ],
                "changed_request_source": "synthetic_tail_growth",
            },
            stage2=None,
        )
        check(
            not any(
                "response contract held" in item
                for item in contract_fail_report["proves"]
            ),
            "CONTRACT_FAIL does not claim response-contract conformance",
        )

        exact_only_report = cq.build_report(
            candidate="stub",
            stage1={
                "outcome": "EXACT_ONLY",
                "runs": [
                    {
                        "label": "cold_A",
                        "http_status": 200,
                        "contract_valid": True,
                    },
                    {
                        "label": "exact_A",
                        "http_status": 200,
                        "contract_valid": True,
                    },
                    {
                        "label": "changed_B",
                        "http_status": 200,
                        "contract_valid": True,
                    },
                ],
                "exact_reuse_percent": 100.0,
                "changed_reuse_percent": 0.0,
                "changed_request_source": "synthetic_tail_growth",
            },
            stage2=None,
        )
        check(
            "Stage-1 exact-prefix cache reuse was measured"
            in exact_only_report["proves"]
            and "Stage-1 changed-prefix cache reuse was measured"
            in exact_only_report["proves"],
            "EXACT_ONLY reports measured cache evidence",
        )
        check(
            not any(
                "met the configured threshold" in item
                for item in exact_only_report["proves"]
            ),
            "EXACT_ONLY does not claim the changed-prefix threshold passed",
        )

        stage2_cache_fail_report = cq.build_report(
            candidate="stub",
            stage1=None,
            stage2={
                "outcome": "CACHE_OR_LATENCY_FAIL",
                "contract_passes": 3,
                "contract_required": 3,
                "warm_reuse_passes": 0,
                "warm_reuse_required": 2,
                "warm_reuse_unmeasured": 0,
                "warm_deadline_failures": [],
                "runs": [],
            },
        )
        check(
            "Stage-2 warm cache reuse was measured"
            in stage2_cache_fail_report["proves"],
            "Stage-2 cache failure reports that reuse was measured",
        )
        check(
            not any(
                "warm cache reuse met" in item
                for item in stage2_cache_fail_report["proves"]
            )
            and not any(
                "latency stayed inside" in item
                for item in stage2_cache_fail_report["proves"]
            ),
            "Stage-2 cache failure claims neither threshold nor deadline pass",
        )

        stage2_pass_report = cq.build_report(
            candidate="stub",
            stage1=None,
            stage2={
                "outcome": "DIRECT_PASS",
                "contract_passes": 5,
                "contract_required": 5,
                "warm_reuse_passes": 4,
                "warm_reuse_required": 4,
                "warm_reuse_unmeasured": 0,
                "warm_deadline_failures": [],
                "runs": [],
            },
        )
        check(
            "Stage-2 response contract held on every required run"
            in stage2_pass_report["proves"]
            and "Stage-2 warm cache reuse met the configured threshold"
            in stage2_pass_report["proves"]
            and "Stage-2 warm latency stayed inside the classifier deadline"
            in stage2_pass_report["proves"],
            "Stage-2 DIRECT_PASS reports contract, cache, and deadline success",
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
