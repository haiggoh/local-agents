#!/usr/bin/env bash
# ============================================================================
# local-agents CONFIG TEMPLATE
# ============================================================================
# Copy this file to `config.local.sh` and edit it for YOUR machine:
#
#     cp config/config.example.sh config/config.local.sh
#
# config.local.sh is GITIGNORED — your private paths and model layout never get
# published. The scripts load config.local.sh if it exists, otherwise these
# example defaults (so a fresh clone still runs and shows you what to change).
# This overlay leaves your ~/.claude/settings.json and every other tool's config
# completely untouched.
# ============================================================================

# --- machine settings --------------------------------------------------------
LA_MODELS_DIR="$HOME/.models"          # where your MLX model directories live
LA_VENV="$HOME/.local-llm/bin"         # venv with `vllm-mlx` and `python -m mlx_lm`
LA_PORT_START=8000                     # port scan range for the local server
LA_PORT_MAX=8010
LA_MAX_OUTPUT_TOKENS=8192              # native Claude Code output cap for local turns
LA_MEMORY_BUDGET_GB=96                 # vllm-mlx per-model memory budget (tune to your RAM)
LA_ADMISSION="wait"                    # SimpleEngine admission: wait (queue) | fail_fast
LA_MAX_MODEL_LEN=32768
LA_API_TIMEOUT_MS=3600000              # per-request timeout for local sessions (ms). Claude Code’s
                                       # default is 600000 (10 min) — too strict for a slow local model
                                       # on a heavy prompt. At the ~0.9 tok/s measured on this stack,
                                       # LA_MAX_OUTPUT_TOKENS=8192 is ~2.5h of generation, so even 60
                                       # min can truncate a maximal turn; use 10800000 (3h) if you want
                                       # a cap that never can. (max 2147483647)
LA_SERVER_TIMEOUT_S=3600               # passed to `vllm-mlx serve --timeout`. vllm-mlx's own default is
                                       # 300s and its streaming guard enforces it SERVER-side, so a local
                                       # model that needs >5 min per turn gets its stream killed and the
                                       # client retries the whole turn. Defaults to LA_API_TIMEOUT_MS/1000.
LA_DENY_TOOLS="Workflow,DesignSync,Artifact,Agent,SendMessage,ListAgents,Monitor,ScheduleWakeup,CronCreate,CronList,CronDelete,EnterWorktree,ExitWorktree,ReportFindings"
                                       # built-in tools withheld from local sessions via
                                       # --disallowedTools, which (unlike --allowedTools) drops the
                                       # DEFINITION from the prompt. With LA_STRICT_MCP this takes the
                                       # request from 254,045 to 83,903 chars (~68.7k -> ~22.7k tok).
                                       # Each is unusable locally or contrary to this stack; see
                                       # config-lib.sh for the per-tool reasoning. Empty = send all.
LA_MCP_CONFIG=""                       # optional JSON naming the ONLY MCP servers to load. Composes
                                       # with LA_STRICT_MCP=true, so you can keep one cheap server
                                       # instead of choosing between all of them and none.
LA_STRICT_MCP=true                     # run local interactive sessions with --strict-mcp-config, so the
                                       # configured MCP servers' tool definitions stay out of the prompt.
                                       # Measured: 99 -> 28 tool defs, ~46.9k -> ~23.9k prefill tokens.
                                       # Set false to keep MCP tools available at that prefill cost.

# Optional: absolute path to your Claude Code auto-memory dir. If set, the agent
# prompt tells the local model where memory lives (helps it avoid guessing paths).
# Leave empty to omit. Example: "$HOME/.claude/projects/-Users-you/memory"
LA_MEMORY_DIR=""

# Optional: an extra line appended to the local agent's system prompt — e.g. a
# personal "council" review rule. Leave empty to omit.
LA_COUNCIL_NOTE=""

# --- model registry (SINGLE SOURCE OF TRUTH) ---------------------------------
# This registry is the one place that defines the roster. It drives launching, the by-ROLE routing
# the offload rules use, the disk-aware role resolver (`bin/la-roles.sh`), AND the interactive
# installer (`install/download-models.sh` reads hf_repo/size from here). Change models HERE only.
# One la_register line per model:
#
#   la_register <alias> <subdir> <serve> <tool_parser> <reasoning_parser> <thinking> <spoof_id> <effort> [roles] [hf_repo] [size_gb]
#
#   alias            what a session/dispatch requests (e.g. `launch ... my-operator`)
#   subdir           directory name under LA_MODELS_DIR
#   serve            vllm  (vllm-mlx, full Anthropic route)  |  mlx_lm (mlx_lm.server, dispatch-only)
#   tool_parser      vllm-mlx --tool-call-parser: auto|qwen|qwen3_coder|mistral|llama|hermes|
#                    deepseek|gpt-oss|... (pick the one matching the model's emitted tool format)
#   reasoning_parser --reasoning-parser (qwen3|deepseek_r1|...) or "" for none
#   thinking         true|false  (VLLM_MLX_ENABLE_THINKING; false = fast operator, true = reasoner)
#   spoof_id         Claude model id Claude Code sends (org-allowlist workaround); vllm serves the
#                    model under BOTH this id AND the alias. Usually claude-opus-4-8 / claude-haiku-4-5-20251001
#   effort           Claude Code --effort: low|medium|high|xhigh|max
#   roles            OPTIONAL comma-separated role tags — operator|reasoner|validator|utility (and
#                    any extras). This is what the rules route on. A role may be filled by several
#                    models (your A/B choice); leaving a role unfilled is fine (that work stays on
#                    cloud). OMIT for an untagged model (still launchable, just not offered by role).
#   hf_repo          OPTIONAL Hugging Face repo id — lets the interactive installer download it.
#                    OMIT to manage the weights yourself.
#   size_gb          OPTIONAL approx download size (installer display / disk consent). OMIT if unknown.
#
# Fields are positional: to set a later optional field, pass "" for any earlier one you're skipping.
# The examples below are the maintainer's mid-2026 M4-Max stack — REPLACE with your models. Note
# operator + thinking share ONE download (same subdir/repo, different launch flags) — the installer
# dedupes by subdir, so that's a single ~16 GB fetch, not two.
# NOTE: the `roles` field (arg 9) is left "" here — roles are defined ONCE below via `la_role`
# (the single source that drives both the resolver and the csl menu). The `roles` tag still works as
# a legacy shortcut (auto-promoted to bindings if you declare no la_role lines), but don't set both.
la_register qwen-3.6-operator      Qwen3.6-27B-UD-MLX-4bit            vllm   qwen  ""          false claude-opus-4-8           high  ""  unsloth/Qwen3.6-27B-UD-MLX-4bit                   16
la_register qwen-3.6-thinking      Qwen3.6-27B-UD-MLX-4bit            vllm   qwen  qwen3       true  claude-opus-4-8           high  ""  unsloth/Qwen3.6-27B-UD-MLX-4bit                   16
la_register deepseek-r1-architect  DeepSeek-R1-Distill-Qwen-32B-4bit  vllm   qwen  deepseek_r1 true  claude-opus-4-8           max   ""  mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit    18
la_register llama-scout            Llama-4-Scout-17B-16E-Instruct-4bit mlx_lm llama ""         false claude-haiku-4-5-20251001 low   ""  mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit 60

# --- role bindings (SINGLE SOURCE OF TRUTH for roles; drives la-roles.sh AND the csl menu) -----
# la_role <role> <alias> <effort> [mode:dispatch|session|both]. The SAME weights fill different roles
# at different efforts (an effort-split); several bindings for one role = your A/B choice. mode:
# dispatch = curl-only (kept out of the interactive launch menu); session/both = launchable via csl.
# Effort variants REUSE the aliased model's server (effort is a launcher flag, not a new model).
la_role operator  qwen-3.6-operator     medium both      # fast operator — the workhorse default
la_role operator  qwen-3.6-operator     high   both      # deeper operator (same server, higher effort)
la_role operator  qwen-3.6-operator     xhigh  both      # deepest operator
la_role reasoner  qwen-3.6-thinking     high   both      # thinking flavor (same weights, thinking on)
la_role reasoner  deepseek-r1-architect max    both      # A/B reasoner — strongest local reasoner
la_role validator deepseek-r1-architect max    dispatch  # independent review — dispatch (no tool_calls)
la_role utility   llama-scout           low    dispatch  # cheap classification — dispatch-only
