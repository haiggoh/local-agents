# Local Copilot BYOK — Plan & Progress

## Summary (progress to date)
- Enabled global Copilot settings and created ~/.copilot/copilot-instructions.md and settings.json (memory enabled).
- Inspected existing local-agents tooling (hotswap, dispatch, launch scripts).
- Built a proof-of-concept proxy: bin/copilot_local_proxy.py (serves /v1/models, /v1/chat/completions, permissive fallbacks).
- Added launch helper: bin/launch-copilot-agent.sh to set COPILOT_* envs and invoke Copilot CLI.
- Tidied repo: moved planning notes to docs/planning/, moved backups to backups/, updated .gitignore.
- Verified vllm serves qwen-3.6-operator; local dispatch and curl calls return completions.

## Current state (PROOF OF CONCEPT — the goal is NOT met)

**Status corrected 2026-08-16.** This section previously read "Copilot BYOK POC is now
FULLY FUNCTIONAL!". That over-claimed, and the correction matters because the earlier
wording would have shipped a public doc announcing a feature that does not exist.

- **What is actually demonstrated:** the SSE wire format works. Two toy prompts — "Test
  probe" and "Write a small hello world function in Python" — returned completions, and
  `/v1/models` plumbing resolves. That is a transport-level result.
- **What is NOT demonstrated — i.e. the actual goal:** Copilot running local Qwen as its
  main engine once cloud quota is exhausted. Owner testing on 2026-08-15/16 found the
  current behaviour lands much closer in function to the existing
  `bin/local-agent-dispatch.py` than to the intended Copilot-fallback feature. Two toy
  prompts completing is not the same as a usable daily engine.
- **Consequence:** the distinguishing value of this work is entirely in the part that is
  not built yet. In its present form it largely duplicates a tool that already exists here,
  so it is a POC to finish or drop — not a release candidate.
- **Dependency risk (unverified, flagged not disproven):** the mechanism rests on
  `COPILOT_PROVIDER_BASE_URL` / `COPILOT_PROVIDER_TYPE` / `COPILOT_PROVIDER_API_KEY`.
  GitHub's published supported-models documentation lists only vendor-hosted providers and
  says nothing about BYOK or custom/local endpoints, so these appear to be undocumented
  environment variables in a proprietary CLI. Undocumented interfaces can break silently on
  any Copilot update; confirm the contract before treating this as supportable.
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
4. ~~**[NEXT]** Create automated integration test~~ — **ALREADY DONE, this item was stale.**
   `bin/test-copilot-byok-integration.sh` exists and landed in the same commit as the proxy
   (e0b2843). It is a real gate, not a stub: it asserts `SUCCESS_PORT` from hotswap, that the
   proxy process stays alive, that `/v1/models` actually returns `qwen-3.6-operator`, and then
   runs a live `copilot -p` probe. Verified present 2026-08-16 by reading it.
5. **[ACTUAL NEXT]** Decide whether to finish or drop this. To finish, the missing piece is the
   real goal — Copilot using the local model as a working engine on quota exhaustion, not just
   a completing toy prompt. Start by running the integration test above and recording what it
   proves and what it still does not, then confirm whether the `COPILOT_PROVIDER_*` contract is
   supported at all (see the dependency risk above). If that contract is not supportable, this
   approach is a dead end regardless of how much polish the proxy gets.
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
- [x] Harden streaming behavior: support chunked responses or SSE if Copilot expects streaming on the wire API. **DONE** — this was the root cause; see the SSE detail under "Current state".
- [ ] Add full support for /v1/models/<id>/versions and both completions/responses wire APIs.
- [ ] Add robust Authorization handling and expected status codes (401/403 semantics).
- [x] Add an automated end-to-end test and document usage in README. **DONE** — the test is
      `bin/test-copilot-byok-integration.sh` (it landed with the proxy in e0b2843), and the README
      now carries a "Copilot BYOK — experimental" section.
- [ ] If required, implement model-id spoofing fallback (set COPILOT_MODEL to a well-known model, COPILOT_PROVIDER_WIRE_MODEL to local alias).

### Effort override for the launcher — REMOVED FROM CODE, STILL WANTED

**Recorded 2026-08-16 so the intent is not lost now that the code is gone.** Released in
plugin `0.5.1`.

`bin/launch-copilot-agent.sh` used to advertise `Usage: <alias> [effort]`, read the second
argument into `EFFORT_OVERRIDE`, and then **never use it** — so any effort passed was silently
discarded. It was almost certainly inherited by copying `bin/launch-claude-agent.sh`, which does
consume it (`EFFORT="${EFFORT_OVERRIDE:-$LA_CUR_EFFORT}"`). It was the sole cause of the
repository's `tests/lint.sh` failure (shellcheck `SC2034`).

The parameter was removed rather than suppressed with a `shellcheck disable`, because the finding
was correct and described a real silent no-op. **Removal is not a decision that the feature is
unwanted** — it is a decision not to keep advertising one that does nothing. Passing a second
argument now prints an explicit warning.

- [ ] **Feature task: give the Copilot launcher a real effort override.** Parity with
      `launch-claude-agent.sh` is the goal: `launch-copilot-agent.sh <alias> [effort]` should
      actually change how hard the local model works.
      - **Open question that gates it:** Copilot CLI exposes no effort/reasoning knob that this
        script can pass through, which is why it could not simply be wired up. So the override
        has to act on **our** side of the boundary, not Copilot's — most plausibly by selecting a
        different registry alias or by setting the thinking/effort environment the hotswap layer
        already understands (`VLLM_MLX_ENABLE_THINKING` and the per-alias effort in the model
        registry), then serving that to Copilot transparently.
      - Decide whether "effort" for this path means *a different model tier* or *the same model
        with thinking toggled*, since the registry supports both and they are not equivalent.
      - Do not reintroduce the bare `EFFORT_OVERRIDE` declaration to satisfy a usage string; wire
        it end-to-end or leave it out. A comment in the script says the same thing at the point
        where someone would be tempted.

## Recommended immediate next action
Run one more instrumented Copilot BYOK probe while proxy logging is at debug and capture proxy output. If proxy logs lack sufficient detail, run a short loopback packet capture (tcpdump -i lo0 -w /tmp/copilot-probe.pcap) and share or inspect locally.

---
Created for review by haiggoh — adjust priorities or request sudo for packet capture and I will proceed.
