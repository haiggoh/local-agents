#!/usr/bin/env python3
"""local-agent-dispatch — universal local MLX model dispatcher

Dispatch a prompt to any registered local MLX model in your local-agents
stack (vllm-mlx / local-llm-hotswap.sh) from ANY context: terminal, script,
AGY session, Claude Code session, or CI pipeline. No cloud model or API key
required for the dispatched work.

Usage:
    local-agent [--model ALIAS] --prompt "TEXT" [--files F1 F2 ...] [--max-tokens N]
    local-agent --convo [--model ALIAS] [--max-tokens N]

Defaults to qwen-3.6-operator. Registered aliases are driven by your
config/config.local.sh model registry.

Examples:
    local-agent --prompt "What does this module do?" --files src/main.py
    local-agent-r1 --prompt "Review this plan and find risks"
    local-agent-qwen --prompt "Summarize key changes" --files diff.txt
    local-agent-devstral --prompt "Refactor this function" --files utils.py --max-tokens 2048
    
    # Continuous Conversation Mode:
    local-agent --convo --prompt "Let's discuss Python"
    (Type 'exit' or 'quit' to end the session)
"""

import os
import sys
import argparse
import json
import subprocess
import tempfile
import time
import re

# realpath, NOT abspath: this script is meant to be reached through a symlink on
# PATH (e.g. ~/.local/bin/local-agent). abspath leaves the symlink unresolved, so
# BIN_DIR would be the symlink's directory and the sibling helper scripts below
# would not be found. Every other script in this bin/ resolves its own location
# the same way, for the same reason.
BIN_DIR = os.path.dirname(os.path.realpath(__file__))
HOTSWAP_SCRIPT = os.path.join(BIN_DIR, "local-llm-hotswap.sh")
LIBRARIAN_SCRIPT = os.path.join(BIN_DIR, "librarian-dispatch.py")

PROGRESS_MODE = "compact"
PROGRESS_LABEL = "model"
SESSION_DIR = os.path.expanduser(
    os.environ.get(
        "LOCAL_AGENT_SESSION_DIR",
        "~/.local/share/local-agent/sessions",
    )
)


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

    # The hotswap script's contract is a line reading `SUCCESS_PORT=<port>`; it is
    # the LAST such line that reflects the port actually landed on. Accept either
    # `=` or whitespace so a future format change does not break this silently.
    matches = re.findall(r"SUCCESS_PORT\s*[=:]?\s*(\d+)", res.stdout)
    if matches:
        return int(matches[-1])

    # No contract line means the port is unknown. Guessing is worse than failing:
    # the model may have landed on any free port in the scanned range, and
    # defaulting to 8000 dispatches to whatever unrelated model is sitting there
    # — a wrong answer that looks like a right one. Fail loudly instead.
    print(
        f"[-] Could not determine the port for '{model_alias}': no SUCCESS_PORT "
        "line in the hotswap output. Refusing to guess, because dispatching to "
        "the wrong port silently returns another model's answer.",
        file=sys.stderr,
    )
    if res.stdout.strip():
        print("--- hotswap output ---", file=sys.stderr)
        print(res.stdout.strip(), file=sys.stderr)
    sys.exit(1)


def read_files_context(file_paths: list, max_file_chars: int = 48000) -> str:
    """
    Read text files into prompt context.

    max_file_chars is a per-file safety limit. A value of 0 disables the
    limit. Oversized files are rejected rather than silently truncated so
    code review never proceeds on an undisclosed partial file.
    """
    if not file_paths:
        return ""

    attached_context = []
    for filepath in file_paths:
        expanded_path = os.path.abspath(os.path.expanduser(filepath))

        if not os.path.isfile(expanded_path):
            print(f"[!] File not found: {expanded_path}", file=sys.stderr)
            continue

        try:
            with open(
                expanded_path,
                "r",
                encoding="utf-8",
                errors="replace",
            ) as f:
                content = f.read()
        except OSError as exc:
            print(
                f"[!] Could not read file {expanded_path}: {exc}",
                file=sys.stderr,
            )
            continue

        if max_file_chars > 0 and len(content) > max_file_chars:
            print(
                f"[!] File exceeds --max-file-chars: {expanded_path} "
                f"({len(content):,} > {max_file_chars:,} chars). "
                "The file was not attached. Increase the limit or use "
                "--max-file-chars 0 deliberately.",
                file=sys.stderr,
            )
            continue

        attached_context.append(
            f"--- File: {expanded_path} ---\n"
            f"{content}\n"
            f"--- End File: {expanded_path} ---"
        )

    if attached_context:
        return "\n\n".join(attached_context) + "\n\n"
    return ""


def run_librarian_with_progress(cmd: list) -> int:
    """Run librarian-dispatch using compact, verbose, or quiet presentation."""
    if PROGRESS_MODE == "verbose":
        return subprocess.run(cmd).returncode

    if PROGRESS_MODE == "quiet":
        return subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode

    # Compact mode suppresses raw transport diagnostics while preserving a
    # visible indication that local inference is active. Diagnostics remain
    # available by rerunning with --progress verbose.
    started = time.monotonic()
    interactive = sys.stderr.isatty()
    frames = ("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    frame_index = 0
    last_second = -1

    if not interactive:
        print(f"[*] {PROGRESS_LABEL} is working…", file=sys.stderr)

    try:
        while True:
            return_code = process.poll()
            elapsed = int(time.monotonic() - started)

            if return_code is not None:
                break

            if interactive and elapsed != last_second:
                frame = frames[frame_index % len(frames)]
                print(
                    f"\r\033[2K{frame} {PROGRESS_LABEL} is working… {elapsed}s",
                    end="",
                    file=sys.stderr,
                    flush=True,
                )
                frame_index += 1
                last_second = elapsed

            time.sleep(0.2)
    except KeyboardInterrupt:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

        if interactive:
            print("\r\033[2K", end="", file=sys.stderr, flush=True)
        print(
            f"[!] {PROGRESS_LABEL} generation interrupted.",
            file=sys.stderr,
        )
        return 130

    elapsed_text = f"{time.monotonic() - started:.1f}s"
    if interactive:
        print("\r\033[2K", end="", file=sys.stderr, flush=True)

    if return_code == 0:
        print(
            f"[✓] {PROGRESS_LABEL} replied in {elapsed_text}",
            file=sys.stderr,
        )
    else:
        print(
            f"[-] {PROGRESS_LABEL} dispatch failed after {elapsed_text} "
            f"(exit {return_code}); rerun with --progress verbose for details.",
            file=sys.stderr,
        )

    return return_code


def dispatch_messages(
    port: int,
    model_alias: str,
    messages: list,
    max_tokens: int,
) -> str:
    """Dispatch a structured chat-completions message list."""
    if not messages:
        print("[-] Refusing to dispatch an empty message list.", file=sys.stderr)
        return ""

    with tempfile.TemporaryDirectory() as tmpdir:
        payload_file = os.path.join(tmpdir, "request.json")
        payload = {
            "model": model_alias,
            "messages": messages,
            "max_tokens": max_tokens,
        }

        with open(payload_file, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)

        cmd = [
            sys.executable,
            LIBRARIAN_SCRIPT,
            "--port",
            str(port),
            "--payload",
            payload_file,
            "--outdir",
            tmpdir,
        ]

        return_code = run_librarian_with_progress(cmd)

        if return_code != 0:
            return ""

        output_file = os.path.join(tmpdir, "output.txt")
        reasoning_file = os.path.join(tmpdir, "reasoning.txt")

        # Show model reasoning separately when the librarian emits it, but do
        # not put hidden reasoning into assistant conversation history.
        #
        # This goes to STDERR deliberately. stdout carries exactly one thing —
        # the model's answer — so `local-agent … > answer.txt` stays usable from
        # a script, a pipeline, or another CLI. A reasoning model would otherwise
        # prepend its whole think block to the file and corrupt the answer.
        if os.path.isfile(reasoning_file):
            try:
                with open(reasoning_file, "r", encoding="utf-8") as f:
                    reasoning = f.read().strip()
                if reasoning:
                    print(
                        "--- Local Model Thinking ---\n"
                        f"{reasoning}\n"
                        "----------------------------",
                        file=sys.stderr,
                    )
            except OSError as exc:
                print(
                    f"[!] Could not read reasoning output: {exc}",
                    file=sys.stderr,
                )

        if not os.path.isfile(output_file):
            print(
                "[-] No output received from local model server.",
                file=sys.stderr,
            )
            return ""

        try:
            with open(output_file, "r", encoding="utf-8") as f:
                return f.read().strip()
        except OSError as exc:
            print(f"[-] Could not read model output: {exc}", file=sys.stderr)
            return ""


def run_single_prompt(
    port: int,
    model_alias: str,
    prompt_text: str,
    max_tokens: int,
) -> str:
    """Backward-compatible one-shot wrapper around structured messages."""
    return dispatch_messages(
        port,
        model_alias,
        [{"role": "user", "content": prompt_text}],
        max_tokens,
    )


def read_conversation_input() -> str:
    """
    Read one conversation turn.

    Normal input is submitted when Enter is pressed.
    Enter :paste to collect multiline input. End it with :end.
    """
    first_line = input("You> ")

    if first_line.strip() != ":paste":
        return first_line

    print(
        "Paste multiline text now. Finish with :end on its own line "
        "(or append :end to the final pasted line)."
    )
    lines = []

    while True:
        line = sys.stdin.readline()

        if line == "":
            raise EOFError

        line = line.rstrip("\r\n")

        if line == ":end":
            break

        # Handle a clipboard whose final line has no trailing newline,
        # causing the user-entered terminator to arrive as "last line:end".
        if line.endswith(":end"):
            final_line = line[:-len(":end")]
            if final_line:
                lines.append(final_line)
            break

        lines.append(line)

    return "\n".join(lines)



def normalize_user_input(text: str) -> str:
    """
    Remove one or more accidentally pasted terminal prompts from the
    beginning of a user turn, such as "You> You> explain this".

    Occurrences elsewhere are preserved so code and quoted transcripts
    are not modified.
    """
    cleaned, count = re.subn(
        r"^(?:[ \t]*You>[ \t]*)+",
        "",
        text,
        count=1,
        flags=re.IGNORECASE,
    )

    if count:
        print(
            "[i] Removed an accidental leading 'You>' prompt marker.",
            file=sys.stderr,
        )

    return cleaned


def model_display_label(model_alias: str) -> str:
    """Derive a short terminal label such as 'qwen' or 'devstral'."""
    label = re.split(r"[-_]", model_alias.strip(), maxsplit=1)[0]
    return label or model_alias


def history_char_count(history: list) -> int:
    """Return a conservative character count for retained raw messages."""
    return sum(len(turn.get("content", "")) for turn in history)


def compact_history_if_needed(
    history: list,
    rolling_summary: str,
    max_chars: int,
    port: int,
    model_alias: str,
    max_tokens: int,
):
    """
    Summarize the oldest complete turns before removing them.

    The newest complete turn is always retained verbatim. Raw history is
    returned unchanged if summarization fails.
    """
    if max_chars <= 0:
        return history, rolling_summary, 0

    total_chars = history_char_count(history) + len(rolling_summary)
    if total_chars <= max_chars:
        return history, rolling_summary, 0

    turn_pairs = [
        history[index:index + 2]
        for index in range(0, len(history), 2)
    ]

    if len(turn_pairs) < 2:
        print(
            "[!] Context exceeds the configured history budget, but the "
            "newest turn will not be discarded. Consider a larger "
            "--max-history-chars value.",
            file=sys.stderr,
        )
        return history, rolling_summary, 0

    # Leave roughly 55% of the budget for recent verbatim turns. The rolling
    # summary and the user's next message use the remaining headroom.
    recent_budget = max(1, int(max_chars * 0.55))
    retained_reversed = []
    retained_chars = 0

    for pair in reversed(turn_pairs):
        pair_chars = sum(len(turn.get("content", "")) for turn in pair)

        # Always retain the newest complete turn, even if it is unusually
        # large. Attachment-size controls will be handled separately.
        if not retained_reversed:
            retained_reversed.append(pair)
            retained_chars += pair_chars
            continue

        if retained_chars + pair_chars > recent_budget:
            break

        retained_reversed.append(pair)
        retained_chars += pair_chars

    retained_pairs = list(reversed(retained_reversed))
    compact_pair_count = len(turn_pairs) - len(retained_pairs)

    if compact_pair_count <= 0:
        print(
            "[!] Context exceeds the configured history budget, but no "
            "older complete turns can be compacted safely.",
            file=sys.stderr,
        )
        return history, rolling_summary, 0

    compact_pairs = turn_pairs[:compact_pair_count]
    compact_messages = [
        turn
        for pair in compact_pairs
        for turn in pair
    ]
    retained_history = [
        turn
        for pair in retained_pairs
        for turn in pair
    ]

    transcript_parts = []
    for turn in compact_messages:
        role = turn.get("role", "unknown").upper()
        transcript_parts.append(f"[{role}]\n{turn.get('content', '')}")

    previous_summary = rolling_summary.strip() or "(none)"
    transcript = "\n\n".join(transcript_parts)

    summary_instruction = f"""Maintain a compact, factual session memory.

Merge the previous rolling summary with the older conversation turns below.
Preserve decisions, user preferences, unresolved work, constraints, exact
identifiers, paths, commands, error messages, numeric values, and important
code literals. Do not invent facts. Do not include hidden reasoning. Write a
concise summary intended to restore context for future assistant turns.

PREVIOUS ROLLING SUMMARY:
{previous_summary}

OLDER TURNS TO COMPACT:
{transcript}
"""

    print(
        f"[i] Context is approaching its limit; compacting "
        f"{len(compact_messages)} older messages…",
        file=sys.stderr,
    )

    summary = dispatch_messages(
        port,
        model_alias,
        [{"role": "user", "content": summary_instruction}],
        min(max_tokens, 1536),
    )

    if not summary:
        print(
            "[!] History compaction failed; no raw messages were removed.",
            file=sys.stderr,
        )
        return history, rolling_summary, 0

    print(
        f"[✓] Compacted {len(compact_messages)} older messages into "
        "rolling session context.",
        file=sys.stderr,
    )
    return retained_history, summary, len(compact_messages)


def print_context_status(
    history: list,
    rolling_summary: str,
    max_chars: int,
    compacted_messages: int,
) -> None:
    """Print the current in-memory context state without calling the model."""
    raw_chars = history_char_count(history)
    summary_chars = len(rolling_summary)
    budget_text = "unlimited" if max_chars <= 0 else f"{max_chars:,} chars"

    print("\n--- Conversation Context ---")
    print(f"Raw messages retained: {len(history)}")
    print(f"Raw history size: {raw_chars:,} chars")
    print(f"Rolling summary: {'present' if rolling_summary else 'not created'}")
    print(f"Rolling summary size: {summary_chars:,} chars")
    print(f"Messages compacted this session: {compacted_messages}")
    print(f"Soft history compaction threshold: {budget_text}")
    print("----------------------------\n")



def validate_session_name(session_name: str) -> str:
    """Validate a portable session name and reject paths/traversal."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", session_name):
        raise ValueError(
            "Session names must be 1-80 characters, begin with a letter "
            "or digit, and contain only letters, digits, dot, underscore, "
            "or hyphen."
        )
    return session_name


def named_session_path(session_name: str) -> str:
    """Return the JSON path for a validated named session."""
    validated = validate_session_name(session_name)
    return os.path.join(SESSION_DIR, f"{validated}.json")


def save_named_session(
    session_name: str,
    model_alias: str,
    history: list,
    rolling_summary: str,
    compacted_messages: int,
) -> str:
    """Atomically save conversation state with owner-only permissions."""
    session_path = named_session_path(session_name)
    session_dir = os.path.dirname(session_path)
    os.makedirs(session_dir, mode=0o700, exist_ok=True)
    os.chmod(session_dir, 0o700)

    payload = {
        "schema_version": 1,
        "session_name": session_name,
        "model_alias": model_alias,
        "conversation_history": history,
        "rolling_summary": rolling_summary,
        "compacted_message_count": compacted_messages,
        "updated_at_unix": int(time.time()),
    }

    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{session_name}.",
        suffix=".tmp",
        dir=session_dir,
        text=True,
    )

    try:
        os.chmod(temporary_name, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, session_path)
        os.chmod(session_path, 0o600)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    return session_path


def load_named_session(
    session_name: str,
    requested_model: str,
    allow_model_mismatch: bool,
):
    """Load and validate a named session, or return empty state if new."""
    session_path = named_session_path(session_name)

    if not os.path.isfile(session_path):
        return [], "", 0, session_path, False

    try:
        with open(session_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Could not load session file {session_path}: {exc}") from exc

    if payload.get("schema_version") != 1:
        raise ValueError(
            f"Unsupported session schema in {session_path}: "
            f"{payload.get('schema_version')!r}"
        )

    saved_model = payload.get("model_alias")
    if saved_model != requested_model and not allow_model_mismatch:
        raise ValueError(
            f"Session '{session_name}' was saved with model "
            f"'{saved_model}', not '{requested_model}'. Use the saved model "
            "or pass --allow-session-model-mismatch deliberately."
        )

    history = payload.get("conversation_history")
    if not isinstance(history, list):
        raise ValueError("Session conversation_history must be a list.")

    validated_history = []
    for index, turn in enumerate(history):
        if not isinstance(turn, dict):
            raise ValueError(f"Session message {index} must be an object.")
        role = turn.get("role")
        content = turn.get("content")
        if role not in ("user", "assistant") or not isinstance(content, str):
            raise ValueError(
                f"Session message {index} has an invalid role or content."
            )
        validated_history.append({"role": role, "content": content})

    rolling_summary = payload.get("rolling_summary", "")
    compacted_messages = payload.get("compacted_message_count", 0)

    if not isinstance(rolling_summary, str):
        raise ValueError("Session rolling_summary must be a string.")
    if not isinstance(compacted_messages, int) or compacted_messages < 0:
        raise ValueError("Session compacted_message_count must be non-negative.")

    return (
        validated_history,
        rolling_summary,
        compacted_messages,
        session_path,
        True,
    )


def autosave_named_session(
    session_name,
    model_alias: str,
    history: list,
    rolling_summary: str,
    compacted_messages: int,
    announce: bool = False,
):
    """Save named state; ephemeral sessions remain entirely in memory."""
    if not session_name:
        return None

    try:
        session_path = save_named_session(
            session_name,
            model_alias,
            history,
            rolling_summary,
            compacted_messages,
        )
    except (OSError, ValueError) as exc:
        print(f"[!] Could not save session: {exc}", file=sys.stderr)
        return None

    if announce:
        print(f"[✓] Session saved: {session_path}", file=sys.stderr)
    return session_path


def main():
    global PROGRESS_MODE, PROGRESS_LABEL

    parser = argparse.ArgumentParser(description="AGY Local Model Dispatcher")
    parser.add_argument(
        "--model",
        default="qwen-3.6-operator",
        help="Local model alias (e.g. qwen-3.6-operator, deepseek-r1-architect, gemma-4-26b)",
    )
    parser.add_argument("--prompt", required=False, help="Task prompt for the local model")
    parser.add_argument("--files", nargs="*", help="Optional file paths to include as context")
    parser.add_argument("--max-tokens", type=int, default=4096, help="Max tokens to generate")
    parser.add_argument(
        "--max-history-chars",
        type=int,
        default=48000,
        help=(
            "Soft threshold for compacting older conversation history; "
            "the newest turn may exceed it; use 0 for unlimited"
        ),
    )
    parser.add_argument(
        "--max-file-chars",
        type=int,
        default=48000,
        help=(
            "Maximum characters per attached text file; oversized files "
            "are rejected; use 0 for unlimited"
        ),
    )
    parser.add_argument(
        "--session",
        help="Create or resume a named conversation session",
    )
    parser.add_argument(
        "--allow-session-model-mismatch",
        action="store_true",
        help="Deliberately resume a session using a different model alias",
    )
    parser.add_argument(
        "--progress",
        choices=("compact", "verbose", "quiet"),
        default="compact",
        help="Inference progress display (default: compact)",
    )
    parser.add_argument("--convo", action="store_true", help="Enable continuous conversation mode")
    
    args = parser.parse_args()
    assistant_label = model_display_label(args.model)
    PROGRESS_MODE = args.progress
    PROGRESS_LABEL = assistant_label

    # Validate arguments
    if not args.convo and not args.prompt:
        parser.error("--prompt is required unless --convo is specified.")

    if args.session and not args.convo:
        parser.error("--session requires --convo.")

    if args.allow_session_model_mismatch and not args.session:
        parser.error("--allow-session-model-mismatch requires --session.")

    if args.session:
        try:
            validate_session_name(args.session)
        except ValueError as exc:
            parser.error(str(exc))

    print(f"[*] Hotswapping local model '{args.model}'...", file=sys.stderr)
    port = hotswap_get_port(args.model)
    print(f"[✓] Local model ready on port {port}", file=sys.stderr)

    # --- CONVOLUTION MODE ---
    if args.convo:
        print("\n" + "="*60)
        print(f"CONVERSATION MODE ACTIVE — {assistant_label}")
        print("="*60)
        print("Type your prompt and press Enter.")
        print("Type ':paste' for multiline input; finish with ':end' on its own line.")
        print("Type ':file PATH' to attach a text file during this conversation.")
        print("Type ':context' for context usage or ':summary' to inspect compacted history.")
        print("Type ':session' for save status or ':save' to save explicitly.")
        print("Type 'exit', 'quit', or 'q' to end the session.")
        print("="*60 + "\n")

        # History for context: List of (role, content)
        # We store the full text including file contexts if they were added in the first prompt
        conversation_history = []
        rolling_summary = ""
        compacted_message_count = 0
        active_session_path = None

        if args.session:
            try:
                (
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                    active_session_path,
                    resumed_existing_session,
                ) = load_named_session(
                    args.session,
                    args.model,
                    args.allow_session_model_mismatch,
                )
            except ValueError as exc:
                print(f"[-] {exc}", file=sys.stderr)
                sys.exit(2)

            if resumed_existing_session:
                print(
                    f"[✓] Resumed session '{args.session}' with "
                    f"{len(conversation_history)} raw messages and "
                    f"{compacted_message_count} compacted messages.",
                    file=sys.stderr,
                )
            else:
                print(
                    f"[i] Starting new named session '{args.session}'.",
                    file=sys.stderr,
                )

        # If an initial prompt was provided, process it first
        if args.prompt:
            # Handle file attachments for the first prompt only (as per original script behavior)
            file_context = read_files_context(args.files, args.max_file_chars)
            initial_prompt = file_context + args.prompt
            
            print(f"User: {args.prompt}")
            if file_context:
                print(f"  (Files attached: {', '.join(args.files)})")
            
            initial_messages = []
            if rolling_summary:
                initial_messages.append(
                    {
                        "role": "system",
                        "content": (
                            "Rolling summary of earlier context in this "
                            "conversation process. Use it as memory, but "
                            "follow the user's current request:\n"
                            + rolling_summary
                        ),
                    }
                )
            initial_messages.extend(conversation_history)
            initial_messages.append({"role": "user", "content": initial_prompt})

            response = dispatch_messages(
                port,
                args.model,
                initial_messages,
                args.max_tokens,
            )

            if response:
                print(f"{assistant_label}: {response}\n")
                conversation_history.append(
                    {"role": "user", "content": initial_prompt}
                )
                conversation_history.append(
                    {"role": "assistant", "content": response}
                )
                active_session_path = autosave_named_session(
                    args.session,
                    args.model,
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                ) or active_session_path
            else:
                print(
                    f"{assistant_label}: "
                    "[No response received; the turn was not added to history.]\n"
                )

        # Start the loop
        while True:
            try:
                user_input = normalize_user_input(
                    read_conversation_input()
                )
            except (EOFError, KeyboardInterrupt):
                active_session_path = autosave_named_session(
                    args.session,
                    args.model,
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                ) or active_session_path
                print("\nGoodbye.")
                break

            if not user_input.strip():
                continue

            command = user_input.strip().lower()

            if command == ":file" or command.startswith(":file "):
                file_path = user_input.strip()[len(":file"):].strip()

                if (
                    len(file_path) >= 2
                    and file_path[0] == file_path[-1]
                    and file_path[0] in ("'", '"')
                ):
                    file_path = file_path[1:-1]

                if not file_path:
                    print("\n[!] Usage: :file PATH\n")
                    continue

                file_context = read_files_context(
                    [file_path],
                    args.max_file_chars,
                )
                if not file_context:
                    continue

                expanded_path = os.path.abspath(os.path.expanduser(file_path))
                print(f"[i] Attached file: {expanded_path}", file=sys.stderr)
                user_input = (
                    file_context
                    + "The user attached this file during the conversation. "
                    + "Read it as context and briefly acknowledge the attachment."
                )

            if command == ":session":
                if args.session:
                    print("\n--- Named Session ---")
                    print(f"Name: {args.session}")
                    print(f"Model: {args.model}")
                    print(f"Path: {active_session_path or named_session_path(args.session)}")
                    print("Autosave: enabled")
                    print("---------------------\n")
                else:
                    print(
                        "\n[i] This is an ephemeral session. Start with "
                        "--session NAME to enable save/resume.\n"
                    )
                continue

            if command == ":save":
                if not args.session:
                    print(
                        "\n[!] This session has no name. Restart with "
                        "--session NAME to enable saving.\n"
                    )
                    continue

                active_session_path = autosave_named_session(
                    args.session,
                    args.model,
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                    announce=True,
                ) or active_session_path
                continue

            if command == ":context":
                print_context_status(
                    conversation_history,
                    rolling_summary,
                    args.max_history_chars,
                    compacted_message_count,
                )
                continue

            if command == ":summary":
                if rolling_summary:
                    print(f"\n--- Rolling Summary ---\n{rolling_summary}\n-----------------------\n")
                else:
                    print("\n[i] No rolling summary has been created yet.\n")
                continue

            if command in ['exit', 'quit', 'q']:
                active_session_path = autosave_named_session(
                    args.session,
                    args.model,
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                ) or active_session_path
                print("Goodbye.")
                break

            (
                compacted_history,
                candidate_summary,
                newly_compacted,
            ) = compact_history_if_needed(
                conversation_history,
                rolling_summary,
                args.max_history_chars,
                port,
                args.model,
                args.max_tokens,
            )

            if newly_compacted:
                conversation_history = compacted_history
                rolling_summary = candidate_summary
                compacted_message_count += newly_compacted
                active_session_path = autosave_named_session(
                    args.session,
                    args.model,
                    conversation_history,
                    rolling_summary,
                    compacted_message_count,
                ) or active_session_path

            current_messages = []
            if rolling_summary:
                current_messages.append(
                    {
                        "role": "system",
                        "content": (
                            "Rolling summary of earlier context in this conversation process. "
                            "Use it as memory, but follow the user's current request:\n"
                            + rolling_summary
                        ),
                    }
                )

            current_messages.extend(
                {"role": turn["role"], "content": turn["content"]}
                for turn in conversation_history
            )
            current_messages.append({"role": "user", "content": user_input})

            response = dispatch_messages(
                port,
                args.model,
                current_messages,
                args.max_tokens,
            )

            if not response:
                print(
                    f"{assistant_label}: "
                    "[No response received; the turn was not added to history.]\n"
                )
                continue

            print(f"{assistant_label}: {response}\n")

            # Update history only after a successful response.
            conversation_history.append(
                {"role": "user", "content": user_input}
            )
            conversation_history.append(
                {"role": "assistant", "content": response}
            )
            active_session_path = autosave_named_session(
                args.session,
                args.model,
                conversation_history,
                rolling_summary,
                compacted_message_count,
            ) or active_session_path

    # --- SINGLE-SHOT MODE (Original Behavior) ---
    else:
        prompt_text = args.prompt
        if args.files:
            file_context = read_files_context(args.files, args.max_file_chars)
            prompt_text = file_context + prompt_text

        if args.progress == "verbose":
            print(
                f"[*] Dispatching prompt to local server (port {port})...",
                file=sys.stderr,
            )
        
        output_text = run_single_prompt(port, args.model, prompt_text, args.max_tokens)
        
        if output_text:
            print(output_text)
        else:
            print("[-] No output received from local model server.", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()