#!/usr/bin/env bash
# test_hotswap_ram_preflight.sh — local-llm-hotswap.sh must run the RAM preflight before it
# launches a NEW server, and must NOT run it when it is only reusing a healthy one.
#
# WHY this exists: launch-claude-agent.sh has been gated by la-ram-preflight.sh since 0.12.0, but
# hotswap — the path every local session's system prompt tells it to use for spawning sub-agents —
# had no gate at all. An autonomous agent could stack servers until RAM died, which is the incident
# that forced the 2026-08-21 hardware reboot. FileVault is on, so a RAM-death reboot locks the
# machine out of remote work: prevention is the only remedy.
#
# The gate must REFUSE, never evict: hotswap is invoked BY sessions that must not be killed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
HOTSWAP="$REPO/bin/local-llm-hotswap.sh"

pass=0 fail=0
ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A stub preflight we control: it records that it ran, and exits with $STUB_EXIT.
make_stub() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/la-ram-preflight.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$LA_TEST_PREFLIGHT_LOG"
exit "${LA_TEST_PREFLIGHT_EXIT:-0}"
STUB
  chmod +x "$WORK/bin/la-ram-preflight.sh"
}

echo "hotswap RAM preflight:"

# 1. STATIC: the script must reference the preflight at all, and honour the documented override.
if grep -q 'la-ram-preflight.sh' "$HOTSWAP"; then
  ok "hotswap calls la-ram-preflight.sh"
else
  bad "hotswap never calls la-ram-preflight.sh"
fi
if grep -q 'LA_SKIP_RAM_PREFLIGHT' "$HOTSWAP"; then
  ok "hotswap honours LA_SKIP_RAM_PREFLIGHT (same override as the launcher)"
else
  bad "hotswap has no LA_SKIP_RAM_PREFLIGHT override"
fi

# 2. The gate must sit AFTER the port scan, so a REUSE path returns SUCCESS_PORT without ever
#    consulting RAM — reusing a live server loads no weights and must never be refused.
scan_line=$(grep -n 'Scanning ports' "$HOTSWAP" | head -1 | cut -d: -f1)
gate_line=$(grep -n 'la-ram-preflight.sh' "$HOTSWAP" | head -1 | cut -d: -f1)
if [ -n "$scan_line" ] && [ -n "$gate_line" ] && [ "$gate_line" -gt "$scan_line" ]; then
  ok "the gate runs after the port scan (reuse is never blocked)"
else
  bad "the gate is not positioned after the port scan (scan=$scan_line gate=$gate_line)"
fi

# 3. The gate must REFUSE rather than evict: no kill on the preflight failure path.
if [ -z "$gate_line" ]; then
  bad "no gate to inspect for eviction (skipped, not passed)"
  gate_block=""
else
  gate_block=$(sed -n "${gate_line},$((gate_line+14))p" "$HOTSWAP")
fi
if [ -z "$gate_block" ]; then
  :
elif printf '%s' "$gate_block" | grep -qE '\b(kill|pkill|la-evict)\b'; then
  bad "the preflight failure path kills something — it must only refuse"
else
  ok "the preflight failure path refuses without killing anything"
fi

# 4. BEHAVIOURAL: with a failing stub preflight on PATH, hotswap must exit non-zero and must NOT
#    print SUCCESS_PORT. Run against an unavailable-port range so no real server can be reused.
make_stub
export LA_TEST_PREFLIGHT_LOG="$WORK/ran.log"; : > "$LA_TEST_PREFLIGHT_LOG"
alias_to_try="$( . "$REPO/config/config-lib.sh"; la_load_config >/dev/null 2>&1 && la_resolve_target operator 2>/dev/null )"
[ -n "$alias_to_try" ] || alias_to_try="qwen-3.8-operator"

# Point hotswap at the stub by shadowing its own bin/ copy inside a scratch clone of bin/.
SCRATCH="$WORK/repo"; mkdir -p "$SCRATCH"
# -L dereferences: config/config.local.sh may be a symlink to the real private registry, and this
# test APPENDS to the scratch config below. Copying the link would append to the real file.
cp -RL "$REPO/bin" "$REPO/config" "$SCRATCH/" 2>/dev/null
for _f in "$SCRATCH/config/config.local.sh" "$SCRATCH/config/config.example.sh"; do
  [ -L "$_f" ] && { echo "FATAL: $_f is a symlink — refusing to write through it" >&2; exit 1; }
done
cp "$WORK/bin/la-ram-preflight.sh" "$SCRATCH/bin/la-ram-preflight.sh"
# SAFETY, learned the hard way: config.example.sh assigns LA_PORT_START with a plain `=`, so an
# environment override does NOT survive la_load_config and an early version of this test launched a
# real 16GB server on a live port. Append the overrides to the scratch config so they are the LAST
# assignments, and point the backend binaries at nothing — the gate is what we are testing, and no
# code path past it may be able to start a server.
{
  echo ''
  echo 'LA_PORT_START=9990'
  echo 'LA_PORT_MAX=9990'
  echo 'LA_RAPID_BIN=/nonexistent/rapid-mlx'
} >> "$SCRATCH/config/config.example.sh"
[ -f "$SCRATCH/config/config.local.sh" ] && {
  echo ''
  echo 'LA_PORT_START=9990'
  echo 'LA_PORT_MAX=9990'
  echo 'LA_RAPID_BIN=/nonexistent/rapid-mlx'
} >> "$SCRATCH/config/config.local.sh"

out=$(LA_TEST_PREFLIGHT_EXIT=1 \
      "$SCRATCH/bin/local-llm-hotswap.sh" "$alias_to_try" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a failing preflight makes hotswap exit non-zero (rc=$rc)"
else
  bad "a failing preflight did not stop hotswap (rc=0)"
fi
if printf '%s' "$out" | grep -q 'SUCCESS_PORT='; then
  bad "hotswap printed SUCCESS_PORT despite a failing preflight"
else
  ok "no SUCCESS_PORT is printed when the preflight fails"
fi
if [ -s "$LA_TEST_PREFLIGHT_LOG" ]; then
  ok "the preflight was actually invoked (proves the negative above is real)"
else
  bad "the preflight was never invoked — the failing-exit result proves nothing"
fi

# 5. The override must let it through: same stub, same failure, LA_SKIP_RAM_PREFLIGHT=1 set.
: > "$LA_TEST_PREFLIGHT_LOG"
out=$(LA_TEST_PREFLIGHT_EXIT=1 LA_SKIP_RAM_PREFLIGHT=1 \
      "$SCRATCH/bin/local-llm-hotswap.sh" "$alias_to_try" 2>&1); rc=$?
if printf '%s' "$out" | grep -qi 'at your own risk\|continuing'; then
  ok "LA_SKIP_RAM_PREFLIGHT=1 continues past a failing preflight"
else
  bad "LA_SKIP_RAM_PREFLIGHT=1 did not continue past a failing preflight"
fi

# 6. REGRESSION (found 2026-09-12 by mutation-testing this very gate): question 0 of the preflight
#    claimed "$ALIAS is ALREADY served on port N — no new weights load" while hotswap REFUSED to
#    reuse that same server, because the preflight ignored the served spoof id and the spec-config
#    hash that hotswap requires to match. The two disagreed, so a request that really did load 16GB
#    of fresh weights sailed through an impossible RAM floor. A gate that fails OPEN is worse than
#    no gate, because callers trust it. The preflight's reuse test must be no looser than hotswap's.
echo
echo "preflight/hotswap reuse agreement:"
q0=$(sed -n '/question 0: is this model already being served/,/^done$/p' bin/la-ram-preflight.sh)
if printf '%s' "$q0" | grep -q 'spec_config_sha256'; then
  ok "question 0 checks the spec-config hash (as hotswap does)"
else
  bad "question 0 ignores spec_config_sha256 — it can credit a reuse hotswap will refuse"
fi
if printf '%s' "$q0" | grep -q 'LA_CUR_SPOOF\|SPOOF'; then
  ok "question 0 checks the served spoof id (as hotswap does)"
else
  bad "question 0 ignores the served spoof id — a stale served_id passes as reusable"
fi
if printf '%s' "$q0" | grep -q 'LA_HOTSWAP_FORCE_FRESH'; then
  ok "question 0 respects LA_HOTSWAP_FORCE_FRESH (a forced relaunch DOES load weights)"
else
  bad "question 0 ignores LA_HOTSWAP_FORCE_FRESH — a forced relaunch is credited as free"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
