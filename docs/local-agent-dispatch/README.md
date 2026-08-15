# `local-agent` — Terminal Local-Agent Dispatcher

`local-agent` is a terminal-native companion interface for the local models registered in the `local-agents` stack. It lets you work with local agents independently of Claude Code while reusing the repository’s existing model registry, hotswap layer, and librarian dispatch infrastructure.

The dispatcher is included alongside the main `local-agents` tooling as a useful alternative launch surface. It is not required for the primary plugin workflow, but users who prefer terminal-based interaction can invoke it directly.

## Requirements

The dispatcher expects these sibling components in the same `bin/` directory:

- `local-agent-dispatch.py`
- `local-llm-hotswap.sh`
- `librarian-dispatch.py`

It also relies on the repository’s model registry and local server configuration.

## Quick start

One-shot prompt:

```zsh
local-agent --prompt "What does this module do?"
```

Attach files:

```zsh
local-agent --prompt "Review the attached code." --files ./src/main.py
```

Interactive conversation:

```zsh
local-agent --convo
```

Choose a model:

```zsh
local-agent --model qwen-3.6-operator --prompt "Summarize this change."
```

## Conversation features

Conversation mode supports:

- structured user/assistant message history;
- model-derived terminal labels such as `qwen:`;
- compact, verbose, and quiet progress modes;
- multiline input with `:paste` and `:end`;
- accidental leading `You>` cleanup;
- rolling context summaries;
- `:context` and `:summary` inspection commands;
- `:file PATH` attachments during a conversation;
- per-file character limits through `--max-file-chars`;
- named session save/resume through `--session`;
- explicit `:save` and `:session` commands;
- atomic owner-only JSON session files.

### Multiline input

Start multiline mode explicitly:

```text
You> :paste
Paste multiline text now. Finish with :end on its own line.
Review this code:

```python
print("hello")
```
:end
```

The `:end` terminator must be on its own line, unless it is appended to the final clipboard line without a trailing newline.

A known follow-up usability improvement is to make fast clipboard pastes display more clearly and prevent terminal input/output from appearing interleaved. The current delimiter-based collection works, but that terminal presentation refinement remains planned.

### Named sessions

Create or resume a session:

```zsh
local-agent --convo --session my-session
```

Useful commands:

```text
:session
:save
exit
```

Sessions are stored by default under:

```text
~/.local/share/local-agent/sessions/
```

Set `LOCAL_AGENT_SESSION_DIR` to use another location. Session files contain conversation content and are not encrypted; the dispatcher attempts to enforce owner-only permissions.

## Progress modes

Compact is the default:

```zsh
local-agent --progress compact --prompt "Explain recursion."
```

Use verbose diagnostics when debugging dispatch:

```zsh
local-agent --progress verbose --prompt "Reply exactly: verbose works"
```

Use quiet mode when only model output is wanted:

```zsh
local-agent --progress quiet --prompt "Reply exactly: quiet works"
```

## Important options

```text
--model ALIAS
--prompt TEXT
--files FILE [FILE ...]
--max-tokens N
--max-history-chars N
--max-file-chars N
--session NAME
--allow-session-model-mismatch
--progress {compact,verbose,quiet}
--convo
```

`--max-history-chars` is a soft compaction threshold, not a strict context ceiling. The newest complete turn may exceed it. Use `0` for unlimited history.

`--max-file-chars` rejects oversized attachments before dispatch. Use `0` only when deliberately allowing unlimited file size.

## Relationship to the main project

The dispatcher is a companion terminal interface to the same infrastructure used by `local-agents`. It is intentionally located in this repository because it depends on the sibling hotswap and librarian scripts, model registry, and local launch conventions.

It can be installed with the rest of the repository even when users do not invoke it. The main plugin workflow does not require it, while terminal users gain an independent way to interact with the registered local models.

## Development status

The dispatcher is an actively developed pre-1.0 component. Its principal workflows have been tested manually against the local model infrastructure. Automated regression tests, version metadata, and a formal release boundary are planned before the first stabilized `v1.0.0` release.

See the project release plan and changelog for the reconstructed feature history and pending work.