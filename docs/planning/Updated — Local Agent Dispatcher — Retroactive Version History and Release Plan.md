# Local Agent Dispatcher — Retroactive Version History and Release Plan

**Project:** `local-agent-dispatch.py`  
**Canonical path:** `/Users/bra0002h/ClaudeWorkspace/local-agents/bin/local-agent-dispatch.py`  
**Backup directory:** `/Users/bra0002h/ClaudeWorkspace/local-agents/backups/local-agent-dispatch`  
**Status:** Pre-1.0, actively developed  
**Versioning proposal:** Semantic Versioning (`MAJOR.MINOR.PATCH`)  
**Current reconstructed version:** **v0.9.0**, functionally validated; unreleased WIP

---

## 1. Purpose

This document retroactively establishes meaningful versions for the major iterations of `local-agent-dispatch.py`.

The goals are to:

- record when major capabilities were introduced;
- identify likely regression boundaries;
- map versions to timestamped backup files where possible;
- distinguish product features from patch-delivery or escaping fixes;
- provide a basis for future Git tags, changelogs, and releases;
- define a path toward a stable `v1.0.0`.

The historical versions below are **reconstructed milestones**, not claims that formal releases occurred at the time.

---

## 2. Versioning policy

Until the dispatcher is packaged, documented, and covered by repeatable tests, use `0.x.y` versions:

- **Minor version (`0.x.0`)** — meaningful feature milestone or architectural change.
- **Patch version (`0.x.y`)** — compatible hardening or bug fixes that do not materially expand the interface.
- **Major version (`1.0.0`)** — first intentionally stabilized release with documented behavior and a reproducible test suite.

Examples:

- Adding structured chat messages: minor version.
- Adding named sessions: minor version.
- Hardening symlink resolution and port selection: patch version.
- Fixing generated-patch escaping: delivery fix, normally not a product release.

---

## 3. Reconstructed release history

## v0.1.0 — Original one-shot dispatcher

### Features

- Model selection through `--model`.
- One-shot prompts through `--prompt`.
- Optional file context through `--files`.
- Configurable output generation through `--max-tokens`.
- Model activation through `local-llm-hotswap.sh`.
- Request execution through `librarian-dispatch.py`.
- Temporary output directory handling.
- Separate reading of `output.txt` and `reasoning.txt`.
- Existing symlink-based `local-agent` command compatibility.

### Limitations

- Every turn required a new shell command.
- No in-process conversation history.
- No multiline interactive input.
- Long shell prompts required careful quoting or heredoc command substitution.

---

## v0.2.0 — Qwen conversational first draft

### Features added

- Optional `--convo` mode.
- Interactive `You>` loop.
- In-memory conversation history.
- Initial prompt support through `--convo --prompt`.
- Backward-compatible one-shot mode.
- Exit commands: `exit`, `quit`, and `q`.

### Known issues

- Conversation history was flattened using literal `User:` and `Assistant:` labels.
- `input()` submitted on every newline.
- Librarian output was captured, making long requests appear silent.
- No context-size management.
- No protection against accidentally pasted `You>` prompts.

### Historical note

The first installation attempt included Markdown fences and surrounding prose. That was a delivery error, not a product release.

---

## v0.3.0 — Interactive multiline paste mode

### Features added

- `:paste` command for multiline input.
- `:end` delimiter to submit accumulated text as one turn.
- Direct `sys.stdin.readline()` handling for long pasted content.
- Removal of per-line continuation prompts that visually interleaved with large pastes.
- Recognition of `:end` appended to a final clipboard line lacking a trailing newline.

### Verified

- Multiline Markdown code fences reached the model as one message.
- Long source-code pastes worked without shell quoting.

---

## v0.4.0 — Conversation UX and bounded history

**Rollback anchor:** `local-agent-dispatch.py.bak-20260811-212821`

### Features added

- Model-derived terminal labels such as `qwen:`.
- Active model shown in the conversation heading.
- Leading accidental `You>` markers removed from user input.
- `--max-history-chars`, defaulting to `48,000` characters.
- Complete-turn history selection.
- Failed or empty model turns excluded from history.
- Visible librarian output restored.

### Verified

- Model labels, `You>` normalization, multiline input, and one-shot mode worked.

---

## v0.5.0 — Structured chat messages

**Rollback anchor:** `local-agent-dispatch.py.bak-structured-20260811-215224`

### Architectural change

Conversation requests switched from flattened prompts to structured chat-completions messages sent through `librarian-dispatch.py --payload`.

### Improvements

- Real `user` and `assistant` message roles.
- Structured JSON request body.
- One-shot compatibility wrapper retained.
- Separate reasoning output excluded from assistant history.

### Verified

- One-shot structured requests.
- Multi-turn identifier retention (`STRUCTURED-731`).
- Multiline paste after the architecture change.

---

## v0.6.0 — Compact, verbose, and quiet progress modes

**Rollback anchor:** `local-agent-dispatch.py.bak-progress-20260811-215752`

### Features added

- `--progress compact` as default.
- `--progress verbose` for raw librarian diagnostics.
- `--progress quiet` for suppressed inference diagnostics.
- Compact spinner and elapsed time.
- Concise completion line.
- Cleaner subprocess interruption handling.

### Verified

All three progress modes returned expected output and exit status `0`.

---

## v0.7.0 — Rolling history summaries and context inspection

**Rollback anchor:** `local-agent-dispatch.py.bak-summary-20260811-221354`

### Features added

- Model-generated summary before older messages are removed.
- Failure-safe compaction: raw history remains if summarization fails.
- Visible compaction notices.
- Rolling summary injected as structured system context.
- Recent complete turns retained verbatim.
- `:context` and `:summary` inspection commands.
- Redundant outer one-shot dispatch announcement limited to verbose mode.

### Verified

Using a `500`-character threshold:

- older messages compacted successfully;
- `AURORA-918` and `Dublin` survived compaction;
- context and summary inspection worked;
- later turns answered from summarized context.

### Semantics

- `--max-history-chars` is a soft threshold, not a strict ceiling.
- The newest complete turn is retained even if it exceeds the threshold.
- At this milestone, summaries existed only for the current process.

---

## v0.8.0 — Attachment limits and mid-conversation files

**Pre-v0.8 rollback anchor:** `local-agent-dispatch.py.bak-files-20260811-225921`  
**Backup SHA-256:** `2d3d9c590bf8de7a807b4ed5b5a3ecd321cf195888b60de6da3330ada5518c85`

> The backup filename records the patch being attempted, but the backup itself is the state immediately **before** v0.8.0 was installed.

### Features added

- `--max-file-chars`, defaulting to `48,000` characters per file.
- Explicit oversized-file rejection instead of silent truncation.
- `--max-file-chars 0` to deliberately disable the limit.
- `:file PATH` during an active conversation.
- Quoted paths with spaces.
- Path expansion and normalization.
- Visible warnings for missing or unreadable files.

### UX corrections

- History setting described as a soft compaction threshold.
- “Persistent session context” renamed to “rolling session context.”
- `:file` documented in the conversation banner.

### Verified

- `:file` attached the dispatcher and Qwen correctly identified `:paste` from it.
- `--max-file-chars 100` rejected the 26,261-character dispatcher without dispatching a model request.
- One-shot `--files` remained wired through the same limit.

---

## v0.8.1 — Symlink, port-contract, and output-channel hardening

**Author:** Claude Code  
**Reviewed pre-v0.9 source SHA-256:** `1ee338d49de6034408a8b335e8aea7f0d48ab331be58cdd6b16d5d11e49164d3`  
**Reviewed source length:** 789 lines

This patch-level milestone records Claude Code’s three isolated changes on top of v0.8.0.

### Fixed and hardened

1. **Symlink-aware script location**
   - Changed `os.path.abspath(__file__)` to `os.path.realpath(__file__)`.
   - Ensures `BIN_DIR` resolves to the actual script directory when `local-agent` is invoked through a symlink.
   - Keeps sibling lookup for `local-llm-hotswap.sh` and `librarian-dispatch.py` reliable.

2. **Strict hotswap port contract**
   - Reads all `SUCCESS_PORT` values and uses the last one.
   - Accepts `=`, `:`, or whitespace separators.
   - Removed heuristic port scanning and the silent fallback to port `8000`.
   - Fails loudly if no contract line is present, avoiding dispatch to the wrong local model.

3. **Reasoning sent to stderr**
   - Separate model reasoning display moved from stdout to stderr.
   - Preserves stdout as the model-answer channel for redirection and pipelines.

### Review result

- Python parsing passed.
- All v0.8.0 features remained present.
- The three changes were isolated and compatible with named-session work.
- The installed pre-v0.9 script hash matched the reviewed attachment exactly before the session patch was applied.

### Process note

Claude Code edited a file with substantial uncommitted work without first creating its own backup. A byte-identical snapshot was subsequently created and moved to the central backup directory before further changes.

---

## v0.9.0 — Named session save and resume

**Pre-v0.9 rollback anchor:** `local-agent-dispatch.py.bak-sessions-20260812-161146`  
**Backup location:** `/Users/bra0002h/ClaudeWorkspace/local-agents/backups/local-agent-dispatch/`

> As with other patch-created backups, this file is the state immediately before v0.9.0 was installed—equivalent to reviewed v0.8.1.

### Features added

- `--session NAME` to create or resume a named conversation.
- Automatic save after every successful response.
- Immediate save after successful history compaction.
- Save on textual exit and at the interactive EOF/interrupt handler.
- `:save` for explicit persistence.
- `:session` to show active name, model, path, and autosave state.
- `--allow-session-model-mismatch` as an explicit override.

### Storage and safety

- Default session directory:
  ```text
  ~/.local/share/local-agent/sessions/
  ```
- Override through `LOCAL_AGENT_SESSION_DIR`.
- Session names restricted to a portable safe character set and length.
- Atomic JSON writes through a temporary file and `os.replace()`.
- Session directory forced to owner-only mode `0700`.
- Session files forced to owner-only mode `0600`.
- Schema validation on load.
- Structured history roles and content validated.
- Model mismatch refused by default.
- Hidden reasoning is not saved.

### Persisted schema v1 fields

- `schema_version`
- `session_name`
- `model_alias`
- `conversation_history`
- `rolling_summary`
- `compacted_message_count`
- `updated_at_unix`

### Installation validation completed

- Candidate and installed source passed `py_compile`.
- `--session` appeared in help.
- `--allow-session-model-mismatch` appeared in help.
- `:session` and `:save` handlers were confirmed installed.
- Backup was moved to the central backup directory.

### Functional validation completed

Create and save:

```zsh
local-agent --convo --session persistence-test
```

```text
You> Remember the exact identifier SESSION-842 and region Cork. Reply only: stored
You> :session
You> :save
You> exit
```

Resume in a new process:

```zsh
local-agent --convo --session persistence-test
```

```text
You> What exact identifier and region did I ask you to remember? Reply with only both values.
```

Expected:

```text
qwen: SESSION-842, Cork
```

Also verify:

```zsh
session_file="$HOME/.local/share/local-agent/sessions/persistence-test.json"
ls -l "$session_file"
/usr/bin/env python3 -m json.tool "$session_file" | head -40
```

Expected permission prefix: `-rw-------`.

---

## 4. Delivery fixes that are not feature releases

These were important engineering fixes but are not independent feature milestones:

- Removing Markdown fences and prose from executable files.
- Correcting malformed heredoc usage.
- Extracting only the main fenced shell block from downloaded notes.
- Converting generated patch templates to raw strings.
- Using regex replacement callbacks to preserve backslashes.
- Splitting long terminal commands to avoid incomplete paste and unmatched quotes.
- Running `py_compile` before and after each installation.
- Creating byte-identical snapshots and verifying them with SHA-256.

---

## 5. Proposed next versions

## v0.10.0 — Terminal UX refinement, session management, and attachment accounting

### Candidate features

- Focused fix for rapid clipboard paste presentation and input/output interleaving.
- Make paste-mode entry and `:end` recognition visibly unambiguous.
- `:sessions` to list saved sessions.
- Session archive/delete commands with confirmation.
- Optional `:new NAME` or controlled in-process session switching.
- Better file-context accounting in `:context`.
- Optional attachment metadata without retaining duplicate file bodies indefinitely.
- Configurable attachment policy based on model context size.
- Clear handling for corrupted or externally edited session files.
- Optional explicit save confirmation policy for autosave failures.

## v0.11.0 — Test and release infrastructure

### Candidate features

- Repeatable smoke-test script.
- `__version__` and `--version`.
- Maintained `CHANGELOG.md`.
- README and architecture documentation.
- Automated checks for one-shot, conversation, multiline, structured payloads, progress modes, summarization, files, and session resume.
- Backup pruning/archive policy.

## v1.0.0 — Stabilized dispatcher

Suggested release criteria:

- Named-session functional save/resume verified.
- Repeatable smoke tests committed.
- CLI help and README match behavior.
- Changelog maintained.
- Version constant and `--version` available.
- Git repository clean and tagged.
- Recovery and rollback procedure documented.
- All major modes tested against supported model aliases.

---

## 6. Recommended repository artifacts

Create and maintain:

```text
CHANGELOG.md
README.md
docs/architecture.md
docs/testing.md
scripts/smoke-test.zsh
```

Add a version constant after v0.9.0 functional validation:

```python
__version__ = "0.9.0"
```

Expose it through:

```text
local-agent --version
```

Use annotated Git tags for future formal milestones. Do not retroactively tag reconstructed versions unless matching historical commits can be verified.

---

## 7. Regression lookup table

| Symptom | First inspect |
|---|---|
| One-shot invocation fails | v0.1.0 baseline and compatibility wrapper |
| Conversation exits after one turn | v0.2.0 |
| Pasted code becomes several prompts | v0.3.0 |
| Literal leading `You>` confuses the model | v0.4.0 |
| Role continuity or payload formatting fails | v0.5.0 |
| Spinner or progress output is wrong | v0.6.0 |
| Old facts disappear after compaction | v0.7.0 |
| `:context` or `:summary` fails | v0.7.0 |
| Initial or mid-session attachment fails | v0.8.0 |
| Symlink launch cannot find helper scripts | v0.8.1 `realpath()` change |
| Wrong model/port receives a request | v0.8.1 port-contract parsing |
| Redirected answer contains reasoning | v0.8.1 stderr routing |
| Named session does not save or resume | v0.9.0 session helpers and autosave calls |
| Session refuses a different model | Expected v0.9.0 behavior; use explicit override only deliberately |
| Session JSON is readable by other users | v0.9.0 permission enforcement |

---

## 8. Current status and immediate next step

The installed script corresponds to **reconstructed v0.9.0** and is functionally validated. The current repository tree remains intentionally dirty and contains substantial uncommitted WIP, so no release should be pushed yet.

Verified areas include syntax and CLI registration, one-shot mode, all progress modes, structured messages, leading `You>` cleanup, multiline `:paste`, rolling summaries, `:context`, `:summary`, `:file`, attachment-size rejection, and named-session creation, autosave, cross-process resume, JSON validation, and owner-only permissions.

A known follow-up is the terminal presentation during very rapid clipboard pastes: isolated `:paste` collection succeeds, but terminal input echoes and output can appear visually interleaved.

The next recommended milestone is **v0.10.0: paste UX refinement plus session management and attachment-accounting refinements**, followed by automated test and release infrastructure. The dispatcher should be documented and prepared in the dirty tree, but not staged, tagged, or pushed until the surrounding WIP is reviewed and the release scope is approved.
