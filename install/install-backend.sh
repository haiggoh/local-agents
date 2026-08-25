#!/usr/bin/env bash
# install-backend.sh — one-time backend setup for local-agents (run OUTSIDE Claude Code).
#
# Sets up the vllm-mlx serving backend that the launcher/hotswap drive:
#   1. a Python venv (default ~/.local-llm)
#   2. the vllm-mlx fork (Apple-Silicon MLX serving) at a known-good ref
#   3. applies this repo's fork patches (required for direct Claude Code routing — see README)
#
# It does NOT download models — run download-models.sh for that. Idempotent-ish and guarded;
# re-run safely. Requires: macOS on Apple Silicon, Homebrew python3, git.
set -euo pipefail

VENV_ROOT="${LA_VENV_ROOT:-$HOME/.local-llm}"
VLLM_SRC="${LA_VLLM_SRC:-$HOME/vllm-mlx}"
VLLM_REF="${LA_VLLM_REF:-v0.4.0}"   # known-good base this repo's patch targets (commit 0dd1157)
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vllm-mlx-local-fork-patches.patch"

echo "== local-agents backend install =="
[ "$(uname -s)" = "Darwin" ] || { echo "⚠ not macOS — vllm-mlx targets Apple Silicon MLX."; }

# 1. venv
if [ ! -d "$VENV_ROOT" ]; then
  echo "[1/4] creating venv at $VENV_ROOT"; python3 -m venv "$VENV_ROOT"
else echo "[1/4] venv exists: $VENV_ROOT"; fi
"$VENV_ROOT/bin/pip" install -q --upgrade pip

# 2. clone the vllm-mlx fork
if [ ! -d "$VLLM_SRC/.git" ]; then
  echo "[2/4] cloning vllm-mlx into $VLLM_SRC"
  git clone https://github.com/waybarrios/vllm-mlx "$VLLM_SRC"
else echo "[2/4] vllm-mlx exists: $VLLM_SRC"; fi
git -C "$VLLM_SRC" fetch --tags --quiet || true
git -C "$VLLM_SRC" checkout --quiet "$VLLM_REF" 2>/dev/null || echo "  (could not checkout $VLLM_REF — using current HEAD; patch may need adjusting)"

# 3. editable install (vllm-mlx + mlx-lm)
echo "[3/4] pip install -e vllm-mlx (+ mlx-lm)"
"$VENV_ROOT/bin/pip" install -q -e "$VLLM_SRC"
"$VENV_ROOT/bin/pip" install -q mlx-lm

# 4. apply the fork patches (required for direct routing; safe to skip if already applied)
echo "[4/4] applying fork patches"
if git -C "$VLLM_SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$VLLM_SRC" apply "$PATCH" && echo "  ✓ patches applied"
else
  echo "  ⚠ patch did not apply cleanly (already applied, or upstream moved)."
  echo "    Inspect: git -C $VLLM_SRC apply --check $PATCH"
  echo "    The 3 patches are documented in README (system-block coalescing, llama4 VLM guard, MLLM KV-cache)."
fi

echo
echo "Done. Next:"
echo "  1. cp config/config.example.sh config/config.local.sh  &&  edit for your models"
echo "  2. ./install/download-models.sh        # fetch the models you registered"
echo "  3. ./bin/launch-claude-agent.sh <alias>  (or ./bin/csl)"
