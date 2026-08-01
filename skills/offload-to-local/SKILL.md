---
name: offload-to-local
description: Use when PLANNING or decomposing ANY multi-step task, and whenever your plan involves reading, searching, summarizing, transforming, drafting, extracting, or editing across files — regardless of whether cost is mentioned. Also when you're about to do delegatable/bulk/mechanical work on a paid cloud model, or you notice you're about to burn cloud tokens on work a smaller model could do. It routes delegatable work to a free local model — by DEFAULT to the broad `operator` role, escalating to a specialist role only when needed — instead of spending cloud tokens. Explicit triggers: starting a multi-step plan (especially under a budget constraint / Credit Efficient Mode), "save cost/tokens", "do this locally", "offload this", "use the local model for this". Do NOT use it to offload frontier-reasoning, architecture, security-critical, or final-review work.
---

# offload-to-local — send the legwork to a free local model

The biggest cost saving in Claude Code is not a cheaper cloud model — it's **$0 local compute**.
When your main session runs a capable cloud model (Opus/Sonnet), keep that model for judgment and
**delegate the bulk/mechanical legwork to a local model** via dispatch. This applies to anyone who
wants to save cost, with or without a spending cap.

## Decide UPFRONT, at decomposition — not mid-work
The habit is not "notice you're already grinding through files and stop." It's: **when you first
break a task into steps, decide per step where it runs before you execute anything.** Waiting until
you're mid-bulk-work means the cloud tokens are already being spent.

**Make it a required column in the plan — don't leave it implicit** (an implicit "I'll offload
later" reliably becomes "I did it all on cloud"). For any multi-step task that touches files or has
bulk/mechanical steps — and *always* under a budget constraint — annotate **every** step:

- `local:<role>` — delegated to a local model (default `operator`; see below), or
- `cloud:<reason>` — kept on the cloud model, with the reason named.

**Default to `operator`.** Under a budget constraint the burden flips: a step is `local:operator`
unless you can name why it must be `cloud:` (frontier reasoning, security-critical, final review,
or it needs live tools the local model can't drive). You justify keeping work on cloud, not
offloading it. Absent budget pressure the annotation is optional — but the upfront pass costs nothing.

## Route by role — operator by default, escalate when needed
`operator` is the **broad default / catch-all**: any delegatable chunk goes here unless it clearly
needs a specialist. The others are *escalations*, not separate silos — a role is a point on a
spectrum of depth, not a narrow bucket. **When in doubt, `operator`.**

| Role | Reach for it when… | How to brief it |
|---|---|---|
| **operator** (DEFAULT) | anything delegatable: read/search/summarize many files, log/diff/output analysis, mechanical transforms, format conversion, repetitive spec-driven edits, boilerplate/scaffold, draft prose, straightforward extraction. If it's not clearly one of the below, it's operator. | Exact task, inputs inline, exact output shape. Favor it. |
| **reasoner** (escalate) | the chunk needs real multi-step reasoning: analyze *why*, enumerate trade-offs, draft a plan, structured comparison. | Question + full context; ask for its reasoning. |
| **validator** (escalate) | independent validation / second-opinion / adversarial critique of a plan or diff. | Artifact + criteria; ask it to find flaws. Usually a curl dispatch — it critiques, doesn't drive tools. |
| **utility** (down-shift) | trivial classification / extraction / tagging at high volume, where even operator is overkill. | Tight instruction + the items; keep it mechanical. |

**Roles are filled by a (model × effort/thinking) pairing — not one model each.** The SAME weights
serve different roles at different depths: fast/thinking-off = operator/utility; higher-effort or
thinking-on = reasoner/validator. So a small roster covers a wide role spectrum by varying effort —
and adding a role rarely means adding a model. Resolve which of *your* on-disk models (and at what
effort) fills each role — **never hardcode a model name**, the roster changes:
```bash
<repo>/bin/la-roles.sh          # per-role table — ● on disk / usable now, ○ not downloaded; shows each model's effort
<repo>/bin/la-roles.sh <role>   # just the on-disk alias(es) for one role (empty = unfilled)
# or `csl roles`
```

**Roles are extensible.** These four are the current canonical set; add more as the roster grows
(e.g. `coder`, `vision`/OCR, `long-context`) — the registry `roles` field takes any tag and the
resolver lists canonical + extras, so a new role is a tag plus a row here. If the existing roles feel
too narrow for the work you keep doing, widen a role's "reach for it when" or add one — the goal is
that most delegatable work maps to *some* role, so offload gets reached for often.

**A partial roster is fine.** If `la-roles.sh` shows a role with no ● (nothing downloaded), keep that
work on cloud or download a model (`install/download-models.sh`, interactive). Several ● under one
role = your A/B choice — pick one or try both.

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
