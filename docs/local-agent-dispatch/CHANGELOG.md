# Changelog — `local-agent-dispatch.py`

All entries below are planned or reconstructed milestones. They are not claims that the corresponding versions were formally released at the historical dates.

## Unreleased — next local-agents release

### Added

- Introduce `local-agent` as a terminal-native companion interface for the `local-agents` model infrastructure.
- Document one-shot and interactive conversation workflows.
- Document structured conversation messages, progress modes, multiline paste, file attachments, rolling summaries, and named sessions.
- Prepare a dedicated dispatcher README and release documentation.

### Planned

- Add automated regression tests for CLI parsing, one-shot dispatch, progress modes, `You>` normalization, multiline input, file limits, rolling summaries, and named-session persistence.
- Add version metadata and a `--version` option.
- Add a documented release checklist and reproducible test command.
- Improve terminal behavior during rapid clipboard pastes so paste-mode status, input collection, and model output cannot appear visually interleaved.
- Preserve current interactive behavior while making the `:paste` / `:end` state transition clearer.

### Release status

This entry is intentionally unreleased. The repository currently contains uncommitted local-agent WIP and unrelated untracked work. Do not publish or tag this entry until the surrounding repository changes have been reviewed and the release owner approves the complete release set.

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