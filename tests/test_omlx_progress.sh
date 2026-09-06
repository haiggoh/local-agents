#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
PROGRESS="$REPO/bin/omlx-progress.sh"

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

echo "== line-mode progress =="

line_output="$(
    bash "$PROGRESS" --self-test-line 2>&1
)"
line_status=$?

[ "$line_status" -eq 0 ]
check $? "line-mode self-test completes"

printf '%s' "$line_output" |
    grep -qF 'Starting isolated oMLX server'
check $? "line mode names the initial stage"

printf '%s' "$line_output" |
    grep -qF 'Discovering session and classifier models'
check $? "line mode reports intermediate progress"

printf '%s' "$line_output" |
    grep -qF 'Progress renderer ready'
check $? "line mode leaves a success line"

printf '%s' "$line_output" |
    grep -qF 'Testing bounded process progress'
check $? "line mode runs a bounded child command"

case "$line_output" in
    *$'\033'*)
        check 1 "line mode contains no terminal control sequences"
        ;;
    *)
        check 0 "line mode contains no terminal control sequences"
        ;;
esac

echo "== forced TTY rendering =="

tty_output="$(
    bash "$PROGRESS" --self-test-tty 2>&1
)"
tty_status=$?

[ "$tty_status" -eq 0 ]
check $? "TTY-mode self-test completes"

case "$tty_output" in
    *$'\033'*)
        check 0 "TTY mode emits in-place control sequences"
        ;;
    *)
        check 1 "TTY mode emits in-place control sequences"
        ;;
esac

printf '%s' "$tty_output" |
    grep -qF '⠋'
check $? "TTY mode emits a spinner frame"

echo "== long-running reassurance =="

reassurance="$(
    bash "$PROGRESS" --self-test-reassurance 2>&1
)"
reassurance_status=$?

[ "$reassurance_status" -eq 0 ]
check $? "reassurance self-test completes"

printf '%s' "$reassurance" |
    grep -qF 'first genuine classifier prefill can take several minutes'
check $? "long startup explains the expected delay"

printf '%s' "$reassurance" |
    grep -qF 'Future launches can reuse'
check $? "long startup explains future cached reuse"

echo "== sourced behavior and invalid mode =="

# shellcheck source=/dev/null
. "$PROGRESS"

LA_PROGRESS_MODE=invalid
la_progress_mode >/dev/null 2>&1
invalid_status=$?

[ "$invalid_status" -eq 2 ]
check $? "invalid progress mode fails closed"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
