#!/usr/bin/env bash
# setup-shortcuts.sh — OPTIONAL convenience installer (idempotent, safe to re-run).
#
# Sets up two conveniences and nothing else:
#   1. `csl` (the session selector) on your PATH via a symlink in ~/.local/bin
#   2. `local-*` shell aliases in your shell rc, inside a clearly-fenced block
#
# It does NOT modify your Claude Code settings, download models, or touch the backend. Re-run it
# after moving this repo (it repoints the symlink and rewrites the fenced alias block in place).
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

# 1. csl on PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN/csl" "$HOME/.local/bin/csl"
echo "✓ csl -> ~/.local/bin/csl"
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) echo "  ⚠ add ~/.local/bin to your PATH to use 'csl' directly";; esac

# 2. shell alias block (zsh or bash)
RCFILE="$HOME/.zshrc"; [ "${SHELL##*/}" = "bash" ] && RCFILE="$HOME/.bashrc"
B="# >>> local-agents aliases (managed by setup-shortcuts.sh) >>>"
E="# <<< local-agents aliases <<<"

# The aliases name ROLES, not models. A hardcoded model name goes stale SILENTLY — the alias keeps
# launching successfully, just the wrong (older) model, with nothing to signal the drift. A role is
# resolved against the on-disk role bindings at invocation time (la_resolve_target), so the roster
# can move without this block needing to be regenerated. Effort variants stay explicit because
# effort is the one lever that is genuinely a per-invocation choice, not a roster fact.
block="$B
# Sessions — <role> is resolved to whichever model fills it on disk right now.
alias local-menu=\"$BIN/csl\"                              # numbered picker (everything, incl. effort)
alias local-operator=\"$BIN/launch-claude-agent.sh operator\"
alias local-fast=\"$BIN/launch-claude-agent.sh operator medium\"
alias local-xhigh=\"$BIN/launch-claude-agent.sh operator xhigh\"
alias local-thinking=\"$BIN/launch-claude-agent.sh reasoner\"
alias local-validator=\"$BIN/launch-claude-agent.sh validator\"
alias local-window=\"$BIN/new-local-window.sh\"             # independent Terminal window
# Dispatch — stateless one-shot prompts (the cheap, preferred path).
alias local-dispatch=\"$BIN/local-agent-dispatch.py\"
# Introspection — what fills each role, what is on disk, what is running.
alias local-roles=\"$BIN/la-roles.sh\"
alias local-disk=\"$BIN/la-disk-inventory.sh\"
alias local-logs=\"tail -f \$HOME/.claude/logs/*_[0-9][0-9][0-9][0-9].log\"  # vllm_/rapid_auto_/omlx_
$E"

touch "$RCFILE"
# Remove any prior managed block IN PLACE (preserve file mode/inode — don't recreate at umask).
if grep -qF "$B" "$RCFILE"; then
  tmp="$(mktemp)"
  awk -v b="$B" -v e="$E" 'BEGIN{s=0} $0==b{s=1} s==0{print} $0==e{s=0}' "$RCFILE" > "$tmp"
  cat "$tmp" > "$RCFILE"; rm -f "$tmp"
fi
printf '\n%s\n' "$block" >> "$RCFILE"
echo "✓ local-* aliases written to $RCFILE (fenced, idempotent)."
echo "  open a new shell or: source $RCFILE"
echo
echo "Sessions:  local-menu (picker) · local-operator / local-fast / local-xhigh · local-thinking · local-validator · local-window <target>"
echo "Dispatch:  local-dispatch --model <role|alias> --prompt ..."
echo "Inspect:   local-roles (who fills each role) · local-disk · local-logs"
echo
echo "The session aliases name ROLES, not models: they resolve to whatever is on disk now, so they"
echo "do not go stale when the roster changes. Pass an explicit alias for a specific model."
