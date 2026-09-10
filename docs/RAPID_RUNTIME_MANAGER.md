# Rapid-MLX runtime manager

`install/manage-rapid-mlx.py` is the repository-owned lifecycle tool for versioned Rapid-MLX environments under:

```text
~/.venvs/rapid-mlx-<version>
```

It replaces one-off installers with one tested workflow for release discovery, exact upgrades/downgrades, deterministic recreation, smoke inspection, transactional pin promotion, and guarded retirement.

## Help and discovery

```bash
python3 install/manage-rapid-mlx.py --help
python3 install/manage-rapid-mlx.py install --help
python3 install/manage-rapid-mlx.py releases
python3 install/manage-rapid-mlx.py installed
```

Running `install` without a version fetches stable PyPI releases and opens an interactive chooser:

```bash
python3 install/manage-rapid-mlx.py install
```

Explicit versions support upgrades, downgrades, and recreation:

```bash
python3 install/manage-rapid-mlx.py install 0.14.1
python3 install/manage-rapid-mlx.py install 0.13.4
```

## Dry-run and pin promotion

Installation promotes active Rapid pins by default after the environment validates. Promotion covers the dedicated Auto Mode launcher/config/test, the shipped example pin, the private `config/config.local.sh` pin when present, and the optional read-only inventory pin.

```bash
# Plan both installation and pin promotion; write nothing
python3 install/manage-rapid-mlx.py install 0.14.1 --dry-run

# Install/validate but leave active pins untouched
python3 install/manage-rapid-mlx.py install 0.14.1 --skip-pin-update

# Promote an already installed version later
python3 install/manage-rapid-mlx.py promote 0.14.1 --dry-run
python3 install/manage-rapid-mlx.py promote 0.14.1
```

Pin promotion is transactional. It requires a clean tracked worktree and index, saves private backups and hashes, writes atomically, runs the dedicated Rapid Auto Mode test, and rolls every edited pin file back if validation fails. A successful installation is retained if later promotion fails; the receipt records that distinction.

Historical changelog/roadmap prose, backups, old evidence, and unrelated version-order test fixtures are not rewritten.

## Receipts, recreation, and dependency refresh

Each successful installation records an executable hash, package inventory, and exact `pip freeze` under:

```text
~/.cache/local-agents/rapid-runtime-manager/receipts/
```

When reinstalling a missing version, the manager uses its valid receipt as a dependency lock. Use `--refresh-deps` only when intentionally requesting a fresh dependency resolution.

For an environment created before the manager:

```bash
python3 install/manage-rapid-mlx.py snapshot 0.14.0
```

## Inspection and smoke test

Neither command starts a model server:

```bash
python3 install/manage-rapid-mlx.py inspect 0.14.0
python3 install/manage-rapid-mlx.py smoke 0.14.0
```

`smoke` verifies the exact Rapid version, `pip check`, package identity, top-level help, and `serve --help`. Runtime/model qualification remains separate: serve a real model, test Anthropic protocol behavior, changed-prefix reuse, concurrency, memory, and a real Claude Code session before release promotion.

## Guarded retirement

```bash
python3 install/manage-rapid-mlx.py remove 0.12.18 --dry-run
python3 install/manage-rapid-mlx.py remove 0.12.18
```

Removal refuses:

- symlinked, malformed, incomplete, or version-mismatched targets;
- the environment currently running the manager;
- running processes referencing the target;
- any active repository/private pin;
- a target without a valid exact recreation receipt.

Interactive removal requires typing `delete <version>`. `--yes` suppresses only that prompt; it bypasses no safety gate. Runtime retirement never deletes model weights.

## Lifecycle and release policy

```text
discover → dry-run → install isolated → smoke/inspect → promote pins → runtime qualification → merge/release → observe → retire superseded venv
```

The manager has its own deterministic test:

```bash
python3 -m py_compile install/manage-rapid-mlx.py tests/test_manage_rapid_mlx.py
python3 tests/test_manage_rapid_mlx.py
```

Develop manager changes on a dedicated feature branch. Merge only after the deterministic suite and `smoke <target-version>` pass. Installation or CLI smoke success alone does not qualify Auto Mode or a model.
