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

`0.13.7`. See `CHANGELOG.md`.

> Keeping this line correct is the smallest possible test of whether this file is being maintained.
> If it disagrees with `.claude-plugin/plugin.json`, treat everything below as suspect too.

Versions `0.13.1`–`0.13.5` consolidated four outstanding feature branches into `main` on 2026-09-01,
so `0.14.0` Phase A reconciles one base rather than five divergent branches. `0.13.6` then applied a
skill fix on top — and correctly declined to take `0.14.0` for it, which is this file working.

`0.13.x` is deliberately being used for feature work that would conventionally earn a minor bump.
**The version number is the release gate for `0.14.0`:** that number is reserved for the runtime
profiles architecture and must not be spent on anything else, because a premature `0.14.0` would
make the gate list below unverifiable — a released `0.14.0` that meets only half its gates cannot be
un-released. Patch-level bumps below it are the cost of keeping that guarantee.

`main` currently carries **unreleased** work past the `0.13.7` tag: the per-model auto-compaction
profiles described under `[Unreleased]` in `CHANGELOG.md`, joined by **locally routed Auto Mode** from
`feat/auto-mode-classifier-localhost-routing` (verified 2026-09-05, documented in the same
`[Unreleased]` section). That is landed code awaiting a release
number, not specification — so it lives in the changelog, and only the sections below are specs.

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

**What this does NOT do.** It discharges no `0.14.0` release gate, promotes no roster-wide default,
and is not a controlled benchmark. It is a proof of concept, and the remaining work is largely the
`0.14.0` programme below — which is why the merge changes direction without changing status.

Cross-references: waypoint `local-model-context-catalogue` owns the per-model context fields this
evidence feeds (`advertised` / `runtime_supported` / `tested_safe` / `auto_compact_window`, each with
evidence and a test date); `local-compaction-and-metal` owns the compaction-and-Metal qualification
that must still be run per promoted profile.

---

## `0.14.0` — Runtime profiles and Rapid-first model management

**Status: NOT STARTED.** No `0.14.0` gate is implemented. Nothing in `0.13.1`–`0.13.6` advances one.

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

### Do not confuse these with `0.14.0`

- **`0.13.3` launcher profile controls** are per-**launch** environment variables
  (`LA_CLAUDE_SETTINGS`, `LA_CLAUDE_TOOLS`, …). `0.14.0` runtime **profiles** are a resolver over
  declared identities in JSON. Same word, different layer. Shipping the former does not advance the
  latter.
- **`0.13.1`'s backend resolution** (`serve=mlx` → `LA_DEFAULT_MLX_BACKEND`, `LA_SERVE_DECLARED`,
  `la_serve_display`, `LA_MLX_BACKENDS`, `la_retired`) is the same *separation of declared from
  effective* at the smallest scale. Phase C should **absorb and extend** these names rather than
  build a parallel mechanism — see the waypoint for the full list.

---

## Deliberately deferred

Not roadmap items. Recorded so they are not mistaken for oversights (§20). `0.14.0` should build the
architecture that makes them safe later, not attempt them:

removing `vllm-mlx` · qualifying every roster model · automatic Rapid upgrades · mutating the stable
Rapid environment in place · Rapid vision promotion · production MTP promotion · K-Search ·
universal hardware recommendations · Homebrew formula publication · PyPI packaging · a generated
standalone repository · a broad UI rewrite.

`0.14.0` must not become several releases at once.

---

## Known open items outside `0.14.0`

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
  evidence problem**, which is the part not to lose: the justification is that a classifier request is
  small and short-lived (measured 35,154 prompt tokens, 8 output tokens, `max_tokens=64`), not that
  the ceiling was re-measured for two full-length concurrent sequences — it was not. Two long
  sequences remain unqualified, `launch-local-auto-mode.sh` still guards with a wired-memory check
  before forcing the second slot, and `la-ram-preflight.sh`'s Rapid formula still models a single
  sequence. Waypoint: `rapid-cache-profiles-the`.
- **`tests/test_rapid_backend.sh` leaked its stub servers** — fixed in `0.13.5`; see `CHANGELOG.md`
  for why the leak was worse than untidy.
