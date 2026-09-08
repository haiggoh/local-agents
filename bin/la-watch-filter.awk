# Stream filter for local-watch.sh watcher windows.
#
# Three jobs, all aimed at one goal: a human reading a watcher window should see EVENTS, not
# logging furniture. Kept as its own file rather than inlined in _health_cmd because that string
# is printf'd into a shell command and then escaped again into osascript -- a nested awk program
# there would be unreadable and unquotable.
#
#  1. Strip the `INFO:module.path:` / `WARNING:` prefix. It is constant filler; the module name
#     tells a human nothing the message text does not.
#  2. Print the per-request banner ONCE. model / max_tokens / stream are FIXED for a session, so
#     repeating them every turn is noise. Later turns get a short "turn N" marker instead.
#  3. Collapse consecutive near-identical lines into one line plus a repeat count, comparing with
#     digits masked so that counters and timings still count as "the same line".
#
# Line-buffered: every print is followed by fflush(), or a `tail -f` pipeline would show nothing
# until the block filled.
{
  line = $0

  # 1. Drop the logger prefix.
  sub(/^(INFO|WARNING|ERROR|DEBUG|CRITICAL):[A-Za-z0-9_.]*:?[ ]*/, "", line)
  if (line == "") next

  # 2. The [REQUEST] banner: full detail on the first turn, a bare turn counter after that.
  if (line ~ /\[REQUEST\]/) {
    turn++
    flush_pending()
    if (turn == 1) { emit(line "   (model/max_tokens/stream are fixed for this session)") }
    else           { emit("[REQUEST] turn " turn) }
    next
  }

  # 3. Collapse consecutive repeats, ignoring digits so counters/timings still match.
  key = line
  gsub(/[0-9]+/, "#", key)
  if (key == last_key) { reps++; next }
  flush_pending()
  emit(line)
  last_key = key; last_line = line; reps = 0
}

function flush_pending() {
  if (reps > 0) { emit("  ... last line repeated " reps " more time" (reps == 1 ? "" : "s")) ; reps = 0 }
}
function emit(s) { print s; fflush() }
END { flush_pending() }
