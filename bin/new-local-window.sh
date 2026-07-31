#!/usr/bin/env bash
# new-local-window.sh — open a local session in a NEW, INDEPENDENT Terminal window (macOS).
#
# The window is owned by Terminal.app, not by whatever shell/agent launched it, so the local
# session keeps running even if you close this terminal or restart a Claude Code session. The
# vllm-mlx server is already an independent background process; the new window just starts an
# interactive `claude` that connects to it.
#
# Usage:  new-local-window.sh <alias> [effort]     e.g. new-local-window.sh qwen-3.6-operator
set -uo pipefail
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
DIR="$(cd -P "$(dirname "$_s")" && pwd)"
LAUNCHER="$DIR/launch-claude-agent.sh"

if [ "$#" -lt 1 ]; then echo "Usage: $0 <alias> [effort]"; exit 1; fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This helper uses macOS Terminal.app. On Linux, run '$LAUNCHER $*' in your terminal emulator."; exit 1
fi
ARGS="$*"
# Launch in a fresh Terminal window. do script runs in its own shell, independent of this process.
osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "'$LAUNCHER' $ARGS"
end tell
OSA
echo "✓ Opened an independent Terminal window running: launch-claude-agent.sh $ARGS"
echo "  (it survives closing this terminal / restarting a Claude Code session)"
