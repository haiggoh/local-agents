#!/usr/bin/env bash
# launch-copilot-agent.sh — start a Copilot CLI session driven by a LOCAL MLX model (BYOK)
# Usage: launch-copilot-agent.sh <alias>
# Example: launch-copilot-agent.sh qwen-3.6-operator
#
# There is deliberately NO effort argument, unlike launch-claude-agent.sh. This script
# previously accepted a second "[effort]" parameter, assigned it, and then never used it —
# so an effort passed here was silently discarded. Copilot CLI exposes no equivalent
# knob to map it onto, so the parameter was removed rather than faked. If Copilot ever
# gains one, wire it through here instead of just re-declaring the variable.
set -uo pipefail
_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
LAUNCH_DIR="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$LAUNCH_DIR/../config/config-lib.sh"
la_load_config || exit 1

MODEL_ALIAS="${1:-}"
# Say so rather than ignoring it, in case someone carries the habit over from
# launch-claude-agent.sh, which does take an effort override. Checked before the alias
# lookup so the message appears whether or not the alias itself was valid.
if [ -n "${2:-}" ]; then
  echo "⚠️  Ignoring extra argument '$2': this launcher takes no effort parameter." >&2
fi
if [ -z "$MODEL_ALIAS" ] || ! la_lookup "$MODEL_ALIAS"; then
  echo "Usage: $0 <alias>"; echo "Registered aliases:"; la_aliases_help
  echo; echo "Tip: run '$LAUNCH_DIR/csl' with no arguments to pick from a numbered menu instead."
  exit 1
fi

# Warm model and get a serving port
echo "⏳ Ensuring model server for $MODEL_ALIAS is running (hotswap)..."
LAUNCH_OUTPUT=$("$LAUNCH_DIR/local-llm-hotswap.sh" "$MODEL_ALIAS")
echo "$LAUNCH_OUTPUT"
VLLM_PORT=$(echo "$LAUNCH_OUTPUT" | grep -o "SUCCESS_PORT=[0-9]*" | cut -d'=' -f2)
[ -z "$VLLM_PORT" ] && { echo "❌ Could not determine the server port."; exit 1; }

# Prefer a local proxy if one is running (our copilot_local_proxy.py), check common ports
PROXY_PORT=""
for p in 8086 8085 8084 8083 8082 8081; do
  if lsof -i :$p -sTCP:LISTEN -t >/dev/null 2>&1; then PROXY_PORT=$p; break; fi
done

if [ -n "$PROXY_PORT" ]; then
  COPILOT_PROVIDER_BASE_URL="http://127.0.0.1:$PROXY_PORT"
  echo "ℹ️  Using local Copilot proxy at $COPILOT_PROVIDER_BASE_URL"
else
  # Fall back to direct vllm-mlx (may require provider emulation)
  COPILOT_PROVIDER_BASE_URL="http://127.0.0.1:$VLLM_PORT/v1"
  echo "⚠️  No local Copilot proxy detected; pointing Copilot directly at vllm port $VLLM_PORT ($COPILOT_PROVIDER_BASE_URL)."
fi

# Set BYOK env vars for Copilot CLI
export COPILOT_PROVIDER_BASE_URL
export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_PROVIDER_API_KEY="local"
# COPILOT_MODEL is used as the logical model identifier in Copilot; send the alias as the model
export COPILOT_MODEL="$MODEL_ALIAS"
# If wire model should differ, set COPILOT_PROVIDER_WIRE_MODEL (here we use the same alias)
export COPILOT_PROVIDER_WIRE_MODEL="$MODEL_ALIAS"

# Optional: set a permissive permission mode for local sessions (you can remove --allow-all)
echo "🔗 Starting Copilot CLI in a local BYOK session (model: $COPILOT_MODEL)"

# Launch interactive Copilot; user can pass additional flags after -- if desired
copilot --model "$COPILOT_MODEL"

