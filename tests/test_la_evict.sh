#!/usr/bin/env bash
# Framework-free integration tests for bin/la-evict.sh.
#
# Uses controlled listener processes on dynamically selected high ports.
# It never scans or modifies the normal local-agents range 8000–8010.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/bin/la-evict.sh"

PASS=0
FAIL=0

check() {
    local status="$1"
    local label="$2"

    if [ "$status" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL: %s\n' "$label"
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local label="$3"

    printf '%s' "$haystack" | grep -qF -- "$needle"
    check "$?" "$label"
}

is_running() {
    local pid="$1"
    local stat

    kill -0 "$pid" 2>/dev/null || return 1
    stat="$(/bin/ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$stat" in
        ""|Z*) return 1 ;;
        *) return 0 ;;
    esac
}

assert_running() {
    local pid="$1"
    local label="$2"

    is_running "$pid"
    check "$?" "$label"
}

wait_for_stopped() {
    local pid="$1"
    local attempt=0

    while [ "$attempt" -lt 50 ]; do
        is_running "$pid" || {
            wait "$pid" 2>/dev/null || true
            return 0
        }
        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

assert_stopped() {
    local pid="$1"
    local label="$2"

    wait_for_stopped "$pid"
    check "$?" "$label"
}

for command in python3 lsof ps pgrep vm_stat awk grep sed sort seq; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$command" >&2
        exit 2
    }
done

[[ -f "$SCRIPT" ]] || {
    printf 'Missing script under test: %s\n' "$SCRIPT" >&2
    exit 2
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/la-evict-test.XXXXXX")"
TEST_HOME="$SB/home"
LOG_DIR="$TEST_HOME/.claude/logs"
MOCK_BIN="$SB/mock-bin"
PYTHON="$(command -v python3)"
REAL_PATH="$PATH"
PIDS=()

mkdir -p "$LOG_DIR" "$MOCK_BIN"

cleanup() {
    local pid

    for pid in "${PIDS[@]:-}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 0.2

    for pid in "${PIDS[@]:-}"; do
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    rm -rf "$SB"
}
trap cleanup EXIT

# Find three consecutive unused high ports. They are held together during each
# probe to avoid selecting a partially occupied range.
BASE="$(
"$PYTHON" - <<'PY'
import socket

for base in range(20000, 45000):
    sockets = []
    try:
        for port in range(base, base + 3):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.bind(("127.0.0.1", port))
            sockets.append(sock)
    except OSError:
        for sock in sockets:
            sock.close()
        continue

    for sock in sockets:
        sock.close()
    print(base)
    raise SystemExit(0)

raise SystemExit("No three-port test range available")
PY
)" || exit 2

[[ "$BASE" =~ ^[0-9]+$ ]] || {
    printf 'Invalid test-port base: %s\n' "$BASE" >&2
    exit 2
}

cat > "$SB/server.py" <<'PY'
#!/usr/bin/env python3
import signal
import socket
import sys

port = int(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "normal"

if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", port))
sock.listen(8)

while True:
    conn, _ = sock.accept()
    conn.close()
PY

cp "$SB/server.py" "$SB/rapid-mlx-server.py"
cp "$SB/server.py" "$SB/vllm-mlx-server.py"
cp "$SB/server.py" "$SB/unknown-server.py"

LAST_PID=""

wait_for_listener() {
    local port="$1"
    local expected_pid="$2"
    local attempt=0
    local observed

    while [ "$attempt" -lt 50 ]; do
        observed="$(
            lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null |
            head -1
        )"

        if [ "$observed" = "$expected_pid" ]; then
            return 0
        fi

        if [ -n "$observed" ] && [ "$observed" != "$expected_pid" ]; then
            printf 'Port %s belongs to unexpected pid %s\n' \
                "$port" "$observed" >&2
            return 1
        fi

        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

start_server() {
    local label="$1"
    local port="$2"
    local mode="${3:-normal}"
    local script="$SB/${label}-server.py"
    local pid

    "$PYTHON" "$script" "$port" "$mode" \
        >"$SB/${label}-${port}.log" 2>&1 &
    pid=$!
    PIDS+=("$pid")

    wait_for_listener "$port" "$pid" || {
        printf 'Controlled server failed to listen: %s pid=%s port=%s\n' \
            "$label" "$pid" "$port" >&2
        exit 2
    }

    LAST_PID="$pid"
}

STATE_FILE="$SB/evict.state"
PORT_START="$BASE"
PORT_MAX="$BASE"
TEST_PATH="$REAL_PATH"

run_evict() {
    env \
        HOME="$TEST_HOME" \
        PATH="$TEST_PATH" \
        LA_PORT_START="$PORT_START" \
        LA_PORT_MAX="$PORT_MAX" \
        LA_EVICT_EXTRA_PORTS="" \
        LA_EVICT_STATE="$STATE_FILE" \
        LA_EVICT_LOG_DIR="$LOG_DIR" \
        LA_EVICT_WINDOW=600 \
        LA_EVICT_YOUNG=120 \
        LA_EVICT_TERM_WAIT=1 \
        /bin/bash "$SCRIPT" "$@"
}

printf 'Using controlled test ports %s–%s\n' "$BASE" "$((BASE + 2))"

# ---------------------------------------------------------------------------
printf '\n== status, dry run, ranking, and escalation ==\n'

PORT_START="$BASE"
PORT_MAX="$((BASE + 1))"
STATE_FILE="$SB/ranking.state"
TEST_PATH="$REAL_PATH"

start_server rapid-mlx "$BASE"
RAPID_PID="$LAST_PID"

sleep 2

start_server vllm-mlx "$((BASE + 1))"
VLLM_PID="$LAST_PID"

OUT="$(run_evict --status)"
STATUS=$?
check "$STATUS" "status exits successfully"
assert_contains ":$BASE" "$OUT" "status lists the older Rapid server"
assert_contains ":$((BASE + 1))" "$OUT" "status lists the newer vllm server"
assert_running "$RAPID_PID" "status does not stop Rapid"
assert_running "$VLLM_PID" "status does not stop vllm"

OUT="$(run_evict --dry-run)"
STATUS=$?
check "$STATUS" "dry run exits successfully"
assert_contains \
    "would evict vllm-mlx on :$((BASE + 1))" \
    "$OUT" \
    "newest unattached server ranks first"
assert_running "$RAPID_PID" "dry run leaves Rapid alive"
assert_running "$VLLM_PID" "dry run leaves vllm alive"

OUT="$(run_evict)"
STATUS=$?
check "$STATUS" "first eviction exits successfully"
assert_contains \
    "evicting vllm-mlx on :$((BASE + 1))" \
    "$OUT" \
    "first invocation evicts the top-ranked server"
assert_stopped "$VLLM_PID" "top-ranked vllm server stopped"
assert_running "$RAPID_PID" "lower-ranked Rapid server remains"

OUT="$(run_evict)"
STATUS=$?
check "$STATUS" "second eviction exits successfully"
assert_contains \
    "Repeat invocation inside 600s" \
    "$OUT" \
    "repeat invocation advances the escalation tier"
assert_stopped "$RAPID_PID" "second invocation removes the remaining server"

# ---------------------------------------------------------------------------
printf '\n== attached-session guard and explicit escalation ==\n'

PORT_START="$BASE"
PORT_MAX="$BASE"
STATE_FILE="$SB/attached.state"

start_server rapid-mlx "$BASE"
ATTACHED_SERVER_PID="$LAST_PID"

ATTACHED_FAKE_PID=999999
ATTACHED_PORT="$BASE"

cat > "$MOCK_BIN/pgrep" <<EOF
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$1" = "-x" ] && [ "\$2" = "claude" ]; then
    echo "$ATTACHED_FAKE_PID"
    exit 0
fi
exec /usr/bin/pgrep "\$@"
EOF

cat > "$MOCK_BIN/ps" <<EOF
#!/bin/sh
if [ "\$#" -eq 3 ] &&
   [ "\$1" = "-Eww" ] &&
   [ "\$2" = "-p" ] &&
   [ "\$3" = "$ATTACHED_FAKE_PID" ]; then
    echo "$ATTACHED_FAKE_PID claude ANTHROPIC_BASE_URL=http://localhost:$ATTACHED_PORT"
    exit 0
fi

if [ "\$#" -eq 3 ] &&
   [ "\$1" = "-o" ] &&
   [ "\$2" = "command=" ] &&
   [ "\$3" = "$ATTACHED_FAKE_PID" ]; then
    echo "claude --model claude-opus-5"
    exit 0
fi

exec /bin/ps "\$@"
EOF

chmod +x "$MOCK_BIN/pgrep" "$MOCK_BIN/ps"
TEST_PATH="$MOCK_BIN:$REAL_PATH"

OUT="$(run_evict)"
STATUS=$?
if [ "$STATUS" -eq 3 ]; then
    check 0 "first attached-only invocation exits with held-back status"
else
    check 1 "first attached-only invocation exits with held-back status"
fi
assert_contains \
    "held back" \
    "$OUT" \
    "first invocation protects an attached server"
assert_contains \
    "only candidate :$BASE is in use" \
    "$OUT" \
    "held-back result identifies the attached port"
assert_running \
    "$ATTACHED_SERVER_PID" \
    "attached server remains after first invocation"

OUT="$(run_evict)"
STATUS=$?
check "$STATUS" "repeat attached invocation completes"
assert_contains \
    "escalating to tier 2" \
    "$OUT" \
    "repeat invocation explicitly escalates past the guard"
assert_stopped \
    "$ATTACHED_SERVER_PID" \
    "second invocation evicts the controlled attached server"

# ---------------------------------------------------------------------------
printf '\n== unknown-listener protection ==\n'

PORT_START="$BASE"
PORT_MAX="$BASE"
STATE_FILE="$SB/unknown.state"
TEST_PATH="$REAL_PATH"

start_server unknown "$BASE"
UNKNOWN_PID="$LAST_PID"

OUT="$(run_evict --tier 1)"
STATUS=$?
check "$STATUS" "unknown-listener run completes without shell failure"
assert_contains \
    "unrecognised listener, refusing without --allow-unknown" \
    "$OUT" \
    "unknown listener is refused by default"
assert_running "$UNKNOWN_PID" "unknown listener remains alive"

kill -TERM "$UNKNOWN_PID" 2>/dev/null || true
wait_for_stopped "$UNKNOWN_PID" || true

# ---------------------------------------------------------------------------
printf '\n== TERM-to-KILL fallback ==\n'

PORT_START="$BASE"
PORT_MAX="$BASE"
STATE_FILE="$SB/sigkill.state"
TEST_PATH="$REAL_PATH"

start_server rapid-mlx "$BASE" ignore-term
STUBBORN_PID="$LAST_PID"

OUT="$(run_evict --tier 1)"
STATUS=$?
check "$STATUS" "TERM-to-KILL run exits successfully"
assert_contains \
    "SIGTERM ignored after 1s" \
    "$OUT" \
    "stubborn server triggers SIGKILL fallback"
assert_stopped "$STUBBORN_PID" "stubborn server is ultimately stopped"

# ---------------------------------------------------------------------------
printf '\n== state reset and empty inventory ==\n'

STATE_FILE="$SB/reset.state"
printf '1 1 test\n' > "$STATE_FILE"

OUT="$(run_evict --reset)"
STATUS=$?
check "$STATUS" "state reset exits successfully"
assert_contains \
    "escalation state cleared" \
    "$OUT" \
    "state reset reports completion"
if [ -e "$STATE_FILE" ]; then
    check 1 "state file removed"
else
    check 0 "state file removed"
fi

OUT="$(run_evict --status)"
STATUS=$?
check "$STATUS" "empty status exits successfully"
assert_contains \
    "No local model servers are listening" \
    "$OUT" \
    "empty inventory is reported"
assert_contains \
    "nothing to evict" \
    "$OUT" \
    "empty result is explicit"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
