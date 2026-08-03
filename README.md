# local-agents

**Save cost (and work offline/privately) by offloading Claude Code work to free local MLX models on Apple Silicon.**

The main use: from your normal Claude Code session — running a capable cloud model like Opus or
Sonnet, whether you connect to Anthropic directly or through a gateway — **dispatch delegatable
sub-tasks to a free local model**. You keep your cloud model driving the hard reasoning and hand
off bulk/mechanical work (searches, summaries, bounded transforms, first-pass reviews) to local
compute — saving cost without changing your workflow or your main model.

It's an **additive overlay**: your private paths, keys, and model layout live in a gitignored
`config.local.sh`, and your `~/.claude/settings.json` is never touched. Works with plain `claude`
and with wrapped launchers.

> Requires an Apple-Silicon Mac with enough unified memory for your models (the reference stack
> targets a 128 GB M4 Max). This is power-user tooling, not a one-click app.

---

## Two ways to use it

**1. Offload sub-tasks from your cloud session — recommended, what most people want.**
Keep driving with your cloud model (Opus/Sonnet). Dispatch bounded sub-tasks to a local model via
`curl` / `librarian-dispatch.py` / `hotswap` — fast (sub-second to seconds), free, private. Nothing
about your main session changes; you're just sending the delegatable parts to local compute. This
saves cost for **anyone**, whether or not you have a spending cap.

**2. Full local mode — niche, for cost/budget-constrained stretches.**
Run an *entire* Claude Code session on a local model (served under a spoofed Claude id so the client
accepts it). Useful mainly when you want zero cloud cost for a block of work, or you're offline.
Trade-off: interactive turns on a local model are slower than a cloud model, so most users won't
want this as their default — reach for it when the cost saving is worth the latency.

## How it works

Claude Code talks to an Anthropic-compatible endpoint. `vllm-mlx` exposes one (`/v1/messages`) and
serves a local MLX model. For dispatch (way 1) you just `curl` that endpoint. For full local mode
(way 2) the model is served under a spoofed Claude model id and `ANTHROPIC_BASE_URL` points Claude
Code at it; direct routing keeps native transcripts + `history.jsonl` working (an earlier proxy
approach suppressed them).

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
  `check-tool-roundtrip.py`, `direct-route-acceptance.py`, `auto-mode-probe.sh`,
  `librarian-dispatch.py`, `thinking-log.py`, `git-local-review`.
- **`bin/new-local-window.sh`** — open a full local session in a new, independent Terminal window (macOS).
- **skills** — `local-agents` (drive local sessions & dispatch) and `offload-to-local` (a habit-forming
  trigger to delegate bulk/mechanical work to a local model to save cost — the plugin's main idea).

## Install

```bash
git clone https://github.com/haiggoh/local-agents && cd local-agents
./install/install-backend.sh                       # venv + vllm-mlx + apply fork patches
cp config/config.example.sh config/config.local.sh # your private overlay (gitignored)
$EDITOR config/config.local.sh                     # set model dir, ports, and your model registry
./install/download-models.sh                       # INTERACTIVE — pick which models to download
```

You choose which weights to fetch — large models aren't the right fit for every machine, and a
**partial roster is fine**: whatever you download fills the roles it's tagged with; the rest of the
work stays on the cloud model.

## The overlay (public tooling, private config)

`config.local.sh` holds everything machine-specific — model directory, ports, memory budget, and the
**model registry** (`la_register` lines mapping an alias to a model dir + parser + spoof + effort).
It's gitignored, so this repo can be public without exposing your setup. The scripts fall back to
`config.example.sh` if no local config exists, so a fresh clone still runs and shows you what to edit.
Nothing here modifies `~/.claude/settings.json` or any other plugin's config.

Register your models like this (see `config.example.sh` for the full column reference):

```bash
# alias | subdir | serve | tool_parser | reasoning_parser | thinking | spoof_id | effort | [roles] | [hf_repo] | [size_gb]
la_register my-operator  Qwen3.6-27B-UD-MLX-4bit  vllm  qwen  ""  false  claude-opus-4-8  high  operator  unsloth/Qwen3.6-27B-UD-MLX-4bit  16
```

The registry is the **single source of truth**: it drives launching, the interactive installer
(`hf_repo`/`size_gb`), and role routing. The last three fields are optional and additive, so older
8-field lines keep working.

### Roles (routing without hardcoding)

Tag each model with the role(s) it can fill — `operator` (bulk/mechanical/tool-driving), `reasoner`
(reasoning first-pass), `validator` (independent review), `utility` (cheap classification). A role
may be filled by several models (your A/B choice) or none (that work stays on cloud). The offload
rules route by **role name**, never a model name, so your roster can change without touching any rule.

Resolve roles → the models you actually have on disk:

```bash
./bin/la-roles.sh          # per-role table: ● on disk / usable now, ○ registered but not downloaded
./bin/la-roles.sh operator # just the on-disk alias(es) for one role
./bin/csl roles            # same, via the csl front-end
```

## Usage

**Way 1 — dispatch a sub-task to a local model (the main use).** Free, fast (sub-second to seconds),
private. Do this from anywhere, including inside your normal cloud Claude Code session:

```bash
PORT=$(./bin/local-llm-hotswap.sh my-operator | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"my-operator","messages":[{"role":"user","content":"..."}],"max_tokens":512}'
```
For long generations use `./bin/librarian-dispatch.py` (SSE + stall watchdog).

**Way 2 — full local session** (niche; slower per turn):
```bash
./bin/launch-claude-agent.sh my-operator                  # interactive local session
./bin/launch-claude-agent.sh deepseek-r1-architect max    # optional effort override
./bin/csl                                                 # pick from a menu of presets
./bin/new-local-window.sh my-operator                     # open it in a NEW, independent Terminal window (macOS)
```

**Convenience (optional):** `./install/setup-shortcuts.sh` puts `csl` on your PATH and adds
`local-*` shell aliases (`local-operator`, `local-menu`, `local-window`, …). Idempotent; edits only
a fenced block in your shell rc.

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
- **"Request timed out" mid-session / a heavy turn never completes** — Claude Code's `API_TIMEOUT_MS`
  defaults to 600000 (10 min) and it also aborts a stream after 5 min with no bytes; a local model doing
  a big prefill over many tools can exceed both. The launcher relaxes them for local sessions
  (`API_TIMEOUT_MS` = `LA_API_TIMEOUT_MS`, default 30 min; `API_FORCE_IDLE_TIMEOUT=0`). Tune
  `LA_API_TIMEOUT_MS` in your config. Complementary lever: fewer tools = smaller prefill = faster turns
  (a lighter MCP set, or start the session with `--strict-mcp-config`).

## License

MIT © Heiko Brantsch
