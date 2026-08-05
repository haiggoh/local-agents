---
name: local-agents
description: 'Use when the user wants to offload Claude Code work to a LOCAL MLX model to save cost — PRIMARILY dispatching a delegatable sub-task from their normal cloud session (Opus/Sonnet), and secondarily running a full local session. Triggers: "dispatch this to a local model", "offload this locally to save cost", "run this on qwen locally", "start a local session / local mode", "run the local model tournament", or working offline. Explains how to drive the local-agents overlay: dispatch focused prompts (main use), launch a full local session (niche), and run the diagnostic harnesses. Do NOT use for ordinary cloud work that isn''t being offloaded.'
---

# local-agents — driving local MLX inference

This overlay routes Claude Code directly to a local `vllm-mlx` server on Apple Silicon. Models,
ports, and paths come from `config/config.local.sh` (your private overlay). First-time setup and
full details are in the plugin README; this skill is the quick operational guide.

## Prereqs (once)
Backend + models must be installed: `./install/install-backend.sh`, then
`cp config/config.example.sh config/config.local.sh` and edit it, then `./install/download-models.sh`.
If the user hasn't done setup, point them to the README rather than guessing paths.

## Interactive local session
```
./bin/launch-claude-agent.sh <alias> [effort-override]   # e.g. qwen-3.6-operator, or ... deepseek-r1-architect max
./bin/csl                                                # menu built from the configured aliases
```
The launcher hotswaps the model onto a free port, exports direct-routing env, and starts `claude`.
It injects a self-preservation + tool-use nudge so the local model won't kill its own server port
or leak reasoning markup.

## Dispatch (PREFERRED for focused work — fast, sub-second to seconds)
Full interactive turns on a local 27B are minutes/turn (large prompt × local prefill). For a
bounded task, dispatch instead of launching a session:
```
PORT=$(./bin/local-llm-hotswap.sh <alias> | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<spoof-or-alias>","messages":[...],"max_tokens":512}'
```
For long generations use `./bin/librarian-dispatch.py` (SSE + stall watchdog).

## Diagnostics
- `./bin/direct-route-acceptance.py --port <p>` — validate the fork patches (system-msg normalization, output-limit, KV-cache hit) on a live server.
- `./bin/tournament-dispatch.py` — Stage-A smoke test across your registered models (edit its MODELS list).
- `./bin/cancellation-matrix.py --port <p>` — verify disconnect/timeout retires work (admission safety).
- `./bin/check-tool-roundtrip.py` — after a local session, verify the native tool round-trip + no leak.
- `./bin/auto-mode-probe.sh setup|analyze` — diagnose Claude Code Auto Mode against a local endpoint.

## Safety rules the agent must respect
- NEVER kill/pkill processes on the local server ports — that terminates a running local session.
- Use `--permission-mode acceptEdits` (the launcher sets this); Auto Mode's safety classifier
  can't be served by the local spoofed model.
