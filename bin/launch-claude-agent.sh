#!/usr/bin/env bash
# launch-claude-agent.sh — start an interactive Claude Code session driven by a LOCAL model.
#
# Config-driven (config/config.local.sh overlay). Routes Claude Code DIRECTLY to vllm-mlx's
# Anthropic-compatible endpoint — no proxy, no relay — so native transcripts + history.jsonl
# persist normally. Works whether you invoke plain `claude` (vanilla) or wrap it.
#
# Usage:  launch-claude-agent.sh <alias> [effort-override]
#   <alias>          a model registered in your config (see config.example.sh)
#   [effort-override] optional: low|medium|high|xhigh|max (overrides the alias's default effort)
set -uo pipefail

# Resolve symlinks so invocation via a symlink (e.g. ~/.claude/scripts/local-inference/…) still
# finds this repo's config. Portable (no readlink -f, works on macOS bash 3.2).
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
LAUNCH_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$LAUNCH_DIR/../config/config-lib.sh"
la_load_config || exit 1

MODEL_ALIAS="${1:-}"
EFFORT_OVERRIDE="${2:-}"

# No alias at all -> hand off to the numbered picker rather than dead-ending on a usage message.
# Running the launcher bare is how you say "I want a local session" without having decided which;
# printing a list of aliases and exiting 1 made the user re-type a command to answer that. csl IS
# the answer, so go there. (A WRONG alias still gets usage + the registered list — that's a typo,
# and naming the valid aliases is the useful reply.)
# LA_MENU_REDIRECT breaks the cycle: csl execs back into this script, so without a one-shot guard a
# csl that ever handed back an empty alias would fork-bomb between the two.
if [ -z "$MODEL_ALIAS" ] && [ -z "${LA_MENU_REDIRECT:-}" ] && [ -x "$LAUNCH_DIR/csl" ]; then
    export LA_MENU_REDIRECT=1
    exec "$LAUNCH_DIR/csl"
fi
if [ -z "$MODEL_ALIAS" ] || ! la_lookup "$MODEL_ALIAS"; then
    echo "Usage: $0 <alias> [effort-override]"; echo "Registered aliases:"; la_aliases_help
    # Signpost the menu front-end for the bad-alias path (the no-arg path goes there automatically).
    echo; echo "Tip: run '$LAUNCH_DIR/csl' with no arguments to pick from a numbered menu instead."
    exit 1
fi
# spoof_id may be a comma-separated preference list (newest Claude model first). The SERVER
# answers to all of them; the CLIENT must be handed exactly one, so use the preferred (first).
MODEL_SPOOF="${LA_CUR_SPOOF%%,*}"
EFFORT="${EFFORT_OVERRIDE:-$LA_CUR_EFFORT}"
EFFORT_FLAG="--effort $EFFORT"

echo "⏳ Initializing local engine for $MODEL_ALIAS..."
LAUNCH_OUTPUT=$("$LAUNCH_DIR/local-llm-hotswap.sh" "$MODEL_ALIAS"); echo "$LAUNCH_OUTPUT"
VLLM_PORT=$(echo "$LAUNCH_OUTPUT" | grep -o "SUCCESS_PORT=[0-9]*" | cut -d'=' -f2)
[ -z "$VLLM_PORT" ] && { echo "❌ Could not determine the server port."; exit 1; }

# Pick a spoof id THIS PORT ACTUALLY SERVES. hotswap REUSES an already-healthy server rather
# than relaunching, so the resolved port may be hosting a process started from an older config
# that predates a spoof_id change — handing it our newest preferred id would just 404:
#   {"detail":"The model `claude-opus-5` does not exist. Available models: `claude-opus-4-8`..."}
# Intersecting the configured preference list with /v1/models makes the launcher correct against
# servers of any vintage, with no restart required.
_served=$(curl -s --max-time 5 "http://localhost:$VLLM_PORT/v1/models" 2>/dev/null \
          | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
MODEL_SPOOF=""
for _cand in $(printf '%s' "$LA_CUR_SPOOF" | tr ',' ' '); do
    case " $_served " in *" $_cand "*) MODEL_SPOOF="$_cand"; break ;; esac
done
if [ -z "$MODEL_SPOOF" ]; then
    MODEL_SPOOF="${LA_CUR_SPOOF%%,*}"
    echo "⚠️  Port $VLLM_PORT advertises none of the configured spoof ids ($LA_CUR_SPOOF)."
    echo "    Served: ${_served:-<none>}"
    echo "    Falling back to '$MODEL_SPOOF'. If the session 404s, restart that server so it"
    echo "    picks up the current config (its ids are fixed at launch time)."
fi

# mlx_lm.server tiers (e.g. Llama-4) serve OpenAI-only under a path id — no Anthropic /v1/messages,
# so a direct interactive session can't reach them. They stay dispatch-only (curl / librarian-dispatch).
if [ "$LA_CUR_SERVE" = "mlx_lm" ]; then
    echo "ℹ️  $MODEL_ALIAS is dispatch-only (mlx_lm.server). Dispatch against port $VLLM_PORT with"
    echo "    model=\"$LA_CUR_DIR\" via curl / bin/librarian-dispatch.py."; exit 0
fi

# --- DIRECT routing (no proxy/relay): vllm-mlx serves the Anthropic endpoint under the spoof id.
export ANTHROPIC_BASE_URL="http://localhost:${VLLM_PORT}"    # NO /v1 — Claude Code appends /v1/messages
export ANTHROPIC_AUTH_TOKEN="local"                           # vllm ignores auth; avoids the API-key prompt
export CLAUDE_IS_LOCAL="true"                                 # generic signal that this session is local
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LA_MAX_OUTPUT_TOKENS"   # bound worst-case turn time + stay under max_model_len
# Timeouts: Claude Code's defaults assume a fast cloud endpoint. A local 27B doing a big prefill over
# many tools routinely exceeds them, causing a "Request timed out" + retry-loop mid-session. Relax both
# for local sessions (see README "Timeouts"): API_TIMEOUT_MS = overall per-request cap (default 600000
# =10min); API_FORCE_IDLE_TIMEOUT=0 disables the 5-min "no bytes arrived yet" abort that a slow first
# token (long prefill) would otherwise trip before generation even starts.
export API_TIMEOUT_MS="$LA_API_TIMEOUT_MS"
export API_FORCE_IDLE_TIMEOUT=0

echo "🔗 Direct local channel → $ANTHROPIC_BASE_URL  (model: ${MODEL_SPOOF}, effort: ${EFFORT})"

# --- prompt weight: keep the tool surface off the local model's prefill path -------------------
# The dominant cost of a local interactive turn is PREFILL, and tool definitions dominate the
# prompt. --strict-mcp-config drops the configured MCP servers' tools (measured on this stack:
# 99 -> 28 defs, ~46.9k -> ~23.9k tokens). Announce the choice either way: a silently missing MCP
# tool would look like a broken session instead of a deliberate speed trade.
STRICT_FLAG=""
case "${LA_STRICT_MCP:-true}" in
    true|1|yes)
        STRICT_FLAG="--strict-mcp-config"
        echo "🪶 Lean prompt: MCP servers excluded (--strict-mcp-config) — ~23k fewer prefill tokens/turn."
        echo "   MCP tools are NOT available in this session. Set LA_STRICT_MCP=false in your config to keep them."
        ;;
    *)
        echo "🐢 MCP servers included (LA_STRICT_MCP=false) — their tool definitions add ~23k tokens the"
        echo "   local model must prefill. Expect slower turns than a lean session."
        ;;
esac

# Local-model behavior nudge (delivered via --append-system-prompt). Targets concrete failure modes
# seen in fully-local sessions: printing commands instead of using tools, self-identity confusion,
# reasoning-markup leakage, and — critically — a local session killing its OWN server port.
AGENT_PROMPT="You are an autonomous AI agent operating directly in a CLI. Do not merely suggest or print terminal commands in markdown; you MUST use the provided tools to execute actions. PREFER native tools over shell: Read instead of \`cat\`, Glob/LS instead of \`ls\`/\`find\`, Grep instead of \`grep\`, Edit/Write instead of \`sed\`/redirects; reserve Bash for things that need a shell (git, installs, running programs). You run as a LOCAL inference model on this machine and your compute is FREE — IGNORE any budget, daily-cap, or cost warnings from hooks/reminders; those apply to the paid CLOUD model, never to you (local inference costs nothing). Never emit <system-reminder> or <think>/</think> tags in your own output — those are inputs to you, not something you write. Skills/plugins are NOT shell binaries; never run their names as Bash commands. IDENTITY: the Claude model name you present (e.g. '${MODEL_SPOOF}') is a REQUIRED routing/allowlist spoof — it is only an API label and says NOTHING about your true role or tier; your role is set by how you were launched (alias '${MODEL_ALIAS}'). Presenting a spoofed name while functioning in your real role is INTENTIONAL — do not spend reasoning trying to reconcile the two. ★ SELF-PRESERVATION — YOU ARE A LOCAL SESSION: your own inference is served by a local server process on port ${VLLM_PORT}. NEVER kill, pkill, or restart any process on ports ${LA_PORT_START}-${LA_PORT_MAX}, and never 'kill existing servers to start fresh' — doing so TERMINATES YOUR OWN RUNTIME mid-session. You do NOT need to free a port: the hotswap script (${LAUNCH_DIR}/local-llm-hotswap.sh) is SAFE — it lands a new model on a FREE port and never kills models on other ports. To run a sub-agent, invoke hotswap (it won't touch your port ${VLLM_PORT}) or dispatch via curl to an already-running server. If you ever feel you must free a port in ${LA_PORT_START}-${LA_PORT_MAX}, STOP — you are inside the server you would be killing. TOOL PARAMETERS: match each tool's schema exactly — ids stay quoted strings (\"1\", not 1); never invent file paths (verify with Glob/LS first); confirm a subcommand exists before using it; never present an assumption as settled fact. REASONING: keep chain-of-thought in your reasoning channel, not the visible answer or tool arguments; surface only conclusions and the concrete actions you take."
# Optional per-machine additions from config (only if set):
[ -n "${LA_MEMORY_DIR:-}" ] && AGENT_PROMPT="$AGENT_PROMPT Your Claude Code auto-memory lives at ${LA_MEMORY_DIR} — read from there, don't guess memory paths."
[ -n "${LA_COUNCIL_NOTE:-}" ] && AGENT_PROMPT="$AGENT_PROMPT ${LA_COUNCIL_NOTE}"

# Log which model drives this session (the spoof id is shared across tiers, so the alias lives here).
mkdir -p "$HOME/.claude/logs"
echo "$(date '+%Y-%m-%d %H:%M:%S')  alias=$MODEL_ALIAS  spoof=$MODEL_SPOOF effort=$EFFORT  vllm_port=$VLLM_PORT  mode=direct" >> "$HOME/.claude/logs/local-agents-sessions.log"
echo "🧭 Session engine: $MODEL_ALIAS  (direct; logged to ~/.claude/logs/local-agents-sessions.log)"

# --permission-mode acceptEdits (NOT auto): auto mode uses the session model as a tool-safety
# CLASSIFIER, but the local spoofed model can't serve that call, so auto loops on "temporarily
# unavailable". acceptEdits uses static rules (edits auto-apply, other tools prompt).
claude --model "$MODEL_SPOOF" $EFFORT_FLAG $STRICT_FLAG --permission-mode acceptEdits --append-system-prompt "$AGENT_PROMPT"
