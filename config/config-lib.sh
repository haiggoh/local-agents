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
# user's A/B choice). One model can also fill several roles by varying EFFORT/thinking (fast =
# operator/utility, deeper = reasoner/validator), so a small roster spans a wide role spectrum.
# These four are the current canonical roles — keep the names stable, but they're EXTENSIBLE (add
# tags like coder/vision/long-context as the roster grows; reports list canonical + extras):
#   operator  — the BROAD DEFAULT / catch-all: bulk / mechanical / tool-driving (favor it)
#   reasoner  — escalation: reasoning-heavy first pass (analysis, trade-offs, plan drafts)
#   validator — escalation: independent validation / second-opinion / adversarial review
#   utility   — down-shift: cheap classification / extraction at volume
LA_CANONICAL_ROLES="operator reasoner validator utility"

# --- backend vocabulary and the DEFAULT MLX backend --------------------------
# Two kinds of value can appear in a registration's `serve` field:
#
#   GENERIC   mlx | "" (empty)      "whichever MLX backend this machine defaults to"
#   PINNED    rapid | vllm | mlx_lm | llama_cpp    "exactly this backend, never substituted"
#
# A generic value is resolved ONCE, in la_finalize_serve (called by la_load_config after the
# machine defaults are applied), to $LA_DEFAULT_MLX_BACKEND. Every consumer therefore reads an
# already-resolved concrete backend out of LA_SERVE / LA_CUR_SERVE and needs no resolution logic
# of its own — while LA_SERVE_DECLARED keeps what the config actually said, so reports can show
# "mlx→rapid" instead of pretending the file said "rapid". Nothing is hidden: la_aliases_help,
# hotswap and the launcher all print the resolved backend AND the declaration it came from.
#
# ★ 2026-08-31 — the default flipped from vllm to rapid. Rapid-MLX's hybrid prefix cache is what
#   made interactive local sessions usable at all (27,290 of 27,584 prompt tokens cached; warm
#   TTFT 2.0s vs 135.6s cold on the incumbent), so it is the backend a bare registration should
#   get. vllm-mlx remains fully supported as an explicit pin and is the LEGACY comparison lane.
#   ONE-LINE ROLLBACK: set LA_DEFAULT_MLX_BACKEND=vllm in config.local.sh — every generic
#   registration reverts, and every explicit pin is unaffected either way.
#
# llama_cpp is deliberately NOT reachable from a generic value: GGUF artifacts belong to
# llama.cpp / llama-server and MLX backends cannot load them, so a GGUF model must pin
# serve=llama_cpp explicitly. la_finalize_serve warns loudly if a GGUF-looking artifact ends up
# on an MLX backend, because that combination fails late (at weight load) and confusingly.
LA_SERVE_BACKENDS="rapid vllm mlx_lm llama_cpp"
LA_SERVE_GENERIC="mlx auto"
# Which backends a GENERIC value may resolve to. Narrower than LA_SERVE_BACKENDS on purpose:
# llama_cpp is a legal PIN but must never be the MLX default, or flipping one line would reroute
# every MLX model to an engine that cannot load safetensors at all.
LA_MLX_BACKENDS="rapid vllm mlx_lm"

# --- model registry storage (populated by la_register in the config file) ----
# Parallel arrays keyed by insertion; la_lookup fills LA_* vars for a given alias.
LA_ALIASES=()
declare -A LA_SUBDIR LA_SERVE LA_SERVE_DECLARED LA_TOOLP LA_REASONP LA_THINK LA_SPOOF LA_EFFORT LA_ROLES LA_REPO LA_SIZE
# Optional per-alias Claude Code auto-compaction overrides. csl applies
# these only to the selected model's child launcher process.
declare -A LA_SESSION_AUTO_COMPACT

# la_register <alias> <subdir> <serve:mlx|rapid|vllm|mlx_lm|llama_cpp> <tool_parser> <reasoning_parser>
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
  # Keep the DECLARED serve value verbatim. LA_SERVE holds the same string for now and is
  # rewritten to a concrete backend by la_finalize_serve; resolution cannot happen here because
  # the config file may set LA_DEFAULT_MLX_BACKEND after (or never, leaving it to the default).
  LA_SUBDIR[$alias]="$2"; LA_SERVE[$alias]="$3"; LA_SERVE_DECLARED[$alias]="$3"
  LA_TOOLP[$alias]="$4"
  LA_REASONP[$alias]="$5"; LA_THINK[$alias]="$6"; LA_SPOOF[$alias]="$7"; LA_EFFORT[$alias]="$8"
  LA_ROLES[$alias]="${9:-}"; LA_REPO[$alias]="${10:-}"; LA_SIZE[$alias]="${11:-}"
}

# --- retired aliases: a rename must not fail silently -------------------------
# la_retired <old-alias> <replacement-alias-or-note>
# When an alias goes away (typically because the thing it named became the default), a bare
# "unknown alias" is a dead end: the user typed a name that worked last week and gets no route
# forward. Registering it here keeps the OLD name discoverable — la_retired_hint prints where it
# went, so the unknown-alias error can say "renamed" instead of "no such thing".
declare -A LA_RETIRED
la_retired() { LA_RETIRED[$1]="$2"; }

# la_retired_hint <alias> -> prints a one-line redirect on stderr if <alias> was retired.
# Returns 0 if a hint was printed, 1 if the alias is simply unknown.
la_retired_hint() {
  local a="$1"
  [ -n "${LA_RETIRED[$a]+x}" ] || return 1
  echo "ℹ️  '$a' was RETIRED — ${LA_RETIRED[$a]}" >&2
  return 0
}

# la_discover_rapid_bin -> prints the first Rapid-MLX executable that actually exists, or "".
# Order is deliberate: the brew install first, because that is the one the user's own upgrade
# habit keeps current; a PATH install second; the versioned venvs last and newest-first, so a
# machine that pre-dates the brew formula behaves exactly as it did before.
la_discover_rapid_bin() {
  local c
  for c in /opt/homebrew/bin/rapid-mlx /usr/local/bin/rapid-mlx; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  c="$(command -v rapid-mlx 2>/dev/null)"
  [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  # Newest venv by version sort, not by mtime: reinstalling an OLD version would otherwise make
  # it look newest. `sort -V` orders 0.12.18 < 0.13.2 correctly, which a lexical sort does not.
  for c in $(ls -d "$HOME"/.venvs/rapid-mlx-*/bin/rapid-mlx 2>/dev/null | sort -V -r); do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  echo ""
  return 1
}

# la_resolve_serve <declared> -> prints the concrete backend a declared value means.
# Generic ("", mlx, auto) -> $LA_DEFAULT_MLX_BACKEND. Anything in LA_SERVE_BACKENDS is a pin and
# passes through. Legacy spellings are normalized. An unrecognized value is a config ERROR: it
# would otherwise reach the launcher as an unknown backend and fall through to the vllm branch,
# which is exactly the kind of silent wrong-backend run this vocabulary exists to prevent.
la_resolve_serve() {
  local d="$1"
  case "$d" in
    vllm-mlx|vllm_mlx)      echo vllm ;;
    rapid-mlx|rapid_mlx)    echo rapid ;;
    mlx-lm|mlx_lm.server)   echo mlx_lm ;;
    llama.cpp|llama-cpp|llama_server|llama-server) echo llama_cpp ;;
    *)
      case " $LA_SERVE_GENERIC " in
        *" ${d:-mlx} "*) echo "$LA_DEFAULT_MLX_BACKEND"; return 0 ;;
      esac
      case " $LA_SERVE_BACKENDS " in
        *" $d "*) echo "$d"; return 0 ;;
      esac
      echo "__invalid__"; return 1 ;;
  esac
}

# la_finalize_serve -> rewrite LA_SERVE from LA_SERVE_DECLARED for every registration.
# Called from la_load_config AFTER the machine defaults, so LA_DEFAULT_MLX_BACKEND is settled.
# Idempotent: it always reads the declared value, never its own output.
la_finalize_serve() {
  local a d r bad=0
  # Validate the machine default itself before it is handed to any registration. A typo here
  # would otherwise be copied onto the whole roster at once.
  case " $LA_MLX_BACKENDS " in
    *" $LA_DEFAULT_MLX_BACKEND "*) ;;
    *) echo "❌ local-agents: LA_DEFAULT_MLX_BACKEND='$LA_DEFAULT_MLX_BACKEND' is not an MLX backend." >&2
       echo "   It must be one of: $LA_MLX_BACKENDS   (llama_cpp is a per-model PIN only — GGUF artifacts)" >&2
       return 1 ;;
  esac
  for a in "${LA_ALIASES[@]:-}"; do
    [ -n "$a" ] || continue
    d="${LA_SERVE_DECLARED[$a]:-}"
    r="$(la_resolve_serve "$d")" || {
      echo "❌ local-agents: model '$a' declares serve='$d', which is not a backend." >&2
      echo "   Pinned backends: $LA_SERVE_BACKENDS   Generic (resolves to the default): $LA_SERVE_GENERIC" >&2
      bad=1; continue
    }
    LA_SERVE[$a]="$r"
    # GGUF cannot load on an MLX backend. Catching it here turns a confusing late failure at
    # weight-load time into one line naming the model and the fix.
    case "${LA_SUBDIR[$a]:-}" in
      *gguf*|*GGUF*)
        case "$r" in
          rapid|vllm|mlx_lm)
            echo "⚠️  local-agents: '$a' looks like a GGUF artifact (${LA_SUBDIR[$a]}) but resolves to serve=$r." >&2
            echo "    MLX backends cannot load GGUF. Pin serve=llama_cpp on that registration." >&2 ;;
        esac ;;
    esac
  done
  [ "$bad" = 0 ]
}

# la_serve_display <alias> -> "rapid" for a pin, "rapid (mlx→rapid)" when it came from a generic
# declaration. Used by every human-facing listing so the resolved backend is never presented as
# though the config file had named it.
la_serve_display() {
  local a="$1" d="${LA_SERVE_DECLARED[$1]:-}" r="${LA_SERVE[$1]:-}"
  case " $LA_SERVE_GENERIC " in
    *" ${d:-mlx} "*) echo "$r (${d:-mlx}->$r)"; return 0 ;;
  esac
  echo "$r"
}

# --- role bindings: role × (model, effort) — SINGLE SOURCE OF TRUTH for roles ----
# la_role <role> <alias> <effort> [mode:dispatch|session|both]
# Binds a ROLE to a specific model AT a specific effort/thinking depth. This unifies the two axes
# that define a role: the SAME weights fill different roles at different efforts (fast operator vs
# deep reasoner). BOTH the resolver (la-roles.sh) and the csl launch menu are generated from these
# bindings, so a role is never defined twice. Several bindings for one role = your A/B choice; the
# same alias at two efforts = an effort-split (e.g. operator@medium and reasoner@xhigh on one model).
#   mode: where the binding is offered — dispatch (curl only), session (interactive launch only), or
#         both (default). A dispatch-only model (no structured tool_calls) should be `dispatch`.
# This is the preferred source. If NO la_role lines are declared, bindings are auto-derived from the
# `roles` tags on la_register at each model's default effort (see la_finalize_roles) — so older
# configs keep working. The legacy `la_preset` list still feeds the csl menu as a fallback.
LA_ROLE_BINDINGS=()   # "role|alias|effort|mode" strings, in declaration order
la_role() { LA_ROLE_BINDINGS+=("$1|$2|${3:-}|${4:-both}"); }

# --- legacy selector PRESETS (fallback for the csl menu if no la_role bindings) --------------
# (label, registered alias, effort). Presets REUSE the aliased model's server — effort is a launcher
# flag, not a new model. Superseded by la_role (which drives BOTH the menu and the resolver); kept
# working for back-compat. If neither la_role nor la_preset is set, csl lists one entry per model.
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
  # Rapid-MLX is the DEFAULT MLX backend (see the backend-vocabulary block above). Set this to
  # `vllm` to send every generic registration back to the incumbent in one line.
  : "${LA_DEFAULT_MLX_BACKEND:=rapid}"
  # Rapid-MLX executable. An explicit LA_RAPID_BIN in config.local.sh always wins — pin it when
  # you need a KNOWN version (A/B against measured evidence, or a rollback). Left unset, it is
  # DISCOVERED in this order, so an ordinary `brew upgrade` keeps the backend current without
  # editing config, and a machine with no brew formula still finds its isolated venv:
  #   1. /opt/homebrew/bin/rapid-mlx      the maintained install (homebrew-core, bottled)
  #   2. whatever `rapid-mlx` is on PATH  a pipx/uv/user install
  #   3. the newest ~/.venvs/rapid-mlx-*  the pinned-venv layout this stack started on
  # Discovery is by EXISTENCE, never by version string: a path that isn't executable is skipped
  # rather than reported as the answer, and hotswap refuses to launch if none resolved.
  if [ -z "${LA_RAPID_BIN:-}" ]; then
    LA_RAPID_BIN="$(la_discover_rapid_bin)"
  fi
  : "${LA_PORT_START:=8000}"
  : "${LA_PORT_MAX:=8010}"
  : "${LA_MAX_OUTPUT_TOKENS:=8192}"
  : "${LA_MEMORY_BUDGET_GB:=96}"
  : "${LA_ADMISSION:=wait}"
  : "${LA_MAX_MODEL_LEN:=32768}"
  # Claude Code's API_TIMEOUT_MS defaults to 600000 (10 min) — too strict for a slow local model on a
  # heavy prompt (big prefill × many tools can exceed it, then retry-loop into a "Request timed out").
  # Give local sessions generous headroom. (Max is 2147483647; stay well under.)
  # Raised 30min -> 60min (2026-08-17). The old value predates knowing the real arithmetic: at the
  # ~0.9 tok/s measured on this stack, LA_MAX_OUTPUT_TOKENS=8192 is ~2.5 HOURS of generation, so any
  # cap short of that can still truncate a maximal turn. 60 min covers ~3,200 output tokens, which
  # comfortably fits real turns while remaining a backstop against a genuinely stuck request. If you
  # want a cap that can never truncate, set 10800000 (3h) — client-side disconnect detection, not this
  # timeout, is what normally retires an abandoned request.
  : "${LA_API_TIMEOUT_MS:=3600000}"   # 60 min per request for local sessions
  # Exclude configured MCP servers from local interactive sessions (--strict-mcp-config).
  # MCP tool DEFINITIONS are the single largest slice of a local session's prompt, and the local
  # model must prefill them. Measured on this stack (2026-08-17, `claude -p` payload intercepted):
  #
  #   default   99 tool defs  173,558 chars (~46.9k tok)  ← 68% of a 254k-char request
  #   strict    28 tool defs   88,585 chars (~23.9k tok)  ← 71 fewer tools, ~23k tok saved (-33%)
  #
  # A 27B local model prefills that on every cache miss (fresh session, or any prefix change), so the
  # default is ON: local sessions run lean. Set LA_STRICT_MCP=false in your config to keep MCP tools
  # available to local sessions at that prefill cost. The launcher always PRINTS which mode it used,
  # so a missing MCP tool is explainable rather than mysteriously absent.
  : "${LA_STRICT_MCP:=true}"
  # Built-in tools withheld from local interactive sessions, via --disallowedTools. Unlike
  # --allowedTools (which only filters what may RUN and leaves every definition in the prompt),
  # --disallowedTools removes the definition from the payload — measured: 22 names dropped the
  # request from 254,045 to 82,206 chars (~68.7k -> ~22.2k tok, -68%). Each name below is either
  # unusable in a local session or contrary to how this stack works:
  #   Workflow/Agent/SendMessage/ListAgents  multi-agent orchestration; local sub-agents go through
  #                                          hotswap/curl, and the Agent picker rejects local models
  #   DesignSync/Artifact                    claude.ai-account-coupled; a local session has no auth
  #   Cron{Create,List,Delete}               session-only schedulers; durable scheduling is launchd
  #   Enter/ExitWorktree                     isolation is driven by the supervising session, not from
  #                                          inside the local one
  #   Monitor/ScheduleWakeup                 watch/loop orchestration; heavy defs, Bash covers it
  #   ReportFindings                         host-UI plumbing for cloud code review
  # Workflow ALONE is 21,865 chars (~5.9k tok) — more than the entire system prompt. Set empty to
  # withhold nothing. AskUserQuestion is deliberately NOT here: a local session must be able to ask.
  : "${LA_DENY_TOOLS:=Workflow,DesignSync,Artifact,Agent,SendMessage,ListAgents,Monitor,ScheduleWakeup,CronCreate,CronList,CronDelete,EnterWorktree,ExitWorktree,ReportFindings}"
  # Optional: path to a JSON file declaring the ONLY MCP servers a local session should load. Composes
  # with LA_STRICT_MCP=true (which otherwise loads none), so you can keep one cheap server whose tools
  # you actually want without paying for the whole configured set. Empty = load none.
  : "${LA_MCP_CONFIG:=}"
  # Server-side per-request cap passed to `vllm-mlx serve --timeout` (seconds). Its default is 300,
  # which a local model at ~0.9 tok/s exceeds on ordinary turns — the server then kills the stream and
  # the client retries the whole turn, so 300s of work is discarded before the attempt that succeeds.
  # Derived from LA_API_TIMEOUT_MS so the server and client caps stay in step by default.
  : "${LA_SERVER_TIMEOUT_S:=$(( LA_API_TIMEOUT_MS / 1000 ))}"
  # Rapid agent profile. These affect only registrations with serve=rapid.
  # They are explicit so baseline/off experiments can override them per launch.
  : "${LA_RAPID_CACHE_MEMORY_MB:=2048}"
  : "${LA_RAPID_HYBRID_CACHE_ENTRIES:=2}"
  : "${LA_RAPID_PIN_SYSTEM_PROMPT:=true}"
  : "${LA_RAPID_RELOCATE_MID_SYSTEM:=true}"
  : "${LA_RAPID_PFLASH:=off}"
  # --- CONCURRENCY: deliberately ONE sequence, and that is not a placeholder ---------------
  # Rapid DOES have a real continuous-batching scheduler (--max-num-seqs, its own default 256), so
  # unlike vllm-mlx's single-slot SimpleEngine it is *capable* of serving an interactive session and
  # a cloud dispatch at once. This stack still runs it at 1, because the binding constraint here is
  # Metal memory, not the scheduler:
  #
  #   measured on Qwen3.8 27B 4-bit / 128 GB: Metal high-water 37.9 GB at 32,214 prompt tokens but
  #   99.9 GB at 103,020 — against a 103.9 GB allocation limit. ~0.6-0.8 GB of KV per 1,000 tokens.
  #   Seven SIGABRTs in ~22h of long-context use. Reducing --cache-memory-mb does NOT move the wall.
  #
  # So ONE long-context Claude Code session already sits near the ceiling. Every additional
  # in-flight sequence carries its own KV working set, so raising this multiplies the thing that is
  # already saturating — the likely result is more aborts, i.e. crashing a live session. These were
  # hardcoded 1/2 before 0.13.1; they are knobs now so the value is DISCOVERABLE and testable, not
  # because it should casually be raised.
  #
  # Effect today: max_concurrent_requests=2 means one request runs and one queues; a third gets HTTP
  # 503 + Retry-After. A dispatch sent to a busy session's server therefore WAITS for the turn.
  # ⚠️ Raising this is gated on the Metal-ceiling work (waypoint rapid-cache-profiles-the), NOT on
  # taste. Until then, the supported way to run a session and a dispatch on the same model
  # concurrently is a SECOND server instance on another port — 27B 4-bit weights are ~16 GB, so two
  # instances fit where two long contexts do not. Note hotswap currently REUSES a healthy matching
  # server by design, so that needs a deliberate opt-out rather than just being available.
  : "${LA_RAPID_MAX_NUM_SEQS:=1}"
  : "${LA_RAPID_MAX_CONCURRENT_REQUESTS:=2}"
  # Optional per-machine extras a user may want the agent prompt to know about (all optional):
  : "${LA_MEMORY_DIR:=}"          # absolute path to your auto-memory dir, if you want the agent told
  : "${LA_COUNCIL_NOTE:=}"        # optional extra line appended to the agent prompt (e.g. a council rule)
  la_finalize_roles
  # Resolve every generic `serve` value to a concrete backend. Must run AFTER the defaults above,
  # since LA_DEFAULT_MLX_BACKEND is one of them. A failure here is a config error, not a warning:
  # continuing would run models on a backend nobody chose.
  la_finalize_serve || return 1
}

# la_finalize_roles -> if the config declared NO explicit la_role bindings, derive them from the
# `roles` tags on la_register (each tagged role bound to that alias at its default effort, mode=both).
# Keeps pre-binding configs working; a no-op when explicit la_role lines exist.
la_finalize_roles() {
  [ "${#LA_ROLE_BINDINGS[@]}" -gt 0 ] && return 0
  local a rest r
  for a in "${LA_ALIASES[@]}"; do
    rest="${LA_ROLES[$a]:-}"; rest="${rest// /}"
    [ -z "$rest" ] && continue
    IFS=',' read -ra rs <<< "$rest"
    for r in "${rs[@]}"; do [ -n "$r" ] && la_role "$r" "$a" "${LA_EFFORT[$a]:-}" both; done
  done
}

# la_role_bindings_for <role> -> prints "alias|effort|mode" for each binding of <role>.
la_role_bindings_for() {
  local want="$1" b role alias effort mode
  for b in "${LA_ROLE_BINDINGS[@]}"; do
    IFS='|' read -r role alias effort mode <<< "$b"
    [ "$role" = "$want" ] && printf '%s|%s|%s\n' "$alias" "$effort" "$mode"
  done
}

# la_roles_for_alias <alias> -> comma-separated roles bound to this alias (from bindings), else "".
# Lets consumers (e.g. the installer) show a model's roles from the single binding source, so the
# `roles` tag on la_register can stay empty/legacy.
la_roles_for_alias() {
  local want="$1" b role alias _ out=""
  for b in "${LA_ROLE_BINDINGS[@]}"; do
    IFS='|' read -r role alias _ <<< "$b"
    [ "$alias" = "$want" ] || continue
    case ",$out," in *",$role,"*) ;; *) out="${out:+$out,}$role";; esac
  done
  echo "$out"
}

# la_bound_roles -> prints the distinct roles that have bindings, canonical order first then extras.
la_bound_roles() {
  local b role _ seen=" " r
  for r in $LA_CANONICAL_ROLES; do
    for b in "${LA_ROLE_BINDINGS[@]}"; do
      IFS='|' read -r role _ <<< "$b"
      [ "$role" = "$r" ] && { echo "$r"; seen="$seen$r "; break; }
    done
  done
  for b in "${LA_ROLE_BINDINGS[@]}"; do
    IFS='|' read -r role _ <<< "$b"
    case "$seen" in *" $role "*) ;; *) echo "$role"; seen="$seen$role ";; esac
  done
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

# la_on_disk <alias> -> 0 if the model's weights are actually present (a real weight file, not
# just a non-empty directory). This is what
# makes the roster "informed by what's actually available": a registered model isn't usable until
# its files are present, so the resolver/installer check disk, not just registration.
la_on_disk() {
  local sub="${LA_SUBDIR[$1]:-}" d
  [ -n "$sub" ] || return 1
  d="$LA_MODELS_DIR/$sub"
  [ -d "$d" ] || return 1
  # Require an actual WEIGHT file, not merely a non-empty directory. A metadata-only shell (configs
  # + tokenizer, no weights) is left behind by an aborted download; it looks installed and is not,
  # and serving it fails at load time instead of here. Weights are always large, so "any file over
  # 1MB" is a format-agnostic test that costs one find with -quit.
  # -L is REQUIRED, not incidental: model-asset-override.sh builds legitimate models as SYMLINK
  # FARMS pointing at a shared snapshot, and plain -type f does not match a symlink, so without -L
  # a perfectly working override view is reported as having no weights. -L still rejects a farm
  # whose targets are gone, which is the behaviour we want.
  [ -n "$(find -L "$d" -type f -size +1024k -print -quit 2>/dev/null)" ]
}

# la_dir_present <alias> -> 0 if the model's directory exists at all, regardless of whether it holds
# weights. The pair distinguishes three states a caller may want to report differently:
#   la_dir_present && la_on_disk    usable now
#   la_dir_present && ! la_on_disk  BROKEN: directory there, weights missing (re-fetch or unbind)
#   ! la_dir_present                simply not downloaded
la_dir_present() {
  local sub="${LA_SUBDIR[$1]:-}"
  [ -n "$sub" ] || return 1
  [ -d "$LA_MODELS_DIR/$sub" ]
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
    printf "  %-26s serve=%-18s spoof=%s effort=%s thinking=%s\n" \
      "$a" "$(la_serve_display "$a")" "${LA_SPOOF[$a]}" "${LA_EFFORT[$a]}" "${LA_THINK[$a]}"
  done
  # Retired names, listed so a stale alias in muscle memory gets a route forward instead of a
  # bare "unknown alias" — the aliases help text is exactly where someone looks after that error.
  if [ "${#LA_RETIRED[@]}" -gt 0 ]; then
    echo "  --- retired aliases ---"
    local r
    for r in "${!LA_RETIRED[@]}"; do
      printf "  %-26s %s\n" "$r" "${LA_RETIRED[$r]}"
    done
  fi
}
