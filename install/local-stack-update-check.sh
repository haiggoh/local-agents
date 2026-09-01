#!/usr/bin/env bash
# local-stack-update-check.sh — WEEKLY launchd check (NOT an auto-upgrade) for the local-inference
# Python backends. Notifies (macOS notification + log) if a newer release is on PyPI than what is
# installed. Upgrades stay MANUAL and SUPERVISED on purpose: the legacy venv is shared by the whole
# local stack and vllm-mlx carries local fork patches, and the Rapid environments are deliberately
# PINNED because the recorded cache/Metal measurements belong to a specific version. A blind
# auto-upgrade could break serving or silently invalidate that evidence. This job only SURFACES
# availability; a human/agent applies it at a safe point.
# Scheduled by ~/Library/LaunchAgents/com.haiggoh.local-stack-update-check.plist (weekly).
#
# TWO ENVIRONMENTS are checked (extended 2026-08-31):
#   ~/.local-llm                 the LEGACY vllm-mlx lane  -> mlx-vlm, mlx-lm
#   ~/.venvs/rapid-mlx-<newest>  the DEFAULT Rapid backend -> rapid-mlx, mlx, mlx-lm
# Rapid was previously unwatched entirely, which is why "who owns the update schedule" kept coming
# up: nothing was checking it. Watching it here is what makes keeping the pinned-venv install
# (rather than handing version control to `brew upgrade`) a maintained choice instead of a chore.
set -uo pipefail

VENV="$HOME/.local-llm/bin/python"
LOG="$HOME/.claude/logs/local-stack-update-check.log"
mkdir -p "$(dirname "$LOG")"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Newest Rapid venv by VERSION order, matching how local-agents' config-lib discovers it. `sort -V`
# is required, not cosmetic: a lexical sort ranks 0.9.14 above 0.13.2 and would report the wrong
# environment as current.
RAPID_VENV=""
for c in $(ls -d "$HOME"/.venvs/rapid-mlx-*/bin/python 2>/dev/null | sort -V -r); do
    [ -x "$c" ] && { RAPID_VENV="$c"; break; }
done

outdated=()
checked=()

# check_env <python> <label> <pkg>...  — append "<label>/<pkg> <inst>-><latest>" for each package
# whose PyPI version is newer than the installed one. A missing env or package is skipped, never
# reported as up-to-date: silence must not be mistaken for a passing check.
check_env() {
    local py="$1" label="$2"; shift 2
    [ -x "$py" ] || { echo "$(ts) SKIP: $label python not found ($py)" >> "$LOG"; return 0; }
    local pkg inst latest newer
    for pkg in "$@"; do
        inst=$("$py" -c "import importlib.metadata as m; print(m.version('$pkg'))" 2>/dev/null) || continue
        # curl (IPv4-friendly) not Python urllib — this network hangs on CloudFront IPv6 here (see memory).
        latest=$(curl -s --max-time 20 "https://pypi.org/pypi/$pkg/json" \
                 | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null) || continue
        [ -n "$latest" ] || continue
        checked+=("$label/$pkg")
        newer=$(python3 -c "
import re
def t(v): return tuple(int(x) for x in re.findall(r'\d+', v))
print('yes' if t('$latest') > t('$inst') else 'no')" 2>/dev/null)
        [ "$newer" = "yes" ] && outdated+=("$label/$pkg $inst->$latest")
    done
}

check_env "$VENV" legacy mlx-vlm mlx-lm
# rapid-mlx first: it is the DEFAULT backend now, so its release is the one that matters most.
# mlx is listed because it is the Metal layer the memory-ceiling evidence is attached to.
# Label with the venv DIRECTORY name, so the log says exactly which environment was inspected.
# That matters here: this reports the NEWEST installed Rapid env, which is not necessarily the one
# local-agents currently serves from (LA_RAPID_BIN may be pinned to an older, qualified version).
RAPID_LABEL="$(basename "$(dirname "$(dirname "${RAPID_VENV:-/none/none}")")")"
check_env "$RAPID_VENV" "$RAPID_LABEL" rapid-mlx mlx mlx-lm

if [ ${#outdated[@]} -gt 0 ]; then
    # Log the CHECKED set alongside the outdated one. Without it an OUTDATED line proves only
    # that SOMETHING was checked, so a silently skipped environment (missing venv, network
    # failure, renamed package) reads exactly like an environment that passed.
    echo "$(ts) OUTDATED: ${outdated[*]}  [checked: ${checked[*]:-nothing}]" >> "$LOG"
    osascript -e "display notification \"${outdated[*]} — upgrade manually/supervised (side-by-side venv, keep the pinned one).\" with title \"Local-stack update available\"" 2>/dev/null || true
else
    echo "$(ts) up-to-date (checked: ${checked[*]:-nothing})" >> "$LOG"
fi
exit 0
