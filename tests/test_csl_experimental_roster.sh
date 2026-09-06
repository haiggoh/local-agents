#!/usr/bin/env bash
# tests/test_csl_experimental_roster.sh — visibility and disk-filter contract.
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

assert_has() {
    printf '%s' "$2" | grep -qF -- "$1"
    check $? "$3"
}

assert_lacks() {
    if printf '%s' "$2" | grep -qF -- "$1"; then
        check 1 "$3"
    else
        check 0 "$3"
    fi
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-csl-experimental.XXXXXX")"
trap 'rm -rf "$SB"' EXIT INT TERM HUP

mkdir -p \
    "$SB/bin" \
    "$SB/config" \
    "$SB/home/.models/StableModel" \
    "$SB/home/.models/ExperimentalModel" \
    "$SB/home/.models/DeletedModel" \
    "$SB/home/.models/Kokoro-TTS" \
    "$SB/home/.models/Qwen-MTP-Sidecar"

cp "$REPO/bin/csl" "$SB/bin/csl"
cp "$REPO/config/config-lib.sh" "$SB/config/config-lib.sh"

head -c 2097152 /dev/zero \
    >"$SB/home/.models/StableModel/model.safetensors"
head -c 2097152 /dev/zero \
    >"$SB/home/.models/ExperimentalModel/model.safetensors"
head -c 2097152 /dev/zero \
    >"$SB/home/.models/Kokoro-TTS/model.safetensors"
head -c 2097152 /dev/zero \
    >"$SB/home/.models/Qwen-MTP-Sidecar/model.safetensors"

cat >"$SB/config/config.local.sh" <<'CONFIG'
LA_MODELS_DIR="$HOME/.models"
LA_RAPID_BIN=/nonexistent/rapid-mlx

la_register stable StableModel rapid qwen "" false claude-opus-5 high "" "" "" qualified
la_register experimental ExperimentalModel rapid auto "" false claude-opus-5 high "" "" "" experimental
la_register deleted DeletedModel rapid auto "" false claude-opus-5 high "" "" "" experimental
CONFIG

cat >"$SB/bin/stub-launcher" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${1:-}" "${2:-}" >"$CSL_TEST_RESULT"
STUB

chmod +x "$SB/bin/csl" "$SB/bin/stub-launcher"

run_menu() {
    printf 'q\n' |
        HOME="$SB/home" \
        CSL_LAUNCHER="$SB/bin/stub-launcher" \
        CSL_TEST_RESULT="$SB/result" \
        bash "$SB/bin/csl" 2>&1
}

echo "== registered on-disk candidates are visible with status =="
menu="$(run_menu)"
assert_has 'stable' "$menu" 'qualified model appears'
assert_has 'status=qualified' "$menu" 'qualified status appears'
assert_has 'experimental' "$menu" 'experimental model appears'
assert_has 'status=experimental' "$menu" 'experimental status appears'

echo "== registered model without payload is omitted =="
assert_lacks 'deleted ' "$menu" 'deleted payload disappears automatically'

echo "== unregistered non-LLMs and sidecars remain excluded =="
assert_lacks 'Kokoro-TTS' "$menu" 'unregistered TTS artifact is excluded'
assert_lacks 'Qwen-MTP-Sidecar' "$menu" 'unregistered MTP sidecar is excluded'

echo "== deleting an experimental payload removes it from the next menu =="
rm -f "$SB/home/.models/ExperimentalModel/model.safetensors"
menu_after_delete="$(run_menu)"
assert_lacks 'experimental ' "$menu_after_delete" \
    'experimental alias disappears after its weight payload is deleted'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
