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
- **`bin/local-agent-dispatch.py`** — universal local model dispatcher, independent of any AI client
  (Claude Code, another agent CLI, or none). Shells out to `local-llm-hotswap.sh` + `librarian-dispatch.py` and
  streams live tokens back to stdout. Install the shell aliases and symlink with `install/setup-shortcuts.sh`
  (or add them manually — see [Local Agent Dispatch](#local-agent-dispatch) below).
- **`bin/csl`** — menu front-end built from your configured aliases.
- **`config/`** — the overlay: `config.example.sh` (template) + your gitignored `config.local.sh`.
- **`install/`** — `install-backend.sh` (venv + vllm-mlx + fork patches), `download-models.sh`,
  and `vllm-mlx-local-fork-patches.patch`.
- **`bin/` diagnostics** — `tournament-dispatch.py`, `cancellation-matrix.py`,
  `check-tool-roundtrip.py`, `direct-route-acceptance.py`, `auto-mode-probe.sh`,
  `librarian-dispatch.py`, `thinking-log.py`, `git-local-review`.
- **`bin/new-local-window.sh`** — open a full local session in a new, independent Terminal window (macOS).
- **skills (7)** — two entry points plus five that each own one phase of a delegation:
  - `local-agents` — drive local sessions & dispatch.
  - `offload-to-local` — the habit-forming trigger to delegate bulk/mechanical work to a local model to
    save cost. The plugin's main idea.
  - `compose-the-payload` — build the dispatch **material** from files on disk, so the corpus never
    enters your own context (this is the actual cost lever).
  - `brief-the-delegate` — write the **instructions**: a stateless dispatch inherits nothing, so every
    unstated ambiguity returns as a confident wrong answer.
  - `isolate-parallel-work` — before dispatching: who owns which port, and does this delegate need its
    own worktree?
  - `guard-shared-runtime` — before touching the shared venv/server, and when the server misbehaves
    (including the wedge whose health check still returns 200).
  - `verify-delegated-work` — after it returns: judge by observable outcome change, never "no error",
    and stop at the retry ceiling.

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
For long generations use `./bin/librarian-dispatch.py --port PORT --payload BODY.json --outdir DIR`
(SSE + stall watchdog; takes a JSON body file, not `--prompt`/`--model`; text lands in `DIR/output.txt`).

**Supervise it.** Offloading pays off only when you verify the result: warm → route (`la-roles.sh`) →
decide `local:`/`cloud:` per step → dispatch → **verify against ground truth** (never trust local
output blind) → correct/re-dispatch. The `offload-to-local` skill documents this loop in full. (Landing
the change afterwards is ordinary shipping discipline, so this plugin deliberately doesn't specify it.)

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

## Monitoring a running local session

Local sessions run direct (no proxy), so there's **no reasoning tee** — you watch a running local
session (or several) via two per-session sources. `bin/local-watch.sh` discovers what's running and
prints ready-to-run monitor commands; feed them to your watcher (a terminal, or Claude Code's Monitor
tool). It handles **multiple concurrent sessions** — each local server has its own port log, each
session its own transcript.

```bash
./bin/local-watch.sh            # list running sessions, active ports, recent transcripts + monitor cmds
./bin/local-watch.sh --health   # just the per-port vllm-log health monitors
./bin/local-watch.sh --mutations# just the transcript mutation/thinking monitors
```

- **Health / turns / timeouts / stalls** → `~/.claude/logs/vllm_<PORT>.log` (one server = one log, so N
  concurrent servers are unambiguous). Filter to `[REQUEST]`/`CLEANUP done`/timeout/error/disconnect;
  drop the 5-second `disconnect_guard poll` heartbeats.
- **Mutations + reasoning** → the session's native transcript `.jsonl`: `tool_use` records
  (Bash/Edit/Write/git/waypoints…) and `type:"thinking"` blocks.
- **Post-hoc chain-of-thought** → `bin/thinking-log.py --latest --local-only` (extracts the reasoning
  blocks; `--local-only` = unsigned = the local model's).

**How live is it?** Two separate delays: the model's **generation** latency (minutes for a big local
turn — inherent; reasoning doesn't exist until it's generated, and a non-streaming turn delivers it
whole at the end) and the transcript **flush** lag (turn completes → record on disk). Measured on
Claude Code 2.1.205, the flush lag for the reasoning-carrying `assistant` records is **~0.2–2.6s** —
so once a turn finishes, its thinking/tools are readable within a few seconds. Re-check after a Claude
Code upgrade (it regressed to 30+min on 2.1.197 once):

```bash
# print how many seconds after each new record's timestamp it lands on disk (run during activity)
python3 - <<'PY'
import time,os,json,datetime,glob
p=max(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),key=os.path.getmtime)
f=open(p); f.seek(0,2)
end=time.time()+120
while time.time()<end:
    ln=f.readline()
    if not ln: time.sleep(0.1); continue
    try: r=json.loads(ln); t=datetime.datetime.fromisoformat(r["timestamp"].replace("Z","+00:00")).timestamp()
    except: continue
    print(f"{r.get('type','?'):10} flush≈{time.time()-t:4.1f}s", flush=True)
PY
```

**Limitation vs the retired proxy era:** the old in-path proxy could livestream reasoning
*token-by-token*; the transcript gives it per-turn (after ~sub-3s flush), not mid-generation. If you
need true live thinking, the non-invasive path is a vllm-mlx **server-side token log** (a fork patch
that tees streamed tokens/reasoning to a per-request file) — restores the live stream without a
request-path proxy that would re-break native transcripts.

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
- **Interactive turns are slow** — the cost is *prefill*, not generation, and the prompt is mostly
  tool definitions. Measured on this stack (2026-08-17, the real `claude -p` payload intercepted):

  | component | chars | ~tokens | share |
  |---|---:|---:|---:|
  | built-in tool definitions (31) | 90,734 | 24.5k | 36% |
  | MCP tool definitions (68 across 3 servers) | 82,824 | 22.4k | 33% |
  | system prompt | 11,194 | 3.0k | 4% |
  | per-turn context re-injection (project instructions, memory index, hook banners) | 73,153 | 19.8k | 29% |
  | **total first-turn prefill** | **254,045** | **68.7k** | |

  The single heaviest definition is one tool at ~5.9k tokens — more than the whole system prompt.
  Two consequences: the launcher now defaults to `--strict-mcp-config` (`LA_STRICT_MCP`), which removes
  71 tool definitions and ~23k prefill tokens; and the remaining per-turn cost is the ~20k-token context
  block, which the server log confirms is re-prefilled on **every** turn even on a cache hit
  (`cache HIT: reusing 62223 cached tokens` followed by `prefilling 19357 new tokens`). Dispatch sends
  a prompt three orders of magnitude smaller, which is the whole reason it feels instant — prefer it
  for focused work.
- **A tool is missing in a local session** — `LA_STRICT_MCP` defaults to `true`, so MCP-provided tools
  are deliberately absent (the launcher prints this at startup). Set `LA_STRICT_MCP=false` to restore
  them, accepting ~23k more prefill tokens per cache miss.
- **`--allowedTools` does not make a session faster** — it filters what may run, not what is *sent*;
  the definitions still occupy the prompt. Measured: restricting to 8 tools left the payload unchanged.
- **★ Every turn seems to take two or three times longer than the model needs** — check the port's log
  for this signature:

  ```
  [disconnect_guard] START poll=0.5s heartbeat=5.0s timeout=300s
  [disconnect_guard] TIMEOUT after 300s, 2 chunks, 60 heartbeats
  [REQUEST] POST /v1/messages (anthropic) stream=False ...   <- same turn, retried
  Anthropic messages: 202 tokens in 220.76s (0.9 tok/s)
  ```

  `vllm-mlx serve` caps every request at **300s by default** and its streaming guard enforces that
  *server-side*, so relaxing Claude Code's client timeouts does nothing: at ~0.9 tok/s an ordinary turn
  exceeds 5 minutes, the server kills the stream, and the client re-runs the whole turn non-streamed.
  You pay 300 wasted seconds before the attempt that actually answers. `hotswap` now passes
  `--timeout $LA_SERVER_TIMEOUT_S` (default 1800). **Serve flags are fixed at launch**, so a server
  started before this change keeps the 300s cap — hotswap detects that on the reuse path and tells you
  to restart it rather than silently handing back a warm-but-broken server.
- **"Request timed out" mid-session / a heavy turn never completes** — Claude Code's `API_TIMEOUT_MS`
  defaults to 600000 (10 min) and it also aborts a stream after 5 min with no bytes; a local model doing
  a big prefill over many tools can exceed both. The launcher relaxes them for local sessions
  (`API_TIMEOUT_MS` = `LA_API_TIMEOUT_MS`, default 30 min; `API_FORCE_IDLE_TIMEOUT=0`). Tune
  `LA_API_TIMEOUT_MS` in your config. See the prefill table above for what is actually consuming the
  time — the `LA_STRICT_MCP` default already removes the largest avoidable slice.

## Savings ledger — what did offloading actually avoid paying for?

Every local dispatch is work a metered cloud model would otherwise have billed you for.
`bin/savings-ledger.py` records each one and values the counterfactual:

```sh
savings-ledger.py record --model qwen-3.6-operator --in 9123 --out 412
savings-ledger.py report --today          # also --week, --month, --since YYYY-MM-DD, --json
savings-ledger.py rollup                  # regenerate the derived rollup
savings-ledger.py rates                   # the rate table and its as-of date
```

`bin/librarian-dispatch.py` appends an event automatically on every successful dispatch
(`--no-ledger` opts out, `--priced-against MODEL` picks the comparison rate). Recording is
best-effort and can never fail a dispatch that already produced output.

**Store** — `~/.claude/local-agents/` (override with `$LOCAL_AGENTS_LEDGER_DIR`), outside the
plugin so updates never touch your data:

- `savings.jsonl` — append-only, one JSON object per dispatch: timestamp, session, local
  model, in/out tokens, the cloud model and rates it was priced against, and the saving.
- `rollup.json` — **derived**, grouped by `(session, UTC day)`. Regenerate it; never hand-edit
  it. It carries `source_events` so you can tell when it's stale.

### Two things it refuses to do

Both are the same principle: a number that looks real but isn't is worse than a stated gap.

**It never prices an unknown model at zero.** A model missing from the rate table records
`saved_usd: null` with `rate_source: "unknown"`, and `report` counts those out loud. Zero
claims the work was free; null says it wasn't valued. (This is not hypothetical — an earlier
tool here priced `claude-opus-5[1m]` at `0.00` because its table was keyed on bare names.
Model ids are normalized before lookup: context-window suffixes `[1m]`, provider prefixes
`anthropic.`, deployment suffixes `-fast`, and dated snapshots all resolve to the catalog name.)

**It never reports a missing prompt-token count as "saved nothing".** Measured on this
backend: it returns `prompt_tokens: 0` even for a ~21,600-character prompt. Offload savings
live mostly on the *input* side — large corpus in, short answer out — so a silent zero would
understate the total by orders of magnitude. Such events are flagged
`input_tokens_source: "unavailable"` and keep the prompt's raw **character** count (a fact,
not an estimate), so `report` says the figure is understated and a later pass can price them
properly:

```text
local offload (all time): 1 dispatch(es), 0 in / 2 out, saved $0.00
  ⚠ 1 event(s) counted the OUTPUT side only covering 9,232 unmeasured prompt characters —
    the server reported no prompt-token count, so the real saving is materially higher
```

### Rates

The built-in table is a **dated snapshot** (`savings-ledger.py rates` prints its as-of date,
and every event records which table priced it). Verify against current vendor pricing before
trusting a large total, and use `--rates-file` to supply your own rather than editing the
plugin.

## License

MIT © Heiko Brantsch

---

## Local Agent Dispatch

`bin/local-agent-dispatch.py` is a universal local model dispatcher that works independently of any AI
client — use it from a plain terminal, a shell script, a Claude Code session, another agent CLI, or a
CI pipeline. No cloud account or API key is needed for the dispatched work.

It is also a terminal-native companion interface for interactive local-agent work outside Claude Code.
It reuses the same model registry, hotswap layer, and librarian dispatcher as the rest of this repository.
The current dispatcher version is `0.9.0`. It is functional and in daily use, with known rough edges
tracked in `docs/local-agent-dispatch/CHANGELOG.md` — expect fixes in subsequent releases rather than
a frozen surface.

### Shell aliases

Add these to your `~/.zshrc` (or `~/.bashrc`):

```zsh
_la_bin="/path/to/local-agents/bin/local-agent-dispatch.py"
alias local-agent="$_la_bin"                                      # default → qwen-3.6-operator
alias local-agent-qwen="$_la_bin --model qwen-3.6-operator"      # Qwen 3.6 27B operator
alias local-agent-thinking="$_la_bin --model qwen-3.6-thinking"  # Qwen 3.6 with thinking
alias local-agent-r1="$_la_bin --model deepseek-r1-architect"    # DeepSeek R1 reasoner
alias local-agent-scout="$_la_bin --model llama-scout"           # Llama Scout fast/light
alias local-agent-kimi="$_la_bin --model kimi-vl-thinking"       # Kimi VL multimodal
alias local-agent-kat="$_la_bin --model kat-coder-optiq"         # KAT Coder OptiQ
alias local-agent-devstral="$_la_bin --model devstral-2-123b"    # Devstral 2 123B
alias local-agent-gemma="$_la_bin --model gemma-4-26b"           # Gemma 4 26B
```

Or create a symlink for shell-agnostic access:

```bash
ln -sf /path/to/local-agents/bin/local-agent-dispatch.py ~/.local/bin/local-agent
```

### Conversation mode

Start an interactive terminal conversation:

```bash
local-agent --convo
```

Conversation mode supports structured history, model-specific labels,
compact/verbose/quiet progress, multiline `:paste` / `:end` input, rolling
summaries, `:file PATH` attachments, and resumable named sessions.

See [`docs/local-agent-dispatch/README.md`](docs/local-agent-dispatch/README.md)
for the complete dispatcher reference and development notes.

### Usage

```bash
# Generic (defaults to qwen-3.6-operator):
local-agent --prompt "What does this module do?" --files src/main.py

# With a specific model:
local-agent-r1 --prompt "Review this plan and identify architectural risks"

# Multiple files, custom token budget:
local-agent-devstral --prompt "Refactor the following into clean functions" \
  --files utils.py helpers.py --max-tokens 2048

# Piping output to a file:
local-agent-qwen --prompt "Summarize test coverage gaps" --files tests/ > summary.txt

# Inside any agent CLI or Claude Code session (prefix ! to run locally, zero cloud quota):
! local-agent-qwen --prompt "First-pass review of this diff" --files my_changes.patch
```

### Options

| Flag | Default | Description |
| :--- | :--- | :--- |
| `--model` | `qwen-3.6-operator` | Model alias from your `config.local.sh` registry |
| `--prompt` | *(required)* | Task prompt text |
| `--files` | *(none)* | One or more file paths to inline as context |
| `--max-tokens` | `4096` | Max tokens the model should generate |

## Copilot BYOK — experimental, not a supported feature

`bin/copilot_local_proxy.py`, `bin/launch-copilot-agent.sh` and
`bin/test-copilot-byok-integration.sh` are an **unfinished proof of concept**, documented here only
so that nobody who stumbles across them mistakes them for a working feature.

The aim was to let GitHub Copilot fall back to a local model once cloud quota runs out. **That does
not work yet.** What is proven is the streaming wire format; what is not proven is Copilot actually
running on a local engine. In its present state it overlaps `local-agent-dispatch` above, so it adds
nothing you cannot already do — and it leans on undocumented `COPILOT_PROVIDER_*` environment
variables that may stop working without warning.

It lives in this repository rather than its own because it reuses the same model registry, hotswap
layer and launcher conventions as everything else here; splitting it out would mean maintaining a
second copy of that infrastructure and letting the two drift. Nothing in the plugin points at it, it
receives no support, and it may be removed. Details and the honest status:
[`docs/local-copilot-byok/COPILOT-BYOK-README.md`](docs/local-copilot-byok/COPILOT-BYOK-README.md).
