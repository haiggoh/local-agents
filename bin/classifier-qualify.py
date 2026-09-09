#!/usr/bin/env python3
"""classifier-qualify.py — model-agnostic Auto Mode classifier qualification.

WHY THIS EXISTS
Sixteen sessions of Auto Mode work qualified candidate classifiers by hand, one
model at a time, and the interesting failures were all found LATE. The two that
cost the most were structural, not incidental:

  1. Qwen3.6 passed exact-request replay brilliantly (99.96% reuse of 37,490
     tokens, warm runs 0.368-0.404s) and still could not serve a live session,
     because its HYBRID cache is non_trimmable: on a later 37,569-token request
     a 98.84% shared prefix (37,132 tokens) was refused outright and the whole
     prompt was recomputed in ~32.9s. A live session grows its prefix every
     turn, so EXACT replay alone qualifies nothing. That is why Stage 1 is
     three runs (cold A -> exact A -> changed B), not two. (The two percentages
     come from different fixture sizes; neither is the other's baseline.)
  2. Devstral failed Stage 1 with HTTP 400 BEFORE any prefill, because two
     adjacent user-role messages violate Mistral alternation. That is a harness
     mismatch, not a model verdict — so an adapted pass must stay visibly
     distinct from an unadapted one rather than being recorded as a plain PASS.

Hence the seven outcomes below: a run must be able to say WHICH boundary it hit.
`EXACT_ONLY` is the Qwen3.6 shape and is the single most important one to name,
because it is the failure that looks like success.

WHAT THIS IS NOT
This does not prove verdict QUALITY across safe/ambiguous/dangerous actions, and
it never claims a model is production-ready. It measures protocol conformance,
cache behaviour and latency against a genuine captured fixture. A real Claude
Code Auto Mode session remains a separate, later gate.

It never mutates the repository, never edits a fixture, and never starts Claude
Code. Bring your own already-serving backend; this only sends requests to it.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

FRAMEWORK_VERSION = "classifier-qualify-v1"
SCHEMA_VERSION = 1

# Stage-2 warm runs must land inside Claude Code's classifier patience. A warm
# run slower than this makes Auto Mode feel broken even when every contract
# passes, so it is a hard gate rather than a reported statistic.
WARM_DEADLINE_SECONDS = 45.0

# Stage 1 gates changed-prefix reuse. Devstral measured 98.86% and Qwen3.6
# measured 0% usable despite a 98.84% shared prefix, so the threshold sits below
# the passing measurement and far above a miss.
CHANGED_PREFIX_MIN_REUSE = 90.0

# Outcomes, most to least successful. Ordering is load-bearing: `worst_outcome`
# reports the earliest boundary a candidate hit.
OUTCOMES = (
    "DIRECT_PASS",
    "MODEL_PASS_WITH_ADAPTER",
    "EXACT_ONLY",
    "CONTRACT_FAIL",
    "CACHE_OR_LATENCY_FAIL",
    "RUNTIME_OR_CONTEXT_FAIL",
    "HARNESS_FAILURE",
)

OUTCOME_MEANING = {
    "DIRECT_PASS": (
        "Every gate passed with the genuine request unmodified. The only "
        "outcome that needs no caveat when reported."
    ),
    "MODEL_PASS_WITH_ADAPTER": (
        "The model itself passed, but only after a semantics-preserving "
        "request adaptation (e.g. merging adjacent user messages for Mistral "
        "alternation). The adapter's correctness across other traffic to the "
        "same backend is a SEPARATE question this run does not answer."
    ),
    "EXACT_ONLY": (
        "Exact-request replay passed but changed-prefix reuse did not — the "
        "Qwen3.6 shape. Looks like a pass on warm-replay numbers alone and "
        "still cannot serve a live session, whose prefix grows every turn."
    ),
    "CONTRACT_FAIL": (
        "The backend answered but the response violated the classifier "
        "contract: a malformed verdict, a missing end_turn, or trailing "
        "material after the verdict."
    ),
    "CACHE_OR_LATENCY_FAIL": (
        "Contracts held but a cache-reuse or warm-deadline gate failed."
    ),
    "RUNTIME_OR_CONTEXT_FAIL": (
        "The backend refused or could not carry the request — HTTP error, "
        "context overflow, or a role/alternation rejection before prefill."
    ),
    "HARNESS_FAILURE": (
        "This framework could not complete the measurement, so the candidate "
        "is UNJUDGED. Never read this as a model verdict."
    ),
}


def load_prewarm_helper(repo: Path) -> Any:
    """Reuse the shipped prewarm primitives instead of reimplementing them.

    replay_fixture / classifier_response_contract / read_log_evidence already
    encode hard-won details (which log lines report cached tokens, when a
    trimmed closing tag is legitimate). A second copy would drift from them.
    """
    helper_path = repo / "bin" / "omlx-auto-prewarm.py"

    if not helper_path.is_file():
        raise FileNotFoundError(f"required helper missing: {helper_path}")

    spec = importlib.util.spec_from_file_location(
        "omlx_auto_prewarm_for_qualify",
        helper_path,
    )

    if not spec or not spec.loader:
        raise ImportError(f"cannot load helper: {helper_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def merge_adjacent_user_messages(body: bytes) -> tuple[bytes, bool]:
    """Coalesce adjacent user-role messages, preserving their text.

    Mistral-family templates reject two user messages in a row with HTTP 400
    before any prefill. Merging is semantics-preserving for the classifier
    request (the blocks stay in order, nothing is dropped), but it IS a request
    modification, so a pass obtained this way is reported as
    MODEL_PASS_WITH_ADAPTER and never as DIRECT_PASS.
    """
    try:
        parsed = json.loads(body)
    except Exception:
        return body, False

    messages = parsed.get("messages") if isinstance(parsed, dict) else None

    if not isinstance(messages, list):
        return body, False

    merged: list[Any] = []
    changed = False

    for message in messages:
        if (
            merged
            and isinstance(message, dict)
            and isinstance(merged[-1], dict)
            and message.get("role") == "user"
            and merged[-1].get("role") == "user"
        ):
            previous = merged[-1]
            previous_content = previous.get("content")
            current_content = message.get("content")

            if isinstance(previous_content, str) and isinstance(
                current_content, str
            ):
                previous["content"] = (
                    f"{previous_content}\n\n{current_content}"
                )
                changed = True
                continue

            if isinstance(previous_content, list) and isinstance(
                current_content, list
            ):
                previous["content"] = previous_content + current_content
                changed = True
                continue

            # MIXED str/list content. Found in adversarial review: without this
            # branch the merge silently declined, the two adjacent user messages
            # survived, the retry hit the SAME HTTP 400, and the candidate was
            # recorded as RUNTIME_OR_CONTEXT_FAIL — a model verdict caused by an
            # adapter gap. Normalise to the block form, which is the shape the
            # Anthropic message API accepts for either operand.
            def as_blocks(value: Any) -> list[Any] | None:
                if isinstance(value, str):
                    return [{"type": "text", "text": value}]

                if isinstance(value, list):
                    return list(value)

                return None

            previous_blocks = as_blocks(previous_content)
            current_blocks = as_blocks(current_content)

            if previous_blocks is not None and current_blocks is not None:
                previous["content"] = previous_blocks + current_blocks
                changed = True
                continue

        merged.append(message)

    if not changed:
        return body, False

    parsed["messages"] = merged
    return reserialize(parsed), True


def reserialize(parsed: Any) -> bytes:
    """Serialize a mutated body while minimizing drift from the capture.

    The measurement compares BYTE prefixes, so any re-serialization difference
    that lands EARLY in the body moves the divergence point away from the tail
    and understates reuse. Found in adversarial review: json.dumps defaults
    escape non-ASCII (raw UTF-8 "caf\u00e9" -> "caf\\u00e9"), so a prompt with
    an accent anywhere near the front would report a cache miss that is purely
    an artifact of this function rather than a property of the model.

    ensure_ascii=False keeps text byte-identical to the capture; the separators
    match what an HTTP JSON client emits. Key order is preserved by json.loads
    (dicts keep insertion order), so it is deliberately NOT sorted — sorting
    would reorder keys away from the captured layout and reintroduce the very
    early-divergence problem this avoids.
    """
    return json.dumps(
        parsed,
        ensure_ascii=False,
        separators=(", ", ": "),
    ).encode("utf-8")


def grow_request_prefix(body: bytes, marker: str) -> tuple[bytes, bool]:
    """Append text to the LAST user message to simulate a grown prefix.

    This is the whole point of run B. Claude Code re-injects a per-turn
    system-reminder onto the newest message, so each turn shares a long prefix
    with the previous one and then diverges at the tail. Appending at the tail
    reproduces that shape; changing anything earlier would not.
    """
    try:
        parsed = json.loads(body)
    except Exception:
        return body, False

    messages = parsed.get("messages") if isinstance(parsed, dict) else None

    if not isinstance(messages, list) or not messages:
        return body, False

    for message in reversed(messages):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue

        content = message.get("content")

        if isinstance(content, str):
            message["content"] = f"{content}\n\n{marker}"
            return reserialize(parsed), True

        if isinstance(content, list):
            for block in reversed(content):
                if (
                    isinstance(block, dict)
                    and block.get("type") == "text"
                    and isinstance(block.get("text"), str)
                ):
                    block["text"] = f"{block['text']}\n\n{marker}"
                    return reserialize(parsed), True

    return body, False


def reuse_percent(
    cached_tokens: int | None,
    prompt_tokens: int | None,
) -> float | None:
    """Reuse as a percentage, or None when it was never measured.

    The None-vs-zero distinction is load-bearing. `cached_tokens=0` is a log
    line REPORTING zero reuse — a genuine measured miss, which is exactly what
    a non-trimmable hybrid cache produces. `cached_tokens=None` means no log
    line was recoverable, so reuse is UNKNOWN. Collapsing the two would let
    absent instrumentation masquerade as a model failure.
    """
    if cached_tokens is None or prompt_tokens is None or prompt_tokens <= 0:
        return None

    return round(100.0 * cached_tokens / prompt_tokens, 3)


def write_variant_fixture(
    helper: Any,
    source_fixture: Path,
    new_body: bytes,
    destination: Path,
) -> None:
    """Write a fixture variant WITHOUT touching the genuine capture.

    The genuine fixture is evidence. Every variant is written to a scratch
    directory and the original is only ever read.
    """
    request_path, headers, _ = helper.load_fixture(source_fixture)
    # Match the capture schema EXACTLY. load_fixture enforces schema_version,
    # method == POST and a body_sha256 that must agree with the payload, so a
    # variant missing any of them is rejected before it ever reaches a backend.
    payload = {
        "schema_version": helper.SCHEMA_VERSION,
        "method": "POST",
        "path": request_path,
        "headers": headers,
        "body_base64": base64.b64encode(new_body).decode("ascii"),
        "body_sha256": helper.sha256_bytes(new_body),
        "body_bytes": len(new_body),
    }
    helper.atomic_private_json(destination, payload)


def describe_run(label: str, result: dict[str, Any]) -> dict[str, Any]:
    cached = result.get("cached_tokens")
    prompt = result.get("prompt_tokens")

    return {
        "label": label,
        "http_status": result.get("http_status"),
        "elapsed_seconds": result.get("elapsed_seconds"),
        "contract_valid": bool(result.get("classifier_contract_valid")),
        "response_type": result.get("response_type"),
        "cached_tokens": cached,
        "prompt_tokens": prompt,
        "reuse_percent": reuse_percent(cached, prompt),
    }


def worst_outcome(outcomes: list[str]) -> str:
    """Return the earliest boundary hit, per OUTCOMES ordering."""
    if not outcomes:
        return "HARNESS_FAILURE"

    return max(outcomes, key=OUTCOMES.index)


def run_stage1(
    helper: Any,
    *,
    fixture: Path,
    backend_url: str,
    timeout: float,
    server_log: Path | None,
    scratch: Path,
    allow_adapter: bool,
) -> dict[str, Any]:
    """cold A -> exact A -> changed B.

    Run A twice on purpose: the first is cold (nothing cached) and the second
    must hit an exact-prefix cache. Only then does B test whether reuse
    survives a CHANGED prefix, which is the gate Qwen3.6 failed.
    """
    runs: list[dict[str, Any]] = []
    adapter_used = False
    active_fixture = fixture

    cold = helper.replay_fixture(
        fixture_path=active_fixture,
        backend_url=backend_url,
        timeout=timeout,
        server_log=server_log,
    )

    # An alternation rejection arrives as HTTP 400 before prefill. Retry once
    # through the adapter so a harness mismatch is not recorded as a model
    # failure — but only when explicitly allowed.
    if cold.get("http_status") == 400 and allow_adapter:
        _, _, body = helper.load_fixture(fixture)
        adapted_body, changed = merge_adjacent_user_messages(body)

        if changed:
            adapted = scratch / "stage1-adapted.json"
            write_variant_fixture(helper, fixture, adapted_body, adapted)
            retry = helper.replay_fixture(
                fixture_path=adapted,
                backend_url=backend_url,
                timeout=timeout,
                server_log=server_log,
            )

            if retry.get("http_status") == 200:
                adapter_used = True
                active_fixture = adapted
                runs.append(describe_run("cold_A_rejected_unadapted", cold))
                cold = retry

    runs.append(describe_run("cold_A", cold))

    if cold.get("http_status") != 200:
        return {
            "stage": 1,
            "runs": runs,
            "adapter_used": adapter_used,
            "outcome": "RUNTIME_OR_CONTEXT_FAIL",
            "detail": (
                "cold run A was refused by the backend "
                f"(HTTP {cold.get('http_status')})"
            ),
        }

    if not cold.get("classifier_contract_valid"):
        return {
            "stage": 1,
            "runs": runs,
            "adapter_used": adapter_used,
            "outcome": "CONTRACT_FAIL",
            "detail": "cold run A violated the classifier contract",
        }

    exact = helper.replay_fixture(
        fixture_path=active_fixture,
        backend_url=backend_url,
        timeout=timeout,
        server_log=server_log,
    )
    runs.append(describe_run("exact_A", exact))

    exact_reuse = reuse_percent(
        exact.get("cached_tokens"),
        exact.get("prompt_tokens"),
    )

    if exact.get("http_status") != 200 or not exact.get(
        "classifier_contract_valid"
    ):
        return {
            "stage": 1,
            "runs": runs,
            "adapter_used": adapter_used,
            "outcome": "CONTRACT_FAIL",
            "detail": "exact replay A did not hold the contract",
        }

    _, _, active_body = helper.load_fixture(active_fixture)
    grown_body, grown = grow_request_prefix(
        active_body,
        "<system-reminder>changed-prefix qualification probe</system-reminder>",
    )

    if not grown:
        return {
            "stage": 1,
            "runs": runs,
            "adapter_used": adapter_used,
            "exact_reuse_percent": exact_reuse,
            "outcome": "HARNESS_FAILURE",
            "detail": (
                "could not construct a grown-prefix variant from the fixture, "
                "so changed-prefix reuse was never measured"
            ),
        }

    changed_fixture = scratch / "stage1-changed-b.json"
    write_variant_fixture(helper, active_fixture, grown_body, changed_fixture)

    changed = helper.replay_fixture(
        fixture_path=changed_fixture,
        backend_url=backend_url,
        timeout=timeout,
        server_log=server_log,
    )
    runs.append(describe_run("changed_B", changed))

    changed_reuse = reuse_percent(
        changed.get("cached_tokens"),
        changed.get("prompt_tokens"),
    )

    summary = {
        "stage": 1,
        "runs": runs,
        "adapter_used": adapter_used,
        "exact_reuse_percent": exact_reuse,
        "changed_reuse_percent": changed_reuse,
    }

    if changed.get("http_status") != 200 or not changed.get(
        "classifier_contract_valid"
    ):
        summary["outcome"] = "CONTRACT_FAIL"
        summary["detail"] = "changed request B did not hold the contract"
        return summary

    # An ABSENT measurement is not a failed measurement. Without cache evidence
    # (no --server-log, or a log whose format we cannot read) reuse is unknown,
    # and reporting unknown as EXACT_ONLY would manufacture a confident model
    # verdict out of missing instrumentation — the exact mistake this framework
    # exists to prevent. Distinguish "measured a miss" from "did not measure".
    if changed_reuse is None:
        summary["outcome"] = "HARNESS_FAILURE"
        summary["detail"] = (
            "changed-prefix reuse was never MEASURED: no cache evidence was "
            "recoverable for run B (pass --server-log pointing at the backend "
            "log). The candidate is UNJUDGED — this is not an EXACT_ONLY "
            "result and must not be reported as one."
        )
        return summary

    if exact_reuse is None:
        summary["outcome"] = "HARNESS_FAILURE"
        summary["detail"] = (
            "exact-replay reuse was never MEASURED, so a changed-prefix figure "
            "has no baseline to be compared against. The candidate is UNJUDGED."
        )
        return summary

    if changed_reuse < CHANGED_PREFIX_MIN_REUSE:
        summary["outcome"] = "EXACT_ONLY"
        summary["detail"] = (
            "exact replay reused the cache but the CHANGED prefix did not "
            f"(measured {changed_reuse}%, need >= "
            f"{CHANGED_PREFIX_MIN_REUSE}%). This is the Qwen3.6 shape: a "
            "hybrid non-trimmable cache reports a large shared prefix and "
            "still recomputes the whole prompt. A live session grows its "
            "prefix every turn, so this candidate cannot serve one."
        )
        return summary

    summary["outcome"] = (
        "MODEL_PASS_WITH_ADAPTER" if adapter_used else "DIRECT_PASS"
    )
    return summary


def run_stage2(
    helper: Any,
    *,
    fixture: Path,
    backend_url: str,
    timeout: float,
    server_log: Path | None,
    warm_runs: int,
) -> dict[str, Any]:
    """cold + N warm exact replays, 5/5 contract and the warm deadline.

    No role adapter here by default: Stage 2 measured clean unadapted, so
    silently adapting would hide a regression.
    """
    runs: list[dict[str, Any]] = []

    cold = helper.replay_fixture(
        fixture_path=fixture,
        backend_url=backend_url,
        timeout=timeout,
        server_log=server_log,
    )
    runs.append(describe_run("cold", cold))

    if cold.get("http_status") != 200:
        return {
            "stage": 2,
            "runs": runs,
            "outcome": "RUNTIME_OR_CONTEXT_FAIL",
            "detail": f"cold run refused (HTTP {cold.get('http_status')})",
        }

    contract_passes = 1 if cold.get("classifier_contract_valid") else 0
    warm_reuse_passes = 0
    warm_reuse_unmeasured = 0
    deadline_failures: list[float] = []

    for index in range(warm_runs):
        warm = helper.replay_fixture(
            fixture_path=fixture,
            backend_url=backend_url,
            timeout=timeout,
            server_log=server_log,
        )
        runs.append(describe_run(f"warm_{index + 1}", warm))

        if warm.get("classifier_contract_valid"):
            contract_passes += 1

        warm_reuse = reuse_percent(
            warm.get("cached_tokens"),
            warm.get("prompt_tokens"),
        )

        if warm_reuse is None:
            warm_reuse_unmeasured += 1
        elif warm_reuse >= CHANGED_PREFIX_MIN_REUSE:
            warm_reuse_passes += 1

        # WARM runs only, deliberately. A cold run is a full prefill and is
        # EXPECTED to blow past the deadline — Devstral's cold run took 147.563s
        # and still qualified, because a real session pays that cost once at
        # startup and then reuses the cache. Gating cold on the warm deadline
        # would reject every candidate. (Raised as a defect in review; it is
        # not one, but it reads like one without this note.)
        elapsed = warm.get("elapsed_seconds")

        if isinstance(elapsed, (int, float)) and elapsed > WARM_DEADLINE_SECONDS:
            deadline_failures.append(float(elapsed))

    total_runs = warm_runs + 1
    summary = {
        "stage": 2,
        "runs": runs,
        "contract_passes": contract_passes,
        "contract_required": total_runs,
        "warm_reuse_passes": warm_reuse_passes,
        "warm_reuse_required": warm_runs,
        "warm_reuse_unmeasured": warm_reuse_unmeasured,
        "warm_deadline_seconds": WARM_DEADLINE_SECONDS,
        "warm_deadline_failures": deadline_failures,
    }

    if contract_passes < total_runs:
        summary["outcome"] = "CONTRACT_FAIL"
        summary["detail"] = (
            f"contract held on {contract_passes}/{total_runs} runs; "
            "Stage 2 requires every run to pass"
        )
        return summary

    # Unmeasured is UNJUDGED, never a cache failure. See the Stage-1 note.
    if warm_reuse_unmeasured:
        summary["outcome"] = "HARNESS_FAILURE"
        summary["detail"] = (
            f"warm cache reuse was never MEASURED on "
            f"{warm_reuse_unmeasured}/{warm_runs} runs (pass --server-log "
            "pointing at the backend log). The candidate is UNJUDGED — this "
            "is not a CACHE_OR_LATENCY_FAIL and must not be reported as one."
        )
        return summary

    if warm_reuse_passes < warm_runs:
        summary["outcome"] = "CACHE_OR_LATENCY_FAIL"
        summary["detail"] = (
            f"warm cache reuse held on {warm_reuse_passes}/{warm_runs} runs"
        )
        return summary

    if deadline_failures:
        summary["outcome"] = "CACHE_OR_LATENCY_FAIL"
        summary["detail"] = (
            "warm runs exceeded the "
            f"{WARM_DEADLINE_SECONDS}s classifier deadline: "
            f"{deadline_failures}"
        )
        return summary

    summary["outcome"] = "DIRECT_PASS"
    return summary


def build_report(
    *,
    candidate: str,
    stage1: dict[str, Any] | None,
    stage2: dict[str, Any] | None,
) -> dict[str, Any]:
    outcomes = [
        stage["outcome"]
        for stage in (stage1, stage2)
        if stage and stage.get("outcome")
    ]
    overall = worst_outcome(outcomes)

    # An adapted Stage-1 pass must not be laundered into a clean pass by a
    # DIRECT_PASS Stage 2.
    if (
        overall == "DIRECT_PASS"
        and stage1
        and stage1.get("adapter_used")
    ):
        overall = "MODEL_PASS_WITH_ADAPTER"

    return {
        "schema_version": SCHEMA_VERSION,
        "framework_version": FRAMEWORK_VERSION,
        "candidate": candidate,
        "stage1": stage1,
        "stage2": stage2,
        "outcome": overall,
        "outcome_meaning": OUTCOME_MEANING[overall],
        "proves": [
            "protocol conformance against a genuine captured request",
            "exact-prefix and changed-prefix cache reuse",
            "warm latency inside the classifier deadline",
        ],
        "does_not_prove": [
            "verdict quality across safe/ambiguous/dangerous actions",
            "cache persistence across backend restarts",
            "coexistence with the CSL-selected main model",
            "concurrency and memory-pressure behaviour",
            "a real Claude Code Auto Mode session",
            "adapter correctness for other traffic to the same backend",
        ],
    }


def render_text(report: dict[str, Any]) -> str:
    lines = [
        f"candidate: {report['candidate']}",
        f"framework: {report['framework_version']}",
        "",
    ]

    for key in ("stage1", "stage2"):
        stage = report.get(key)

        if not stage:
            lines.append(f"{key}: skipped")
            continue

        lines.append(f"{key}: {stage.get('outcome')}")

        if stage.get("detail"):
            lines.append(f"  detail: {stage['detail']}")

        for run in stage.get("runs", []):
            lines.append(
                "  {label:<28} HTTP {http} {elapsed}s "
                "contract={contract} reuse={reuse}".format(
                    label=run["label"],
                    http=run["http_status"],
                    elapsed=run["elapsed_seconds"],
                    contract="pass" if run["contract_valid"] else "FAIL",
                    reuse=(
                        f"{run['reuse_percent']}%"
                        if run["reuse_percent"] is not None
                        else "n/a"
                    ),
                )
            )

        lines.append("")

    lines.append(f"QUALIFICATION_VERDICT={report['outcome']}")
    lines.append(f"  {report['outcome_meaning']}")
    lines.append("")
    lines.append("does NOT prove:")
    lines.extend(f"  - {item}" for item in report["does_not_prove"])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Qualify a local model as an Auto Mode classifier against a "
            "genuine captured request. Read-only: never mutates the "
            "repository, the fixture, or a running server's state."
        ),
    )
    parser.add_argument(
        "--candidate",
        help="candidate label recorded in the report (e.g. devstral-small2)",
    )
    parser.add_argument(
        "--stage1-fixture",
        type=Path,
        help="genuine Stage-1 captured request fixture",
    )
    parser.add_argument(
        "--stage2-fixture",
        type=Path,
        help="genuine Stage-2 captured request fixture",
    )
    parser.add_argument(
        "--backend-url",
        default="http://127.0.0.1:8002",
        help="already-serving backend base URL (this tool starts nothing)",
    )
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument(
        "--server-log",
        type=Path,
        help="backend log, read for cache evidence (cached/prompt tokens)",
    )
    parser.add_argument(
        "--warm-runs",
        type=int,
        default=4,
        help="Stage-2 warm replays after the cold run (default 4)",
    )
    parser.add_argument(
        "--merge-adjacent-user-messages",
        action="store_true",
        help=(
            "allow one adapted Stage-1 retry after an HTTP 400 alternation "
            "rejection; a pass obtained this way is reported as "
            "MODEL_PASS_WITH_ADAPTER, never DIRECT_PASS"
        ),
    )
    parser.add_argument("--json", type=Path, help="write the JSON report here")
    parser.add_argument(
        "--explain-outcomes",
        action="store_true",
        help="print what each outcome code means and exit",
    )
    args = parser.parse_args(argv)

    if args.explain_outcomes:
        for name in OUTCOMES:
            print(f"{name}\n  {OUTCOME_MEANING[name]}\n")
        return 0

    if not args.candidate:
        parser.error("--candidate is required")

    if not args.stage1_fixture and not args.stage2_fixture:
        parser.error("at least one of --stage1-fixture / --stage2-fixture")

    if args.warm_runs < 1:
        parser.error("--warm-runs must be at least 1")

    repo = Path(__file__).resolve().parent.parent

    try:
        helper = load_prewarm_helper(repo)
    except Exception as exc:
        print(f"HARNESS_FAILURE: {exc}", file=sys.stderr)
        return 3

    scratch = Path(tempfile.mkdtemp(prefix="classifier-qualify-"))
    stage1 = stage2 = None

    try:
        if args.stage1_fixture:
            stage1 = run_stage1(
                helper,
                fixture=args.stage1_fixture,
                backend_url=args.backend_url,
                timeout=args.timeout,
                server_log=args.server_log,
                scratch=scratch,
                allow_adapter=args.merge_adjacent_user_messages,
            )

        if args.stage2_fixture:
            stage2 = run_stage2(
                helper,
                fixture=args.stage2_fixture,
                backend_url=args.backend_url,
                timeout=args.timeout,
                server_log=args.server_log,
                warm_runs=args.warm_runs,
            )
    except Exception as exc:
        report = build_report(
            candidate=args.candidate,
            stage1=stage1,
            stage2=stage2,
        )
        report["outcome"] = "HARNESS_FAILURE"
        report["outcome_meaning"] = OUTCOME_MEANING["HARNESS_FAILURE"]
        report["harness_error"] = repr(exc)
        print(render_text(report))

        if args.json:
            helper.atomic_private_json(args.json, report)

        return 3
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    report = build_report(
        candidate=args.candidate,
        stage1=stage1,
        stage2=stage2,
    )
    print(render_text(report))

    if args.json:
        helper.atomic_private_json(args.json, report)

    return 0 if report["outcome"] in {
        "DIRECT_PASS",
        "MODEL_PASS_WITH_ADAPTER",
    } else 1


if __name__ == "__main__":
    sys.exit(main())
