---
name: guard-shared-runtime
description: 'Use BEFORE modifying the local execution environment (installing packages, upgrading dependencies, changing config) or when the local inference server behaves unexpectedly. Triggered by dependency changes, reinstall checks, or server wedges. Do NOT use for verifying output, isolating work, or composing payloads.'
---

# guard-shared-runtime — protect the shared environment

The local runtime (Python env, vllm-mlx server, config files) is shared across sessions and dispatches. Blind upgrades or unchecked failures can break subsequent work.

## Check-don't-blind-upgrade
Before installing or upgrading any dependency in the shared virtual environment:
1. **Dry-run:** Simulate the change to detect transitive churn. `--dry-run` resolves and reports what it
   *would* install without touching the environment; it needs **pip >= 22.2** (check with `pip --version`).
   ```bash
   pip install --dry-run <package>
   ```
   Read the resolved set, not just the headline: a dependency being *downgraded* or *added* is the churn you
   are looking for.
2. **Verify stability:** Ensure no critical packages are downgraded or removed.
3. **Defer if risky:** If the dry-run shows significant churn, defer the upgrade to a supervised moment or use an isolated environment for that specific task.

## Verify fork patches survived reinstall
If you maintain local fork patches (e.g., for vllm-mlx or Claude Code hooks):
1. **Check integrity:** After any reinstall or update, verify that your patches are still applied.
2. **Run diagnostics:** Use the plugin’s diagnostic harnesses (e.g., `direct-route-acceptance.py`) to confirm the server behaves as expected.

## Wedged single-slot servers
A single-slot server (like vllm-mlx) can become **wedged**: the health endpoint returns `200 OK`, but generation is permanently stuck. This is not a timeout; it is a deadlock.

### Symptoms
- Health check (`/health`) returns `200`.
- Dispatches hang indefinitely or return empty/partial responses.
- No CPU/GPU activity despite pending requests.

### Diagnosis
1. **Probe with a real generation:** Send a trivial prompt (e.g., "Say hello") with a bounded wait. Use the HTTP client's own limit (`curl -m 20`) rather than a `timeout` wrapper — `timeout` is a GNU coreutils binary and is **not present by default on macOS**, so a `timeout`-based recipe silently fails there.
2. **If it hangs:** The server is wedged. Slow responses are normal for large models; permanent hangs are not.

### Recovery
1. **SIGTERM the server:** Send `SIGTERM` to the vllm-mlx process. It frees the port in ~2 seconds.
   ```bash
   kill -TERM <pid>
   ```
2. **Restart:** Launch a new instance on the same or a new port.
3. **Do NOT pkill:** Avoid `pkill` or `kill -9` unless SIGTERM fails, as it may leave zombie processes or corrupt state.

### Prevention
- **Stall watchdog:** Use the plugin's streaming dispatch helper for long generations. Be precise about what it does: it **flags** a stall after a configurable window with no new data (default 30s) and keeps printing liveness ticks during a long prefill. It does **not** abort the request for you — the decision to kill and relaunch stays yours.
- **Avoid concurrent heavy loads:** Do not dispatch multiple large prompts to a single-slot server simultaneously.

