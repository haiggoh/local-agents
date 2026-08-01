#!/usr/bin/env bash
# la-roles.sh — the disk-aware role resolver: show which of YOUR on-disk models (and at what effort)
# fills each role. This is the single command the offload rules point at.
#
# Roles are defined once, as la_role bindings (role × model × effort) in the config — the SAME source
# the csl launch menu is generated from, so the two never drift. For each role this lists its
# bindings, marking ● usable now (weights on disk) or ○ not downloaded, with the effort and mode.
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

# Machine-readable single-role query: emit only on-disk aliases (deduped) for scripts / quick lookup.
if [ "$#" -ge 1 ]; then
  want="$1"; seen=" "
  while IFS='|' read -r alias effort mode; do
    [ -n "$alias" ] || continue
    case "$seen" in *" $alias "*) continue;; esac
    la_on_disk "$alias" && { echo "$alias"; seen="$seen$alias "; }
  done < <(la_role_bindings_for "$want")
  exit 0
fi

# Human report. Enumerate the canonical roles ALWAYS (so an unfilled role is visibly unfilled), plus
# any extra roles that have bindings.
roles_to_show() {
  local r seen=" "
  for r in $LA_CANONICAL_ROLES; do echo "$r"; seen="$seen$r "; done
  while IFS= read -r r; do case "$seen" in *" $r "*) ;; *) echo "$r";; esac; done < <(la_bound_roles)
}

echo "Local roles (config: ${LA_CONFIG_SOURCE}; models dir: ${LA_MODELS_DIR}):"
echo "  ● = on disk / usable now   ○ = registered but not downloaded   [mode] = dispatch/session/both"
while IFS= read -r role; do
  printf "\n[%s]\n" "$role"
  any=0
  while IFS='|' read -r alias effort mode; do
    [ -n "$alias" ] || continue
    any=1
    if la_on_disk "$alias"; then mark="●"; else mark="○"; fi
    size="${LA_SIZE[$alias]:-}"; [ -n "$size" ] && size=" (~${size} GB)"
    printf "  %s %-24s effort=%-6s [%s]%s\n" "$mark" "$alias" "${effort:-?}" "${mode:-both}" "$size"
  done < <(la_role_bindings_for "$role")
  [ "$any" -eq 0 ] && echo "  (no model bound to this role — keep such work on the cloud model, or bind/download one)"
done < <(roles_to_show)

echo
echo "Same alias under two roles/efforts = the (model × effort) split. Several ● in one role = A/B."
echo "Route by role, not by a hardcoded name. Download more: install/download-models.sh (interactive)."
