#!/usr/bin/env bash
# launch-local-auto-mode.sh — run a LOCAL Claude Code session in `auto` permission mode with its
# SAFETY-CLASSIFIER routed to a LOCAL backend (Comprehensive plan, Phase 8 / "local classifier" item).
#
# WHY THIS FILE EXISTS
#   Auto mode uses a SEPARATE classifier (plan §2.1), independent of /model. For a gateway-routed
#   session that classifier goes to the cloud; the point here is to point it LOCAL so a cloud 429 /
#   budget-limit can never force the acceptEdits fallback.
#
#   The catch we hit on 2026-09-02 (plan "2026-09-02 AUTO MODE DOES NOT WORK OUT OF THE BOX", and
#   waypoint local-auto-mode-classifier): a classifier request can only be served if the backend can
#   actually give it a slot. A main interactive session already holds the ONLY slot (--max-num-seqs=1,
#   Metal-memory bound), so the classifier queued behind it and TIMED OUT — "claude-opus-5 is
#   temporarily unavailable". Exporting ANTHROPIC_BASE_URL=localhost is therefore NECESSARY but NOT
#   SUFFICIENT — the classifier also needs a free slot.
#
#   So this launcher GIVES the classifier a free slot, in one of two config-strategies:
#     A) raise --max-num-seqs to 2 on the MAIN server and let the classifier run as a 2nd concurrent
#        sequence on the SAME weights (chosen by LA_AUTO_CLASSIFIER_MODE=a). Cheapest — no second
#        server — but it must fit in the remaining Metal headroom (we guard against OOM).
#     B) keep a SEPARATE small model warm on a second free port (LA_AUTO_CLASSIFIER_MODE=b), so the
#        main session never shares a slot. Safer memory isolation, uses a bit more RAM.
#   The small model used for the classifier is chosen automatically from the SMALLEST-WEIGHT model on
#   disk (so it doesn't need a lot of extra RAM); override with LA_AUTO_CLASSIFIER_MODEL=<alias>.
#
#   Plan Phase 8 named qwen-3.6-safety, but that predates many models. The only requirement is a
#   low-RAM one — the plan's model choice is irrelevant once we can pick from the whole disk.
#
# DESIGN (config-driven, NEVER hardcodes a port or a model):
#   * The classifier target is whatever claude --permission-mode auto emits the classifier to. Its
#     base URL is inherited from the session env (ANTHROPIC_BASE_URL), which we set to the chosen
#     server. We never hardcode a port — local-llm-hotswap.sh prints the first FREE port (SUCCESS_PORT)
#     after scanning LA_PORT_START..LA_PORT_MAX (8000..8010). We read that; we don't assume it.
#   * The chosen model comes from la_lookup (config-lib), so the model name/effort/parser are config,
#     not hardcoded here. Default: the smallest-weight alias on disk.
#
# USAGE:
#   JOYIA_LOCAL_AUTO_CLASSIFIER=1 \
#     launch-local-auto-mode.sh <main-alias> [strategy: a|b] [effort-override]
#
#   <main-alias>   the model the interactive session runs on (e.g. qwen-3.6-operator, ornith-1.5-35b).
#   [a|b]          optional strategy. a = raise --max-num-seqs to 2 on that server (default).
#                  b = keep a separate small classifier model warm on a second free port.
#   The launcher: (1) warms the chosen server(s) on free port(s), (2) exports the local-session env,
#   (3) launches `claude --permission-mode auto` (NOT acceptEdits) pointed at them.
#
# It is OFF by default; flip JOYIA_LOCAL_AUTO_CLASSIFIER=1 to use it. See:
#   ~/.claude/scripts/local-inference/launch-local-auto-mode.sh (live copy; edit the plugin repo).
set -uo pipefail

# Resolve symlinks (portable across macOS bash 3.2) so this works by own path, ~/.claude symlink, or
# plugin-repo path.
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
LAUNCH_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$LAUNCH_DIR/../config/config-lib.sh"
la_load_config || exit 1

# --- opt-in gate -------------------------------------------------------------
# Default OFF. Changing where the auto-mode classifier points is exactly the lever the plan keeps
# conservative, so only run it when the caller explicitly flips the switch.
if [ "${JOYIA_LOCAL_AUTO_CLASSIFIER:-0}" != "1" ]; then
    echo "❌ launch-local-auto-mode.sh is OFF by design."
    echo "   It routes the auto-mode SAFETY-CLASSIFIER to a local backend (Plan Phase 8)."
    echo "   Flip the opt-in to use it:"
    echo
    echo "     JOYIA_LOCAL_AUTO_CLASSIFIER=1 $0 <main-alias> [a|b]"
    echo
    echo "   Strategy a (default): raise --max-num-seqs to 2 on the main server (reuse its weights)."
    echo "   Strategy b: keep a small classifier model warm on a separate free port."
    echo
    echo "   Without it, use launch-claude-agent.sh <alias> (acceptEdits, not auto)."
    exit 0
fi

# --- resolve caller's choices -----------------------------------------------
# Usage: launch-local-auto-mode.sh <main-alias> [strategy a|b] [effort]
MAIN_ALIAS="${1:-}"
STRATEGY="${2:-}"
case "$STRATEGY" in ""|a) STRATEGY="a" ;; b) ;; *) echo "❌ unknown strategy '$STRATEGY' (use a|b)"; exit 1 ;; esac
EFFORT_OVERRIDE="${3:-}"

[ -z "$MAIN_ALIAS" ] && { echo "❌ need a <main-alias> (the model the interactive session runs on)."; echo "   e.g. $0 qwen-3.6-operator a"; exit 1; }
if ! la_lookup "$MAIN_ALIAS"; then
    echo "❌ unknown main-alias '$MAIN_ALIAS'. Registered:"; la_aliases_help; exit 1
fi
# la_lookup sets LA_CUR_* for the MAIN session (the server we warm).
MAIN_SPOOF="${LA_CUR_SPOOF%%,*}"
EFFORT="${EFFORT_OVERRIDE:-$LA_CUR_EFFORT}"

# --- pick the small classifier model ----------------------------------------
# The classifier carries a TINY prompt (tool calls + policy), so RAM headroom for it is governed by
# prompt cache, not weights — but we still prefer the smallest-weight model on disk so launching it
# (strategy b) or adding a 2nd sequence (strategy a) costs as little Metal RAM as possible.
#
# If LA_AUTO_CLASSIFIER_MODEL is set, la_lookup it. Otherwise pick the smallest-weight alias on disk:
# la_size[<alias>] is the GB column; pick the smallest, tie-broken by lowest params (smallest file).
if [ -n "${LA_AUTO_CLASSIFIER_MODEL:-}" ] && la_lookup "$LA_AUTO_CLASSIFIER_MODEL"; then
    CLS_ALIAS="$LA_AUTO_CLASSIFIER_MODEL"
else
    CLS_ALIAS=""
    _min_size=""
    # Measure the ACTUAL disk size (du) of each candidate — this reflects real GB, not the optional
    # LA_SIZE column. la_lookup sets LA_CUR_DIR to the weights dir, so du on it is authoritative.
    _disk_size() { du -sk "$1" 2>/dev/null | cut -f1; }
    for _c in "${LA_ALIASES[@]:-}"; do
        [ "$_c" = "$MAIN_ALIAS" ] && continue   # never classifier our own main model (strategy a)
        # Prefer disk-measured size; fall back to the config column. Both are just a hint — du is the
        # source of truth, so read the dir only if la_lookup already set it.
        _s_val=""
        if la_lookup "$_c"; then _s_val="$(_disk_size "$LA_CUR_DIR")"; [ -z "$_s_val" ] && _s_val="${LA_SIZE[$_c]:-}"; fi
        [ -z "$_s_val" ] && continue
        # du returns KB; the LA_SIZE column is GB. Normalize du to GB for comparison.
        _s_gb=$(awk "BEGIN{printf \"%.0f\", $_s_val/1024}" 2>/dev/null)
        [ -z "$_s_gb" ] && continue
        if [ -z "$_min_size" ]; then _min_size="$_s_gb"; CLS_ALIAS="$_c"; continue; fi
        if [ "$_s_gb" -lt "$_min_size" ] 2>/dev/null; then _min_size="$_s_gb"; CLS_ALIAS="$_c"; fi
    done
    [ -z "$CLS_ALIAS" ] && CLS_ALIAS="$MAIN_ALIAS"   # fallback: nothing else small on disk
    echo "   (classifier model auto-picked as smallest on disk: $CLS_ALIAS, ~${_min_size:-?}GB)"
fi
if ! la_lookup "$CLS_ALIAS"; then
    echo "❌ could not resolve the classifier model for $CLS_ALIAS"; exit 1
fi
# Strategy a reuses the MAIN server; the classifier model is just "what to feed the 2nd sequence",
# but the SERVER (port) is the main server. Strategy b warms CLS_ALIAS on its own free port.
if [ "$STRATEGY" = "a" ]; then
    CLS_FOR_SERVER="$MAIN_ALIAS"
    CLS_SPOOF="$MAIN_SPOOF"
else
    CLS_FOR_SERVER="$CLS_ALIAS"
    CLS_SPOOF="${LA_CUR_SPOOF%%,*}"
fi

# --- warm the server(s) on FREE ports (dynamic, never hardcoded) ------------
# local-llm-hotswap.sh resolves an alias to the first FREE port and prints SUCCESS_PORT. Strategy a:
# just warm the MAIN server once (we will later raise its --max-num-seqs at launch). Strategy b:
# warm the main server AND the small classifier server, each on its own free port.
echo "⏳ Warming servers on free ports (strategy $STRATEGY) via hotswap..."
LAUNCH_OUTPUT=$("$LAUNCH_DIR/local-llm-hotswap.sh" "$MAIN_ALIAS"); echo "$LAUNCH_OUTPUT"
MAIN_PORT=$(echo "$LAUNCH_OUTPUT" | grep -o "SUCCESS_PORT=[0-9]*" | cut -d'=' -f2)
[ -z "$MAIN_PORT" ] && { echo "❌ could not resolve the main server port."; exit 1; }

if [ "$STRATEGY" = "b" ]; then
    # Warm the separate classifier server on its own free port. Its model may already be running
    # (hotswap reuses), so capture whatever free port it landed on.
    _cls_out=$("$LAUNCH_DIR/local-llm-hotswap.sh" "$CLS_FOR_SERVER"); echo "$_cls_out"
    CLS_PORT=$(echo "$_cls_out" | grep -o "SUCCESS_PORT=[0-9]*" | cut -d'=' -f2)
    [ -z "$CLS_PORT" ] && CLS_PORT="$MAIN_PORT"   # same server if hotswap reused it (rare for b)
    # Sanity: the two should be different ports. Warn but continue if not.
    [ "$CLS_PORT" = "$MAIN_PORT" ] && echo "⚠️ strategy b requested but both landed on $MAIN_PORT — treating as a (see below)." && STRATEGY="a"
else
    CLS_PORT="$MAIN_PORT"
fi

# Pick a spoof id THIS PORT ACTUALLY SERVES (hotswap may reuse a server started from older config).
_pick_spoof() {
    local _port="$1" _list="$2" _c
    local _served=$(curl -s --max-time 5 "http://localhost:${_port}/v1/models" 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
    for _c in $(printf '%s' "$_list" | tr ',' ' '); do
        case " $_served " in *" $_c "*) printf '%s' "$_c"; return 0 ;; esac
    done
    printf '%s' "$_list" | cut -d',' -f1
}
MAIN_SPOOF=$(_pick_spoof "$MAIN_PORT" "$MAIN_SPOOF")
if [ "$STRATEGY" = "b" ]; then CLS_SPOOF=$(_pick_spoof "$CLS_PORT" "${LA_CUR_SPOOF:-claude-opus-5}"); fi

# --- tell the user what we wired up ----------------------------------------
echo "🧭 Local auto-mode classifier session (strategy $STRATEGY):"
if [ "$STRATEGY" = "a" ]; then
    echo "   main      : $MAIN_ALIAS  presenting as $MAIN_SPOOF  →  http://localhost:$MAIN_PORT"
    echo "   classifier: same server, --max-num-seqs=2 (2nd concurrent sequence, same weights)"
else
    echo "   main      : $MAIN_ALIAS  presenting as $MAIN_SPOOF  →  http://localhost:$MAIN_PORT"
    echo "   classifier: $CLS_ALIAS  presenting as $CLS_SPOOF  →  http://localhost:$CLS_PORT (separate small model)"
fi
echo "   permission: auto"
echo "   opt-in    : JOYIA_LOCAL_AUTO_CLASSIFIER=${JOYIA_LOCAL_AUTO_CLASSIFIER}"
echo

# --- OOM guard -------------------------------------------------------------
# Strategy a raises --max-num-seqs to 2 on the main server. That needs ~2x peak Metal RAM for the
# batched turn. The cap here is 103.9 GB and a ~88k-token main turn already peaks at ~101 GB, so a
# 2nd concurrent 35B-MoE sequence would OOM-crash the server. Before raising --max-num-seqs we check
# the server's current peak; if it is already near the cap we refuse (and suggest strategy b),
# unless the caller overrides with LA_FORCE_MAX_NUM_SEQS2=1.
if [ "$STRATEGY" = "a" ]; then
    _peak=$(curl -s --max-time 3 "http://localhost:$MAIN_PORT/healthz" 2>/dev/null | grep -oE "[0-9.]+GB" | tail -1)
    _peak_num=${_peak%GB}
    if [ -n "${_peak_num:-}" ] && awk "BEGIN{exit !($_peak_num > 90)}"; then
        echo "⚠️ main server peak ${_peak} is near the 103.9 GB Metal cap — raising --max-num-seqs to 2"
        echo "   would likely OOM-crash it. Use strategy b (separate small model) instead, or force with"
        echo "   LA_FORCE_MAX_NUM_SEQS2=1 if you are certain there is headroom."
        [ "${LA_FORCE_MAX_NUM_SEQS2:-0}" = "1" ] || exit 1
    fi
fi

# --- DIRECT routing env (mirrors launch-claude-agent.sh) --------------------
# ANTHROPIC_BASE_URL points at the classifier's server, which claude --permission-mode auto inherits
# for its classifier call. NO /v1 suffix — Claude Code appends /v1/messages.
export ANTHROPIC_BASE_URL="http://localhost:${MAIN_PORT}"
export ANTHROPIC_AUTH_TOKEN="local"
export CLAUDE_IS_LOCAL="true"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LA_MAX_OUTPUT_TOKENS"
export API_TIMEOUT_MS="$LA_API_TIMEOUT_MS"
export API_FORCE_IDLE_TIMEOUT=0
# A slow first token on a local model doing a big prefill normally trips Claude Code's 5-min
# streaming idle watchdog. Local prefill that emits nothing is normal, not a hang — turn the guard off.
export CLAUDE_ENABLE_STREAM_WATCHDOG=0

# strategy a: tell the warmed server to admit 2 concurrent sequences (the main turn + the classifier).
if [ "$STRATEGY" = "a" ]; then
    export VLLM_MLX_SIMPLE_ENGINE_MAX_NUM_SEQS=2
    echo "   (raised --max-num-seqs to 2 on the main server; the classifier runs as a 2nd sequence)"
fi

# Log the launcher run.
mkdir -p "$HOME/.claude/logs"
echo "$(date '+%Y-%m-%d %H:%M:%S')  main=$MAIN_ALIAS classifier_mode=$STRATEGY classmod=$CLS_ALIAS spoof=$MAIN_SPOOF effort=$EFFORT backend=${LA_CUR_SERVE} main_port=$MAIN_PORT cls_port=$CLS_PORT mode=auto" \
    >> "$HOME/.claude/logs/local-agents-sessions.log"

# claude --permission-mode auto (NOT acceptEdits): this is the whole point. In auto mode every
# consequential Bash call is judged by the SEPARATE classifier; we've pointed that classifier at a
# warmed local backend with a free slot, so a cloud 429 / budget-limit can't force the acceptEdits
# fallback.
claude --model "$MAIN_SPOOF" --effort "$EFFORT" --strict-mcp-config --permission-mode auto \
    --append-system-prompt "You are running in LOCAL auto mode with a local safety-classifier backend."