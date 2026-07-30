#!/usr/bin/env bash
# auto-mode-probe.sh — T4-1: the ONE read-only diagnostic that decides whether ANY of
# Action Plan Part 4's approaches (alias / rewrite / patch) are worth building.
#
# QUESTION: when Claude Code runs in Auto Mode against the DIRECT local vllm-mlx endpoint,
# does the safety-classifier request even get EMITTED — and where does it route?
# (Part 4 §12: outcome determines everything downstream.)
#
# This does NOT patch or change the operator. `setup` prints a ready-to-paste local Auto Mode
# launch + benign prompt; `analyze` greps the captured --debug logs for the answer.
#
# Usage:
#   auto-mode-probe.sh setup            # prints the launch command + what to type + what to watch
#   auto-mode-probe.sh analyze [dir]    # greps the debug logs (default /tmp/cc-auto-probe)
set -euo pipefail
DBG="${2:-/tmp/cc-auto-probe}"
PORT="${VLLM_PORT:-8000}"

case "${1:-setup}" in
setup)
  mkdir -p "$DBG"
  cat <<EOF
=== T4-1 Auto Mode classifier probe — SETUP ===
1) Confirm the operator is up:  curl -s localhost:$PORT/v1/models | python3 -m json.tool
2) In a FRESH terminal, launch a DIRECT local Auto Mode session (mirrors the launcher env,
   but permission-mode=auto and --debug, into an isolated debug-log dir):

   CLAUDE_CODE_DEBUG_LOGS_DIR="$DBG" \\
   ANTHROPIC_BASE_URL="http://localhost:$PORT" \\
   ANTHROPIC_AUTH_TOKEN="local" \\
   CLAUDE_CODE_MAX_OUTPUT_TOKENS="8192" \\
   claude --debug --permission-mode auto --model claude-opus-4-8

   NOTE: leave CLAUDE_CODE_ATTRIBUTION_HEADER at its default (issue #64585: setting it to 0
   itself breaks the classifier — don't confound the probe).
3) Type ONE benign consequential action (not covered by an allow rule):
      run this exact command with your tools:  printf 'auto-classifier-probe\\n'
4) Note what happens: does it run? get blocked "cannot determine the safety"? hang?
5) Exit, then run:  $0 analyze "$DBG"
EOF
  ;;
analyze)
  echo "=== analyzing debug logs in $DBG ==="
  if [ ! -d "$DBG" ] || [ -z "$(ls -A "$DBG" 2>/dev/null)" ]; then
    echo "  no logs in $DBG — run '$0 setup' first."; exit 2
  fi
  hit() { grep -rIl "$1" "$DBG" 2>/dev/null | head -1; }
  show() { grep -rIh "$1" "$DBG" 2>/dev/null | head -3 | sed 's/^/      /'; }
  echo "-- Was a classifier request emitted?"
  for m in "classifier_request_started" "source=side_query" "stage=xml_s1" "tengu_auto_mode_config"; do
    if [ -n "$(hit "$m")" ]; then echo "  ✓ '$m' present"; show "$m"; else echo "  ✗ '$m' absent"; fi
  done
  echo "-- Eligibility / gating:"
  for m in "dacEnabled" "cannot determine the safety" "temporarily unavailable" "auto mode"; do
    [ -n "$(hit "$m")" ] && { echo "  ⚠ '$m':"; show "$m"; }
  done
  echo "-- Where did the classifier route (local vs gateway)?"
  grep -rIhoE "https?://[a-zA-Z0-9.:_-]+/v1/(messages|chat)" "$DBG" 2>/dev/null | sort | uniq -c | sed 's/^/      /'
  echo
  echo "INTERPRETATION (Part 4 §12):"
  echo "  - no classifier request + auto unavailable  -> provider/eligibility gate (alias won't help; needs patch or acceptEdits)"
  echo "  - request hits localhost:$PORT with unknown model -> backend ALIAS is promising (Part 4 §15)"
  echo "  - request hits localhost:$PORT, HTTP 200, still blocked -> verdict-FORMAT mismatch (Part 4 §16)"
  echo "  - request routed to the JOYIA GATEWAY host -> hybrid routing still active (and counts vs budget: run the §7 measurement)"
  ;;
*)
  echo "usage: $0 [setup | analyze [debug-dir]]"; exit 1 ;;
esac
