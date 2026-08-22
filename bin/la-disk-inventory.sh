#!/usr/bin/env bash
# la-disk-inventory.sh — DISK-FIRST inventory: what is actually in your models dir, and
# does anything know about it?
#
# This is the complement to bin/la-roles.sh, not a replacement. They answer opposite questions:
#
#   la-roles.sh          registry -> disk   "which ROLE can I fill right now?"   (● on disk / ○ not)
#   la-disk-inventory.sh disk -> registry   "what is ON my disk, and is it accounted for?"
#
# Three states are deliberately distinct and must not be conflated:
#
#   DOWNLOAD LIST   a catalog of models that COULD be fetched (model-catalog.psv). Aspirational.
#   ON DISK         weights that actually exist. What you can serve today.
#   REGISTERED      an alias in config.local.sh, so a role/launcher can address it.
#
# A model can be in any combination. The interesting cases this surfaces:
#   ORPHAN      on disk, in no catalog and no registry — usually a MANUAL download made outside
#               the downloader, or a retired model whose entry was removed while weights stayed.
#   UNMARKED    on disk with no .la-download-complete marker — acquired by other means, so the
#               downloader cannot vouch for completeness. Verify before trusting it.
#   NOPAYLOAD   a directory with configs/tokenizer but NO weight file (>1MB) — a metadata-only
#               shell from an aborted selection. It LOOKS present and is not.
#
# Usage:  la-disk-inventory.sh [--orphans] [--empty] [--du]
#   --orphans   only rows nothing knows about        --empty  only payload-free directories
#   --du        measure real allocated size (slower; otherwise sizes are omitted)
set -uo pipefail

ORPHANS_ONLY=0; EMPTY_ONLY=0; DO_DU=0
for a in "$@"; do case "$a" in
  --orphans) ORPHANS_ONLY=1 ;; --empty) EMPTY_ONLY=1 ;; --du) DO_DU=1 ;;
  -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a (see --help)" >&2; exit 2 ;;
esac; done

_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
HERE="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config/config-lib.sh"
la_load_config || exit 1
DIR=${LA_MODELS_DIR:?registry did not define LA_MODELS_DIR}
[[ -d $DIR ]] || { printf 'Models dir does not exist: %s\n' "$DIR" >&2; exit 1; }

declare -A REG_SUB CAT_SUB
for a in "${LA_ALIASES[@]}"; do
  sub=${LA_SUBDIR[$a]:-}; [[ -n $sub ]] || continue
  REG_SUB[$sub]="${REG_SUB[$sub]:+${REG_SUB[$sub]},}$a"
done

# Catalogs are OPTIONAL here: this tool must still work for someone who never used the downloader.
for cat in "$HOME/.claude/scripts/model-catalog.psv" "$HOME/.claude/scripts/image-model-catalog.psv" \
           "$HERE/../config/model-catalog.psv" "$HERE/../config/model-catalog.local.psv"; do
  [[ -r $cat ]] || continue
  while IFS='|' read -r alias _ _ _ sub _; do
    [[ -n ${alias:-} && $alias != \#* && -n ${sub:-} ]] || continue
    CAT_SUB[$sub]="${CAT_SUB[$sub]:+${CAT_SUB[$sub]},}$alias"
  done < "$cat"
done

printf 'Disk inventory — %s   (config: %s)\n' "$DIR" "$LA_CONFIG_SOURCE"
printf '%-42s %-9s %-22s %-8s %s\n' "DIRECTORY" "STATE" "KNOWN AS" "MARKER" "$( ((DO_DU)) && echo SIZE || echo FILES)"
orphans=0; empties=0; unmarked=0; total=0
while IFS= read -r d; do
  base=${d##*/}; total=$((total+1))
  files=$(find "$d" -type f ! -name '.la-download-complete' -print 2>/dev/null | head -2000 | grep -c . || true)
  # Weights are always large; a dir full of small configs is a metadata-only shell, not a model.
  # -L so a legitimate symlink farm (model-asset-override.sh) is not misreported as payload-free.
  payload=$(find -L "$d" -type f -size +1024k -print -quit 2>/dev/null | grep -c . || true)
  marker=$([[ -f "$d/.la-download-complete" ]] && echo yes || echo no)
  [[ $marker == no ]] && unmarked=$((unmarked+1))
  reg=${REG_SUB[$base]:-}; cat=${CAT_SUB[$base]:-}
  if   (( payload == 0 ));          then state=NOPAYLOAD; empties=$((empties+1))
  elif [[ -z $reg && -z $cat ]];    then state=ORPHAN;   orphans=$((orphans+1))
  elif [[ -n $reg && -n $cat ]];    then state=both
  elif [[ -n $reg ]];               then state=registry
  else                                   state=catalog
  fi
  ((ORPHANS_ONLY)) && [[ $state != ORPHAN ]] && continue
  ((EMPTY_ONLY))   && [[ $state != NOPAYLOAD ]] && continue
  if ((DO_DU)); then metric=$(du -sh "$d" 2>/dev/null | cut -f1); else metric=$files; fi
  printf '%-42s %-9s %-22s %-8s %s\n' "$base" "$state" "${reg:-${cat:--}}" "$marker" "$metric"
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

printf '\n%d directories · %d ORPHAN (nothing knows about them) · %d NOPAYLOAD (no weight file) · %d without a completion marker\n' \
  "$total" "$orphans" "$empties" "$unmarked"
(( orphans )) && printf 'ORPHANs are usually manual downloads or retired models whose entry was removed.\nRegister one to use it, add it to a catalog to make it re-downloadable, or delete it deliberately.\n'
(( empties )) && printf 'NOPAYLOAD dirs contain configs but no weights — they look installed and are not. Safe to remove or re-fetch.\n'
(( unmarked )) && printf 'A missing marker is NOT corruption — it means the downloader did not fetch it, so completeness is unverified.\n'
exit 0
