# local-agents

**Run Claude Code on local MLX models (Apple Silicon) as an additive overlay.**

Route Claude Code directly to a local [`vllm-mlx`](https://github.com/waybarrios/vllm-mlx) server
so you can work offline or without spending cloud budget — while keeping native transcripts,
`history.jsonl`, and normal Claude Code behavior. It's an **overlay**: your private paths, keys, and
model layout live in a gitignored `config.local.sh`, and your `~/.claude/settings.json` is never
touched. Works with plain `claude` and with wrapped launchers.

> Requires an Apple-Silicon Mac with enough unified memory for your models (the reference stack
> targets a 128 GB M4 Max). This is power-user tooling, not a one-click app.

---

## Why

Claude Code talks to an Anthropic-compatible endpoint. `vllm-mlx` exposes one (`/v1/messages`) and
can serve a local MLX model under a spoofed Claude model id (an org-allowlist workaround). Point
`ANTHROPIC_BASE_URL` at it and Claude Code runs on your local model — free, private, offline-capable.
Earlier proxy/relay approaches broke native transcript + history persistence; **direct routing
restores them** (the proxy in the request path was the suppressor).

## What's in the box

- **`bin/launch-claude-agent.sh`** — start an interactive local Claude Code session (hotswaps a
  model onto a free port, sets direct-routing env, injects a self-preservation + tool-use nudge).
- **`bin/local-llm-hotswap.sh`** — land a registered model on the first free port; safe (never kills
  a healthy model on another port); bounded readiness with diagnostics.
- **`bin/csl`** — menu front-end built from your configured aliases.
- **`config/`** — the overlay: `config.example.sh` (template) + your gitignored `config.local.sh`.
- **`install/`** — `install-backend.sh` (venv + vllm-mlx + fork patches), `download-models.sh`,
  and `vllm-mlx-local-fork-patches.patch`.
- **`bin/` diagnostics** — `tournament-dispatch.py`, `cancellation-matrix.py`,
  `check-tool-roundtrip.py`, `auto-mode-probe.sh`, `librarian-dispatch.py`, `thinking-log.py`,
  `git-local-review`.

## Install

```bash
git clone https://github.com/haiggoh/local-agents && cd local-agents
./install/install-backend.sh                       # venv + vllm-mlx + apply fork patches
cp config/config.example.sh config/config.local.sh # your private overlay (gitignored)
$EDITOR config/config.local.sh                     # set model dir, ports, and your model registry
./install/download-models.sh                       # edit its HF-repo map first, then fetch weights
```

## The overlay (public tooling, private config)

`config.local.sh` holds everything machine-specific — model directory, ports, memory budget, and the
**model registry** (`la_register` lines mapping an alias to a model dir + parser + spoof + effort).
It's gitignored, so this repo can be public without exposing your setup. The scripts fall back to
`config.example.sh` if no local config exists, so a fresh clone still runs and shows you what to edit.
Nothing here modifies `~/.claude/settings.json` or any other plugin's config.

Register your models like this (see `config.example.sh` for the full column reference):

```bash
# alias | subdir | serve | tool_parser | reasoning_parser | thinking | spoof_id | effort
la_register my-operator  Qwen3.6-27B-UD-MLX-4bit  vllm  qwen  ""  false  claude-opus-4-8  high
```

## Usage

```bash
./bin/launch-claude-agent.sh my-operator          # interactive local session
./bin/launch-claude-agent.sh deepseek-r1-architect max   # optional effort override
./bin/csl                                          # pick from a menu
```

**Prefer dispatch for focused work.** A full interactive turn on a local 27B is minutes/turn (large
system prompt + many tools × local prefill speed). For a bounded task, dispatch a small prompt
directly — sub-second to seconds:

```bash
PORT=$(./bin/local-llm-hotswap.sh my-operator | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-8","messages":[{"role":"user","content":"..."}],"max_tokens":512}'
```

## The fork patches (required for direct routing)

`install/vllm-mlx-local-fork-patches.patch` applies three fixes not in upstream `v0.4.0`:

1. **`chat_template_safety.py`** — coalesce all system-role messages into one leading block. Without
   it, Claude Code's top-level system + per-turn `<system-reminder>` land as interleaved system turns
   and the chat template 500s with *"System message must be at the beginning."* (Upstream PR #646 is
   still open — keep this patch.)
2. **`api/utils.py`** — treat `model_type: llama4` as text-only so Llama-4 uses the text route instead
   of a VLM text-extraction path it can't fit.
3. **`engine/simple.py`** — the MLLM KV-cache probe accepts `ArraysCache`, so hybrid models (e.g.
   Qwen3.6's `qwen3_5` arch) can use the system-prefix snapshot cache (turn-2+ prefill hits the cache
   instead of re-prefilling the whole prompt).

Re-apply after any `vllm-mlx` reinstall/upgrade: `git -C <vllm-mlx> apply vllm-mlx-local-fork-patches.patch`.

## Safety

- **Self-preservation.** The launcher tells the local model it *is* the server on its port and must
  never kill processes on the serving ports — a local session that "frees ports to start fresh" would
  kill its own runtime. `hotswap` only ever lands on a *free* port and never kills a healthy model.
- **`acceptEdits`, not Auto Mode.** Auto Mode uses the session model as a tool-safety classifier, but
  the local spoofed model can't serve that call (it loops on "temporarily unavailable"). The launcher
  forces `--permission-mode acceptEdits` (edits auto-apply; other tools prompt). For high-risk actions
  keep human approval — a local model is not Anthropic's safety classifier.
- **No reasoning leakage.** The nudge forbids emitting `<think>` markup / raw chain-of-thought into
  visible output or tool arguments.

## Diagnostics

| Script | What it checks |
|--------|----------------|
| `direct-route-acceptance.py --port <p>` | Validates the direct-routing fork patches on a live server: system-message normalization (all shapes → 200), oversized-`max_tokens` rejection, and system-prefix KV-cache hit (turn-2 reuse). Run after install to confirm the patches took. |
| `tournament-dispatch.py` | Stage-A smoke test per model: load, identity, plain reply, structured tool call, streaming, multi-turn. (Edit its `MODELS` list for your models.) |
| `cancellation-matrix.py --port <p>` | Does a client disconnect/timeout retire the generation (freeing the single slot) rather than block the next request? |
| `check-tool-roundtrip.py` | After a local session, verifies the native tool round-trip (call → result → answer → transcript) with no markup leak. |
| `auto-mode-probe.sh` | Whether Claude Code's Auto Mode classifier request reaches the local endpoint (and where it routes). |

## Troubleshooting

- **Model won't load / `hotswap` times out** — check the log tail it prints; confirm the model dir
  exists and matches your `la_register` subdir; ensure enough free RAM.
- **HF downloads hang** — some networks black-hole the CDN's IPv6; force IPv4 or switch networks.
- **Direct request 500s "System message must be at the beginning"** — the fork patch isn't applied;
  re-apply `vllm-mlx-local-fork-patches.patch`.
- **Interactive turns are slow** — expected for large local models; prefer dispatch for focused work.

## License

MIT © Heiko Brantsch
