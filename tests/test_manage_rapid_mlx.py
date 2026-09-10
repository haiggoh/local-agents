#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "install" / "manage-rapid-mlx.py"
spec = importlib.util.spec_from_file_location("rapid_manager", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

passed = 0
failed: list[str] = []


def check(condition: bool, label: str) -> None:
    global passed
    if condition:
        passed += 1
        print(f"  PASS: {label}")
    else:
        failed.append(label)
        print(f"  FAIL: {label}")


def raises(callable_, label: str) -> None:
    try:
        callable_()
    except module.ManagerError:
        check(True, label)
    else:
        check(False, label)


def create_repo(root: Path, version: str = "0.13.4", private: str = "0.12.18") -> Path:
    repo = root / "repo"
    (repo / ".git").mkdir(parents=True)
    for relative in module.PIN_FILES:
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative == "bin/launch-claude-agent-rapid-auto.sh":
            text = (
                f': "${{LA_RAPID_AUTO_BIN:=$HOME/.venvs/rapid-mlx-{version}/bin/rapid-mlx}}"\n'
                f'rapid_auto_version="rapid-mlx {version}"\n'
            )
        elif relative == "config/config-lib.sh":
            text = f': "${{LA_RAPID_AUTO_BIN:=$HOME/.venvs/rapid-mlx-{version}/bin/rapid-mlx}}"\n'
        elif relative == "config/config.example.sh":
            text = f'# LA_RAPID_BIN="$HOME/.venvs/rapid-mlx-0.13.2/bin/rapid-mlx"\n'
        else:
            text = f"grep -qF 'rapid-mlx {version}' launcher\nprintf 'rapid-mlx {version}'\n"
        path.write_text(text, encoding="utf-8")
    local = repo / module.PRIVATE_PIN_FILE
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_text(f'LA_RAPID_BIN="$HOME/.venvs/rapid-mlx-{private}/bin/rapid-mlx"\n', encoding="utf-8")
    return repo.resolve()


print("== versions and release selection ==")
check(module.version_key("0.14.0") > module.version_key("0.13.4"), "versions sort numerically")
check(module.version_key("0.14.0") > module.version_key("0.14.0rc1"), "stable sorts above prerelease")
raises(lambda: module.target_for("../../escape", Path("/tmp/home")), "unsafe version cannot escape managed root")
releases = {"0.14.0": [{"yanked": False}], "0.15.0rc1": [{"yanked": False}], "0.13.4": [{"yanked": True}], "bad": [{}]}
check(module.valid_versions(releases) == ["0.14.0"], "stable listing excludes prerelease/yanked/malformed")
check(module.valid_versions(releases, True) == ["0.15.0rc1", "0.14.0"], "prerelease listing is explicit")

print("== installed state and private receipts ==")
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    root = home / ".venvs"
    root.mkdir()
    complete = root / "rapid-mlx-0.14.0"
    (complete / "bin").mkdir(parents=True)
    binary = complete / "bin" / "rapid-mlx"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    binary.chmod(0o700)
    (root / "rapid-mlx-0.13.4").mkdir()
    entries = module.installed_versions(home)
    check(entries[0][0] == "0.14.0" and entries[0][2] == "complete", "complete environment detected")
    check(entries[1][2] == "incomplete", "incomplete environment stays unhealthy")
    receipt = home / "receipt.json"
    module.atomic_json(receipt, {"ok": True})
    check(stat.S_IMODE(receipt.stat().st_mode) == 0o600, "receipt mode is private")
    lock_path = module.receipt_path("0.14.0", home)
    module.atomic_json(lock_path, {"version": "0.14.0", "pip_freeze": ["rapid-mlx==0.14.0", "mlx==0.32.2"]})
    check(module.locked_requirements("0.14.0", home) is not None, "valid recreation lock recovered")
    module.atomic_json(lock_path, {"version": "0.14.0", "pip_freeze": ["mlx==0.32.2"]})
    check(module.locked_requirements("0.14.0", home) is None, "receipt without Rapid pin rejected")

print("== pin planning ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    plan = module.plan_pin_update(repo, "0.14.0")
    changed = {str(item.path.relative_to(repo)) for item in plan.changes}
    check(changed == set(module.PIN_FILES + (module.PRIVATE_PIN_FILE,)), "all and only active pin surfaces planned")
    check(all(b"0.14.0" in item.after for item in plan.changes), "all planned outputs contain target version")
    check(all(b"0.13.4" not in item.after and b"0.12.18" not in item.after and b"0.13.2" not in item.after for item in plan.changes), "supported old active pins removed from outputs")
    before = {item.path: item.path.read_bytes() for item in plan.changes}
    result = module.apply_pin_plan(plan, repo, dry_run=True, validator=None)
    check(result["result"] == "dry_run" and all(path.read_bytes() == data for path, data in before.items()), "pin dry-run writes nothing")

print("== transactional promotion and private mode ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    plan = module.plan_pin_update(repo, "0.14.0")
    transaction = root / "transaction"
    module.tracked_repo_clean = lambda _repo: None
    result = module.apply_pin_plan(plan, repo, validator=lambda _repo, _version: None, backup_root=transaction)
    check(result["result"] == "promoted", "pin transaction reports promotion")
    check(all(b"0.14.0" in item.path.read_bytes() for item in plan.changes), "pin transaction writes every target")
    private = repo / module.PRIVATE_PIN_FILE
    check(stat.S_IMODE(private.stat().st_mode) == 0o600, "private overlay remains mode 600")
    check((transaction / "manifest.json").is_file(), "transaction manifest retained")
    check(not module.plan_pin_update(repo, "0.14.0").changes, "second promotion is an idempotent no-op")

print("== bytecode-free post-promotion validation ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    commands: list[list[str]] = []
    original_run = module.run
    try:
        module.run = lambda command, **_kwargs: commands.append(command)
        module.default_pin_validator(repo, "0.13.4")
    finally:
        module.run = original_run
    compile_command = commands[0]
    check(
        compile_command[:3] == [sys.executable, "-B", "-c"]
        and "py_compile" not in compile_command
        and "compile(" in compile_command[3],
        "post-promotion syntax validation cannot create repository bytecode",
    )

print("== full rollback on validator failure ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    plan = module.plan_pin_update(repo, "0.14.0")
    before = {item.path: item.path.read_bytes() for item in plan.changes}
    before_modes = {item.path: stat.S_IMODE(item.path.stat().st_mode) for item in plan.changes}
    module.tracked_repo_clean = lambda _repo: None
    def fail_validator(_repo: Path, _version: str) -> None:
        raise module.ManagerError("planted validator failure")
    raises(lambda: module.apply_pin_plan(plan, repo, validator=fail_validator, backup_root=root / "transaction"), "validator failure is reported")
    check(all(path.read_bytes() == data for path, data in before.items()), "validator failure rolls back every file")
    check(all(stat.S_IMODE(path.stat().st_mode) == mode for path, mode in before_modes.items()), "rollback restores every original file mode")

print("== partial migration and unsafe files fail closed ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    path = repo / "config" / "config-lib.sh"
    path.write_text("no supported Rapid pin here\n", encoding="utf-8")
    raises(lambda: module.plan_pin_update(repo, "0.14.0"), "missing supported anchor refuses partial migration")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root, version="0.14.0", private="0.14.0")
    (repo / "config" / "config-lib.sh").write_text("no Rapid pin here\n", encoding="utf-8")
    raises(lambda: module.plan_pin_update(repo, "0.14.0"), "unsupported no-diff surface is not misreported as promoted")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    path = repo / "config" / "config-lib.sh"
    path.unlink()
    path.symlink_to(repo / "config" / "config.example.sh")
    raises(lambda: module.plan_pin_update(repo, "0.14.0"), "symlinked pin surface rejected")

print("== install dry-run and skip-pin semantics ==")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = create_repo(root)
    home = root / "home"
    receipt = module.install_and_maybe_promote(
        "0.14.1", python_arg=None, refresh_deps=False, home=home, repo=repo,
        skip_pin_update=True, dry_run=True,
    )
    check(receipt["result"] == "dry_run" and receipt["pin_update"] == "skipped", "skip-pin dry-run is explicit")
    check(not (home / ".venvs").exists() and not module.receipt_path("0.14.1", home).exists(), "install dry-run creates no venv or receipt")
    raises(
        lambda: module.install_and_maybe_promote(
            "0.14.1", python_arg=None, refresh_deps=False, home=home, repo=repo,
            skip_pin_update=False, dry_run=True,
        ),
        "home override refuses promotion before installation",
    )
    check(not (home / ".venvs").exists(), "failed home-override preflight creates no venv")

print("== help and command surface ==")
parser = module.build_parser()
help_text = parser.format_help()
check("--dry-run" in help_text and "install" in help_text and "promote" in help_text and "smoke" in help_text, "root help advertises manager controls")
install_parser = next(action for action in parser._actions if hasattr(action, "choices") and action.choices).choices["install"]
check("--skip-pin-update" in install_parser.format_help(), "install help advertises skip-pin option")

print(f"\n{passed} passed, {len(failed)} failed")
for label in failed:
    print(f"  FAILED: {label}")
raise SystemExit(1 if failed else 0)
