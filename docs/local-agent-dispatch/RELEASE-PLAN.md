# Release Plan — `local-agent-dispatch.py`

## Objective

Prepare `local-agent-dispatch.py` for inclusion in a future `local-agents` release as a positively advertised terminal companion interface for the repository’s local-agent infrastructure.

The dispatcher provides an independent terminal launch surface outside Claude Code while reusing the existing model registry, hotswap layer, librarian dispatcher, and launcher conventions.

## Current position

The dispatcher implementation and its primary documentation are committed
locally but have not been pushed or tagged as a public release.

The current local development version is `0.9.0.dev0`. Manual validation has
covered:

- syntax and CLI options;
- one-shot mode;
- compact, verbose, and quiet progress;
- structured conversation messages;
- accidental leading `You>` cleanup;
- `:paste` / `:end` multiline input;
- rolling summaries and context inspection;
- `:file` and attachment-size rejection;
- named-session creation, autosave, resume, and JSON permissions;
- version output through `--version`.

The rapid-clipboard-paste display behavior remains the next usability
refinement: input and output can appear visually interleaved even though the
isolated `:paste` workflow succeeds.

The repository remains ahead of `origin/main` with local Copilot and
dispatcher commits. No push or release tag has been created. Remaining
untracked or ignored runtime material must stay outside the release scope
unless explicitly reviewed.

## Release principles

1. Do not publish the current dirty tree merely because the dispatcher is useful.
2. Preserve WIP backups before every state-changing edit.
3. Separate dispatcher work from unrelated Copilot files, logs, and other experiments.
4. Add documentation and tests now if useful, but keep them clearly marked as unreleased until the repository release is approved.
5. Do not claim a version is released until the final tree, tests, changelog, and tag are reviewed together.
6. Keep the dispatcher in `local-agents` for now because it depends on sibling scripts and shared infrastructure.

## Proposed repository files

```text
bin/local-agent-dispatch.py
docs/planning/Local Agent Dispatcher — Retroactive Version History and Release Plan.md
docs/local-agent-dispatch/README.md
docs/local-agent-dispatch/CHANGELOG.md
docs/local-agent-dispatch/RELEASE-PLAN.md
tests/local-agent-dispatch/
```

The exact placement may follow the repository’s existing documentation conventions. If the project prefers a top-level README or changelog, move the content accordingly before commit.

## Stage 0 — Freeze and inventory current WIP

- Keep the current WIP backup untouched.
- Record the current script hash and repository status.
- Review Claude Code’s pending changes before adding or publishing anything.
- Keep Copilot-related untracked files and logs out of the dispatcher release unless separately approved.
- Review whether the current script has a final newline and trailing whitespace; fix only in a deliberate cleanup revision with a new backup.

## Stage 1 — Add documentation to the dirty tree

Prepare, but do not release:

- dispatcher README;
- dispatcher changelog;
- this release plan;
- an update to the existing retroactive version-history document.

Documentation should advertise the dispatcher as a useful terminal companion, not frame it as an unsupported or unwanted subsystem. It should still accurately distinguish unreleased WIP from a tagged release.

## Stage 2 — Fix paste-burst UX

Investigate the observed rapid-paste behavior:

- make entry into paste mode visibly unambiguous;
- prevent the terminal from visually mixing input echoes with model output;
- ensure the `:end` transition is visibly recognized before dispatch;
- avoid any possibility of dispatching partial clipboard input;
- retain the current successful `:paste` and `:end` semantics;
- add a regression fixture for a large multiline paste.

This should be a focused patch based on the current source, not a rewrite of the dispatcher.

## Stage 3 — Add automated tests

Create a test suite that does not require a live model for ordinary unit tests. Mock or stub the hotswap and librarian boundaries.

Minimum coverage:

- argument validation and help output;
- model label derivation;
- leading `You>` normalization;
- normal single-line input;
- `:paste` collection and `:end` handling;
- final-line `:end` handling;
- structured message construction;
- progress-mode routing;
- rolling-summary success and failure safety;
- `:file` parsing and quoted paths;
- attachment-size rejection;
- session-name validation;
- atomic session serialization and load validation;
- model-mismatch refusal;
- autosave behavior;
- one-shot compatibility.

Keep a small separate live-model smoke suite for end-to-end verification.

## Stage 4 — Release metadata and reproducible verification

The dispatcher development metadata is now present:

- `__version__ = "0.9.0.dev0"`;
- `--version`;
- development-version wording in the dispatcher documentation.

The remaining work in this stage is verification and release preparation:

- add a documented version source of truth;
- add a reproducible automated test command;
- add a release checklist;
- update the changelog for the first public terminal-companion release;
- ensure the README, changelog, and release plan match actual behavior.

These are development checkpoints, not public releases. The next version
number should be chosen only after the paste UX work, automated tests, and
release scope have been reviewed.

## Stage 5 — Repository review

Before committing:

- inspect `git status` and `git diff --stat`;
- classify every modified and untracked file;
- exclude logs and unrelated experiments;
- verify backups and hashes;
- run syntax checks and automated tests;
- run selected live-model smoke tests;
- check documentation paths and links;
- review the complete staged diff;
- obtain explicit approval for the release scope.

## Stage 6 — Commit and release

Only after the previous stages pass:

1. stage the explicitly approved dispatcher files;
2. inspect the staged diff and file list;
3. commit the dispatcher release separately from unrelated Copilot work where practical;
4. create the agreed Git tag;
5. push only after final confirmation;
6. publish release notes advertising the terminal companion interface.

## Suggested release announcement

> `local-agent` is now included as a terminal-native companion interface for the local models registered in `local-agents`. It provides one-shot prompts and interactive conversations outside Claude Code while reusing the project’s existing model registry, hotswap layer, and librarian infrastructure. It includes multiline paste, structured history, progress modes, file attachments, rolling summaries, and resumable named sessions.

## Explicit non-actions for the current checkpoint

- Do not push a new release yet.
- Do not tag a release yet.
- Do not stage the entire repository.
- Do not include `logs/`, backups, generated bytecode, or local configuration.
- Do not conflate Copilot work with dispatcher release work without explicit approval.
- Do not apply the paste UX patch until its scope and backup are confirmed.
- Do not describe `0.9.0.dev0` as a public release.

## Release readiness checklist

- [ ] Claude Code WIP reviewed and incorporated or intentionally excluded.
- [ ] Paste-burst UX fix implemented and tested.
- [ ] Automated regression tests committed.
- [ ] Live smoke tests repeated.
- [x] `--version` implemented for the current development checkpoint.
- [ ] A documented version source of truth is finalized.
- [ ] README and changelog match actual behavior.
- [ ] Existing retroactive version history updated.
- [x] Backups and hashes recorded for the current implementation checkpoints.
- [ ] Repository diff and commit range classified.
- [x] Logs and unrelated runtime work excluded from tracked release files.
- [ ] Clean staged diff reviewed.
- [ ] Release approved, tagged, and pushed.
