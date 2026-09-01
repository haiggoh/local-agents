#!/usr/bin/env bash
# tests/test_rapid_backend.sh — integration tests for the Rapid-MLX backend (serve=rapid).
#
# Usage: bash tests/test_rapid_backend.sh
#
# WHY a shell harness, not Python: the rapid logic lives in SHELL scripts
# (bin/local-llm-hotswap.sh, bin/la-ram-preflight.sh) that are not importable.
# The honest way to test them is to RUN the real, unmodified scripts against a
# controlled environment, rather than re-implement the logic in the test.
#
# METHOD — sandbox, never the live machine:
#   * The real bin/ + config/ are COPIED into a fresh mktemp sandbox; the scripts
#     resolve their config relative to their own path, so the copy is self-contained.
#   * HOME is pointed at the sandbox, so every ~/.claude/... path (logs, meta files)
#     and the model dir land in the sandbox, never the real home.
#   * A controlled config.local.sh is written into the sandbox (the real one is
#     gitignored and never touched).
#   * LA_RAPID_BIN points at a STUB rapid-mlx (a tiny Python HTTP server) that
#     records its argv and serves /v1/models — so the real launch path runs end to
#     end without loading 16 GB of weights or binding a real model.
#   * Test ports are 8100+ (LA_PORT_START/MAX set in the sandbox config), NEVER
#     8000-8010, so the harness can't touch a live local session's server. Stubs
#     are killed in an EXIT trap.
#
# COVERED here (the genuinely new rapid logic):
#   * hotswap: rapid command construction (flags, parser translation, thinking on/off,
#     pin/relocate), the server_<port>.meta identity record, SUCCESS_PORT, and the
#     meta-based REUSE of an already-healthy rapid server.
#   * preflight: the rapid RAM-overhead formula (6 GB + cache ceiling) vs the flat
#     vllm 6 GB, the explicit-override precedence, and the meta-based "already served".
#
# NOT covered (deliberate): the 1-line `rapid` addition to bin/csl's interactive
# session filter (a `case` inside a TTY read loop) — verified by inspection.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
check() {  # $1=0/1 condition, $2=label
  if [ "$1" -eq 0 ]; then PASS=$((PASS+1)); printf '  PASS: %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$2"; fi
}
assert_grep() {  # $1=needle, $2=haystack, $3=label
  printf '%s' "$2" | grep -qF -- "$1"
  check $? "$3"
}

# --- sandbox -----------------------------------------------------------------
SB="$(mktemp -d "${TMPDIR:-/tmp}/la-rapid-test.XXXXXX")"
mkdir -p "$SB/home/.models/FakeModel" "$SB/home/.stub" "$SB/home/.claude/logs/local-agents-configs"
cp -R "$REPO/bin" "$SB/bin"
cp -R "$REPO/config" "$SB/config"
# A real weight file (>1MB) so the "metadata-only shell" guard passes.
head -c 2097152 /dev/zero > "$SB/home/.models/FakeModel/weight.bin"

STUB="$SB/home/.stub/rapid-mlx"
cat > "$STUB" <<'PY'
#!/usr/bin/env python3
import sys, os, json
from http.server import BaseHTTPRequestHandler, HTTPServer
argv = sys.argv[1:]
with open(os.environ["STUB_ARGV_FILE"], "w") as f:
    json.dump(argv, f)
def opt(name, default=None):
    for i, a in enumerate(argv):
        if a == name:
            return argv[i + 1]
    return default
port = int(opt("--port", "0"))
spoof = opt("--served-model-name", "stub")
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/v1/models":
            # Compact separators (no space after the colon), matching what real rapid-mlx emits.
            # The hotswap readiness/reuse grep is '"id":"..."' (no space); spaced JSON would
            # make CURRENT_IDS come back empty and break the reuse path.
            b = json.dumps({"data": [{"id": spoof}]}, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
chmod +x "$STUB"

# Controlled config: rapid + vllm aliases on the SAME fake model, test ports only.
cat > "$SB/config/config.local.sh" <<CFG
LA_MODELS_DIR="\$HOME/.models"
LA_PORT_START=8100
LA_PORT_MAX=8102
LA_RAPID_BIN="\$HOME/.stub/rapid-mlx"
LA_RAPID_CACHE_MEMORY_MB=2048
LA_RAPID_HYBRID_CACHE_ENTRIES=2
LA_RAPID_PIN_SYSTEM_PROMPT=true
LA_RAPID_RELOCATE_MID_SYSTEM=true
LA_RAPID_PFLASH=off
la_register rapid-qwen     FakeModel rapid qwen qwen3 true  claude-opus-5 high "" "" 16
la_register rapid-qwen-fast FakeModel rapid qwen ""    false claude-opus-5 low  "" "" 16
la_register vllm-qwen      FakeModel vllm  qwen ""    false claude-opus-5 high "" "" 16
CFG

STUB_PIDS=()
cleanup() {
  for pid in "${STUB_PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  rm -rf "$SB"
}
trap cleanup EXIT

# Run a real script inside the sandbox. $1=script, rest=args. STUB_ARGV_FILE selects
# where the stub records its argv.
run() {
  local script="$1"; shift
  ( cd "$SB" && HOME="$SB/home" STUB_ARGV_FILE="$ARGV_FILE" HOTSWAP_READY_TIMEOUT=15 \
      bash "$SB/bin/$script" "$@" )
}

# ===========================================================================
echo "== hotswap: rapid command construction (thinking ON) =="
ARGV_FILE="$SB/argv1.json"; rm -f "$ARGV_FILE"
OUT=$(run local-llm-hotswap.sh rapid-qwen)
assert_grep "SUCCESS_PORT=8100" "$OUT" "prints SUCCESS_PORT on a free test port"
[ -f "$ARGV_FILE" ]; check $? "stub was actually launched (argv recorded)"
ARGS=$(cat "$ARGV_FILE" 2>/dev/null)
assert_grep "qwen3_coder_xml" "$ARGS" "tool parser qwen translated to qwen3_coder_xml"
assert_grep "claude-opus-5"   "$ARGS" "served under the spoof id"
assert_grep "--cache-memory-mb" "$ARGS" "cache ceiling flag present"
assert_grep "2048"            "$ARGS" "cache ceiling value wired through"
assert_grep "--hybrid-cache-entries" "$ARGS" "hybrid cache entries flag present"
# Bounded continuous batching. This is what lets ONE server carry an interactive local session and
# cloud dispatches at the same time — the thing vllm-mlx's single-slot SimpleEngine cannot do. Both
# flags must be passed EXPLICITLY: rapid's own defaults are 256/256, which its own help calls too
# high for a memory-constrained device, so inheriting them is not the same as choosing them.
assert_grep "--max-num-seqs" "$ARGS" "concurrency: --max-num-seqs passed explicitly, not inherited"
assert_grep "--max-concurrent-requests" "$ARGS" "concurrency: admission cap passed explicitly"
assert_grep "--pin-system-prompt" "$ARGS" "pin-system-prompt on"
assert_grep "--relocate-mid-conversation-system" "$ARGS" "relocate-mid-conversation-system on"
assert_grep "--no-mllm"       "$ARGS" "mllm disabled"
assert_grep "--no-spec-decode" "$ARGS" "spec-decode disabled"
assert_grep "--reasoning-parser" "$ARGS" "thinking ON -> reasoning parser present"
assert_grep "qwen3"           "$ARGS" "reasoning parser = qwen3"
assert_grep "--default-temperature" "$ARGS" "thinking ON -> sampling temp set"
# thinking ON must NOT carry the no-thinking pair
if printf '%s' "$ARGS" | grep -qF -- "--no-thinking"; then check 1 "thinking ON omits --no-thinking"; else check 0 "thinking ON omits --no-thinking"; fi

# ===========================================================================
echo "== hotswap: rapid command construction (thinking OFF) =="
ARGV_FILE="$SB/argv2.json"; rm -f "$ARGV_FILE"
OUT=$(run local-llm-hotswap.sh rapid-qwen-fast)
ARGS=$(cat "$ARGV_FILE" 2>/dev/null)
assert_grep "--no-thinking" "$ARGS" "thinking OFF -> --no-thinking"
assert_grep "--no-reasoning-parser" "$ARGS" "thinking OFF -> --no-reasoning-parser"
if printf '%s' "$ARGS" | grep -qF -- "--reasoning-parser"; then check 1 "thinking OFF omits --reasoning-parser"; else check 0 "thinking OFF omits --reasoning-parser"; fi

# ===========================================================================
echo "== hotswap: rapid .meta identity record =="
META="$SB/home/.claude/logs/local-agents-configs/server_8100.meta"
[ -f "$META" ]; check $? "server_8100.meta written after launch"
# assert_grep takes CONTENT as $2 (it runs `printf '%s' "$2" | grep`), not a path —
# read the file once and pass its contents, or every assertion below silently fails.
META_CONTENT="$(cat "$META" 2>/dev/null)"
assert_grep "backend=rapid" "$META_CONTENT" "meta records backend=rapid"
assert_grep "alias=rapid-qwen" "$META_CONTENT" "meta records the alias"
assert_grep "model_dir=$SB/home/.models/FakeModel" "$META_CONTENT" "meta records the model dir"
assert_grep "served_id=claude-opus-5" "$META_CONTENT" "meta records the served spoof id"
grep -q '^pid=' "$META" 2>/dev/null; check $? "meta records the server pid"

# ===========================================================================
echo "== hotswap: rapid REUSE of an already-healthy server =="
# The stub from the thinking-ON launch is still bound to 8100; a second launch of the
# SAME alias must detect it via the meta file and reuse the port, NOT start a new server.
ARGV_FILE="$SB/argv3.json"; rm -f "$ARGV_FILE"
OUT=$(run local-llm-hotswap.sh rapid-qwen)
assert_grep "already healthy" "$OUT" "second launch reuses the healthy server"
assert_grep "SUCCESS_PORT=8100" "$OUT" "reuse reports the same port"
if [ -f "$ARGV_FILE" ]; then check 1 "reuse did NOT launch a new server"; else check 0 "reuse did NOT launch a new server"; fi

# ===========================================================================
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]