#!/usr/bin/env bash
# download-models.sh — the local-model downloader (ENGINE).
#
# Run OUTSIDE Claude Code. Interactive by default; scriptable with --select/--all.
#
# The model list is DATA and lives outside this file, in model-catalog.psv, so a
# roster change never edits this script and an engine change never edits the
# roster. Registry-managed models (config.local.sh) load in addition to it.
#
# Usage:
#   download-models.sh                     # interactive picker
#   download-models.sh --list               # show the catalog and exit
#   download-models.sh --select ALIAS ...   # non-interactive, repeatable
#   download-models.sh --all                # everything (honours --group)
#   download-models.sh --group NAME         # restrict to one group
#   download-models.sh --dry-run            # resolve + report, write nothing
#   download-models.sh --force              # re-fetch even if COMPLETE
#   download-models.sh --check-auth         # Hugging Face auth diagnostics
#   download-models.sh --catalog FILE       # explicit catalog, repeatable
#   download-models.sh --target DIR         # download somewhere else (another volume)
#   download-models.sh --headroom-gb N      # disk reserve to keep free (default 100)
#   download-models.sh --allow-tight        # proceed even if the reserve is breached
#
# Disk preflight: before downloading, the queued selection is summed against free space
# on the target volume, minus a reserve (default 100 GB, or $LA_DISK_HEADROOM_GB). If it
# will not fit you get a shortfall figure, a concrete --select subset that DOES fit, and
# any other mounted volume with room. Non-interactive runs REFUSE rather than fill the
# disk. Already-complete entries cost nothing and are not counted. Catalog sizes are
# display estimates, so this is a guard rail, not an allocation guarantee. (This disk
# reserve is unrelated to the 20-30 GB RUNTIME-MEMORY headroom in the model plans.)
#
# Catalog resolution: --catalog / $LA_MODEL_CATALOG (':'-separated) win outright;
# otherwise base + local-overlay files are loaded from $LA_ROOT/config then from
# this script's directory. See the loader block below for the exact order.
#
# States are deliberately separate: a written .la-download-complete marker is
# ACQUISITION evidence only, never artifact verification or runtime qualification.
#
# Requires Bash 4+ because local-agents/config/config-lib.sh uses associative arrays.
# If PATH selects Apple's Bash 3.2, bootstrap into a common Homebrew Bash location.

if (( BASH_VERSINFO[0] < 4 )); then
  for modern_bash in \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash
  do
    if [[ -x "$modern_bash" ]] &&
       "$modern_bash" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null
    then
      [[ ${LOCAL_AGENTS_DOWNLOAD_DEBUG:-0} == 1 ]] && printf 'Relaunching under %s\n' "$modern_bash" >&2
      exec "$modern_bash" "$0" "$@"
    fi
  done

  printf 'Bash 4+ is required; no compatible interpreter was found.\n' >&2
  exit 2
fi

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

FORCE=0; LIST_ONLY=0; DRY_RUN=0; CHECK_AUTH=0; NON_AUTH_ACTION=0; ALL=0; ALLOW_TIGHT=0
GROUP_FILTER=""; SELECTED=(); CATALOG_OVERRIDE=(); TARGET_OVERRIDE=""
HEADROOM_GB=${LA_DISK_HEADROOM_GB:-100}
while (($#)); do
  case "$1" in
    --force) FORCE=1; NON_AUTH_ACTION=1; shift ;;
    --list) LIST_ONLY=1; NON_AUTH_ACTION=1; shift ;;
    --dry-run) DRY_RUN=1; NON_AUTH_ACTION=1; shift ;;
    --check-auth) CHECK_AUTH=1; shift ;;
    --all) ALL=1; NON_AUTH_ACTION=1; shift ;;
    --allow-tight) ALLOW_TIGHT=1; NON_AUTH_ACTION=1; shift ;;
    --target) (($# >= 2)) || { echo '--target needs a directory' >&2; exit 2; }; TARGET_OVERRIDE=$2; NON_AUTH_ACTION=1; shift 2 ;;
    --headroom-gb) (($# >= 2)) || { echo '--headroom-gb needs a number' >&2; exit 2; }; [[ $2 =~ ^[0-9]+$ ]] || { echo '--headroom-gb must be a whole number of GB' >&2; exit 2; }; HEADROOM_GB=$2; NON_AUTH_ACTION=1; shift 2 ;;
    --catalog) (($# >= 2)) || { echo '--catalog needs a file path' >&2; exit 2; }; CATALOG_OVERRIDE+=("$2"); NON_AUTH_ACTION=1; shift 2 ;;
    --group) (($# >= 2)) || { echo '--group needs a value' >&2; exit 2; }; GROUP_FILTER=$2; NON_AUTH_ACTION=1; shift 2 ;;
    --select) (($# >= 2)) || { echo '--select needs an alias' >&2; exit 2; }; SELECTED+=("$2"); NON_AUTH_ACTION=1; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v hf >/dev/null 2>&1 || { echo "Missing 'hf' CLI." >&2; exit 1; }

check_hf_auth() {
  local hf_home token_path auth_output implicit_setting
  if [[ -n ${HF_HOME:-} ]]; then
    hf_home=$HF_HOME
  elif [[ -n ${XDG_CACHE_HOME:-} ]]; then
    hf_home=$XDG_CACHE_HOME/huggingface
  else
    hf_home=$HOME/.cache/huggingface
  fi
  token_path=${HF_TOKEN_PATH:-$hf_home/token}
  [[ -s $token_path ]] && printf 'Hugging Face token file: present (%s)\n' "$token_path" || printf 'Hugging Face token file: not found or empty (%s)\n' "$token_path"
  [[ ! ${HF_TOKEN+x} ]] || printf 'Warning: HF_TOKEN is set and overrides the stored token.\n' >&2
  implicit_setting=${HF_HUB_DISABLE_IMPLICIT_TOKEN:-0}
  case ${implicit_setting^^} in
    1|ON|YES|TRUE)
      printf 'Warning: HF_HUB_DISABLE_IMPLICIT_TOKEN is enabled; downloads may remain anonymous.\n' >&2
      ;;
  esac
  if auth_output=$(hf auth whoami 2>&1); then printf 'Hugging Face authentication: active\n%s\n' "$auth_output"; return 0; fi
  printf 'Hugging Face authentication: unavailable\n%s\n' "$auth_output" >&2; return 1
}
if ((CHECK_AUTH)); then
  auth_ok=0; check_hf_auth || auth_ok=$?
  if ((!NON_AUTH_ACTION)); then exit "$auth_ok"; fi
  ((auth_ok == 0)) || printf 'Continuing; public repositories may still be accessible anonymously.\n' >&2
fi
# Derive the repo root from THIS script's real location (symlink-safe), so a clone works at any
# path and an install/ symlink on $PATH still finds the repo's config. $LA_ROOT still wins if set.
_lar="${BASH_SOURCE[0]}"
while [[ -h $_lar ]]; do
  _lard=$(cd -P "$(dirname "$_lar")" && pwd); _lar=$(readlink "$_lar")
  [[ $_lar == /* ]] || _lar="$_lard/$_lar"
done
LA_ROOT=${LA_ROOT:-"$(cd -P "$(dirname "$_lar")/.." && pwd)"}
CONFIG_LIB="$LA_ROOT/config/config-lib.sh"
[[ -r $CONFIG_LIB ]] || { printf 'Missing registry loader: %s\n' "$CONFIG_LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG_LIB"
la_load_config || exit 1
if [[ -n $TARGET_OVERRIDE ]]; then
  TARGET_DIR=$TARGET_OVERRIDE
  printf 'Target overridden by --target: %s\n' "$TARGET_DIR"
else
  TARGET_DIR=${LA_MODELS_DIR:?registry did not define LA_MODELS_DIR}
fi
mkdir -p "$TARGET_DIR" || { printf 'Cannot create target directory: %s\n' "$TARGET_DIR" >&2; exit 1; }
[[ -w $TARGET_DIR ]] || { printf 'Target directory is not writable: %s\n' "$TARGET_DIR" >&2; exit 1; }

A=(); LABEL=(); REPO=(); REV=(); SUB=(); SIZE=(); GROUP=(); STATUS=(); INCLUDE=(); RUNTIME=()
declare -A BY_ALIAS BY_SUBDIR BY_ID

group_add() {
  local i=$1 group=$2 current
  current=${GROUP[i]}
  [[ ,$current, == *,$group,* ]] || GROUP[i]="${current:+$current,}$group"
}
group_has() {
  local i=$1 group=$2
  [[ ,${GROUP[i]}, == *,$group,* ]]
}
normalize_include() {
  local raw=$1 pattern normalized=""
  local -a patterns=()
  [[ -n $raw ]] || { printf '%s' ""; return 0; }
  IFS=';' read -r -a patterns <<<"$raw"
  while IFS= read -r pattern; do
    normalized+="${normalized:+;}$pattern"
  done < <(printf '%s\n' "${patterns[@]}" | LC_ALL=C sort -u)
  printf '%s' "$normalized"
}

add_entry() {
  local alias=$1 label=$2 repo=$3 rev=${4:-main} sub=$5 size=$6 group=$7 status=$8 include=$9 runtime=${10}
  local i prior identity
  include=$(normalize_include "$include")
  identity="$repo"$'\x1f'"$rev"$'\x1f'"$include"
  [[ -n $alias && -n $repo && -n $sub ]] || return 0
  case $sub in
    /*|..|../*|*/..|*/../*)
      printf "Unsafe model subdir '%s' for alias '%s'.\n" "$sub" "$alias" >&2
      exit 1
      ;;
  esac
  [[ $alias != *$'\n'* && $repo != *$'\n'* && $rev != *$'\n'* && $sub != *$'\n'* && $include != *$'\n'* ]] || {
    printf "Catalog fields may not contain newlines (alias '%s').\n" "$alias" >&2
    exit 1
  }
  if [[ ${BY_ALIAS[$alias]+x} ]]; then
    prior=${BY_ALIAS[$alias]}
    [[ ${REPO[prior]} == "$repo" && ${REV[prior]} == "$rev" && ${INCLUDE[prior]} == "$include" ]] && { group_add "$prior" "$group"; return 0; }
    printf "Catalog conflict for alias '%s'\n" "$alias" >&2; exit 1
  fi
  if [[ ${BY_SUBDIR[$sub]+x} ]]; then
    prior=${BY_SUBDIR[$sub]}
    [[ ${REPO[prior]} == "$repo" && ${REV[prior]} == "$rev" && ${INCLUDE[prior]} == "$include" ]] || { printf "Catalog conflict for subdir '%s'\n" "$sub" >&2; exit 1; }
    LABEL[prior]="${LABEL[prior]} + $alias"; BY_ALIAS[$alias]=$prior; group_add "$prior" "$group"; return 0
  fi
  if [[ ${BY_ID[$identity]+x} ]]; then
    prior=${BY_ID[$identity]}; BY_ALIAS[$alias]=$prior; BY_SUBDIR[$sub]=$prior
    LABEL[prior]="${LABEL[prior]} + $alias"; group_add "$prior" "$group"; return 0
  fi
  i=${#A[@]}; BY_ALIAS[$alias]=$i; BY_SUBDIR[$sub]=$i; BY_ID[$identity]=$i
  A+=("$alias"); LABEL+=("$label"); REPO+=("$repo"); REV+=("$rev"); SUB+=("$sub")
  SIZE+=("$size"); GROUP+=("$group"); STATUS+=("$status"); INCLUDE+=("$include"); RUNTIME+=("$runtime")
}

# Existing registry first. Optional LA_REV is supported if introduced later.
for alias in "${LA_ALIASES[@]}"; do
  repo=${LA_REPO[$alias]:-}; sub=${LA_SUBDIR[$alias]:-}; [[ -n $repo && -n $sub ]] || continue
  rev=main; declare -p LA_REV >/dev/null 2>&1 && rev=${LA_REV[$alias]:-main}
  roles=$(la_roles_for_alias "$alias"); [[ -n $roles ]] || roles=${LA_ROLES[$alias]:-untagged}
  add_entry "$alias" "$alias [$roles]" "$repo" "$rev" "$sub" "${LA_SIZE[$alias]:-?}" existing registry "" registry-defined
done

# --- catalog (DATA) -----------------------------------------------------------
# The model list lives in a separate .psv data file, never inline here. Adding a
# model must not require editing this script.
#
# Resolution order:
#   1. --catalog PATH (repeatable) or $LA_MODEL_CATALOG (':'-separated) — exact
#      files, and a missing one is a hard error.
#   2. Otherwise every file below that exists, in order (base first, then the
#      gitignored local overlay). Loading several is safe: identical entries fold
#      by identity and a genuine alias/subdir conflict still aborts.
#        $LA_ROOT/config/model-catalog.psv
#        $LA_ROOT/config/model-catalog.local.psv
#        <this script's dir>/model-catalog.psv
#        <this script's dir>/model-catalog.local.psv
load_catalog_file() {
  local file=$1 alias label repo rev sub size group status include runtime
  local -i lineno=0 loaded=0
  while IFS='|' read -r alias label repo rev sub size group status include runtime || [[ -n $alias ]]; do
    ((++lineno))
    runtime=${runtime%$'\r'}
    [[ -n $alias && $alias != \#* ]] || continue
    if [[ -z $repo || -z $sub ]]; then
      printf 'Catalog %s line %d: alias %s needs at least repo and subdir.\n' "$file" "$lineno" "$alias" >&2
      exit 1
    fi
    add_entry "$alias" "$label" "$repo" "${rev:-main}" "$sub" "$size" "$group" "$status" "$include" "$runtime"
    ((++loaded))
  done < "$file"
  printf 'Catalog: %s (%d entries)\n' "$file" "$loaded"
}

CATALOG_FILES=()
if ((${#CATALOG_OVERRIDE[@]})); then
  CATALOG_FILES=("${CATALOG_OVERRIDE[@]}")
elif [[ -n ${LA_MODEL_CATALOG:-} ]]; then
  IFS=':' read -r -a CATALOG_FILES <<<"$LA_MODEL_CATALOG"
else
  for candidate in \
    "$LA_ROOT/config/model-catalog.psv" \
    "$LA_ROOT/config/model-catalog.local.psv" \
    "$SCRIPT_DIR/model-catalog.psv" \
    "$SCRIPT_DIR/model-catalog.local.psv"
  do
    [[ -r $candidate ]] && CATALOG_FILES+=("$candidate")
  done
  if ((${#CATALOG_FILES[@]} == 0)); then
    printf 'WARNING: no model catalog found; listing REGISTRY ENTRIES ONLY.\n' >&2
    printf 'WARNING: expected one of these data files:\n' >&2
    printf 'WARNING:   %s\n' "$LA_ROOT/config/model-catalog.psv" \
      "$LA_ROOT/config/model-catalog.local.psv" \
      "$SCRIPT_DIR/model-catalog.psv" \
      "$SCRIPT_DIR/model-catalog.local.psv" >&2
  fi
fi
# Dedupe by REAL path before loading: the same catalog is reachable under several names once the
# private overlay lives in the repo and older paths are symlinks into it. Loading it twice is
# harmless only by luck (identity-dedupe folds it) and becomes a hard "catalog conflict" the moment
# the copies diverge, so collapse them here instead.
declare -A _seen_catalog
for catalog_file in "${CATALOG_FILES[@]}"; do
  [[ -r $catalog_file ]] || { printf 'Unreadable catalog file: %s\n' "$catalog_file" >&2; exit 1; }
  _real=$(cd -P "$(dirname "$catalog_file")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$catalog_file")")
  _real=${_real:-$catalog_file}
  if [[ -L $catalog_file ]]; then
    _tgt=$(readlink "$catalog_file"); [[ $_tgt == /* ]] || _tgt="$(dirname "$catalog_file")/$_tgt"
    _real=$(cd -P "$(dirname "$_tgt")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$_tgt")") || _real=$_tgt
  fi
  [[ ${_seen_catalog[$_real]+x} ]] && continue
  _seen_catalog[$_real]=1
  load_catalog_file "$catalog_file"
done

marker() { printf '%s/.la-download-complete' "$1"; }
has_payload() {
  local dest=$1 found
  [[ -d $dest ]] || return 1
  found=$(find "$dest" -path "$dest/.cache" -prune -o \
    \( -type f -o -type l \) ! -path "$(marker "$dest")" -print -quit 2>/dev/null)
  [[ -n $found ]]
}
is_complete() {
  local dest=$1 repo=$2 rev=$3 include=$4 m marker_include
  m=$(marker "$dest")
  has_payload "$dest" && [[ -f $m ]] && grep -Fqx "repo=$repo" "$m" && grep -Fqx "revision=$rev" "$m" || return 1
  marker_include=$(sed -n 's/^include=//p' "$m" | head -n 1)
  [[ $(normalize_include "$marker_include") == "$include" ]]
}
write_marker() {
  local dest=$1 repo=$2 rev=$3 include=$4 m tmp; m=$(marker "$dest"); tmp="$m.tmp.$$"
  { printf 'repo=%s\nrevision=%s\ninclude=%s\ncompleted_at=%s\n' "$repo" "$rev" "$include" "$(date -u +%FT%TZ)"; } >"$tmp"
  mv "$tmp" "$m"
}
state_for() {
  local i=$1 dest="$TARGET_DIR/${SUB[$1]}"
  if is_complete "$dest" "${REPO[i]}" "${REV[i]}" "${INCLUDE[i]}"; then printf COMPLETE
  elif has_payload "$dest"; then printf PRESENT
  elif [[ -d $dest ]]; then printf METADATA
  else printf ABSENT; fi
}
print_entry() {
  local i=$1 state; state=$(state_for "$i")
  printf '%3d) %-8s %-23s ~%-6s GB %-19s %s\n' "$((i+1))" "$state" "${A[i]}" "${SIZE[i]}" "${GROUP[i]}" "${REPO[i]}"
  printf '     %s | status=%s | runtime=%s\n' "${LABEL[i]}" "${STATUS[i]}" "${RUNTIME[i]}"
}

IDX=()
for ((i=0; i<${#A[@]}; i++)); do
  [[ -z $GROUP_FILTER ]] || group_has "$i" "$GROUP_FILTER" || continue
  IDX+=("$i")
done
((${#IDX[@]})) || { printf "No entries for group '%s'.\n" "$GROUP_FILTER" >&2; exit 2; }

free_gb=$(df -Pg "$TARGET_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)
printf 'Model downloader — config: %s\nTarget: %s\n' "$LA_CONFIG_SOURCE" "$TARGET_DIR"
[[ -n $free_gb ]] && printf 'Disk: ~%s GB free\n' "$free_gb"
if ((LIST_ONLY || ${#SELECTED[@]} == 0)); then for i in "${IDX[@]}"; do print_entry "$i"; done; fi
((LIST_ONLY)) && exit 0

CHOICES=()
if ((ALL)); then
  CHOICES=("${IDX[@]}")
  printf '\nSelecting all %d entries%s.\n' "${#IDX[@]}" "${GROUP_FILTER:+ in group '$GROUP_FILTER'}"
  if ((${#SELECTED[@]})); then
    printf -- '--all overrides --select; ignoring %d explicit alias(es).\n' "${#SELECTED[@]}" >&2
  fi
elif ((${#SELECTED[@]})); then
  for alias in "${SELECTED[@]}"; do
    [[ ${BY_ALIAS[$alias]+x} ]] || { printf "Unknown alias '%s'.\n" "$alias" >&2; exit 2; }
    i=${BY_ALIAS[$alias]}; [[ -z $GROUP_FILTER ]] || group_has "$i" "$GROUP_FILTER" || { printf "Alias '%s' is outside group '%s'.\n" "$alias" "$GROUP_FILTER" >&2; exit 2; }
    CHOICES+=("$i")
  done
elif [[ -t 0 ]]; then
  printf "Selection (catalog numbers, space-separated; q quits): "; read -r line
  [[ $line != q && $line != Q && -n $line ]] || exit 0
  read -r -a number_choices <<<"$line"
  for tok in "${number_choices[@]}"; do
    [[ $tok =~ ^[0-9]+$ ]] || { printf "Invalid selection '%s'.\n" "$tok" >&2; exit 2; }
    i=$((tok-1)); ((i >= 0)) && [[ ${A[i]+x} ]] || { printf "Out of range '%s'.\n" "$tok" >&2; exit 2; }
    [[ -z $GROUP_FILTER ]] || group_has "$i" "$GROUP_FILTER" || { printf "Selection '%s' is outside the filter.\n" "$tok" >&2; exit 2; }
    CHOICES+=("$i")
  done
else
  echo 'Non-interactive use requires --select ALIAS, --all, or --list.' >&2; exit 2
fi

DRY_ROOT=""
cleanup() { [[ -z $DRY_ROOT ]] || rm -rf -- "$DRY_ROOT" || true; }
stop() { cleanup; trap - EXIT; exit "$1"; }
if ((DRY_RUN)); then
  DRY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/download-models.XXXXXX")
  trap cleanup EXIT
  trap 'stop 129' HUP
  trap 'stop 130' INT
  trap 'stop 143' TERM
fi

# Deduplicate repeated selections up front, so [n/total] counts real work.
declare -A CHOSEN
QUEUE=()
for i in "${CHOICES[@]}"; do
  if [[ ${CHOSEN[$i]+x} ]]; then continue; fi
  CHOSEN[$i]=1; QUEUE+=("$i")
done
total=${#QUEUE[@]}; c=0

# --- disk preflight -----------------------------------------------------------
# Sums the catalog sizes of the work actually queued (already-COMPLETE entries are
# skipped below, so they do not count unless --force). Catalog sizes are DISPLAY
# ESTIMATES, not allocated-disk forecasts, so this is a guard rail rather than a
# guarantee. Headroom defaults to 100 GB and is NOT the 20-30 GB runtime-memory
# figure from the model plans; that is a different budget.
free_gb=$(df -Pg "$TARGET_DIR" 2>/dev/null | LC_ALL=C awk 'NR==2 {print $4+0}')
need_gb=0; unknown_sizes=0
PLAN_FIT=(); PLAN_DROP=()
if [[ -n $free_gb ]]; then
  budget_gb=$(LC_ALL=C awk -v f="$free_gb" -v h="$HEADROOM_GB" 'BEGIN{b=f-h; print (b>0?b:0)}')
  # size-ascending order over the queue: greedy fit maximises how many entries land
  order=$(for i in "${QUEUE[@]}"; do
            sz=${SIZE[i]}; [[ $sz =~ ^[0-9]+([.][0-9]+)?$ ]] || sz=-1
            printf '%s\t%s\n' "$sz" "$i"
          done | LC_ALL=C sort -g -k1,1)
  run=0
  while IFS=$'\t' read -r sz i; do
    [[ -n ${i:-} ]] || continue
    # Already-COMPLETE entries are skipped by the download loop, so they cost no disk.
    # Counting them would raise false "will not fit" alarms on a mostly-downloaded roster.
    if (( ! FORCE )) && is_complete "$TARGET_DIR/${SUB[i]}" "${REPO[i]}" "${REV[i]}" "${INCLUDE[i]}"; then
      PLAN_FIT+=("$i"); continue
    fi
    if [[ $sz == -1 ]]; then unknown_sizes=$((unknown_sizes+1)); PLAN_FIT+=("$i"); continue; fi
    need_gb=$(LC_ALL=C awk -v a="$need_gb" -v b="$sz" 'BEGIN{printf "%.2f", a+b}')
    if LC_ALL=C awk -v r="$run" -v s="$sz" -v b="$budget_gb" 'BEGIN{exit !(r+s<=b)}'; then
      run=$(LC_ALL=C awk -v r="$run" -v s="$sz" 'BEGIN{printf "%.2f", r+s}'); PLAN_FIT+=("$i")
    else
      PLAN_DROP+=("$i")
    fi
  done <<<"$order"

  printf '\nDisk preflight — target %s\n' "$TARGET_DIR"
  printf '  free %s GB · reserve %s GB headroom · usable %s GB · queued ~%s GB' \
    "$free_gb" "$HEADROOM_GB" "$budget_gb" "$need_gb"
  ((unknown_sizes)) && printf ' (+%d entr%s of UNKNOWN size — treat the total as a lower bound)' \
    "$unknown_sizes" "$([[ $unknown_sizes == 1 ]] && echo y || echo ies)"
  printf '\n'

  if ((${#PLAN_DROP[@]})); then
    short=$(LC_ALL=C awk -v n="$need_gb" -v b="$budget_gb" 'BEGIN{printf "%.2f", n-b}')
    printf '\n  ⚠️  WILL NOT FIT — short by ~%s GB after reserving %s GB.\n' "$short" "$HEADROOM_GB"
    printf '\n  Option A — a subset that DOES fit (%d of %d, ~%s GB):\n' \
      "${#PLAN_FIT[@]}" "${#QUEUE[@]}" "$run"
    if ((${#PLAN_FIT[@]})); then
      printf '        --select %s' "${A[${PLAN_FIT[0]}]}"
      for i in "${PLAN_FIT[@]:1}"; do printf ' --select %s' "${A[i]}"; done
      printf '\n'
    else
      printf '        (nothing in this selection fits — even the smallest entry exceeds the usable space)\n'
    fi
    printf '\n  Leave for later (%d):\n' "${#PLAN_DROP[@]}"
    for i in "${PLAN_DROP[@]}"; do printf '        %-26s ~%s GB\n' "${A[i]}" "${SIZE[i]}"; done

    printf '\n  Option B — download to another volume with --target DIR:\n'
    df -Pg 2>/dev/null | LC_ALL=C awk -v need="$need_gb" -v head="$HEADROOM_GB" '
      NR>1 && $4+0 >= need+head && $6 !~ /^\/(dev|System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware))/ {
        printf "        %-42s %s GB free\n", $6, $4 }' | LC_ALL=C sort -u
    df -Pg 2>/dev/null | LC_ALL=C awk -v need="$need_gb" -v head="$HEADROOM_GB" '
      NR>1 && $4+0 >= need+head && $6 !~ /^\/(dev|System)/ {c++} END{ if(!c)
        printf "        (no mounted volume currently has ~%.0f GB free — attach external storage,\n         or reclaim space per the SSD-reclamation plan)\n", need+head }'
    printf '\n  Option C — proceed anyway with --allow-tight (accepts running below the reserve).\n'
    printf '  Option D — change the reserve with --headroom-gb N (currently %s).\n' "$HEADROOM_GB"

    if ((DRY_RUN)); then
      printf '\n  Dry run: reporting only, continuing.\n'
    elif ((ALLOW_TIGHT)); then
      printf '\n  --allow-tight given: continuing despite the shortfall.\n' >&2
    elif [[ -t 0 ]]; then
      printf '\n  Continue with the fitting subset (f), everything anyway (a), or quit (q)? [f/a/q] '
      read -r disk_choice
      case ${disk_choice:-q} in
        f|F) QUEUE=("${PLAN_FIT[@]}"); total=${#QUEUE[@]}
             ((total)) || { printf '  Nothing fits; stopping.\n' >&2; stop 0; }
             printf '  Continuing with %d entr%s.\n' "$total" "$([[ $total == 1 ]] && echo y || echo ies)" ;;
        a|A) printf '  Continuing with the full selection despite the shortfall.\n' >&2 ;;
        *)   printf '  Stopping; nothing downloaded.\n'; stop 0 ;;
      esac
    else
      printf '\n  Refusing to start non-interactively. Re-run with the Option A selection,\n'
      printf '  a --target volume, --allow-tight, or a smaller --headroom-gb.\n' >&2
      stop 1
    fi
  else
    printf '  ✓ fits with ~%s GB still spare above the reserve.\n' \
      "$(LC_ALL=C awk -v b="$budget_gb" -v n="$need_gb" 'BEGIN{printf "%.2f", b-n}')"
  fi
else
  printf '\nDisk preflight: could not read free space for %s — proceeding WITHOUT a disk guard.\n' "$TARGET_DIR" >&2
fi

for i in "${QUEUE[@]}"; do
  ((++c))
  alias=${A[i]}; repo=${REPO[i]}; rev=${REV[i]}; include=${INCLUDE[i]}; dest="$TARGET_DIR/${SUB[i]}"
  if ((${#SELECTED[@]} || ALL)); then print_entry "$i"; fi
  if (( ! FORCE )) && is_complete "$dest" "$repo" "$rev" "$include"; then printf '[%d/%d] %s: complete; skipping\n' "$c" "$total" "$alias"; continue; fi
  local_dest=$dest; ((DRY_RUN)) && local_dest="$DRY_ROOT/${SUB[i]}"
  cmd=(hf download "$repo" --revision "$rev" --local-dir "$local_dest")
  if [[ -n $include ]]; then IFS=';' read -r -a patterns <<<"$include"; for pattern in "${patterns[@]}"; do cmd+=(--include "$pattern"); done; fi
  ((FORCE)) && cmd+=(--force-download); ((DRY_RUN)) && cmd+=(--dry-run)
  # Field note: on some networks the HF CDN (CloudFront) IPv6 endpoints black-hole and hf hangs in
  # SYN_SENT. If a download stalls at 0 bytes, force IPv4 (a sitecustomize shim on PYTHONPATH) or
  # switch network. See the README troubleshooting section.
  printf '\n[%d/%d] %s -> %s\n' "$c" "$total" "$repo" "$dest"
  printf 'Command:'; printf ' %q' "${cmd[@]}"; printf '\n'
  if ((DRY_RUN)); then
    "${cmd[@]}"; printf '%s: dry run only\n' "$alias"
  else
    mkdir -p "$dest"; rm -f "$(marker "$dest")"
    "${cmd[@]}"
    has_payload "$dest" || { printf '%s: download produced no payload files; not marking complete\n' "$alias" >&2; exit 1; }
    write_marker "$dest" "$repo" "$rev" "$include"
    printf '%s: acquisition complete; artifact acceptance remains separate\n' "$alias"
  fi
done

if ((DRY_RUN)); then
  printf '\nDry run finished; nothing was written to %s.\n' "$TARGET_DIR"
else
  printf '\nDone. Acquisition is not artifact verification — check roles with: %s\n' \
    "$LA_ROOT/bin/la-roles.sh"
fi
