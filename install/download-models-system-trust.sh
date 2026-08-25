#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd -P
)"

DOWNLOADER="$SCRIPT_DIR/download-models.sh"
HF_CLI="${LA_HF_SYSTEM_TRUST_CLI:-$HOME/.local/hf-system-trust/bin/hf}"

if [[ ! -x "$DOWNLOADER" ]]; then
  printf 'ERROR: downloader is missing or not executable: %s\n' \
    "$DOWNLOADER" >&2
  exit 1
fi

if [[ ! -x "$HF_CLI" ]]; then
  printf 'ERROR: system-trust Hugging Face client is missing or not executable: %s\n' \
    "$HF_CLI" >&2
  exit 1
fi

HF_CLI_DIR="$(
  cd -- "$(dirname -- "$HF_CLI")"
  pwd -P
)"

HF_CLI_NAME="$(basename -- "$HF_CLI")"

if [[ "$HF_CLI_NAME" != "hf" ]]; then
  printf 'ERROR: the configured client must be an executable named hf: %s\n' \
    "$HF_CLI" >&2
  exit 1
fi

HF_CLI="$HF_CLI_DIR/$HF_CLI_NAME"

export PATH="$HF_CLI_DIR:$PATH"

# Forward-compatible with a future downloader that supports LA_HF_CLI
# directly. The current downloader resolves this client through PATH.
export LA_HF_CLI="$HF_CLI"

RESOLVED_HF="$(command -v hf || true)"

if [[ "$RESOLVED_HF" != "$HF_CLI" ]]; then
  printf 'ERROR: failed to select the system-trust Hugging Face client.\n' >&2
  printf 'Expected: %s\n' "$HF_CLI" >&2
  printf 'Resolved: %s\n' "${RESOLVED_HF:-<none>}" >&2
  exit 1
fi

printf 'Hugging Face CLI: %s\n' "$HF_CLI" >&2
printf 'TLS trust mode: system (native operating-system trust)\n' >&2

exec "$DOWNLOADER" "$@"
