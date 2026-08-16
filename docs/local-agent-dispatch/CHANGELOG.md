# Changelog — `local-agent-dispatch.py`

All entries below are planned or reconstructed milestones. They are not claims that the corresponding versions were formally released at the historical dates.

## 0.9.0 — first published release of the terminal dispatcher

Published as part of plugin release `0.5.0`. The `.dev0` suffix was dropped because
the code is being released rather than held back; it is functional and in daily use,
not feature-complete. Known rough edges below are expected to be fixed in later
releases rather than blocking this one.

### Added in this release

- `tests/test_local_agent_dispatch.py` — framework-free unit tests (47 assertions) for
  `normalize_user_input`, `validate_session_name` and `model_display_label`, matching the
  existing `tests/test_savings_ledger.py` style. Mutation-tested: seven injected defects
  were each caught, so the suite is known to be capable of failing.

### Known rough edges (not fixed in 0.9.0)

- Visual interleaving during rapid clipboard pastes. Isolated `:paste` / `:end`
  collection has passed manual functional testing; the presentation issue is deliberately
  left for a separate focused patch.
- Test coverage reaches three of seventeen top-level functions. Session save/load,
  `read_files_context` file-size limits, the `:paste` / `:end` conversation collector,
  history compaction and the model-mismatch refusal are not yet covered.
- Model aliases are still hardcoded per model rather than routed by role, and the
  `local-*` / `local-agent-*` command namespaces differ by one infix while doing
  completely different things (launch a session vs. one-shot dispatch). Both are queued
  for a naming pass.

### Implemented and tested

- One-shot dispatch.
- Interactive conversation mode.
- Structured conversation messages.
- Compact, verbose, and quiet progress modes.
- `:paste` / `:end` multiline input.
- Leading `You>` normalization.
- Rolling summaries with `:context` and `:summary`.
- `:file PATH` and attachment-size enforcement.
- Named-session save/resume with autosave.

### Known follow-up

Rapid clipboard pastes can make terminal input echoes and model output appear
visually interleaved even though isolated multiline collection succeeds.

### Planned

- Improve paste-mode terminal presentation.
- Add automated regression tests.
- Finalize release metadata and the documented version source of truth.
- Add a reproducible smoke-test command.
- Complete release review before tagging or pushing.

## v0.9.0 — Named session save and resume

### Added

- `--session NAME` to create or resume a named conversation.
- Automatic save after successful responses and history compaction.
- `:save` for explicit persistence.
- `:session` for session status and storage path.
- Atomic JSON writes through a temporary file and replacement.
- Owner-only session directory and file permissions.
- Session schema validation.
- Model-mismatch protection with an explicit override option.
- Persistence of structured history, rolling summary, and compaction count.

### Verified

- New-session creation.
- Autosave and explicit save.
- Cross-process resume and exact-token recall.
- JSON parsing and owner-only permissions.

## v0.8.1 — Symlink, port-contract, and output-channel hardening

### Changed

- Resolve the dispatcher directory with `realpath()` so sibling scripts work through the launcher symlink.
- Require an explicit `SUCCESS_PORT` from the hotswap layer instead of guessing a port.
- Send reasoning diagnostics to stderr so stdout remains suitable for answer output and pipelines.

## v0.8.0 — Attachment limits and mid-conversation files

### Added

- `--max-file-chars` with explicit oversized-file rejection.
- `:file PATH` for attaching files during an active conversation.
- Quoted paths and path normalization.
- Clear attachment warnings.
- Clarified rolling-session-context and soft-history-threshold wording.

## v0.7.0 — Rolling history summaries and context inspection

### Added

- Model-generated rolling summaries before older turns are removed.
- Failure-safe compaction.
- Visible compaction notices.
- Summary injection as structured system context.
- `:context` and `:summary`.

## v0.6.0 — Progress modes

### Added

- Compact progress as the default.
- Verbose raw librarian diagnostics.
- Quiet inference output.
- Spinner, elapsed-time status, and concise completion reporting.

## v0.5.0 — Structured chat messages

### Changed

- Replace flattened `User:` / `Assistant:` prompts with structured chat-completion messages.
- Preserve one-shot compatibility.

## v0.4.0 — Conversation UX and bounded history

### Added

- Model-derived response labels.
- Active model in the conversation heading.
- Leading accidental `You>` cleanup.
- Soft history compaction threshold.
- Failed-turn exclusion from history.
- Visible librarian progress.

## v0.3.0 — Interactive multiline paste

### Added

- `:paste` and `:end` multiline input.
- Direct stdin collection for long pasted content.
- Support for a terminator appended to a final clipboard line without a newline.

## v0.2.0 — Initial conversation mode

### Added

- `--convo`.
- Interactive prompt loop.
- In-memory history.
- Backward-compatible one-shot mode.
- `exit`, `quit`, and `q` commands.

## v0.1.0 — Original one-shot dispatcher

### Added

- Model selection.
- One-shot prompts.
- File context.
- Token limit configuration.
- Hotswap and librarian integration.
- Temporary output handling.
- Existing `local-agent` launcher compatibility.

## Versioning policy

- `0.x.0`: meaningful feature or architectural milestone.
- `0.x.y`: compatible hardening or bug fix.
- `1.0.0`: documented behavior, repeatable automated tests, release metadata, clean repository state, and a tagged stabilized release.