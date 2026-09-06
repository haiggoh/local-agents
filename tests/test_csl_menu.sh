#!/usr/bin/env bash
# tests/test_csl_menu.sh — deterministic coverage for the interactive csl menu.
#
# Uses a sandboxed HOME, copied config loader, fake model files, and a stub
# launcher. It never reads private configuration, starts a server, opens a
# watcher, or touches a live model.
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

assert_grep() {
  printf '%s' "$2" | grep -qF -- "$1"
  check $? "$3"
}

assert_no_grep() {
  if printf '%s' "$2" | grep -qF -- "$1"; then
    check 1 "$3"
  else
    check 0 "$3"
  fi
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-csl-menu-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT INT TERM HUP

mkdir -p \
  "$SB/bin" \
  "$SB/config" \
  "$SB/home/.models/ModelAlpha" \
  "$SB/home/.models/ModelBeta" \
  "$SB/home/.models/ModelAbsent" \
  "$SB/home/.models/DispatchOnly"

cp "$REPO/bin/csl" "$SB/bin/csl"
cp "$REPO/config/config-lib.sh" "$SB/config/config-lib.sh"

head -c 2097152 /dev/zero > "$SB/home/.models/ModelAlpha/weights.bin"
head -c 2097152 /dev/zero > "$SB/home/.models/ModelBeta/weights.bin"
head -c 2097152 /dev/zero > "$SB/home/.models/DispatchOnly/weights.bin"

cat > "$SB/config/config.local.sh" <<'CSL_TEST_CONFIG'
LA_MODELS_DIR="$HOME/.models"
LA_RAPID_BIN=/nonexistent/rapid-mlx

la_register alpha ModelAlpha rapid qwen "" false claude-opus-5 high
la_register beta ModelBeta vllm qwen qwen3 true claude-opus-5 medium
la_register absent ModelAbsent rapid qwen "" false claude-opus-5 low
la_register dispatch-only DispatchOnly mlx_lm llama "" false claude-haiku-4-5-20251001 low

la_role operator alpha high both
la_role reasoner beta medium both
CSL_TEST_CONFIG

cat > "$SB/bin/stub-launcher" <<'CSL_STUB_LAUNCHER'
#!/usr/bin/env bash
# Record LA_AUTO_MODE too: the menu text is cosmetic, but the value the launcher
# actually receives is the contract, so assert on that.
printf '%s|%s|auto=%s|telemetry=%s\n' "${1:-}" "${2:-}" "${LA_AUTO_MODE:-unset}" "${LA_TELEMETRY:-unset}" > "$CSL_TEST_RESULT"
CSL_STUB_LAUNCHER
chmod +x "$SB/bin/csl" "$SB/bin/stub-launcher"

run_csl() {
  local input="$1"
  local result_file="$2"

  printf '%b' "$input" |
    HOME="$SB/home" \
    CSL_LAUNCHER="$SB/bin/stub-launcher" \
    CSL_TEST_RESULT="$result_file" \
      bash "$SB/bin/csl" 2>&1
}

echo "== 1. primary menu lists every available session model =="
out="$(run_csl 'q\n' "$SB/no-launch")"
assert_grep 'Available models (on disk, session-capable' "$out" \
  'primary menu describes its availability filter'
assert_grep '1) alpha' "$out" 'first on-disk Rapid model is directly listed'
assert_grep '2) beta' "$out" 'second on-disk vllm model is directly listed'
assert_grep 'backend=rapid' "$out" 'menu displays resolved backend'
assert_grep 'thinking=true' "$out" 'menu displays thinking mode'
assert_grep 'effort=medium' "$out" 'menu displays configured effort'
assert_grep 'roles=operator' "$out" 'menu displays role metadata'
assert_no_grep 'absent ' "$out" 'absent model is omitted'
assert_no_grep 'dispatch-only' "$out" 'non-session backend is omitted'
assert_no_grep 'Recommended pairings' "$out" \
  'role recommendations no longer replace the model list'
assert_grep 'watcher: OFF' "$out" 'watcher defaults off'
assert_no_grep 'watcher: ON' "$out" 'watcher is not enabled implicitly'
assert_grep 'auto-mode: ON  — cached startup is quick; cold refresh may take several minutes' "$out"   'auto mode default explains cached and cold startup'
assert_no_grep 'auto-mode: OFF' "$out" 'auto mode is not silently disabled'
assert_grep 'telemetry: OFF' "$out" 'telemetry defaults off (a local session stays local)'
assert_no_grep 'telemetry: ON' "$out" 'telemetry is not silently enabled'
assert_grep 'c) choose a listed model × custom effort' "$out" \
  'custom effort composition remains available'

echo "== 2. numbered choice uses the model default effort =="
rm -f "$SB/default-result"
run_csl '2\n' "$SB/default-result" >/dev/null
assert_grep 'beta|medium' "$(cat "$SB/default-result" 2>/dev/null)" \
  'numbered beta selection launches with configured medium effort'

echo "== 3. custom composition overrides effort explicitly =="
rm -f "$SB/custom-result"
run_csl 'c\n1\n5\n' "$SB/custom-result" >/dev/null
assert_grep 'alpha|max' "$(cat "$SB/custom-result" 2>/dev/null)" \
  'custom composition launches alpha at max effort'

echo "== 4. watcher remains an explicit opt-in =="
out="$(
  printf 'q\n' |
    HOME="$SB/home" \
    CSL_WATCH=1 \
    CSL_LAUNCHER="$SB/bin/stub-launcher" \
    CSL_TEST_RESULT="$SB/watch-result" \
      bash "$SB/bin/csl" 2>&1
)"
assert_grep 'watcher: ON' "$out" 'CSL_WATCH=1 opts in by default'

echo "== 5. auto mode can be opted OUT of by default =="
out="$(
  printf 'q\n' |
    HOME="$SB/home" \
    CSL_AUTO_MODE=0 \
    CSL_LAUNCHER="$SB/bin/stub-launcher" \
    CSL_TEST_RESULT="$SB/auto-off-result" \
      bash "$SB/bin/csl" 2>&1
)"
assert_grep 'auto-mode: OFF — acceptEdits; classifier startup skipped' "$out"   'CSL_AUTO_MODE=0 visibly skips classifier startup'
assert_no_grep 'auto-mode: ON' "$out" 'the opt-out is not overridden by the new default'

echo "== 6. the launcher RECEIVES the auto-mode default, not just the menu text =="
rm -f "$SB/auto-launch-result"
run_csl '1\n' "$SB/auto-launch-result" >/dev/null
assert_grep 'alpha|high|auto=1' "$(cat "$SB/auto-launch-result" 2>/dev/null)" \
  'a default launch hands the launcher LA_AUTO_MODE=1'

echo "== 7. pressing a turns the ON default off, all the way to the launcher =="
rm -f "$SB/auto-toggled-result"
run_csl 'a\n1\n' "$SB/auto-toggled-result" >/dev/null
assert_grep 'alpha|high|auto=0' "$(cat "$SB/auto-toggled-result" 2>/dev/null)" \
  'the a toggle reaches the launcher as LA_AUTO_MODE=0'

echo "== 8. telemetry suppression reaches the launcher, and can be opted back in =="
rm -f "$SB/telemetry-result"
run_csl '1\n' "$SB/telemetry-result" >/dev/null
assert_grep 'telemetry=0' "$(cat "$SB/telemetry-result" 2>/dev/null)" \
  'a default launch hands the launcher LA_TELEMETRY=0'
out="$(
  printf 'q\n' |
    HOME="$SB/home" \
    CSL_TELEMETRY=1 \
    CSL_LAUNCHER="$SB/bin/stub-launcher" \
    CSL_TEST_RESULT="$SB/telemetry-on-result" \
      bash "$SB/bin/csl" 2>&1
)"
assert_grep 'telemetry: ON' "$out" 'CSL_TELEMETRY=1 opts back in by default'

echo "== 9. pressing t flips telemetry, all the way to the launcher =="
rm -f "$SB/telemetry-toggled"
run_csl 't\n1\n' "$SB/telemetry-toggled" >/dev/null
assert_grep 'telemetry=1' "$(cat "$SB/telemetry-toggled" 2>/dev/null)" \
  'the t toggle reaches the launcher as LA_TELEMETRY=1'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
