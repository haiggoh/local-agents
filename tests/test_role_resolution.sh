#!/usr/bin/env bash
# test_role_resolution.sh — la_resolve_target must accept a ROLE NAME wherever an alias is accepted.
#
# WHY this exists: the shell aliases and every `<alias>` argument used to hardcode a model name
# (qwen-3.6-operator), so they went stale every time the roster moved while still "working" —
# launching last month's model in silence. A role name resolves against what is on disk NOW.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=/dev/null
. config/config-lib.sh
la_load_config >/dev/null 2>&1 || { echo "FAIL: config would not load"; exit 1; }

pass=0 fail=0
ok()   { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

echo "la_resolve_target:"

# 1. An alias passes through untouched — the existing contract must not change.
got="$(la_resolve_target qwen-3.6-operator)"
check "an existing alias resolves to itself" "$got" "qwen-3.6-operator"

got="$(la_resolve_target operator)"
check "operator defaults to Qwen3.8 MTP" "$got" "qwen-3.8-operator"

got="$(la_resolve_target reasoner)"
check "reasoner defaults to Qwen3.8 MTP" "$got" "qwen-3.8-thinking"

la_lookup qwen-3.8-operator || {
  bad "qwen-3.8-operator lookup failed"
}
case "${LA_CUR_RAPID_SPEC_CONFIG:-}" in
  *'"method":"mtp"'*Qwen3.8-27B-MTP-4bit*)
    ok "operator default carries the Qwen3.8 MTP configuration"
    ;;
  *)
    bad "operator default lacks the Qwen3.8 MTP configuration"
    ;;
esac

# 2. A role name resolves to an ON-DISK alias bound to that role.
for role in operator reasoner validator utility; do
  got="$(la_resolve_target "$role")" || { bad "role '$role' resolved to nothing"; continue; }
  if [ -z "$got" ]; then bad "role '$role' resolved to empty"; continue; fi
  la_lookup "$got"   || { bad "role '$role' -> '$got' which is not a registered alias"; continue; }
  la_on_disk "$got"  || { bad "role '$role' -> '$got' which is NOT on disk"; continue; }
  ok "role '$role' -> on-disk alias '$got'"
done

# 3. Resolution prefers what is on disk: an off-disk binding must never win over an on-disk one.
#    qwen-80b-thinking is registered but retired/absent; assert nothing off-disk is ever returned.
for role in operator reasoner validator utility; do
  got="$(la_resolve_target "$role" 2>/dev/null)" || continue
  [ -n "$got" ] || continue
  la_on_disk "$got" || bad "role '$role' returned off-disk '$got'"
done
ok "no role returns an off-disk alias"

# 3b. PLANTED POSITIVE: bind an off-disk model AHEAD of an on-disk one under a synthetic role.
#     Without this, the suite cannot detect a missing on-disk filter at all — every real role's
#     first binding happens to be on disk, so dropping the filter changes nothing observable.
#     (Verified by mutation: removing `la_on_disk` from la_resolve_target passed 8/8 before this.)
la_register _test_absent_model  _test_absent_dir_does_not_exist  mlx qwen "" false claude-opus-5 high "" "" 1
la_role _testrole _test_absent_model  high both      # off disk, bound FIRST
la_role _testrole qwen-3.6-operator   high both      # on disk, bound second
got="$(la_resolve_target _testrole 2>/dev/null)"
check "an off-disk binding is skipped for the on-disk one" "$got" "qwen-3.6-operator"

# 4. Unknown input fails, and does NOT silently fall back to some default.
if got="$(la_resolve_target definitely-not-a-model 2>/dev/null)"; then
  bad "unknown target returned '$got' instead of failing"
else
  ok "unknown target fails (no silent fallback)"
fi

# 5. An alias that is registered but has NO weights must still resolve as itself (the RAM
#    preflight and load path own that error) — resolution is naming, not availability policy.
got="$(la_resolve_target qwen-80b-thinking 2>/dev/null)"
check "a registered-but-absent ALIAS still resolves to itself" "$got" "qwen-80b-thinking"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
