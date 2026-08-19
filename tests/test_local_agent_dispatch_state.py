#!/usr/bin/env python3
"""Framework-free tests for the dispatcher's STATEFUL helpers (patch 2).

Usage: python3 tests/test_local_agent_dispatch_state.py

Companion to test_local_agent_dispatch.py, which covers the pure helpers. This
tier covers the parts that touch a filesystem or stdin: named-session save/load,
read_files_context's per-file cap, the :paste/:end conversation collector, and
compact_history_if_needed's early returns.

Still NO model server and NO pytest, by design:
  * every path here writes into a tmpdir, never the real ~/.local/share tree.
    SESSION_DIR is resolved at import time from LOCAL_AGENT_SESSION_DIR, so the
    environment is set BEFORE the module is loaded below.
  * only compact_history_if_needed's three early-return paths are exercised.
    Anything with two or more complete turn pairs calls the summarizer, which
    would need a live port -- that belongs in a live tier, not here.
  * rapid-paste PRESENTATION is deliberately out of scope (plan step 7).
"""
import builtins
import contextlib
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "local-agent-dispatch.py")

TMP_ROOT = tempfile.mkdtemp(prefix="lad-state-tests-")
os.environ["LOCAL_AGENT_SESSION_DIR"] = os.path.join(TMP_ROOT, "sessions")

spec = importlib.util.spec_from_file_location("lad_state", SCRIPT)
lad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lad)

# Guard against writing to the developer's real session directory: if the env
# var is ever read at call time instead of import time, this catches it.
assert TMP_ROOT in lad.SESSION_DIR, (
    "SESSION_DIR did not honour LOCAL_AGENT_SESSION_DIR (%r) -- refusing to run "
    "against the real session store" % lad.SESSION_DIR
)

passed = failed = 0


def check(cond, label):
    global passed, failed
    if cond:
        passed += 1
        print("  ok   %s" % label)
    else:
        failed += 1
        print("  FAIL %s" % label)


def expect_valueerror(fn, label):
    try:
        fn()
    except ValueError:
        check(True, label)
    except Exception as exc:  # noqa: BLE001 - wrong exception type is a failure
        check(False, "%s -- raised %s instead" % (label, type(exc).__name__))
    else:
        check(False, "%s -- no error raised" % label)


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return path


HISTORY = [
    {"role": "user", "content": "first question"},
    {"role": "assistant", "content": "first answer"},
]

print("\n-- named session save/load round-trip --")
saved_path = lad.save_named_session("roundtrip", "qwen-op", HISTORY, "a summary", 4)
check(os.path.isfile(saved_path), "save_named_session writes the file it returns")

history, summary, compacted, path, resumed = lad.load_named_session(
    "roundtrip", "qwen-op", False
)
check(history == HISTORY, "history survives the round-trip unchanged")
check(summary == "a summary", "rolling_summary survives the round-trip")
check(compacted == 4, "compacted_message_count survives the round-trip")
check(resumed is True, "an existing session reports resumed=True")
check(path == saved_path, "load reports the same path save returned")

print("\n-- on-disk shape and permissions --")
payload = json.load(open(saved_path, encoding="utf-8"))
check(payload.get("schema_version") == 1, "writes schema_version 1")
check(payload.get("session_name") == "roundtrip", "records the session name")
check(isinstance(payload.get("updated_at_unix"), int), "records an integer timestamp")
check(
    stat.S_IMODE(os.stat(saved_path).st_mode) == 0o600,
    "session file is owner-only (0600)",
)
check(
    stat.S_IMODE(os.stat(os.path.dirname(saved_path)).st_mode) == 0o700,
    "session directory is owner-only (0700)",
)
check(
    not [n for n in os.listdir(os.path.dirname(saved_path)) if n.endswith(".tmp")],
    "no .tmp file is left behind by the atomic write",
)

print("\n-- a session that does not exist --")
history, summary, compacted, path, resumed = lad.load_named_session(
    "never-saved", "qwen-op", False
)
check(
    (history, summary, compacted, resumed) == ([], "", 0, False),
    "a missing session yields empty state with resumed=False",
)

print("\n-- model-mismatch refusal --")
expect_valueerror(
    lambda: lad.load_named_session("roundtrip", "a-different-model", False),
    "refuses to load a session saved under another model",
)
history, _, _, _, _ = lad.load_named_session("roundtrip", "a-different-model", True)
check(
    history == HISTORY,
    "allow_model_mismatch=True loads it deliberately",
)

print("\n-- rejecting corrupt or unsupported session files --")
bad_dir = os.path.dirname(saved_path)
write(os.path.join(bad_dir, "notjson.json"), "{ this is not json")
expect_valueerror(
    lambda: lad.load_named_session("notjson", "qwen-op", False),
    "rejects a file that is not valid JSON",
)
write(
    os.path.join(bad_dir, "badschema.json"),
    json.dumps({
        "schema_version": 99,
        "model_alias": "qwen-op",          # matches, so mismatch is not the reason
        "conversation_history": HISTORY,   # valid, so history validation is not the reason
        "rolling_summary": "",
        "compacted_message_count": 0,
    }),
)
expect_valueerror(
    lambda: lad.load_named_session("badschema", "qwen-op", False),
    "rejects an unsupported schema_version",
)
for name, body, why in [
    # 42 rather than a string on purpose: a string is ITERABLE, so with the isinstance-list check
    # removed the loop would still reject it per-character and this test would pass for the wrong
    # reason (a mutation run caught exactly that). A non-iterable isolates the list check.
    ("histnotlist", {"conversation_history": 42}, "conversation_history is not a list"),
    ("histisstring", {"conversation_history": "nope"}, "conversation_history is a bare string"),
    ("turnnotdict", {"conversation_history": ["nope"]}, "a turn is not an object"),
    (
        "badrole",
        {"conversation_history": [{"role": "system", "content": "x"}]},
        "a turn has a role other than user/assistant",
    ),
    (
        "badcontent",
        {"conversation_history": [{"role": "user", "content": 42}]},
        "a turn's content is not a string",
    ),
]:
    doc = {"schema_version": 1, "model_alias": "qwen-op"}
    doc.update(body)
    write(os.path.join(bad_dir, name + ".json"), json.dumps(doc))
    expect_valueerror(
        lambda n=name: lad.load_named_session(n, "qwen-op", False),
        "rejects a session where %s" % why,
    )

print("\n-- read_files_context per-file cap --")
small = write(os.path.join(TMP_ROOT, "small.txt"), "x" * 100)
big = write(os.path.join(TMP_ROOT, "big.txt"), "y" * 500)

with contextlib.redirect_stderr(io.StringIO()):
    out = lad.read_files_context([small], max_file_chars=1000)
check(small in out and "x" * 100 in out, "attaches a file under the cap, with its path")

err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = lad.read_files_context([big], max_file_chars=100)
check(out == "", "an oversized file is NOT attached")
check("y" * 100 not in out, "oversized content is rejected, never truncated in silently")
check("--max-file-chars" in err.getvalue(), "explains the cap on stderr when it rejects")

with contextlib.redirect_stderr(io.StringIO()):
    out = lad.read_files_context([big], max_file_chars=0)
check("y" * 500 in out, "max_file_chars=0 disables the cap")

err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = lad.read_files_context([os.path.join(TMP_ROOT, "absent.txt"), small])
check("File not found" in err.getvalue(), "warns about a missing file")
check(small in out, "a missing file is skipped without dropping the good ones")
check(lad.read_files_context([]) == "", "no files yields an empty context")

print("\n-- read_conversation_input: plain, :paste/:end, appended :end --")


def feed(first, rest=""):
    """Drive read_conversation_input: `first` answers input(), `rest` is stdin."""
    real_stdin, real_input = sys.stdin, builtins.input
    sys.stdin = io.StringIO(rest)
    builtins.input = lambda _prompt="": first
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return lad.read_conversation_input()
    finally:
        sys.stdin, builtins.input = real_stdin, real_input


check(feed("just one line") == "just one line", "a normal line is returned as-is")
check(
    feed(":paste", "alpha\nbeta\n:end\n") == "alpha\nbeta",
    ":paste collects until :end on its own line",
)
check(
    feed(":paste", "alpha\nbeta:end\n") == "alpha\nbeta",
    "an :end appended to the final pasted line still terminates and keeps the text",
)
check(
    feed(":paste", "alpha\n:end\n") == "alpha",
    "a single pasted line is collected",
)
check(feed(":paste", ":end\n") == "", "an immediately-ended paste yields empty text")
check(
    feed("  :paste  ", "alpha\n:end\n") == "alpha",
    ":paste is recognised despite surrounding whitespace",
)
# NOTE: the paste still needs a real terminator afterwards -- ":end" in the MIDDLE of a line is
# content, so without the following ":end" line stdin is exhausted and EOFError is raised (which is
# correct behaviour, and is pinned separately below).
check(
    feed(":paste", "keep :end this\n:end\n") == "keep :end this",
    ":end in the middle of a line is content, not a terminator",
)
try:
    feed(":paste", "unterminated\n")
    check(False, "exhausted stdin during a paste should raise EOFError")
except EOFError:
    check(True, "exhausted stdin during a paste raises EOFError")

print("\n-- compact_history_if_needed early returns (no server involved) --")
long_hist = [
    {"role": "user", "content": "u" * 50},
    {"role": "assistant", "content": "a" * 50},
]
err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = lad.compact_history_if_needed(long_hist, "sum", 0, 8000, "m", 128)
check(out == (long_hist, "sum", 0), "max_chars=0 disables compaction entirely")
check(
    err.getvalue() == "",
    "max_chars=0 returns BEFORE the budget logic, so it warns about nothing",
)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = lad.compact_history_if_needed(long_hist, "sum", -1, 8000, "m", 128)
check(out == (long_hist, "sum", 0), "a negative max_chars disables compaction")
check(err.getvalue() == "", "a negative max_chars also returns before any warning")
out = lad.compact_history_if_needed(long_hist, "sum", 10_000_000, 8000, "m", 128)
check(out == (long_hist, "sum", 0), "history under budget is returned unchanged")

err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = lad.compact_history_if_needed(long_hist, "", 10, 8000, "m", 128)
check(
    out == (long_hist, "", 0),
    "with only one complete turn the newest turn is NEVER discarded",
)
check(
    "--max-history-chars" in err.getvalue(),
    "says why it could not compact instead of failing silently",
)

shutil.rmtree(TMP_ROOT, ignore_errors=True)
print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
