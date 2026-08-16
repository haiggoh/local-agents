#!/usr/bin/env python3
"""Framework-free tests for the pure helpers in bin/local-agent-dispatch.py.

Usage: python3 tests/test_local_agent_dispatch.py

Scope is deliberately narrow: only functions that are pure and cheap, so this
suite stays fast and never needs a model server. Session save/load, file-context
reading and the :paste/:end conversation collector need a tmpdir and belong in a
separate follow-up patch; live-model behaviour stays out of this tier entirely.

Importing the dispatcher by path is safe: __main__ is guarded, and the only
os.makedirs call lives inside save_named_session rather than at module level.
"""
import contextlib
import importlib.util
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "local-agent-dispatch.py")
spec = importlib.util.spec_from_file_location("lad", SCRIPT)
lad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lad)

passed = failed = 0


def check(cond, label):
    global passed, failed
    if cond:
        passed += 1
        print("  PASS:", label)
    else:
        failed += 1
        print("  FAIL:", label)


@contextlib.contextmanager
def quiet_stderr():
    """normalize_user_input reports removals on stderr; keep test output clean."""
    saved, sys.stderr = sys.stderr, io.StringIO()
    try:
        yield sys.stderr
    finally:
        sys.stderr = saved


print("== normalize_user_input: strip pasted prompt markers, but only leading ones ==")
# The point of the function is that pasting the terminal's own "You>" prompt back
# into a turn should not become part of the question, while a "You>" that appears
# inside quoted text or code is content and must survive untouched.
for raw, want in [
    ("You> explain this", "explain this"),
    ("You> You> explain this", "explain this"),          # the docstring's own example
    ("You>You>You>stacked", "stacked"),                  # no spaces between markers
    ("  \tYou>  spaced out", "spaced out"),              # leading blanks are consumed
    ("you> lowercase", "lowercase"),                     # match is case-insensitive
    ("YOU> shouting", "shouting"),
    ("YoU> mixed", "mixed"),
    ("explain You> this", "explain You> this"),           # non-leading: preserved
    ("no marker at all", "no marker at all"),
    ("> not a marker", "> not a marker"),
    ("Your> not a marker either", "Your> not a marker either"),
]:
    got = None
    with quiet_stderr():
        got = lad.normalize_user_input(raw)
    check(got == want, "%r -> %r" % (raw, want) + ("" if got == want else " (got %r)" % got))

with quiet_stderr():
    check(lad.normalize_user_input("You>") == "", "a bare marker collapses to empty string")
    # No re.MULTILINE, so the match is anchored to the start of the whole string and
    # the run of markers ends at the newline rather than eating it.
    check(lad.normalize_user_input("You>\nhello") == "\nhello",
          "the marker run stops at a newline and does not consume it")
    check(lad.normalize_user_input("line one\nYou> line two") == "line one\nYou> line two",
          "a marker on a later line is content, not a prompt (no MULTILINE)")
    check(lad.normalize_user_input("") == "", "empty input is returned unchanged")

print("== normalize_user_input: it announces removals, and stays silent otherwise ==")
with quiet_stderr() as err:
    lad.normalize_user_input("You> stripped")
    check("You>" in err.getvalue(), "a removal is reported on stderr")
with quiet_stderr() as err:
    lad.normalize_user_input("nothing to strip")
    check(err.getvalue() == "", "a no-op says nothing at all")

print("== model_display_label: first segment before - or _ ==")
for raw, want in [
    ("qwen-3.6-operator", "qwen"),
    ("deepseek-r1-architect", "deepseek"),
    ("deepseek_r1_architect", "deepseek"),   # underscore separates too
    ("llama-scout", "llama"),
    ("devstral", "devstral"),                # no separator: whole alias
    ("  qwen-3.6-operator  ", "qwen"),       # surrounding blanks ignored
    ("qwen3.6", "qwen3.6"),                  # a dot is NOT a separator
]:
    got = lad.model_display_label(raw)
    check(got == want, "%r -> %r" % (raw, want) + ("" if got == want else " (got %r)" % got))

# Documenting a real quirk rather than asserting an ideal: when the alias starts with a
# separator the first segment is empty, so the function falls back to `model_alias` --
# the ORIGINAL argument, which has not been stripped. Pinning it means a future
# refactor cannot change it silently.
check(lad.model_display_label("-qwen") == "-qwen",
      "a leading separator falls back to the full alias")
check(lad.model_display_label("  -qwen  ") == "  -qwen  ",
      "and that fallback returns the UNSTRIPPED original (quirk, pinned deliberately)")
check(lad.model_display_label("") == "", "empty alias yields empty label")

print("== validate_session_name: accepts portable names ==")
for good in [
    "a",                        # single char is the documented minimum
    "1",
    "session",
    "my.session_name-2",
    "A" + "b" * 79,             # 80 chars is the documented maximum
]:
    try:
        check(lad.validate_session_name(good) == good, "accepts %r" % (good[:24],))
    except ValueError as exc:
        check(False, "accepts %r (raised %s)" % (good[:24], exc))

print("== validate_session_name: rejects paths, traversal and stray characters ==")
for bad, why in [
    ("", "empty"),
    (".hidden", "leading dot"),
    ("-lead", "leading hyphen"),
    ("_lead", "leading underscore"),
    ("..", "bare traversal"),
    ("../../etc/passwd", "traversal with separators"),
    ("a/b", "forward slash"),
    ("/absolute", "absolute path"),
    ("a\\b", "backslash"),
    ("a b", "space"),
    ("a\nb", "embedded newline"),
    ("ok\n", "trailing newline"),
    ("a:b", "colon"),
    ("a*", "glob character"),
    ("A" + "b" * 80, "81 characters, one over the limit"),
]:
    try:
        lad.validate_session_name(bad)
        check(False, "rejects %s (%r) -- but it was accepted" % (why, bad[:24]))
    except ValueError:
        check(True, "rejects %s" % why)

print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
