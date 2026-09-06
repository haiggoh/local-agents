#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"

# shellcheck source=/dev/null
. "$REPO/config/config-lib.sh"

PASS=0
FAIL=0

check() {
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$2"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "$2"
  fi
}

actual="$(
  unset LA_AUTO_MODE_SEGMENTED_TRANSCRIPT
  unset CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT
  la_configure_auto_mode_env 1
  printf '%s' "${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-unset}"
)"
[ "$actual" = "1" ]
check $? "Auto Mode enables segmented transcripts by default"

actual="$(
  unset CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT
  LA_AUTO_MODE_SEGMENTED_TRANSCRIPT=0
  la_configure_auto_mode_env 1
  printf '%s' "${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-unset}"
)"
[ "$actual" = "0" ]
check $? "one-launch opt-out reaches Claude Code"

actual="$(
  LA_AUTO_MODE_SEGMENTED_TRANSCRIPT=1
  CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1
  la_configure_auto_mode_env 0
  printf '%s' "${CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT:-unset}"
)"
[ "$actual" = "unset" ]
check $? "acceptEdits launch does not inherit the Auto Mode experiment"

(
  LA_AUTO_MODE_SEGMENTED_TRANSCRIPT=invalid
  la_configure_auto_mode_env 1
) >/dev/null 2>&1
[ "$?" -eq 2 ]
check $? "invalid control fails closed"

grep -qF 'la_configure_auto_mode_env "$LA_AUTO_MODE"' \
  "$REPO/bin/launch-claude-agent.sh"
check $? "real launcher calls the tested helper"

grep -qF 'CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT' \
  "$REPO/config/config-lib.sh"
check $? "tested helper owns the client-facing variable"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
