#!/usr/bin/env bash
# config-lib.sh — the OVERLAY loader for local-agents.
#
# Design (the "additive overlay" principle): your machine-specific values and model
# registry live in config.local.sh, which is GITIGNORED and never published. This lib
# loads config.local.sh if present, otherwise falls back to the shipped config.example.sh
# so a fresh clone still runs (with example defaults) and shows you what to customize.
# Nothing here touches your ~/.claude/settings.json or any other tool's config.
#
# Sourced by launch-claude-agent.sh, local-llm-hotswap.sh, and csl.

# Resolve the plugin root (this file is in <root>/config/).
LA_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA_ROOT="$(cd "$LA_CONFIG_DIR/.." && pwd)"

# --- model registry storage (populated by la_register in the config file) ----
# Parallel arrays keyed by insertion; la_lookup fills LA_* vars for a given alias.
LA_ALIASES=()
declare -A LA_SUBDIR LA_SERVE LA_TOOLP LA_REASONP LA_THINK LA_SPOOF LA_EFFORT

# la_register <alias> <subdir> <serve:vllm|mlx_lm> <tool_parser> <reasoning_parser> <thinking:true|false> <spoof_id> <effort>
# reasoning_parser may be "" (none). Called once per model from the config file.
la_register() {
  local alias="$1"
  LA_ALIASES+=("$alias")
  LA_SUBDIR[$alias]="$2"; LA_SERVE[$alias]="$3"; LA_TOOLP[$alias]="$4"
  LA_REASONP[$alias]="$5"; LA_THINK[$alias]="$6"; LA_SPOOF[$alias]="$7"; LA_EFFORT[$alias]="$8"
}

# Load config.local.sh (private) if it exists, else config.example.sh (shipped defaults).
la_load_config() {
  if [ -f "$LA_CONFIG_DIR/config.local.sh" ]; then
    # shellcheck source=/dev/null
    . "$LA_CONFIG_DIR/config.local.sh"
    LA_CONFIG_SOURCE="config.local.sh"
  elif [ -f "$LA_CONFIG_DIR/config.example.sh" ]; then
    # shellcheck source=/dev/null
    . "$LA_CONFIG_DIR/config.example.sh"
    LA_CONFIG_SOURCE="config.example.sh (defaults — copy to config.local.sh and edit)"
  else
    echo "❌ local-agents: no config found in $LA_CONFIG_DIR" >&2
    return 1
  fi
  # Machine defaults (only set if the config file didn't).
  : "${LA_MODELS_DIR:=$HOME/.models}"
  : "${LA_VENV:=$HOME/.local-llm/bin}"
  : "${LA_PORT_START:=8000}"
  : "${LA_PORT_MAX:=8010}"
  : "${LA_MAX_OUTPUT_TOKENS:=8192}"
  : "${LA_MEMORY_BUDGET_GB:=96}"
  : "${LA_ADMISSION:=wait}"
  : "${LA_MAX_MODEL_LEN:=32768}"
  # Optional per-machine extras a user may want the agent prompt to know about (all optional):
  : "${LA_MEMORY_DIR:=}"          # absolute path to your auto-memory dir, if you want the agent told
  : "${LA_COUNCIL_NOTE:=}"        # optional extra line appended to the agent prompt (e.g. a council rule)
}

# la_lookup <alias> -> sets LA_CUR_* for the matched model, returns 1 if unknown.
la_lookup() {
  local a="$1"
  if [ -z "${LA_SUBDIR[$a]+x}" ]; then return 1; fi
  LA_CUR_ALIAS="$a"
  LA_CUR_DIR="$LA_MODELS_DIR/${LA_SUBDIR[$a]}"
  LA_CUR_SERVE="${LA_SERVE[$a]}"
  LA_CUR_TOOLP="${LA_TOOLP[$a]}"
  LA_CUR_REASONP="${LA_REASONP[$a]}"
  LA_CUR_THINK="${LA_THINK[$a]}"
  LA_CUR_SPOOF="${LA_SPOOF[$a]}"
  LA_CUR_EFFORT="${LA_EFFORT[$a]}"
  return 0
}

# la_aliases_help -> prints the registered aliases (for usage messages).
la_aliases_help() {
  local a
  for a in "${LA_ALIASES[@]}"; do
    printf "  %-26s serve=%s spoof=%s effort=%s thinking=%s\n" \
      "$a" "${LA_SERVE[$a]}" "${LA_SPOOF[$a]}" "${LA_EFFORT[$a]}" "${LA_THINK[$a]}"
  done
}
