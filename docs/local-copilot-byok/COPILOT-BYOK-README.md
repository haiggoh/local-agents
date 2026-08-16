# Copilot BYOK — Local Inference Mode

> ## ⚠️ EXPERIMENTAL PROOF OF CONCEPT — NOT A WORKING FEATURE
>
> **Status as of 2026-08-16: the intended goal is NOT achieved.** Read this before following any
> instruction below, because the rest of this document is written as a usage guide and would
> otherwise imply the feature works.
>
> - **What is demonstrated:** the streaming wire format is correct. Toy prompts return completions
>   through the proxy, and `/v1/models` resolves. That is a *transport-level* result.
> - **What is NOT demonstrated:** GitHub Copilot actually using a local model as its engine when
>   cloud quota is exhausted, which was the entire point. In its current state it behaves much like
>   `bin/local-agent-dispatch.py`, which already exists here — so it does not yet add what it set
>   out to add.
> - **It may be a dead end.** The approach depends on `COPILOT_PROVIDER_BASE_URL`,
>   `COPILOT_PROVIDER_TYPE` and `COPILOT_PROVIDER_API_KEY`. GitHub's published supported-models
>   documentation lists only vendor-hosted providers and does not mention BYOK, Ollama, self-hosted
>   servers, or custom OpenAI-compatible endpoints. Those environment variables appear to be
>   undocumented, so they can change or stop working without notice. Confirm that contract before
>   investing further.
> - **No support is offered and it may be removed.** It ships in this repository because it reuses
>   this repository's model registry, hotswap layer and launcher conventions; keeping it here avoids
>   maintaining a drifting duplicate of that infrastructure. It is not part of the plugin's supported
>   surface and nothing in the plugin points users at it.
>
> Start by running `bin/test-copilot-byok-integration.sh` and treating its result as the source of
> truth, not this guide.

Run GitHub Copilot CLI with local Qwen 3.6 inference models instead of cloud compute. This uses Copilot's **BYOK (Bring Your Own Key)** mode to proxy requests through a local HTTP server that forwards to vLLM-MLX.

## Quick Start

### 1. Prerequisites
- vLLM-MLX installed and accessible via `bin/local-llm-hotswap.sh`
- Copilot CLI installed (v1.0.80+)
- Python 3.8+

### 2. Run the Integration Test
```bash
cd local-agents
bash bin/test-copilot-byok-integration.sh
```

This automatically:
- Starts vLLM model server
- Starts the local Copilot proxy
- Runs a Copilot CLI test prompt
- Validates success

Expected output:
```
✅ [TEST PASSED] Copilot BYOK integration test succeeded!
   - vLLM model server: working
   - Local proxy: working
   - Copilot CLI: connected and completed prompt
```

### 3. Use Copilot with Local Inference

**Option A: Manual setup (recommended for development)**
```bash
# Terminal 1: Start vLLM model server
cd local-agents
./bin/local-llm-hotswap.sh qwen-3.6-operator
# Output: SUCCESS_PORT=8000

# Terminal 2: Start Copilot proxy
python3 bin/copilot_local_proxy.py --port 8087

# Terminal 3: Run Copilot with BYOK env vars
export COPILOT_PROVIDER_BASE_URL='http://127.0.0.1:8087'
export COPILOT_PROVIDER_TYPE='openai'
export COPILOT_PROVIDER_API_KEY='local'
export COPILOT_MODEL='qwen-3.6-operator'
export COPILOT_PROVIDER_WIRE_MODEL='qwen-3.6-operator'

copilot -p "Your prompt here" --allow-all
```

**Option B: Using the launcher script (experimental)**
```bash
./bin/launch-copilot-agent.sh "Your prompt here"
```

## Architecture

### Components

1. **vLLM-MLX Server** (`local-llm-hotswap.sh`)
   - Serves OpenAI-compatible `/v1/models` and `/v1/chat/completions` endpoints
   - Runs Qwen 3.6 model locally
   - Default port: 8000

2. **Local Copilot Proxy** (`copilot_local_proxy.py`)
   - HTTP server on port 8087 (configurable)
   - Emulates OpenAI provider API endpoints
   - Translates Copilot requests to vLLM calls
   - **Key feature**: Server-Sent Events (SSE) streaming responses

3. **Copilot CLI**
   - Standard `copilot` command-line interface
   - Uses BYOK environment variables to route requests to local proxy
   - Full feature support (prompts, documentation lookup, etc.)

### Request Flow

```
Copilot CLI
    ↓
COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:8087
    ↓
Local Copilot Proxy (8087)
    ├─ GET /v1/models → returns model list
    └─ POST /v1/chat/completions (streaming)
        ↓
        vLLM Server (8000)
        ├─ /v1/models
        └─ /v1/chat/completions
            ↓
            Qwen 3.6 Model
            ↓
        Returns completion
        ↓
    Formats as SSE chunks
    ↓
Returns streaming response to Copilot CLI
```

## How It Works: The Streaming Fix

### The Problem
Earlier attempts to connect Copilot to a local proxy failed with `IncompleteMessage` errors. Copilot would connect but immediately close the connection.

### Root Cause
Copilot sends the header `x-stainless-helper-method: stream`, indicating it expects **Server-Sent Events (SSE)** streaming format for responses, not raw HTTP chunks.

### The Solution
The proxy now:
1. Detects the `x-stainless-helper-method: stream` header
2. Sets response headers:
   - `Content-Type: text/event-stream`
   - `Cache-Control: no-cache`
   - `Connection: keep-alive`
   - `Transfer-Encoding: chunked`
3. Formats response as SSE:
   ```
   data: {"id":"...", "object":"chat.completion.chunk", "choices":[...]}\n\n
   data: {"id":"...", "object":"chat.completion.chunk", "choices":[...]}\n\n
   data: [DONE]\n\n
   ```
4. Terminates with HTTP/1.1 chunked encoding terminator: `0\r\n\r\n`

## Configuration

### Environment Variables
- `COPILOT_PROVIDER_BASE_URL`: URL of local proxy (default: `http://127.0.0.1:8087`)
- `COPILOT_PROVIDER_TYPE`: Provider type (default: `openai`)
- `COPILOT_PROVIDER_API_KEY`: API key (can be any value in local mode, use `local`)
- `COPILOT_MODEL`: Model ID for Copilot lookup (use `qwen-3.6-operator`)
- `COPILOT_PROVIDER_WIRE_MODEL`: Actual model name sent to provider (use `qwen-3.6-operator`)

### Proxy Options
```bash
python3 bin/copilot_local_proxy.py --port 8087 --host 127.0.0.1
```

## Testing & Validation

### Unit Test: Integration Test Script
```bash
bash bin/test-copilot-byok-integration.sh
```

Validates:
- vLLM model server startup
- Proxy health check (`/v1/models`)
- Copilot CLI connection and prompt completion
- Exit code and log inspection

### Manual Testing
```bash
# Test 1: Simple probe
export COPILOT_PROVIDER_BASE_URL='http://127.0.0.1:8087'
export COPILOT_PROVIDER_TYPE='openai'
export COPILOT_PROVIDER_API_KEY='local'
export COPILOT_MODEL='qwen-3.6-operator'
export COPILOT_PROVIDER_WIRE_MODEL='qwen-3.6-operator'

copilot -p "Hello, what's your name?" --allow-all

# Test 2: Code generation
copilot -p "Write a Python function to reverse a string" --allow-all

# Test 3: Documentation lookup
copilot -p "How do I use async/await in Python?" --allow-all
```

### Debugging

**Enable verbose logging:**
```bash
export COPILOT_LOG_LEVEL=debug
copilot -p "test" --allow-all --log-level=debug --log-dir ./logs
```

**Check proxy logs:**
```bash
tail -f logs/copilot_proxy.log
tail -f logs/proxy_requests.log  # Request audit log
```

**Check Copilot logs:**
```bash
ls -lh logs/process-*.log
tail -f logs/process-*.log
```

## Limitations & Known Issues

1. **Model ID validation**: Copilot may warn that the model is "not in the built-in catalog". This is expected and does not affect functionality.
2. **Streaming only**: The proxy currently implements streaming responses. Non-streaming mode is available but not tested.
3. **Single model**: Proxy forwards all requests to vLLM's configured model. Model switching is not yet supported.
4. **Error handling**: Long-running requests may timeout; adjust `x-stainless-timeout` header if needed.

## Future Enhancements

1. Add support for model switching via environment variables
2. Implement request caching and deduplication
3. Add metrics/telemetry logging
4. Support for non-streaming completions API
5. Add systemd/launchd integration for persistent proxy daemon
6. Implement model-id spoofing fallback (use well-known model ID with local wire model name)

## File Structure

```
local-agents/
├── bin/
│   ├── copilot_local_proxy.py          # Main proxy server
│   ├── launch-copilot-agent.sh         # Launcher wrapper
│   ├── test-copilot-byok-integration.sh # Integration test
│   ├── local-llm-hotswap.sh            # vLLM startup
│   └── local-agent-dispatch.py         # Dispatch utility
├── docs/
│   ├── COPILOT-BYOK-README.md          # This file
│   └── planning/
│       └── local-copilot-byok-plan.md  # Architecture & design
└── logs/
    ├── copilot_proxy.log               # Proxy runtime logs
    ├── proxy_requests.log              # Request audit
    └── process-*.log                   # Copilot CLI logs
```

## References

- [Copilot BYOK Documentation](https://docs.github.com/en/copilot/managing-copilot/configure-personal-settings/configuring-your-copilot-settings)
- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference/chat/create)
- [vLLM-MLX](https://github.com/vLLM-project/vLLM)
- [Server-Sent Events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)

## Support

For issues, check:
1. vLLM server is running: `curl http://127.0.0.1:8000/v1/models`
2. Proxy is running: `curl http://127.0.0.1:8087/v1/models`
3. Copilot debug logs: `tail -50 logs/process-*.log`
4. Proxy request audit: `tail -50 logs/proxy_requests.log`

See `docs/planning/local-copilot-byok-plan.md` for additional technical details.
