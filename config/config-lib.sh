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

# --- roles: the STABLE vocabulary the routing rules refer to -------------------
# The offload rules (skill + CLAUDE.md) route by ROLE, never by a specific model name, so the
# roster can change without touching any rule. A model declares which role(s) it can fill via the
# `roles` field of la_register; a role may be filled by 0, 1, or several models (several = the
# user's A/B choice). These four are the canonical roles the rules assume — keep the names stable:
#   operator  — bulk / mechanical / tool-driving (the workhorse; fast)
#   reasoner  — reasoning-heavy first pass (analysis, trade-offs, plan drafts)
#   validator — independent validation / second-opinion / adversarial review
#   utility   — cheap classification / extraction at volume
# Extra role tags beyond these are allowed and simply appended in reports.
LA_CANONICAL_ROLES="operator reasoner validator utility"

# --- model registry storage (populated by la_register in the config file) ----
# Parallel arrays keyed by insertion; la_lookup fills LA_* vars for a given alias.
LA_ALIASES=()
declare -A LA_SUBDIR LA_SERVE LA_TOOLP LA_REASONP LA_THINK LA_SPOOF LA_EFFORT LA_ROLES LA_REPO LA_SIZE

# la_register <alias> <subdir> <serve:vllm|mlx_lm> <tool_parser> <reasoning_parser>
#             <thinking:true|false> <spoof_id> <effort> [roles] [hf_repo] [size_gb]
# reasoning_parser may be "" (none). The last three are OPTIONAL and additive, so pre-existing
# 8-field config lines keep working unchanged:
#   roles    comma-separated role tags (see LA_CANONICAL_ROLES); "" = untagged (still launchable,
#            just not offered by role in the resolver).
#   hf_repo  Hugging Face repo id — lets the interactive installer download this model; "" = the
#            installer won't manage it (you place the weights yourself).
#   size_gb  approx download size, for the installer's disk/consent display; "" = unknown.
# Called once per model from the config file.
la_register() {
  local alias="$1"
  LA_ALIASES+=("$alias")
  LA_SUBDIR[$alias]="$2"; LA_SERVE[$alias]="$3"; LA_TOOLP[$alias]="$4"
  LA_REASONP[$alias]="$5"; LA_THINK[$alias]="$6"; LA_SPOOF[$alias]="$7"; LA_EFFORT[$alias]="$8"
  LA_ROLES[$alias]="${9:-}"; LA_REPO[$alias]="${10:-}"; LA_SIZE[$alias]="${11:-}"
}

# --- optional selector PRESETS -----------------------------------------------
# Convenience launch options for the csl menu: (label, registered alias, effort). Presets
# REUSE the aliased model's server — effort is a launcher flag, not a new model — so listing
# fast/high/xhigh variants of one model does NOT spin up duplicate servers. If no presets are
# registered, csl falls back to one entry per registered model at its default effort.
LA_PRESET_LABEL=(); LA_PRESET_ALIAS=(); LA_PRESET_EFFORT=()
la_preset() { LA_PRESET_LABEL+=("$1"); LA_PRESET_ALIAS+=("$2"); LA_PRESET_EFFORT+=("$3"); }

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

# la_on_disk <alias> -> 0 if the model's weights directory exists and is non-empty. This is what
# makes the roster "informed by what's actually available": a registered model isn't usable until
# its files are present, so the resolver/installer check disk, not just registration.
la_on_disk() {
  local sub="${LA_SUBDIR[$1]:-}" d
  [ -n "$sub" ] || return 1
  d="$LA_MODELS_DIR/$sub"
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]
}

# la_models_for_role <role> -> prints, one per line, the aliases tagged with <role> (any position
# in their comma-separated roles list). Empty output = no model fills that role.
la_models_for_role() {
  local want="$1" a r rest
  for a in "${LA_ALIASES[@]}"; do
    rest=",${LA_ROLES[$a]:-},"
    # normalize spaces so " operator, reasoner " matches
    rest="${rest// /}"
    case "$rest" in *,"$want",*) echo "$a";; esac
  done
}

# la_aliases_help -> prints the registered aliases (for usage messages).
la_aliases_help() {
  local a
  for a in "${LA_ALIASES[@]}"; do
    printf "  %-26s serve=%s spoof=%s effort=%s thinking=%s\n" \
      "$a" "${LA_SERVE[$a]}" "${LA_SPOOF[$a]}" "${LA_EFFORT[$a]}" "${LA_THINK[$a]}"
  done
}
