---
name: isolate-parallel-work
description: 'Use BEFORE dispatching work that touches files or requires exclusive access to a server/port. Triggered by the need to run multiple agents concurrently or to prevent clobbering. Do NOT use for verifying output, guarding runtime, or composing payloads.'
---

# isolate-parallel-work — prevent clobbering and contention

When multiple agents (local sessions, cloud subagents, or manual edits) work on the same repo or share a server, isolation is mandatory.

## Detect other running sessions
"Look for other sessions" is not actionable. Use signals, not intuition:

1. **Servers and their owners:** list what is actually listening before assuming a port is yours.
   ```bash
   # narrow the grep to whatever port range your launcher scans, not a guessed one
   lsof -nP -iTCP -sTCP:LISTEN | grep -E ':80[0-9][0-9]'
   ```
2. **Which agent sessions are live, and where they point.** Read each candidate process's environment: the
   endpoint variable is the only reliable local-vs-remote tell, because a "this is local" shell flag **leaks**
   into any later process started from the same shell.
   ```bash
   ps eww <pid> | tr ' ' '\n' | grep -m1 '^ANTHROPIC_BASE_URL='
   lsof -a -p <pid> -d cwd -Fn        # what that session is working on
   ```
3. **Catch sessions whose process you mis-matched:** recently-modified transcript files reveal activity your
   process grep missed.
   ```bash
   # <transcripts-dir> = wherever the harness writes per-session transcripts
   # (for Claude Code: ~/.claude/projects/<cwd-slug>/)
   find <transcripts-dir> -name '*.jsonl' -mmin -20
   ```
4. **Check the queue-admission setting** before sharing a single-slot server: with admission set to wait,
   concurrent requests queue instead of erroring; without it, the second request can wedge the server
   permanently. Verify it on the *running* process rather than assuming the launcher set it.

## Share a single-slot server safely
If multiple agents must use the same single-slot server (e.g., vllm-mlx):
1. **Queue requests:** Do not dispatch simultaneously. Use a queue or sequential dispatch.
2. **Monitor contention:** If one agent is generating, others must wait.

## Give file-touching delegates their own worktree/branch
If a delegate modifies files:
1. **Create a worktree or branch:** Give the delegate its own isolated workspace.
   ```bash
   git worktree add ../worktree-<id> <branch>
   ```
2. **Dispatch to the worktree:** Point the delegate’s file operations to the worktree path.
3. **Merge after verification:** Only merge the worktree into the main branch after `verify-delegated-work` passes.

## Isolate parallel sessions
If launching a parallel local session:
1. **Use a disjoint file set:** Ensure the two agents do not touch the same files.
2. **Use separate ports:** If possible, run each session on its own server instance to avoid contention.

