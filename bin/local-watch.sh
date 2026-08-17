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
#   local-watch.sh --open       # actually OPEN a Terminal window per running local session (two panes'
#                               # worth: engine health for its port + mutations for its transcript).
#                               # With several sessions running you get a set per session, so watching
#                               # two at once needs no manual bookkeeping.
set -uo pipefail
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
BIN_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$BIN_DIR/../config/config-lib.sh"; la_load_config || exit 1
LOGDIR="$HOME/.claude/logs"; PROJ="$HOME/.claude/projects"
MODE="${1:-list}"

_health_cmd() {  # $1=port
  # Includes the KV-cache / prefill / throughput lines: for an OPERATOR (thinking off) these are the
  # substitute for watching reasoning. They tell you which phase a long turn is in — 'cache MISS' or
  # 'prefilling N new tokens' means it is still reading the prompt and has generated nothing yet,
  # while 'N tokens in Ts (X tok/s)' is the only place the real generation rate appears.
  printf "tail -n0 -f %s/vllm_%s.log | grep --line-buffered -E '\\[REQUEST\\]|last user message preview|cache (HIT|MISS|SKIP)|prefilling|tokens in .*tok/s|CLEANUP done|TIMEOUT after|timed out|timeout|Error|Traceback|Killed|OOM|Exception|EngineBusy|CLIENT DISCONNECTED' | grep --line-buffered -vE 'disconnect_guard poll'\n" "$LOGDIR" "$1"
}
# Which transcript is a given local session actually writing? Correlate instead of guessing: the
# launcher's `claude` child holds the .jsonl open, so lsof names it exactly. Beats sorting by mtime,
# which picks whichever session wrote last — often the wrong one when two are running (and, from a
# supervising cloud session, usually that session's own transcript).
_transcript_for_pid() {  # $1 = pid of a claude process
  lsof -p "$1" 2>/dev/null | grep -o "$PROJ/[^ ]*\.jsonl" | head -1
}
_launcher_sessions() {   # -> "pid<TAB>alias" per running launcher
  pgrep -fl "launch-claude-agent.sh" 2>/dev/null \
    | grep -v "pgrep\|local-watch" \
    | awk '{pid=$1; alias=$NF; print pid "\t" alias}'
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

# --open: stop printing commands for the user to paste and just start the watchers. One Terminal
# window per running session, so N concurrent sessions need no manual pairing of port to transcript.
if [ "$MODE" = "--open" ]; then
  _n=0
  while IFS="$(printf '\t')" read -r _pid _alias; do
    [ -n "${_pid:-}" ] || continue
    _cpid=$(pgrep -P "$_pid" 2>/dev/null | head -1)
    _tr=""; [ -n "$_cpid" ] && _tr=$(_transcript_for_pid "$_cpid")
    [ -z "$_tr" ] && _tr=$(_transcript_for_pid "$_pid")
    # The port this session talks to is recorded by the launcher at startup; last line for this alias.
    _port=$(grep "alias=$_alias " "$HOME/.claude/logs/local-agents-sessions.log" 2>/dev/null \
            | tail -1 | grep -o "vllm_port=[0-9]*" | cut -d= -f2)
    [ -z "$_port" ] && _port="$LA_PORT_START"
    _cmd="echo '=== local-watch: $_alias (pid $_pid, port $_port) ==='; $(_health_cmd "$_port")"
    [ -n "$_tr" ] && _cmd="$_cmd & $(_mut_cmd "$_tr"); wait"
    osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "$(printf '%s' "$_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
end tell
OSA
    _n=$((_n+1))
    echo "✓ Opened a watcher window for '$_alias' (pid $_pid, port $_port)"
    [ -n "$_tr" ] && echo "    transcript: $_tr" || echo "    transcript: not resolvable yet (engine health only)"
  done <<EOF
$(_launcher_sessions)
EOF
  if [ "$_n" -eq 0 ]; then
    echo "No running local session found (nothing to open)."
    echo "Start one with csl, then re-run: local-watch.sh --open"
  fi
  exit 0
fi

if [ "$MODE" = "list" ]; then
  echo "▶ Running local launcher sessions (launch-claude-agent.sh):"
  _found=0
  while IFS="$(printf '\t')" read -r _pid _alias; do
    [ -n "${_pid:-}" ] || continue
    _found=1
    # The launcher exec's/holds `claude` as a child; that child owns the transcript file handle.
    _cpid=$(pgrep -P "$_pid" 2>/dev/null | head -1)
    _tr=""
    [ -n "$_cpid" ] && _tr=$(_transcript_for_pid "$_cpid")
    [ -z "$_tr" ] && _tr=$(_transcript_for_pid "$_pid")
    echo "  • pid $_pid  alias=$_alias"
    if [ -n "$_tr" ]; then
      echo "      transcript (correlated, not guessed): $_tr"
      echo "      $(_mut_cmd "$_tr")"
    else
      echo "      transcript: not resolvable yet (session still starting, or claude not yet writing)"
    fi
  done <<EOF
$(_launcher_sessions)
EOF
  [ "$_found" -eq 0 ] && echo "  (none running — the sections below still work on past sessions)"
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
  echo "▶ MUTATIONS + THINKING — recent transcripts (newest first; for a RUNNING session prefer the"
  echo "  correlated path printed above, which is exact — these are for past or not-yet-started ones):"
  # shellcheck disable=SC2012
  ls -t "$PROJ"/*/*.jsonl 2>/dev/null | head -6 | while IFS= read -r t; do
    echo "  • $(basename "$t")   ($(date -r "$t" +%H:%M:%S 2>/dev/null))"
    echo "      $(_mut_cmd "$t")"
  done
  echo
  echo "▶ POST-HOC reasoning (chain-of-thought after the fact; --local-only = unsigned/local blocks):"
  echo "      $BIN_DIR/thinking-log.py --latest --local-only"
fi
