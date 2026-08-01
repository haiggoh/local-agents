#!/usr/bin/env bash
# download-models.sh — INTERACTIVE model downloader (run OUTSIDE Claude Code).
#
# Reads the model registry (config.local.sh, else config.example.sh) — the SINGLE source of truth —
# and lets you CHOOSE which models to download. Large weights aren't the right fit for every user,
# so nothing is fetched without your selection. A partial roster is fine: whatever you download
# fills the roles it's tagged with, and the rest of the work stays on the cloud model.
#
# Each downloadable model is one with an hf_repo in the registry. Entries are DEDUPED by subdir, so
# two aliases sharing one download (e.g. an operator + a thinking flavor of the same weights) appear
# once and fetch once.
#
# Usage:
#   install/download-models.sh              # interactive picker
#   install/download-models.sh --all        # download everything (non-interactive; for scripts/CI)
#   install/download-models.sh --force      # re-download even if already on disk
# (Non-interactive stdin with no --all lists the catalog and exits without downloading.)
set -euo pipefail

FORCE=0; ALL=0
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (see --help)"; exit 2 ;;
  esac
done

# Load the registry via the shared config lib (resolves symlinks; local overlay else example).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config/config-lib.sh"
la_load_config || exit 1
TARGET_DIR="$LA_MODELS_DIR"; mkdir -p "$TARGET_DIR"

command -v hf >/dev/null 2>&1 || { echo "❌ 'hf' CLI not found. pip install -U huggingface_hub"; exit 1; }

# --- build the downloadable catalog: dedupe by subdir, keep first alias/repo/size/roles seen -----
CAT_SUBDIR=(); CAT_REPO=(); CAT_SIZE=(); CAT_LABEL=()
declare -A SEEN_SUBDIR
for a in "${LA_ALIASES[@]}"; do
  repo="${LA_REPO[$a]:-}"; sub="${LA_SUBDIR[$a]:-}"
  [ -n "$repo" ] && [ -n "$sub" ] || continue          # only installer-managed entries
  if [ -n "${SEEN_SUBDIR[$sub]:-}" ]; then
    # another alias shares this download — fold its role into the existing label
    idx="${SEEN_SUBDIR[$sub]}"
    CAT_LABEL[$idx]="${CAT_LABEL[$idx]} + $a"
    continue
  fi
  SEEN_SUBDIR[$sub]=${#CAT_SUBDIR[@]}
  CAT_SUBDIR+=("$sub"); CAT_REPO+=("$repo"); CAT_SIZE+=("${LA_SIZE[$a]:-?}")
  roles="$(la_roles_for_alias "$a")"; [ -z "$roles" ] && roles="${LA_ROLES[$a]:-untagged}"
  CAT_LABEL+=("$a [${roles}]")
done

n=${#CAT_SUBDIR[@]}
[ "$n" -eq 0 ] && { echo "No installer-managed models in the registry (no hf_repo set). Nothing to download."; exit 0; }

FREE_GB=$(df -Pg "$TARGET_DIR" 2>/dev/null | awk 'NR==2{print $4}')
echo "Model downloader — config: ${LA_CONFIG_SOURCE}"
[ -n "$FREE_GB" ] && echo "Disk: ~${FREE_GB} GB free at $TARGET_DIR"
echo "Catalog (● already on disk, ○ not yet):"
tot=0
for ((i=0;i<n;i++)); do
  d="$TARGET_DIR/${CAT_SUBDIR[$i]}"
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then mark="●"; else mark="○"; fi
  printf "  %2d) %s  %-40s ~%s GB  [%s]\n" "$((i+1))" "$mark" "${CAT_LABEL[$i]}" "${CAT_SIZE[$i]}" "${CAT_REPO[$i]}"
done

# --- choose what to fetch ----------------------------------------------------
choices=()
if [ "$ALL" -eq 1 ]; then
  for ((i=0;i<n;i++)); do choices+=("$i"); done
elif [ ! -t 0 ]; then
  echo
  echo "(non-interactive stdin and no --all: listed the catalog above, downloading nothing.)"
  echo "Re-run interactively to pick, or pass --all."
  exit 0
else
  echo
  echo "Enter numbers to download (space-separated), 'a' for all, or 'q' to quit:"
  printf "Selection: "; read -r line
  case "$line" in
    q|Q|"") echo "Nothing selected."; exit 0 ;;
    a|A|all) for ((i=0;i<n;i++)); do choices+=("$i"); done ;;
    *) for tok in $line; do
         [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ] \
           && choices+=("$((tok-1))") || { echo "invalid selection: $tok"; exit 2; }
       done ;;
  esac
fi
[ "${#choices[@]}" -eq 0 ] && { echo "Nothing selected."; exit 0; }

# NOTE: on some networks the HF CDN (CloudFront) IPv6 endpoints black-hole and hf hangs in
# SYN_SENT. If downloads stall, force IPv4 (a sitecustomize shim on PYTHONPATH) or use another
# network. See README "Troubleshooting".
echo
c=0; total=${#choices[@]}
for idx in "${choices[@]}"; do
  c=$((c+1)); sub="${CAT_SUBDIR[$idx]}"; repo="${CAT_REPO[$idx]}"; dest="$TARGET_DIR/$sub"
  if [ "$FORCE" -eq 0 ] && [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "[$c/$total] $repo — already on disk, skipping (--force to re-download)"; continue
  fi
  echo "[$c/$total] $repo -> $dest"
  hf download "$repo" --local-dir "$dest"
done
echo -e "\n✓ done. Verify roles with: bin/la-roles.sh"
