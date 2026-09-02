#!/usr/bin/env bash
# tests/test_version_consistency.sh — the release version number is written down in THREE places.
# This asserts they agree.
#
# Usage: bash tests/test_version_consistency.sh
#
# WHAT THIS PROTECTS. The plugin's version lives in three files that no single command updates:
#   1. .claude-plugin/plugin.json  — the manifest, and the only one the harness actually reads;
#   2. CHANGELOG.md                — the first NUMBERED "## [x.y.z]" heading (## [Unreleased] is skipped);
#   3. docs/ROADMAP.md             — the backtick-quoted version under "## Current released version".
#
# WHY IT EXISTS, with evidence. The roadmap line drifted from the manifest THREE times on a single
# day (2026-09-01): first at 0.13.5 vs 0.13.6, then again at 0.13.6 vs 0.13.7. The cause is
# structural rather than careless — two or three sessions bump the manifest and the changelog
# concurrently on different branches, and a hand-maintained third copy of the number cannot keep
# up with them. The roadmap's own warning ("if this disagrees with plugin.json, treat everything
# below as suspect") CAUGHT each drift, which is the argument for automating the check rather than
# deleting the warning.
#
# IT ALSO CATCHES THE SECOND, QUIETER DRIFT: a manifest bumped with NO changelog entry at all.
# That already happened — 0.13.6 bumped plugin.json and shipped no CHANGELOG entry until it was
# backfilled. No special case is needed for it: a missing entry means the top numbered heading is
# still the PREVIOUS version, so the comparison fails on its own.
#
# METHOD. Pure file reads: no network, no server, no sandbox, and nothing is written. The manifest
# is parsed as real JSON (never grepped for a version-shaped string, which would happily match a
# dependency's version), and the two Markdown files are parsed with anchored patterns so a
# version number quoted incidentally elsewhere in the prose cannot satisfy the check.
#
# A FAILURE PRINTS ALL THREE VALUES TOGETHER. Reporting only "mismatch" would leave the reader to
# go and look up which file is the stale one; printing the three side by side makes the fix obvious
# and, just as importantly, makes clear WHICH file is authoritative — the manifest always is.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

MANIFEST="$ROOT/.claude-plugin/plugin.json"
CHANGELOG="$ROOT/CHANGELOG.md"
ROADMAP="$ROOT/docs/ROADMAP.md"

pass=0
fail=0
ok()   { echo "✓ $1"; pass=$((pass + 1)); }
bad()  { echo "✗ $1" >&2; fail=$((fail + 1)); }

# --- extraction -------------------------------------------------------------
# Each extractor prints the version it found, or nothing at all if the file or the
# expected structure is missing. An empty result is always a failure, never a pass:
# a check that silently succeeds when it cannot find its input is worse than no check.

manifest_version() {
    [ -f "$MANIFEST" ] || return 0
    python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("version", ""))
except Exception:
    pass
' "$MANIFEST"
}

changelog_version() {
    [ -f "$CHANGELOG" ] || return 0
    # First heading of the form "## [x.y.z]"; "## [Unreleased]" does not match and is skipped.
    sed -n -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' "$CHANGELOG" | head -1
}

roadmap_version() {
    [ -f "$ROADMAP" ] || return 0
    # The backtick-quoted version on the first non-blank line after the heading.
    awk '
        /^## Current released version/ { seen = 1; next }
        seen && /`[0-9]+\.[0-9]+\.[0-9]+`/ {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/))
                print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$ROADMAP"
}

# --- the assertions ---------------------------------------------------------

mv_="$(manifest_version)"
cv_="$(changelog_version)"
rv_="$(roadmap_version)"

echo "version consistency:"
echo "  .claude-plugin/plugin.json : ${mv_:-<not found>}"
echo "  CHANGELOG.md (top entry)   : ${cv_:-<not found>}"
echo "  docs/ROADMAP.md            : ${rv_:-<not found>}"
echo

if [ -z "$mv_" ]; then
    bad "plugin.json: no version found — the manifest is the authoritative copy and must parse"
else
    ok "plugin.json declares version $mv_"
fi

if [ -z "$cv_" ]; then
    bad "CHANGELOG.md: no numbered '## [x.y.z]' heading found (only ## [Unreleased]?)"
elif [ "$cv_" != "$mv_" ]; then
    bad "CHANGELOG.md top entry is $cv_ but plugin.json says $mv_ — either the bump shipped without a changelog entry, or the entry was written for the wrong version"
else
    ok "CHANGELOG.md top entry matches the manifest ($cv_)"
fi

if [ -z "$rv_" ]; then
    bad "docs/ROADMAP.md: no backtick-quoted version under '## Current released version'"
elif [ "$rv_" != "$mv_" ]; then
    bad "docs/ROADMAP.md says $rv_ but plugin.json says $mv_ — the roadmap version line is stale, so treat the rest of that file as suspect until it is resynced"
else
    ok "docs/ROADMAP.md version line matches the manifest ($rv_)"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "✓ version consistency: $pass check(s) passed — all three copies agree on $mv_"
    exit 0
fi
echo "✗ version consistency: $fail of $((pass + fail)) check(s) FAILED" >&2
echo "  plugin.json=${mv_:-<none>}  CHANGELOG=${cv_:-<none>}  ROADMAP=${rv_:-<none>}" >&2
echo "  plugin.json is authoritative: bring the other two into line with it." >&2
exit 1
