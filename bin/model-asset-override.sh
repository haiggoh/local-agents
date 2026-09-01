#!/usr/bin/env bash
# model-asset-override.sh — build an ISOLATED asset-override view of a model directory.
#
# Creates <dest> as a farm of SYMLINKS pointing at every file in <src>, so the override
# costs kilobytes instead of duplicating tens of gigabytes of weights. You then drop real
# files into <dest> to add or shadow individual non-weight assets (a missing
# video_preprocessor_config.json, a patched config.json, an upstream chat_template.jinja).
#
# WHY: the local-model roster plan requires that original downloaded checkpoints stay
# byte-for-byte unchanged and that upstream asset/template experiments happen in isolated
# copies or runtime overrides — never as in-place edits to a shared snapshot. This gives
# that isolation without the disk cost, and keeps weight conclusions separable from
# asset/template conclusions.
#
# Usage:
#   model-asset-override.sh <src-model-dir> <dest-override-dir> [--force]
#   # then: cp/write your overriding asset files into <dest-override-dir>
#
# To shadow a file that exists in <src>, just write a real file over the symlink — but
# delete the symlink FIRST, or you will write THROUGH it and corrupt the original:
#   rm <dest>/config.json && vi <dest>/config.json
# (This script refuses to run if <dest> already exists unless --force is given.)
set -euo pipefail

SRC="${1:-}"; DEST="${2:-}"; FORCE="${3:-}"

if [ -z "$SRC" ] || [ -z "$DEST" ]; then
  sed -n '2,26p' "$0"; exit 2
fi

[ -d "$SRC" ] || { echo "❌ src is not a directory: $SRC"; exit 1; }

SRC_ABS="$(cd "$SRC" && pwd)"

if [ -e "$DEST" ]; then
  if [ "$FORCE" = "--force" ]; then
    # Only ever remove a directory that looks like one of our own symlink farms:
    # every entry must be a symlink or a small (<1 MiB) regular file.
    bad=0
    while IFS= read -r -d '' f; do
      if [ -L "$f" ]; then continue; fi
      if [ -f "$f" ]; then
        sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
        [ "$sz" -lt 1048576 ] && continue
      fi
      bad=1; echo "   refusing: $f is neither a symlink nor a small file"; break
    done < <(find "$DEST" -mindepth 1 -maxdepth 1 -print0)
    [ "$bad" -eq 0 ] || { echo "❌ $DEST does not look like an override farm; remove it yourself"; exit 1; }
    rm -rf "$DEST"
  else
    echo "❌ dest already exists: $DEST (pass --force to rebuild)"; exit 1
  fi
fi

mkdir -p "$DEST"
DEST_ABS="$(cd "$DEST" && pwd)"

n=0
for f in "$SRC_ABS"/*; do
  [ -e "$f" ] || continue                     # empty-glob guard
  base="$(basename "$f")"
  ln -s "$f" "$DEST_ABS/$base"
  n=$((n+1))
done

echo "✓ override farm: $DEST_ABS"
echo "  $n symlink(s) -> $SRC_ABS"
echo "  originals are untouched; write real files into the farm to add/shadow assets"
echo "  (to shadow an existing file: rm the symlink first, or you write THROUGH it)"
