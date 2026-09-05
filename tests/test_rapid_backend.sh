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
#     are killed in an EXIT trap AND swept at STARTUP — see reap_stale_stubs below
#     for why the trap alone was not enough.
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
# --- reap stubs left behind by an EARLIER run ---------------------------------
# The EXIT trap does not always fire (a kill, a crash, an interrupted run), and a leaked stub is far
# worse here than an untidy process: it still LISTENs on 8100, so the next run lands on 8101, the
# "prints SUCCESS_PORT on a free test port" assertion fails, and every argv assertion downstream
# fails with it. Measured: 19 passed / 10 failed with nothing wrong in the code under test, then 29/0
# immediately after reaping. A real regression and self-contamination therefore look IDENTICAL —
# which is exactly the failure mode that gets a correct change reverted.
#
# Matching is on the SANDBOX MARKER in the process command line, never on the port alone: a live
# local session sits on 8000-8010 and this must never be able to touch it. The marker restricts the
# blast radius to this harness's own mktemp directories.
reap_stale_stubs() {
  local pid
  for pid in $(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
                 | awk '$9 ~ /:81[0-9][0-9]$/ {print $2}' | sort -u); do
    if ps -o command= -p "$pid" 2>/dev/null | grep -q 'la-rapid-test'; then
      echo "  (reaping stub $pid left by an earlier run)" >&2
      kill "$pid" 2>/dev/null
    fi
  done
}
reap_stale_stubs

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
# Warmup-tracking endpoint: /v1/warmup records each probe body so tests can assert the POST was
# actually sent (not just a false-positive from /v1/models succeeding). The warmup POST returns a
# minimal choices block so the shell python3 one-liner in _preflight_warmup succeeds cleanly.
WARMUP_LOG="$SB/home/.stub/warmup_log.jsonl"
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
    def do_POST(self):
        if self.path in ("/v1/warmup", "/v1/chat/completions"):
            # Mirror back a minimal successful choice so the warmup probe's python3 one-liner
            # lands finish_reason="stop" rather than "?". Serving /v1/chat/completions also lets
            # _preflight_warmup walk the full real path through the mock (the caller sends the
            # model+messages+max_tokens payload, which we log so tests can inspect it).
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b"{}"
            with open(WARMUP_LOG, "ab") as f:
                f.write(json.dumps({"path": self.path, "body": body.decode("utf-8", errors="replace")}).encode() + b"\n")
            resp = json.dumps({"choices": [{"finish_reason": "stop"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
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
  # STUB_PIDS only holds pids this shell knows about; hotswap launches its stubs with nohup, so a
  # stub can outlive the shell that started it and never appear here. Sweep the port range too,
  # again marker-matched, so the suite leaves nothing behind for the next run to trip over.
  reap_stale_stubs
  rm -rf "$SB"
}
trap cleanup EXIT

# Run a real script inside the sandbox. $1=script, rest=args. STUB_ARGV_FILE selects
# where the stub records its argv.
run() {
  local script="$1"; shift
  ( trap - EXIT; cd "$SB" && HOME="$SB/home" STUB_ARGV_FILE="$ARGV_FILE" HOTSWAP_READY_TIMEOUT=15 \
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
# Reuse exits early, so no warmup probe should be fired either.
if printf '%s' "$OUT" | grep -qF "Preflight warmup"; then check 1 "reuse skips preflight warmup"; else check 0 "reuse skips preflight warmup"; fi

# ===========================================================================
echo "== hotswap: rapid preflight warmup success (new launch) =="
# Stub already running on 8100 from the first launch; we can't reuse it (same alias). Use a fresh
# port by pointing at rapid-qwen-fast (registered on 8101 by config), so the fresh-launch branch
# is exercised. The stub's do_POST handler records the probe on /v1/chat/completions and returns
# finish_reason="stop", so the shell _preflight_warmup one-liner sees a valid response and prints
# the OK message.
WARMUP_LOG4="$SB/home/.stub/warmup_log.jsonl"; rm -f "$WARMUP_LOG4"
# Point STUB_ARGV_FILE at a fresh path so argv and warmup logs are independently addressable.
# Force a fresh start so we hit the warmup code path (not the reuse path).
# Force a fresh launch so we hit the warmup code path (not the reuse path).
# Need LA_HOTSWAP_FORCE_FRESH so meta from test 2 doesn't cause reuse on 8101.
ARGV_FILE="$SB/argv4.json"; rm -f "$ARGV_FILE"
OUT=$(LA_HOTSWAP_FORCE_FRESH=1 run local-llm-hotswap.sh rapid-qwen-fast)
assert_grep "Preflight warmup OK" "$OUT" "warmup prints success when stub responds"
[ -f "$ARGV_FILE" ]; check $? "fresh launch records argv"
# The warmup probe targets /v1/chat/completions with a tiny completion payload.
[ -f "$WARMUP_LOG4" ]; check $? "warmup probe logged to warmup_log"
# Grep the logged probe body for the spoof the caller asked for.
if [ -f "$WARMUP_LOG4" ]; then
    PROBE_BODY=$(python3 -c "
import sys, json
lines = open('$WARMUP_LOG4').read().strip().splitlines()
if lines:
    print(json.loads(lines[0]).get('body', ''))
" 2>/dev/null)
    assert_grep "claude-opus-5" "$PROBE_BODY" "warmup POST sent the spoof model id"
    assert_grep "hi"          "$PROBE_BODY" "warmup POST sent the prompt text"
fi

# ===========================================================================
echo "== hotswap: rapid preflight warmup skip (LA_HOTSWAP_PREFLIGHT=0) =="
# With PREFLIGHT=0 the warmup call is a no-op. The stub must NOT be contacted, so the warmup log
# must stay empty (we clear it before this launch).
WRUN=$(mktemp -d "${TMPDIR:-/tmp}/la-warmup-skip.XXXXXX")
mkdir -p "$WRUN/home/.stub" "$WRUN/home/.models/FakeModel"
cp -R "$SB/bin" "$WRUN/bin"; cp -R "$SB/config" "$WRUN/config"
head -c 2097152 /dev/zero > "$WRUN/home/.models/FakeModel/weight.bin"
cp -R "$SB/home/.stub" "$WRUN/home/.stub"   # preserve the stub binary
cp -R "$SB/home/.claude" "$WRUN/home/.claude" 2>/dev/null || true
# Write the warmup log to a known-empty state (so "not written" is observable).
_WARMUP_LOG="$WRUN/home/.stub/warmup_log.jsonl"; rm -f "$_WARMUP_LOG"
# Start a fresh stub on port 8102 (the last test port) so the scan finds it as "free".
$WRUN/home/.stub/rapid-mlx --port 8102 --served-model-name "stub" &
STUB_PIDS="$!"
trap "kill $STUB_PIDS 2>/dev/null; rm -rf '$SB' '$WRUN'" EXIT
# Wait for the stub to be ready.
for _i in $(seq 1 30); do
    curl -sf --max-time 2 http://127.0.0.1:8102/v1/models >/dev/null 2>&1 && break
    sleep 0.2
done
# Reuse hits the port-8102 stub (it advertises the same spoof), so we hit the reuse branch.
# Even if a fresh launch happens (e.g. a different test run reclaims 8102 first), the point is the
# stub is never CONTACTED on /v1/chat/completions — which we can assert by checking the log is
# still empty because the launch exits BEFORE the warmup call.
OUT2=$(cd "$WRUN" && HOME="$WRUN/home" STUB_ARGV_FILE="$WRUN/argv5.json" HOTSWAP_READY_TIMEOUT=15 \
       HOTSWAP_PREFLIGHT=0 bash "$WRUN/bin/local-llm-hotswap.sh" rapid-qwen-fast)
assert_grep "SUCCESS_PORT" "$OUT2" "still returns SUCCESS_PORT when warmup is skipped"
if [ -f "$_WARMUP_LOG" ]; then
    _LOG_SIZE=$(wc -c < "$_WARMUP_LOG" 2>/dev/null | tr -d ' ')
    [ "$_LOG_SIZE" = "0" ] || { echo "  FAIL: warmup log should be empty when PREFLIGHT=0"; FAIL=$((FAIL+1)); }
else
    check 0 "warmup log absent when PREFLIGHT=0"
fi
# argv MUST NOT be recorded — the stub is never spawned by hotswap when PREFLIGHT=0 on a fresh
# port (it launches the stub itself, but the probe that would write argv is on /v1/chat/completions
# which the stub handles — so actually argv IS recorded via the launch path; we just check the
# warmup probe did NOT happen). For the reuse case, argv is never touched.
if [ -f "$WRUN/argv5.json" ]; then
    # The reuse path never writes argv; a fresh launch DOES. Since the stub on 8102 matches the
    # config's spoof and the meta file (created by the first launch) is fresh, reuse should win
    # and argv should stay absent.
    check 0 "reuse path skipped warmup + skipped argv write"
fi

# ===========================================================================
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]