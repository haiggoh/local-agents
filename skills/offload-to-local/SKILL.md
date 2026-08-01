---
name: offload-to-local
description: Use when PLANNING or decomposing any multi-step task while cost matters, AND when you're about to do delegatable/bulk/mechanical work on a paid cloud model — reading/summarizing many files, wide grep-and-summarize searches, log/diff/output analysis, boilerplate or scaffold drafting, format/mechanical transforms, repetitive spec-driven edits, first-pass reviews, or draft text you'll refine. It routes each delegatable stage to the RIGHT free local model by role instead of spending cloud tokens. Triggers include starting a multi-step plan under a budget constraint / Credit Efficient Mode, "save cost/tokens", "do this locally", "offload this", "use the local model for this", or noticing you're about to burn cloud tokens on work a smaller model could do. Do NOT use it to offload frontier-reasoning, architecture, security-critical, or final-review work.
---

# offload-to-local — send the legwork to a free local model

The biggest cost saving in Claude Code is not a cheaper cloud model — it's **$0 local compute**.
When your main session runs a capable cloud model (Opus/Sonnet), keep that model for judgment and
**delegate the bulk/mechanical legwork to a local model** via dispatch. This applies to anyone who
wants to save cost, with or without a spending cap.

## Decide UPFRONT, at decomposition — not mid-work
The habit is not "notice you're already grinding through files and stop." It's: **when you first
break a task into steps, scan the plan for delegatable stages and route them to local before you
execute anything.** Waiting until you're mid-bulk-work means the cloud tokens are already being spent.

**Under an active budget constraint** (a spending cap, Credit Efficient Mode, or the user has flagged
cost) the default flips: every delegatable stage goes local unless you can name why it *must* stay on
the cloud model. You justify keeping work on cloud, not offloading it. Absent any budget pressure this
is optional — but the upfront scan still costs nothing.

## Route by role — resolve, then brief
Match each delegatable stage to a **role**, then resolve which of *your* on-disk models fills it —
**never hardcode a model name**, the roster changes. The registry (`config.local.sh`) is the single
source of truth; this resolves it against what's actually downloaded:
```bash
<repo>/bin/la-roles.sh          # per-role table — ● on disk / usable now, ○ registered but not downloaded
<repo>/bin/la-roles.sh <role>   # just the on-disk alias(es) for one role (empty = unfilled)
# or `csl roles`
```

| Delegatable stage | Role | How to brief it |
|---|---|---|
| Read/summarize many files, log/diff/output analysis, wide grep-and-summarize, mechanical transforms, format conversion, repetitive spec-driven edits, boilerplate/scaffold, draft prose | **operator** | Exact task, all inputs inline, exact output shape (schema/format). The workhorse — favor it. |
| Reasoning-heavy first pass: analyze *why*, enumerate trade-offs, draft a plan, structured comparison | **reasoner** | The question + full context; ask for its reasoning. Slower per turn. |
| Independent validation / second-opinion / adversarial critique of a plan or diff | **validator** | Feed the artifact + the criteria; ask it to find flaws. Usually run as a curl dispatch — it critiques, it doesn't drive tools. |
| Cheap classification / extraction / tagging at volume | **utility** | Tight instruction + the items; keep it small and mechanical. |

**A partial roster is fine.** If `la-roles.sh` shows a role with no ● (nothing downloaded for it),
keep that work on the cloud model or download a model for it (`install/download-models.sh`,
interactive). If a role lists several ● models, that's your A/B choice — pick one or try both.

## Keep on the cloud model (quality-critical)
Architecture / design decisions, tricky debugging, security-sensitive logic, the FINAL
review / verification, and the orchestration & judgment itself. Offload the legwork; keep the
judgment. **Verify local output before trusting it** — it's a smaller model, so a plausible-but-wrong
answer is the risk; the point is that the legwork cost nothing.

## Briefing (local dispatch is stateless)
A dispatch is a stateless HTTP call — nothing carries between requests — so each one must be
self-contained: the role you want the model to play, the inputs, and the exact output format,
resent every call. For a bounded mechanical stage that's usually all it needs (task + inputs), not
your full rule set. If the delegated work is architecture/code-shaped **and you run the
`brief-agents` plugin**, also fold the relevant lines of its `~/.claude/agent-briefing-index.md`
into the prompt — handing a delegate your durable *rules* is brief-agents' job; this skill only
covers the local-dispatch mechanics. (No dependency: without brief-agents, just skip that step.)

## How to dispatch
```bash
# ensure the right model is up (hotswap once for a batch), then curl it:
PORT=$(<repo>/bin/local-llm-hotswap.sh <alias> | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<alias-or-spoof>","messages":[{"role":"user","content":"<role + task + inputs + output spec>"}],"max_tokens":1024}'
```
For long generations use `<repo>/bin/librarian-dispatch.py` (SSE + stall watchdog). For a single
trivial item where spin-up costs more than it saves, just do it; when unsure, offload.
