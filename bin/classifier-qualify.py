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
import urllib.parse
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
        "Every requested gate passed without a request adapter. Check the "
        "Stage-1 changed-request source before describing the evidence as "
        "genuine A/B."
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


def fixture_body_sha256(helper: Any, fixture: Path) -> str:
    """Return the verified captured-body identity for report provenance."""
    _, _, body = helper.load_fixture(fixture)
    return helper.sha256_bytes(body)


def validate_fixture_stage(
    helper: Any,
    fixture: Path,
    expected_stage: int,
) -> None:
    """Reject a mislabeled classifier fixture before backend contact."""
    request_path, _, body = helper.load_fixture(fixture)
    request_path = urllib.parse.urlsplit(request_path).path

    if request_path != "/v1/messages":
        raise RuntimeError(
            f"{fixture}: classifier fixture path must be /v1/messages"
        )

    try:
        request = json.loads(body)
    except Exception as exc:
        raise RuntimeError(
            f"{fixture}: request body is not valid JSON"
        ) from exc

    if not isinstance(request, dict):
        raise RuntimeError(
            f"{fixture}: request body must be a JSON object"
        )

    messages = request.get("messages")
    max_tokens = request.get("max_tokens")
    stop_sequences = request.get("stop_sequences")
    tools = request.get("tools")

    if not isinstance(messages, list) or not all(
        isinstance(message, dict) for message in messages
    ):
        raise RuntimeError(
            f"{fixture}: messages must be a list of objects"
        )

    if expected_stage == 1:
        severity_close = f"{chr(60)}/severity{chr(62)}"

        if max_tokens != 64:
            raise RuntimeError(
                f"{fixture}: Stage 1 requires max_tokens=64, "
                f"got {max_tokens!r}"
            )

        if len(messages) < 2:
            raise RuntimeError(
                f"{fixture}: Stage 1 requires a segmented "
                "multi-message request"
            )

        if not (
            isinstance(stop_sequences, list)
            and severity_close in stop_sequences
        ):
            raise RuntimeError(
                f"{fixture}: Stage 1 requires the severity closing "
                "stop sequence"
            )

        return

    if expected_stage == 2:
        if max_tokens != 8192:
            raise RuntimeError(
                f"{fixture}: Stage 2 requires max_tokens=8192, "
                f"got {max_tokens!r}"
            )

        if len(messages) != 1:
            raise RuntimeError(
                f"{fixture}: Stage 2 requires exactly one message"
            )

        if "stop_sequences" in request:
            raise RuntimeError(
                f"{fixture}: Stage 2 must not contain stop_sequences"
            )

        if tools not in (None, []):
            raise RuntimeError(
                f"{fixture}: Stage 2 must not contain tools"
            )

        return

    raise ValueError(f"unsupported classifier stage: {expected_stage}")


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
    fixture_b: Path | None,
    synthetic_b: bool,
    backend_url: str,
    timeout: float,
    server_log: Path | None,
    scratch: Path,
    allow_adapter: bool,
) -> dict[str, Any]:
    """Replay cold A, exact A, then an explicit genuine or synthetic B."""
    runs: list[dict[str, Any]] = []
    adapter_used = False
    active_fixture = fixture
    fixture_b_sha256 = (
        fixture_body_sha256(helper, fixture_b)
        if fixture_b is not None
        else None
    )
    provenance = {
        "changed_request_source": (
            "genuine_fixture_b"
            if fixture_b is not None
            else "synthetic_tail_growth"
        ),
        "fixture_a_sha256": fixture_body_sha256(helper, fixture),
        "fixture_b_sha256": fixture_b_sha256,
        "synthetic_b": synthetic_b,
    }

    def summary(**values: Any) -> dict[str, Any]:
        return {
            "stage": 1,
            "runs": runs,
            "adapter_used": adapter_used,
            **provenance,
            **values,
        }

    cold = helper.replay_fixture(
        fixture_path=active_fixture,
        backend_url=backend_url,
        timeout=timeout,
        server_log=server_log,
    )

    if cold.get("http_status") == 400 and allow_adapter:
        _, _, body = helper.load_fixture(fixture)
        adapted_body, changed = merge_adjacent_user_messages(body)

        if changed:
            adapted = scratch / "stage1-adapted-a.json"
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
                runs.append(
                    describe_run("cold_A_rejected_unadapted", cold)
                )
                cold = retry

    runs.append(describe_run("cold_A", cold))

    if cold.get("http_status") != 200:
        return summary(
            outcome="RUNTIME_OR_CONTEXT_FAIL",
            detail=(
                "cold run A was refused by the backend "
                f"(HTTP {cold.get('http_status')})"
            ),
        )

    if not cold.get("classifier_contract_valid"):
        return summary(
            outcome="CONTRACT_FAIL",
            detail="cold run A violated the classifier contract",
        )

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

    if exact.get("http_status") != 200:
        return summary(
            exact_reuse_percent=exact_reuse,
            outcome="RUNTIME_OR_CONTEXT_FAIL",
            detail=(
                "exact replay A failed at runtime "
                f"(HTTP {exact.get('http_status')})"
            ),
        )

    if not exact.get("classifier_contract_valid"):
        return summary(
            exact_reuse_percent=exact_reuse,
            outcome="CONTRACT_FAIL",
            detail="exact replay A did not hold the contract",
        )

    if fixture_b is not None:
        changed_fixture = fixture_b

        if adapter_used:
            _, _, body_b = helper.load_fixture(fixture_b)
            adapted_b_body, changed_b = merge_adjacent_user_messages(
                body_b
            )

            if changed_b:
                adapted_b = scratch / "stage1-adapted-b.json"
                write_variant_fixture(
                    helper,
                    fixture_b,
                    adapted_b_body,
                    adapted_b,
                )
                changed_fixture = adapted_b
    else:
        _, _, active_body = helper.load_fixture(active_fixture)
        left, right = chr(60), chr(62)
        marker = (
            f"{left}system-reminder{right}"
            "changed-prefix qualification probe"
            f"{left}/system-reminder{right}"
        )
        grown_body, grown = grow_request_prefix(active_body, marker)

        if not grown:
            return summary(
                exact_reuse_percent=exact_reuse,
                outcome="HARNESS_FAILURE",
                detail=(
                    "could not construct a grown-prefix variant from the "
                    "fixture, so changed-prefix reuse was never measured"
                ),
            )

        changed_fixture = scratch / "stage1-changed-b.json"
        write_variant_fixture(
            helper,
            active_fixture,
            grown_body,
            changed_fixture,
        )

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
    result = summary(
        exact_reuse_percent=exact_reuse,
        changed_reuse_percent=changed_reuse,
    )

    if changed.get("http_status") != 200:
        result["outcome"] = "RUNTIME_OR_CONTEXT_FAIL"
        result["detail"] = (
            "changed request B failed at runtime "
            f"(HTTP {changed.get('http_status')})"
        )
        return result

    if not changed.get("classifier_contract_valid"):
        result["outcome"] = "CONTRACT_FAIL"
        result["detail"] = "changed request B did not hold the contract"
        return result

    if changed_reuse is None:
        result["outcome"] = "HARNESS_FAILURE"
        result["detail"] = (
            "changed-prefix reuse was never MEASURED: no cache evidence "
            "was recoverable for run B (pass --server-log pointing at the "
            "backend log). The candidate is UNJUDGED — this is not an "
            "EXACT_ONLY result and must not be reported as one."
        )
        return result

    if exact_reuse is None:
        result["outcome"] = "HARNESS_FAILURE"
        result["detail"] = (
            "exact-replay reuse was never MEASURED, so a changed-prefix "
            "figure has no baseline to be compared against. The candidate "
            "is UNJUDGED."
        )
        return result

    if changed_reuse < CHANGED_PREFIX_MIN_REUSE:
        result["outcome"] = "EXACT_ONLY"
        result["detail"] = (
            "exact replay reused the cache but the CHANGED prefix did not "
            f"(measured {changed_reuse}%, need >= "
            f"{CHANGED_PREFIX_MIN_REUSE}%). This is the Qwen3.6 shape: a "
            "hybrid non-trimmable cache reports a large shared prefix and "
            "still recomputes the whole prompt. A live session grows its "
            "prefix every turn, so this candidate cannot serve one."
        )
        return result

    result["outcome"] = (
        "MODEL_PASS_WITH_ADAPTER" if adapter_used else "DIRECT_PASS"
    )
    return result


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
    # An HTTP failure is a RUNTIME fault, never a contract violation. Measured
    # 2026-09-10: a Metal out-of-memory mid-suite returned 500 and the run was
    # reported as CONTRACT_FAIL, i.e. the MODEL was blamed for the machine
    # running out of GPU memory. Same family as the unmeasured-vs-failed bug.
    http_failures: list[dict[str, Any]] = []

    for index in range(warm_runs):
        warm = helper.replay_fixture(
            fixture_path=fixture,
            backend_url=backend_url,
            timeout=timeout,
            server_log=server_log,
        )
        runs.append(describe_run(f"warm_{index + 1}", warm))

        status = warm.get("http_status")

        if not (isinstance(status, int) and 200 <= status < 300):
            http_failures.append(
                {"run": f"warm_{index + 1}", "http_status": status}
            )
            continue

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
        "http_failures": http_failures,
    }

    # Runtime faults are adjudicated FIRST: a 500 makes every later tally
    # meaningless, and reporting a contract or cache verdict on top of it would
    # attribute an environment failure to the candidate.
    if http_failures:
        summary["outcome"] = "RUNTIME_OR_CONTEXT_FAIL"
        summary["detail"] = (
            f"the backend returned an HTTP failure on {len(http_failures)} "
            f"run(s): {http_failures}. This is a RUNTIME fault (e.g. a Metal "
            "out-of-memory under pressure), not a model verdict — the "
            "candidate is not judged on it. Re-run with more headroom."
        )
        return summary

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

    proves: list[str] = []
    does_not_prove = [
        "verdict quality across safe/ambiguous/dangerous actions",
        "cache persistence across backend restarts",
        "coexistence with the CSL-selected main model",
        "concurrency and memory-pressure behaviour",
        "a real Claude Code Auto Mode session",
        "adapter correctness for other traffic to the same backend",
    ]

    if stage1:
        stage1_outcome = stage1.get("outcome")
        stage1_runs = stage1.get("runs") or []
        successful_runs = [
            run
            for run in stage1_runs
            if isinstance(run.get("http_status"), int)
            and 200 <= run["http_status"] < 300
        ]

        if (
            successful_runs
            and stage1_outcome != "CONTRACT_FAIL"
            and all(run.get("contract_valid") for run in successful_runs)
        ):
            proves.append(
                "Stage-1 response contract held on every successful run"
            )

        if stage1.get("exact_reuse_percent") is not None:
            proves.append("Stage-1 exact-prefix cache reuse was measured")

        changed_reuse = stage1.get("changed_reuse_percent")
        changed_was_run = any(
            run.get("label") == "changed_B" for run in stage1_runs
        )

        if changed_was_run and changed_reuse is not None:
            proves.append("Stage-1 changed-prefix cache reuse was measured")

            if changed_reuse >= CHANGED_PREFIX_MIN_REUSE:
                proves.append(
                    "Stage-1 changed-prefix reuse met the configured threshold"
                )

        changed_source = stage1.get("changed_request_source")

        if changed_source == "genuine_fixture_b" and changed_was_run:
            proves.append(
                "Stage-1 changed-prefix evidence used captured fixture B"
            )
        elif changed_source == "synthetic_tail_growth":
            does_not_prove.append(
                "genuine Stage-1 A/B behavior; changed B was synthesized by "
                "tail growth"
            )

    if stage2:
        stage2_outcome = stage2.get("outcome")
        contract_required = stage2.get("contract_required")
        contract_passes = stage2.get("contract_passes")
        warm_required = stage2.get("warm_reuse_required")
        warm_passes = stage2.get("warm_reuse_passes")
        warm_unmeasured = stage2.get("warm_reuse_unmeasured")

        if (
            isinstance(contract_required, int)
            and contract_required > 0
            and contract_passes == contract_required
        ):
            proves.append(
                "Stage-2 response contract held on every required run"
            )

        if (
            isinstance(warm_required, int)
            and warm_required > 0
            and warm_unmeasured == 0
        ):
            proves.append("Stage-2 warm cache reuse was measured")

            if warm_passes == warm_required:
                proves.append(
                    "Stage-2 warm cache reuse met the configured threshold"
                )

        if stage2_outcome == "DIRECT_PASS":
            proves.append(
                "Stage-2 warm latency stayed inside the classifier deadline"
            )

    return {
        "schema_version": SCHEMA_VERSION,
        "framework_version": FRAMEWORK_VERSION,
        "candidate": candidate,
        "stage1": stage1,
        "stage2": stage2,
        "outcome": overall,
        "outcome_meaning": OUTCOME_MEANING[overall],
        "proves": proves,
        "does_not_prove": does_not_prove,
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

        if key == "stage1" and stage.get("changed_request_source"):
            lines.append(
                "  changed_request_source: "
                f"{stage['changed_request_source']}"
            )

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
    lines.append("proves:")

    if report["proves"]:
        lines.extend(f"  - {item}" for item in report["proves"])
    else:
        lines.append("  (none)")

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
        help="genuine Stage-1 captured request fixture A",
    )
    parser.add_argument(
        "--stage1-fixture-b",
        type=Path,
        help="genuine changed Stage-1 captured request fixture B",
    )
    parser.add_argument(
        "--stage1-synthetic-b",
        action="store_true",
        help=(
            "explicitly synthesize changed B by growing fixture A at the tail"
        ),
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

    if args.stage1_fixture:
        if bool(args.stage1_fixture_b) == bool(args.stage1_synthetic_b):
            parser.error(
                "Stage 1 requires exactly one of --stage1-fixture-b / "
                "--stage1-synthetic-b"
            )
    elif args.stage1_fixture_b or args.stage1_synthetic_b:
        parser.error(
            "--stage1-fixture-b / --stage1-synthetic-b require "
            "--stage1-fixture"
        )

    if args.warm_runs < 1:
        parser.error("--warm-runs must be at least 1")

    repo = Path(__file__).resolve().parent.parent

    try:
        helper = load_prewarm_helper(repo)

        if args.stage1_fixture:
            validate_fixture_stage(helper, args.stage1_fixture, 1)

            if args.stage1_fixture_b:
                validate_fixture_stage(helper, args.stage1_fixture_b, 1)
                fixture_a_sha256 = fixture_body_sha256(
                    helper,
                    args.stage1_fixture,
                )
                fixture_b_sha256 = fixture_body_sha256(
                    helper,
                    args.stage1_fixture_b,
                )

                if fixture_a_sha256 == fixture_b_sha256:
                    raise RuntimeError(
                        "Stage-1 fixture B must differ from fixture A"
                    )

        if args.stage2_fixture:
            validate_fixture_stage(helper, args.stage2_fixture, 2)
    except Exception as exc:
        report = build_report(
            candidate=args.candidate,
            stage1=None,
            stage2=None,
        )
        report["outcome"] = "HARNESS_FAILURE"
        report["outcome_meaning"] = OUTCOME_MEANING["HARNESS_FAILURE"]
        report["harness_error"] = str(exc)
        print(render_text(report))

        if args.json and "helper" in locals():
            helper.atomic_private_json(args.json, report)

        return 3

    scratch = Path(tempfile.mkdtemp(prefix="classifier-qualify-"))
    stage1 = stage2 = None

    try:
        if args.stage1_fixture:
            stage1 = run_stage1(
                helper,
                fixture=args.stage1_fixture,
                fixture_b=args.stage1_fixture_b,
                synthetic_b=args.stage1_synthetic_b,
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
