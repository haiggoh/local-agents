#!/usr/bin/env bash
# oMLX Auto Mode readiness gate.
#
# Sourced by launch-claude-agent-omlx.sh after config-lib.sh and
# omlx-progress.sh. It owns:
# - fixture fingerprint and refresh policy;
# - main-session engine warmup;
# - genuine classifier request capture;
# - detached cold replay;
# - genuine follow-up request verification;
# - exact-fixture fast verification on ordinary launches;
# - reactive invalidation after a classifier failure.

la_prewarm_require_uint() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*)
            printf 'ERROR: %s must be a non-negative integer\n' \
                "$name" >&2
            return 2
            ;;
    esac
}

la_prewarm_require_number() {
    local name="$1"
    local value="$2"

    python3 - "$name" "$value" <<'PY_NUMBER'
import sys

name, value = sys.argv[1:3]

try:
    parsed = float(value)
except ValueError:
    print(f"ERROR: {name} must be numeric", file=sys.stderr)
    raise SystemExit(2)

if parsed < 0:
    print(f"ERROR: {name} must be non-negative", file=sys.stderr)
    raise SystemExit(2)
PY_NUMBER
}

la_prewarm_private_file() {
    local path="$1"

    : >"$path"
    chmod 600 "$path"
}

la_prewarm_metrics() {
    python3 - "$1" <<'PY_METRICS'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

values = (
    data.get("prompt_tokens"),
    data.get("cached_tokens"),
    data.get("elapsed_seconds"),
)

print(
    "\t".join(
        "" if value is None else str(value)
        for value in values
    )
)
PY_METRICS
}

la_prewarm_cache_growth() {
    python3 - "$1" <<'PY_GROWTH'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

before = data.get("cache_dir_bytes_before")
after = data.get("cache_dir_bytes_after")
delta = data.get("cache_dir_bytes_delta")


def display(value):
    if value is None:
        return "unavailable"
    return f"{value / (1024 ** 3):.3f} GiB"


print(
    "\t".join(
        (
            display(before),
            display(after),
            display(delta),
        )
    )
)
PY_GROWTH
}

la_omlx_prewarm_prepare() {
    : "${LA_OMLX_AUTO_PREWARM:=1}"
    : "${LA_OMLX_PREWARM_FIXTURE_ROOT:=$HOME/.cache/local-agents/omlx-auto-fixtures}"
    : "${LA_OMLX_PREWARM_MAX_AGE_DAYS:=7}"
    : "${LA_OMLX_PREWARM_REFRESH_EVERY:=0}"
    : "${LA_OMLX_PREWARM_CAPTURE_TIMEOUT_S:=900}"
    : "${LA_OMLX_PREWARM_COLD_TIMEOUT_S:=600}"
    : "${LA_OMLX_PREWARM_VERIFY_TIMEOUT_S:=45}"
    : "${LA_OMLX_SESSION_WARM_TIMEOUT_S:=600}"
    : "${LA_OMLX_PREWARM_MIN_PROMPT_TOKENS:=10000}"
    : "${LA_OMLX_PREWARM_MIN_CACHED_TOKENS:=8000}"
    : "${LA_OMLX_PREWARM_MIN_REUSE_PERCENT:=70}"
    : "${LA_OMLX_PREWARM_PROGRESS_INTERVAL_S:=15}"

    [ "$LA_OMLX_AUTO_PREWARM" = 1 ] || {
        printf '%s\n' \
            "ERROR: oMLX Auto Mode requires classifier readiness verification." \
            "       Turn Auto Mode off instead of bypassing its safety gate." >&2
        return 2
    }

    local name

    for name in \
        LA_OMLX_PREWARM_MAX_AGE_DAYS \
        LA_OMLX_PREWARM_REFRESH_EVERY \
        LA_OMLX_PREWARM_CAPTURE_TIMEOUT_S \
        LA_OMLX_PREWARM_COLD_TIMEOUT_S \
        LA_OMLX_PREWARM_VERIFY_TIMEOUT_S \
        LA_OMLX_SESSION_WARM_TIMEOUT_S \
        LA_OMLX_PREWARM_MIN_PROMPT_TOKENS \
        LA_OMLX_PREWARM_MIN_CACHED_TOKENS \
        LA_OMLX_PREWARM_PROGRESS_INTERVAL_S
    do
        la_prewarm_require_uint "$name" "${!name}" || return
    done

    la_prewarm_require_number \
        LA_OMLX_PREWARM_MIN_REUSE_PERCENT \
        "$LA_OMLX_PREWARM_MIN_REUSE_PERCENT" || return

    LA_OMLX_PREWARM_HELPER="$LAUNCH_DIR/omlx-auto-prewarm.py"

    [ -x "$LA_OMLX_PREWARM_HELPER" ] || {
        printf 'ERROR: classifier fixture helper missing: %s\n' \
            "$LA_OMLX_PREWARM_HELPER" >&2
        return 2
    }

    LA_OMLX_PREWARM_CLAUDE_BIN="$(
        command -v claude 2>/dev/null || true
    )"

    [ -x "$LA_OMLX_PREWARM_CLAUDE_BIN" ] || {
        printf 'ERROR: Claude Code executable not found\n' >&2
        return 2
    }

    local claude_version
    local omlx_version
    local -a fingerprint_args

    claude_version="$(
        "$LA_OMLX_PREWARM_CLAUDE_BIN" --version |
            head -1
    )"

    omlx_version="$(
        "$LA_OMLX_BIN" --version |
            head -1
    )"

    fingerprint_args=(
        fingerprint
        --claude-bin "$LA_OMLX_PREWARM_CLAUDE_BIN"
        --claude-version "$claude_version"
        --omlx-version "$omlx_version"
        --classifier-dir "$LA_OMLX_CLASSIFIER_MODEL_DIR"
        --classifier-model-id "$LA_OMLX_CLASSIFIER_MODEL_ID"
        --cwd "$PWD"
        --segmented-transcript
        "${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-1}"
        --profile-value "session_alias=$MODEL_ALIAS"
        --profile-value "session_model_id=$SESSION_MODEL_ID"
        --profile-value "effort=$EFFORT"
        --profile-value "tools=${LA_CLAUDE_TOOLS:-default}"
        --profile-value "deny=${LA_DENY_TOOLS:-}"
        --profile-value "autocompact=${LA_AUTO_COMPACT_WINDOW:-}"
        --profile-value "strict_mcp=${LA_STRICT_MCP:-true}"
    )

    if [ -n "${LA_CLAUDE_SETTINGS:-}" ]; then
        fingerprint_args+=(
            --profile-file "$LA_CLAUDE_SETTINGS"
        )
    fi

    LA_OMLX_PREWARM_FINGERPRINT="$(
        "$LA_OMLX_PREWARM_HELPER" \
            "${fingerprint_args[@]}"
    )"

    case "$LA_OMLX_PREWARM_FINGERPRINT" in
        ''|*[!0-9a-f]*)
            printf '%s\n' \
                "ERROR: invalid classifier fixture fingerprint" >&2
            return 2
            ;;
    esac

    LA_OMLX_PREWARM_FIXTURE_DIR="$LA_OMLX_PREWARM_FIXTURE_ROOT/$LA_OMLX_PREWARM_FINGERPRINT"
    LA_OMLX_PREWARM_SHARED_CACHE_DIR="$LA_OMLX_SHARED_CACHE_DIR"

    mkdir -p \
        "$LA_OMLX_PREWARM_FIXTURE_ROOT" \
        "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        "$LA_OMLX_PREWARM_SHARED_CACHE_DIR"

    chmod 700 \
        "$LA_OMLX_PREWARM_FIXTURE_ROOT" \
        "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        "$LA_OMLX_PREWARM_SHARED_CACHE_DIR"
}

la_omlx_prewarm_mark_unhealthy() {
    local failure_kind="$1"

    "$LA_OMLX_PREWARM_HELPER" mark-unhealthy \
        --fixture-dir "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        --failure-kind "$failure_kind" \
        >/dev/null 2>&1 || true
}

la_omlx_warm_session_model() {
    local backend_url="$1"

    # Assigned by launch-claude-agent-omlx.sh before this sourced function runs.
    # shellcheck disable=SC2154
    local request_file="$runtime_root/session-warm-request.json"
    local response_file="$runtime_root/session-warm-response.json"
    local status_file="$runtime_root/session-warm-status.txt"
    local error_file="$runtime_root/session-warm-error.txt"

    python3 - "$SESSION_MODEL_ID" "$request_file" <<'PY_REQUEST'
import json
import os
import sys
import tempfile
from pathlib import Path

model, output = sys.argv[1:3]
path = Path(output)

payload = {
    "model": model,
    "system": "Local engine readiness probe.",
    "messages": [
        {
            "role": "user",
            "content": "Reply briefly.",
        }
    ],
    "max_tokens": 1,
    "temperature": 0,
    "stream": False,
}

descriptor, temporary = tempfile.mkstemp(
    prefix=path.name + ".",
    suffix=".tmp",
    dir=str(path.parent),
)

try:
    with os.fdopen(
        descriptor,
        "w",
        encoding="utf-8",
        newline="",
    ) as handle:
        json.dump(payload, handle)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())

    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY_REQUEST

    la_prewarm_private_file "$response_file"
    la_prewarm_private_file "$status_file"
    la_prewarm_private_file "$error_file"

    if ! la_progress_run \
        "Loading $SESSION_MODEL_ID session engine" \
        "$status_file" \
        "$error_file" \
        curl \
        -sS \
        --max-time "$LA_OMLX_SESSION_WARM_TIMEOUT_S" \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --request POST \
        --header 'Content-Type: application/json' \
        --header 'Anthropic-Version: 2023-06-01' \
        --data-binary "@$request_file" \
        "$backend_url/v1/messages"
    then
        # Assigned by launch-claude-agent-omlx.sh before this function runs.
        # shellcheck disable=SC2154
        printf '%s\n' \
            "ERROR: session-model warmup failed" \
            "       Log: $server_log" >&2
        return 1
    fi

    local status
    status="$(cat "$status_file")"

    [ "$status" = 200 ] || {
        printf 'ERROR: session-model warmup returned HTTP %s\n' \
            "${status:-unknown}" >&2
        return 1
    }

    python3 - "$response_file" <<'PY_RESPONSE'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

if payload.get("type") != "message":
    raise SystemExit("session warmup did not return an Anthropic message")
PY_RESPONSE

    rm -f \
        "$request_file" \
        "$response_file" \
        "$status_file" \
        "$error_file"
}

la_omlx_verify_fixture() {
    local backend_url="$1"
    local fixture="$2"
    local result="$3"
    local label="$4"
    local stdout_file="$runtime_root/prewarm-verify.stdout"
    local stderr_file="$runtime_root/prewarm-verify.stderr"

    LA_OMLX_PREWARM_LAST_PROMPT=0
    LA_OMLX_PREWARM_LAST_CACHED=0
    LA_OMLX_PREWARM_LAST_ELAPSED=0

    if ! la_progress_run \
        "$label" \
        "$stdout_file" \
        "$stderr_file" \
        "$LA_OMLX_PREWARM_HELPER" replay \
        --fixture "$fixture" \
        --backend-url "$backend_url" \
        --timeout "$LA_OMLX_PREWARM_VERIFY_TIMEOUT_S" \
        --server-log "$server_log" \
        --output "$result" \
        --min-prompt-tokens "$LA_OMLX_PREWARM_MIN_PROMPT_TOKENS" \
        --min-cached-tokens "$LA_OMLX_PREWARM_MIN_CACHED_TOKENS" \
        --min-reuse-percent "$LA_OMLX_PREWARM_MIN_REUSE_PERCENT" \
        --max-elapsed-seconds "$LA_OMLX_PREWARM_VERIFY_TIMEOUT_S"
    then
        return 1
    fi

    IFS=$'\t' read -r \
        LA_OMLX_PREWARM_LAST_PROMPT \
        LA_OMLX_PREWARM_LAST_CACHED \
        LA_OMLX_PREWARM_LAST_ELAPSED < <(
            la_prewarm_metrics "$result"
        )

    printf '   classifier cache: %s/%s tokens reused in %ss\n' \
        "${LA_OMLX_PREWARM_LAST_CACHED:-?}" \
        "${LA_OMLX_PREWARM_LAST_PROMPT:-?}" \
        "${LA_OMLX_PREWARM_LAST_ELAPSED:-?}" >&2
}

la_omlx_fast_verify() {
    local backend_url="$1"
    local fixture="$LA_OMLX_PREWARM_FIXTURE_DIR/classifier-request.json"
    local result="$LA_OMLX_PREWARM_FIXTURE_DIR/last-fast-verification.json"

    la_omlx_verify_fixture \
        "$backend_url" \
        "$fixture" \
        "$result" \
        "Verifying persisted classifier prefix" || return

    "$LA_OMLX_PREWARM_HELPER" mark-verified \
        --fixture-dir "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        --fingerprint "$LA_OMLX_PREWARM_FINGERPRINT" \
        --prompt-tokens "${LA_OMLX_PREWARM_LAST_PROMPT:-0}" \
        --cached-tokens "${LA_OMLX_PREWARM_LAST_CACHED:-0}" \
        --elapsed-seconds "${LA_OMLX_PREWARM_LAST_ELAPSED:-0}" \
        >/dev/null
}

la_omlx_capture_genuine() {
    local backend_url="$1"
    local fixture="$2"
    local capture_state="$3"
    local probe_log="$4"
    local probe_target="$5"
    local marker="$6"
    local label="$7"

    local capture_stdout="$runtime_root/prewarm-capture.stdout"
    local capture_stderr="$runtime_root/prewarm-capture.stderr"
    local target_quoted

    rm -f \
        "$fixture" \
        "$capture_state" \
        "$probe_log" \
        "$probe_target"

    printf -v target_quoted '%q' "$probe_target"

    local probe_prompt
    probe_prompt="In LOCAL Auto Mode, use Bash to run exactly this command and report its output: printf '${marker}\\n' > ${target_quoted} && cat ${target_quoted}. Do not substitute another tool or path."

    local -a probe_command

    probe_command=(
        "$LA_OMLX_PREWARM_CLAUDE_BIN"
        --model "$SESSION_MODEL_ID"
        --effort "$EFFORT"
        --permission-mode auto
        --strict-mcp-config
        --print
        --output-format json
        --no-session-persistence
        --append-system-prompt
        "LOCAL oMLX Auto Mode classifier fixture refresh."
    )

    if [ -n "${LA_CLAUDE_SETTINGS:-}" ]; then
        probe_command+=(
            --settings "$LA_CLAUDE_SETTINGS"
        )
    fi

    if [ -n "${LA_CLAUDE_TOOLS:-}" ]; then
        probe_command+=(
            --tools "$LA_CLAUDE_TOOLS"
        )
    fi

    if [ -n "${LA_DENY_TOOLS:-}" ]; then
        probe_command+=(
            --disallowedTools "$LA_DENY_TOOLS"
        )
    fi

    probe_command+=("$probe_prompt")

    la_progress_run \
        "$label" \
        "$capture_stdout" \
        "$capture_stderr" \
        "$LA_OMLX_PREWARM_HELPER" capture-run \
        --backend-url "$backend_url" \
        --fixture "$fixture" \
        --ready-file "$capture_state" \
        --probe-log "$probe_log" \
        --cwd "$PWD" \
        --classifier-model-id "$LA_OMLX_CLASSIFIER_MODEL_ID" \
        --timeout "$LA_OMLX_PREWARM_CAPTURE_TIMEOUT_S" \
        --env 'CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1' \
        --env 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' \
        --env 'DISABLE_TELEMETRY=1' \
        --env 'DISABLE_ERROR_REPORTING=1' \
        --env 'DISABLE_AUTOUPDATER=1' \
        --env "API_TIMEOUT_MS=${LA_API_TIMEOUT_MS:-1800000}" \
        --env 'API_FORCE_IDLE_TIMEOUT=0' \
        --env 'CLAUDE_ENABLE_STREAM_WATCHDOG=0' \
        -- \
        "${probe_command[@]}"
}

la_omlx_full_refresh() {
    local backend_url="$1"

    local fixture_a="$LA_OMLX_PREWARM_FIXTURE_DIR/classifier-request.json"
    local state_a="$LA_OMLX_PREWARM_FIXTURE_DIR/capture-a.json"
    local log_a="$LA_OMLX_PREWARM_FIXTURE_DIR/probe-a.log"
    local target_a="$LA_OMLX_PREWARM_FIXTURE_DIR/probe-a.txt"

    local fixture_b="$LA_OMLX_PREWARM_FIXTURE_DIR/verification-request.json"
    local state_b="$LA_OMLX_PREWARM_FIXTURE_DIR/capture-b.json"
    local log_b="$LA_OMLX_PREWARM_FIXTURE_DIR/probe-b.log"
    local target_b="$LA_OMLX_PREWARM_FIXTURE_DIR/probe-b.txt"

    local cold_result="$LA_OMLX_PREWARM_FIXTURE_DIR/last-cold-replay.json"
    local verify_result="$LA_OMLX_PREWARM_FIXTURE_DIR/last-genuine-verification.json"
    local cold_stdout="$runtime_root/prewarm-cold.stdout"
    local cold_stderr="$runtime_root/prewarm-cold.stderr"

    la_omlx_capture_genuine \
        "$backend_url" \
        "$fixture_a" \
        "$state_a" \
        "$log_a" \
        "$target_a" \
        "local-auto-prewarm-a" \
        "Capturing genuine Auto Mode classifier request" || {
            la_omlx_prewarm_mark_unhealthy capture_a_failed
            return 1
        }

    if ! la_progress_run \
        "Loading classifier model and completing detached prefill" \
        "$cold_stdout" \
        "$cold_stderr" \
        "$LA_OMLX_PREWARM_HELPER" replay \
        --fixture "$fixture_a" \
        --backend-url "$backend_url" \
        --timeout "$LA_OMLX_PREWARM_COLD_TIMEOUT_S" \
        --server-log "$server_log" \
        --cache-dir "$LA_OMLX_PREWARM_SHARED_CACHE_DIR" \
        --cache-settle-timeout 10 \
        --output "$cold_result"
    then
        la_omlx_prewarm_mark_unhealthy cold_replay_failed
        return 1
    fi

    local cache_before cache_after cache_delta

    IFS=$'\t' read -r \
        cache_before \
        cache_after \
        cache_delta < <(
            la_prewarm_cache_growth "$cold_result"
        )

    printf '%s\n' \
        "   shared cache before classifier replay: ${cache_before:-?}" \
        "   shared cache after classifier replay:  ${cache_after:-?}" \
        "   net change during classifier replay:   ${cache_delta:-?}" >&2

    la_omlx_capture_genuine \
        "$backend_url" \
        "$fixture_b" \
        "$state_b" \
        "$log_b" \
        "$target_b" \
        "local-auto-prewarm-b" \
        "Capturing second genuine classifier request" || {
            la_omlx_prewarm_mark_unhealthy capture_b_failed
            return 1
        }

    la_omlx_verify_fixture \
        "$backend_url" \
        "$fixture_b" \
        "$verify_result" \
        "Verifying genuine follow-up request and cache reuse" || {
            la_omlx_prewarm_mark_unhealthy genuine_verification_failed
            return 1
        }

    "$LA_OMLX_PREWARM_HELPER" mark-ready \
        --fixture-dir "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        --fingerprint "$LA_OMLX_PREWARM_FINGERPRINT" \
        --launch-count 0 \
        >/dev/null

    "$LA_OMLX_PREWARM_HELPER" mark-verified \
        --fixture-dir "$LA_OMLX_PREWARM_FIXTURE_DIR" \
        --fingerprint "$LA_OMLX_PREWARM_FINGERPRINT" \
        --prompt-tokens "${LA_OMLX_PREWARM_LAST_PROMPT:-0}" \
        --cached-tokens "${LA_OMLX_PREWARM_LAST_CACHED:-0}" \
        --elapsed-seconds "${LA_OMLX_PREWARM_LAST_ELAPSED:-0}" \
        >/dev/null

    rm -f \
        "$state_a" \
        "$state_b" \
        "$log_a" \
        "$log_b" \
        "$target_a" \
        "$target_b" \
        "$fixture_b"
}

la_omlx_readiness_gate() {
    local backend_url="$1"
    local decision

    decision="$(
        "$LA_OMLX_PREWARM_HELPER" decision \
            --fixture-dir "$LA_OMLX_PREWARM_FIXTURE_DIR" \
            --fingerprint "$LA_OMLX_PREWARM_FINGERPRINT" \
            --max-age-days "$LA_OMLX_PREWARM_MAX_AGE_DAYS" \
            --refresh-every "$LA_OMLX_PREWARM_REFRESH_EVERY"
    )"

    if [[ "$decision" == *'"action": "verify"'* ]]; then
        if la_omlx_fast_verify "$backend_url"; then
            return 0
        fi

        la_omlx_prewarm_mark_unhealthy fast_verification_failed

        printf '%s\n' \
            "Cached classifier verification failed; performing a genuine refresh." >&2
    else
        printf '%s\n' \
            "Classifier fixture refresh required: new, changed, expired, or unhealthy." >&2
    fi

    la_omlx_full_refresh "$backend_url"
}

la_omlx_record_session_health() {
    local log_path="$1"
    local start_offset="$2"
    local recent="$runtime_root/post-session-classifier.log"

    [ -f "$log_path" ] || return 0

    tail -c "+$((start_offset + 1))" \
        "$log_path" \
        >"$recent" 2>/dev/null || true

    if grep -q 'claude-sonnet-5' "$recent" &&
       grep -Eq \
           'cancelled, aborting|Prefill interrupted|classifier.*(error|failed|timeout)' \
           "$recent"
    then
        la_omlx_prewarm_mark_unhealthy recent_classifier_failure

        printf '%s\n' \
            "⚠️  A classifier failure was detected during this session." \
            "    The next Auto Mode launch will refresh its genuine fixture." >&2
    fi
}
