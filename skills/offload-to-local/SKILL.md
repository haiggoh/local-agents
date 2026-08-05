---
name: offload-to-local
description: 'Use when PLANNING or decomposing ANY multi-step task, and whenever your plan involves reading, searching, summarizing, transforming, drafting, extracting, or editing across files — regardless of whether cost is mentioned. Also when you''re about to do delegatable/bulk/mechanical work on a paid cloud model, or you notice you''re about to burn cloud tokens on work a smaller model could do. It routes delegatable work to a free local model — by DEFAULT to the broad `operator` role, escalating to a specialist role only when needed — instead of spending cloud tokens. Explicit triggers: starting a multi-step plan (especially under a budget constraint / Credit Efficient Mode), "save cost/tokens", "do this locally", "offload this", "use the local model for this". Do NOT use it to offload frontier-reasoning, architecture, security-critical, or final-review work.'
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
unless you can name why it's `cloud:`. Valid `cloud:` reasons are of two kinds:
- **quality/capability** — frontier reasoning, security-critical, or final review/verification; and
- **cost-benefit** — the work is small or one-off and the spin-up/briefing overhead would exceed the
  saving (`cloud:not worth offloading`). This is a first-class, legitimate reason, not a cop-out.

**Offload is the default, not a mandate.** The point is to stop *reflexively* doing bulk/mechanical
work on the paid model — not to force a local hop onto trivia where it costs more than it saves. When
in doubt on a real chunk of work, offload; on a one-liner, just do it. Absent budget pressure the
whole annotation is optional — but the upfront pass costs nothing.

## Route by role — operator by default, escalate when needed
`operator` is the **broad default / catch-all**: any delegatable chunk goes here unless it clearly
needs a specialist. The others are *escalations*, not separate silos — a role is a point on a
spectrum of depth, not a narrow bucket. **When in doubt, `operator`.**

| Role | Reach for it when… | How to brief it |
|---|---|---|
| **operator** (DEFAULT) | anything delegatable: read/search/summarize many files, log/diff/output analysis, mechanical transforms, format conversion, repetitive spec-driven edits, boilerplate/scaffold, draft prose, straightforward extraction. If it's not clearly one of the below, it's operator. | Exact task, inputs inline, exact output shape. Favor it. |
| **reasoner** (escalate) | the chunk needs real multi-step reasoning: analyze *why*, enumerate trade-offs, draft a plan, structured comparison. | Question + full context; ask for its reasoning. |
| **validator** (escalate) | independent validation / second-opinion / adversarial critique of a plan or diff. | Artifact + criteria; ask it to find flaws. Usually a curl dispatch (review needs no tool-driving). |
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

**Tool use is NOT a reason to avoid local.** A local *session* (the operator via
`launch-claude-agent.sh`) drives Claude Code's tools fine — qwen-class models handle tool-calling
normally; only a stateless curl *dispatch* can't run a tool loop. So "it involves tools" never
disqualifies local. But be honest about the default: for tool-driving work **coupled to what this
session is already doing**, cloud is usually right — it holds the live context and tool state. The
local-*session* route is a deliberate move for one specific shape of work (below), not the default.

### Advanced: delegate a tool-driving chunk to a parallel local session
Worth it for a **big, isolated, verifiable** chunk (e.g. a mechanical refactor across many files then
run the tests) — not for small or tightly-coupled tool-work. Launch a local session as a side worker
(`bin/new-local-window.sh <alias>` opens an independent window) and let it grind while this cloud
session continues. To make it pay off and stay safe:
- **Isolate** — give it its own git worktree/branch or a disjoint file set, so the two agents can't clobber each other.
- **Watch + verify** — local models hallucinate paths and botch tool schemas; supervise the session (tail its log / a monitor) and review its diff before trusting it. Never merge unsupervised local edits blind.
- **Mind the infra** — vllm-mlx is single-slot and minutes-per-turn: this suits a long *background* chunk, not latency-sensitive or interactive-with-you work, and a busy session queues your own dispatches.
- **Amortize** — launching a session costs more than a curl dispatch; reach for it only when the chunk is substantial. Smaller → dispatch it, or keep it on cloud.

The supervision + review is real cloud-attention cost, so the win is cheap *compute*, not zero effort.
Use it when the chunk is big enough that $0 tool-driving compute clearly beats the coordination overhead.

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
**Stream long or open-ended generations** with `librarian-dispatch.py` (SSE). Why stream: a **stall
watchdog** aborts a hung local server (no tokens for N s) instead of blocking forever on a dead
request; no timeout death on multi-minute runs (the connection keeps receiving); and live progress.
It takes a **JSON body file** and an output dir (NOT `--prompt`/`--model` flags):
```bash
# write a standard chat-completions body, then dispatch it:
echo '{"model":"<alias-or-spoof>","max_tokens":800,"messages":[{"role":"user","content":"<role + task + inputs + output spec>"}]}' > /tmp/body.json
<repo>/bin/librarian-dispatch.py --port "$PORT" --payload /tmp/body.json --outdir /tmp/la-out
# assistant text streams to /tmp/la-out/output.txt; live heartbeats print on stdout;
# exit 0 = done, 2 = HTTP/engine error, 3 = transport. (The script sets stream=true for you.)
```
Don't wrap dispatches in `timeout` — it's GNU-only (absent on stock macOS) and the built-in stall
watchdog already handles a hung server. Plain curl (above) is fine for short, bounded calls. For a
single trivial item where spin-up costs more than it saves, just do it; when unsure, offload.

## The supervised offload loop (put it together)
Offloading pays off only when you **supervise** it. The repeatable loop:
1. **Warm** the model once up front (`local-llm-hotswap.sh <alias>`, backgroundable) so the first
   dispatch isn't paying cold-start latency; capture the `SUCCESS_PORT` it prints.
2. **Route** — resolve role→model with `la-roles.sh` (never hardcode a name).
3. **Decide** per step: `local:<role>` or `cloud:<reason>` (above).
4. **Dispatch** the local step self-contained (stateless — resend the full briefing).
5. **VERIFY against ground truth** — never trust local output blind. Compare it to something known
   (the real file list, a functional test, a diff) and judge by an *observable outcome change*, not
   "it replied / no error." A smaller model's failure mode is plausible-but-wrong.
6. **Correct** — if it's off (hallucinated path, stale interface, wrong shape), fix the briefing and
   re-dispatch, or finish on cloud. Retrying is cheap; the compute was free.
7. **Ship** (when the work is a repo/plugin change): verify → commit → push → reinstall → confirm it's
   live in the *installed* copy, not just the source tree.

Grab cheap ground truth **before** dispatching (e.g. `ls` the real files) so step 5 is a comparison,
not a fresh guess. The supervision is real cloud attention — that's the cost; the legwork compute is $0.
