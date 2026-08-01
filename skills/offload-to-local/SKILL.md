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

## Route by role — brief the right local model for the job
Different local models fill different roles (aliases below are the maintainer's stack; yours come from
`config.local.sh`). Match the stage to the role and brief it accordingly:

| Delegatable stage | Local role → alias | How to brief it |
|---|---|---|
| Read/summarize many files, log/diff/output analysis, wide grep-and-summarize, mechanical transforms, format conversion, repetitive spec-driven edits, boilerplate/scaffold, draft prose | **operator** → `qwen-3.6-operator` (fast, thinking off) | Give the exact task, all inputs inline, and the exact output shape you want back (schema/format). It's the workhorse — favor it. |
| Reasoning-heavy first pass: analyze *why*, enumerate trade-offs, draft a plan, structured comparison | **reasoner** → `qwen-3.6-thinking` | State the question + full context; ask for its reasoning. Slower per turn by design. |
| Independent validation / second-opinion review / adversarial critique of a plan or diff | **validator** → `deepseek-r1-architect` (dispatch-only, no tool_calls) | Feed the artifact + the criteria; ask it to find flaws. Curl-dispatch only — not an interactive tool driver. |
| Cheap classification / extraction / tagging at volume | **utility** → `llama-scout` (dispatch-only) | Tight instruction + the items; keep it small and mechanical. |

## Keep on the cloud model (quality-critical)
Architecture / design decisions, tricky debugging, security-sensitive logic, the FINAL
review / verification, and the orchestration & judgment itself. Offload the legwork; keep the
judgment. **Verify local output before trusting it** — it's a smaller model, so a plausible-but-wrong
answer is the risk; the point is that the legwork cost nothing.

## Briefing (local agents start with NOTHING)
The local server is **stateless per request** and the model has **none** of your CLAUDE.md, memory,
role, or conversation context. Every dispatch must be self-contained: state the role you want it to
play, paste the inputs it needs, and specify the exact output format. Resend the briefing each call.
If a repo/agent-briefing index exists, fold the relevant bits into the prompt.

## How to dispatch
```bash
# ensure the right model is up (hotswap once for a batch), then curl it:
PORT=$(<repo>/bin/local-llm-hotswap.sh <alias> | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<alias-or-spoof>","messages":[{"role":"user","content":"<role + task + inputs + output spec>"}],"max_tokens":1024}'
```
For long generations use `<repo>/bin/librarian-dispatch.py` (SSE + stall watchdog). For a single
trivial item where spin-up costs more than it saves, just do it; when unsure, offload.
