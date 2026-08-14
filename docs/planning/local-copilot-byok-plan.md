# Local Copilot BYOK — Plan & Progress

## Summary (progress to date)
- Enabled global Copilot settings and created ~/.copilot/copilot-instructions.md and settings.json (memory enabled).
- Inspected existing local-agents tooling (hotswap, dispatch, launch scripts).
- Built a proof-of-concept proxy: bin/copilot_local_proxy.py (serves /v1/models, /v1/chat/completions, permissive fallbacks).
- Added launch helper: bin/launch-copilot-agent.sh to set COPILOT_* envs and invoke Copilot CLI.
- Tidied repo: moved planning notes to docs/planning/, moved backups to backups/, updated .gitignore.
- Verified vllm serves qwen-3.6-operator; local dispatch and curl calls return completions.

## Current state (WORKING ✅)
- **Copilot BYOK POC is now FULLY FUNCTIONAL!**
- The proxy successfully handles Copilot CLI requests with local Qwen 3.6 model.
- Tested with two prompts: "Test probe" and "Write a small hello world function in Python" — both completed successfully.
- The key fix was implementing **proper Server-Sent Events (SSE) streaming format** for chat/completions responses, not raw HTTP chunked encoding.
- Proxy request audit log shows single requests (no retries) for successful prompts; Copilot logs show `hasError=false` completion.

**Root cause of prior failures:**
- Copilot sends `x-stainless-helper-method: stream` header, indicating it expects streaming responses.
- Prior proxy implementation tried HTTP chunked encoding instead of OpenAI-style SSE (Server-Sent Events).
- SSE format for chat/completions: `data: <JSON_object>\n\n` repeated, terminated by HTTP chunked encoding's `0\r\n\r\n`.
- Also fixed: Added proper Content-Type (`text/event-stream`), Cache-Control, and persistent connection headers for streaming.


## Root cause hypothesis
~~Copilot performs additional provider probes (specific paths, method sequences, or minor schema expectations) beyond the minimal OpenAI-compatible endpoints. The proxy must emulate OpenAI provider semantics precisely (model manifests, /models vs /v1/models, versions, expected fields, and specific status codes/headers). Copilot may also call alternative wire APIs ("responses") or expect model versions metadata.~~

**RESOLVED**: The issue was the streaming response format. Copilot expects OpenAI-style Server-Sent Events (SSE) for endpoints marked with `x-stainless-helper-method: stream`. The proxy now correctly detects this header and sends SSE-formatted responses with proper HTTP/1.1 chunked encoding and streaming-specific headers.

   ./bin/local-llm-hotswap.sh qwen-3.6-operator
## Priority next steps (short-term)
1. ~~Analyze the tcpdump pcap~~ — **SKIPPED** (fixed with SSE streaming format)
2. ~~If pcap confirms malformed headers~~ — **SKIPPED** (fixed with SSE streaming format)
3. **[COMPLETED]** Add proper Server-Sent Events streaming support to proxy
   - ✅ Detect `x-stainless-helper-method: stream` header
   - ✅ Send `Content-Type: text/event-stream` for streaming responses
   - ✅ Format each message chunk as `data: <JSON>\n\n`
   - ✅ Use HTTP/1.1 chunked encoding to frame SSE messages
   - ✅ Properly terminate chunked stream with `0\r\n\r\n`
4. **[NEXT]** Create automated integration test: script that starts hotswap → proxy → runs `copilot -p "test prompt"` and validates success (exit code 0, no errors in logs).
5. **[OPTIONAL FOLLOW-UP]** Implement model-id spoofing fallback if new issues arise:
   - Set COPILOT_MODEL=gpt-5.4 (well-known model) and COPILOT_PROVIDER_WIRE_MODEL=qwen-3.6-operator (actual local model) to bypass model validation while using local inference.

   Confirm it prints SUCCESS_PORT=<port> and that http://127.0.0.1:<port>/v1/models returns an OpenAI-style models list.

2. Start the local proxy (example):
   python3 bin/copilot_local_proxy.py --port 8087
   Proxy logs: local-agents/logs/copilot_proxy_hardened.log and request audit: local-agents/logs/proxy_requests.log

3. Capture provider probe and run Copilot in another terminal (non-interactive):
   sudo timeout 20 tcpdump -i lo0 -s 0 -w /tmp/copilot-probe.pcap tcp and port 8087
   (in separate terminal)
   COPILOT_PROVIDER_BASE_URL='http://127.0.0.1:8087' \
   COPILOT_PROVIDER_TYPE='openai' \
   COPILOT_PROVIDER_API_KEY='local' \
   COPILOT_MODEL='qwen-3.6-operator' \
   COPILOT_PROVIDER_WIRE_MODEL='qwen-3.6-operator' \
   copilot -p "Probe capture" --allow-all --model qwen-3.6-operator --log-level=debug --log-dir ~/ClaudeWorkspace/local-agents/logs

4. Inspect captures and logs:
   - Proxy request audit: local-agents/logs/proxy_requests.log
   - Proxy runtime logs: local-agents/logs/copilot_proxy_*.log
   - Copilot CLI logs: local-agents/logs/process-*.log and ~/.copilot/logs/
   - Pcap: tcpdump -r /tmp/copilot-probe.pcap -nn -vv | sed -n '1,200p'

If the pcap shows the client resetting the connection quickly (RST), focus on response headers/schema and chunked/streaming behavior; if the request is malformed, focus on emulating expected endpoint paths.

## Artifacts created
- bin/copilot_local_proxy.py (POC proxy)
- bin/launch-copilot-agent.sh (adapter)
- docs/planning/local-agent-dispatch-qwen-upgrade-planning-session.txt (moved)
- backups/local-agent-dispatch/* (moved backups)
- .gitignore updated to include backups/
- ~/.copilot/copilot-instructions.md and settings.json (local global settings)

## Remaining TODOs (actionable checklist - updated)
- [x] Capture a short tcpdump during a probe (user ran capture; /tmp/copilot-probe.pcap exists). Inspect pcap for low-level behavior.
- [x] Add permissive probe handling: HEAD/OPTIONS, multiple path aliases, fallback model manifest (done in proxy).
- [ ] Parse pcap and exact Copilot request/response headers to determine schema mismatch.
- [ ] Implement exact OpenAI model manifest schemas in proxy (complete field parity: id, name, created, owned_by, permission array).
- [ ] Harden streaming behavior: support chunked responses or SSE if Copilot expects streaming on the wire API.
- [ ] Add full support for /v1/models/<id>/versions and both completions/responses wire APIs.
- [ ] Add robust Authorization handling and expected status codes (401/403 semantics).
- [ ] Add an automated end-to-end test and document usage in README (bin/README.md or docs/).
- [ ] If required, implement model-id spoofing fallback (set COPILOT_MODEL to a well-known model, COPILOT_PROVIDER_WIRE_MODEL to local alias).

## Recommended immediate next action
Run one more instrumented Copilot BYOK probe while proxy logging is at debug and capture proxy output. If proxy logs lack sufficient detail, run a short loopback packet capture (tcpdump -i lo0 -w /tmp/copilot-probe.pcap) and share or inspect locally.

---
Created for review by haiggoh — adjust priorities or request sudo for packet capture and I will proceed.
