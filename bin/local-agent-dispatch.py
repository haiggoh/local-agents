#!/usr/bin/env python3
"""local-agent-dispatch — universal local MLX model dispatcher

Dispatch a prompt to any registered local MLX model in your local-agents
stack (vllm-mlx / local-llm-hotswap.sh) from ANY context: terminal, script,
AGY session, Claude Code session, or CI pipeline. No cloud model or API key
required for the dispatched work.

Usage:
    local-agent [--model ALIAS] --prompt "TEXT" [--files F1 F2 ...] [--max-tokens N]

Defaults to qwen-3.6-operator. Registered aliases are driven by your
config/config.local.sh model registry.

Examples:
    local-agent --prompt "What does this module do?" --files src/main.py
    local-agent-r1 --prompt "Review this plan and find risks"
    local-agent-qwen --prompt "Summarize key changes" --files diff.txt
    local-agent-devstral --prompt "Refactor this function" --files utils.py --max-tokens 2048
"""

import os
import sys
import argparse
import subprocess
import tempfile
import re

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
HOTSWAP_SCRIPT = os.path.join(BIN_DIR, "local-llm-hotswap.sh")
LIBRARIAN_SCRIPT = os.path.join(BIN_DIR, "librarian-dispatch.py")


def hotswap_get_port(model_alias: str) -> int:
    """Run local-llm-hotswap.sh to ensure model server is active and get port."""
    if not os.path.isfile(HOTSWAP_SCRIPT):
        raise FileNotFoundError(f"Hotswap script not found: {HOTSWAP_SCRIPT}")

    cmd = [HOTSWAP_SCRIPT, model_alias]
    res = subprocess.run(cmd, capture_output=True, text=True)

    if res.returncode != 0:
        print(f"[-] Hotswap failed for '{model_alias}':", file=sys.stderr)
        print(res.stderr or res.stdout, file=sys.stderr)
        sys.exit(res.returncode)

    # Search for port output (e.g., SUCCESS_PORT 8000 or listening port)
    match = re.search(r"SUCCESS_PORT\s+(\d+)", res.stdout)
    if match:
        return int(match.group(1))

    match = re.search(r"port\s+(\d+)", res.stdout)
    if match:
        return int(match.group(1))

    # Fallback to default port range scanner
    for line in res.stdout.splitlines():
        if "800" in line:
            m = re.search(r"\b(800\d)\b", line)
            if m:
                return int(m.group(1))

    return 8000


def main():
    parser = argparse.ArgumentParser(description="AGY Local Model Dispatcher")
    parser.add_argument(
        "--model",
        default="qwen-3.6-operator",
        help="Local model alias (e.g. qwen-3.6-operator, deepseek-r1-architect, gemma-4-26b)",
    )
    parser.add_argument("--prompt", required=True, help="Task prompt for the local model")
    parser.add_argument("--files", nargs="*", help="Optional file paths to include as context")
    parser.add_argument("--max-tokens", type=int, default=4096, help="Max tokens to generate")
    args = parser.parse_args()

    print(f"[*] Hotswapping local model '{args.model}'...", file=sys.stderr)
    port = hotswap_get_port(args.model)
    print(f"[✓] Local model ready on port {port}", file=sys.stderr)

    prompt_text = args.prompt
    if args.files:
        attached_context = []
        for filepath in args.files:
            if os.path.isfile(filepath):
                try:
                    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read()
                    attached_context.append(f"--- File: {filepath} ---\n{content}\n--- End File ---")
                except Exception as e:
                    print(f"[!] Could not read file {filepath}: {e}", file=sys.stderr)

        if attached_context:
            prompt_text = "\n\n".join(attached_context) + "\n\n" + prompt_text

    with tempfile.TemporaryDirectory() as tmpdir:
        cmd = [
            sys.executable,
            LIBRARIAN_SCRIPT,
            "--port",
            str(port),
            "--prompt",
            prompt_text,
            "--model",
            args.model,
            "--max-tokens",
            str(args.max_tokens),
            "--outdir",
            tmpdir,
        ]

        print(f"[*] Dispatching prompt to local server (port {port})...", file=sys.stderr)
        res = subprocess.run(cmd)

        if res.returncode != 0:
            print(f"[-] Dispatch failed with exit code {res.returncode}", file=sys.stderr)
            sys.exit(res.returncode)

        output_file = os.path.join(tmpdir, "output.txt")
        reasoning_file = os.path.join(tmpdir, "reasoning.txt")

        if os.path.isfile(reasoning_file):
            try:
                with open(reasoning_file, "r", encoding="utf-8") as f:
                    reasoning = f.read().strip()
                if reasoning:
                    print(f"--- Local Model Thinking ---\n{reasoning}\n----------------------------\n")
            except Exception:
                pass

        if os.path.isfile(output_file):
            with open(output_file, "r", encoding="utf-8") as f:
                output_text = f.read()
            print(output_text)
        else:
            print("[-] No output received from local model server.", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
