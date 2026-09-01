#!/usr/bin/env bash
# tests/test_session_profiles.sh — model-specific csl auto-compaction.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"

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

assert_eq() {
  if [ "$1" = "$2" ]; then
    check 0 "$3"
  else
    printf '     expected: %s\n     actual:   %s\n' "$1" "$2"
    check 1 "$3"
  fi
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-session-profile-test.XXXXXX")"
SB="$(cd -P "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT INT TERM HUP

mkdir -p \
  "$SB/bin" \
  "$SB/config" \
  "$SB/home/.models/Alpha" \
  "$SB/home/.models/Ornith"

cp "$REPO/bin/csl" "$SB/bin/csl"
cp "$REPO/config/config-lib.sh" "$SB/config/config-lib.sh"

head -c 2097152 /dev/zero > "$SB/home/.models/Alpha/weights.bin"
head -c 2097152 /dev/zero > "$SB/home/.models/Ornith/weights.bin"

cat > "$SB/config/config.local.sh" <<'CFG'
LA_MODELS_DIR="$HOME/.models"
LA_RAPID_BIN=/nonexistent/rapid-mlx

la_register alpha Alpha rapid qwen "" false claude-opus-5 high
la_register ornith-1.5-35b Ornith rapid hermes "" false claude-opus-5 high

LA_SESSION_AUTO_COMPACT["ornith-1.5-35b"]=200k
CFG

cat > "$SB/bin/stub-launcher" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' \
  "${1:-}" \
  "${2:-}" \
  "${LA_AUTO_COMPACT_WINDOW:-}" > "$CSL_TEST_RESULT"
STUB

chmod +x "$SB/bin/csl" "$SB/bin/stub-launcher"

run_csl() {
  local input="$1"
  local result="$2"
  shift 2

  printf '%b' "$input" |
    env -u LA_AUTO_COMPACT_WINDOW \
      HOME="$SB/home" \
      CSL_LAUNCHER="$SB/bin/stub-launcher" \
      CSL_TEST_RESULT="$result" \
      bash "$SB/bin/csl" "$@" 2>&1
}

echo "== interactive Ornith selection applies 200k =="
run_csl '2\n' "$SB/ornith-interactive" >/dev/null
assert_eq \
  'ornith-1.5-35b|high|200k' \
  "$(cat "$SB/ornith-interactive")" \
  'interactive Ornith receives 200k'

echo "== direct csl Ornith launch applies 200k =="
run_csl '' "$SB/ornith-direct" ornith-1.5-35b high >/dev/null
assert_eq \
  'ornith-1.5-35b|high|200k' \
  "$(cat "$SB/ornith-direct")" \
  'direct csl Ornith receives 200k'

echo "== unprofiled model receives no override =="
run_csl '1\n' "$SB/alpha" >/dev/null
assert_eq \
  'alpha|high|' \
  "$(cat "$SB/alpha")" \
  'non-Ornith model receives no auto-compaction override'

echo "== custom effort retains selected-model profile =="
run_csl 'c\n2\n5\n' "$SB/ornith-custom" >/dev/null
assert_eq \
  'ornith-1.5-35b|max|200k' \
  "$(cat "$SB/ornith-custom")" \
  'custom-effort Ornith receives 200k'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
