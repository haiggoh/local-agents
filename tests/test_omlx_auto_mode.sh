#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
LAUNCHER="$REPO/bin/launch-claude-agent-omlx.sh"
MAIN="$REPO/bin/launch-claude-agent.sh"

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

out="$("$LAUNCHER" --self-test 2>&1)"
[ "$out" = "OMLX_AUTO_LAUNCHER_SELF_TEST_OK" ]
check $? "oMLX launcher self-test"

grep -qF 'LA_AUTO_MODE_RUNTIME:=rapid' "$MAIN"
check $? "Rapid remains the generic launcher default"

grep -qF 'launch-claude-agent-omlx.sh' "$MAIN"
check $? "main launcher has an oMLX Auto Mode dispatch"

grep -qF 'claude-sonnet-5' "$LAUNCHER"
check $? "classifier compatibility ID is explicit"

grep -qF -- '--paged-ssd-cache-dir' "$LAUNCHER"
check $? "persistent paged prefix cache is enabled"

grep -qF -- '--hot-cache-write-through' "$LAUNCHER"
check $? "hot cache writes through to persistent cache"

grep -qF 'CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1' "$LAUNCHER"
check $? "segmented transcript reaches Claude Code"

grep -qF 'ANTHROPIC_BASE_URL=' "$LAUNCHER"
check $? "Claude Code is routed to the isolated oMLX endpoint"

grep -qF 'LA_OMLX_DRY_RUN' "$LAUNCHER"
check $? "integration can be validated without starting a server"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
