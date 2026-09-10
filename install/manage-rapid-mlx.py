#!/usr/bin/env python3
"""Manage versioned Rapid-MLX runtimes and local-agents runtime pins.

The manager discovers releases, installs or recreates exact versions in
~/.venvs/rapid-mlx-<version>, validates them, and promotes active local-agents
pins transactionally by default. It never starts a model server.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

PACKAGE = "rapid-mlx"
PYPI_URL = "https://pypi.org/pypi/rapid-mlx/json"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:([a-zA-Z]+)(\d+))?$")
SCHEMA = 2

# Only these live/configuration surfaces are promoted. Historical changelog and
# roadmap text, backups, evidence, and unrelated version-order fixtures are not.
PIN_FILES = (
    "bin/launch-claude-agent-rapid-auto.sh",
    "config/config-lib.sh",
    "config/config.example.sh",
    "tests/test_rapid_auto_mode.sh",
)
PRIVATE_PIN_FILE = "config/config.local.sh"
OPTIONAL_PIN_FILES = ("bin/local-inference-readonly-inventory.zsh",)
PATH_PIN_RE = re.compile(
    r"(?P<prefix>rapid-mlx-)(?P<version>\d+\.\d+\.\d+)(?P<suffix>/bin/(?:rapid-mlx|python))"
)
RAPID_AUTO_VERSION_RE = re.compile(r"rapid-mlx (?P<version>\d+\.\d+\.\d+)")


class ManagerError(RuntimeError):
    """A fail-closed manager error suitable for a concise CLI message."""


@dataclass(frozen=True)
class FileChange:
    path: Path
    before: bytes
    after: bytes
    private: bool
    mode: int


@dataclass(frozen=True)
class PinPlan:
    version: str
    changes: tuple[FileChange, ...]
    scanned: tuple[Path, ...]


def version_key(value: str) -> tuple[int, int, int, int, str, int]:
    match = VERSION_RE.fullmatch(value)
    if not match:
        raise ValueError(value)
    major, minor, patch, label, serial = match.groups()
    return (
        int(major), int(minor), int(patch),
        1 if label is None else 0, label or "", int(serial or 0),
    )


def require_version(value: str) -> str:
    try:
        version_key(value)
    except ValueError as exc:
        raise ManagerError(f"unsupported version syntax: {value!r}") from exc
    return value


def valid_versions(releases: dict[str, Any], include_prereleases: bool = False) -> list[str]:
    result: list[str] = []
    for version, files in releases.items():
        match = VERSION_RE.fullmatch(version)
        if not match or (match.group(4) and not include_prereleases):
            continue
        if not isinstance(files, list) or not files:
            continue
        if all(isinstance(item, dict) and item.get("yanked", False) for item in files):
            continue
        result.append(version)
    return sorted(result, key=version_key, reverse=True)


def fetch_releases(timeout: float = 15.0, include_prereleases: bool = False) -> list[str]:
    request = urllib.request.Request(
        PYPI_URL,
        headers={"Accept": "application/json", "User-Agent": "local-agents-rapid-manager/2"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise ManagerError(f"could not retrieve Rapid-MLX releases: {exc}") from exc
    releases = payload.get("releases") if isinstance(payload, dict) else None
    if not isinstance(releases, dict):
        raise ManagerError("PyPI response has no releases object")
    result = valid_versions(releases, include_prereleases)
    if not result:
        raise ManagerError("PyPI returned no usable Rapid-MLX releases")
    return result


def choose_version(releases: list[str], installed: set[str]) -> str:
    print("Available Rapid-MLX releases:")
    for index, version in enumerate(releases, 1):
        marker = "installed" if version in installed else ""
        print(f"  {index:2}. {version:14} {marker}")
    if not sys.stdin.isatty():
        raise ManagerError("interactive selection needs a TTY; pass a version explicitly")
    raw = input("Choose version number: ").strip()
    if not raw.isdigit() or not 1 <= int(raw) <= len(releases):
        raise ManagerError("invalid release selection")
    return releases[int(raw) - 1]


def venv_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".venvs"


def target_for(version: str, home: Path | None = None) -> Path:
    require_version(version)
    return venv_root(home) / f"rapid-mlx-{version}"


def cache_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".cache" / "local-agents" / "rapid-runtime-manager"


def receipt_path(version: str, home: Path | None = None) -> Path:
    return cache_root(home) / "receipts" / f"rapid-mlx-{version}.json"


def installed_versions(home: Path | None = None) -> list[tuple[str, Path, str]]:
    root = venv_root(home)
    entries: list[tuple[str, Path, str]] = []
    if not root.is_dir():
        return entries
    for path in root.glob("rapid-mlx-*"):
        if path.is_symlink() or not path.is_dir():
            continue
        version = path.name.removeprefix("rapid-mlx-")
        if not VERSION_RE.fullmatch(version):
            continue
        binary = path / "bin" / "rapid-mlx"
        state = "complete" if binary.is_file() and os.access(binary, os.X_OK) else "incomplete"
        entries.append((version, path, state))
    return sorted(entries, key=lambda item: version_key(item[0]), reverse=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(
    command: list[str], *, capture: bool = False, log: Path | None = None,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    if log is None:
        return subprocess.run(command, check=True, text=True, capture_output=capture, cwd=cwd)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as handle:
        handle.write("$ " + shlex.join(command) + "\n")
        handle.flush()
        process = subprocess.run(
            command, text=True, stdout=handle, stderr=subprocess.STDOUT, cwd=cwd,
        )
    if process.returncode:
        raise ManagerError(f"command failed with exit {process.returncode}; see {log}")
    return process


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def choose_python(explicit: str | None) -> Path:
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("LA_RAPID_BASE_PYTHON"):
        candidates.append(os.environ["LA_RAPID_BASE_PYTHON"])
    candidates.extend([sys.executable, "/opt/homebrew/bin/python3.14", "python3.14", "python3"])
    seen: set[str] = set()
    for candidate in candidates:
        resolved = shutil.which(candidate) if "/" not in candidate else candidate
        if not resolved:
            continue
        path = Path(resolved).expanduser().resolve()
        if str(path) in seen or not os.access(path, os.X_OK):
            continue
        seen.add(str(path))
        if subprocess.run([str(path), "-c", "import venv"], capture_output=True).returncode == 0:
            return path
    raise ManagerError("no Python with the stdlib venv module was found; pass --python")


def binary_version(binary: Path) -> str:
    try:
        result = run([str(binary), "--version"], capture=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ManagerError(f"could not execute {binary}: {exc}") from exc
    return result.stdout.strip() or result.stderr.strip()


def package_inventory(python: Path) -> dict[str, str]:
    code = """
import importlib.metadata, json
names=['rapid-mlx','mlx','mlx-metal','mlx-lm','mlx-vlm','transformers','tokenizers','huggingface-hub','llguidance']
out={}
for name in names:
    try: out[name]=importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError: out[name]='ABSENT'
print(json.dumps(out, sort_keys=True))
"""
    return json.loads(run([str(python), "-c", code], capture=True).stdout)


def validate_environment(version: str, target: Path) -> dict[str, Any]:
    if target.is_symlink() or not target.is_dir():
        raise ManagerError(f"environment is missing or unsafe: {target}")
    binary = target / "bin" / "rapid-mlx"
    python = target / "bin" / "python"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ManagerError(f"Rapid executable is missing: {binary}")
    observed = binary_version(binary)
    expected = f"rapid-mlx {version}"
    if observed != expected:
        raise ManagerError(f"expected {expected!r}, got {observed!r}")
    run([str(python), "-m", "pip", "check"], capture=True)
    return {
        "schema_version": SCHEMA,
        "version": version,
        "target": str(target),
        "rapid_version_output": observed,
        "rapid_binary_sha256": sha256_file(binary),
        "python": str(python),
        "python_version": run([str(python), "--version"], capture=True).stdout.strip(),
        "packages": package_inventory(python),
        "pip_freeze": [
            line for line in run([str(python), "-m", "pip", "freeze"], capture=True).stdout.splitlines()
            if line.strip()
        ],
        "validated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }


def locked_requirements(version: str, home: Path | None = None) -> list[str] | None:
    path = receipt_path(version, home)
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    lines = payload.get("pip_freeze") if isinstance(payload, dict) else None
    if payload.get("version") != version or not isinstance(lines, list):
        return None
    clean = [line for line in lines if isinstance(line, str) and line.strip()]
    normalized = {line.casefold().replace("_", "-") for line in clean}
    return clean if f"rapid-mlx=={version}" in normalized else None


def repository_root(explicit: Path | None = None) -> Path:
    candidate = (explicit or Path(__file__).resolve().parent.parent).expanduser().resolve()
    if not (candidate / ".git").exists():
        raise ManagerError(f"not a local-agents Git repository: {candidate}")
    return candidate


def tracked_repo_clean(repo: Path) -> None:
    unstaged = subprocess.run(["git", "diff", "--quiet"], cwd=repo).returncode
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=repo).returncode
    if unstaged or staged:
        raise ManagerError("pin promotion requires a clean tracked worktree and index")


def _replace_path_pins(text: str, version: str) -> str:
    return PATH_PIN_RE.sub(lambda m: m.group("prefix") + version + m.group("suffix"), text)


def plan_pin_update(repo: Path, version: str) -> PinPlan:
    require_version(version)
    repo = repo.resolve()
    changes: list[FileChange] = []
    scanned: list[Path] = []
    for relative in PIN_FILES + OPTIONAL_PIN_FILES + (PRIVATE_PIN_FILE,):
        path = repo / relative
        private = relative == PRIVATE_PIN_FILE
        if not path.exists():
            if private or relative in OPTIONAL_PIN_FILES:
                continue
            raise ManagerError(f"required pin surface is absent: {path}")
        if path.is_symlink() or not path.is_file():
            raise ManagerError(f"unsafe pin surface: {path}")
        before = path.read_bytes()
        try:
            text = before.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ManagerError(f"pin surface is not UTF-8: {path}") from exc
        output = _replace_path_pins(text, version)
        if relative in (
            "bin/launch-claude-agent-rapid-auto.sh",
            "tests/test_rapid_auto_mode.sh",
        ):
            output = RAPID_AUTO_VERSION_RE.sub(f"rapid-mlx {version}", output)
        after = output.encode("utf-8")
        scanned.append(path)
        if after != before:
            changes.append(FileChange(path, before, after, private, path.stat().st_mode & 0o777))
    required_invariants = {
        "bin/launch-claude-agent-rapid-auto.sh": (
            f"rapid-mlx-{version}/bin/rapid-mlx",
            f"rapid-mlx {version}",
        ),
        "config/config-lib.sh": (f"rapid-mlx-{version}/bin/rapid-mlx",),
        "config/config.example.sh": (f"rapid-mlx-{version}/bin/rapid-mlx",),
        "tests/test_rapid_auto_mode.sh": (f"rapid-mlx {version}",),
    }
    final_by_path = {
        str(path.relative_to(repo)): path.read_text(encoding="utf-8")
        for path in scanned
    }
    for change in changes:
        final_by_path[str(change.path.relative_to(repo))] = change.after.decode("utf-8")
    missing_invariants: list[str] = []
    for relative, markers in required_invariants.items():
        final = final_by_path.get(relative, "")
        for marker in markers:
            if marker not in final:
                missing_invariants.append(f"{relative}: {marker}")
    if missing_invariants:
        raise ManagerError(
            "pin surfaces are partially migrated or no longer match supported invariants: "
            + "; ".join(missing_invariants)
        )
    return PinPlan(version, tuple(changes), tuple(scanned))


def print_pin_plan(plan: PinPlan, repo: Path) -> None:
    print(f"Rapid-MLX pin plan: {plan.version}")
    if not plan.changes:
        print("  no changes (already promoted)")
        return
    for change in plan.changes:
        kind = "private" if change.private else "tracked"
        print(f"  {kind:7} {change.path.relative_to(repo)}")


def default_pin_validator(repo: Path, version: str) -> None:
    launcher = repo / "bin" / "launch-claude-agent-rapid-auto.sh"
    config = repo / "config" / "config-lib.sh"
    tests = repo / "tests" / "test_rapid_auto_mode.sh"
    for path in (launcher, config, tests):
        text = path.read_text(encoding="utf-8")
        if path.name != "test_rapid_auto_mode.sh" and f"rapid-mlx-{version}/bin/rapid-mlx" not in text:
            raise ManagerError(f"post-promotion versioned path missing from {path}")
        if path in (launcher, tests) and f"rapid-mlx {version}" not in text:
            raise ManagerError(f"post-promotion exact version assertion missing from {path}")
    compile_code = (
        "from pathlib import Path; "
        "[compile(Path(p).read_text(encoding='utf-8'), p, 'exec') "
        "for p in ('install/manage-rapid-mlx.py', 'tests/test_manage_rapid_mlx.py')]"
    )
    run([sys.executable, "-B", "-c", compile_code], cwd=repo)
    run(["bash", "tests/test_rapid_auto_mode.sh"], cwd=repo)
    run(["git", "diff", "--check"], cwd=repo)


def apply_pin_plan(
    plan: PinPlan, repo: Path, *, dry_run: bool = False,
    validator: Callable[[Path, str], None] | None = default_pin_validator,
    backup_root: Path | None = None,
) -> dict[str, Any]:
    repo = repo.resolve()
    print_pin_plan(plan, repo)
    if dry_run or not plan.changes:
        return {"result": "dry_run" if dry_run else "already_promoted", "changed": []}
    tracked_repo_clean(repo)
    transaction = backup_root or (
        cache_root() / "pin-transactions" /
        (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}")
    )
    transaction.mkdir(parents=True, exist_ok=False)
    os.chmod(transaction, 0o700)
    written: list[FileChange] = []
    manifest: list[dict[str, Any]] = []
    try:
        for change in plan.changes:
            relative = change.path.relative_to(repo)
            backup = transaction / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(change.before)
            os.chmod(backup, 0o600)
            if backup.read_bytes() != change.before:
                raise ManagerError(f"backup verification failed: {backup}")
            manifest.append({
                "path": str(relative),
                "before_sha256": hashlib.sha256(change.before).hexdigest(),
                "after_sha256": hashlib.sha256(change.after).hexdigest(),
                "private": change.private,
            })
        atomic_json(transaction / "manifest.json", {"version": plan.version, "files": manifest})
        for change in plan.changes:
            mode = change.mode
            fd, name = tempfile.mkstemp(prefix=change.path.name + ".", dir=change.path.parent)
            temporary = Path(name)
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(change.after)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, 0o600 if change.private else mode)
                os.replace(temporary, change.path)
            finally:
                temporary.unlink(missing_ok=True)
            written.append(change)
        if validator:
            validator(repo, plan.version)
        for change in plan.changes:
            if change.path.read_bytes() != change.after:
                raise ManagerError(f"post-write verification failed: {change.path}")
        return {
            "result": "promoted",
            "changed": [str(c.path.relative_to(repo)) for c in plan.changes],
            "transaction": str(transaction),
        }
    except Exception as exc:
        rollback_errors: list[str] = []
        for change in reversed(written):
            try:
                fd, name = tempfile.mkstemp(prefix=change.path.name + ".rollback.", dir=change.path.parent)
                temporary = Path(name)
                try:
                    with os.fdopen(fd, "wb") as handle:
                        handle.write(change.before)
                        handle.flush()
                        os.fsync(handle.fileno())
                    os.chmod(temporary, change.mode)
                    os.replace(temporary, change.path)
                finally:
                    temporary.unlink(missing_ok=True)
            except Exception as rollback_exc:  # pragma: no cover - catastrophic filesystem case
                rollback_errors.append(f"{change.path}: {rollback_exc}")
        if rollback_errors:
            raise ManagerError(
                f"pin promotion failed ({exc}); rollback also failed:\n" + "\n".join(rollback_errors)
            ) from exc
        raise ManagerError(f"pin promotion failed and was rolled back: {exc}") from exc


def promote_pins(version: str, repo: Path, *, dry_run: bool = False) -> dict[str, Any]:
    target = target_for(version)
    if not dry_run:
        validate_environment(version, target)
    plan = plan_pin_update(repo, version)
    return apply_pin_plan(plan, repo, dry_run=dry_run)


def install_environment(
    version: str, *, python_arg: str | None, refresh_deps: bool,
    home: Path | None, dry_run: bool,
) -> dict[str, Any]:
    target = target_for(version, home)
    if dry_run:
        lock = None if refresh_deps else locked_requirements(version, home)
        return {
            "result": "dry_run", "version": version, "target": str(target),
            "installation_mode": "locked_recreation" if lock else "fresh_resolution",
        }
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        receipt = validate_environment(version, target)
        receipt["result"] = "already_complete"
        atomic_json(receipt_path(version, home), receipt)
        return receipt
    base_python = choose_python(python_arg)
    log = cache_root(home) / "logs" / f"install-{version}-{dt.datetime.now().strftime('%Y%m%dT%H%M%S')}.log"
    created_target = True  # target was proven absent; clean partial venv failures too
    try:
        # Venv entry points contain absolute interpreter paths. Build at the
        # final absent target; moving a completed venv would leave stale shebangs.
        run([str(base_python), "-m", "venv", str(target)], log=log)
        child = target / "bin" / "python"
        lock = None if refresh_deps else locked_requirements(version, home)
        if lock:
            lock_path = target / ".rapid-runtime-lock.txt"
            lock_path.write_text("\n".join(lock) + "\n", encoding="utf-8")
            run([str(child), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(lock_path)], log=log)
            lock_path.unlink()
            mode = "locked_recreation"
        else:
            run([str(child), "-m", "pip", "install", "--disable-pip-version-check", f"{PACKAGE}=={version}"], log=log)
            mode = "fresh_resolution"
        receipt = validate_environment(version, target)
        receipt.update({
            "result": "installed", "installation_mode": mode,
            "base_python": str(base_python), "install_log": str(log),
        })
        atomic_json(receipt_path(version, home), receipt)
        return receipt
    except Exception:
        if created_target and target.exists() and not target.is_symlink():
            shutil.rmtree(target)
        raise


def install_and_maybe_promote(
    version: str, *, python_arg: str | None, refresh_deps: bool,
    home: Path | None, repo: Path, skip_pin_update: bool, dry_run: bool,
) -> dict[str, Any]:
    if not skip_pin_update and home is not None and home.resolve() != Path.home().resolve():
        raise ManagerError(
            "pin promotion is disabled with the test-only --home override; "
            "pass --skip-pin-update"
        )
    receipt = install_environment(
        version, python_arg=python_arg, refresh_deps=refresh_deps, home=home, dry_run=dry_run,
    )
    receipt["pin_update"] = "skipped" if skip_pin_update else "pending"
    if skip_pin_update:
        return receipt
    try:
        receipt["pin_promotion"] = promote_pins(version, repo, dry_run=dry_run)
        receipt["pin_update"] = "dry_run" if dry_run else "promoted"
    except Exception:
        receipt["pin_update"] = "failed_rolled_back"
        if not dry_run:
            atomic_json(receipt_path(version, home), receipt)
        raise
    if not dry_run:
        atomic_json(receipt_path(version, home), receipt)
    return receipt


def snapshot_environment(version: str, home: Path | None = None, *, dry_run: bool = False) -> Path:
    path = receipt_path(version, home)
    if dry_run:
        print(f"would write recreation receipt: {path}")
        return path
    receipt = validate_environment(version, target_for(version, home))
    receipt["result"] = "snapshot"
    atomic_json(path, receipt)
    return path


def smoke_environment(version: str, home: Path | None = None) -> dict[str, Any]:
    target = target_for(version, home)
    receipt = validate_environment(version, target)
    binary = target / "bin" / "rapid-mlx"
    top_help = run([str(binary), "--help"], capture=True).stdout
    serve_help = run([str(binary), "serve", "--help"], capture=True).stdout
    if "serve" not in top_help or "--host" not in serve_help:
        raise ManagerError("Rapid CLI smoke test did not find expected serve/help surfaces")
    return {"result": "smoke_pass", "version": version, "binary_sha256": receipt["rapid_binary_sha256"], "model_server_started": False}


def inspect_environment(version: str, output: Path | None, home: Path | None = None, *, dry_run: bool = False) -> Path:
    target = target_for(version, home)
    destination = (output or cache_root(home) / "inspections" / f"rapid-mlx-{version}.txt").expanduser()
    if dry_run:
        print(f"would inspect {target} and write {destination}")
        return destination
    receipt = validate_environment(version, target)
    binary = target / "bin" / "rapid-mlx"
    sections = [
        "=== RECEIPT ===\n" + json.dumps(receipt, indent=2, sort_keys=True),
        "=== TOP-LEVEL HELP ===\n" + run([str(binary), "--help"], capture=True).stdout,
        "=== SERVE HELP ===\n" + run([str(binary), "serve", "--help"], capture=True).stdout,
    ]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n\n".join(sections).rstrip() + "\n", encoding="utf-8")
    os.chmod(destination, 0o600)
    return destination


def referenced_paths(repo: Path, target: Path) -> list[str]:
    matches: list[str] = []
    for relative in PIN_FILES + OPTIONAL_PIN_FILES + (PRIVATE_PIN_FILE,):
        path = repo / relative
        if not path.is_file() or path.is_symlink():
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if str(target) in line or target.name in line:
                matches.append(f"{path}:{number}:{line.strip()}")
    return matches


def running_references(target: Path) -> list[str]:
    table = subprocess.check_output(["ps", "-Aww", "-o", "pid=,command="], text=True)
    own_pid = os.getpid()
    matches: list[str] = []
    for line in table.splitlines():
        stripped = line.strip()
        pid_text, separator, command = stripped.partition(" ")
        if not separator or not pid_text.isdigit() or int(pid_text) == own_pid:
            continue
        if str(target) in command:
            matches.append(line)
    return matches


def remove_environment(
    version: str, *, yes: bool, repo: Path, home: Path | None, dry_run: bool,
) -> None:
    target = target_for(version, home)
    if target.is_symlink() or not target.is_dir():
        raise ManagerError(f"refusing removal: not a real managed directory: {target}")
    validate_environment(version, target)
    if not locked_requirements(version, home):
        raise ManagerError(f"refusing removal without a valid recreation receipt; run snapshot {version}")
    try:
        Path(sys.executable).resolve().relative_to(target.resolve())
    except ValueError:
        pass
    else:
        raise ManagerError("refusing to remove the environment running this manager")
    running = running_references(target)
    if running:
        raise ManagerError("environment is referenced by running process(es):\n" + "\n".join(running))
    references = referenced_paths(repo, target)
    if references:
        raise ManagerError("environment is still pinned:\n" + "\n".join(references))
    if dry_run:
        print(f"would remove {target}")
        return
    if not yes:
        if not sys.stdin.isatty():
            raise ManagerError("removal requires a TTY or --yes")
        if input(f"Permanently remove {target}? Type 'delete {version}': ") != f"delete {version}":
            raise ManagerError("removal cancelled")
    shutil.rmtree(target)
    if target.exists() or target.is_symlink():
        raise ManagerError(f"removal verification failed: {target}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--repo", type=Path, help="local-agents repository (default: script repository)")
    parser.add_argument("--dry-run", action="store_true", help="print the plan without writing, installing, promoting, snapshotting, or deleting")
    sub = parser.add_subparsers(dest="command", required=True)
    releases = sub.add_parser("releases", help="list installable PyPI releases")
    releases.add_argument("--pre", action="store_true", help="include prereleases")
    releases.add_argument("--limit", type=int, default=20)
    sub.add_parser("installed", help="list local versioned environments")
    install_p = sub.add_parser("install", help="install/validate a release and promote pins by default")
    install_p.add_argument("version", nargs="?", help="omit for interactive release selection")
    install_p.add_argument("--pre", action="store_true", help="offer prereleases in picker")
    install_p.add_argument("--python", help="base Python executable")
    install_p.add_argument("--refresh-deps", action="store_true", help="ignore an existing recreation lock")
    install_p.add_argument("--skip-pin-update", action="store_true", help="install/validate without promoting repository/private active pins")
    install_p.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="print the install and promotion plan without writes")
    install_p.add_argument("--repo", type=Path, default=argparse.SUPPRESS, help="local-agents repository")
    promote = sub.add_parser("promote", help="transactionally promote active pins to an installed version")
    promote.add_argument("version")
    promote.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="print the pin plan without writes")
    promote.add_argument("--repo", type=Path, default=argparse.SUPPRESS, help="local-agents repository")
    snapshot = sub.add_parser("snapshot", help="save an exact recreation receipt")
    snapshot.add_argument("version")
    snapshot.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS)
    inspect_p = sub.add_parser("inspect", help="capture CLI/package evidence")
    inspect_p.add_argument("version")
    inspect_p.add_argument("--output", type=Path)
    inspect_p.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS)
    smoke = sub.add_parser("smoke", help="validate package and CLI surfaces without starting a server")
    smoke.add_argument("version")
    smoke.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS)
    remove_p = sub.add_parser("remove", help="remove an inactive, unpinned, reproducible venv")
    remove_p.add_argument("version")
    remove_p.add_argument("--yes", action="store_true", help="skip typed confirmation; safety gates still apply")
    remove_p.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="validate removal gates without deleting")
    remove_p.add_argument("--repo", type=Path, default=argparse.SUPPRESS, help="local-agents repository")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    home = args.home.expanduser() if args.home else None
    try:
        repo = repository_root(args.repo) if args.command in {"install", "promote", "remove"} else None
        if args.command == "releases":
            for version in fetch_releases(include_prereleases=args.pre)[:args.limit]:
                print(version)
        elif args.command == "installed":
            entries = installed_versions(home)
            print("\n".join(f"{v:14} {s:10} {p}" for v, p, s in entries) or "No versioned Rapid-MLX environments found.")
        elif args.command == "install":
            version = args.version
            if version is None:
                options = fetch_releases(include_prereleases=args.pre)[:30]
                version = choose_version(options, {entry[0] for entry in installed_versions(home)})
            receipt = install_and_maybe_promote(
                require_version(version), python_arg=args.python, refresh_deps=args.refresh_deps,
                home=home, repo=repo, skip_pin_update=args.skip_pin_update, dry_run=args.dry_run,
            )
            print(json.dumps(receipt, indent=2, sort_keys=True))
        elif args.command == "promote":
            print(json.dumps(promote_pins(require_version(args.version), repo, dry_run=args.dry_run), indent=2, sort_keys=True))
        elif args.command == "snapshot":
            print(snapshot_environment(require_version(args.version), home, dry_run=args.dry_run))
        elif args.command == "inspect":
            print(inspect_environment(require_version(args.version), args.output, home, dry_run=args.dry_run))
        elif args.command == "smoke":
            if args.dry_run:
                print(json.dumps({"result": "dry_run", "would_smoke": args.version}, indent=2))
            else:
                print(json.dumps(smoke_environment(require_version(args.version), home), indent=2, sort_keys=True))
        elif args.command == "remove":
            remove_environment(require_version(args.version), yes=args.yes, repo=repo, home=home, dry_run=args.dry_run)
            print(f"{'would remove' if args.dry_run else 'removed'} {target_for(args.version, home)}")
        return 0
    except (ManagerError, subprocess.CalledProcessError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
