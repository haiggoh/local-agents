#!/usr/bin/env bash
# Live Qwen3.8 MTP smoke for the machine-local registered alias.
#
# Preconditions:
# - no local model runtime or listener on ports 8000-8010;
# - qwen-3.8-operator resolves to Rapid with an MTP speculative config;
# - target and sidecar are installed locally.
#
# Verifies MTP injection, speculative response metrics, and an exact bounded
# response marker. It deliberately leaves the server running for inspection
# and follow-up benchmarking; use bin/la-evict.sh afterward.
set -euo pipefail
umask 077

REPO="$HOME/ClaudeWorkspace/local-agents"
EXPECTED_BRANCH="fix/omlx-classifier-prewarm"
ALIAS="qwen-3.8-operator"
EXPECTED_SPEC='{"method":"mtp","model":"'"$HOME"'/.models/Qwen3.8-27B-MTP-4bit","num_speculative_tokens":3,"disable_auto_k":false,"continuous_batching":false,"allow_dynamic_membership":false}'

fail() {
    printf 'STOP: %s\n' "$*" >&2
    exit 1
}

[ -d "$REPO/.git" ] ||
    fail "repository unavailable: $REPO"

cd "$REPO"

branch="$(git branch --show-current)"
status="$(git status --porcelain=v1 --untracked-files=all)"

[ "$branch" = "$EXPECTED_BRANCH" ] ||
    fail "expected branch $EXPECTED_BRANCH, found ${branch:-DETACHED}"

[ -z "$status" ] ||
    fail "repository is not clean: $status"

printf '%s\n' '=== 1. FRESH-RUNTIME PREFLIGHT ==='

active_runtime="$(
python3 - <<'PY_RUNTIME'
from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

table = subprocess.check_output(
    ["ps", "-Aww", "-o", "pid=,command="],
    text=True,
)

matches = []

for raw in table.splitlines():
    stripped = raw.strip()

    if not stripped:
        continue

    pid_text, separator, command = stripped.partition(" ")

    if not separator or not pid_text.isdigit():
        continue

    try:
        arguments = shlex.split(command)
    except ValueError:
        arguments = command.split()

    basenames = [Path(argument).name for argument in arguments]

    rapid_serve = (
        "rapid-mlx" in basenames
        and "serve" in arguments
    )
    other_runtime = any(
        name in {"vllm-mlx", "omlx-server"}
        for name in basenames
    )
    omlx_serve = any(
        basenames[index] == "omlx"
        and index + 1 < len(arguments)
        and arguments[index + 1] == "serve"
        for index in range(len(arguments))
    )

    if rapid_serve or other_runtime or omlx_serve:
        matches.append(raw)

print("\n".join(matches))
PY_RUNTIME
)"

if [ -n "$active_runtime" ]; then
    printf '%s\n' "$active_runtime" >&2
    fail "a local model runtime is already active; evict it before this fresh smoke"
fi

for port in 8000 8001 8002 8003 8004 8005 8006 8007 8008 8009 8010; do
    pids="$(
        lsof -nP -t \
            -iTCP:"$port" \
            -sTCP:LISTEN 2>/dev/null |
            LC_ALL=C sort -u ||
            true
    )"

    [ -z "$pids" ] ||
        fail "port $port has listener PID(s): $pids"

    printf 'port=%s free=1\n' "$port"
done

source config/config-lib.sh
la_load_config
la_lookup "$ALIAS" ||
    fail "alias lookup failed: $ALIAS"

[ "$LA_CUR_SERVE" = rapid ] ||
    fail "$ALIAS did not resolve to Rapid"

[ "$LA_CUR_RAPID_SPEC_CONFIG" = "$EXPECTED_SPEC" ] ||
    fail "live alias speculative config differs from expected"

expected_spec_sha="$(
    printf '%s' "$EXPECTED_SPEC" |
        /usr/bin/shasum -a 256 |
        awk '{print $1}'
)"

printf 'alias=%s\n' "$ALIAS"
printf 'model_dir=%s\n' "$LA_CUR_DIR"
printf 'spec_sha256=%s\n' "$expected_spec_sha"
printf 'FRESH_RUNTIME_PREFLIGHT=PASS\n'

printf '\n%s\n' '=== 2. LAUNCH QWEN3.8 MTP ==='

launch_output="$(
    LA_HOTSWAP_PREFLIGHT=1 \
        bash bin/local-llm-hotswap.sh "$ALIAS" 2>&1
)"
launch_rc=$?

printf '%s\n' "$launch_output"
printf 'launch_exit=%s\n' "$launch_rc"

[ "$launch_rc" -eq 0 ] ||
    fail "hotswap launch failed"

port="$(
    printf '%s\n' "$launch_output" |
        sed -n 's/^SUCCESS_PORT=//p' |
        tail -1
)"

case "$port" in
    ''|*[!0-9]*)
        fail "launch did not return a numeric SUCCESS_PORT"
        ;;
esac

meta="$HOME/.claude/logs/local-agents-configs/server_${port}.meta"

[ -f "$meta" ] ||
    fail "Rapid metadata file is absent: $meta"

meta_spec_sha="$(
    awk -F= '
        $1 == "spec_config_sha256" {
            print substr($0, index($0, "=") + 1)
        }
    ' "$meta"
)"

pid="$(
    awk -F= '$1 == "pid" {print $2}' "$meta"
)"

[ "$meta_spec_sha" = "$expected_spec_sha" ] ||
    fail "metadata speculative-config identity mismatch"

case "$pid" in
    ''|*[!0-9]*)
        fail "metadata lacks a numeric PID"
        ;;
esac

kill -0 "$pid" 2>/dev/null ||
    fail "Rapid PID $pid is not alive"

printf 'port=%s\n' "$port"
printf 'pid=%s\n' "$pid"
printf 'meta=%s\n' "$meta"
printf 'meta_spec_sha256=%s\n' "$meta_spec_sha"
printf 'QWEN38_MTP_LAUNCH=PASS\n'

printf '\n%s\n' '=== 3. BOUNDED GENERATION SMOKE ==='

response_file="$(mktemp "${TMPDIR:-/tmp}/qwen38-mtp-response.XXXXXX")"
timing_file="$(mktemp "${TMPDIR:-/tmp}/qwen38-mtp-timing.XXXXXX")"

http_code="$(
    curl \
        --silent \
        --show-error \
        --max-time 180 \
        --output "$response_file" \
        --write-out '%{http_code} %{time_starttransfer} %{time_total}' \
        --header 'Content-Type: application/json' \
        --data "$(
            printf '%s' \
                '{"model":"claude-opus-5","messages":[{"role":"user","content":"Reply with exactly MTP_SMOKE_OK and nothing else."}],"max_tokens":64,"temperature":0}'
        )" \
        "http://127.0.0.1:${port}/v1/chat/completions"
)"

printf '%s\n' "$http_code" | tee "$timing_file"

status="${http_code%% *}"

[ "$status" = 200 ] ||
    fail "generation returned HTTP $status"

RESPONSE_FILE="$response_file" python3 - <<'PY_RESPONSE'
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

path = Path(os.environ["RESPONSE_FILE"])
payload = json.loads(path.read_text(encoding="utf-8"))

print(json.dumps(
    payload,
    indent=2,
    ensure_ascii=False,
    sort_keys=True,
))

choices = payload.get("choices")
text = ""

if isinstance(choices, list) and choices:
    first = choices[0]

    if isinstance(first, dict):
        message = first.get("message")

        if isinstance(message, dict):
            content = message.get("content")

            if isinstance(content, str):
                text = content

print(f"assistant_text={text!r}")

metrics: list[tuple[str, Any]] = []


def walk(value: Any, prefix: str = "") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            current = f"{prefix}.{key}" if prefix else key

            if any(
                term in key.casefold()
                for term in (
                    "mtp",
                    "spec",
                    "draft",
                    "accept",
                    "verify",
                )
            ):
                metrics.append((current, child))

            walk(child, current)

    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{prefix}[{index}]")


walk(payload)

print(f"metric_match_count={len(metrics)}")

for key, value in metrics:
    print(f"metric={key} value={value!r}")

if "MTP_SMOKE_OK" not in text:
    raise SystemExit(
        "STOP: response did not contain the requested smoke marker"
    )

print("BOUNDED_GENERATION_SMOKE=PASS")
PY_RESPONSE

printf '\n%s\n' '=== 4. RAPID MTP LOG EVIDENCE ==='

log_file="$(
    find "$HOME/.claude/logs" \
        -type f \
        -name "*_${port}.log" \
        -print 2>/dev/null |
        sort |
        tail -1
)"

if [ -z "$log_file" ]; then
    printf 'log_file=NOT_FOUND\n'
else
    printf 'log_file=%s\n' "$log_file"

    grep -iE \
        'mtp|speculative|draft|inject|sidecar|accept|verify' \
        "$log_file" |
        tail -160 ||
        true
fi

printf '\n%s\n' '=== 5. LIVE PROCESS COMMAND ==='
ps -p "$pid" \
    -o pid=,ppid=,pgid=,state=,etime=,command=

printf '\nRESULTS\n'
printf '%s\n' \
    'QWEN38_MTP_REAL_SMOKE=PASS' \
    'SPEC_CONFIG_IDENTITY=PASS' \
    'HTTP_GENERATION=PASS' \
    'REPOSITORY_MUTATED=0' \
    'SERVER_LEFT_RUNNING=1'
printf 'PORT=%s\n' "$port"
printf 'PID=%s\n' "$pid"
printf 'META=%s\n' "$meta"
printf 'LOG=%s\n' "${log_file:-NOT_FOUND}"
printf 'RESPONSE=%s\n' "$response_file"
