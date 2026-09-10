#!/usr/bin/env zsh
#
# Read-only local-inference inventory for macOS.
#
# The script does not:
#   - use sudo;
#   - contact the network;
#   - install or upgrade packages;
#   - download models;
#   - import MLX or load model weights;
#   - start or stop services;
#   - modify Claude Code, runtime, Git, or model configuration;
#   - delete, move, rename, or chmod existing files.
#
# Its only writes are a new report directory and files inside that directory.
#
# Usage:
#   zsh ./local-inference-readonly-inventory.zsh
#   zsh ./local-inference-readonly-inventory.zsh /path/to/new-report-directory

emulate -L zsh
setopt NO_UNSET
setopt PIPE_FAIL
setopt EXTENDED_GLOB

export LC_ALL=C
export LANG=C

# Prevent accidental online behavior by Python/Hugging Face tooling inherited
# from the user's environment. The script does not invoke Hub download APIs.
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export PIP_NO_INDEX=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export DO_NOT_TRACK=1

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
default_output="$HOME/.claude/reports/local-inference-inventory-$timestamp"
output_dir="${1:-$default_output}"

if [[ -e "$output_dir" ]]; then
  print -u2 -- "Refusing to overwrite existing path: $output_dir"
  exit 2
fi

mkdir -p -- "$output_dir" || {
  print -u2 -- "Could not create report directory: $output_dir"
  exit 1
}

report="$output_dir/summary.txt"
warnings="$output_dir/warnings.txt"

: > "$report"
: > "$warnings"

section() {
  print -r -- "" >> "$report"
  print -r -- "================================================================" >> "$report"
  print -r -- "$1" >> "$report"
  print -r -- "================================================================" >> "$report"
}

run_report() {
  local title="$1"
  shift

  section "$title"
  print -r -- "\$ ${(q-)@}" >> "$report"

  "$@" >> "$report" 2>> "$warnings"
  local exit_code=$?

  if (( exit_code != 0 )); then
    print -r -- "[exit status: $exit_code]" >> "$report"
  fi

  return 0
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

hash_small_file() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    return 0
  fi

  local bytes
  bytes="$(stat -f '%z' "$file_path" 2>/dev/null || print 0)"

  # Metadata only. Avoid hashing unexpectedly large files.
  if [[ "$bytes" == <-> ]] && (( bytes <= 16777216 )); then
    shasum -a 256 -- "$file_path" 2>/dev/null | awk '{print $1}'
  else
    print -r -- "SKIPPED_SIZE_${bytes}"
  fi
}

print -r -- "Local inference read-only inventory" >> "$report"
print -r -- "Started UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$report"
print -r -- "Host: $(hostname 2>/dev/null || print unknown)" >> "$report"
print -r -- "Output: $output_dir" >> "$report"
print -r -- "Network operations requested: no" >> "$report"

section "SAFETY BOUNDARY"
cat >> "$report" <<'SAFETY_BOUNDARY'
This inventory performs local reads only, except for creating this report
directory and writing report files inside it.

It does not install, upgrade, download, delete, move, modify configuration,
start a model server, stop a process, import MLX, or load model weights.

Some filesystem scans may take several minutes when model caches are large.
SAFETY_BOUNDARY

run_report "DATE AND UPTIME" date
run_report "KERNEL AND ARCHITECTURE" uname -a
run_report "MACOS VERSION" sw_vers
run_report "HARDWARE SUMMARY" system_profiler SPHardwareDataType
run_report "MEMORY SIZE" sysctl hw.memsize
run_report "LOGICAL CPU COUNT" sysctl hw.logicalcpu
run_report "PHYSICAL CPU COUNT" sysctl hw.physicalcpu
run_report "UPTIME" uptime
run_report "POWER SOURCE" pmset -g batt
run_report "POWER SETTINGS" pmset -g custom
run_report "MEMORY PRESSURE" memory_pressure
run_report "VM STATISTICS" vm_stat
run_report "SWAP USAGE" sysctl vm.swapusage
run_report "FILESYSTEM CAPACITY" df -h
run_report "FILESYSTEM INODES" df -i

if [[ -x /usr/bin/thermal ]]; then
  run_report "THERMAL STATE" /usr/bin/thermal
else
  section "THERMAL STATE"
  print -r -- "The /usr/bin/thermal utility is unavailable." >> "$report"
fi

# ---------------------------------------------------------------------------
# Active processes
# ---------------------------------------------------------------------------

process_pattern='rapid-mlx|vllm-mlx|vllm_mlx|mlx[-_ ]?lm|mlx[-_ ]?vlm|omlx|llama-(server|cli|bench)|llama\.cpp|download-more-models|download-models|huggingface|hf download|python.*(serve|server|download)|mflux|comfyui|diffusers'

section "ACTIVE INFERENCE, MODEL, AND DOWNLOAD PROCESSES"
print -r -- "Pattern: $process_pattern" >> "$report"

ps -axo pid=,ppid=,user=,lstart=,etime=,%cpu=,%mem=,rss=,command= \
  | grep -Ei "$process_pattern" \
  | grep -Ev 'grep -E|local-inference-readonly-inventory' \
  >> "$report" 2>> "$warnings" || true

ps -axo pid=,ppid=,user=,lstart=,etime=,%cpu=,%mem=,rss=,command= \
  | grep -Ei "$process_pattern" \
  | grep -Ev 'grep -E|local-inference-readonly-inventory' \
  > "$output_dir/processes.txt" 2>> "$warnings" || true

section "LISTENING TCP PORTS"
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:LISTEN >> "$report" 2>> "$warnings" || true
  lsof -nP -iTCP -sTCP:LISTEN > "$output_dir/listening-ports.txt" \
    2>> "$warnings" || true
else
  print -r -- "lsof unavailable" >> "$report"
fi

section "OPEN MODEL FILES FROM MATCHING PROCESSES"
if command -v lsof >/dev/null 2>&1; then
  integer matched_pid_count=0

  for pid in ${(f)"$(
    ps -axo pid=,command= \
      | grep -Ei "$process_pattern" \
      | grep -Ev 'grep -E|local-inference-readonly-inventory' \
      | awk '{print $1}'
  )"}; do
    [[ "$pid" == <-> ]] || continue
    (( matched_pid_count += 1 ))

    print -r -- "--- PID $pid ---" >> "$report"
    lsof -nP -p "$pid" 2>> "$warnings" \
      | grep -Ei '\.(safetensors|gguf|bin|mlx|json|jinja|model|weights)([[:space:]]|$)|/\.models/|huggingface' \
      >> "$report" || true
  done

  if (( matched_pid_count == 0 )); then
    print -r -- "No matching active process found." >> "$report"
  fi
else
  print -r -- "lsof unavailable" >> "$report"
fi

# ---------------------------------------------------------------------------
# Runtime executables
# ---------------------------------------------------------------------------

runtime_tsv="$output_dir/runtime-executables.tsv"
print -r -- $'name\tresolved_path\tfile_type\tversion_output' > "$runtime_tsv"

runtime_commands=(
  rapid-mlx
  rmlx
  vllm-mlx
  vllm_mlx
  omlx
  mlx_lm.server
  mlx_lm.generate
  mlx_lm.convert
  llama-server
  llama-cli
  llama-bench
  llama-quantize
  hf
  huggingface-cli
  uv
  pipx
  python3
  python3.12
  git
  brew
)

for cmd in "${runtime_commands[@]}"; do
  executable_path="$(command_path "$cmd")"
  [[ -n "$executable_path" ]] || continue

  file_type="$(file -b -- "$executable_path" 2>/dev/null | tr '\t\r\n' '   ')"

  # Version probes only. Timeout prevents a malformed CLI from hanging.
  version_output=""
  if command -v perl >/dev/null 2>&1; then
    version_output="$(
      perl -e 'alarm shift; exec @ARGV' 5 "$executable_path" --version 2>/dev/null \
        | head -n 3 \
        | tr '\t\r\n' '   ' || true
    )"
  else
    version_output="$("$executable_path" --version 2>/dev/null | head -n 3 | tr '\t\r\n' '   ' || true)"
  fi

  print -r -- "${cmd}\t${executable_path}\t${file_type}\t${version_output}" \
    >> "$runtime_tsv"
done

section "RUNTIME EXECUTABLES"
column -t -s $'\t' "$runtime_tsv" >> "$report" 2>> "$warnings" \
  || cat "$runtime_tsv" >> "$report"

# ---------------------------------------------------------------------------
# Homebrew inventory
# ---------------------------------------------------------------------------

section "HOMEBREW RELEVANT PACKAGES"
if command -v brew >/dev/null 2>&1; then
  brew list --versions 2>> "$warnings" \
    | grep -Ei '(^| )(rapid-mlx|mlx|llama|python|uv|huggingface|cmake|ninja)( |$)' \
    >> "$report" || true

  brew --prefix >> "$report" 2>> "$warnings" || true
else
  print -r -- "Homebrew unavailable." >> "$report"
fi

# ---------------------------------------------------------------------------
# Python environment discovery without importing MLX
# ---------------------------------------------------------------------------

python_paths_file="$output_dir/python-interpreters.txt"
: > "$python_paths_file"

for candidate in \
  "$(command_path python3)" \
  "$(command_path python3.12)" \
  "$HOME/.rapid-mlx/bin/python" \
  "$HOME/.venvs/rapid-mlx-0.14.0/bin/python"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  print -r -- "${candidate:A}" >> "$python_paths_file"
done

python_search_roots=(
  "$HOME/.venvs"
  "$HOME/.virtualenvs"
  "$HOME/.local"
  "$HOME/.rapid-mlx"
  "$HOME/ClaudeWorkspace"
  "$HOME/.claude"
)

for root in "${python_search_roots[@]}"; do
  [[ -d "$root" ]] || continue

  find "$root" -maxdepth 6 -type f \
    \( -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.12' \) \
    -perm -111 -print 2>> "$warnings" \
    >> "$python_paths_file" || true
done

sort -u -o "$python_paths_file" "$python_paths_file"

packages_tsv="$output_dir/python-packages.tsv"
print -r -- $'python\tpython_version\tpackage\tversion\tlocation' > "$packages_tsv"

while IFS= read -r py; do
  [[ -x "$py" ]] || continue

  "$py" - "$packages_tsv" <<'PYTHON_PACKAGE_INVENTORY_A13C' 2>> "$warnings" || true
import importlib.metadata
import json
import os
import platform
import sys

output = sys.argv[1]
wanted = {
    "rapid-mlx",
    "vllm-mlx",
    "mlx",
    "mlx-lm",
    "mlx-vlm",
    "mlx-optiq",
    "omlx",
    "mflux",
    "transformers",
    "tokenizers",
    "huggingface-hub",
    "safetensors",
    "fastapi",
    "uvicorn",
    "torch",
}

python_version = platform.python_version()
python_path = os.path.realpath(sys.executable)

rows = []
for distribution in importlib.metadata.distributions():
    name = distribution.metadata.get("Name", "")
    normalized = name.lower().replace("_", "-")
    if normalized not in wanted:
        continue

    location = str(distribution.locate_file(""))
    version = distribution.version
    rows.append((normalized, version, location))

with open(output, "a", encoding="utf-8") as handle:
    for name, version, location in sorted(rows):
        fields = [python_path, python_version, name, version, location]
        safe = [field.replace("\t", " ").replace("\n", " ") for field in fields]
        handle.write("\t".join(safe) + "\n")
PYTHON_PACKAGE_INVENTORY_A13C
done < "$python_paths_file"

section "RELEVANT PYTHON PACKAGES"
column -t -s $'\t' "$packages_tsv" >> "$report" 2>> "$warnings" \
  || cat "$packages_tsv" >> "$report"

# ---------------------------------------------------------------------------
# Known configuration and catalog files
# ---------------------------------------------------------------------------

config_tsv="$output_dir/config-files.tsv"
print -r -- $'path\ttype\tbytes\tmtime_utc\tsha256_or_status' > "$config_tsv"

config_candidates=(
  "$HOME/.claude/settings.json"
  "$HOME/.claude/settings.local.json"
  "$HOME/.claude/scripts/download-more-models.sh"
  "$HOME/.claude/scripts/download-more-models.zsh"
  "$HOME/ClaudeWorkspace/local-agents/config/model-catalog.psv"
  "$HOME/ClaudeWorkspace/local-agents/config/model-catalog.local.psv"
  "$HOME/ClaudeWorkspace/local-agents/install/download-models.sh"
  "$HOME/ClaudeWorkspace/local-agents/pyproject.toml"
)

for config_path in "${config_candidates[@]}"; do
  [[ -e "$config_path" || -L "$config_path" ]] || continue

  type="$(file -b -- "$config_path" 2>/dev/null | tr '\t\r\n' '   ')"
  bytes="$(stat -f '%z' "$config_path" 2>/dev/null || print unknown)"
  epoch="$(stat -f '%m' "$config_path" 2>/dev/null || print 0)"
  mtime="$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || print unknown)"
  hash="$(hash_small_file "$config_path")"

  print -r -- "${config_path}\t${type}\t${bytes}\t${mtime}\t${hash}" \
    >> "$config_tsv"
done

section "KNOWN CONFIGURATION AND CATALOG FILES"
column -t -s $'\t' "$config_tsv" >> "$report" 2>> "$warnings" \
  || cat "$config_tsv" >> "$report"

# ---------------------------------------------------------------------------
# Model roots
# ---------------------------------------------------------------------------

model_roots_file="$output_dir/model-roots.txt"
: > "$model_roots_file"

model_root_candidates=(
  "$HOME/.models"
  "$HOME/models"
  "$HOME/Models"
  "$HOME/.cache/huggingface"
  "$HOME/.cache/huggingface/hub"
  "$HOME/Library/Caches/huggingface"
  "$HOME/Library/Application Support/ComfyUI/models"
  "$HOME/ComfyUI/models"
  "$HOME/ClaudeWorkspace/local-agents/models"
)

for variable_name in HF_HOME HUGGINGFACE_HUB_CACHE TRANSFORMERS_CACHE XDG_CACHE_HOME; do
  variable_value="${(P)variable_name-}"
  [[ -n "$variable_value" ]] || continue

  case "$variable_name" in
    HF_HOME)
      print -r -- "$variable_value" >> "$model_roots_file"
      print -r -- "$variable_value/hub" >> "$model_roots_file"
      ;;
    XDG_CACHE_HOME)
      print -r -- "$variable_value/huggingface" >> "$model_roots_file"
      ;;
    *)
      print -r -- "$variable_value" >> "$model_roots_file"
      ;;
  esac
done

for root in "${model_root_candidates[@]}"; do
  print -r -- "$root" >> "$model_roots_file"
done

awk 'NF && !seen[$0]++' "$model_roots_file" \
  | while IFS= read -r root; do
      [[ -d "$root" ]] && print -r -- "${root:A}"
    done \
  | sort -u \
  > "$model_roots_file.tmp"

mv -- "$model_roots_file.tmp" "$model_roots_file"

model_roots_tsv="$output_dir/model-roots.tsv"
print -r -- $'path\tfilesystem\tapparent_bytes\tallocated_kib\tfiles\tsymlinks' \
  > "$model_roots_tsv"

while IFS= read -r root; do
  [[ -d "$root" ]] || continue

  filesystem="$(df -P "$root" 2>/dev/null | tail -n 1 | awk '{print $1}')"
  apparent="$(du -skA "$root" 2>> "$warnings" | awk '{print $1 * 1024}')"
  allocated="$(du -sk "$root" 2>> "$warnings" | awk '{print $1}')"
  files="$(find "$root" -type f -print 2>> "$warnings" | wc -l | tr -d ' ')"
  symlinks="$(find "$root" -type l -print 2>> "$warnings" | wc -l | tr -d ' ')"

  print -r -- "${root}\t${filesystem}\t${apparent:-unknown}\t${allocated:-unknown}\t${files}\t${symlinks}" \
    >> "$model_roots_tsv"
done < "$model_roots_file"

section "MODEL AND CACHE ROOTS"
column -t -s $'\t' "$model_roots_tsv" >> "$report" 2>> "$warnings" \
  || cat "$model_roots_tsv" >> "$report"

# ---------------------------------------------------------------------------
# Model metadata scanner
# ---------------------------------------------------------------------------

models_tsv="$output_dir/models.tsv"
weights_tsv="$output_dir/weight-files.tsv"
duplicates_tsv="$output_dir/possible-large-file-duplicates.tsv"

python3 - "$model_roots_file" "$models_tsv" "$weights_tsv" "$duplicates_tsv" \
  <<'PYTHON_MODEL_INVENTORY_8D21' 2>> "$warnings" || true
import hashlib
import json
import os
import stat
import sys
from collections import defaultdict
from pathlib import Path

roots_file, models_out, weights_out, duplicates_out = sys.argv[1:]

CONFIG_NAMES = (
    "config.json",
    "adapter_config.json",
    "generation_config.json",
    "processor_config.json",
    "preprocessor_config.json",
    "video_preprocessor_config.json",
)

MARKER_NAMES = (
    ".complete",
    ".completed",
    ".download-complete",
    ".download_complete",
    "COMPLETE",
    "DOWNLOAD_COMPLETE",
)

WEIGHT_SUFFIXES = (
    ".safetensors",
    ".gguf",
    ".bin",
    ".npz",
    ".mlx",
)

MAX_METADATA_HASH_BYTES = 16 * 1024 * 1024
LARGE_FILE_THRESHOLD = 512 * 1024 * 1024


def clean(value):
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        value = ",".join(str(item) for item in value)
    if isinstance(value, dict):
        value = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def sha256_small(path):
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    if size > MAX_METADATA_HASH_BYTES:
        return f"SKIPPED_SIZE_{size}"
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while True:
                block = handle.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
    except OSError:
        return ""
    return digest.hexdigest()


def load_json(path):
    try:
        if path.stat().st_size > MAX_METADATA_HASH_BYTES:
            return {}, "too-large"
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle), "ok"
    except Exception as exc:
        return {}, f"{type(exc).__name__}: {exc}"


with open(roots_file, "r", encoding="utf-8") as handle:
    roots = [Path(line.strip()) for line in handle if line.strip()]

model_header = [
    "directory",
    "root",
    "config_status",
    "model_type",
    "architectures",
    "base_model",
    "quantization",
    "weight_files",
    "weight_bytes",
    "index_files",
    "metadata_sha256",
    "marker_files",
    "symlinks",
    "broken_symlinks",
]

weight_header = [
    "path",
    "bytes",
    "allocated_bytes",
    "inode",
    "links",
    "is_symlink",
    "target",
]

model_rows = []
weight_rows = []
large_by_size = defaultdict(list)
seen_weight_paths = set()

for root in roots:
    if not root.is_dir():
        continue

    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)

        # Avoid recursively revisiting nested VCS internals.
        dirs[:] = [
            name for name in dirs
            if name not in {".git", ".svn", "__pycache__"}
        ]

        config_path = current_path / "config.json"
        weight_names = [
            name for name in files
            if name.lower().endswith(WEIGHT_SUFFIXES)
        ]
        index_names = [
            name for name in files
            if name.endswith(".index.json")
        ]

        if config_path.is_file() or weight_names or index_names:
            config = {}
            config_status = "missing"

            if config_path.is_file():
                config, config_status = load_json(config_path)

            quant = config.get("quantization_config", "")
            if not quant:
                quant = config.get("quantization", "")
            if isinstance(quant, dict):
                quant = {
                    key: quant.get(key)
                    for key in (
                        "quant_method",
                        "bits",
                        "group_size",
                        "mode",
                    )
                    if key in quant
                }

            base_model = (
                config.get("_name_or_path")
                or config.get("base_model")
                or config.get("base_model_name_or_path")
                or ""
            )

            metadata_hash_parts = []
            for metadata_name in CONFIG_NAMES:
                metadata_path = current_path / metadata_name
                if metadata_path.is_file():
                    metadata_hash_parts.append(
                        f"{metadata_name}:{sha256_small(metadata_path)}"
                    )

            total_weight_bytes = 0
            symlink_count = 0
            broken_symlink_count = 0

            for name in weight_names:
                weight_path = current_path / name
                path_key = str(weight_path)
                if path_key in seen_weight_paths:
                    continue
                seen_weight_paths.add(path_key)

                try:
                    lst = weight_path.lstat()
                except OSError:
                    continue

                is_symlink = stat.S_ISLNK(lst.st_mode)
                target = ""
                if is_symlink:
                    symlink_count += 1
                    try:
                        target = os.readlink(weight_path)
                    except OSError:
                        target = ""
                    if not weight_path.exists():
                        broken_symlink_count += 1

                try:
                    st = weight_path.stat()
                    size = st.st_size
                    allocated = st.st_blocks * 512
                    inode = st.st_ino
                    links = st.st_nlink
                except OSError:
                    size = lst.st_size
                    allocated = lst.st_blocks * 512
                    inode = lst.st_ino
                    links = lst.st_nlink

                total_weight_bytes += size

                weight_rows.append([
                    str(weight_path),
                    size,
                    allocated,
                    inode,
                    links,
                    "yes" if is_symlink else "no",
                    target,
                ])

                if size >= LARGE_FILE_THRESHOLD:
                    large_by_size[size].append(
                        (str(weight_path), inode, links)
                    )

            marker_files = [
                name for name in MARKER_NAMES
                if (current_path / name).exists()
            ]

            model_rows.append([
                str(current_path),
                str(root),
                config_status,
                config.get("model_type", ""),
                config.get("architectures", ""),
                base_model,
                quant,
                len(weight_names),
                total_weight_bytes,
                len(index_names),
                ";".join(metadata_hash_parts),
                ",".join(marker_files),
                symlink_count,
                broken_symlink_count,
            ])

with open(models_out, "w", encoding="utf-8") as handle:
    handle.write("\t".join(model_header) + "\n")
    for row in sorted(model_rows, key=lambda item: item[0]):
        handle.write("\t".join(clean(item) for item in row) + "\n")

with open(weights_out, "w", encoding="utf-8") as handle:
    handle.write("\t".join(weight_header) + "\n")
    for row in sorted(weight_rows, key=lambda item: item[0]):
        handle.write("\t".join(clean(item) for item in row) + "\n")

with open(duplicates_out, "w", encoding="utf-8") as handle:
    handle.write("bytes\tinode\tlinks\tpath\n")
    for size, entries in sorted(large_by_size.items(), reverse=True):
        if len(entries) < 2:
            continue
        for path, inode, links in sorted(entries):
            handle.write(
                "\t".join(clean(item) for item in (size, inode, links, path))
                + "\n"
            )
PYTHON_MODEL_INVENTORY_8D21

section "DISCOVERED MODEL DIRECTORIES"
if [[ -s "$models_tsv" ]]; then
  print -r -- "Full table: $models_tsv" >> "$report"
  awk -F '\t' '
    NR == 1 {
      print "directory\tmodel_type\tarchitectures\tquantization\tweight_files\tweight_bytes\tmarkers\tbroken_symlinks"
      next
    }
    {
      print $1 "\t" $4 "\t" $5 "\t" $7 "\t" $8 "\t" $9 "\t" $12 "\t" $14
    }
  ' "$models_tsv" \
    | column -t -s $'\t' >> "$report" 2>> "$warnings" \
    || true
else
  print -r -- "No model table generated." >> "$report"
fi

section "POSSIBLE LARGE-FILE DUPLICATES"
print -r -- "This groups files by byte size only; it is not proof of identical content." \
  >> "$report"
if [[ -s "$duplicates_tsv" ]]; then
  cat "$duplicates_tsv" >> "$report"
else
  print -r -- "No duplicate-size report generated." >> "$report"
fi

# ---------------------------------------------------------------------------
# Local Git repository identity
# ---------------------------------------------------------------------------

git_tsv="$output_dir/git-repositories.tsv"
print -r -- $'repository\thead\tbranch\torigin\tdirty_entries' > "$git_tsv"

git_search_roots=(
  "$HOME/ClaudeWorkspace/local-agents"
  "$HOME/.claude"
  "$HOME/ClaudeWorkspace"
)

typeset -A seen_git_roots

for search_root in "${git_search_roots[@]}"; do
  [[ -d "$search_root" ]] || continue

  while IFS= read -r dotgit; do
    repo="${dotgit:h}"
    [[ -n "${seen_git_roots[$repo]-}" ]] && continue
    seen_git_roots[$repo]=1

    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || print unknown)"
    branch="$(git -C "$repo" branch --show-current 2>/dev/null || print detached)"
    [[ -n "$branch" ]] || branch="detached"
    origin="$(git -C "$repo" remote get-url origin 2>/dev/null || print none)"
    dirty="$(git -C "$repo" status --porcelain=v1 -uno 2>/dev/null | wc -l | tr -d ' ')"

    print -r -- "${repo}\t${head}\t${branch}\t${origin}\t${dirty}" \
      >> "$git_tsv"
  done < <(
    find "$search_root" -maxdepth 5 -type d -name .git -print 2>> "$warnings"
  )
done

section "LOCAL GIT REPOSITORIES"
column -t -s $'\t' "$git_tsv" >> "$report" 2>> "$warnings" \
  || cat "$git_tsv" >> "$report"

# ---------------------------------------------------------------------------
# Final manifest
# ---------------------------------------------------------------------------

section "REPORT FILES"
find "$output_dir" -maxdepth 1 -type f -print \
  | sort \
  >> "$report" 2>> "$warnings" || true

print -r -- "Completed UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$report"

# Hash only the generated inventory reports.
(
  cd "$output_dir" || exit 1
  for generated in *(N-.); do
    [[ "$generated" == "SHA256SUMS.txt" ]] && continue
    shasum -a 256 -- "$generated"
  done | sort > SHA256SUMS.txt
) 2>> "$warnings" || true

print -r -- ""
print -r -- "Inventory complete."
print -r -- "Report directory: $output_dir"
print -r -- "Primary summary:  $report"
print -r -- "Warnings:         $warnings"
print -r -- ""
print -r -- "No installation, download, deletion, service launch, or configuration edit was requested."
