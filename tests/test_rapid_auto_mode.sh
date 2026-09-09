#!/usr/bin/env bash
# Deterministic tests for the dedicated Rapid Auto Mode launcher.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
LAUNCHER="$REPO/bin/launch-claude-agent-rapid-auto.sh"
MAIN="$REPO/bin/launch-claude-agent.sh"
GATE="$REPO/bin/omlx-auto-prewarm-gate.sh"
CONFIG_LIB="$REPO/config/config-lib.sh"
PROGRESS="$REPO/bin/omlx-progress.sh"
HELPER="$REPO/bin/omlx-auto-prewarm.py"
PROMPT="$REPO/config/local-agent-system-prompt.txt"

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
[ "$out" = "RAPID_AUTO_LAUNCHER_SELF_TEST_OK" ]
check $? "Rapid Auto Mode launcher self-test"

if grep -qF 'launch-claude-agent-rapid-auto.sh' "$MAIN"; then
    check 1 "main launcher remains unwired before live smoke qualification"
else
    check 0 "main launcher remains unwired before live smoke qualification"
fi

grep -qF 'serve "$LA_RAPID_AUTO_CLASSIFIER_MODEL_ID"' "$LAUNCHER"
check $? "classifier identity is Rapid model argument"

grep -qF -- '--served-model-name "$SESSION_MODEL_ID"' "$LAUNCHER"
check $? "session identity is Rapid served model name"

grep -qF 'LA_OMLX_PREWARM_FIXTURE_ROOT="$LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT"' "$LAUNCHER"
check $? "Rapid uses its own classifier fixture namespace"

grep -qF 'HOME="$rapid_home"' "$LAUNCHER"
check $? "Rapid child receives isolated persistent HOME"

grep -qF 'HF_HOME="$hf_home"' "$LAUNCHER"
check $? "Rapid child receives temporary Hugging Face home"

grep -qF 'HF_HUB_OFFLINE=1' "$LAUNCHER"
check $? "Rapid child is forbidden from downloading model files"

grep -qF 'export ANTHROPIC_AUTH_TOKEN=local' "$LAUNCHER"
check $? "launcher cannot inherit a cloud authentication token"

grep -qF 'unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL' "$LAUNCHER"
check $? "launcher removes inherited cloud gateway variables"

grep -qF 'la_omlx_readiness_gate' "$LAUNCHER"
check $? "Rapid launcher reuses fail-closed readiness gate"

grep -qF '_request_allows_trimmed_closing' "$HELPER"
check $? "shared helper contains request-aware verdict validation"

grep -qF 'LA_AUTO_MODE_BACKEND_LABEL' "$GATE"
check $? "shared readiness gate labels its active backend"

grep -qF 'classifier-identity-request.json' "$LAUNCHER"
check $? "launcher probes hidden Sonnet identity before readiness"

grep -qF 'local-agents-rapid-auto-owned' "$LAUNCHER"
check $? "runtime cleanup requires an ownership marker"

grep -qF 'refusing symlinked Rapid Auto Mode root' "$LAUNCHER"
check $? "launcher rejects symlinked persistent roots"

grep -qF 'ensure_private_rapid_root "$LA_RAPID_AUTO_PREWARM_FIXTURE_ROOT"' "$LAUNCHER"
check $? "launcher secures the Rapid fixture root before use"

grep -qF 'must be a strict descendant' "$LAUNCHER"
check $? "launcher confines persistent roots below the local-agents cache base"

grep -qF 'model directory must not be a symlink' "$LAUNCHER"
check $? "launcher rejects a symlinked qualified model root"

grep -qF 'PY_MODEL_PROCESSES' "$LAUNCHER"
check $? "launcher uses a self-match-safe model-process gate"

grep -qF 'LA_RAPID_AUTO_MODEL_DIR' "$CONFIG_LIB"
check $? "config library exposes qualified Rapid Auto Mode model"

grep -qF 'rapid-mlx 0.13.4' "$LAUNCHER"
check $? "launcher pins the qualified Rapid version"

grep -qF 'requires a non-thinking session alias' "$LAUNCHER"
check $? "launcher rejects unqualified thinking aliases"

grep -qF 'requires classifier ID claude-sonnet-5' "$LAUNCHER"
check $? "launcher pins the qualified classifier identity"

grep -qF -- '--autocompact "$LA_AUTO_COMPACT_WINDOW"' "$LAUNCHER"
check $? "launcher preserves native Claude autocompaction option"

grep -qF 'must be between 1 and 65535' "$LAUNCHER"
check $? "launcher validates the dedicated port range"

grep -qF 'must be at least 8000' "$LAUNCHER"
check $? "launcher preserves the qualified classifier cache floor"

grep -qF 'local-agent-system-prompt.txt' "$LAUNCHER"
check $? "launcher preserves the maintained local-agent prompt"

grep -qF 'OPT-IN QUALIFICATION LAUNCHER' "$LAUNCHER"
check $? "launcher is visibly not the default route before live smoke"

echo "== sandboxed Rapid Auto Mode dry run =="

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-rapid-auto-dry.XXXXXX")"
SB_CANON="$(cd -P "$SB" && /bin/pwd -P)"
trap 'rm -rf "$SB"' EXIT INT TERM HUP

mkdir -p \
    "$SB/bin" \
    "$SB/config" \
    "$SB/home/.models/Qwen3.6-35B-A3B-4bit"

cp "$LAUNCHER" "$SB/bin/launch-claude-agent-rapid-auto.sh"
cp "$GATE" "$SB/bin/omlx-auto-prewarm-gate.sh"
cp "$PROGRESS" "$SB/bin/omlx-progress.sh"
cp "$HELPER" "$SB/bin/omlx-auto-prewarm.py"
cp "$CONFIG_LIB" "$SB/config/config-lib.sh"
cp "$PROMPT" "$SB/config/local-agent-system-prompt.txt"
printf '{}\n' >"$SB/home/.models/Qwen3.6-35B-A3B-4bit/config.json"

cat >"$SB/bin/rapid-mlx" <<'RAPID_STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' "rapid-mlx 0.13.4"
    exit 0
fi
exit 97
RAPID_STUB
chmod 700 "$SB/bin/rapid-mlx"

cat >"$SB/config/config.local.sh" <<'CONFIG'
LA_DEFAULT_MLX_BACKEND=rapid
la_register alpha Qwen3.6-35B-A3B-4bit mlx qwen "" false claude-opus-5 high
CONFIG

dry_run="$(
    HOME="$SB/home" \
    LA_RAPID_AUTO_BIN="$SB/bin/rapid-mlx" \
    LA_RAPID_AUTO_MODEL_DIR="$SB/home/.models/Qwen3.6-35B-A3B-4bit" \
    LA_RAPID_AUTO_DRY_RUN=1 \
    CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1 \
        bash "$SB/bin/launch-claude-agent-rapid-auto.sh" alpha high 2>&1
)"
dry_status=$?

[ "$dry_status" -eq 0 ]
check $? "sandboxed Rapid Auto Mode dry run completes"

printf '%s' "$dry_run" | grep -qF 'RAPID_AUTO_DRY_RUN_OK'
check $? "dry run reports explicit success marker"

printf '%s' "$dry_run" |
    grep -qF "model_dir=$SB_CANON/home/.models/Qwen3.6-35B-A3B-4bit"
check $? "dry run preserves canonical qualified local model directory"

printf '%s' "$dry_run" |
    grep -qF 'classifier_model_argument=claude-sonnet-5'
check $? "dry run uses Sonnet as retained model-path identity"

printf '%s' "$dry_run" |
    grep -qF 'served_model_name=claude-opus-5'
check $? "dry run uses Opus as served session identity"

printf '%s' "$dry_run" | grep -qF 'segmented=1'
check $? "segmented transcript reaches dedicated launcher"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
