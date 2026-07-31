---
name: offload-to-local
description: Use when you're about to do delegatable, bulk, or mechanical work on a paid cloud model and cost matters — reading/summarizing many files, wide grep-and-summarize searches, log/diff/output analysis, boilerplate or scaffold drafting, format/mechanical transforms, repetitive spec-driven edits, first-pass reviews, or draft text you'll refine. It routes that legwork to a FREE local model instead of spending cloud tokens. Triggers include "save cost/tokens", "do this locally", "offload this", "use the local model for this", or simply noticing you're about to burn cloud tokens on work a smaller model could do. Do NOT use it to offload frontier-reasoning, architecture, security-critical, or final-review work.
---

# offload-to-local — send the legwork to a free local model

The biggest cost saving in Claude Code is not a cheaper cloud model — it's **$0 local compute**.
When your main session runs a capable cloud model (Opus/Sonnet), keep that model for judgment and
**delegate the bulk/mechanical legwork to a local model** via dispatch. This applies to anyone who
wants to save cost, with or without a spending cap.

## Offload (dispatch to local — free)
- reading / summarizing many files; log, diff, or command-output analysis
- wide "grep and summarize" searches across a codebase
- mechanical transforms & format conversions; repetitive edits from a clear spec
- boilerplate / scaffold drafting; draft prose you'll refine
- classification / extraction; first-pass reviews (flag candidates for you to confirm)

## Keep on the cloud model (quality-critical)
- architecture / design decisions, tricky debugging, security-sensitive logic
- the FINAL review / verification, and the orchestration & judgment itself

Offload the legwork; keep the judgment. **Verify local output before trusting it** — it's a smaller
model, so a plausible-but-wrong answer is the risk; the point is that the legwork cost nothing.

## How to dispatch
```bash
# ensure the operator is up (hotswap once for a batch), then curl it:
PORT=$(<repo>/bin/local-llm-hotswap.sh <alias> | grep -o 'SUCCESS_PORT=[0-9]*' | cut -d= -f2)
curl -s http://localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<alias-or-spoof>","messages":[{"role":"user","content":"<the delegated task + inputs>"}],"max_tokens":1024}'
```
For long generations use `<repo>/bin/librarian-dispatch.py` (SSE + stall watchdog). The local server
is stateless per request, so include the needed context/inputs in each call.

## The trigger to build the habit
The moment you catch yourself about to read/grep/summarize many files, draft boilerplate, convert
formats, or do a first-pass review **on the paid model** — stop and dispatch it locally first.
"I'll just do it myself" on bulk/mechanical work is the tell that you're spending cloud tokens on
$0 work. For a single trivial item where spin-up costs more than it saves, just do it; when unsure,
offload.
