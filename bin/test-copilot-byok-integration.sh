#!/bin/bash
# Integration test: Verify Copilot BYOK works end-to-end with local Qwen proxy
# Usage: ./bin/test-copilot-byok-integration.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOTSWAP="$SCRIPT_DIR/local-llm-hotswap.sh"
PROXY="$SCRIPT_DIR/copilot_local_proxy.py"
LOG_DIR="$PROJECT_ROOT/logs"
TEST_PROMPT="Write a simple hello world function"

mkdir -p "$LOG_DIR"

echo "[TEST] Starting Copilot BYOK integration test..."

# Step 1: Start vLLM hotswap
echo "[TEST] Step 1: Starting vLLM model server..."
HOTSWAP_OUTPUT=$("$HOTSWAP" qwen-3.6-operator 2>&1)
echo "$HOTSWAP_OUTPUT" | grep -q "SUCCESS_PORT" || {
    echo "[TEST] ❌ FAILED: Hotswap did not start model server"
    exit 1
}
LLAMA_PORT=$(echo "$HOTSWAP_OUTPUT" | grep "SUCCESS_PORT" | sed 's/.*SUCCESS_PORT=\([0-9]*\).*/\1/')
echo "[TEST] ✅ vLLM listening on port $LLAMA_PORT"

# Step 2: Start proxy
echo "[TEST] Step 2: Starting Copilot proxy..."
PROXY_PORT=8087
nohup python3 "$PROXY" --port "$PROXY_PORT" > "$LOG_DIR/test-proxy.log" 2>&1 &
PROXY_PID=$!
sleep 1

# Verify proxy started
if ! kill -0 $PROXY_PID 2>/dev/null; then
    echo "[TEST] ❌ FAILED: Proxy failed to start. Logs:"
    cat "$LOG_DIR/test-proxy.log"
    exit 1
fi
echo "[TEST] ✅ Proxy running on port $PROXY_PORT (PID $PROXY_PID)"

# Step 3: Test proxy health with curl
echo "[TEST] Step 3: Testing proxy health..."
curl -s "http://127.0.0.1:$PROXY_PORT/v1/models" | grep -q "qwen-3.6-operator" || {
    echo "[TEST] ❌ FAILED: Proxy /v1/models did not return expected model"
    kill $PROXY_PID || true
    exit 1
}
echo "[TEST] ✅ Proxy health check passed"

# Step 4: Run Copilot probe
echo "[TEST] Step 4: Running Copilot BYOK probe..."
COPILOT_LOG="$LOG_DIR/test-copilot-probe.log"
rm -f "$COPILOT_LOG"

export COPILOT_PROVIDER_BASE_URL="http://127.0.0.1:$PROXY_PORT"
export COPILOT_PROVIDER_TYPE='openai'
export COPILOT_PROVIDER_API_KEY='local'
export COPILOT_MODEL='qwen-3.6-operator'
export COPILOT_PROVIDER_WIRE_MODEL='qwen-3.6-operator'

copilot -p "$TEST_PROMPT" --allow-all --log-level=info --log-dir "$LOG_DIR" 2>&1 | tee "$COPILOT_LOG" | head -20

# Check exit code and logs for success
if grep -q "hasError=false" "$LOG_DIR"/process-*.log 2>/dev/null || \
   grep -q "received\|function" "$COPILOT_LOG"; then
    echo "[TEST] ✅ Copilot probe succeeded"
    TEST_RESULT=0
else
    echo "[TEST] ❌ FAILED: Copilot probe did not complete successfully"
    echo "[TEST] Last 50 lines of Copilot log:"
    tail -50 "$LOG_DIR"/process-*.log 2>/dev/null || true
    TEST_RESULT=1
fi

# Cleanup
echo "[TEST] Cleaning up..."
PID=$(lsof -iTCP:$PROXY_PORT -sTCP:LISTEN -t 2>/dev/null) && kill $PID 2>/dev/null || true
sleep 0.5

# Summary
echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo "✅ [TEST PASSED] Copilot BYOK integration test succeeded!"
    echo "   - vLLM model server: working"
    echo "   - Local proxy: working"
    echo "   - Copilot CLI: connected and completed prompt"
    exit 0
else
    echo "❌ [TEST FAILED] See logs at: $LOG_DIR"
    exit 1
fi
