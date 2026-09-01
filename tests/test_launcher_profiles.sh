#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT/bin/launch-claude-agent.sh"
CONFIG="$ROOT/config/config.example.sh"
PROMPT="$ROOT/config/local-agent-system-prompt.txt"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

bash -n "$LAUNCHER"
bash -n "$CONFIG"

for expected in \
    LA_AGENT_PROMPT_FILE \
    LA_CLAUDE_SETTINGS \
    LA_CLAUDE_TOOLS \
    LA_AUTO_COMPACT_WINDOW
do
    grep -q "$expected" "$LAUNCHER" ||
        fail "$expected missing from launcher"
    grep -q "$expected" "$CONFIG" ||
        fail "$expected missing from config.example.sh"
done

grep -Fq '"${CLAUDE_EXTRA_ARGS[@]}"' "$LAUNCHER" ||
    fail "final invocation does not preserve argument boundaries"

grep -Fq -- '--settings "$LA_CLAUDE_SETTINGS"' "$LAUNCHER" ||
    fail "settings argument is not quoted"

grep -Fq -- '--tools "$LA_CLAUDE_TOOLS"' "$LAUNCHER" ||
    fail "tools argument is not quoted"

grep -Fq -- '--autocompact "$LA_AUTO_COMPACT_WINDOW"' "$LAUNCHER" ||
    fail "autocompact argument is not quoted"

grep -Fq 'LA_CLAUDE_TOOLS and LA_DENY_TOOLS' "$LAUNCHER" ||
    fail "allowed/denied tool conflict check missing"

python3 - "$PROMPT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

expected = {
    "__LA_MODEL_ALIAS__",
    "__LA_MODEL_SPOOF__",
    "__LA_BACKEND__",
    "__LA_CURRENT_PORT__",
    "__LA_PORT_START__",
    "__LA_PORT_MAX__",
    "__LA_HOTSWAP_PATH__",
}

found = set(re.findall(r"__LA_[A-Z0-9_]+__", text))
if found != expected:
    raise SystemExit(
        f"prompt placeholders differ: expected={sorted(expected)} found={sorted(found)}"
    )

for placeholder in expected:
    if text.count(placeholder) != 1:
        raise SystemExit(
            f"placeholder must occur exactly once: {placeholder}"
        )

size = len(text.encode("utf-8"))
if size > 1600:
    raise SystemExit(f"prompt unexpectedly large: {size} bytes")

required_phrases = (
    "LOCAL CLAUDE CODE SESSION",
    "zero gateway cost",
    "Protect the runtime",
    "stop and ask",
)

for phrase in required_phrases:
    if phrase not in text:
        raise SystemExit(f"required prompt phrase missing: {phrase}")

print(f"prompt template: PASS ({size} bytes)")
PY

if grep -Fq 'You are an autonomous AI agent operating directly in a CLI' "$LAUNCHER"; then
    fail "old embedded prompt still present"
fi

printf 'launcher profile controls: PASS\n'
