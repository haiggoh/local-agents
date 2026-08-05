#!/usr/bin/env bash
# local-llm-hotswap.sh — land a registered model on the first FREE port and print SUCCESS_PORT.
#
# Config-driven: the model registry + machine settings come from config/config.local.sh
# (your private overlay) or config/config.example.sh (shipped defaults). SAFE by design — it
# scans ports, reuses a healthy matching server, reclaims only frozen zombies, and NEVER kills a
# healthy model already running on another port (so it can't shut down a live local session).
set -uo pipefail

# Resolve symlinks so invocation via a symlink still finds this repo's config (portable).
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
HOTSWAP_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$HOTSWAP_DIR/../config/config-lib.sh"
la_load_config || exit 1

MODEL_NAME="${1:-}"
LOG_FILE_BASE="$HOME/.claude/logs/vllm"
CONFIG_DIR="$HOME/.claude/logs/local-agents-configs"
mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE_BASE")"

# Base flag for EVERY vllm tier. --enable-auto-tool-choice is what surfaces structured tool_calls;
# without it the model's commands leak into chat as markdown. Per-model --tool-call-parser is added
# from the registry. Concurrent Claude Code requests (main turn + background calls) hit the
# single-slot SimpleEngine; LA_ADMISSION=wait makes overflow QUEUE instead of erroring (EngineBusy).
export VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION="$LA_ADMISSION"

if [ -z "$MODEL_NAME" ] || ! la_lookup "$MODEL_NAME"; then
    echo "Usage: $0 <alias>"; echo "Registered aliases:"; la_aliases_help; exit 1
fi
MODEL_DIR="$LA_CUR_DIR"; SPOOF_NAME="$LA_CUR_SPOOF"; SERVE="$LA_CUR_SERVE"
TOOLP="$LA_CUR_TOOLP"; REASONP="$LA_CUR_REASONP"; THINK="$LA_CUR_THINK"
if [ ! -d "$MODEL_DIR" ]; then echo "❌ model dir not found: $MODEL_DIR (check LA_MODELS_DIR / subdir in config)"; exit 1; fi

# --- bounded readiness wait (dumps log tail + PID liveness on timeout; validates identity) ----
wait_ready() {
    local port="$1" logf="$2" label="${3:-server}" pid="${4:-}" expected_id="${5:-}"
    # NOTE: keep these on SEPARATE `local` lines. Under `set -u`, a single
    # `local a=x b=$((...a...))` evaluates every RHS before binding any name, so `timeout`
    # inside the arithmetic resolves to a not-yet-set variable -> "timeout: unbound variable"
    # (localized "timeout ist nicht gesetzt"), which aborted wait_ready and suppressed SUCCESS_PORT.
    local timeout="${HOTSWAP_READY_TIMEOUT:-480}"
    local deadline=$(( SECONDS + timeout ))
    until curl -s --max-time 2 "http://localhost:$port/v1/models" > /dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            { echo "❌ $label startup FAILED — /v1/models silent after ${timeout}s (port $port, log $logf)"
              if [ -n "$pid" ]; then kill -0 "$pid" 2>/dev/null \
                 && echo "   pid $pid ALIVE (loading/wedged)" || echo "   pid $pid DEAD (crashed — see log)"; fi
              echo "   --- last 80 log lines ---"; tail -n 80 "$logf" 2>/dev/null; } >&2
            exit 1
        fi
        sleep 2
    done
    if [ -n "$expected_id" ]; then
        local observed
        observed=$(curl -s --max-time 4 "http://localhost:$port/v1/models" 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
        case " $observed " in *" $expected_id "*) : ;; *) echo "⚠️  $label: expected id '$expected_id' not in /v1/models (observed: ${observed:-none})." >&2 ;; esac
    fi
}

echo "Scanning ports $LA_PORT_START-$LA_PORT_MAX for a free slot (config: ${LA_CONFIG_SOURCE})..."
TARGET_PORT=""
for ((port=LA_PORT_START; port<=LA_PORT_MAX; port++)); do
    if lsof -i :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        CURRENT_IDS=$(curl -s --max-time 4 "http://localhost:$port/v1/models" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
        CURRENT_MODEL=$(printf '%s\n' "$CURRENT_IDS" | head -n 1)
        # If GET already returned an id the process is alive — do NOT probe-kill (a cold heavy model
        # can be slow). Only run a completion probe when GET gave nothing.
        if [ -n "$CURRENT_MODEL" ]; then HEALTH="alive:$CURRENT_MODEL"; else
            HEALTH=$(curl -s --max-time 25 -X POST "http://localhost:$port/v1/chat/completions" -H "Content-Type: application/json" \
                     -d '{"model":"probe","messages":[{"role":"user","content":"p"}],"max_tokens":1}'); fi
        if [ -z "$HEALTH" ]; then
            echo "⚠️ Port $port frozen (zombie). Reclaiming..."; TARGET_PID=$(lsof -t -i :$port -sTCP:LISTEN)
            [ -n "$TARGET_PID" ] && { kill -9 "$TARGET_PID"; sleep 1; }; TARGET_PORT=$port; break
        elif printf '%s\n' "$CURRENT_IDS" | grep -qxF "$MODEL_NAME" || printf '%s\n' "$CURRENT_IDS" | grep -qxF "$MODEL_DIR"; then
            # Match the DISTINCT alias/dir id (served alongside the shared spoof) so tiers sharing a
            # spoof don't wrongly reuse each other's server.
            echo "✅ $MODEL_NAME already healthy on port $port."; echo "SUCCESS_PORT=$port"; exit 0
        fi
        echo "ℹ️ Port $port busy serving '$CURRENT_MODEL'. Skipping..."
    else TARGET_PORT=$port; break; fi
done
[ -z "$TARGET_PORT" ] && { echo "❌ All ports $LA_PORT_START-$LA_PORT_MAX saturated."; exit 1; }
LOG_FILE="${LOG_FILE_BASE}_${TARGET_PORT}.log"

# --- mlx_lm.server branch (dispatch-only tiers, e.g. Llama-4 which vllm-mlx misroutes) --------
if [ "$SERVE" = "mlx_lm" ]; then
    echo "🚀 Launching $MODEL_NAME via mlx_lm.server on free port $TARGET_PORT..."
    nohup "$LA_VENV/python" -m mlx_lm server --model "$MODEL_DIR" --host 127.0.0.1 --port "$TARGET_PORT" \
        --max-tokens 4096 > "$LOG_FILE" 2>&1 &
    wait_ready "$TARGET_PORT" "$LOG_FILE" "$MODEL_NAME" "$!" "$MODEL_DIR"
    echo "ℹ️  $MODEL_NAME model id = $MODEL_DIR  (use as the 'model' field when dispatching)"
    echo "SUCCESS_PORT=$TARGET_PORT"; exit 0
fi

# --- vllm-mlx branch ---------------------------------------------------------
TMP_CONFIG="$CONFIG_DIR/vllm_config_${TARGET_PORT}.yaml"
# spoof_id may be a COMMA-SEPARATED preference list, newest Claude model first
# (e.g. "claude-opus-5,claude-opus-4-8"). We serve the SAME weights under EVERY id plus the
# alias, so one server satisfies both a current Claude Code (which asks for the newest model)
# and an older one still on the previous model — with no version detection anywhere. Without
# this, a client asking for an unserved id gets a hard 404 from vllm:
#   {"detail":"The model `claude-opus-5` does not exist. Available models: `claude-opus-4-8`..."}
# Verified safe against vllm-mlx's own loader (model_registry.py): the registry is a
# dict keyed by NAME and the only uniqueness check is on name — duplicate `path` values are
# explicitly allowed. ⚠ CAVEAT: `_loaded` and the concurrent-load coalescer (`same_model_future`)
# are ALSO keyed by name, not by source path, so if a single server is asked for TWO different
# ids it will load the weights TWICE (~model-size each) until the memory-budget evictor reclaims
# the idle one. Harmless in normal use — one client session sends one id for its whole lifetime —
# but do NOT deliberately mix ids against one port.
SPOOF_PRIMARY="${SPOOF_NAME%%,*}"          # first = preferred; what wait_ready checks for
{
  echo "manager:"
  echo "  memory_budget_gb: $LA_MEMORY_BUDGET_GB"
  echo "models:"
  # shellcheck disable=SC2001
  for _id in $(printf '%s' "$SPOOF_NAME" | tr ',' ' ') "$MODEL_NAME"; do
    [ -n "$_id" ] || continue
    echo "  - name: \"$_id\""
    echo "    path: \"$MODEL_DIR\""
    echo "    max_model_len: $LA_MAX_MODEL_LEN"
    echo "    kv_cache_quantization_level: 4"
  done
} > "$TMP_CONFIG"

EXTRA_ARGS="--enable-auto-tool-choice --tool-call-parser $TOOLP"
[ -n "$REASONP" ] && EXTRA_ARGS="$EXTRA_ARGS --reasoning-parser $REASONP --default-temperature 0.6 --default-top-p 0.95"
export VLLM_MLX_ENABLE_THINKING="${VLLM_MLX_ENABLE_THINKING:-$THINK}"

echo "🚀 Launching $MODEL_NAME on free port $TARGET_PORT  (🧠 thinking: $VLLM_MLX_ENABLE_THINKING)..."
nohup "$LA_VENV/vllm-mlx" serve --models-config "$TMP_CONFIG" --port "$TARGET_PORT" $EXTRA_ARGS > "$LOG_FILE" 2>&1 &
wait_ready "$TARGET_PORT" "$LOG_FILE" "$MODEL_NAME" "$!" "$SPOOF_PRIMARY"
tail -n 8 "$LOG_FILE"
echo "SUCCESS_PORT=$TARGET_PORT"
