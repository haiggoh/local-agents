# Local Claude Code context-reduction profile — measurement protocol

**Goal:** shrink the ~64k-char / 79-tool stable prefix that makes local interactive
turns prefill-bound (RESUME §18). Every reduction here is a *candidate*, tested one at
a time against `/context`, never batched. Nothing here is active until you launch with
`--settings` / the documented flags.

Build verified: `claude 2.1.205`. Confirmed flags: `--settings`, `--tools`,
`--disallowedTools`, `--allowedTools`, `--strict-mcp-config`, `--safe-mode`, `--bare`,
`--append-system-prompt`, `--permission-mode`.

## Measurement loop (do this for EACH experiment)
1. Launch the current operator normally; run `/context`; record: total initial tokens,
   system-prompt tokens, built-in-tool tokens, MCP-tool tokens, memory tokens, tool count.
2. Launch with ONE change; run `/context`; record the same six numbers.
3. Also confirm the local coding workflow still works (read, edit, bash, a tool round-trip).
4. Keep the change only if it materially cuts prefill AND breaks nothing.

## Baselines (run once, for reference bounds)
- `claude --safe-mode`  → customization-overhead lower bound (keeps built-in tools).
- `claude --bare`       → minimal floor (skips hooks/skills/plugins/MCP/auto-memory/CLAUDE.md;
                          keeps Bash + core file tools). Too aggressive for daily use, but
                          it tells you the absolute minimum prefix this build can run at.

## The big levers (LAUNCHER FLAGS — confirmed valid, biggest wins first)
These are the highest-impact reductions and are all reversible per-launch:

- **`--disallowedTools "mcp__*"`**  → removes ALL MCP tool schemas from context. On this
  machine that's the whole `joyia` server (aws/backstage/jira/xray/confluence/gitlab/
  memory/image/ocr/cc_live/…) + `filesystem` — dozens of schemas a local coding session
  rarely needs. Expected to be the single largest cut. (WebSearch is already broken via the
  gateway per CLAUDE.md, so losing web-ish MCP tools locally costs nothing.)
- **`--strict-mcp-config`**  → ignore all MCP servers except those from an explicit
  `--mcp-config`. Cleaner than deny-listing when you want a known-minimal MCP set.
- **`--tools <names…>`**  → allowlist ONLY the built-ins a repo session needs. Use the
  build's EXACT names (check `claude --help` / a live session). A safe starting set is the
  file+shell+search+edit+task core; do NOT drop Task/Agent if the workflow delegates.

## The safe settings.json (this file: local-profile.json)
Holds only `permissions.deny: ["NotebookEdit"]` — a bare-name deny removes that tool's
schema from context (vs a scoped `Bash(rm *)` rule which keeps the tool visible). Kept
deliberately tiny so `--settings local-profile.json` can never fail a launch. Add more
bare-name denies here only after confirming (a) the exact tool name and (b) it's unused.

## Verify-then-test candidates (research-derived keys — NOT yet confirmed in this build)
My grep of the cask wrapper couldn't confirm these; check them against the real bundle or
docs before adding. Test each ALONE with `/context`:
- `disableBundledSkills: true`  — likely a large cut (the skill listing is big); safe for a
  focused coding session. **Highest-value candidate if valid.**
- `disableWorkflows: true`
- `includeGitInstructions: false`  — only if equivalent git guidance already lives in CLAUDE.md.
- `autoMemoryEnabled: false`  — CAUTION: this removes the per-turn CLAUDE.md/memory
  `<system-reminder>`. That reminder is exactly the ~9k-token suffix that (a) you WANT for
  local usefulness and (b) is the KV-cache prefix-defeater (RESUME §18). Turning it off
  trades capability for speed — measure the tradeoff, don't default it on. The
  prefix-stabilizer approach (see consolidated plan Tier 2) is the better answer.
- `skillOverrides: { "<name>": "off" | "name-only" }`, `skillListingMaxDescChars`,
  `skillListingBudgetFraction` — finer skill-listing trims if the toggle above is too blunt.

## Activation (when a profile is proven)
Add to `launch-claude-agent.sh` after the env exports, e.g.:
```
#   claude --model "$MODEL_SPOOF" $EFFORT_FLAG --permission-mode acceptEdits \
#     --settings "$SCRIPT_DIR/local-profile.json" \
#     --disallowedTools "mcp__*" \
#     --append-system-prompt "$AGENT_PROMPT"
```
Rollback = delete the two added flags. Keep this notes file as the record of what was tested.
