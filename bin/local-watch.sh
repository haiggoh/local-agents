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
#   local-watch.sh              # DEFAULT: open a watcher window per running local session (engine
#                               # health for its port + mutations for its transcript). With several
#                               # sessions running you get one per session, so watching two at once
#                               # needs no manual bookkeeping. If NOTHING is running there is nothing
#                               # to watch, so it falls back to the listing below rather than doing
#                               # nothing — "watch my session" is the reason you ran this, and it
#                               # should not require remembering a flag.
#   local-watch.sh --list       # print-only: sessions, active ports, transcripts + monitor commands
#   local-watch.sh --open       # force the open behaviour (explicit form of the default)
#   local-watch.sh --health     # only the vllm-log health monitor command(s), one per active port
#   local-watch.sh --mutations  # only the transcript mutation/thinking monitor command(s)
#   local-watch.sh --attach <pid>
#                               # FOLLOW one specific session, starting before it is ready. Used by
#                               # csl's watcher toggle: it is spawned at launch time, waits for that
#                               # session's port sidecar (immediate) and transcript sidecar (written
#                               # on turn 1), then tails engine health + mutations for it alone.
set -uo pipefail
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
BIN_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$BIN_DIR/../config/config-lib.sh"; la_load_config || exit 1
LOGDIR="$HOME/.claude/logs"; PROJ="$HOME/.claude/projects"
MODE="${1:-}"
# Bare invocation means "watch what's running". Resolve that to --open when there IS something to
# watch, and to the listing when there isn't, so the useful thing happens without a remembered flag.
if [ -z "$MODE" ]; then
  if pgrep -f "launch-claude-agent.sh" >/dev/null 2>&1; then MODE="--open"; else MODE="list"; fi
fi
[ "$MODE" = "--list" ] && MODE="list"

_health_cmd() {  # $1=port
  # Includes the KV-cache / prefill / throughput lines: for an OPERATOR (thinking off) these are the
  # substitute for watching reasoning. They tell you which phase a long turn is in — 'cache MISS' or
  # 'prefilling N new tokens' means it is still reading the prompt and has generated nothing yet,
  # while 'N tokens in Ts (X tok/s)' is the only place the real generation rate appears.
  printf "tail -n0 -f %s/vllm_%s.log | grep --line-buffered -E '\\[REQUEST\\]|last user message preview|cache (HIT|MISS|SKIP)|prefilling|tokens in .*tok/s|CLEANUP done|TIMEOUT after|timed out|timeout|Error|Traceback|Killed|OOM|Exception|EngineBusy|CLIENT DISCONNECTED' | grep --line-buffered -vE 'disconnect_guard poll'\n" "$LOGDIR" "$1"
}
# Which transcript is a given local session actually writing? READ it, do not infer it.
#
# CORRECTED 2026-08-18. The previous implementation asked lsof for the .jsonl handle held by the
# launcher's `claude` child. That can never work: Claude Code appends to the transcript and CLOSES
# it, so a live `claude` shows ZERO jsonl handles (measured across repeated samples on a running
# session). The result was that every running session — the main use case — printed "not resolvable
# yet", blaming startup timing for a design flaw.
#
# Two tempting replacements are also wrong, and both were tested:
#   • newest-mtime: picks whichever session wrote last, which from a supervising cloud session is
#     usually that session's OWN transcript.
#   • content-matching the vllm log's user-message preview: watching a log copies the watched
#     session's prompts INTO the watcher's transcript, so the watcher matches itself. Verified: the
#     latest-preview probe returned the supervising session and missed the real one.
# Claude Code also exposes no session id on the process and has no --session-id flag for a new
# session, so there is nothing to read off the process either.
#
# So the launcher records it: launch-claude-agent.sh watches for the transcript appearing in its own
# project dir after its own start (it is the one uncontaminated observer) and writes the path to a
# sidecar keyed by its pid. This function just reads that.
_transcript_for_launcher() {  # $1 = launcher pid
  local sc="$LOGDIR/local-agents-session-$1.transcript" t
  [ -s "$sc" ] || return 1
  t=$(head -1 "$sc" 2>/dev/null)
  [ -n "$t" ] && [ -f "$t" ] && printf '%s\n' "$t"
}

# Fallback only: plausible transcripts for a session whose sidecar is not there yet (a session
# started before this version, or one that has not taken its first turn). Narrowed by the claude
# process's real cwd, so at least the project dir is right. Reported as CANDIDATES, never as a fact.
_transcript_candidates() {  # $1 = claude pid
  local cwd proj
  cwd=$(lsof -p "$1" 2>/dev/null | awk '$4=="cwd"{print $NF; exit}')
  [ -n "$cwd" ] || return 1
  proj="$PROJ/$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')"
  [ -d "$proj" ] || return 1
  # shellcheck disable=SC2012
  ls -t "$proj"/*.jsonl 2>/dev/null | head -3
}
_launcher_sessions() {   # -> "pid<TAB>alias" per running launcher
  # The alias is the argument AFTER the script path — NOT the last field. csl launches presets as
  # `launch-claude-agent.sh <alias> <effort>`, so $NF is the effort override on every menu-started
  # session, which would then miss the sessions log and fall back to the wrong port.
  pgrep -fl "launch-claude-agent.sh" 2>/dev/null \
    | grep -v "pgrep\|local-watch" \
    | awk '{
        pid=$1; alias="";
        for (i=2; i<=NF; i++) if ($i ~ /launch-claude-agent\.sh$/) { if (i+1<=NF) alias=$(i+1); break }
        if (alias != "") print pid "\t" alias
      }'
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

# --attach <pid>: follow ONE session, tolerating that it is not ready yet.
# csl spawns this the moment it launches a session, so neither sidecar exists at first. The port
# lands immediately; the transcript only exists once the session takes its first turn (which on a
# local model can be minutes). So: start health as soon as the port is known, and fold in mutations
# whenever the transcript shows up, instead of refusing to start.
if [ "$MODE" = "--attach" ]; then
  _apid="${2:-}"
  case "$_apid" in ''|*[!0-9]*) echo "Usage: local-watch.sh --attach <launcher-pid>"; exit 1;; esac
  _pfile="$LOGDIR/local-agents-session-$_apid.port"
  _tfile="$LOGDIR/local-agents-session-$_apid.transcript"
  printf '=== local-watch --attach: following session pid %s ===\n' "$_apid"
  _port=""
  for _i in $(seq 1 60); do
    [ -s "$_pfile" ] && { _port=$(head -1 "$_pfile"); break; }
    kill -0 "$_apid" 2>/dev/null || { echo "session pid $_apid exited before publishing a port."; exit 0; }
    sleep 1
  done
  if [ -z "$_port" ]; then
    echo "No port sidecar after 60s ($_pfile)."
    echo "If this session was started by an older local-agents, relaunch it or use: local-watch.sh --list"
    exit 1
  fi
  printf 'engine health: port %s\n' "$_port"
  eval "$(_health_cmd "$_port")" &
  _hpid=$!
  # Fold in mutations when the transcript appears; keep health running either way.
  (
    for _j in $(seq 1 600); do
      if [ -s "$_tfile" ]; then
        _t=$(head -1 "$_tfile")
        if [ -n "$_t" ] && [ -f "$_t" ]; then
          printf '\n=== transcript now recorded: %s ===\n' "$_t"
          eval "$(_mut_cmd "$_t")"
          exit 0
        fi
      fi
      kill -0 "$_apid" 2>/dev/null || exit 0
      sleep 2
    done
  ) &
  _mpid=$!
  # Leave with the session: when the launcher exits, stop tailing.
  ( while kill -0 "$_apid" 2>/dev/null; do sleep 5; done
    printf '\n=== session pid %s exited — watcher stopping ===\n' "$_apid"
    kill "$_hpid" "$_mpid" 2>/dev/null ) &
  wait "$_hpid" 2>/dev/null
  exit 0
fi

# --open: stop printing commands for the user to paste and just start the watchers. One Terminal
# window per running session, so N concurrent sessions need no manual pairing of port to transcript.
if [ "$MODE" = "--open" ]; then
  _n=0
  while IFS="$(printf '\t')" read -r _pid _alias; do
    [ -n "${_pid:-}" ] || continue
    _cpid=$(pgrep -P "$_pid" 2>/dev/null | head -1)
    _tr=$(_transcript_for_launcher "$_pid" || true)
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
    if [ -n "$_tr" ]; then
      echo "    transcript: $_tr"
    else
      echo "    transcript: no sidecar yet — engine health only. The launcher writes"
      echo "      $LOGDIR/local-agents-session-$_pid.transcript once this session takes its first turn."
    fi
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
    _tr=$(_transcript_for_launcher "$_pid" || true)
    echo "  • pid $_pid  alias=$_alias"
    if [ -n "$_tr" ]; then
      echo "      transcript (recorded by the launcher, not guessed): $_tr"
      echo "      $(_mut_cmd "$_tr")"
    else
      echo "      transcript: NOT RECORDED — no sidecar at"
      echo "        $LOGDIR/local-agents-session-$_pid.transcript"
      echo "      Either this session started before local-agents 0.9.0, or it has not taken its"
      echo "      first turn yet (the .jsonl is created on turn 1, not at startup)."
      _cands=$([ -n "$_cpid" ] && _transcript_candidates "$_cpid" || true)
      if [ -n "$_cands" ]; then
        echo "      CANDIDATES in this session's project dir (newest first) — unverified, pick by content:"
        printf '%s\n' "$_cands" | while IFS= read -r _c; do echo "        $_c"; done
      fi
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
