#!/usr/bin/env bash
# local-watch.sh — discover running LOCAL sessions and emit ready-to-run monitor commands.
#
# Direct routing has NO reasoning tee (the old proxy that fed qwen-reasoning.log is retired), so a
# concurrent cloud session watches a local one via two per-session sources — and this enumerates
# them for MULTIPLE concurrent local sessions at once:
#   • HEALTH (turns / timeouts / stalls / disconnects)  → the per-PORT vllm request log
#       ~/.claude/logs/vllm_<PORT>.log   (one server = one log → clean for N concurrent servers)
#   • MUTATIONS + THINKING (per SESSION)                → the native transcript .jsonl
#       tool_use (Bash/Edit/Write/git/waypoints…) and type:"thinking" blocks (post-turn, not live)
# Post-hoc reasoning of any session:  bin/thinking-log.py --session <id> [--local-only]
#
# Feed the printed `tail … | grep …` lines to your watcher (e.g. Claude Code's Monitor tool, or run
# them in a terminal). This script only DISCOVERS + PRINTS; it does not start anything.
#
# Usage:
#   local-watch.sh              # list running local sessions, active ports, recent transcripts + cmds
#   local-watch.sh --health     # only the vllm-log health monitor command(s), one per active port
#   local-watch.sh --mutations  # only the transcript mutation/thinking monitor command(s)
set -uo pipefail
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
BIN_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$BIN_DIR/../config/config-lib.sh"; la_load_config || exit 1
LOGDIR="$HOME/.claude/logs"; PROJ="$HOME/.claude/projects"
MODE="${1:-list}"

_health_cmd() {  # $1=port
  printf "tail -n0 -f %s/vllm_%s.log | grep --line-buffered -E '\\[REQUEST\\]|last user message preview|CLEANUP done|timed out|timeout|Error|Traceback|Killed|OOM|Exception|EngineBusy|CLIENT DISCONNECTED' | grep --line-buffered -vE 'disconnect_guard poll'\n" "$LOGDIR" "$1"
}
_mut_cmd() {     # $1=transcript path
  printf "tail -n0 -f %s | grep --line-buffered -E '\"type\":\"thinking\"|\"name\":\"(Bash|Edit|Write|NotebookEdit)\"|git (commit|push)|waypoints\\.py (done|edit|add)|installed_plugins|marketplace|rm -|mv '\n" "$1"
}
_active_ports() {
  local p
  for ((p=LA_PORT_START; p<=LA_PORT_MAX; p++)); do
    curl -s --max-time 2 "http://localhost:$p/v1/models" >/dev/null 2>&1 && echo "$p"
  done
}
_model_on() {    # $1=port → the non-spoof model id served (best-effort)
  curl -s --max-time 2 "http://localhost:$1/v1/models" 2>/dev/null \
    | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | grep -v '^claude-' | head -1
}

if [ "$MODE" = "list" ]; then
  echo "▶ Running local launcher sessions (launch-claude-agent.sh):"
  pgrep -fl "launch-claude-agent.sh" 2>/dev/null | grep -v "pgrep\|local-watch" | sed 's/^/  /' || true
  [ -z "$(pgrep -f launch-claude-agent.sh 2>/dev/null | grep -v $$)" ] && echo "  (none)"
  echo
fi

if [ "$MODE" = "list" ] || [ "$MODE" = "--health" ]; then
  echo "▶ HEALTH — active local vllm servers (one monitor per port; safe for N concurrent sessions):"
  ports="$(_active_ports)"
  [ -z "$ports" ] && echo "  (no server on $LA_PORT_START-$LA_PORT_MAX)"
  for p in $ports; do
    echo "  • port $p  (serving: $(_model_on "$p" || echo '?'))"
    echo "      $(_health_cmd "$p")"
  done
  echo
fi

if [ "$MODE" = "list" ] || [ "$MODE" = "--mutations" ]; then
  echo "▶ MUTATIONS + THINKING — recent transcripts (pick the one for your session; newest first):"
  echo "  (a local session's transcript is written to its cwd-slug dir; correlate by mtime/activity.)"
  # shellcheck disable=SC2012
  ls -t "$PROJ"/*/*.jsonl 2>/dev/null | head -6 | while IFS= read -r t; do
    echo "  • $(basename "$t")   ($(date -r "$t" +%H:%M:%S 2>/dev/null))"
    echo "      $(_mut_cmd "$t")"
  done
  echo
  echo "▶ POST-HOC reasoning (chain-of-thought after the fact; --local-only = unsigned/local blocks):"
  echo "      $BIN_DIR/thinking-log.py --latest --local-only"
fi
