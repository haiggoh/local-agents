#!/usr/bin/env bash
# launch-claude-agent-omlx.sh — local Claude Code Auto Mode through oMLX.
#
# The session model is exposed under its configured Claude compatibility ID.
# A separate dense classifier is exposed as claude-sonnet-5. oMLX therefore
# routes the two request classes without a proxy while its paged prefix cache
# reuses the growing segmented classifier transcript.
set -euo pipefail

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
    printf '%s\n' "OMLX_AUTO_LAUNCHER_SELF_TEST_OK"
    exit 0
fi

# shellcheck source=/dev/null
. "$LAUNCH_DIR/../config/config-lib.sh"
la_load_config || exit 1
# shellcheck source=/dev/null
. "$LAUNCH_DIR/omlx-progress.sh"
# shellcheck source=/dev/null
. "$LAUNCH_DIR/omlx-auto-prewarm-gate.sh"

MODEL_ALIAS="${1:-}"
EFFORT_OVERRIDE="${2:-}"

if [ -z "$MODEL_ALIAS" ] || ! la_lookup "$MODEL_ALIAS"; then
    echo "Usage: $0 <alias> [effort-override]" >&2
    exit 2
fi

MODEL_DIR="$LA_CUR_DIR"
SESSION_MODEL_ID="${LA_CUR_SPOOF%%,*}"
EFFORT="${EFFORT_OVERRIDE:-$LA_CUR_EFFORT}"

: "${LA_OMLX_BIN:=/opt/homebrew/bin/omlx}"
: "${LA_OMLX_PORT:=8002}"
: "${LA_OMLX_CLASSIFIER_MODEL_DIR:=}"
: "${LA_OMLX_CLASSIFIER_MODEL_ID:=claude-sonnet-5}"
: "${LA_OMLX_CACHE_ROOT:=$HOME/.cache/local-agents/omlx-auto}"
: "${LA_OMLX_CACHE_MAX_SIZE:=100GB}"
: "${LA_OMLX_HOT_CACHE_MAX_SIZE:=8GB}"

# oMLX 0.6.4 exposes one process-wide paged-cache path. Main-session and
# classifier KV blocks share this directory and its existing 100 GB ceiling.
: "${LA_OMLX_SHARED_CACHE_DIR:=$LA_OMLX_CACHE_ROOT/$LA_OMLX_CLASSIFIER_MODEL_ID}"

: "${LA_OMLX_MEMORY_GUARD:=balanced}"
: "${LA_OMLX_MAX_CONCURRENT_REQUESTS:=2}"
: "${LA_OMLX_KEEP_RUNTIME_VIEW:=0}"
: "${LA_OMLX_DRY_RUN:=0}"

[ -x "$LA_OMLX_BIN" ] || {
    echo "ERROR: oMLX executable missing: $LA_OMLX_BIN" >&2
    exit 2
}

[ -f "$MODEL_DIR/config.json" ] || {
    echo "ERROR: session model is unavailable: $MODEL_DIR" >&2
    exit 2
}

[ -n "$LA_OMLX_CLASSIFIER_MODEL_DIR" ] || {
    echo "ERROR: LA_OMLX_CLASSIFIER_MODEL_DIR is required" >&2
    exit 2
}

[ -f "$LA_OMLX_CLASSIFIER_MODEL_DIR/config.json" ] || {
    echo "ERROR: classifier model is unavailable: $LA_OMLX_CLASSIFIER_MODEL_DIR" >&2
    exit 2
}

case "$LA_OMLX_PORT" in
    ''|*[!0-9]*)
        echo "ERROR: LA_OMLX_PORT must be numeric" >&2
        exit 2
        ;;
esac

case "$LA_OMLX_MAX_CONCURRENT_REQUESTS" in
    ''|*[!0-9]*)
        echo "ERROR: LA_OMLX_MAX_CONCURRENT_REQUESTS must be numeric" >&2
        exit 2
        ;;
esac

if [ "$SESSION_MODEL_ID" = "$LA_OMLX_CLASSIFIER_MODEL_ID" ]; then
    echo "ERROR: session and classifier model IDs must differ" >&2
    exit 2
fi

if [ "$LA_OMLX_DRY_RUN" = "1" ]; then
    printf '%s\n' \
        "OMLX_DRY_RUN_OK" \
        "session_alias=$MODEL_ALIAS" \
        "session_model_dir=$MODEL_DIR" \
        "session_model_id=$SESSION_MODEL_ID" \
        "classifier_model_dir=$LA_OMLX_CLASSIFIER_MODEL_DIR" \
        "classifier_model_id=$LA_OMLX_CLASSIFIER_MODEL_ID" \
        "port=$LA_OMLX_PORT" \
        "segmented=${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-unset}"
    exit 0
fi

if lsof -nP -iTCP:"$LA_OMLX_PORT" -sTCP:LISTEN -t \
    >/dev/null 2>&1
then
    echo "ERROR: oMLX Auto Mode port is occupied: $LA_OMLX_PORT" >&2
    lsof -nP -iTCP:"$LA_OMLX_PORT" -sTCP:LISTEN >&2 || true
    exit 2
fi

la_omlx_prewarm_prepare || exit 2

runtime_root="$(
    mktemp -d "${TMPDIR:-/tmp}/local-agents-omlx-auto.XXXXXX"
)"
runtime_root="$(cd -P "$runtime_root" && /bin/pwd -P)"

base_root="$runtime_root/base"
model_root="$runtime_root/models"
session_view="$model_root/$SESSION_MODEL_ID"
classifier_view="$model_root/$LA_OMLX_CLASSIFIER_MODEL_ID"

cache_root="$LA_OMLX_SHARED_CACHE_DIR"
log_dir="$HOME/.claude/logs"
server_log="$log_dir/omlx_${LA_OMLX_PORT}.log"

mkdir -p \
    "$base_root" \
    "$session_view" \
    "$classifier_view" \
    "$cache_root" \
    "$log_dir"

link_model_contents() {
    local source_dir="$1"
    local destination_dir="$2"
    local item

    while IFS= read -r -d '' item; do
        ln -s "$item" "$destination_dir/$(basename "$item")"
    done < <(
        find "$source_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -print0
    )
}

link_model_contents "$MODEL_DIR" "$session_view"
link_model_contents \
    "$LA_OMLX_CLASSIFIER_MODEL_DIR" \
    "$classifier_view"

[ -f "$session_view/config.json" ] || {
    echo "ERROR: session model view is incomplete" >&2
    exit 2
}

[ -f "$classifier_view/config.json" ] || {
    echo "ERROR: classifier model view is incomplete" >&2
    exit 2
}

omlx_pid=""

cleanup() {
    if [ -n "$omlx_pid" ] && kill -0 "$omlx_pid" 2>/dev/null; then
        kill "$omlx_pid" 2>/dev/null || true

        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$omlx_pid" 2>/dev/null || break
            sleep 1
        done

        if kill -0 "$omlx_pid" 2>/dev/null; then
            kill -9 "$omlx_pid" 2>/dev/null || true
        fi

        wait "$omlx_pid" 2>/dev/null || true
    fi

    if [ "$LA_OMLX_KEEP_RUNTIME_VIEW" != "1" ]; then
        rm -rf "$runtime_root"
    fi
}

trap cleanup EXIT INT TERM HUP

la_progress_init
la_progress_stage "Starting isolated oMLX server"

"$LA_OMLX_BIN" serve \
    --base-path "$base_root" \
    --model-dir "$model_root" \
    --no-hf-cache \
    --host 127.0.0.1 \
    --port "$LA_OMLX_PORT" \
    --log-level debug \
    --sse-keepalive-mode chunk \
    --max-concurrent-requests "$LA_OMLX_MAX_CONCURRENT_REQUESTS" \
    --memory-guard "$LA_OMLX_MEMORY_GUARD" \
    --paged-ssd-cache-dir "$cache_root" \
    --paged-ssd-cache-max-size "$LA_OMLX_CACHE_MAX_SIZE" \
    --hot-cache-max-size "$LA_OMLX_HOT_CACHE_MAX_SIZE" \
    --hot-cache-write-through \
    --initial-cache-blocks 256 \
    >"$server_log" 2>&1 &

omlx_pid=$!

ready=0
for _ in $(seq 1 120); do
    la_progress_tick "Discovering session and classifier models"

    if ! kill -0 "$omlx_pid" 2>/dev/null; then
        tail -120 "$server_log" >&2 || true
        echo "ERROR: oMLX server exited during startup" >&2
        exit 1
    fi

    models_json="$(
        curl -sS --max-time 2 \
            "http://127.0.0.1:$LA_OMLX_PORT/v1/models" \
            2>/dev/null || true
    )"

    if printf '%s' "$models_json" |
       SESSION_MODEL_ID="$SESSION_MODEL_ID" \
       CLASSIFIER_MODEL_ID="$LA_OMLX_CLASSIFIER_MODEL_ID" \
       python3 -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

ids = {row.get("id") for row in payload.get("data", [])}
wanted = {
    os.environ["SESSION_MODEL_ID"],
    os.environ["CLASSIFIER_MODEL_ID"],
}
raise SystemExit(0 if wanted <= ids else 1)
'
    then
        ready=1
        break
    fi

    sleep 2
done

[ "$ready" -eq 1 ] || {
    tail -160 "$server_log" >&2 || true
    echo "ERROR: oMLX did not advertise both model IDs" >&2
    exit 1
}

la_progress_success "oMLX advertised both model IDs"

export ANTHROPIC_BASE_URL="http://127.0.0.1:$LA_OMLX_PORT"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local}"
export CLAUDE_IS_LOCAL=true
export CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_AUTOUPDATER=1
export API_TIMEOUT_MS="${LA_API_TIMEOUT_MS:-1800000}"
export API_FORCE_IDLE_TIMEOUT=0
export CLAUDE_ENABLE_STREAM_WATCHDOG=0

if ! la_omlx_warm_session_model "$ANTHROPIC_BASE_URL"; then
    printf '%s\n'         "ERROR: Local session model did not become ready."         "       Claude Code was not started."         "       Log: $server_log" >&2
    exit 1
fi

if ! la_omlx_readiness_gate "$ANTHROPIC_BASE_URL"; then
    printf '%s\n'         "ERROR: Local Auto Mode classifier was not ready."         "       Claude Code was not started because fallback would be unsafe."         "       Log: $server_log" >&2
    exit 1
fi

la_progress_success "Local Auto Mode ready — opening Claude Code"

claude_args=(
    --model "$SESSION_MODEL_ID"
    --effort "$EFFORT"
    --permission-mode auto
    --strict-mcp-config
    --append-system-prompt
    "LOCAL oMLX Auto Mode: session=$MODEL_ALIAS; classifier=$LA_OMLX_CLASSIFIER_MODEL_ID; inference is local."
)

if [ -n "${LA_CLAUDE_SETTINGS:-}" ]; then
    claude_args+=(--settings "$LA_CLAUDE_SETTINGS")
fi

if [ -n "${LA_CLAUDE_TOOLS:-}" ]; then
    claude_args+=(--tools "$LA_CLAUDE_TOOLS")
fi

if [ -n "${LA_DENY_TOOLS:-}" ]; then
    claude_args+=(--disallowedTools "$LA_DENY_TOOLS")
fi

printf '%s\n' \
    "🧭 oMLX Auto Mode" \
    "   session:    $MODEL_ALIAS as $SESSION_MODEL_ID" \
    "   classifier: $LA_OMLX_CLASSIFIER_MODEL_ID" \
    "   endpoint:   $ANTHROPIC_BASE_URL" \
    "   shared cache: $cache_root" \
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

la_omlx_record_session_health     "$server_log"     "${session_log_offset:-0}"

exit "$session_status"
