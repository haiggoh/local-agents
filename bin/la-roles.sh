#!/usr/bin/env bash
# la-roles.sh — the disk-aware role resolver: show which of YOUR on-disk models fills each role.
#
# This is the single command the offload rules point at. It reads the registry (config.local.sh,
# else config.example.sh) and, for every role, lists the registered models tagged with it, marking
# each ● on-disk (usable now) or ○ not downloaded. The roster can change freely — the rules refer
# to ROLES, this resolves roles → actual available models at call time.
#
# Usage: la-roles.sh            # human table
#        la-roles.sh <role>     # print just the ON-DISK alias(es) for one role (empty if none)
set -uo pipefail

# Resolve symlinks so invocation via a PATH symlink still finds this repo's config (portable).
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
BIN_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$BIN_DIR/../config/config-lib.sh"
la_load_config || exit 1

# Machine-readable single-role query: emit only on-disk aliases (for scripts / quick lookup).
if [ "$#" -ge 1 ]; then
  want="$1"
  while IFS= read -r a; do
    [ -n "$a" ] && la_on_disk "$a" && echo "$a"
  done < <(la_models_for_role "$want")
  exit 0
fi

# Human report. Enumerate the canonical roles ALWAYS (so an unfilled role is visibly unfilled),
# then any extra role tags the config introduced.
extra_roles() {
  local a r rest seen=" "
  for a in "${LA_ALIASES[@]}"; do
    rest="${LA_ROLES[$a]:-}"; rest="${rest// /}"
    IFS=',' read -ra rs <<< "$rest"
    for r in "${rs[@]}"; do
      [ -z "$r" ] && continue
      case " $LA_CANONICAL_ROLES " in *" $r "*) continue;; esac
      case "$seen" in *" $r "*) continue;; esac
      seen="$seen$r "; echo "$r"
    done
  done
}

echo "Local roles (config: ${LA_CONFIG_SOURCE}; models dir: ${LA_MODELS_DIR}):"
echo "  ● = on disk / usable now   ○ = registered but not downloaded"
for role in $LA_CANONICAL_ROLES $(extra_roles); do
  printf "\n[%s]\n" "$role"
  any=0
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    any=1
    if la_on_disk "$a"; then mark="●"; else mark="○"; fi
    size="${LA_SIZE[$a]:-}"; [ -n "$size" ] && size=" (~${size} GB)"
    printf "  %s %-24s serve=%-6s effort=%-6s%s\n" "$mark" "$a" "${LA_SERVE[$a]}" "${LA_EFFORT[$a]}" "$size"
  done < <(la_models_for_role "$role")
  [ "$any" -eq 0 ] && echo "  (no model fills this role — keep such work on the cloud model, or download one)"
done

echo
echo "Multiple ● under one role = your A/B choice. Route by role, not by a hardcoded name."
echo "Download more: install/download-models.sh (interactive)."
