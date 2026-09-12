#!/usr/bin/env bash
# test_spoof_identity.sh — the Claude-model spoof ids must have ONE source of truth, and a running
# server's advertised ids must be what every consumer trusts.
#
# WHY this exists: `claude-opus-5,claude-opus-4-8` was written out literally on 40 la_register
# lines. When Anthropic ships the next model (5-2, 6, …) that is 40 edits in the private overlay
# plus a scatter of hardcoded defaults in bin/, and any line missed keeps working while serving the
# WRONG id — a silent-stale failure, the same shape as hardcoded-names-in-shortcuts-go-stale.
#
# The asymmetry that makes it bite: vllm-mlx serves EVERY id in the list, so a client asking for
# either one is satisfied. Rapid takes a single --served-model-name and gets only the FIRST, so on
# Rapid the fallback id in the list is not actually served. Consumers must therefore read the ids
# the server advertises rather than assuming the configured primary.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"

pass=0 fail=0
ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

echo "central spoof source of truth:"

# 1. config-lib must DEFINE the canonical ids, so a new Claude model is one edit, not forty.
if grep -qE '^\s*:?\s*"?\$?\{?LA_SPOOF_CURRENT' config/config-lib.sh; then
  ok "config-lib defines LA_SPOOF_CURRENT"
else
  bad "config-lib does not define LA_SPOOF_CURRENT"
fi
if grep -q 'LA_SPOOF_DEFAULT' config/config-lib.sh; then
  ok "config-lib defines LA_SPOOF_DEFAULT (the list la_register falls back to)"
else
  bad "config-lib defines no LA_SPOOF_DEFAULT"
fi

# 2. la_register must accept an EMPTY / omitted spoof field and fill it from the central default,
#    so a registration does not have to name any Claude model at all.
out=$(bash -c '
  . config/config-lib.sh
  la_load_config >/dev/null 2>&1
  la_register spoof-test-alias SomeDir mlx qwen "" false "" high
  echo "${LA_SPOOF[spoof-test-alias]}"
' 2>/dev/null)
if [ -n "$out" ] && [ "$out" != "" ]; then
  ok "an empty spoof field inherits the central default ($out)"
else
  bad "an empty spoof field stayed empty — no central default applied"
fi

# 3. The shipped example config must not hand out a STALE primary. It listed only
#    claude-opus-4-8 while the real overlay led with claude-opus-5, which is exactly how a
#    fresh checkout (or a worktree without the gitignored overlay) silently disagrees with
#    production — the confusion that started this work.
if grep -q 'la_register' config/config.example.sh; then
  ex_spoofs=$(grep 'la_register' config/config.example.sh | grep -o 'claude-[a-z0-9.,-]*' | sort -u)
  cur=$(bash -c '. config/config-lib.sh; echo "${LA_SPOOF_CURRENT:-}"' 2>/dev/null)
  if [ -z "$cur" ]; then
    bad "cannot read LA_SPOOF_CURRENT to compare the example config against"
  elif printf '%s\n' "$ex_spoofs" | grep -q "^${cur}$" || \
       ! printf '%s\n' "$ex_spoofs" | grep -q 'claude-opus'; then
    ok "the example config leads with the current id, or names no opus id at all"
  else
    bad "the example config's opus id(s) [$(echo $ex_spoofs | tr '\n' ' ')] do not lead with $cur"
  fi
fi

echo
echo "Rapid single-id asymmetry:"

# 4. Rapid accepts ONE --served-model-name, so only the FIRST id in the list is reachable. Any
#    consumer that assumes the whole list is served will 404 against a Rapid server. hotswap must
#    say so where the flag is built, so the next person does not add a second id and expect it.
if grep -B4 -A2 'served-model-name' bin/local-llm-hotswap.sh | grep -qiE 'single|only the first|one id'; then
  ok "hotswap documents that Rapid serves only the first id"
else
  bad "hotswap does not document Rapid's single-id limit at --served-model-name"
fi

# 5. The launcher already intersects the configured list with /v1/models. That intersection is the
#    correct pattern under Rapid and must not regress into trusting the configured primary.
if grep -q 'v1/models' bin/launch-claude-agent.sh && \
   grep -q 'LA_CUR_SPOOF' bin/launch-claude-agent.sh; then
  ok "the launcher intersects the configured list with what the port advertises"
else
  bad "the launcher no longer intersects configured ids against /v1/models"
fi

# 6. The preflight's reuse test compares against the SERVED id. Under Rapid that must be the
#    served_id recorded for the port (or the advertised list) — never a second, unserved candidate.
if grep -q 'SPOOF_PRIMARY' bin/la-ram-preflight.sh; then
  ok "the preflight compares the served id, matching hotswap's reuse test"
else
  bad "the preflight no longer compares a served spoof id"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
