#!/usr/bin/env bash
# tests/lint.sh — static analysis of the shell scripts in bin/.
#
# Runs shellcheck (severity=warning+) over every bin/*.sh. This exists because a
# single-line `local a=x b=$((...a...))` slipped a `set -u` unbound-variable abort into
# wait_ready() (fixed in v0.2.9); shellcheck flags exactly that as SC2318, so this lint
# would have caught it before release. Requires shellcheck (`brew install shellcheck`).
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "SKIP: shellcheck not installed (brew install shellcheck)" >&2
    exit 0   # don't fail the suite just because the linter is absent locally
fi

shopt -s nullglob
scripts=("$BIN"/*.sh)
if [ ${#scripts[@]} -eq 0 ]; then
    echo "no bin/*.sh to lint"; exit 0
fi

echo "shellcheck: linting ${#scripts[@]} script(s) in bin/ (severity=warning)"
if shellcheck --severity=warning "${scripts[@]}"; then
    echo "✓ shellcheck clean"
    exit 0
else
    echo "✗ shellcheck found issues (see above)" >&2
    exit 1
fi
