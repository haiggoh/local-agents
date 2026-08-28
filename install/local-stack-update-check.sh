#!/usr/bin/env bash
# local-stack-update-check.sh — WEEKLY launchd check (NOT an auto-upgrade) for the local-inference
# Python backends in ~/.local-llm. Notifies (macOS notification + log) if a newer mlx-vlm / mlx-lm is
# on PyPI than what's installed. Upgrades stay MANUAL and SUPERVISED on purpose: the venv is shared by
# the whole local stack and vllm-mlx carries local fork patches, so a blind auto-upgrade could break
# serving. This job only SURFACES availability; a human/agent applies it at a safe point.
# Scheduled by ~/Library/LaunchAgents/com.haiggoh.local-stack-update-check.plist (weekly).
set -uo pipefail

VENV="$HOME/.local-llm/bin/python"
LOG="$HOME/.claude/logs/local-stack-update-check.log"
mkdir -p "$(dirname "$LOG")"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

[ -x "$VENV" ] || { echo "$(ts) SKIP: venv python not found ($VENV)" >> "$LOG"; exit 0; }

outdated=()
for pkg in mlx-vlm mlx-lm; do
    inst=$("$VENV" -c "import importlib.metadata as m; print(m.version('$pkg'))" 2>/dev/null) || continue
    # curl (IPv4-friendly) not Python urllib — this network hangs on CloudFront IPv6 here (see memory).
    latest=$(curl -s --max-time 20 "https://pypi.org/pypi/$pkg/json" \
             | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null) || continue
    [ -n "$latest" ] || continue
    newer=$(python3 -c "
import re
def t(v): return tuple(int(x) for x in re.findall(r'\d+', v))
print('yes' if t('$latest') > t('$inst') else 'no')" 2>/dev/null)
    [ "$newer" = "yes" ] && outdated+=("$pkg $inst->$latest")
done

if [ ${#outdated[@]} -gt 0 ]; then
    echo "$(ts) OUTDATED: ${outdated[*]}" >> "$LOG"
    osascript -e "display notification \"${outdated[*]} — upgrade manually/supervised (shared venv).\" with title \"Local-stack update available\"" 2>/dev/null || true
else
    echo "$(ts) up-to-date (mlx-vlm, mlx-lm)" >> "$LOG"
fi
exit 0
