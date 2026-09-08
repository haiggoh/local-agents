# Errata

Corrections to statements in this repository's history that cannot be edited in place.

A pushed commit message cannot be corrected without rewriting history, and rewriting a
pushed branch that another agent may be working on would clobber live work. So a wrong
claim in a commit message is corrected here instead, and the commit is left alone.

## `5c6633b` — the concurrent 0.13.6 author was a CLOUD session, not a local one

`5c6633b` ("docs: give 0.13.6 a changelog entry and resync the roadmap version line")
states:

> Provenance worth recording: 988e4d8 was made by a CONCURRENT local session working in
> this same worktree

**That is wrong.** `988e4d8` was made by a concurrent **cloud** session. Confirmed by the
user on 2026-09-01. Supporting evidence: no local session was launched that day —
`~/.claude/logs/local-agents-sessions.log` has no entry for the date — and the `:8000`
server had been up since 2026-08-30, so its presence indicated nothing about that commit.

**What that commit still gets right:** `988e4d8` did sweep up an uncommitted
`docs/ROADMAP.md` edit belonging to another session, verified by diffing its roadmap hunks
against the text that session had written. Nothing was lost. Only the "local" label is wrong.

**The lesson, which is the durable part.** Do not attribute a concurrent change to a
specific client unless something in the record actually identifies it. Git identity and the
`Co-Authored-By` footer are shared across all of these sessions, so neither distinguishes
local from cloud. The only reliable local markers — a launch entry in
`local-agents-sessions.log`, and a `localhost` `ANTHROPIC_BASE_URL` — live in the session,
not in the commit. Attribution was not determinable from the record here; what settled it
was asking the human, which is worth reaching for immediately rather than inferring from
commit style or message quality.

A related correction to the same day's reading: the other session did **not** commit onto
`main` and then re-home. The reflog shows it checked out a new branch
`fix/offload-rule-falsifiable` from `main` first, committed `988e4d8` there, then reset to
`HEAD~1` and re-committed as `94b5ab6`. `main` was never polluted.
