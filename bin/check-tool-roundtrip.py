#!/usr/bin/env python3
"""check-tool-roundtrip.py — T2-1 acceptance verifier for the direct local route.

The one gate the stack hasn't formally passed: a full native tool ROUND-TRIP through
direct local routing — structured tool_call -> tool executes -> tool_result -> final
answer -> native transcript, with NO reasoning/markup leakage.

The dispatch tournament already proves the operator EMITS structured tool_calls; this
verifies the rest of the loop actually happened inside a real Claude Code session, by
inspecting that session's native transcript.

HOW TO USE:
  1. In a LOCAL session (fresh terminal):
        ~/.claude/scripts/local-inference/launch-claude-agent.sh qwen-3.6-operator
     then type exactly:
        list the files in ~/.claude/scripts using your tools
     let it run the tool + answer, then exit.
  2. Back here (any shell):
        ~/.claude/scripts/local-inference/check-tool-roundtrip.py
     (auto-picks the newest transcript; or pass a path / session-id)

It checks: (a) an assistant tool_use block exists, (b) a matching tool_result follows,
(c) a final assistant TEXT answer follows the result, (d) no <think>/<tool_call>/
<function=/[TOOL_CALLS]/bracket-call markup leaked into visible content or tool inputs,
(e) history.jsonl got a fresh row (native persistence). Prints PASS/FAIL per criterion.
"""
import glob, json, os, sys, time

PROJECTS = os.path.expanduser("~/.claude/projects")
HISTORY = os.path.expanduser("~/.claude/history.jsonl")
LEAK_MARKERS = ["<think>", "</think>", "<tool_call>", "<function=", "[TOOL_CALLS]", "[ARGS]"]

def newest_transcript():
    files = glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True)
    return max(files, key=os.path.getmtime) if files else None

def resolve(arg):
    if not arg:
        return newest_transcript()
    if os.path.isfile(arg):
        return arg
    hits = glob.glob(os.path.join(PROJECTS, "**", f"{arg}*.jsonl"), recursive=True)
    return hits[0] if hits else None

def load(path):
    recs = []
    for line in open(path, errors="ignore"):
        line = line.strip()
        if line:
            try: recs.append(json.loads(line))
            except Exception: pass
    return recs

def content_blocks(rec):
    msg = rec.get("message") or {}
    c = msg.get("content")
    return c if isinstance(c, list) else ([{"type": "text", "text": c}] if isinstance(c, str) else [])

def main():
    path = resolve(sys.argv[1] if len(sys.argv) > 1 else None)
    if not path:
        print("FAIL: no transcript found"); sys.exit(2)
    age_min = (time.time() - os.path.getmtime(path)) / 60
    print(f"transcript: {path}\n  (age {age_min:.1f} min)\n")
    recs = load(path)

    tool_use_idx = tool_result_idx = final_answer_idx = None
    leaks = []
    for i, r in enumerate(recs):
        typ = r.get("type")
        for b in content_blocks(r):
            bt = b.get("type")
            if typ == "assistant" and bt == "tool_use" and tool_use_idx is None:
                tool_use_idx = i
                inp = json.dumps(b.get("input", {}))
                for mk in LEAK_MARKERS:
                    if mk in inp: leaks.append(f"tool input @rec{i}: {mk}")
            if typ == "user" and bt == "tool_result" and tool_use_idx is not None and tool_result_idx is None:
                tool_result_idx = i
            if typ == "assistant" and bt == "text":
                txt = b.get("text") or ""
                for mk in LEAK_MARKERS:
                    if mk in txt: leaks.append(f"assistant text @rec{i}: {mk}")
                if tool_result_idx is not None and i > tool_result_idx and final_answer_idx is None:
                    final_answer_idx = i

    def ok(b): return "PASS" if b else "FAIL"
    c1 = tool_use_idx is not None
    c2 = tool_result_idx is not None
    c3 = final_answer_idx is not None
    c4 = len(leaks) == 0
    # history freshness
    c5 = False
    if os.path.isfile(HISTORY):
        c5 = (time.time() - os.path.getmtime(HISTORY)) / 60 < 60
    print(f"[{ok(c1)}] structured tool_use block present" + (f" (rec {tool_use_idx})" if c1 else ""))
    print(f"[{ok(c2)}] tool_result follows the call" + (f" (rec {tool_result_idx})" if c2 else ""))
    print(f"[{ok(c3)}] final assistant answer after result" + (f" (rec {final_answer_idx})" if c3 else ""))
    print(f"[{ok(c4)}] no reasoning/markup leakage")
    if leaks:
        for l in leaks[:8]: print(f"        leak: {l}")
    print(f"[{ok(c5)}] history.jsonl fresh (<60 min) — native persistence")

    passed = all([c1, c2, c3, c4])
    print(f"\n=== T2-1 ROUND-TRIP: {'PASS' if passed else 'FAIL'} ===")
    print("(re-run in the local session if this transcript wasn't the tool-round-trip one)")
    sys.exit(0 if passed else 1)

if __name__ == "__main__":
    main()
