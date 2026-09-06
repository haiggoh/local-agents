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

grep -qF -- '--base-path "$base_root"' "$LAUNCHER"
check $? "session server uses an isolated oMLX base path"

grep -qF -- '--no-hf-cache' "$LAUNCHER"
check $? "session server ignores unrelated Hugging Face cache models"

grep -qF 'CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1' "$LAUNCHER"
check $? "segmented transcript reaches Claude Code"

grep -qF 'ANTHROPIC_BASE_URL=' "$LAUNCHER"
check $? "Claude Code is routed to the isolated oMLX endpoint"

grep -qF 'LA_OMLX_DRY_RUN' "$LAUNCHER"
check $? "integration can be validated without starting a server"

echo "== real dry-run behavior with a sandboxed registry =="

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-omlx-dry-run.XXXXXX")"
trap 'rm -rf "$SB"' EXIT INT TERM HUP

mkdir -p \
    "$SB/bin" \
    "$SB/config" \
    "$SB/home/.models/SessionModel" \
    "$SB/home/.models/ClassifierModel"

cp "$LAUNCHER" "$SB/bin/launch-claude-agent-omlx.sh"
cp "$REPO/config/config-lib.sh" "$SB/config/config-lib.sh"

printf '{}\n' > "$SB/home/.models/SessionModel/config.json"
printf '{}\n' > "$SB/home/.models/ClassifierModel/config.json"

cat > "$SB/config/config.local.sh" <<'OMLX_TEST_CONFIG'
LA_MODELS_DIR="$HOME/.models"

la_register \
    alpha \
    SessionModel \
    rapid \
    qwen \
    "" \
    false \
    claude-opus-5 \
    high
OMLX_TEST_CONFIG

dry_run="$(
    HOME="$SB/home" \
    LA_OMLX_BIN=/usr/bin/true \
    LA_OMLX_CLASSIFIER_MODEL_DIR="$SB/home/.models/ClassifierModel" \
    LA_OMLX_DRY_RUN=1 \
    CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1 \
        bash "$SB/bin/launch-claude-agent-omlx.sh" alpha high 2>&1
)"
dry_status=$?

[ "$dry_status" -eq 0 ]
check $? "sandboxed oMLX dry run completes"

printf '%s' "$dry_run" |
    grep -qF "session_model_dir=$SB/home/.models/SessionModel"
check $? "oMLX launcher uses the resolved LA_CUR_DIR"

printf '%s' "$dry_run" |
    grep -qF 'session_model_id=claude-opus-5'
check $? "session compatibility model ID is preserved"

printf '%s' "$dry_run" |
    grep -qF 'classifier_model_id=claude-sonnet-5'
check $? "classifier compatibility model ID is preserved"

printf '%s' "$dry_run" |
    grep -qF 'segmented=1'
check $? "segmented transcript reaches the dry-run contract"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
