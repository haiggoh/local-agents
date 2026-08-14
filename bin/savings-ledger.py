#!/usr/bin/env python3
"""Local-offload savings ledger — what did running this locally avoid paying for?

Every local dispatch is work that would otherwise have gone to a metered cloud model.
This records each one as an append-only event, prices it against a named cloud rate, and
derives a small rollup a status line can read without parsing a growing log.

    savings-ledger.py record --model qwen --in 9123 --out 412 [--priced-against claude-opus-5]
    savings-ledger.py rollup                     # regenerate the derived rollup from events
    savings-ledger.py report [--today|--week|--month|--since YYYY-MM-DD] [--json]
    savings-ledger.py rates                      # print the rate table and its as-of date

Store (outside this plugin, so updates never touch your data; override the directory with
$LOCAL_AGENTS_LEDGER_DIR):

    ~/.claude/local-agents/savings.jsonl   append-only event log, one JSON object per line
    ~/.claude/local-agents/rollup.json     DERIVED — regenerate it, never hand-edit it

THE CENTRAL HONESTY RULE: a model this table doesn't know is priced as **null**, never as
zero. A zero saving is a claim that the work was free; null says "not priced". Silently
pricing an unknown model at 0.00 is a real bug that shipped in an earlier tool here — the
figure looked plausible and understated savings indefinitely, because nothing distinguishes
"saved nothing" from "never valued". `report` counts unpriced events out loud for the same
reason.
"""
import argparse
import datetime as dt
import json
import os
import sys

# --- Cloud rate table ------------------------------------------------------------------
# USD per MILLION tokens, standard (non-batch, non-cached) rates. RATES_AS_OF is part of
# the data, not a comment: a rate table without a date silently ages into wrong numbers,
# and every figure this tool prints is only as good as this date.
#
# Verify against the vendor's current pricing page before trusting a large total, and pass
# --rates-file to override the whole table rather than editing a published plugin.
RATES_AS_OF = "2026-06-24"
DEFAULT_RATES = {
    "claude-fable-5":   {"in": 10.0, "out": 50.0},
    "claude-mythos-5":  {"in": 10.0, "out": 50.0},
    "claude-opus-5":    {"in": 5.0,  "out": 25.0},
    "claude-opus-4-8":  {"in": 5.0,  "out": 25.0},
    "claude-opus-4-7":  {"in": 5.0,  "out": 25.0},
    "claude-opus-4-6":  {"in": 5.0,  "out": 25.0},
    "claude-sonnet-5":  {"in": 3.0,  "out": 15.0},
    "claude-sonnet-4-6": {"in": 3.0, "out": 15.0},
    "claude-haiku-4-5": {"in": 1.0,  "out": 5.0},
}

DEFAULT_PRICED_AGAINST = "claude-opus-5"


def ledger_dir():
    d = os.environ.get("LOCAL_AGENTS_LEDGER_DIR")
    if not d:
        d = os.path.join(os.path.expanduser("~"), ".claude", "local-agents")
    return d


def events_path():
    return os.path.join(ledger_dir(), "savings.jsonl")


def rollup_path():
    return os.path.join(ledger_dir(), "rollup.json")


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


# --- Model-id normalization ------------------------------------------------------------
# The reason this exists: a cloud model id in the wild is rarely the bare catalog name. It
# arrives with a context-window suffix (`claude-opus-5[1m]`), a provider prefix
# (`anthropic.claude-opus-5` on one hosted platform), a deployment suffix (`-fast`), or a
# dated snapshot (`claude-haiku-4-5-20251001`). A table keyed on bare names misses every
# one of those — and combined with a zero default, that is precisely how an earlier tool
# came to price real spend at 0.00. Normalize first, then look up.
def normalize_model(model):
    """Reduce a model id to the catalog name this table is keyed on."""
    if not model:
        return ""
    m = str(model).strip().lower()
    if "/" in m:                      # some gateways prefix with a route or vendor path
        m = m.rsplit("/", 1)[-1]
    for prefix in ("anthropic.", "anthropic/"):
        if m.startswith(prefix):
            m = m[len(prefix):]
    if "[" in m:                      # context-window suffix, e.g. claude-opus-5[1m]
        m = m.split("[", 1)[0]
    for suffix in ("-fast", "-latest"):
        if m.endswith(suffix):
            m = m[: -len(suffix)]
    # Dated snapshot: claude-haiku-4-5-20251001 -> claude-haiku-4-5
    parts = m.rsplit("-", 1)
    if len(parts) == 2 and len(parts[1]) == 8 and parts[1].isdigit():
        m = parts[0]
    return m.strip("-")


def load_rates(rates_file=None):
    """Return (rates, as_of, source_label). A --rates-file wins over the built-in table."""
    if rates_file:
        with open(rates_file, encoding="utf-8") as fh:
            data = json.load(fh)
        rates = data.get("rates", data)
        as_of = data.get("as_of", "unknown")
        return rates, as_of, "file:%s@%s" % (os.path.basename(rates_file), as_of)
    return DEFAULT_RATES, RATES_AS_OF, "builtin@%s" % RATES_AS_OF


def price(model, input_tokens, output_tokens, rates, source_label):
    """Value the counterfactual: what this many tokens would have cost on `model`.

    Returns (saved_usd, rate_in, rate_out, rate_source). saved_usd is None — not 0.0 —
    when the model isn't in the table, and rate_source says so, so a reader can tell an
    unpriced event from a genuinely free one.
    """
    entry = rates.get(normalize_model(model))
    if not entry:
        return None, None, None, "unknown"
    rate_in, rate_out = float(entry["in"]), float(entry["out"])
    saved = (input_tokens / 1_000_000.0) * rate_in + (output_tokens / 1_000_000.0) * rate_out
    return round(saved, 6), rate_in, rate_out, source_label


def append_event(event):
    os.makedirs(ledger_dir(), exist_ok=True)
    # Append-only: one line per dispatch, never rewritten. Concurrent local sessions each
    # append, and a single write() of one short line is what keeps that safe without a lock.
    with open(events_path(), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, ensure_ascii=False) + "\n")


def read_events():
    """Every readable event, oldest first. A corrupt line is skipped, not fatal — a
    half-written line from a killed process must not make the whole ledger unreadable."""
    path = events_path()
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                out.append(obj)
    return out


def utc_day(event):
    ts = event.get("ts") or ""
    return ts[:10]          # ISO-8601 is lexically sortable; the date is the first 10 chars


def build_rollup(events):
    """Derive the per-(session, UTC day) rollup. Purely a function of the events — there is
    no incremental path, deliberately: a hand-maintained rollup drifts from its log and
    then you have two numbers and no way to tell which lied."""
    groups = {}
    for e in events:
        key = "%s\t%s" % (e.get("session") or "unknown", utc_day(e))
        g = groups.setdefault(key, {
            "session": e.get("session") or "unknown",
            "day": utc_day(e),
            "events": 0, "input_tokens": 0, "output_tokens": 0,
            "saved_usd": 0.0, "unpriced_events": 0, "output_only_events": 0,
        })
        g["events"] += 1
        g["input_tokens"] += int(e.get("input_tokens") or 0)
        g["output_tokens"] += int(e.get("output_tokens") or 0)
        if e.get("input_tokens_source") == "unavailable":
            g["output_only_events"] += 1
        if e.get("saved_usd") is None:
            g["unpriced_events"] += 1
        else:
            g["saved_usd"] += float(e["saved_usd"])
    for g in groups.values():
        g["saved_usd"] = round(g["saved_usd"], 6)
    rows = sorted(groups.values(), key=lambda g: (g["day"], g["session"]))
    return {
        "contract": 1,
        "generated": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_events": len(events),   # staleness check: compare to the log's line count
        "rows": rows,
    }


def write_rollup(rollup):
    os.makedirs(ledger_dir(), exist_ok=True)
    tmp = rollup_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rollup, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, rollup_path())      # atomic: a reader never sees a half-written rollup


def window_start(args, today):
    if args.since:
        return args.since
    if args.week:
        return (today - dt.timedelta(days=6)).strftime("%Y-%m-%d")
    if args.month:
        return (today - dt.timedelta(days=29)).strftime("%Y-%m-%d")
    if args.today:
        return today.strftime("%Y-%m-%d")
    return None


def main(argv=None):
    p = argparse.ArgumentParser(prog="savings-ledger",
                                description="Track what local offload avoided paying for.")
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("record", help="append one dispatch event")
    pr.add_argument("--model", required=True, help="the LOCAL model that did the work")
    pr.add_argument("--in", dest="input_tokens", type=int, required=True)
    pr.add_argument("--out", dest="output_tokens", type=int, required=True)
    pr.add_argument("--priced-against", default=DEFAULT_PRICED_AGAINST,
                    help="cloud model whose rate values the counterfactual (default: %s)"
                         % DEFAULT_PRICED_AGAINST)
    pr.add_argument("--session", default=os.environ.get("CLAUDE_CODE_SESSION_ID"),
                    help="session id (default: $CLAUDE_CODE_SESSION_ID)")
    pr.add_argument("--role", default=None, help="the role this dispatch filled")
    pr.add_argument("--tool", default="unknown", help="which dispatch path recorded this")
    pr.add_argument("--input-tokens-source", choices=("server", "unavailable"),
                    default="server",
                    help="'unavailable' when the server reported no usable prompt-token "
                         "count; the saving is then understated and says so")
    pr.add_argument("--input-chars", type=int, default=None,
                    help="prompt size in characters — a FACT to keep when the token count "
                         "is unavailable, so the event can be priced properly later")
    pr.add_argument("--port", type=int, default=None)
    pr.add_argument("--rates-file", default=None)
    pr.add_argument("--quiet", action="store_true")

    sub.add_parser("rollup", help="regenerate the derived rollup from the event log")

    pp = sub.add_parser("report", help="totals over a period")
    pp.add_argument("--today", action="store_true")
    pp.add_argument("--week", action="store_true", help="last 7 days including today")
    pp.add_argument("--month", action="store_true", help="last 30 days including today")
    pp.add_argument("--since", default=None, metavar="YYYY-MM-DD")
    pp.add_argument("--json", action="store_true")

    pt = sub.add_parser("rates", help="print the rate table and its as-of date")
    pt.add_argument("--rates-file", default=None)
    pt.add_argument("--json", action="store_true")
    args = p.parse_args(argv)

    if args.cmd == "record":
        rates, _as_of, source_label = load_rates(args.rates_file)
        saved, rate_in, rate_out, rate_source = price(
            args.priced_against, args.input_tokens, args.output_tokens, rates, source_label)
        event = {
            "ts": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session": args.session or None,
            "model": args.model,
            "role": args.role,
            "input_tokens": args.input_tokens,
            "output_tokens": args.output_tokens,
            "priced_against": normalize_model(args.priced_against) or None,
            "rate_in": rate_in,
            "rate_out": rate_out,
            "rate_source": rate_source,
            "saved_usd": saved,
            "tool": args.tool,
            "input_tokens_source": args.input_tokens_source,
        }
        if args.port is not None:
            event["port"] = args.port
        if args.input_chars is not None:
            event["input_chars"] = args.input_chars
        append_event(event)
        if not args.quiet:
            if saved is None:
                print("recorded (UNPRICED — %r is not in the rate table, so this event "
                      "counts tokens but no saving)" % args.priced_against)
            else:
                print("recorded: %d in / %d out on %s -> $%.4f not spent on %s"
                      % (args.input_tokens, args.output_tokens, args.model, saved,
                         event["priced_against"]))
            if args.input_tokens_source == "unavailable":
                print("  ⚠ no prompt-token count from the server — this saving counts the "
                      "OUTPUT side only and is understated")
        return 0

    if args.cmd == "rollup":
        rollup = build_rollup(read_events())
        write_rollup(rollup)
        print("rollup: %d row(s) from %d event(s) -> %s"
              % (len(rollup["rows"]), rollup["source_events"], rollup_path()))
        return 0

    if args.cmd == "report":
        events = read_events()
        today = now_utc().date()
        start = window_start(args, today)
        label = ("since %s" % start) if start else "all time"
        if start:
            events = [e for e in events if utc_day(e) >= start]
        total = sum(e["saved_usd"] for e in events if e.get("saved_usd") is not None)
        unpriced = sum(1 for e in events if e.get("saved_usd") is None)
        output_only = sum(1 for e in events
                          if e.get("input_tokens_source") == "unavailable")
        unmeasured_chars = sum(int(e.get("input_chars") or 0) for e in events
                               if e.get("input_tokens_source") == "unavailable")
        tin = sum(int(e.get("input_tokens") or 0) for e in events)
        tout = sum(int(e.get("output_tokens") or 0) for e in events)
        if args.json:
            print(json.dumps({
                "contract": 1, "period": label, "since": start,
                "events": len(events), "unpriced_events": unpriced,
                "output_only_events": output_only,
                "unmeasured_input_chars": unmeasured_chars,
                "input_tokens": tin, "output_tokens": tout,
                "saved_usd": round(total, 6),
            }, indent=2))
            return 0
        if not events:
            print("local offload (%s): no dispatches recorded" % label)
            return 0
        print("local offload (%s): %d dispatch(es), %s in / %s out, saved $%.2f"
              % (label, len(events), f"{tin:,}", f"{tout:,}", total))
        if unpriced:
            # Stated, not swallowed: the total is a floor when some events aren't priced.
            print("  ⚠ %d event(s) unpriced (model not in the rate table) — the saving "
                  "above is a floor, not the whole picture" % unpriced)
        if output_only:
            # This is the big one in practice. Local offload is characteristically
            # large-corpus-in / small-answer-out, so a server that reports no prompt-token
            # count strips out most of the value. Saying "saved $0.00" when a 20k-character
            # prompt was processed locally would be the same class of lie as pricing an
            # unknown model at zero — so the shortfall is named, with the raw character
            # count kept on the events so they can be repriced once a count is available.
            extra = (" covering %s unmeasured prompt characters" % f"{unmeasured_chars:,}"
                     ) if unmeasured_chars else ""
            print("  ⚠ %d event(s) counted the OUTPUT side only%s — the server reported no "
                  "prompt-token count, so the real saving is materially higher"
                  % (output_only, extra))
        return 0

    if args.cmd == "rates":
        rates, as_of, _ = load_rates(args.rates_file)
        if args.json:
            print(json.dumps({"as_of": as_of, "rates": rates}, indent=2))
            return 0
        print("cloud rates (USD per million tokens), as of %s — verify before trusting a "
              "large total:" % as_of)
        for name in sorted(rates):
            print("  %-20s in $%-7.2f out $%-7.2f" % (name, rates[name]["in"], rates[name]["out"]))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
