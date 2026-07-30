#!/usr/bin/env bash
# download-models.sh — fetch MLX model weights into LA_MODELS_DIR (run OUTSIDE Claude Code).
#
# EDIT the MODELS map below to the Hugging Face repos you want (the defaults are the maintainer's
# mid-2026 M4-Max stack; they map to the aliases in config.example.sh). Uses the `hf` CLI
# (pip install -U huggingface_hub). Public repos download anonymously; `hf auth login` for gated.
set -euo pipefail

# Resolve LA_MODELS_DIR from config if available, else default.
CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../config"
# shellcheck source=/dev/null
[ -f "$CFG/config.local.sh" ] && . "$CFG/config.local.sh" || { [ -f "$CFG/config.example.sh" ] && . "$CFG/config.example.sh"; }
TARGET_DIR="${LA_MODELS_DIR:-$HOME/.models}"
mkdir -p "$TARGET_DIR"

command -v hf >/dev/null 2>&1 || { echo "❌ 'hf' CLI not found. pip install -U huggingface_hub"; exit 1; }

# subdir (must match config's subdir)  ->  HF repo id.  EDIT THESE for your models.
declare -A MODELS=(
  [Qwen3.6-27B-UD-MLX-4bit]="unsloth/Qwen3.6-27B-UD-MLX-4bit"
  [DeepSeek-R1-Distill-Qwen-32B-4bit]="mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
  [Llama-4-Scout-17B-16E-Instruct-4bit]="mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit"
)

FREE_GB=$(df -Pg "$TARGET_DIR" 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$FREE_GB" ] && echo "[disk] ~${FREE_GB} GB free at $TARGET_DIR"

# NOTE: on some networks the HF CDN (CloudFront) IPv6 endpoints black-hole and hf hangs in
# SYN_SENT. If downloads stall, force IPv4 (e.g. a sitecustomize shim on PYTHONPATH) or use a
# wired/other network. See README "Troubleshooting".

i=0; n=${#MODELS[@]}
for subdir in "${!MODELS[@]}"; do
  i=$((i+1)); repo="${MODELS[$subdir]}"
  echo -e "\n[$i/$n] $repo -> $TARGET_DIR/$subdir"
  hf download "$repo" --local-dir "$TARGET_DIR/$subdir"
done
echo -e "\n✓ done. Verify with: ls -la $TARGET_DIR"
