#!/usr/bin/env bash
# launch-claude-agent-rapid-auto.sh — local Claude Code Auto Mode via Rapid-MLX.
#
# What IS proven: the native dual-identity route. One Rapid process accepts both
# compatibility identities. Mechanically: a TEMPORARY SYMLINK named
# "claude-sonnet-5" points at the real model directory and Rapid is served from
# that parent, so the relative model path IS the classifier identity, while
# --served-model-name exposes "claude-opus-5". No proxy and no persistent user
# alias is involved (a persistent alias was tried and rejected — it resolves to
# a HuggingFace repo ID, not the local path). Claude Code needs a separate
# logical classifier IDENTITY, not separate weights or a second process.
#
# Consequence worth knowing when debugging: /v1/models advertises ONLY the Opus
# identity, and a response to a Sonnet-addressed request reports
# model='claude-opus-5'. That is expected, not a misroute.
#
# What is NOT proven, and why this launcher is not the default route:
# Qwen3.6 below is the model the dual-identity route was DEMONSTRATED on, not a
# qualified classifier. It FAILED the production-critical changed-prefix reuse
# gate: its hybrid cache reports non_trimmable=True, so Rapid refuses the cache
# entry even at a 98.84% shared prefix (37,132 of 37,569 tokens) and recomputes
# the whole prompt (~32.9s). Exact-request reuse is excellent; growing-prefix
# reuse is unavailable. A live Auto Mode session grows its prefix every turn, so
# that is the case that matters.
#
# Devstral Small 2 24B is the current leading candidate — dense/non-hybrid, so it
# genuinely trims (98.86% reuse, LCP 37,808, 436 tokens re-prefilled), and it
# passed genuine Stage 2 at 5/5 contract with 100% warm reuse under the 45s
# deadline. It needs a Stage-1 adjacent-user-role adapter (Mistral alternation),
# whose production correctness across other Mistral traffic is unproven.
#
# So the model pin below is deliberately NOT called qualified, and repointing it
# is expected work — see tests/test_rapid_auto_mode.sh for the guards that keep
# this route opt-in until a real end-to-end smoke test passes.
set -euo pipefail
umask 077

_s="${BASH_SOURCE[0]}"
while [ -h "$_s" ]; do
    _d="$(cd -P "$(dirname "$_s")" && pwd)"
    _s="$(readlink "$_s")"
    case "$_s" in
        /*) ;;
        *) _s="$_d/$_s" ;;
    esac
done

LAUNCH_DIR="$(cd -P "$(dirname "$_s")" && pwd)"

if [ "${1:-}" = "--self-test" ]; then
    printf '%s\n' "RAPID_AUTO_LAUNCHER_SELF_TEST_OK"
    exit 0
fi

# shellcheck source=/dev/null
. "$LAUNCH_DIR/../config/config-lib.sh"
la_load_config || exit 1
# shellcheck source=/dev/null
. "$LAUNCH_DIR/omlx-progress.sh"
# Historical function names remain for compatibility; the gate is shared at
# the request, fixture, replay, and readiness layers.
# shellcheck source=/dev/null
. "$LAUNCH_DIR/omlx-auto-prewarm-gate.sh"

MODEL_ALIAS="${1:-}"
EFFORT_OVERRIDE="${2:-}"

: "${LA_AGENT_PROMPT_FILE:=$LAUNCH_DIR/../config/local-agent-system-prompt.txt}"
: "${LA_CLAUDE_SETTINGS:=}"
: "${LA_CLAUDE_TOOLS:=}"
: "${LA_DENY_TOOLS:=}"
: "${LA_MCP_CONFIG:=}"
: "${LA_AUTO_COMPACT_WINDOW:=}"

[ -f "$LA_AGENT_PROMPT_FILE" ] || {
    echo "ERROR: local agent prompt is unavailable: $LA_AGENT_PROMPT_FILE" >&2
    exit 2
}

if [ -z "$MODEL_ALIAS" ] || ! la_lookup "$MODEL_ALIAS"; then
    echo "Usage: $0 <alias> [effort-override]" >&2
    exit 2
fi

la_configure_auto_mode_env 1 || exit 2

selected_model_dir="$(
    cd -P "$LA_CUR_DIR" 2>/dev/null &&
        /bin/pwd -P || true
)"
SESSION_MODEL_ID="${LA_CUR_SPOOF%%,*}"
EFFORT="${EFFORT_OVERRIDE:-$LA_CUR_EFFORT}"

: "${LA_RAPID_AUTO_BIN:=$HOME/.venvs/rapid-mlx-0.13.4/bin/rapid-mlx}"
: "${LA_RAPID_AUTO_MODEL_DIR:=$HOME/.models/Qwen3.6-35B-A3B-4bit}"
: "${LA_RAPID_AUTO_CLASSIFIER_MODEL_ID:=claude-sonnet-5}"
: "${LA_RAPID_AUTO_PORT:=8002}"
: "${LA_RAPID_AUTO_CACHE_ROOT:=$HOME/.cache/local-agents/rapid-auto}"
: "${LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT:=$HOME/.cache/local-agents/rapid-auto-fixtures}"
: "${LA_RAPID_AUTO_CACHE_MEMORY_MB:=16384}"
: "${LA_RAPID_AUTO_HYBRID_CACHE_ENTRIES:=8}"
: "${LA_RAPID_AUTO_RESIDENT_MEMORY_LIMIT_GB:=32}"
: "${LA_RAPID_AUTO_KEEP_RUNTIME_VIEW:=0}"
: "${LA_RAPID_AUTO_DRY_RUN:=0}"

[ -x "$LA_RAPID_AUTO_BIN" ] || {
    echo "ERROR: pinned Rapid-MLX executable missing: $LA_RAPID_AUTO_BIN" >&2
    exit 2
}

rapid_auto_version="$("$LA_RAPID_AUTO_BIN" --version 2>/dev/null || true)"
[ "$rapid_auto_version" = "rapid-mlx 0.13.4" ] || {
    printf 'ERROR: Rapid Auto Mode requires rapid-mlx 0.13.4, got %s\n' \
        "${rapid_auto_version:-<unavailable>}" >&2
    exit 2
}

[ -n "$selected_model_dir" ] && [ -f "$selected_model_dir/config.json" ] || {
    echo "ERROR: selected model is unavailable: $LA_CUR_DIR" >&2
    exit 2
}

rapid_auto_model_dir="$(
    cd -P "$LA_RAPID_AUTO_MODEL_DIR" 2>/dev/null &&
        /bin/pwd -P || true
)"

[ ! -L "$LA_RAPID_AUTO_MODEL_DIR" ] || {
    echo "ERROR: Rapid Auto Mode model directory must not be a symlink" >&2
    exit 2
}

[ -n "$rapid_auto_model_dir" ] && [ -f "$rapid_auto_model_dir/config.json" ] || {
    echo "ERROR: pinned Rapid Auto Mode model is unavailable: $LA_RAPID_AUTO_MODEL_DIR" >&2
    exit 2
}

if [ "$selected_model_dir" != "$rapid_auto_model_dir" ]; then
    printf '%s\n' \
        "ERROR: Rapid Auto Mode currently supports only its single pinned model." \
        "       (pinned for the dual-identity demonstration; NOT a qualified" \
        "        classifier — it fails changed-prefix reuse.)" \
        "       selected: $selected_model_dir" \
        "       pinned:   $rapid_auto_model_dir" >&2
    exit 2
fi

if [ "$LA_CUR_THINK" != false ]; then
    echo "ERROR: Rapid Auto Mode requires a non-thinking session alias" >&2
    exit 2
fi

if [ "$SESSION_MODEL_ID" != "claude-opus-5" ]; then
    printf 'ERROR: Rapid Auto Mode requires session ID claude-opus-5, got %s\n' \
        "$SESSION_MODEL_ID" >&2
    exit 2
fi

case "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" in
    ''|.|..|*/*)
        echo "ERROR: unsafe Rapid classifier compatibility ID" >&2
        exit 2
        ;;
esac

if [ "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" != "claude-sonnet-5" ]; then
    printf 'ERROR: Rapid Auto Mode requires classifier ID claude-sonnet-5, got %s\n' \
        "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" >&2
    exit 2
fi

if [ "$SESSION_MODEL_ID" = "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" ]; then
    echo "ERROR: session and classifier model IDs must differ" >&2
    exit 2
fi

for numeric_name in \
    LA_RAPID_AUTO_PORT \
    LA_RAPID_AUTO_CACHE_MEMORY_MB \
    LA_RAPID_AUTO_HYBRID_CACHE_ENTRIES \
    LA_RAPID_AUTO_RESIDENT_MEMORY_LIMIT_GB
do
    numeric_value="${!numeric_name}"
    case "$numeric_value" in
        ''|*[!0-9]*)
            printf 'ERROR: %s must be a non-negative integer\n' "$numeric_name" >&2
            exit 2
            ;;
    esac
done

if [ "$LA_RAPID_AUTO_CACHE_MEMORY_MB" -lt 8000 ]; then
    echo "ERROR: LA_RAPID_AUTO_CACHE_MEMORY_MB must be at least 8000" >&2
    exit 2
fi

if [ "$LA_RAPID_AUTO_HYBRID_CACHE_ENTRIES" -lt 1 ]; then
    echo "ERROR: LA_RAPID_AUTO_HYBRID_CACHE_ENTRIES must be at least 1" >&2
    exit 2
fi

if [ "$LA_RAPID_AUTO_RESIDENT_MEMORY_LIMIT_GB" -lt 32 ]; then
    echo "ERROR: LA_RAPID_AUTO_RESIDENT_MEMORY_LIMIT_GB must be at least 32" >&2
    exit 2
fi

if [ "$LA_RAPID_AUTO_PORT" -lt 1 ] || [ "$LA_RAPID_AUTO_PORT" -gt 65535 ]; then
    echo "ERROR: LA_RAPID_AUTO_PORT must be between 1 and 65535" >&2
    exit 2
fi

case "$LA_RAPID_AUTO_KEEP_RUNTIME_VIEW" in
    0|1) ;;
    *)
        echo "ERROR: LA_RAPID_AUTO_KEEP_RUNTIME_VIEW must be 0 or 1" >&2
        exit 2
        ;;
esac

case "$LA_RAPID_AUTO_DRY_RUN" in
    0|1) ;;
    *)
        echo "ERROR: LA_RAPID_AUTO_DRY_RUN must be 0 or 1" >&2
        exit 2
        ;;
esac

if [ -n "$LA_CLAUDE_SETTINGS" ]; then
    [ -f "$LA_CLAUDE_SETTINGS" ] || {
        echo "ERROR: LA_CLAUDE_SETTINGS is not a file: $LA_CLAUDE_SETTINGS" >&2
        exit 2
    }
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
        "$LA_CLAUDE_SETTINGS" >/dev/null 2>&1 || {
            echo "ERROR: LA_CLAUDE_SETTINGS is not valid JSON" >&2
            exit 2
        }
fi

if [ -n "$LA_CLAUDE_TOOLS" ]; then
    case "$LA_CLAUDE_TOOLS" in
        *[!A-Za-z0-9_,]*|,*|*,|*,,*)
            echo "ERROR: LA_CLAUDE_TOOLS must be a comma-separated built-in tool list" >&2
            exit 2
            ;;
    esac
fi

if [ -n "$LA_MCP_CONFIG" ]; then
    [ -f "$LA_MCP_CONFIG" ] || {
        echo "ERROR: LA_MCP_CONFIG is not a file: $LA_MCP_CONFIG" >&2
        exit 2
    }
fi

if [ -n "$LA_AUTO_COMPACT_WINDOW" ]; then
    python3 -c '
import re,sys
value=sys.argv[1]
valid=value == "auto" or bool(re.fullmatch(r"(?:[1-9][0-9]{2,5}|1000000)", value))
raise SystemExit(0 if valid else 1)
' "$LA_AUTO_COMPACT_WINDOW" || {
        echo "ERROR: LA_AUTO_COMPACT_WINDOW must be auto or 100k-1m tokens" >&2
        exit 2
    }
fi

if [ "$LA_RAPID_AUTO_DRY_RUN" = 1 ]; then
    printf '%s\n' \
        "RAPID_AUTO_DRY_RUN_OK" \
        "session_alias=$MODEL_ALIAS" \
        "model_dir=$selected_model_dir" \
        "session_model_id=$SESSION_MODEL_ID" \
        "classifier_model_id=$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" \
        "classifier_model_argument=$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" \
        "served_model_name=$SESSION_MODEL_ID" \
        "rapid_bin=$LA_RAPID_AUTO_BIN" \
        "port=$LA_RAPID_AUTO_PORT" \
        "cache_root=$LA_RAPID_AUTO_CACHE_ROOT" \
        "fixture_root=$LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT" \
        "segmented=${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-unset}"
    exit 0
fi

if lsof -nP -iTCP:"$LA_RAPID_AUTO_PORT" -sTCP:LISTEN -t \
    >/dev/null 2>&1
then
    echo "ERROR: Rapid Auto Mode port is occupied: $LA_RAPID_AUTO_PORT" >&2
    lsof -nP -iTCP:"$LA_RAPID_AUTO_PORT" -sTCP:LISTEN >&2 || true
    exit 2
fi

existing_model_processes="$(
    python3 <<'PY_MODEL_PROCESSES'
import subprocess

commands = subprocess.check_output(
    ["ps", "-Aww", "-o", "command="],
    text=True,
)
markers = (
    "/rapid-mlx ",
    " rapid-mlx ",
    "/vllm-mlx ",
    " vllm-mlx ",
    "omlx serve",
)
print(
    "\n".join(
        line
        for line in commands.splitlines()
        if any(marker in line for marker in markers)
    )
)
PY_MODEL_PROCESSES
)"

if [ -n "$existing_model_processes" ]; then
    printf '%s\n' \
        "ERROR: another local model server is already running." \
        "$existing_model_processes" >&2
    exit 2
fi

# Configure the shared readiness implementation for Rapid. The fixture and
# cache namespaces are Rapid-specific, and the backend version participates in
# the fingerprint, so oMLX and Rapid readiness evidence cannot be confused.
# The helper itself remains shared; require the request-aware validator and the
# generic Rapid cached= metric before any persistent readiness state is used.
if ! grep -qF '_request_allows_trimmed_closing' \
        "$LAUNCH_DIR/omlx-auto-prewarm.py" ||
   ! grep -qF 'cached[=_ :]+' \
        "$LAUNCH_DIR/omlx-auto-prewarm.py"
then
    echo "ERROR: classifier readiness helper lacks required Rapid support" >&2
    exit 2
fi
# shellcheck disable=SC2034
LA_AUTO_MODE_BACKEND_LABEL="Rapid-MLX"
# shellcheck disable=SC2034
LA_OMLX_BIN="$LA_RAPID_AUTO_BIN"
# shellcheck disable=SC2034
LA_OMLX_CLASSIFIER_MODEL_DIR="$rapid_auto_model_dir"
# shellcheck disable=SC2034
LA_OMLX_CLASSIFIER_MODEL_ID="$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID"
# shellcheck disable=SC2034
LA_OMLX_PREWARM_FIXTURE_ROOT="$LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT"
rapid_home="$LA_RAPID_AUTO_CACHE_ROOT/home"
LA_OMLX_SHARED_CACHE_DIR="$rapid_home/.cache/rapid-mlx"
rapid_persistent_base="$HOME/.cache/local-agents"

validate_rapid_persistent_root() {
    local path="$1"

    python3 - "$rapid_persistent_base" "$path" <<'PY_PERSISTENT_ROOT'
from pathlib import Path
import sys

base = Path(sys.argv[1]).expanduser().resolve(strict=False)
target = Path(sys.argv[2]).expanduser().resolve(strict=False)

if target == base or base not in target.parents:
    raise SystemExit(
        f"ERROR: Rapid Auto Mode persistent root must be a strict descendant of {base}: {target}"
    )
PY_PERSISTENT_ROOT
}

ensure_private_rapid_root() {
    local path="$1"

    validate_rapid_persistent_root "$path" || return 2

    if [ -L "$path" ]; then
        printf 'ERROR: refusing symlinked Rapid Auto Mode root: %s\n' "$path" >&2
        return 2
    fi

    mkdir -p "$path"

    [ -d "$path" ] && [ ! -L "$path" ] || {
        printf 'ERROR: Rapid Auto Mode root is not a directory: %s\n' "$path" >&2
        return 2
    }

    validate_rapid_persistent_root "$path" || return 2
    chmod 700 "$path"
}

mkdir -p "$rapid_persistent_base"
[ -d "$rapid_persistent_base" ] && [ ! -L "$rapid_persistent_base" ] || {
    echo "ERROR: Rapid Auto Mode persistent base is unsafe: $rapid_persistent_base" >&2
    exit 2
}

ensure_private_rapid_root "$LA_RAPID_AUTO_CACHE_ROOT" || exit 2
ensure_private_rapid_root "$rapid_home" || exit 2
ensure_private_rapid_root "$rapid_home/.cache" || exit 2
ensure_private_rapid_root "$LA_OMLX_SHARED_CACHE_DIR" || exit 2
ensure_private_rapid_root "$LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT" || exit 2

la_omlx_prewarm_prepare || exit 2

runtime_root=""
owner_marker=""
rapid_pid=""
cleanup_done=0

stop_rapid() {
    [ -n "$rapid_pid" ] || return 0

    if kill -0 "$rapid_pid" 2>/dev/null; then
        kill "$rapid_pid" 2>/dev/null || true

        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            kill -0 "$rapid_pid" 2>/dev/null || break
            sleep 1
        done

        if kill -0 "$rapid_pid" 2>/dev/null; then
            kill -9 "$rapid_pid" 2>/dev/null || true
        fi
    fi

    wait "$rapid_pid" 2>/dev/null || true
    rapid_pid=""
}

remove_runtime_root() {
    [ -n "$runtime_root" ] || return 0
    [ "$LA_RAPID_AUTO_KEEP_RUNTIME_VIEW" != 1 ] || return 0
    [ -f "$owner_marker" ] && [ ! -L "$owner_marker" ] || return 0
    [ "$(cat "$owner_marker" 2>/dev/null)" = "$runtime_root" ] || return 0

    case "$(basename "$runtime_root")" in
        local-agents-rapid-auto.*) ;;
        *) return 0 ;;
    esac

    [ "$runtime_root" != / ] && [ "$runtime_root" != "$HOME" ] || return 0
    rm -rf -- "$runtime_root"
}

cleanup() {
    [ "$cleanup_done" -eq 0 ] || return 0
    cleanup_done=1
    stop_rapid
    remove_runtime_root
}

on_exit() {
    status=$?
    trap - EXIT INT TERM HUP
    cleanup
    exit "$status"
}

on_signal() {
    exit 130
}

trap on_exit EXIT
trap on_signal INT TERM HUP

runtime_root="$(
    mktemp -d "${TMPDIR:-/tmp}/local-agents-rapid-auto.XXXXXX"
)"
runtime_root="$(cd -P "$runtime_root" && /bin/pwd -P)"
owner_marker="$runtime_root/.local-agents-rapid-auto-owned"
printf '%s\n' "$runtime_root" >"$owner_marker"
chmod 600 "$owner_marker"


serve_root="$runtime_root/serve"
hf_home="$runtime_root/hf"
temp_dir="$runtime_root/tmp"
classifier_view="$serve_root/$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID"
log_dir="$HOME/.claude/logs"
server_log="$log_dir/rapid_auto_${LA_RAPID_AUTO_PORT}.log"

mkdir -p \
    "$serve_root" \
    "$hf_home" \
    "$temp_dir" \
    "$rapid_home/.cache" \
    "$LA_OMLX_SHARED_CACHE_DIR" \
    "$log_dir"
chmod 700 \
    "$runtime_root" \
    "$serve_root" \
    "$hf_home" \
    "$temp_dir" \
    "$rapid_home" \
    "$rapid_home/.cache" \
    "$LA_OMLX_SHARED_CACHE_DIR"

ln -s "$rapid_auto_model_dir" "$classifier_view"

resolved_classifier_view="$(
    cd -P "$classifier_view" &&
        /bin/pwd -P
)"

[ "$resolved_classifier_view" = "$rapid_auto_model_dir" ] || {
    echo "ERROR: Rapid classifier model view resolves unexpectedly" >&2
    exit 2
}

la_progress_init
la_progress_stage "Starting isolated Rapid-MLX Auto Mode server"

: >"$server_log"
chmod 600 "$server_log"

(
    cd "$serve_root"

    exec env \
        HOME="$rapid_home" \
        XDG_CACHE_HOME="$rapid_home/.cache" \
        HF_HOME="$hf_home" \
        TMPDIR="$temp_dir" \
        PYTHONUNBUFFERED=1 \
        RAPID_MLX_TELEMETRY=0 \
        HF_HUB_OFFLINE=1 \
        TRANSFORMERS_OFFLINE=1 \
        "$LA_RAPID_AUTO_BIN" \
            --no-telemetry \
            serve "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" \
            --served-model-name "$SESSION_MODEL_ID" \
            --host 127.0.0.1 \
            --port "$LA_RAPID_AUTO_PORT" \
            --log-level DEBUG \
            --max-num-seqs 2 \
            --max-concurrent-requests 2 \
            --enable-prefix-cache \
            --prefix-cache-index radix \
            --cache-memory-mb "$LA_RAPID_AUTO_CACHE_MEMORY_MB" \
            --hybrid-cache-entries "$LA_RAPID_AUTO_HYBRID_CACHE_ENTRIES" \
            --idle-cache-clear-seconds 0 \
            --response-cache-entries 0 \
            --resident-memory-limit-gb "$LA_RAPID_AUTO_RESIDENT_MEMORY_LIMIT_GB" \
            --timeout "$LA_SERVER_TIMEOUT_S" \
            --no-mllm \
            --no-spec-decode \
            --pflash off \
            --pin-system-prompt \
            --relocate-mid-conversation-system \
            --enable-auto-tool-choice \
            --tool-call-parser qwen3_coder_xml \
            --no-thinking \
            --no-reasoning-parser
) >"$server_log" 2>&1 &
rapid_pid=$!

ready=0
for _ in $(seq 1 180); do
    la_progress_tick "Discovering Rapid session identity"

    if ! kill -0 "$rapid_pid" 2>/dev/null; then
        tail -160 "$server_log" >&2 || true
        echo "ERROR: Rapid Auto Mode server exited during startup" >&2
        exit 1
    fi

    models_json="$(
        curl -sS --max-time 2 \
            "http://127.0.0.1:$LA_RAPID_AUTO_PORT/v1/models" \
            2>/dev/null || true
    )"

    if printf '%s' "$models_json" |
       SESSION_MODEL_ID="$SESSION_MODEL_ID" \
       python3 -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

ids = {row.get("id") for row in payload.get("data", [])}
raise SystemExit(0 if os.environ["SESSION_MODEL_ID"] in ids else 1)
'
    then
        ready=1
        break
    fi

    sleep 2
done

[ "$ready" -eq 1 ] || {
    tail -200 "$server_log" >&2 || true
    echo "ERROR: Rapid did not advertise the session model ID" >&2
    exit 1
}

la_progress_success "Rapid advertised the session model ID"

export ANTHROPIC_BASE_URL="http://127.0.0.1:$LA_RAPID_AUTO_PORT"
export ANTHROPIC_AUTH_TOKEN=local
unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export CLAUDE_IS_LOCAL=true
export CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LA_MAX_OUTPUT_TOKENS"
export API_TIMEOUT_MS="${LA_API_TIMEOUT_MS:-1800000}"
export API_FORCE_IDLE_TIMEOUT=0
export CLAUDE_ENABLE_STREAM_WATCHDOG=0

if ! la_omlx_warm_session_model "$ANTHROPIC_BASE_URL"; then
    printf '%s\n' \
        "ERROR: Rapid session model did not become ready." \
        "       Claude Code was not started." \
        "       Log: $server_log" >&2
    exit 1
fi

classifier_request="$runtime_root/classifier-identity-request.json"
classifier_response="$runtime_root/classifier-identity-response.json"

python3 - "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" \
    "$classifier_request" <<'PY_CLASSIFIER_REQUEST'
import json
import os
import sys

model, destination = sys.argv[1:3]
payload = {
    "model": model,
    "max_tokens": 4,
    "messages": [
        {
            "role": "user",
            "content": "Reply OK.",
        }
    ],
}

fd = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
    0o600,
)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
    handle.write("\n")
PY_CLASSIFIER_REQUEST

classifier_status="$(
    curl -sS \
        --max-time "$LA_OMLX_SESSION_WARM_TIMEOUT_S" \
        --output "$classifier_response" \
        --write-out '%{http_code}' \
        --request POST \
        --header 'Content-Type: application/json' \
        --header 'Anthropic-Version: 2023-06-01' \
        --data-binary "@$classifier_request" \
        "$ANTHROPIC_BASE_URL/v1/messages"
)"

[ "$classifier_status" = 200 ] || {
    printf '%s\n' \
        "ERROR: Rapid rejected the classifier compatibility ID." \
        "       HTTP status: $classifier_status" \
        "       Log: $server_log" >&2
    exit 1
}

python3 - "$classifier_response" <<'PY_CLASSIFIER_RESPONSE'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

if payload.get("type") != "message":
    raise SystemExit(
        "ERROR: classifier identity probe was not an Anthropic message"
    )
PY_CLASSIFIER_RESPONSE

la_progress_success "Rapid accepted both Opus and Sonnet identities"

if ! la_omlx_readiness_gate "$ANTHROPIC_BASE_URL"; then
    printf '%s\n' \
        "ERROR: Local Rapid Auto Mode classifier was not ready." \
        "       Claude Code was not started because fallback would be unsafe." \
        "       Log: $server_log" >&2
    exit 1
fi

la_progress_success "Local Rapid Auto Mode ready — opening Claude Code"

AGENT_PROMPT=$(cat "$LA_AGENT_PROMPT_FILE")
AGENT_PROMPT=${AGENT_PROMPT//__LA_MODEL_ALIAS__/$MODEL_ALIAS}
AGENT_PROMPT=${AGENT_PROMPT//__LA_MODEL_SPOOF__/$SESSION_MODEL_ID}
AGENT_PROMPT=${AGENT_PROMPT//__LA_BACKEND__/rapid}
AGENT_PROMPT=${AGENT_PROMPT//__LA_CURRENT_PORT__/$LA_RAPID_AUTO_PORT}
AGENT_PROMPT=${AGENT_PROMPT//__LA_PORT_START__/$LA_PORT_START}
AGENT_PROMPT=${AGENT_PROMPT//__LA_PORT_MAX__/$LA_PORT_MAX}
AGENT_PROMPT=${AGENT_PROMPT//__LA_HOTSWAP_PATH__/$LAUNCH_DIR\/local-llm-hotswap.sh}

if printf '%s' "$AGENT_PROMPT" | grep -Eq '__LA_[A-Z0-9_]+__'; then
    echo "ERROR: unresolved placeholder in local agent prompt: $LA_AGENT_PROMPT_FILE" >&2
    exit 1
fi

AGENT_PROMPT="$AGENT_PROMPT LOCAL Rapid Auto Mode: classifier=$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID; inference is local."

claude_args=(
    --model "$SESSION_MODEL_ID"
    --effort "$EFFORT"
    --permission-mode auto
    --strict-mcp-config
    --append-system-prompt "$AGENT_PROMPT"
)

if [ -n "${LA_CLAUDE_SETTINGS:-}" ]; then
    claude_args+=(--settings "$LA_CLAUDE_SETTINGS")
fi

if [ -n "${LA_MCP_CONFIG:-}" ]; then
    claude_args+=(--mcp-config "$LA_MCP_CONFIG")
fi

if [ -n "${LA_AUTO_COMPACT_WINDOW:-}" ]; then
    claude_args+=(--autocompact "$LA_AUTO_COMPACT_WINDOW")
fi

if [ -n "${LA_CLAUDE_TOOLS:-}" ]; then
    claude_args+=(--tools "$LA_CLAUDE_TOOLS")
fi

if [ -n "${LA_DENY_TOOLS:-}" ]; then
    claude_args+=(--disallowedTools "$LA_DENY_TOOLS")
fi

printf '%s\n' \
    "⚠️  OPT-IN QUALIFICATION LAUNCHER — not yet wired into the default Auto Mode route" \
    "🧭 Rapid Auto Mode" \
    "   session:    $MODEL_ALIAS as $SESSION_MODEL_ID" \
    "   classifier: $LA_RAPID_AUTO_CLASSIFIER_MODEL_ID" \
    "   endpoint:   $ANTHROPIC_BASE_URL" \
    "   cache:      $LA_OMLX_SHARED_CACHE_DIR" \
    "   log:        $server_log"

session_log_offset=0
if [ -f "$server_log" ]; then
    session_log_offset="$(
        wc -c <"$server_log" |
            tr -d ' '
    )"
fi

session_status=0
if claude "${claude_args[@]}"; then
    session_status=0
else
    session_status=$?
fi

la_omlx_record_session_health \
    "$server_log" \
    "${session_log_offset:-0}"

exit "$session_status"
