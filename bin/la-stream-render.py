#!/usr/bin/env python3
"""la-stream-render.py — render a Claude Code transcript stream for a HUMAN watching a local session.

Reads transcript .jsonl records on stdin (typically `tail -f`) and prints only what a person
watching a slow local model actually wants: what it is thinking, and what it is doing.

Why this exists: tailing the raw .jsonl put ~67% noise on screen (measured on a real session: 154
of 230 records were attachment/queue-operation/mode/permission-mode/ai-title/file-history chatter),
and the interesting parts arrived as unwrapped single-line JSON, so thinking was technically
present but effectively illegible. The transcript itself formats thinking as clean paragraphs; this
reproduces that on the live stream.

Renders:
  🧠 thinking   verbatim, re-wrapped, blank-line-separated paragraphs, in its own block
  🔧 tool       one concise line per call: tool name + the most identifying argument
  💬 text       the assistant's visible reply
  👤 user       your prompts, so the exchange reads in order
Skips everything else. --raw passes unrecognised records through if you need to debug.
"""
import json, sys, textwrap, shutil, re, signal

# A streaming renderer is almost always on the left of a pipe (`| head`, `| less`, a closed watcher
# window). Default Python turns that into a BrokenPipeError traceback on the user's screen; restore
# the shell-native behaviour of just ending quietly.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

WIDTH = min(shutil.get_terminal_size((100, 24)).columns, 100)
RAW = "--raw" in sys.argv
NO_COLOR = "--no-color" in sys.argv or not sys.stdout.isatty()
def c(code, s):
    return s if NO_COLOR else f"\033[{code}m{s}\033[0m"

def hr(label):
    pad = max(0, WIDTH - len(label) - 4)
    return c("2", f"── {label} " + "─" * pad)

def wrap(text, indent="   "):
    out = []
    for para in re.split(r"\n\s*\n", text.strip()):
        para = " ".join(para.split())
        if para:
            out.append(textwrap.fill(para, width=WIDTH - len(indent),
                                     initial_indent=indent, subsequent_indent=indent))
    return "\n\n".join(out)

def tool_summary(inp):
    """The one argument that identifies what a call is doing."""
    if not isinstance(inp, dict):
        return ""
    for k in ("command", "file_path", "pattern", "path", "url", "query", "prompt", "description"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            v = " ".join(v.split())
            return v if len(v) <= WIDTH - 24 else v[: WIDTH - 27] + "..."
    return ""

def emit(line=""):
    try:
        print(line, flush=True)
    except BrokenPipeError:
        sys.exit(0)

seen_tools = {}
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or not raw.startswith("{"):
        continue
    try:
        r = json.loads(raw)
    except Exception:
        if RAW:
            emit(c("2", raw[:WIDTH]))
        continue
    typ = r.get("type")
    msg = r.get("message") or {}
    blocks = msg.get("content") or []
    if isinstance(blocks, str):
        blocks = [{"type": "text", "text": blocks}]

    if typ == "user":
        for b in blocks:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and b.get("text", "").strip():
                t = b["text"]
                if "<system-reminder>" in t:      # injected context, not something you typed
                    continue
                emit(); emit(hr("👤 you")); emit(wrap(t))
            elif b.get("type") == "tool_result":
                tid = b.get("tool_use_id")
                name = seen_tools.pop(tid, "tool")
                content = b.get("content")
                if isinstance(content, list):
                    content = " ".join(x.get("text", "") for x in content if isinstance(x, dict))
                content = " ".join(str(content or "").split())
                status = c("31", "failed") if b.get("is_error") else c("32", "ok")
                extra = f" · {len(content)} chars" if content else ""
                emit(c("2", f"   ↳ {name} {status}{extra}"))
    elif typ == "assistant":
        for b in blocks:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "thinking":
                th = (b.get("thinking") or "").strip()
                if th:
                    emit(); emit(hr("🧠 thinking")); emit(wrap(th))
            elif bt == "text":
                tx = (b.get("text") or "").strip()
                if tx:
                    emit(); emit(hr("💬 says")); emit(wrap(tx))
            elif bt == "tool_use":
                nm = b.get("name", "?")
                seen_tools[b.get("id")] = nm
                s = tool_summary(b.get("input"))
                emit(); emit(f"   {c('36','🔧 ' + nm)}" + (c("2", f"  {s}") if s else ""))
    elif RAW:
        emit(c("2", f"[{typ}] {raw[:WIDTH-10]}"))
