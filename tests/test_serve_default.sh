#!/usr/bin/env bash
# tests/test_serve_default.sh — the backend-resolution layer: which engine a registration gets.
#
# Usage: bash tests/test_serve_default.sh
#
# WHAT THIS PROTECTS. As of 2026-08-31 Rapid-MLX is the DEFAULT MLX backend, reached by declaring
# the GENERIC value `serve=mlx` (or leaving the field empty) rather than by naming rapid in every
# registration. That indirection is only safe if three things hold, and each is a test below:
#   1. a generic declaration resolves to LA_DEFAULT_MLX_BACKEND, so ONE line flips the whole roster;
#   2. an explicit pin is NEVER substituted, in either direction — that is what keeps the vllm-mlx
#      legacy lane reachable and keeps recorded per-backend evidence attributable;
#   3. the resolved backend is always VISIBLE alongside the declaration it came from, so no report
#      claims the config file said something it did not.
# Plus the guards that make a wrong value fail EARLY and loudly instead of at weight-load time:
# an unknown backend, a bad machine default, and GGUF pointed at an MLX engine.
#
# METHOD — sandbox, never the live machine. config-lib.sh resolves its own directory from
# BASH_SOURCE, so copying it into a mktemp dir beside a GENERATED config.local.sh gives a fully
# controlled registry. The real (gitignored) config.local.sh is never read and never written.
# No server is started and no port is bound: this file tests resolution, not serving. The two
# tests that DO invoke the real hotswap script pass HOTSWAP_READY_TIMEOUT=4 and a nonexistent
# LA_VENV / LA_RAPID_BIN, so that even a MUTATED resolver which sends them down an unexpected
# launch branch fails in seconds instead of blocking on the 480s readiness wait. A suite that
# hangs under mutation cannot demonstrate that it detects the mutation.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
check() {  # $1=0/1 condition, $2=label
  if [ "$1" -eq 0 ]; then PASS=$((PASS+1)); printf '  PASS: %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$2"; fi
}
assert_eq() {  # $1=expected, $2=actual, $3=label
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); printf '  PASS: %s\n' "$3"
  else FAIL=$((FAIL+1)); printf '  FAIL: %s\n     expected: %s\n     actual:   %s\n' "$3" "$1" "$2"; fi
}
assert_grep() {  # $1=needle, $2=haystack, $3=label
  printf '%s' "$2" | grep -qF -- "$1"; check $? "$3"
}
assert_no_grep() {  # $1=needle, $2=haystack, $3=label
  printf '%s' "$2" | grep -qF -- "$1" && check 1 "$3" || check 0 "$3"
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-serve-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/config"
cp "$REPO/config/config-lib.sh" "$SB/config/config-lib.sh"

# write_config <body> — generate the sandbox config.local.sh. Every test drives the REAL loader
# (la_load_config -> la_finalize_serve), so what is under test is the shipped code path.
write_config() { printf '%s\n' "$1" > "$SB/config/config.local.sh"; }

# load_and <expr> — source the copied lib in a fresh bash, load the sandbox config, run <expr>.
# stdout and stderr are returned together so warnings and errors are assertable; the loader's exit
# status is echoed on the last line as RC=<n>.
load_and() {
  /opt/homebrew/bin/bash -c '
    . "'"$SB"'/config/config-lib.sh"
    la_load_config; rc=$?
    '"$1"'
    echo "RC=$rc"
  ' 2>&1
}

echo "== 1. a GENERIC declaration resolves to the machine default =="
write_config 'la_register g-mlx   FakeModel mlx    qwen "" false claude-opus-5 high
la_register g-empty FakeModel ""     qwen "" false claude-opus-5 high
la_register g-auto  FakeModel auto   qwen "" false claude-opus-5 high'
out="$(load_and 'echo "mlx=${LA_SERVE[g-mlx]} empty=${LA_SERVE[g-empty]} auto=${LA_SERVE[g-auto]}"')"
assert_grep 'mlx=rapid empty=rapid auto=rapid' "$out" 'serve=mlx / "" / auto all resolve to rapid'
assert_grep 'RC=0' "$out" 'loader succeeds on a generic-only registry'

echo "== 2. the default is rapid WITHOUT the config naming it =="
# The point of the flip: a config that says nothing about backends still gets rapid. If this fails
# the default lives somewhere else and the "one-line rollback" claim is false.
out="$(load_and 'echo "default=$LA_DEFAULT_MLX_BACKEND"')"
assert_grep 'default=rapid' "$out" 'LA_DEFAULT_MLX_BACKEND defaults to rapid'

echo "== 3. ONE line flips the whole roster (the documented rollback) =="
write_config 'LA_DEFAULT_MLX_BACKEND=vllm
la_register g-mlx    FakeModel mlx   qwen "" false claude-opus-5 high
la_register pin-rapid FakeModel rapid qwen "" false claude-opus-5 high'
out="$(load_and 'echo "generic=${LA_SERVE[g-mlx]} pinned=${LA_SERVE[pin-rapid]}"')"
assert_grep 'generic=vllm' "$out" 'LA_DEFAULT_MLX_BACKEND=vllm sends generic registrations to vllm'
assert_grep 'pinned=rapid' "$out" 'an explicit rapid pin SURVIVES a vllm default (pins are never substituted)'

echo "== 4. pins are never substituted in the other direction either =="
write_config 'la_register pin-vllm  FakeModel vllm   qwen "" false claude-opus-5 high
la_register pin-mlxlm FakeModel mlx_lm llama "" false claude-haiku-4-5-20251001 low
la_register pin-gguf  FakeGGUF  llama_cpp mistral "" false claude-opus-5 high'
out="$(load_and 'echo "v=${LA_SERVE[pin-vllm]} m=${LA_SERVE[pin-mlxlm]} l=${LA_SERVE[pin-gguf]}"')"
assert_grep 'v=vllm m=mlx_lm l=llama_cpp' "$out" 'vllm / mlx_lm / llama_cpp pins pass through untouched'

echo "== 5. llama_cpp is NOT reachable from a generic value =="
# GGUF must be opted into explicitly. If a generic value could ever resolve to llama_cpp, flipping
# the MLX default would silently reroute MLX models to an engine that cannot load them.
write_config 'LA_DEFAULT_MLX_BACKEND=llama_cpp
la_register g-mlx FakeModel mlx qwen "" false claude-opus-5 high'
out="$(load_and 'true')"
assert_grep 'is not an MLX backend' "$out" 'llama_cpp is refused as the MLX default'
assert_no_grep 'RC=0' "$out" 'a bad machine default fails the loader (non-zero)'

echo "== 6. legacy spellings normalize =="
write_config 'la_register a FakeModel vllm-mlx  qwen "" false claude-opus-5 high
la_register b FakeModel rapid-mlx qwen "" false claude-opus-5 high
la_register c FakeGGUF  llama.cpp qwen "" false claude-opus-5 high
la_register d FakeModel mlx-lm    qwen "" false claude-opus-5 high'
out="$(load_and 'echo "a=${LA_SERVE[a]} b=${LA_SERVE[b]} c=${LA_SERVE[c]} d=${LA_SERVE[d]}"')"
assert_grep 'a=vllm b=rapid c=llama_cpp d=mlx_lm' "$out" 'vllm-mlx/rapid-mlx/llama.cpp/mlx-lm normalize to canonical names'

echo "== 7. an unknown backend is a hard config error, naming the model =="
write_config 'la_register typo FakeModel rapd qwen "" false claude-opus-5 high'
out="$(load_and 'true')"
assert_grep "model 'typo' declares serve='rapd'" "$out" 'the error names the offending alias and value'
assert_no_grep 'RC=0' "$out" 'an unknown backend fails the loader rather than falling through to vllm'

echo "== 8. GGUF on an MLX backend warns, naming the alias and the fix =="
write_config 'la_register oops devstral2-q5-gguf mlx mistral "" false claude-opus-5 high'
out="$(load_and 'echo "resolved=${LA_SERVE[oops]}"')"
assert_grep "'oops' looks like a GGUF artifact" "$out" 'the GGUF-on-MLX warning names the alias'
assert_grep 'Pin serve=llama_cpp' "$out" 'the warning states the fix'
assert_grep 'RC=0' "$out" 'the GGUF warning is a WARNING — it does not block a load'

echo "== 9. the declaration is preserved, and displayed alongside what it resolved to =="
write_config 'la_register g-mlx    FakeModel mlx  qwen "" false claude-opus-5 high
la_register pin-vllm FakeModel vllm qwen "" false claude-opus-5 high'
out="$(load_and 'echo "decl=${LA_SERVE_DECLARED[g-mlx]}"; echo "disp_generic=$(la_serve_display g-mlx)"; echo "disp_pin=$(la_serve_display pin-vllm)"')"
assert_grep 'decl=mlx' "$out" 'LA_SERVE_DECLARED keeps what the config actually said'
assert_grep 'disp_generic=rapid (mlx->rapid)' "$out" 'a resolved backend is shown WITH its declaration'
assert_grep 'disp_pin=vllm' "$out" 'a pin displays bare, with no misleading arrow'

echo "== 10. resolution is idempotent (finalize reads the declaration, not its own output) =="
write_config 'la_register g-mlx FakeModel mlx qwen "" false claude-opus-5 high'
out="$(load_and 'la_finalize_serve; la_finalize_serve; echo "twice=${LA_SERVE[g-mlx]} decl=${LA_SERVE_DECLARED[g-mlx]}"')"
assert_grep 'twice=rapid decl=mlx' "$out" 're-running la_finalize_serve does not corrupt either value'

echo "== 11. la_lookup hands the RESOLVED backend to callers =="
write_config 'la_register g-mlx FakeModel mlx qwen "" false claude-opus-5 high'
out="$(load_and 'la_lookup g-mlx; echo "cur=$LA_CUR_SERVE"')"
assert_grep 'cur=rapid' "$out" 'LA_CUR_SERVE is concrete, so consumers need no resolution logic'

echo "== 12. a retired alias redirects instead of dead-ending =="
write_config 'la_register qwen-x FakeModel mlx qwen "" false claude-opus-5 high
la_retired old-name "Rapid is now the default -> use qwen-x"'
out="$(load_and 'la_retired_hint old-name; echo "hint_rc=$?"; la_retired_hint never-existed; echo "unknown_rc=$?"')"
assert_grep 'use qwen-x' "$out" 'a retired alias prints where it went'
assert_grep 'hint_rc=0' "$out" 'la_retired_hint reports success for a known retirement'
assert_grep 'unknown_rc=1' "$out" 'a genuinely unknown alias gets no invented hint'
out="$(load_and 'la_aliases_help')"
assert_grep 'retired aliases' "$out" 'retirements are listed in the aliases help, where the error sends you'

echo "== 13. Rapid executable discovery: brew wins, then PATH, then NEWEST venv =="
# Version-ordered, not lexical: 0.9.x must not beat 0.13.x, and 0.12.18 must not beat 0.13.2.
FAKEHOME="$SB/fakehome"; mkdir -p "$FAKEHOME/.venvs/rapid-mlx-0.12.18/bin" \
  "$FAKEHOME/.venvs/rapid-mlx-0.13.2/bin" "$FAKEHOME/.venvs/rapid-mlx-0.9.14/bin" "$FAKEHOME/brew"
for v in 0.12.18 0.13.2 0.9.14; do
  printf '#!/bin/sh\n' > "$FAKEHOME/.venvs/rapid-mlx-$v/bin/rapid-mlx"
  chmod +x "$FAKEHOME/.venvs/rapid-mlx-$v/bin/rapid-mlx"
done
out="$(/opt/homebrew/bin/bash -c '
  . "'"$SB"'/config/config-lib.sh"
  HOME="'"$FAKEHOME"'"; PATH=/usr/bin:/bin
  la_discover_rapid_bin' 2>&1)"
assert_grep 'rapid-mlx-0.13.2/bin/rapid-mlx' "$out" 'the NEWEST venv wins by version sort (0.13.2 > 0.12.18 > 0.9.14)'
# A PATH install outranks any venv.
printf '#!/bin/sh\n' > "$FAKEHOME/brew/rapid-mlx"; chmod +x "$FAKEHOME/brew/rapid-mlx"
out="$(/opt/homebrew/bin/bash -c '
  . "'"$SB"'/config/config-lib.sh"
  HOME="'"$FAKEHOME"'"; PATH="'"$FAKEHOME"'/brew:/usr/bin:/bin"
  la_discover_rapid_bin' 2>&1)"
assert_grep "$FAKEHOME/brew/rapid-mlx" "$out" 'an on-PATH rapid-mlx outranks the versioned venvs'
# Nothing anywhere -> empty, non-zero. Callers must be able to tell "none" from "found something".
out="$(/opt/homebrew/bin/bash -c '
  . "'"$SB"'/config/config-lib.sh"
  HOME="'"$SB"'/emptyhome"; PATH=/usr/bin:/bin
  la_discover_rapid_bin; echo "rc=$?"' 2>&1)"
assert_grep 'rc=1' "$out" 'discovery reports failure when no rapid-mlx exists anywhere'

echo "== 14. an explicit LA_RAPID_BIN always beats discovery =="
write_config 'LA_RAPID_BIN=/pinned/rapid-mlx
la_register g-mlx FakeModel mlx qwen "" false claude-opus-5 high'
out="$(load_and 'echo "bin=$LA_RAPID_BIN"')"
assert_grep 'bin=/pinned/rapid-mlx' "$out" 'a pinned LA_RAPID_BIN is not overwritten by discovery'

echo "== 15. csl offers only backends that expose Anthropic /v1/messages =="
# rapid and vllm do; mlx_lm.server and llama-server do not, so they must stay out of the session
# menu — including when the rapid one arrived via a GENERIC declaration.
write_config 'la_register g-mlx    FakeModel mlx       qwen    "" false claude-opus-5 high
la_register pin-vllm FakeModel vllm      qwen    "" false claude-opus-5 high
la_register pin-mlxlm FakeModel mlx_lm   llama   "" false claude-haiku-4-5-20251001 low
la_register pin-gguf FakeGGUF   llama_cpp mistral "" false claude-opus-5 high'
out="$(load_and '
  SESSION=""
  for a in "${LA_ALIASES[@]}"; do
    case "${LA_SERVE[$a]:-}" in rapid|vllm) SESSION="$SESSION $a" ;; esac
  done
  echo "session:$SESSION"')"
assert_grep 'session: g-mlx pin-vllm' "$out" 'generic-resolved rapid and pinned vllm are session-capable'
assert_no_grep 'pin-mlxlm' "$out" 'mlx_lm stays out of the session menu'
assert_no_grep 'pin-gguf' "$out" 'llama_cpp stays out of the session menu'

echo "== 16. hotswap REFUSES a GGUF registration instead of loading it into MLX =="
# The real script, unmodified, in a sandboxed HOME. Exit 3 and an actionable message, NOT a
# fall-through into the vllm branch.
HS="$SB/hsbox"; mkdir -p "$HS/config" "$HS/bin" "$HS/home/.models/FakeGGUF" "$HS/home/.claude/logs/local-agents-configs"
cp "$REPO/config/config-lib.sh" "$HS/config/"; cp "$REPO/bin/local-llm-hotswap.sh" "$HS/bin/"
head -c 2097152 /dev/zero > "$HS/home/.models/FakeGGUF/model-Q5_K_M.gguf"
cat > "$HS/config/config.local.sh" <<'CFG'
LA_MODELS_DIR="$HOME/.models"
LA_PORT_START=8100
LA_PORT_MAX=8110
LA_RAPID_BIN=/nonexistent/rapid-mlx
LA_VENV=/nonexistent/venv/bin
la_register pin-gguf FakeGGUF llama_cpp mistral "" false claude-opus-5 high
CFG
hotswap() {  # run the real script in the sandbox, bounded so no branch can block the suite
  HOME="$HS/home" HOTSWAP_READY_TIMEOUT=4 /opt/homebrew/bin/bash "$HS/bin/local-llm-hotswap.sh" "$@" 2>&1
}
out="$(hotswap pin-gguf)"; rc=$?
assert_eq 3 "$rc" 'hotswap exits 3 on a serve=llama_cpp registration'
assert_grep 'launches MLX backends only' "$out" 'the refusal explains why'
assert_grep 'llama-server' "$out" 'the refusal names the tool that DOES serve it'
assert_no_grep 'SUCCESS_PORT' "$out" 'nothing was started'

echo "== 17. hotswap announces the backend it resolved, before loading anything =="
out="$(hotswap no-such-alias)"
assert_grep 'Registered aliases' "$out" 'an unknown alias lists what IS registered'
cat > "$HS/config/config.local.sh" <<'CFG'
LA_MODELS_DIR="$HOME/.models"
LA_PORT_START=8100
LA_PORT_MAX=8110
LA_RAPID_BIN=/nonexistent/rapid-mlx
LA_VENV=/nonexistent/venv/bin
la_register g-mlx FakeGGUFless mlx qwen "" false claude-opus-5 high
CFG
mkdir -p "$HS/home/.models/FakeGGUFless"; head -c 2097152 /dev/zero > "$HS/home/.models/FakeGGUFless/weight.bin"
out="$(hotswap g-mlx)"
assert_grep 'backend: rapid (mlx->rapid)' "$out" 'the resolved backend AND its declaration are printed'
assert_grep 'machine default: rapid' "$out" 'the machine default is stated too'
# And when the default backend has no executable, the failure names the brew route and the rollback.
assert_grep 'brew install rapid-mlx' "$out" 'a missing rapid binary points at the maintained install'
assert_grep 'LA_DEFAULT_MLX_BACKEND=vllm' "$out" 'a missing rapid binary points at the one-line fallback'

echo
echo "-------------------------------------------"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
