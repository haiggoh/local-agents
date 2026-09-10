# Changelog

All notable changes to `local-agents` are documented in this file.

The project began using Git tags after development was already underway and did not tag every later release consistently. Historical entries through `0.12.0` were reconstructed from the complete public Git commit history, full commit messages, plugin-manifest version transitions, README history, and available tags.

Where no Git tag exists, the release heading links directly to its release commit. Component versions—such as the terminal `local-agent-dispatch` version—remain independent unless explicitly identified as the plugin release version.

## [Unreleased]

Awaiting a release number on branch `fix/omlx-classifier-prewarm`: the Auto Mode
local-classifier readiness work. Not released because no live Claude Code smoke
test has confirmed either backend's classifier route yet — startup success alone
is not qualification.

### Added

- `install/manage-rapid-mlx.py`, a repository-owned Rapid runtime manager with PyPI release discovery, interactive version selection, exact upgrades/downgrades, side-by-side reproducible venvs, private dependency-lock receipts, non-serving CLI smoke inspection, transactional active-pin promotion, guarded retirement, and `--dry-run`/`--help` support. Installation promotes active pins by default; `--skip-pin-update` keeps installation separate when required. Covered by `tests/test_manage_rapid_mlx.py` and documented in `docs/RAPID_RUNTIME_MANAGER.md`.

- Auto Mode classifier readiness gate for local sessions. A private fixture
  engine captures a genuine classifier request, measures cache readiness, and
  every launch replays it before the session opens, so a local Auto Mode session
  cannot start with a classifier that will fail on first use. Fixtures refresh
  weekly, on Claude/backend/profile identity change, or after a detected
  failure. Startup progress is reported transparently instead of appearing to
  hang, and capture diagnostics are sanitized before they are recorded.
- An opt-in Rapid-MLX Auto Mode launcher, deliberately NOT the default route.
  One qualified engine carries both compatibility identities natively: the
  relative model path stays the classifier identity while `--served-model-name`
  exposes the session identity — no proxy and no persistent user alias. It keeps
  its own cache and fixture roots, isolated from generic Rapid sessions and from
  oMLX, behind `LA_RAPID_AUTO_*`.

- Role names are now accepted wherever a model alias is, via `la_resolve_target`
  in `config/config-lib.sh`. `launch-claude-agent.sh operator`,
  `local-llm-hotswap.sh reasoner` and `local-agent-dispatch.py --model validator`
  resolve to whichever model fills that role **on disk right now**. An alias still
  wins over a role, so no existing invocation changes behaviour. Covered by
  `tests/test_role_resolution.sh` (9 assertions, mutation-tested 3/3 including a
  planted off-disk binding, without which the on-disk filter was undetectable).
- `tests/test_setup_shortcuts.sh` — regression coverage for the alias installer
  (19 assertions, mutation-tested 5/5). It exists because this release's own
  rewrite briefly removed the installer's write steps while it still printed
  `✓ local-* aliases written` and exited 0, creating no file at all.

### Changed

- The readiness gate is backend-neutral. The historical `LA_OMLX_*` names remain
  the public compatibility surface, and the backend is recorded in the prewarm
  profile so a fixture cannot be replayed across backends.
- The `local-*` shell aliases name ROLES instead of hardcoded models. The old
  block pinned `qwen-3.6-*` while the roster had moved on, so the aliases kept
  succeeding on a stale model with no signal. Retired the nine per-model
  `local-agent-*` dispatch aliases and the `agy-local` compat alias in favour of
  one `local-dispatch` taking `--model <role|alias>`; added `local-validator`,
  `local-roles` and `local-disk`. `local-logs` now matches the `rapid_auto_*` and
  `omlx_*` logs the current backends actually write, not only `vllm_*`.

## [0.13.10] — 2026-09-08

### Fixed

- Stop the companion watcher window stealing keyboard focus from the local
  session. `local-watch.sh --open` used `activate`, which brought Terminal
  forward, so the window you type into lost focus and had to be clicked back.
  `do script` creates its window without it. Focus restoration is window-level
  rather than app-level because the session is normally another Terminal
  window, and is guarded for the case where no window exists yet.
- Collapse repeating watcher output. Watcher windows now pipe engine health
  through `bin/la-watch-filter.awk`, which strips the constant
  `INFO:module.path:` logger prefix, prints the per-request banner once — the
  model, `max_tokens` and stream flag are fixed for a session — and collapses
  consecutive near-identical lines into one line plus a repeat count, matching
  with digits masked so counters and timings still compare equal.
  `--diagnostic` bypasses the filter, so the raw stream stays raw.

## [0.13.9] — 2026-09-06

### Added

- Enable Claude Code's segmented Auto Mode transcript representation for
  local Auto Mode sessions, with a one-launch opt-out. This gives inference
  backends stable, message-aligned classifier-history boundaries.
- Add an oMLX Auto Mode backend that serves the selected local session model
  as `claude-opus-5` and a separate dense classifier as
  `claude-sonnet-5` on one isolated Anthropic-compatible endpoint.
- Add persistent oMLX paged SSD caching with an in-memory hot cache and
  write-through durability.

### Fixed

- Fix the released `0.13.8` Auto Mode path timing out as classifier history
  grew. The original second-slot explanation was not the binding issue:
  measured classifier requests were already admitted with
  `running=1 waiting=0`; repeated full-prefix prefill crossed Claude Code's
  classifier deadline.
- Isolate each local-agents oMLX server with a private `--base-path` and
  disable unrelated Hugging Face cache discovery. This prevents a session
  launch from rewriting or being respawned by the managed Homebrew oMLX
  service.
- Resolve the session model through `LA_CUR_DIR`, the actual registry
  contract, rather than the nonexistent `LA_CUR_SUBDIR`.

### Validated

- Synthetic growing-prefix acceptance reused 12,544 of 13,856 tokens and
  13,824 of 15,004 tokens. Latency fell from 75.8 seconds cold to 9.7 and
  8.6 seconds.
- A real lean local Claude Code session launched with Ornith as
  `claude-opus-5`, the dense DeepSeek classifier as `claude-sonnet-5`,
  segmented transcript mode enabled, and Auto Mode on. A consequential Bash
  action completed successfully through the local oMLX endpoint.
- Rapid remains available as an immediate rollback through
  `LA_AUTO_MODE_RUNTIME=rapid`.

## [0.13.8] — 2026-09-05

Merged `feat/auto-mode-classifier-localhost-routing` into `main` (fast-forward, so the history is
linear and every commit is attributable).

### Added

- **Auto Mode with its safety classifier routed to the local backend.** Claude Code judges each
  consequential tool call with a *separate* classifier, independent of the session model, so on a
  cloud-routed session a rate-limit or an exhausted budget took Auto Mode away precisely when local
  work had become the fallback. A local session already points `ANTHROPIC_BASE_URL` at its own
  server, so the classifier request follows it: `bin/launch-local-auto-mode.sh` warms a server that
  has a slot free for it and launches into `--permission-mode auto`, and `launch-claude-agent.sh`
  honours `LA_AUTO_MODE=1` for the same effect on an ordinary launch.

  Verified end-to-end on 2026-09-05: the local server logged
  `request model='claude-sonnet-5' served by loaded engine='claude-opus-5'` — the classifier's own
  model identity, answered by the loaded local engine — while the session held no connection to the
  cloud gateway, and the judged action then executed. Routing is proven; **verdict quality is not**,
  and a local model is still not Anthropic's classifier.
- **A free concurrency slot for the classifier.** The classifier is a second, concurrent request:
  with `--max-num-seqs=1` it queues behind the turn that triggered it and times out, which surfaces
  as a fail-closed `temporarily unavailable` refusal. `LA_RAPID_MAX_NUM_SEQS` therefore defaults to
  `2`, and enabling auto mode sets `LA_HOTSWAP_FORCE_FRESH=1` so a server left over from a
  single-slot launch is restarted rather than reused.
- **Nonessential outbound traffic is off by default for local sessions.** `LA_TELEMETRY=0` (the
  launcher default, toggled with `t` in `csl` or `CSL_TELEMETRY=1`) exports
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` and
  `DISABLE_AUTOUPDATER`, and the session prints `🔇 Telemetry: OFF` at startup.

  The reason it is a default rather than an option: routing inference locally does not stop the CLI
  talking to the internet. Measured — a session whose every request provably went to `127.0.0.1`
  still held outbound sockets to Anthropic (`160.79.104.10`) and Google/Statsig (`34.149.66.165`),
  neither of which is inference or the gateway, so neither appears in a cost or routing check.
  Verified by outcome: zero non-loopback sockets after a real turn, against two before, with a
  control cloud session still showing three so the check demonstrably still detects them.

  Scope is deliberately limited to Claude Code's own traffic — hooks the *user* has configured still
  run, in separate processes. Trade-off: the umbrella also disables `/design-sync`, Projects and the
  CLI update check, all irrelevant to a local session.
- **`bin/launch-local-auto-mode.sh`** — the standalone auto-mode harness: it warms a server that has
  a slot free for the classifier, launches straight into `--permission-mode auto`, and hands the
  session a first action chosen to exercise the classifier, so a run either proves local routing or
  fails closed. Opt-in via `JOYIA_LOCAL_AUTO_CLASSIFIER=1`; the `csl` toggle covers everyday use.
- `tests/test_csl_menu.sh` sections 5–9, covering the auto-mode default, the `CSL_AUTO_MODE=0`
  opt-out, the telemetry default and its `CSL_TELEMETRY=1` opt-in, both `a`/`t` toggles, and in every
  case the value the launcher actually receives rather than the menu text that describes it.
- **Per-model auto-compaction profiles for local sessions.** `config-lib.sh` gained the optional
  associative array `LA_SESSION_AUTO_COMPACT`, keyed by model alias, and `csl` applies the selected
  model's value by exporting `LA_AUTO_COMPACT_WINDOW` into the launcher it execs. The export is
  deliberately confined to that child process, so it can neither propagate back into the parent
  shell nor reach an independently launched cloud session — a local context policy must never
  become a global Claude Code setting.
- `tests/test_session_profiles.sh` covering the override.

### Changed

- **`csl` now launches with auto mode ON by default** (`a` toggles it, `CSL_AUTO_MODE=0` opts out).
  The default flipped only once local classifier routing was actually verified: the reason to prefer
  it is that the classifier now costs nothing and cannot be withdrawn by a cloud 429, which is the
  whole point of a local session. Two consequences are documented rather than hidden — a judged call
  pays one extra local request (measured 35,154 prompt tokens for an 8-token verdict, 27.4 s cold),
  and calls already covered by a `permissions.allow` rule or by a read-only tool are never judged at
  all, so "nothing happened" must not be read as "the classifier ran and approved it".
- **Documentation caught up with the behaviour.** The README previously stated the opposite in three
  places — that local sessions force `acceptEdits`, that the local model "can't serve that call", and
  that classifier routing was unsolved. Those passages now describe locally routed Auto Mode, with
  its evidence and its limits, and `bin/launch-local-auto-mode.sh` is listed in the inventory instead
  of being undocumented.
- `bin/local-llm-hotswap.sh` and `config/config-lib.sh` support the classifier's second
  concurrency slot: `LA_RAPID_MAX_NUM_SEQS` defaults to `2`, and enabling auto mode sets
  `LA_HOTSWAP_FORCE_FRESH=1` so a server left over from a single-slot launch is restarted rather
  than reused.
- **Argument passthrough now receives the same profile as an interactive choice.** `csl <alias>`
  previously `exec`ed the launcher *before* the config was loaded, so a model selected by argument
  silently got no profile while the same model chosen from the numbered menu got one. Passthrough
  still skips the picker and the watcher; it no longer skips the profile.

### Fixed

- **`tests/test_rapid_backend.sh`: three warmup assertions that had never passed, and a regressed
  stub-server leak.** All three failures were faults in the harness, not the shipped script — the
  worst kind, because they read as a warmup regression in `local-llm-hotswap.sh`. The stub never
  wrote its warmup log: it is generated from a correctly *quoted* heredoc (its body is Python), but
  one line inside read `WARMUP_LOG="$SB/..."`, so the file received the literal characters `$SB`;
  `open()` raised, `do_POST` died before answering, and the probe read an empty reply and reported
  `finish_reason=?`. The skip test asked for a skip nobody reads (`HOTSWAP_PREFLIGHT=0`, while the
  code reads `LA_HOTSWAP_PREFLIGHT` — a wrong env-var name fails **open**, silently). And that
  section could not start at all: it inherited the 8100–8102 range with every port already held by
  an earlier test, so its hand-started stub died with *Address already in use*; it now has its own
  8103–8105 range, and its stub binary is no longer copied one level too deep by
  `cp -R src/.stub dst/.stub`, which nests when the destination already exists.

  The stub leak that `0.13.5` records as fixed had **regressed**: a later section did
  `STUB_PIDS="$!"` — a scalar assignment that discarded every pid the array held — and installed a
  second `EXIT` trap that dropped the `reap_stale_stubs` sweep. `cleanup()` is now the only `EXIT`
  trap, and the reaper matches *both* sandbox markers; matching only `la-rapid-test` had left the
  warmup-skip sandbox's stub listening on 8103 after every run, swept by port but skipped by marker.

  38 passed / 0 failed, verified twice consecutively with no listener left on 8100–8105.
  Mutation-tested against the product rather than merely re-run: breaking `_preflight_warmup` fails
  two assertions, breaking its skip guard fails one.

### Runtime direction — Ornith is no longer an experiment

The branch that produced the work above was named `experiment/ornith-200k-autocompact`. It has been
merged deliberately, because the experiment succeeded and the question it was asking is settled:

- **Ornith is markedly faster than Qwen 3.8** in real interactive use, which makes it uniquely
  suited to driving a *full* local session rather than only stateless dispatch.
- **The 200K+ context window is confirmed in the model's own documentation**, and a practical test
  showed it stays stable well past 100K tokens **with no auto-compaction at all**. That is the
  finding that matters, because it contradicts the older working assumption behind a 100K local
  threshold — prior local failures had clustered near 103K–105K, and 100K was only ever a fallback
  guess, never a measured property of every model.
- Consequently Ornith is treated as the intended direction for local sessions, not a candidate
  under evaluation.

This is a **proof of concept, not a finished migration.** Substantial work remains, most of it
already specified as part of `0.14.0`; see [`docs/ROADMAP.md`](docs/ROADMAP.md). Nothing here
promotes a roster-wide default or discharges any `0.14.0` release gate.

## [0.13.7] — 2026-09-01

### Changed

- **`csl` now lists every on-disk, session-capable model in its primary
  numbered menu**, rather than hiding the full roster behind free composition.
- Model rows show resolved backend, thinking mode, configured effort, and role
  metadata. Numbered selections use the configured effort; `c` remains the
  custom-effort path.
- The watcher now defaults off. It can still be toggled with `w`, or enabled
  initially with `CSL_WATCH=1`.
- Added an isolated deterministic menu test covering availability filtering,
  default-effort launching, custom effort, and watcher opt-in.
- Added the pinned non-thinking `ornith-1.5-35b` registration to the public
  example configuration and documented its download and launch workflow.
- Non-thinking Ornith is now the recommended full local-session model based on
  successful real Claude Code use and the best interactive performance observed
  so far, including noticeably better responsiveness than Qwen 3.8.
- This is explicitly early operational evidence, not a controlled benchmark.
  Ornith thinking remains untested and is not publicly registered or
  recommended.

### Validated

- CSL menu tests: **16 passed**.
- Backend resolution and launch-safety tests: **39 passed**.
- Rapid backend tests: **29 passed**.
- ShellCheck passed.
- The public example resolves Ornith to Rapid-MLX, thinking off, the expected
  Hugging Face repository, and the exact pinned revision.
- A live private-roster check confirmed the newly acquired qualification
  aliases remain directly visible and the watcher defaults off.

## [0.13.6] — 2026-09-01

### Fixed

- **`skills/offload-to-local`: the two cloud-escape reasons were jointly exhaustive**, so a plan could
  satisfy the rule while never offloading anything — compliant on paper, useless in practice. Measured
  instance: four delegatable steps, four `cloud:` annotations, zero local dispatches, every call
  individually defensible. The pattern is invisible per step and only appears in the aggregate.
  Three repairs: a POSITIVE test for what qualifies (a self-contained transformation over many similar
  inputs whose output is checkable against the source, with a measured worked example), "too hard to
  delegate" reframed as a SPEC gap that splits into `cloud:spec` + `local:` slices rather than an
  unfalsifiable verdict, and the requirement that a cloud reason be checkable and name its expiry —
  with the DISTRIBUTION being what to watch, so a plan with zero local steps owes an explicit sentence
  at plan level. Also: decide before READING the inputs, since opening the files to judge delegation
  already spends the expensive part.
- Deliberately versioned `0.13.6`, **not** `0.14.0` — that number belongs to the runtime-profiles
  architecture, and `docs/ROADMAP.md` (added one version earlier) is what made that boundary explicit
  enough to hold.

## [0.13.5] — 2026-09-01

Release hygiene. No behaviour change to any backend or launcher.

### Added

- **`docs/ROADMAP.md`** — what is specced but not shipped. `0.13.0`'s changelog claimed to add
  "changelog and roadmap documentation" and only the changelog appeared, so the entire `0.14.0`
  specification lived in a plan file on one machine while `[Unreleased]` sat literally empty. "Did we
  skip a specced feature?" was not answerable from the repo. It now is: every `0.14.0` phase,
  identity layer, release gate and explicit non-goal is listed with status, and an item can only
  leave the file by appearing in this changelog under a real version, or by moving to a deferred
  list with a stated reason.
- The roadmap also records why `0.13.x` is being used for work that would conventionally earn a
  minor bump: **the version number is the release gate for `0.14.0`.** A released `0.14.0` meeting
  half its gates cannot be un-released.

### Fixed

- **`tests/test_rapid_backend.sh` no longer leaks its stub servers**, and now sweeps stubs left by an
  earlier run at startup as well as in the EXIT trap. The trap alone was insufficient because hotswap
  launches stubs with `nohup`, so they outlive the shell that recorded their pids.
  This was worse than untidiness: a leaked stub keeps LISTENing on 8100, so the next run lands on
  8101 and `SUCCESS_PORT=8100` fails along with every argv assertion after it. Measured **19 passed /
  10 failed with nothing wrong in the code under test**, then 29/0 immediately after reaping — it
  bit three times while consolidating `0.13.1`–`0.13.4`. A genuine regression and self-contamination
  were indistinguishable, which is the failure mode that gets a correct change reverted.
  Matching is on the sandbox marker in the process command line, never on the port alone, so the
  sweep can never touch a live local session on 8000-8010. Verified idempotent: three consecutive
  runs, 29/29 each, zero leaked listeners after every one.

## [0.13.4] — 2026-09-01

### Added

- `install/download-models-system-trust.sh` — optional wrapper that runs `install/download-models.sh`
  against a Hugging Face client built to use the **native operating-system trust store** instead of
  `certifi`. This is the corporate-TLS path: on a network with an inspecting proxy, a bundled CA set
  fails while the system store succeeds. Overridable with `LA_HF_SYSTEM_TRUST_CLI`, defaulting to
  `~/.local/hf-system-trust/bin/hf`.
- It **fails closed** rather than silently falling back to the ordinary client: it verifies the
  downloader and the client are both executable, that the client is actually named `hf`, and that
  `command -v hf` resolves to exactly the intended absolute path after the `PATH` prepend. A wrapper
  that quietly used the wrong client would produce a TLS failure that looks like a network fault.
- Also exports `LA_HF_CLI` for forward compatibility with a future downloader that takes the client
  directly rather than through `PATH`.

## [0.13.3] — 2026-09-01

Per-launch Claude Code controls for full local sessions, and the model-facing session prompt
moved out of the launcher into a versioned template.

### Added

- Add validated per-launch Claude Code controls for full local sessions:
  `LA_CLAUDE_SETTINGS`, `LA_CLAUDE_TOOLS`, `LA_AUTO_COMPACT_WINDOW`, and
  `LA_AGENT_PROMPT_FILE`.
- Add `config/local-agent-system-prompt.txt` as a versioned, model-facing local-session prompt
  template with runtime placeholder substitution.
- Add focused launcher-profile tests covering the new controls, argument quoting, prompt
  placeholders, prompt-size bounds, and allowed/denied tool conflict protection.

### Changed

- Move the local identity, tool-use, zero-gateway-cost, and runtime self-preservation instructions
  out of `launch-claude-agent.sh` and into the external prompt template.
- Validate settings JSON, tool-list syntax, auto-compaction bounds, prompt readability, and
  unresolved prompt placeholders before launching Claude Code.
- Preserve launcher-owned invariants—direct localhost routing, compatibility model identity,
  `acceptEdits`, RAM preflight, server lifecycle, and strict-MCP behavior—rather than forwarding
  arbitrary Claude Code arguments.
- Fail closed when the same tool appears in both `LA_CLAUDE_TOOLS` and `LA_DENY_TOOLS`.

### Validated experimentally

- Claude Code 2.1.246 running Qwen3.8 27B 4-bit through Rapid-MLX accepted a per-launch settings
  overlay, an explicit eight-tool profile, strict MCP exclusion, and a 100K auto-compaction window.
- The interactive acceptance test completed native `Glob`, `Write`, `Read`, `Grep`, `Edit`, and
  `Bash` operations, preserved native transcript/resume behavior, removed its disposable test
  artifact, and exited cleanly without changing the implementation worktree.
- The lean profile began at approximately 24K context with 3.4K system-tool tokens, compared with
  approximately 28.4K context and 6.7K system-tool tokens in the earlier broader local baseline.
  This is an operational comparison, not a controlled performance benchmark.

### Known limitations

- Local sessions still use `acceptEdits`; the Auto Mode classifier path for spoofed local models
  remains unresolved.
- Exposing the `Agent` tool does not by itself repair local Auto Mode classifier routing.
- Claude Code and the current status-line renderer still display the compatibility model identity,
  a fictional cloud-price estimate, and a percentage derived from the spoofed model window rather
  than the effective local auto-compaction policy.
- The detached transcript-correlation helper can outlive the Claude client until its polling
  deadline. Lifecycle cleanup for that helper remains separate follow-up work.

## [0.13.2] — 2026-09-01

### Added — machine-local scripts adopted into the plugin

Four helpers that had been living in `~/.claude/scripts` on a single machine now ship with the
plugin. Each was checked for universality first: no hardcoded user paths, no dependency on this
machine's gateway or corporate tooling. These were authored deliberately WITHOUT a version bump, to
fold into the next release rather than ship alone — this is that release.

- `bin/local-inference-readonly-inventory.zsh` — offline, read-only snapshot of the whole stack,
  written to one timestamped report directory. Complements `bin/la-disk-inventory.sh` (disk →
  registry accounting) rather than duplicating it.
- `bin/model-asset-override.sh` — symlink-farm view of a model directory, to add or shadow a single
  non-weight asset without copying the weights.
- `install/local-stack-update-check.sh` — notify-only weekly check, now covering **two**
  environments: the legacy `~/.local-llm` lane (`mlx-vlm`, `mlx-lm`) and the newest
  `~/.venvs/rapid-mlx-*` (`rapid-mlx`, `mlx`, `mlx-lm`). Rapid became the default backend in
  `0.13.1` while being watched by nothing at all, which is the actual reason "who owns the venv
  update schedule" kept coming up. `mlx` is included on purpose: it is the Metal layer the
  memory-ceiling evidence is measured on, and the one dependency Homebrew's `rapid-mlx` formula
  declines to pin — which is why the pinned venv exists. Newest env is chosen by `sort -V`, since a
  lexical sort ranks `0.9.14` above `0.13.2`. Both log branches print the CHECKED set, so a silently
  skipped environment can no longer read like one that passed. Upgrades stay manual: the legacy venv
  is shared, the `vllm-mlx` fork carries local patches, and the Rapid envs are pinned on purpose.
- `install/hf-ipv4/sitecustomize.py` — the IPv4 shim that `install/download-models.sh` and the README
  troubleshooting section **already told you to use**, but which shipped nowhere. The README now
  gives the exact `PYTHONPATH` invocation.

## [0.13.1] — 2026-08-31

Rapid-MLX becomes the DEFAULT backend for MLX model launches. `0.13.0` made it *available*; this
makes it what a registration gets when it does not ask for anything specific. llama.cpp remains the
backend for GGUF artifacts, and vllm-mlx remains fully supported as an explicit pin.

### Changed — DEFAULT BACKEND FLIP (read this before debugging a backend surprise)

- The `serve` field gains a **generic** value, `mlx` (an empty field means the same), which resolves
  to `LA_DEFAULT_MLX_BACKEND` — **now `rapid`**. Registrations that named `vllm` only because it was
  the incumbent were migrated to `mlx`; nothing about the vllm code path changed.
- **Rollback is one line:** `LA_DEFAULT_MLX_BACKEND=vllm` in `config.local.sh`. Every generic
  registration reverts; every explicit pin is unaffected in either direction, which is what keeps
  per-backend measurements attributable to the backend they were taken on.
- **The concurrency caps became config knobs, at unchanged values.** `--max-num-seqs` and
  `--max-concurrent-requests` were hardcoded `1`/`2` in `0.13.0`; they are now
  `LA_RAPID_MAX_NUM_SEQS` / `LA_RAPID_MAX_CONCURRENT_REQUESTS` with **the same defaults**, so the
  value is discoverable and testable without editing the script. **Behaviour is unchanged.** They
  are 1/2 on purpose: Rapid does schedule continuously (its own default is 256), but the binding
  constraint here is Metal memory — one long-context session measured 99.9 GB at 103,020 prompt
  tokens against a 103.9 GB limit, with seven `SIGABRT`s in ~22h — so each extra in-flight sequence
  multiplies the thing already saturating. Raising them is gated on the Metal-ceiling work, not on
  preference.
- `LA_RAPID_BIN` is now **discovered** when unset: brew → `PATH` → newest `~/.venvs/rapid-mlx-*`
  (version-ordered, so `0.13.2` outranks `0.12.18` and `0.9.14`). Setting it explicitly still wins
  and remains the recommended posture for a qualified version.
- The four `qwen-3.x-rapid-*` qualification aliases are **retired** — the base aliases now *are*
  Rapid, and keeping them would register a duplicate (subdir, backend, spoof) triple that makes
  server-reuse matching ambiguous. `qwen-3.6-vllm-operator` / `-thinking` were added as explicit
  legacy pins so the vllm lane stays reachable.
- Kimi-VL registrations stay **pinned to `vllm`**: the viable-but-degraded MLLM verdict on record is
  an audit of vllm-mlx's route specifically, and moving them would silently reassign that evidence
  to a backend it was never taken on.

### Added

- `la_retired` / `la_retired_hint`: a retired alias now prints where it went instead of dead-ending
  on "unknown alias", and retirements are listed in the aliases help — which is where the error
  sends you.
- `llama_cpp` is a recognised `serve` value. hotswap **refuses** it with instructions (exit 3)
  rather than falling through to the vllm branch and dying at weight-load time on an artifact MLX
  cannot read. It is deliberately **not** reachable from a generic value, so flipping the MLX
  default can never reroute a GGUF model.
- The loader warns when a GGUF-looking artifact resolves to an MLX backend, naming the alias and the
  fix.
- Config errors now fail the loader instead of being absorbed: an unknown `serve` value, and an
  `LA_DEFAULT_MLX_BACKEND` that is not an MLX backend.
- `la_serve_display`: every human-facing listing (aliases help, hotswap banner, session banner,
  session log) shows the resolved backend **with** the declaration it came from — `rapid
  (mlx->rapid)` for a generic value, bare `vllm` for a pin.
- `tests/test_serve_default.sh` — 39 assertions over the resolution layer, backend vocabulary,
  discovery order, the guards, and the two real scripts (`csl` filter, hotswap refusal). Every
  hotswap invocation is bounded (`HOTSWAP_READY_TIMEOUT=4`) so a mutated resolver fails in seconds
  instead of hanging the suite.
- `tests/test_rapid_backend.sh` gains assertions that the concurrency caps are passed explicitly
  rather than inherited (29 assertions, was 27).

### Validated experimentally

- `tests/test_serve_default.sh`: 39 pass, 0 fail. **Mutation-tested with 9 planted defects** (default
  flipped, pins treated as generic, GGUF warning removed, declaration dropped from the display,
  version sort downgraded to lexical, hotswap's llama_cpp gate removed, backend banner removed,
  invalid values silently accepted, retired-alias hint disabled) — all 9 detected, baseline restored
  clean.
- `tests/test_rapid_backend.sh`: 29 pass, 0 fail. ShellCheck-clean at `-S error` across every edited
  script.
- Every flag hotswap passes was verified present in **both** rapid-mlx `0.12.18` (the pinned,
  qualified version) and `0.13.2`, so the concurrency change is safe on the currently-serving build.

### Known limitations

- Rapid-MLX `0.13.2` is installed **side by side** at `~/.venvs/rapid-mlx-0.13.2` and passes
  `pip check`, but `LA_RAPID_BIN` remains pinned to the qualified `0.12.18`. Promotion still needs a
  serve-level smoke test; it was not run because a live local session held port 8000 and the RAM
  headroom for a second 27B was thin. Retain `0.12.18` until `0.13.2` has 7 successful days.
- Moving a model to Rapid does not qualify it there. Only the Qwen3.6/3.8 aliases have Rapid
  runtime evidence; the rest resolve to Rapid as the sensible default but are unmeasured on it.
- **A dispatch aimed at a model that a local session is already using WAITS for that turn.** With
  `--max-num-seqs 1` one request runs and one queues; a third gets HTTP 503 + `Retry-After`. Rapid
  could batch instead, but not within this machine's measured Metal ceiling. The supported answer is
  a second server instance on another port — which hotswap does not currently offer, because it
  deliberately REUSES a healthy matching server. That opt-out is unbuilt.
- The RAM preflight's Rapid overhead formula (`6 GB + cache_mb/1024`) models a single sequence, so
  it would understate load if the concurrency caps were ever raised.


## [0.13.0] — 2026-08-25

### Added

- Add Rapid-MLX as a first-class `local-agents` backend.
- Make Rapid-MLX the preferred architecture for full local sessions.
- Retain patched `vllm-mlx` for compatibility, controlled A/B comparisons, unsupported models, and rollback.
- Add backend-aware server identity and safe reuse.
- Add Rapid-aware RAM preflight and cache accounting.
- Allow Rapid-backed aliases to launch through `csl`.
- Correct backend and thinking-state display in local-session banners.
- Add smoke tests for Rapid hotswap, reuse, and RAM preflight.
- Reposition full local Claude Code sessions as a major supported workflow complementary to local dispatch from cloud sessions.
- Add project-wide changelog and roadmap documentation.
- Add `la-evict.sh`, an emergency, one-server-at-a-time memory-recovery fallback for when the machine is already out of RAM and the terminal is unresponsive. It is deliberately standalone (no `config-lib.sh`, no registry) so it keeps working while the stack is sick.

### Validated experimentally

The following behavior has been observed on an Apple M4 Max with 128 GB unified memory. Release verification completed 2026-08-25: 224 tests pass with none failing (47 dispatch, 45 dispatch-state, 70 savings-ledger, 27 Rapid backend, 35 eviction), `tests/lint.sh` is ShellCheck-clean, and no cross-catalog alias, destination, or artifact-identity conflicts remain.

- Rapid-MLX `0.12.18` serving Qwen3.6 and Qwen3.8 through the existing Homebrew Claude Code client.
- Anthropic Messages, structured tools, tool-result continuation, streaming, cancellation, orphan cleanup, and immediate request reuse.
- Full Qwen3.8 local Claude Code sessions through `local-agents`.
- Hybrid-prefix reuse of approximately 27K prompt tokens.
- Warm follow-up turns completing in approximately 2–3 seconds with a measured 20 GB/eight-entry cache profile.
- Qwen3.8 oQ6, Qwen3.8 8-bit, matching 4-bit and 8-bit MTP sidecars, Nemotron Nano 4/6/8-bit, and Granite H-Tiny 6-bit acquired for later qualification.

### Known limitations

- The Rapid proof establishes bounded Qwen3.6 and Qwen3.8 text paths, not compatibility with the complete model roster.
- Rapid vision support requires a separately pinned and qualified environment.
- Visible reasoning leakage observed with Qwen3.6 persists with Qwen3.8.
- MTP sidecars are acquired but remain unqualified.
- **Total Metal memory is not bounded by `--cache-memory-mb`.** That flag caps the reusable prefix cache only; the KV/working set scales with context length and is not governed by it.
- **Long-context sessions can abort the server.** Measured on Qwen3.8 27B 4-bit at 128 GB: Metal high-water was 37.9 GB at 32,214 prompt tokens but 99.9 GB at 103,020, against a 103.9 GB allocation limit — roughly 0.6–0.8 GB of KV per 1,000 tokens. The practical wall is near 105K tokens and the safe operating ceiling near 80K; compact before then. Seven `SIGABRT` aborts were observed in about 22 hours of long-context use.
- **The measured 20 GB/eight-entry cache profile is not a safe default** and is deliberately not shipped. It produced roughly 2–3 second warm turns at shorter contexts, then reached about 107.9 GB Metal during a long-context run and aborted. Shipped defaults are 2,048 MB with two entries; the aggressive profile belongs in a private overlay.
- Reducing the cache does **not** move the wall: a two-entry/6 GB/fixed-256-step profile aborted identically at about 103K tokens with the cache empty.
- `ps rss` is not authoritative for MLX memory — it understated a server by roughly sevenfold. Inspect wired, Metal, and swap instead.

## [0.12.0] — 2026-08-22

Release commit: [`13bf844`](https://github.com/haiggoh/local-agents/commit/13bf844b6e3ef32530ef49d7c78a94cd7cd37dba)

### Added

- RAM preflight before loading local-model weights.
- A prominent local-session banner showing model, compatibility ID, effort, thinking state, port, and watcher command.
- `la-stream-render.py` for readable watcher output.
- Diagnostics that distinguish whether a model fits, which other servers are resident, and whether those servers are attached to live Claude Code sessions.

### Changed

- RAM checks stop as soon as the answer is known instead of inspecting every process unconditionally.
- The preflight reports possible idle-server reclamation or smaller alternatives but never terminates anything automatically.
- Watcher output renders reasoning as readable paragraphs and tool calls as concise lines; raw output remains available in diagnostic mode.

### Fixed

- Attachment detection now examines local Claude processes’ `ANTHROPIC_BASE_URL` instead of transient established TCP connections.
- Transcript correlation now identifies newly created transcript files rather than any transcript modified after launcher startup.
- Prevented a pre-existing active session from being selected as a newly launched session’s transcript.

### Safety

- Added `LA_SKIP_RAM_PREFLIGHT=1` as an explicit override.
- Addressed a real machine-freeze incident caused by loading another model without sufficient unified-memory headroom.

## [0.11.0] — 2026-08-22

Release commit: [`55f9ef0`](https://github.com/haiggoh/local-agents/commit/55f9ef00532b2254d043378abc8593773042c9d9)

### Added

- Revision-pinned, resumable model-download engine.
- Data-only public model catalog plus additive private catalogs.
- Selective file acquisition through include patterns.
- `.la-download-complete` markers.
- Acquisition states: `COMPLETE`, `PRESENT`, `METADATA`, and `ABSENT`.
- Disk preflight with configurable reserve and fitting-subset suggestions.
- `la-disk-inventory.sh` with orphan and no-payload detection.

### Changed

- Separated model-list data from downloader implementation.
- Deduplicated downloads by alias, destination, and exact artifact identity.
- Deduplicated catalog files by real path.
- Required a real weight payload for on-disk usability checks.
- Followed valid model symlink farms when checking weights.

### Safety

- Non-interactive downloads refuse to exceed the configured disk reserve.
- Metadata-only model directories are rejected before server startup.
- Private overlays under `config/*.local.*` are ignored automatically.

## [0.10.1] — 2026-08-19

Release commit: [`584bd0b`](https://github.com/haiggoh/local-agents/commit/584bd0b2562236db7ba2537860478da948b326a1)

### Fixed

- Disabled Claude Code’s separate streaming-idle watchdog for local sessions through `CLAUDE_ENABLE_STREAM_WATCHDOG=0`.
- Fixed local turns being aborted and retried after two silent five-minute prefill windows.
- Prevented long-context sessions from entering a cycle where each failed retry enlarged the next prompt.

### Safety

- Retained overall client and server request limits while disabling a watchdog that incorrectly treated multi-minute local prefill as a stalled stream.

## [0.10.0] — 2026-08-19

Release commit: [`2fe748b`](https://github.com/haiggoh/local-agents/commit/2fe748b62371eceb07828c03d1948adb0b4737ed)

### Added

- Free composition of any session-capable model with Claude Code effort levels `low`, `medium`, `high`, `xhigh`, and `max`.
- Role-based recommendations without restricting the complete model × effort space.
- Watcher toggle in `csl`, enabled by default.
- Immediate per-session port sidecars so monitoring can begin before the first transcript exists.

### Changed

- Deduplicated repeated model/effort role recommendations.
- Clarified role-based dispatch versus free-composition session selection.

### Fixed

- Corrected picker output captured inside command substitution instead of being shown.
- Verified compose, toggle, invalid-input, passthrough, role, and watcher paths.

## [0.9.1] — 2026-08-18

Release commit: [`c72cfb5`](https://github.com/haiggoh/local-agents/commit/c72cfb595e93ced4078f66ef1fd4abc75f317e7a)

### Documentation

- Added plugin marketplace installation commands to the README.
- Made installation discoverable directly from the repository.

## [0.9.0] — 2026-08-18

Release commit: [`0c3d0ad`](https://github.com/haiggoh/local-agents/commit/0c3d0adf46184573a31a4224aae5ab8604d04a77)

### Fixed

- Replaced impossible `lsof`-based transcript inference with launcher-recorded transcript association.
- Added per-launch transcript sidecars.
- Rejected sidecars pointing at missing transcript files.
- Added an honest unverified-candidate fallback when no association exists.
- Prevented newest-mtime and content-matching approaches from attaching the watcher to the wrong session.

### Changed

- Allowed a long polling window for slow first turns before transcript creation.
- Pruned stale sidecars after their launcher exits.

## [0.8.1] — 2026-08-17

Tag: [`v0.8.1`](https://github.com/haiggoh/local-agents/tree/v0.8.1)  
Release commit: [`06de907`](https://github.com/haiggoh/local-agents/commit/06de907ee2da66e5be42b8524a8a227779cc5c62)

### Changed

- Running `local-watch.sh` bare now opens watcher windows.
- `--list` explicitly requests print-only behavior.
- With no running sessions, the watcher falls back to listing.

### Fixed

- Corrected alias extraction when an effort argument follows the model alias.
- Prevented menu-launched sessions from being misidentified by their effort argument.

## [0.8.0] — 2026-08-17

Tag: [`v0.8.0`](https://github.com/haiggoh/local-agents/tree/v0.8.0)  
Release commit: [`1a1bc10`](https://github.com/haiggoh/local-agents/commit/1a1bc10d165ce1e40005af764d9530c4c014b387)

### Added

- `LA_DENY_TOOLS` to remove unusable built-in tool definitions from local requests.
- `LA_MCP_CONFIG` for retaining only selected MCP servers.
- Watcher-window startup support.
- Cache, prefill, and token-rate information in watcher health output.

### Performance

- Reduced a measured local Claude Code request from approximately 68.7K to 22.7K tokens.
- Reduced request size by approximately 67% and measured tool-definition weight by approximately 86%.
- Confirmed that `--disallowedTools` removes definitions, whereas `--allowedTools` does not reduce prompt size.

### Fixed

- Removed instructions to use nonexistent Claude Code tools.
- Updated local-agent guidance to use only exposed tools.

### Changed

- Raised default local request timeout from 30 to 60 minutes.
- Kept `AskUserQuestion` available.

## [0.7.0] — 2026-08-17

Tag: [`v0.7.0`](https://github.com/haiggoh/local-agents/tree/v0.7.0)  
Release commit: [`e4406e9`](https://github.com/haiggoh/local-agents/commit/e4406e92cad6b24408b9872d14f93234178f68dd)

### Fixed

- Prevented `vllm-mlx` from terminating streaming turns at its 300-second server default.
- Added `LA_SERVER_TIMEOUT_S`, derived from the local client timeout by default.
- Added warnings for reused servers with missing or stale timeout settings.
- Prevented long turns from wasting five minutes before a complete retry.

### Changed

- Running the launcher without an alias now opens `csl`.
- Invalid aliases still show usage and valid choices.

## [0.6.0] — 2026-08-17

Tag: [`v0.6.0`](https://github.com/haiggoh/local-agents/tree/v0.6.0)  
Release commit: [`9bab151`](https://github.com/haiggoh/local-agents/commit/9bab1515c43cbe8849c24abedebe518c823ec6ba)

### Added

- `LA_STRICT_MCP` configuration.
- Startup output explaining whether MCP tools are included.

### Performance

- Made `--strict-mcp-config` the default for local sessions.
- Removed 71 configured MCP tool definitions from measured prompts.
- Reduced measured tool weight from approximately 46.9K to 23.9K tokens.

### Documentation

- Documented that tool definitions can dominate local prefill.
- Recorded that `--allowedTools` does not shrink request payloads.

## [0.5.1] — 2026-08-16

Tag: [`v0.5.1`](https://github.com/haiggoh/local-agents/tree/v0.5.1)  
Release commits: [`3628ee4`](https://github.com/haiggoh/local-agents/commit/3628ee41ebb65f7889d48b67afce6543858b3317), [`7561f5d`](https://github.com/haiggoh/local-agents/commit/7561f5d9d73b867ddaacdd6d8418c9e784f66ff8)

### Fixed

- Removed the Copilot launcher’s unused effort argument.
- Warned on unexpected extra Copilot launcher arguments.
- Restored a clean ShellCheck gate instead of suppressing a valid warning.

### Documentation

- Recorded future Copilot effort selection as deferred work.
- Corrected stale pending entries for Copilot SSE and integration testing.

## [0.5.0] — 2026-08-16

Tag: [`v0.5.0`](https://github.com/haiggoh/local-agents/tree/v0.5.0)  
Release commit: [`cf1266f`](https://github.com/haiggoh/local-agents/commit/cf1266fff422c07e1a915d794415a874550b4f56)

### Added

- Conversation-capable terminal `local-agent-dispatch` interface.
- Structured history; compact, verbose, and quiet progress; multiline paste; file attachments; rolling summaries; and resumable named sessions.
- Pure-helper tests for input normalization, session names, and model labels.
- Public dispatcher documentation and component release metadata.
- Experimental Copilot BYOK transport proof and integration harness.

### Changed

- Prepared the repository for public distribution.
- Removed internal planning artifacts, private path references, and unexplained branding.
- Moved Copilot material into a clearly experimental documentation area.
- Removed the dispatcher’s development suffix for its first public release.

### Fixed

- Added a launcher hint directing no-argument users to `csl`.
- Corrected misleading claims that Copilot BYOK was fully functional.
- Documented dependence on unstable Copilot provider environment variables.

### Known limitations

- Copilot BYOK proved transport-level SSE compatibility, not reliable local-engine operation.
- Dispatcher paste presentation and test coverage remained incomplete.

## [0.4.0] — 2026-08-14

Release commit: [`773b74d`](https://github.com/haiggoh/local-agents/commit/773b74d7749e72b413e3b5a59481bbfaf1632994)

### Added

- Local-offload savings ledger.
- Append-only JSONL dispatch events and derived per-session/per-day rollups.
- Reports for today, week, month, and arbitrary start dates.
- Automatic best-effort ledger recording for successful dispatches.
- Dated cloud-pricing table and custom rates-file support.
- Initial terminal dispatcher files and documentation from preparatory commits included before this release boundary.

### Safety

- Unknown cloud models remain unpriced instead of producing a false zero.
- Missing input-token counts remain explicitly unavailable rather than being interpreted as zero.
- Raw prompt character counts are retained when tokens cannot be measured.
- Ledger recording cannot fail a successful dispatch.

### Testing

- Added 70 ledger tests.
- Mutation-tested model normalization, unknown pricing, and separate accounting of unpriced events.
- Verified a live end-to-end dispatch.

## [0.3.0] — 2026-08-11

Release commit: [`188e835`](https://github.com/haiggoh/local-agents/commit/188e83564cb0bb6572972eb2df73364d6fff27c9)

### Added

- Delegation-phase skills:
  - `compose-the-payload`;
  - `brief-the-delegate`;
  - `isolate-parallel-work`;
  - `guard-shared-runtime`;
  - `verify-delegated-work`.

### Changed

- Split delegation into narrowly triggered phases.
- Moved generic shipping discipline out of local-model workflows.
- Kept runtime-specific verification in `guard-shared-runtime`.
- Removed unnecessary foreign-plugin references.

### Fixed

- Replaced nonexistent role-resolution commands.
- Replaced GNU-only checksum examples with macOS-compatible SHA-256 commands.
- Documented minimum `pip` support for dry-run dependency resolution.
- Removed undefined variables and unverified port assumptions.
- Defined delegate prompt placeholders explicitly.

### Validation

- Verified skill frontmatter, path safety, independence, and ShellCheck.

## [0.2.15] — 2026-08-05

Release commit: [`63eeac3`](https://github.com/haiggoh/local-agents/commit/63eeac37df79465a5ae95ea0aef011ee26073efc)

### Fixed

- The launcher selects the newest configured compatibility ID actually advertised by a reused server.
- Prevented pre-change servers from causing immediate model-not-found errors.
- Warned when none of the configured IDs are advertised.

## [0.2.14] — 2026-08-05

Release commit: [`2aa2b4b`](https://github.com/haiggoh/local-agents/commit/2aa2b4b2574594d84c4e8367b0ba372effec0995)

### Added

- Comma-separated compatibility-ID preference lists.
- One server can advertise the same local weights under multiple Claude IDs.
- Backward compatibility with single-value IDs.

### Known limitations

- Loaded models are keyed by served name, so deliberately requesting multiple IDs may load the same weights more than once before idle eviction.

## [0.2.13] — 2026-08-05

Release commit: [`3fe94d0`](https://github.com/haiggoh/local-agents/commit/3fe94d0891d0ce0a74346e0355acd1fcab07934e)

### Fixed

- Quoted skill-description frontmatter for strict YAML parsers.
- Restored skill visibility outside tolerant Claude Code parsing.
- Verified description values round-trip unchanged.

## [0.2.12] — 2026-08-04

Release commit: [`115a8a3`](https://github.com/haiggoh/local-agents/commit/115a8a3dc249810191b11cb797ede4f793f5362e)

### Added

- `--prompt`, `--model`, and `--max-tokens` convenience options for `librarian-dispatch.py`.
- Automatic temporary output directory when `--outdir` is omitted.

### Changed

- Preserved the JSON-payload interface as the primary low-level route.

### Testing

- Verified convenience, payload-regression, and missing-input error paths.

## [0.2.11] — 2026-08-04

Release commit: [`b08eee4`](https://github.com/haiggoh/local-agents/commit/b08eee46f0a866b4d21b8814ad7ea61c756af801)

### Added

- Live streaming of `reasoning_content`.
- `reasoning.txt` output.
- Reasoning counts in completion metadata and heartbeat output.

### Fixed

- Reasoning-only responses no longer produce false `NO DATA` failures.

## [0.2.10] — 2026-08-04

Release commit: [`dc0b571`](https://github.com/haiggoh/local-agents/commit/dc0b571115ac8ee27ac2c7035a53b375232c16d0)

### Added

- Documented supervised offload loop: warm, route, decide, dispatch, verify, correct, and ship.
- ShellCheck lint gate.

### Fixed

- Corrected dispatch documentation to use the actual payload-file interface.
- Documented that standard macOS lacks GNU `timeout` and that the dispatcher provides its own watchdog.

## [0.2.9] — 2026-08-04

Release commit: [`e9e1a19`](https://github.com/haiggoh/local-agents/commit/e9e1a193067500ad1cc21504f08d2598e32da2fd)

### Fixed

- Fixed `wait_ready` aborting under `set -u` because arithmetic referenced a not-yet-bound same-line local variable.
- Restored `SUCCESS_PORT` on fresh launches.

## [0.2.8] — 2026-08-03

Release commit: [`fdd9fab`](https://github.com/haiggoh/local-agents/commit/fdd9faba1d9de4b40458faf081e6e5fe0bec5e6c)

### Added

- Documented multi-session monitoring.
- Per-port inference-health monitoring.
- Transcript mutation and thinking monitoring.
- Health-only and mutations-only watcher modes.
- Repeatable transcript flush-lag measurement.

### Findings

- Measured reasoning-carrying transcript records appearing approximately 0.2–2.6 seconds after turn completion in the tested Claude Code version.

## [0.2.7] — 2026-08-03

Release commit: [`b0001d2`](https://github.com/haiggoh/local-agents/commit/b0001d2a88034cdbd92514ed73f1ea45308e72ad)

### Added

- `LA_API_TIMEOUT_MS`.

### Fixed

- Increased local request timeout beyond Claude Code’s cloud-tuned default.
- Disabled the five-minute no-bytes idle abort for slow local prefill.

## [0.2.6] — 2026-08-02

Release commit: [`08cf812`](https://github.com/haiggoh/local-agents/commit/08cf812afb92afb0fcc23f8fa4ce246e8b871779)

### Changed

- Corrected the recommendation that all tool-driving work should default to a local session.
- Documented parallel local sessions as a bounded pattern for substantial, isolated, verifiable work.
- Added worktree/branch isolation and diff-review guidance.
- Clarified that supervision and review remain real orchestration costs.

## [0.2.5] — 2026-08-02

Release commit: [`320126f`](https://github.com/haiggoh/local-agents/commit/320126fc0b3b90fb02774d37ce99081838b66bd2)

### Changed

- Added guidance to use streaming dispatch for long or open-ended generations.
- Clarified that local Claude Code sessions can drive tools.
- Clarified that stateless dispatch cannot run a tool loop.
- Retained cloud routing where offload overhead exceeds the saving.

## [0.2.4] — 2026-08-01

Release commit: [`a432c1d`](https://github.com/haiggoh/local-agents/commit/a432c1dc8278b96bc649eaeb726f08c4a344e8b9)

### Added

- SessionStart offload nudge.
- `la_role` as shared role-binding source.
- Explicit `cloud:not worth offloading` escape valve.

### Changed

- Unified role resolution and `csl` around the same bindings.
- Kept legacy presets and role tags backward compatible.

## [0.2.3] — 2026-08-01

Release commit: [`e16e512`](https://github.com/haiggoh/local-agents/commit/e16e51240448715d4894d2863d415f974c7ad922)

### Changed

- Made `operator` the broad default local role.
- Defined `reasoner`, `validator`, and `utility` as depth/specialization escalations.
- Required per-step `local:` or `cloud:` routing decisions for bulk multi-step work.
- Defined roles as model × effort/thinking combinations.
- Made the role vocabulary extensible.

## [0.2.2] — 2026-08-01

Release commit: [`cd62743`](https://github.com/haiggoh/local-agents/commit/cd627437bef35d76fc1dbdec7abe580d40712145)

### Added

- Optional registry fields for roles, Hugging Face repository, and approximate size.
- Disk-aware role resolution and `la-roles.sh`.
- Interactive model installation from the registry.
- Partial-roster and multiple-model-per-role support.

### Changed

- Made the registry the roster’s single source of truth.
- Replaced hardcoded model names in routing guidance with role names.
- Kept older eight-field registry entries compatible.

## [0.2.1] — 2026-08-01

Release commit: [`e9c12cf`](https://github.com/haiggoh/local-agents/commit/e9c12cf823f544a9ef452aff8e2dae4e6fb792bd)

### Changed

- Moved offload decisions to task decomposition.
- Added role-based routing for operator, reasoner, validator, and utility work.
- Required self-contained instructions for stateless delegates.
- Expanded triggers beyond explicit cost-saving requests.

## [0.2.0] — 2026-07-31

Release commit: [`3e8a51b`](https://github.com/haiggoh/local-agents/commit/3e8a51b94e2c61a84f57e163f2a337f7a8f724b8)

### Added

- `offload-to-local` skill.
- Guidance for dispatching searches, summaries, boilerplate, transforms, and first-pass reviews to local models.
- Guidance to retain frontier reasoning, security-sensitive work, and final review on capable cloud models by default.

## [0.1.0] — 2026-07-30

Release commit: [`f722c55`](https://github.com/haiggoh/local-agents/commit/f722c5585284b4934a987f7fbc15829f3790d877)

### Added

- Initial local MLX inference overlay for Claude Code on Apple Silicon.
- Direct Anthropic-compatible local routing with native transcripts and history.
- Gitignored machine-specific configuration.
- Config-driven model registry.
- Local launcher, hotswap helper, and `csl` picker.
- Self-preservation and tool-use guidance for local sessions.
- Backend installation and model-download helpers.
- Patch bundle for the local `vllm-mlx` fork.
- Tournament, cancellation, tool-roundtrip, direct-routing, and Auto-mode diagnostics.

[Unreleased]: https://github.com/haiggoh/local-agents/compare/13bf844b6e3ef32530ef49d7c78a94cd7cd37dba...HEAD
[0.12.0]: https://github.com/haiggoh/local-agents/commit/13bf844b6e3ef32530ef49d7c78a94cd7cd37dba
[0.11.0]: https://github.com/haiggoh/local-agents/commit/55f9ef00532b2254d043378abc8593773042c9d9
[0.10.1]: https://github.com/haiggoh/local-agents/commit/584bd0b2562236db7ba2537860478da948b326a1
[0.10.0]: https://github.com/haiggoh/local-agents/commit/2fe748b62371eceb07828c03d1948adb0b4737ed
[0.9.1]: https://github.com/haiggoh/local-agents/commit/c72cfb595e93ced4078f66ef1fd4abc75f317e7a
[0.9.0]: https://github.com/haiggoh/local-agents/commit/0c3d0adf46184573a31a4224aae5ab8604d04a77
[0.8.1]: https://github.com/haiggoh/local-agents/tree/v0.8.1
[0.8.0]: https://github.com/haiggoh/local-agents/tree/v0.8.0
[0.7.0]: https://github.com/haiggoh/local-agents/tree/v0.7.0
[0.6.0]: https://github.com/haiggoh/local-agents/tree/v0.6.0
[0.5.1]: https://github.com/haiggoh/local-agents/tree/v0.5.1
[0.5.0]: https://github.com/haiggoh/local-agents/tree/v0.5.0
[0.4.0]: https://github.com/haiggoh/local-agents/commit/773b74d7749e72b413e3b5a59481bbfaf1632994
[0.3.0]: https://github.com/haiggoh/local-agents/commit/188e83564cb0bb6572972eb2df73364d6fff27c9
[0.2.15]: https://github.com/haiggoh/local-agents/commit/63eeac37df79465a5ae95ea0aef011ee26073efc
[0.2.14]: https://github.com/haiggoh/local-agents/commit/2aa2b4b2574594d84c4e8367b0ba372effec0995
[0.2.13]: https://github.com/haiggoh/local-agents/commit/3fe94d0891d0ce0a74346e0355acd1fcab07934e
[0.2.12]: https://github.com/haiggoh/local-agents/commit/115a8a3dc249810191b11cb797ede4f793f5362e
[0.2.11]: https://github.com/haiggoh/local-agents/commit/b08eee46f0a866b4d21b8814ad7ea61c756af801
[0.2.10]: https://github.com/haiggoh/local-agents/commit/dc0b571115ac8ee27ac2c7035a53b375232c16d0
[0.2.9]: https://github.com/haiggoh/local-agents/commit/e9e1a193067500ad1cc21504f08d2598e32da2fd
[0.2.8]: https://github.com/haiggoh/local-agents/commit/fdd9faba1d9de4b40458faf081e6e5fe0bec5e6c
[0.2.7]: https://github.com/haiggoh/local-agents/commit/b0001d2a88034cdbd92514ed73f1ea45308e72ad
[0.2.6]: https://github.com/haiggoh/local-agents/commit/08cf812afb92afb0fcc23f8fa4ce246e8b871779
[0.2.5]: https://github.com/haiggoh/local-agents/commit/320126fc0b3b90fb02774d37ce99081838b66bd2
[0.2.4]: https://github.com/haiggoh/local-agents/commit/a432c1dc8278b96bc649eaeb726f08c4a344e8b9
[0.2.3]: https://github.com/haiggoh/local-agents/commit/e16e51240448715d4894d2863d415f974c7ad922
[0.2.2]: https://github.com/haiggoh/local-agents/commit/cd627437bef35d76fc1dbdec7abe580d40712145
[0.2.1]: https://github.com/haiggoh/local-agents/commit/e9c12cf823f544a9ef452aff8e2dae4e6fb792bd
[0.2.0]: https://github.com/haiggoh/local-agents/commit/3e8a51b94e2c61a84f57e163f2a337f7a8f724b8
[0.1.0]: https://github.com/haiggoh/local-agents/commit/f722c5585284b4934a987f7fbc15829f3790d877
