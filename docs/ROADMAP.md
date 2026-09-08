# Roadmap

`CHANGELOG.md` records what shipped. This file records what is **specced but not shipped**, so a
planned feature cannot be quietly dropped between releases.

It exists because `0.13.0`'s changelog claimed to "add project-wide changelog and roadmap
documentation" and only the changelog appeared. The `0.14.0` specification lived entirely outside the
repository, in a plan file on one machine, while `CHANGELOG.md`'s `[Unreleased]` section sat empty —
so "did we skip a specced feature?" was not answerable from the repo at all. It is now.

**How to use this file:** an item leaves this file only by moving into `CHANGELOG.md` under a real
version. Nothing is deleted for being inconvenient. If an item is abandoned, it moves to
[Deliberately deferred](#deliberately-deferred) with a reason — never silently removed.

---

## Current released version

`0.13.10`. See `CHANGELOG.md`.

> Keeping this line correct is the smallest possible test of whether this file is being maintained.
> If it disagrees with `.claude-plugin/plugin.json`, treat everything below as suspect too.

Versions `0.13.1`–`0.13.5` consolidated four outstanding feature branches into `main` on 2026-09-01,
so `0.14.0` Phase A reconciles one base rather than five divergent branches. `0.13.6` then applied a
skill fix on top — and correctly declined to take `0.14.0` for it, which is this file working.

`0.13.x` is deliberately being used for feature work that would conventionally earn a minor bump.
**The version number is a release gate:** a reserved number must not be spent on anything else,
because a premature bump would make its gate list unverifiable — a released version that meets only
half its gates cannot be un-released. Patch-level bumps below it are the cost of keeping that
guarantee.

**Reassigned 2026-09-06.** `0.14.0` was previously reserved for the *runtime profiles* architecture.
It now belongs to **portable manifests and artifact identity**, and runtime profiles move to
`0.15.0`. See [Release sequence](#release-sequence--why-0140-was-split) for why. The reservation
discipline is unchanged; only which number holds which scope has moved.

`0.13.8` released what had accumulated past `v0.13.7`: the per-model auto-compaction profiles and
**locally routed Auto Mode**, plus the telemetry-off default for local sessions. The "verified
2026-09-05" note that stood here has been **withdrawn** — see
[Auto Mode](#locally-routed-auto-mode-correctness). The verification was real but ran in a fresh
project with no accumulated context, which is the one condition under which the feature cannot fail.
`feat/auto-mode-classifier-localhost-routing` was merged fast-forward, so `main`'s history is linear
and every commit stays attributable. `main` now carries **nothing** awaiting a release number.

The portable-model-manifest specification (a self-describing `.local-model-manifest.json` beside each
artifact's weights) lives on the branch `feature/portable-model-manifests` and is **not** on `main`.
It was previously omitted from this file for that reason. **Corrected 2026-09-06:** an unmerged
*branch* is not a reason to omit a *spec* — this file's stated job is to record what is specced but
not shipped, and the manifest architecture is now the foundation `0.14.0` is named for. It has its own
section below. Landed code awaiting a number still belongs in the changelog; only the sections below
are specs.

---

## Release sequence — why `0.14.0` was split

**Decided 2026-09-06.** Every roadmap item used to sit behind one large `0.14.0`. That was a
sequencing accident, not a dependency: the old `0.14.0` bundled **two different kinds of identity**,
and only one of them is a prerequisite for anything else.

| Identity | Question it answers | Who needs it |
|---|---|---|
| **Artifact** identity | *What is this thing on disk?* | acquisition, catalogue, retirement, disk decisions |
| **Runtime** identity | *How should it be served?* | `csl`, hotswap, dispatcher, backend selection |

The acquisition and retirement programme — the highest-priority work — needs only **artifact**
identity. Gating it behind runtime profiles kept a large, urgent, mostly-independent workstream
waiting on an architecture it does not read. So the split is:

| Version | Scope | Gates on |
|---|---|---|
| `0.13.9` | **Operational unblocks.** Rapid-MLX upgrade to the current release; locally routed Auto Mode correctness. No schema changes, no new architecture. | nothing |
| `0.14.0` | **Portable manifests and artifact identity.** `.local-model-manifest.json`, manifest tooling, downloader writes a truthful manifest atomically. | `0.13.9` only for convenience |
| `0.15.0` | **Runtime profiles.** The three profile JSONs, canonical resolver, profile-aware hotswap, `csl`/roles, dispatcher migration. (The former `0.14.0` Phases B–D, F, G.) | `0.14.0` |
| `0.16.0` | **Backend lanes.** [oMLX](#0160--backend-lanes--omlx) as an isolated optional backend. | `0.15.0` — a runtime profile is the clean way to select a backend |

**Not release-gated at all.** These run continuously against whatever is current, and must not be
parked behind a version number: model acquisition waves, the tournament, retirement and disk
decisions, and local-session UX fixes. Several are user-flagged high priority, and a release number is
the wrong instrument for holding them.

**Ordering authority.** The dependency-ordered index across every open item is the waypoint
`local-agents-master-order-the`. This table is the *release* shape; that waypoint is the *work* order.
Where they disagree, the waypoint is newer.

---

## Runtime direction — Ornith, and the 200K context finding

**Status: settled as a direction, unfinished as an implementation.**

The branch `experiment/ornith-200k-autocompact` has been **merged deliberately**. It is no longer an
experiment; it is the intended direction for full local sessions. What it established:

| Question | Result |
|---|---|
| Interactive speed vs Qwen 3.8 | **Markedly faster** in real Claude Code use |
| Advertised context | **200K+**, confirmed in the model's own documentation |
| Stability well past 100K, no auto-compaction | **Held** — no instability observed |
| Suitability for a *full* local session | **Yes** — not merely stateless dispatch |

**Why the context result matters beyond one model.** A 100K local threshold was always a *fallback
guess*, never a measured property: prior local failures clustered near 103K–105K, and the native
`--autocompact` minimum is itself 100K, so no lower threshold was even enforceable. A model that
runs far past 100K with compaction switched off shows that the ceiling is per-artifact — a function
of model, quantization, runtime, backend and co-residency — rather than a universal constant. This
is exactly the distinction the catalogue work insists on: **an architectural maximum is not the
tested safe operating limit.** Ornith supplies the first strong data point for a `tested_safe`
value that is not a guess.

**What this does NOT do.** It discharges no release gate, promotes no roster-wide default, and is not
a controlled benchmark. It is a proof of concept, and the remaining work is spread across the `0.14.0`
manifest programme (which is where a `tested_safe` value gets recorded) and the `0.15.0` runtime-profile
programme (which is where one gets selected) — which is why the merge changes direction without changing
status.

Cross-references: waypoint `local-model-context-catalogue` owns the per-model context fields this
evidence feeds (`advertised` / `runtime_supported` / `tested_safe` / `auto_compact_window`, each with
evidence and a test date); `local-compaction-and-metal` owns the compaction-and-Metal qualification
that must still be run per promoted profile.

---

## `0.13.9` — Operational unblocks

**Status: NOT STARTED.** Both items are user-flagged high priority. Neither changes a schema or adds
architecture, which is why they are a patch release and not gated behind anything.

### Rapid-MLX upgrade to the current release

`LA_RAPID_BIN` is pinned to the qualified `0.12.18`. A side-by-side venv was built for `0.13.2` on
2026-08-31 and never smoke-tested, so it never got promoted.

**Retarget to `0.13.4`** (latest on PyPI, uploaded 2026-09-03) rather than finishing the `0.13.2`
promotion — `0.13.2` was never qualified, so there is no evidence to preserve by going through it, and
promoting a superseded version means running the same smoke test twice.

What the promotion needs, unchanged from waypoint `promote-rapid-mlx-0-13-2-to`: serve a Qwen3.6/3.8
4-bit on a free port (capture `SUCCESS_PORT`, never assume 8000); `GET /v1/models` shows the spoof id;
one Anthropic `/v1/messages` round-trip; one structured tool call via `qwen3_coder_xml`; warm-vs-cold
TTFT to confirm the hybrid prefix cache still engages; and an explicit concurrency check.

**The dependency delta is the part not to skip.** `0.13.2` already moved `transformers` 5.12.1→5.15.1
and `mlx` 0.31.2→0.32.2, and `0.13.4` must be re-checked rather than assumed equal. **`mlx` is the
layer every Metal-ceiling figure was measured on**, so recorded Metal numbers are invalid until
re-measured — they must not be carried across the upgrade. Retain `0.12.18` for at least 7 successful
days; deleting it needs separate approval of exact paths.

Homebrew remains rejected for this: it will not pin `mlx`. Reasons are on record in memory
`rapid-mlx-venv-vs-homebrew` so they are not re-litigated.

### Locally routed Auto Mode correctness

**Released in `0.13.9` on 2026-09-06.** The operational fix uses segmented
classifier transcripts and an isolated oMLX endpoint with a separate dense
`claude-sonnet-5` classifier. The measured paged-prefix cache reused nearly
all prior classifier context on growing requests. Rapid remains the rollback
lane; classifier verdict-quality comparison remains separate qualification
work.


**The `0.13.8` "verified" claim is withdrawn.** Auto Mode worked for roughly the first two hours of a
real session on 2026-09-05 and then failed permanently — about 40 consecutive refusals reading
`claude-sonnet-5 is temporarily unavailable (timed out)`, then stage-2 classifier errors.

Measured root cause, from correlating every classifier request in `~/.claude/logs/vllm_8000.log` to its
outcome:

- The classifier prompt is **the entire conversation transcript**, not a small policy prompt. Measured
  growth across one session: 35k → 75k tokens.
- Claude Code's stage-1 deadline is computed, not fixed:
  `min(120_000, 60_000 + ceil((max(classifierTokens, mainLoopTokens) − 50_000) / 50_000) × 10_000)` ms.
  Base **60s**, +10s per 50k context, hard cap **120s**. That reproduces the observed 70.3 / 80.4 /
  90.4s disconnects exactly.
- **Budget grows 10s per 50k; prefill costs ~62s per 50k at ~800 tok/s.** The two curves diverge, so no
  base constant fixes this — raising the deadline moves the crossover, it does not remove it.
- The prompt is re-prefilled from scratch every call. The cache reports
  `LCP unavailable: shared=11207 … non_trimmable=True` — it *finds* the shared prefix and discards it.

**Three corrections to premises this repo previously relied on:**

1. **Slot contention was never the binding constraint.** Every classifier `[schedule]` line read
   `running=1 waiting=0` (651 of 657 samples; `running=2` occurred 3 times). `--max-num-seqs 2`
   relieved a constraint that was not binding.
2. **The classifier prompt is not small.** The 35,154-token figure on record was the *first* call of a
   session — a floor mistaken for a ceiling.
3. **The classifier model is not redirectable by configuration.** `CLAUDE_CODE_AUTO_MODE_MODEL` exists
   in the binary but is never read; it appears only in host-managed env passthrough allowlists. The
   resolver reads remote config, then a hardcoded default. There is no classifier timeout env var
   either.

**Direction (no proxy).** The classifier always *requests* `claude-sonnet-5`, and Rapid routes by
requested model name through its `ModelRegistry` (`routes/anthropic.py`, `get_engine(request.model)`).
`POST /v1/models/load` is unconditional — the residency manager is always constructed and shares that
registry. So a **second small model registered under the name `claude-sonnet-5`** serves the classifier
on the same port as the session's `claude-opus-5`, with no proxy and no env var. Verified: two models
resident on one port, second one loaded in 1.9s.

**Open question gating the model choice:** the classifier engine must have a **trimmable** cache.
Hybrid Mamba/SSM models (granite-4.0-h, and the KAT-Coder path in the failing session) report
`non_trimmable=True` and cannot reuse a partial prefix, only an exact full match — so they pay full
prefill every call. A dense-attention model should trim and reduce each call to the delta. Measured so
far: granite 30k tok in 12.3s / 60k in 38.6s versus Qwen3.8-27B-4bit 28k in 145.1s, but two granite
runs disagreed by ~8× under memory contention, so the prefill curve needs a clean re-measurement before
a model is committed.

Also to try: `CLAUDE_CODE_AUTO_MODE_SEGMENTED_TRANSCRIPT=1`, which *is* env-readable (default `false`)
and splits the transcript into one message per block, giving the cache message-aligned boundaries
instead of one mutating blob.

**Settled 2026-09-06 — do not patch the deadline formula.** The constants (`60000`, `120000`) are plain
text in the JS bundle inside the `claude` binary and a same-byte-length numeric patch would work, so
this was considered and **rejected on the merits, not on difficulty**: the budget grows 10s per 50k
while prefill costs ~62s per 50k, so a larger constant moves the crossover point without removing it,
and the formula's own 120s hard cap means there is a context size past which no constant helps. It
would also be a code-signed vendor binary reverted by every Homebrew cask update, i.e. permanent
maintenance for a temporary reprieve. **Fix the cost side.** Do not reopen this without new evidence
that the slope, not the intercept, has changed.

Repo defects to fix in this release, all verified: the OOM guard in `launch-local-auto-mode.sh` is
silently dead (`ps -o wired=` is not a valid macOS keyword — `ps: wired: keyword not found`, so the
value is always 0 and the guard never fires); strategy `b` is a self-documented no-op; the "classifier
prompt is tiny" comments in `launch-local-auto-mode.sh` and `config-lib.sh` justify the wrong fix; and
`csl` defaults Auto Mode **on** while the path it actually launches
(`launch-claude-agent.sh`) bypasses every guard in `launch-local-auto-mode.sh`.

---

## `0.14.0` — Portable manifests and artifact identity

**Status: NOT STARTED on `main`.** The specification and partial work live on
`feature/portable-model-manifests`, which is not merged.

**Specifications of record:**

- `~/.claude/plans/Plan — Portable Local-Model Manifests, Researched Catalogue, and Context-Aware
  Sessions (Merged Update).md` (919 lines, 2026-09-04). Absorbs the earlier
  `Plan: Integrate model context and autocompaction catalogue into local-agents`, which needs no
  separate tracking.
- `~/.claude/plans/Plan — Local Model Acquisition, Portable Manifests, Tournament, and Retirement
  (Reviewed Update).md` (439 lines, 2026-09-05) — waypoint `local-model-acquisition`.

Waypoints: `portable-local-model` (the source-of-truth gate every other manifest item waits on),
`manifest-tooling-build`, `downloader-writes-a-truthful`, `controlled-44-entry-manifest`,
`release-the-manifest-tranche`, `local-model-context-catalogue`, `later-let-agy-discover`.

### The decision it supports

One artifact's truth lives **beside its weights**, in `~/.models/<dir>/.local-model-manifest.json`, not
in a catalogue that drifts from disk. The manifest records source repo/revision, directory, kind,
launchability, context source and pointer, exact configured context, server/tested/effective context,
quant/runtime/hardware, test date, and any sidecar relationship.

The division that must not blur:

| Artefact | Role |
|---|---|
| PSV catalogues | acquisition selection and download metadata |
| reviewed context YAML | migration/reconciliation evidence |
| `.local-model-manifest.json` | installed-artifact truth beside the payload |
| `local-agents` | validated *consumer* of manifest/runtime state |

None of the catalogues is an independently authoritative runtime database.

### Autocompaction semantics (corrected)

Claude Code accepts explicit settings in 100,000-token increments, minimum 100,000, maximum 1,000,000:

```
autocompaction = min(1_000_000, floor(effective_context / 100_000) * 100_000)
```

`effective_context` is the **minimum** of: selected native or explicitly qualified extended mode; exact
artifact configuration; backend capability; explicit server allocation; and any enforced tested-safe
cap. **A model's architectural maximum is not permission to allocate it** — a recommendation is invalid
whenever the live server exposes less.

### Phases

- [ ] **A — Reconcile the live base** (moved here from the old `0.14.0`). Branch/HEAD/tags/remote/index/
      worktree, and ownership classification of every dirty path. Shared with `0.15.0`; do it once.
- [ ] **B — Catalogue source-of-truth decision.** YAML vs PSV vs sidecar manifest, resolved to one
      deterministic outcome. Gates everything else here.
- [ ] **C — Manifest tooling.** build / validate / inspect / reconcile / backfill, standard library only.
- [ ] **D — Downloader writes a truthful manifest at completion, atomically.** A metadata-only directory
      is not a complete acquisition. Interrupted completion must repair metadata without re-downloading.
- [ ] **E — Controlled 44-entry backfill.** Eleven ordered gates, never a blind `--all`.
- [ ] **F — `csl` derives context and autocompaction from manifests,** preserving explicit overrides.
      Fail *before* Claude Code starts on invalid configuration, printing model identity, artifact
      context, server context, effective context, selected autocompaction, and the corrective action.
- [ ] **G — Release the tranche.** Reconcile the version first, then changelog, tag, publish.

### Known premise defects in the specifications

Both found 2026-09-06; fix the plans, not just the code.

- The acquisition plan's §1 says the repo already contains `config/model-catalogue-context-list.yaml`.
  It is not on `main` and not on disk — it exists only in `e27f31a` on
  `feature/portable-model-manifests`. §6 tells the implementer to merge additions *into* that file, so
  §6 has no base until that branch is reconciled.
- **Catalogue inputs arrive with a false extension.** Notes exported from JoyIA Chat can only download
  as `.md`/`.txt`/`.pdf`, so a plan names `foo.psv` while disk holds `foo.psv.md`. All four inputs for
  the acquisition plan were affected. **Check for a trailing `.md`/`.txt` before reporting a plan's
  input file missing.** A rename may still not be enough: catalogue resolution is a hardcoded filename
  list, not a glob (`bin/la-disk-inventory.sh`), so each new catalogue must also be *registered* in the
  consumer or it stays invisible while looking installed.

---

## `0.15.0` — Runtime profiles and Rapid-first model management

> **Renumbered 2026-09-06** from `0.14.0`. Scope is unchanged; only its place in the sequence moved,
> because the manifest foundation below is what other workstreams actually read. Phase **A**
> (reconcile the live base) is no longer part of this release — it moved to `0.14.0`, which needs the
> same reconciliation first and would otherwise duplicate it.

**Status: NOT STARTED.** No gate here is implemented. Nothing in `0.13.1`–`0.13.8` advances one.

**Specification of record:** `~/.claude/plans/Plan — local-agents 0.14.0 Runtime Profiles and
Rapid-First Model Management.md` (1,288 lines), tracked by waypoint `local-agents-0-14-0-runtime`.
That plan is authoritative for detail; this section is the checklist, and is deliberately terse
enough to stay accurate.

### The decision it supports

Separate **artifact identity** (what is on disk) from **runtime behaviour** (how it is served). Today
one `la_register` line conflates them, which is why a model cannot have two runtime personalities
without being registered twice — the exact duplication that forced the `qwen-3.x-rapid-*` aliases
retired in `0.13.1`.

### Identity model — five layers (§5)

| Layer | Artifact | Status |
|---|---|---|
| Artifact identity | `config/model-catalog.psv` | ✅ exists |
| Runtime-profile identity | `config/model-runtime-profiles.json` | ❌ not created |
| Resource-profile identity | `config/runtime-resource-profiles.json` | ❌ not created |
| Environment-profile identity | `config/runtime-environments.json` | ❌ not created |
| Live-server identity | `server_<port>.meta` | 🟡 partial — exists, needs profile fields (§5.5, §12) |

### Phases (§22) — strictly ordered

- [ ] **A — Reconcile the live base.** Inspect branch/HEAD/tags/manifest/remote/index/worktree,
      including ignored files. Report before mutating.
      *Materially easier as of `0.13.5`: all four outstanding feature branches are merged to `main`,
      so Phase A reads one consolidated base instead of five divergent branches.*
- [ ] **B — Read-only resolver prototype.** Create only the three JSON files plus
      `bin/la-model-profile.py`. Seed one artifact (`qwen38-27b-4bit`) and two profiles
      (`qwen38-rapid-operator`, `qwen38-rapid-thinking`) plus one legacy fallback. Change no
      downloader or launcher behaviour until it passes. This is the [smallest first
      slice](#smallest-first-slice).
- [ ] **C — Validation and legacy adaptation.** Base/local overlay loading; validate references,
      duplicates, cycles, paths, provenance; adapt existing `la_register` entries into compatibility
      profiles; migration preview with no writes.
- [ ] **D — Profile-aware hotswap.** Resolve through the canonical resolver; preserve the existing
      backend branches; emit the structured launch result (§12); expand server metadata identity;
      verify requested vs effective `/v1/models`; refuse unsafe reuse; exercise rollback.
- [ ] **E — Downloader adaptation.** Profile/backend/capability filters; profile→artifact resolution;
      preserve every existing safeguard; fix registry/catalog duplication via canonical artifact
      identity; JSON listing output.
- [ ] **F — `csl` and roles.** Consume shared profiles; show only session-capable combinations;
      preserve role recommendations and free composition; keep legacy aliases working.
- [ ] **G — Dispatcher migration.** Resolve profile before hotswap; use the effective API model ID in
      payloads; named sessions to schema v2 while still loading v1; test one-shot and conversation
      flows on Rapid; preserve output and persistence semantics.
- [ ] **H — Packaging preparation.** `packaging/standalone-files.txt`; deterministic builder;
      isolated artifact tests. Do not publish until the clean-install gate passes.
- [ ] **I — Documentation and release.** README architecture and commands; CHANGELOG with the exact
      verified release base; document schemas, migration, profiles, fallback; align the manifest and
      version **only after** tests pass.

### Hotswap contract (§12)

`SUCCESS_PORT` alone is insufficient once the user-facing profile ID differs from the API model ID
the backend serves. Hotswap must return structured JSON (`schema_version`, `port`, `api_model_id`,
`profile_id`, `artifact_id`, `backend`, `backend_version`, `environment_profile`, `resource_profile`,
`reused`). `SUCCESS_PORT=` / `SUCCESS_MODEL_ID=` may continue to be emitted for compatibility, but
consumers should migrate. **Status: ❌ not started** — hotswap emits `SUCCESS_PORT` only.

### Smallest first slice

Before any refactor, prove this read-only vertical slice: both profiles resolve to the same exact
artifact; operator and thinking settings differ correctly; no network access; no change to downloader
or launcher behaviour; all identities and provenance visible; invalid references and duplicate IDs
fail deterministically. **Only then** may the resolver become a dependency of anything else.

### Release gates (§19) — all must hold

```text
[ ] live 0.13.6 base reconciled
[ ] artifact/profile/resource/environment schemas documented
[ ] canonical resolver tests pass
[ ] legacy private configuration remains usable
[ ] profile-aware downloader regression passes
[ ] Rapid operator/thinking profiles resolve correctly
[ ] legacy vllm and mlx_lm behavior remains intact
[ ] csl consumes shared profile data
[ ] dispatcher consumes profile and API-model identity
[ ] safe reuse compares material profile identity
[ ] session schema migration is tested
[ ] README, CHANGELOG, manifest, and help match behavior
[ ] working tree and staged scope are fully understood
[ ] rollback launch is exercised
```

Additionally, **only if** standalone packaging ships in the same release: clean-install artifact test
passes; archive is deterministic; release manifest contains only approved files; installer avoids
silent dotfile mutation; published assets are immutable and checksummed.

### Do not confuse these with `0.15.0`

- **`0.13.3` launcher profile controls** are per-**launch** environment variables
  (`LA_CLAUDE_SETTINGS`, `LA_CLAUDE_TOOLS`, …). `0.15.0` runtime **profiles** are a resolver over
  declared identities in JSON. Same word, different layer. Shipping the former does not advance the
  latter.
- **`0.13.1`'s backend resolution** (`serve=mlx` → `LA_DEFAULT_MLX_BACKEND`, `LA_SERVE_DECLARED`,
  `la_serve_display`, `LA_MLX_BACKENDS`, `la_retired`) is the same *separation of declared from
  effective* at the smallest scale. Phase C should **absorb and extend** these names rather than
  build a parallel mechanism — see the waypoint for the full list.

---

## `0.16.0` — Backend lanes — oMLX

**Status: NOT STARTED.** User-flagged high priority 2026-09-06. Researched from primary sources the
same day.

| Fact | Value |
|---|---|
| Repo | `github.com/jundot/omlx`, Apache-2.0, homepage `omlx.ai` |
| Maintainer | a **single individual**, who states in his own release notes that PR volume exceeds his review capacity |
| Latest | **v0.6.4, 2026-08-29** |
| Install | macOS `.dmg` (ships precompiled Metal kernels, auto-update, `~/.omlx/bin/omlx` CLI shim) · Homebrew tap `jundot/omlx` · source `pip install -e .` (`OMLX_WITH_CUSTOM_KERNEL=1` needs full Xcode) |
| **Not** on PyPI | `pypi.org/pypi/omlx` → 404 |

### Why it earns a lane rather than a pin

- **It speaks Anthropic `/v1/messages`,** not just OpenAI — so it can serve a full local Claude Code
  session directly, the same way Rapid does. It also has explicit "Claude Code Optimization" (context
  scaling, SSE keep-alive).
- **Tiered hot(RAM) + cold(SSD) KV cache with prefix sharing and copy-on-write, persisting across
  server restarts.** This is worth investigating against the Auto Mode caching problem above: Rapid
  discards a found prefix on hybrid models (`non_trimmable=True`), and a different cache implementation
  may not.
- **First-class support for exactly our Wave 2/3 candidates:** Qwen3.8-Flash-Next (`qwen4_exp`, added
  in 0.6.3 with tool calls, continuous batching, prefix-cache preservation and Lightning MTP),
  GLM-5.3-Flash (`glm5_next`), DeepSeek-V4-Flash, Laguna. 0.6.4 added QSA prefill/decode acceleration.
- Multi-model serving with LRU eviction, pinning and per-model TTL; continuous batching; experimental
  ANE prefill and multi-Mac distributed inference.

### Correction to a premise this roadmap and the acquisition plan both carried

**oQ ≠ OptiQ.** They are two independent quantizers with confusingly similar names, and we had them
conflated:

- **oQ** ("oMLX Universal Dynamic Quantization") is oMLX's own scheme — data-driven mixed precision from
  a 600-sample calibration set, levels oQ2 through oQ8. The `e` suffix (`oQ4e`, `oQ6e`, `oQ8e`) is the
  GPTQ-enhanced variant. On-disk examples: `Qwen3.8-27B-oQ6`, `kat-v2.5-oq6e`, `kat-v2.5-oq8e`,
  `laguna-s2.1-oq4e-fast`.
- **OptiQ** is a separate tool (`mlx-optiq`) behind the ~30 `mlx-community/*-OptiQ-*` models. On-disk
  examples: `KAT-Coder-V2.5-Dev-OptiQ-4bit`, `gemma-4-31B-it-OptiQ-4bit`. **No oMLX↔OptiQ relationship
  was found in any primary source.**

**Consequence that removes a blocker:** oQ's own documentation states it *"produces standard mlx-lm
compatible models that work everywhere — oMLX, mlx-lm, and any app that supports MLX safetensors. No
custom loader required."* So **oQ artifacts do not require oMLX**, and adopting oMLX is a performance and
model-coverage decision, not a prerequisite for serving the oQ weights already on disk. The acquisition
plan's engine policy should be read accordingly.

### Constraints

Add as an **isolated optional** backend. Must not disturb Rapid-MLX dependencies and must never become
a silent default — `serve=` resolution stays explicit, exactly as `serve=vllm` and `serve=llama_cpp` do.
Test a non-speculative baseline before MTP / DSpark / DFlash. The single-maintainer bus factor is a
real risk for a load-bearing dependency and argues for keeping Rapid the default.

---

## Not release-gated — continuous programmes

These do **not** wait for a version number. They were previously implicit behind `0.14.0`, which is the
sequencing accident the [release split](#release-sequence--why-0140-was-split) corrects.

### Model acquisition, tournament, and retirement

**User-flagged high priority 2026-09-06:** *"deleting outdated models and acquiring their newer
counterparts is a priority."*

Specification: the acquisition plan (waypoint `local-model-acquisition`, pinned). **Start at its
Work Package 0 — a read-only reconciliation ending in an approval report.** The plan states explicitly
that it is not authorization to edit, install, download, delete, commit, push, tag, or release.

Waves are strictly gated; no later wave starts until the prior wave's disk, load, protocol, memory and
benchmark evidence is reviewed.

| Wave | Artifacts |
|---|---|
| 1 | Qwen3.6 35B-A3B 4-bit · **Nemotron 3.5 Lightning 4-bit** · Qwen3-Coder-Next 4-bit · Granite 4.2 30B Q4 |
| 2 | GPT-OSS 120B MXFP4-Q8 · Ternary Bonsai 27B MLX 2-bit · Qwen3.8 Flash-Next REAP-288 Q4 |
| 3 | Flash-Next full oQ2 MTP · Mistral Medium 3.5 Q4 (Q5 conditional) · GLM-5.3 AJ-IQ2 (IQ3 conditional) · DeepSeek V4 Flash 0731 hetero-v2 |

**Context claims corrected against exact selected `config.json`:** the earlier 1M-extension claims for
Qwen3.6, Nemotron 3.5, Qwen3-Coder-Next and both Flash-Next artifacts are **withdrawn** — those configs
declare 262,144. Ternary Bonsai's gap is closed at 262,144 via `/text_config/max_position_embeddings`;
reconcile the Rapid PSV's 7.9 GB planning estimate against the published 8.49 GB package **before**
download.

**Tournament** — bounded, and speed is a promotion criterion alongside quality. Tiers 8K / 32K / 100K
(200K / 300K / 1M only once qualified); one warm-up plus ≥3 measured runs; median, min, max and
variability; cold and warm kept separate; 512 measured output tokens; concurrency 1; fixed sampling.
Primary operational metric: **`time_to_accepted_result`**. Baseline with acceleration disabled first,
then the best qualified optimized profile separately — a pruned or modified checkpoint is a different
artifact, not an acceleration setting of the full one.

**Retirement.** Named supersession candidates, each requiring the full gate below:

- **Nemotron 3 Nano text variants → Nemotron 3.5 Lightning.** User's assessment 2026-09-06: the newer
  release supersedes them. Three quantizations are on disk (4-bit, 6-bit, 8-bit), acquired complete but
  never verified or qualified — so this is retiring *unqualified* weights, which is cheaper to justify
  than retiring a working incumbent, but still needs the replacement to be qualified first.
- **Dense Qwen3.6-27B → qualified Qwen3.8-27B.**
- **`devstral-24b-gguf` → Devstral Small 2 24B** (waypoint `priority-qualify-devstral`).
- Redundant quantizations, only after matched tests.

Deletion eligibility requires **all** of: verified replacement acquisition; stable preferred-runtime
load; parser/tool tests; controlled *and* real-session qualification; the replacement winning or
matching the incumbent's niche; no remaining aliases, profiles, manifests, sidecars, scripts, tests or
external dependencies; exact path/size/replacement evidence in a deletion report; and **explicit
separate user approval**. **Never delete merely because a newer family exists.** Retain distinct
lightweight, multimodal, reasoning, coding, extreme-context, TTS and depth-specialist niches unless
strict domination is proven.

Disk context: waypoint `decide-the-model-disk` (366 GB free against 1.0 TB committed) is the standing
pressure this programme relieves.

### K-Search

Un-deferred 2026-09-06. **Researched from primary sources the same day, and it is not what this
roadmap's previous one-word listing implied.**

K-Search is an **LLM-driven GPU-kernel generation system**, not a kernel library and not an
Apple-specific component. It maintains a co-evolving search tree of hypotheses about kernel bottlenecks
and iterates candidate kernels, calling frontier models through an OpenAI-compatible endpoint.

| Fact | Value |
|---|---|
| Repo | `github.com/caoshiyi/K-Search`, Apache-2.0 |
| Paper | arXiv:2602.19128 (Cao, Mao, Gonzalez, Stoica — Berkeley/Sky) |
| Reported gain | avg 2.10×, up to 14.3× on complex MoE kernels vs SOTA evolutionary search |
| Latest update | **last commit 2026-06-01. Zero releases, no versioning** — git clone only |
| MLX support added | **2026-04-20**, "Add MLX backend + Mamba selective scan task" |
| Install | `git clone`, then `uv pip install openai wandb` + `flashinfer-bench-ksearch` |

**Four things to know before committing effort:**

1. **It needs an LLM API key and consumes cloud tokens to run.** Kernel generation is the product; the
   frontier model is the engine. This is a *paid* optimization pass, which changes its cost profile
   entirely versus "install a faster kernel".
2. **Stated prerequisites say NVIDIA GPU (H100/B200 recommended).** MLX is an added task backend, not
   the primary design target. There is exactly one Apple-Silicon task: `k_search/tasks/mlx_mamba/`,
   targeting the **forward selective scan (SSM recurrence)** — which is why it generalizes across Mamba
   models rather than binding to one.
3. **The shipped workload shapes are Mamba-1-ish and will need re-parameterizing.** All six default
   workloads use `dstate=16, ngroups=1`. Nemotron-H uses `ssm_state_size=128, n_groups=8,
   mamba_head_dim=64`. A generated kernel tuned on the defaults is not tuned for our models.
4. **The "≥ ~20% of end-to-end latency" gate is ours, not K-Search's.** It appears nowhere in the repo
   or the paper. It is a locally authored decision rule and should be labelled as such — it is a good
   rule, but it carries no upstream authority.

The gate itself is unchanged: profile first, proceed only if the dominant op clears the threshold, then
validate recurrent-state numerics, test prefill/decode/chunking/cancellation/memory, and integrate
behind a fallback. Nemotron's custom architecture and reasoning files carry remote-code trust
implications and must be **reviewed before anything is loaded**.

**Nemotron 3.5 integration risk, confirmed from both configs:** 3.5 Lightning is still Mamba-2 hybrid
(`NemotronHForCausalLM` / `nemotron_h`, identical SSM hyperparameters to Nemotron 3 Nano), but it
expresses its hybrid pattern as a **`layers_block_type` list** over 52 layers
(`['mamba','moe','mamba','moe','mamba','attention','moe', …]`) instead of Nano's
`hybrid_override_pattern` string. **Any code keyed on `hybrid_override_pattern` will not see 3.5's
layout.** It also adds MTP and declares `max_position_embeddings=262144`. An MLX 4-bit build exists at
`mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit` (created 2026-08-11); no oQ or OptiQ build of
3.5 was found.

Waypoint: `nemotron-3-nano-granite-4-0-h`.

### Local-session UX and observability

A cluster with no previous roadmap presence, all tracked as waypoints and none needing an architecture
to land: the banner rendering inside the session rather than only before launch
(`banner-must-render-inside-the`); the watcher window stealing focus from the session
(`watcher-window-steals-focus`); local-only metrics Claude Code cannot show natively — live tok/s and a
local-identity indicator (`add-local-only-metrics-claude`); local sessions displaying `$0` and no cap
instead of a cloud budget segment (`local-sessions-must-show-0`); a recognizable transcript marker so
local sessions can be found later (`local-sessions-need-a`); live reasoning visibility
(`real-time-thinking-visibility`); Qwen thinking-block leakage (`qwen-thinking-block-leakage`); and the
thinking-model runaway heuristic (`thinking-model-runaway-fix-a`).

---

## Deliberately deferred

Not roadmap items. Recorded so they are not mistaken for oversights (§20). The `0.14.0`–`0.16.0`
sequence should build the architecture that makes them safe later, not attempt them:

removing `vllm-mlx` · qualifying **every** roster model · automatic Rapid upgrades · mutating the
stable Rapid environment in place · Rapid vision promotion · production MTP promotion · universal
hardware recommendations · Homebrew formula publication · PyPI packaging · a generated standalone
repository · a broad UI rewrite.

No single release may become several releases at once.

**Two items left this list on 2026-09-06:**

- **K-Search is no longer deferred**, and it is **not model-specific** — it optimizes the Mamba
  selective-scan kernel, so any Mamba-based model benefits. The Mamba surface is growing on both ends:
  **Nemotron 3.5 Lightning** and **Granite 4.2 30B Q4** both arrive in acquisition Wave 1, Granite 4.0
  H-Tiny is already on disk, and Granite is additionally the leading classifier-engine candidate for
  locally routed Auto Mode — so one kernel win compounds across three workstreams. It stays *gated*.
  See [K-Search](#k-search) for what it actually is, which is not what its previous one-word listing
  implied. Tracked by `nemotron-3-nano-granite-4-0-h`, whose title now badly understates its scope.
- **"Qualifying every roster model" is narrowed, not revived.** A *bounded* tournament with fixed tiers
  is specified and active (see below). Universal qualification stays deferred. Bounded ≠ universal, and
  the deferral was previously being read as forbidding both.

---

## Known open items not owned by a release above

Tracked as waypoints; listed here so the repo is not silent about them.

- **Rapid-MLX `0.13.2` is installed side-by-side but not promoted.** `LA_RAPID_BIN` stays pinned to
  the qualified `0.12.18`. Promotion needs a serve-level smoke test (including a warm-vs-cold TTFT
  check and an explicit concurrency check), and `0.12.18` is retained for 7 successful days after.
  Note `0.13.2` moves `transformers` 5.12.1→5.15.1 and `mlx` 0.31.2→0.32.2, and **`mlx` is the layer
  the Metal-ceiling evidence measures** — so recorded Metal figures must be re-measured, not carried
  over. Waypoint: `promote-rapid-mlx-0-13-2-to`.
- **Non-Qwen models default to Rapid without Rapid evidence.** `0.13.1` moved them to the default
  because that is what a default means; only the Qwen3.6/3.8 aliases are runtime-qualified there.
  Rapid's parser vocabulary does cover them, so this is a qualification gap, not a known
  incompatibility. Kimi-VL stays pinned to `vllm` deliberately. Waypoint:
  `non-qwen-models-now-default`.
- **The Metal ceiling bounds concurrency, not just context — and the default is now 2, not 1.**
  `--max-num-seqs` was 1 because one long-context session already measured 99.9 GB against a
  103.9 GB limit. Locally routed Auto Mode needs a second slot or its classifier queues and times
  out, so `LA_RAPID_MAX_NUM_SEQS` now defaults to `2`. **That raises the default without retiring the
  evidence problem**, and as of 2026-09-06 the stated justification is also **disproven**. It read: *"a
  classifier request is small and short-lived (measured 35,154 prompt tokens, 8 output tokens,
  `max_tokens=64`)"*. Both halves fail. 35,154 tokens was the **first** classifier call of a session;
  the same session reached 75k, because the classifier prompt is the whole transcript. And the
  classifier **never queued**: every classifier `[schedule]` line read `running=1 waiting=0` (651 of 657
  samples), so the second slot relieved a constraint that was not binding. The ceiling was still never
  re-measured for two full-length concurrent sequences, two long sequences remain unqualified, and
  `la-ram-preflight.sh`'s Rapid formula still models a single sequence. Worse, the wired-memory guard in
  `launch-local-auto-mode.sh` that was supposed to bound this is **dead code** — `ps -o wired=` is not a
  valid macOS keyword, so it always evaluates 0 and never fires. Whether `2` remains the right default
  should be re-decided on the real cause, not on this bullet. Waypoints: `rapid-cache-profiles-the`,
  `auto-mode-local-inference`.
- **`tests/test_rapid_backend.sh` leaked its stub servers** — fixed in `0.13.5`; see `CHANGELOG.md`
  for why the leak was worse than untidy.
