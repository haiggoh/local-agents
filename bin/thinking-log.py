#!/usr/bin/env python3
"""
thinking-log.py — extract a session's reasoning ("thinking") into permanently readable text.

Claude Code collapses thinking to transient grey text in the TUI (no built-in setting keeps it
visible), but it IS persisted to the session transcript as type:"thinking" content blocks. This
pulls them out so you can read a local model's chain-of-thought after the fact — e.g. to catch
qwen-thinking making a logic mistake.

Local (vllm-mlx / Plan B) thinking blocks have NO `signature` (a local server can't sign); real
gateway-Claude ones do. Use --local-only to show just the local model's reasoning.

Usage:
  thinking-log.py                      # latest session in this project dir
  thinking-log.py --latest --local-only
  thinking-log.py <session.jsonl>
  thinking-log.py --session <id>       # by session id (with or without .jsonl)
  thinking-log.py ... --out FILE       # also write to FILE
  thinking-log.py ... --dir <project transcripts dir>
"""
import sys, os, json, glob, argparse

# Default to the current cwd's Claude Code project transcript dir (slug = cwd with / -> -),
# so this works for any user without a hardcoded username. Override with --dir.
DEFAULT_DIR = os.path.join(os.path.expanduser("~/.claude/projects"),
                           os.getcwd().replace("/", "-"))


def _text_of(content):
    """Flatten a message 'content' (str or list of blocks) to plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                out.append(b.get("text", ""))
        return " ".join(out)
    return ""


def extract(path, local_only=False):
    """Yield (timestamp, preceding_user_text, thinking_text, is_local) per thinking block."""
    last_user = ""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        msg = r.get("message", {})
        role = msg.get("role")
        content = msg.get("content")
        if role == "user":
            t = _text_of(content).strip()
            if t and not t.startswith("[Request interrupted"):
                last_user = t
        elif role == "assistant" and isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "thinking":
                    is_local = not b.get("signature")
                    if local_only and not is_local:
                        continue
                    txt = b.get("thinking", "")
                    if txt.strip():
                        yield (r.get("timestamp", ""), last_user, txt, is_local)


def resolve_path(args):
    if args.session:
        s = args.session if args.session.endswith(".jsonl") else args.session + ".jsonl"
        return s if os.path.isabs(s) else os.path.join(args.dir, s)
    if args.path and args.path != "--latest":
        return args.path if os.path.isabs(args.path) else os.path.join(args.dir, args.path)
    # latest
    files = sorted(glob.glob(os.path.join(args.dir, "*.jsonl")), key=os.path.getmtime, reverse=True)
    if not files:
        sys.exit(f"No .jsonl transcripts in {args.dir}")
    return files[0]


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("path", nargs="?", help="session .jsonl path, or --latest")
    ap.add_argument("--latest", action="store_true", help="use most recent session")
    ap.add_argument("--session", help="session id (with/without .jsonl)")
    ap.add_argument("--dir", default=DEFAULT_DIR, help="project transcripts dir")
    ap.add_argument("--local-only", action="store_true", help="only unsigned (local model) thinking")
    ap.add_argument("--out", help="also write the report to this file")
    args = ap.parse_args()

    path = resolve_path(args)
    lines = []
    n = 0
    lines.append(f"# Thinking log — {os.path.basename(path)}")
    lines.append(f"# ({'local-only' if args.local_only else 'all thinking blocks'})\n")
    for ts, user, think, is_local in extract(path, args.local_only):
        n += 1
        tag = "LOCAL" if is_local else "gateway"
        lines.append("=" * 78)
        lines.append(f"[{n}] {ts}  ({tag})")
        if user:
            u = user.replace("\n", " ")
            lines.append(f"  ↳ prompt: {u[:160]}{'…' if len(u) > 160 else ''}")
        lines.append("")
        lines.append(think.rstrip())
        lines.append("")
    footer = f"\n{n} thinking block(s) found in {os.path.basename(path)}."
    lines.append(footer)
    report = "\n".join(lines)
    print(report)
    if args.out:
        outp = os.path.expanduser(args.out)
        with open(outp, "w") as f:
            f.write(report + "\n")
        print(f"\n(written to {outp})")


if __name__ == "__main__":
    main()
