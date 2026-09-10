#!/usr/bin/env bash
# test_setup_shortcuts.sh — the alias installer must actually WRITE the block, stay idempotent,
# and preserve the rc file's mode.
#
# WHY: during the 2026-09-10 role-alias rewrite the block-assembly edit accidentally removed the
# `touch`/`printf >>` write steps. The installer still printed "✓ local-* aliases written to ..."
# and exited 0 while creating no file at all. Success text is not evidence; only the file is.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok(){ printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
run(){ HOME="$H" SHELL=/bin/zsh bash "$REPO/install/setup-shortcuts.sh" >/dev/null 2>&1; }

echo "setup-shortcuts.sh:"
run || bad "installer exited non-zero"
RC="$H/.zshrc"

# 1. The file must EXIST and CONTAIN the block — the bug was a happy exit with no write.
[ -f "$RC" ] && ok "the rc file is actually created" || bad "no rc file was written"
grep -qF "# >>> local-agents aliases" "$RC" 2>/dev/null && ok "opening fence present" || bad "opening fence missing"
grep -qF "# <<< local-agents aliases <<<" "$RC" 2>/dev/null && ok "closing fence present" || bad "closing fence missing"

# 2. Every advertised alias must be present (the help text and the block must not drift apart).
for a in local-menu local-operator local-fast local-xhigh local-thinking local-validator \
         local-window local-dispatch local-roles local-disk local-logs; do
  grep -qE "^alias $a=" "$RC" && ok "alias $a written" || bad "alias $a MISSING from the block"
done

# 3. Session aliases must name ROLES, not a hardcoded model — that is the whole point of the
#    rewrite, and a regression would be silent (the alias would still work, on a stale model).
grep -qE '^alias local-operator=.*launch-claude-agent\.sh operator"?$' "$RC" \
  && ok "local-operator targets the ROLE, not a model name" \
  || bad "local-operator does not target a role"
if grep -qE '^alias local-(operator|fast|xhigh|thinking|validator)=.*(qwen|deepseek|llama|gemma|kat)' "$RC"; then
  bad "a session alias still hardcodes a MODEL name"
else
  ok "no session alias hardcodes a model name"
fi

# 4. Idempotent: a second run must not duplicate the block.
run
n="$(grep -cF "# >>> local-agents aliases" "$RC")"
[ "$n" = "1" ] && ok "re-running does not duplicate the block" || bad "block appears $n times after 2 runs"

# 5. Mode preserved EXACTLY. Use a distinctive mode (640), not 600: `mktemp` itself creates 600,
#    so a redirect-and-move bug that recreates the file coincidentally yields 600 and a 600-based
#    assertion passes while the inode was in fact replaced. Verified by mutation: swapping the
#    in-place `cat >` for `mv` survived a 600 check and is caught by this one.
chmod 640 "$RC"; run
m="$(stat -f '%Lp' "$RC")"
[ "$m" = "640" ] && ok "rc file mode preserved exactly (640)" || bad "rc mode changed 640 -> $m"

# 6. The emitted block must be valid shell.
zsh -n "$RC" 2>/dev/null && ok "emitted rc parses under zsh" || bad "emitted rc is not valid zsh"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
