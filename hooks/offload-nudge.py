#!/usr/bin/env python3
"""SessionStart hook — put the offload-by-role rule IN CONTEXT every session.

Why this exists: local-agents was the only behavioral rule in the family without an in-context
nudge. A skill (trigger-dependent) or a buried CLAUDE.md line underfires — verified by probe: a
fresh session planned a textbook bulk task entirely on cloud despite the rule being present. Every
sibling plugin (no-hidden-changes, measure-twice, audit-loose-ends, run-to-completion, brief-agents)
injects its nudge at SessionStart; this brings offload up to that bar.

Fail-safe: any error → no output, exit 0. Never break or slow a session start.
"""
import json
import os
import sys


def main():
    try:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
        resolver = f"{root}/bin/la-roles.sh" if root else "the plugin's bin/la-roles.sh (or `csl roles`)"
        nudge = (
            "local-agents (offload-to-local): before executing a multi-step or file-touching task, "
            "decide offload PER STEP up front — annotate each planned step `local:<role>` or "
            "`cloud:<reason>`. DEFAULT each delegatable step to `local:operator` (free local compute); "
            "keep a step on cloud with a named reason — quality/capability (frontier reasoning, "
            "security-critical, final review/verification) OR plain cost-benefit: for small or "
            "one-off work where spin-up/briefing overhead "
            "would exceed the saving, `cloud:not worth offloading` is a perfectly good reason. Offload "
            "is the DEFAULT, not a mandate. Roles are a spectrum: operator (broad default) · reasoner · "
            "validator · utility — one model fills several by varying effort. Resolve on-disk models "
            f"(and effort) with `{resolver}`; dispatch via curl, or bin/librarian-dispatch.py (SSE) "
            "for long/open-ended generations (stall watchdog, no timeout death). Tool use is fine "
            "locally — route tool-driving work to a local SESSION (qwen-class models drive tools "
            "normally); only a stateless dispatch can't run a tool loop, so it's not a cloud reason. "
            "The smell is reflexively doing BULK/mechanical work yourself on the paid model — not "
            "skipping offload on trivia. Full guidance: the offload-to-local skill."
        )
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": nudge,
            }
        }))
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
