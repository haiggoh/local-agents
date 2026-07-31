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
block="$B
alias local-menu=\"$BIN/csl\"
alias local-operator=\"$BIN/launch-claude-agent.sh qwen-3.6-operator\"
alias local-fast=\"$BIN/launch-claude-agent.sh qwen-3.6-operator medium\"
alias local-xhigh=\"$BIN/launch-claude-agent.sh qwen-3.6-operator xhigh\"
alias local-thinking=\"$BIN/launch-claude-agent.sh qwen-3.6-thinking\"
alias local-architect=\"$BIN/launch-claude-agent.sh deepseek-r1-architect\"
alias local-scout=\"$BIN/launch-claude-agent.sh llama-scout\"
alias local-window=\"$BIN/new-local-window.sh\"
alias local-logs=\"tail -f \$HOME/.claude/logs/vllm_*.log\"
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
echo "Aliases: local-menu (selector) · local-operator/fast/xhigh · local-thinking · local-architect · local-scout · local-window <alias> (new independent window) · local-logs"
