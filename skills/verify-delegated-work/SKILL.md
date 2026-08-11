---
name: verify-delegated-work
description: 'Use AFTER a delegate (local model, cloud subagent, or external tool) returns output that modifies state, generates code, or asserts facts. Triggered by the need to validate correctness before trusting the result. Do NOT use for planning, briefing, or runtime checks. Covers ground-truth comparison, mutation testing of generated tests, and the retry ceiling.'
---

# verify-delegated-work — trust nothing, verify everything

A smaller model or automated agent’s default failure mode is **plausible-but-wrong**. It will return a clean diff, a passing test suite, or a confident summary that is subtly incorrect. Verification is not optional; it is the cost of offloading.

## Capture ground truth BEFORE delegating
You cannot verify what you do not know. Before dispatching work that touches files or asserts facts, capture the baseline:
- **File state:** `git diff` for tracked files, otherwise a content hash — use `shasum -a 256`, which is
  present on both macOS and Linux (`md5sum` is GNU coreutils and is missing from most macOS installs).
- **Fact state:** The actual list of files, the current value of a variable, or the output of a diagnostic command.
- **Test state:** The current pass/fail status of the test suite.

Store this baseline in a temporary variable or file. When the delegate returns, compare its output against this baseline, not against your memory of it.

## Judge by observable outcome change
Do not accept "it replied" or "no error" as success. Verify by **observable change**:
- **Code/Files:** Does the diff match the intent? Does the file exist where promised?
- **Tests:** Did the test suite pass *after* the change? If the delegate wrote new tests, **mutation-test them**: break the code intentionally and ensure the new tests fail. If they don’t, the tests are useless.
- **Facts/Summaries:** Does the summary match the ground truth captured in step 1? Spot-check specific claims against the source.

## The retry ceiling (stop looping)
Verification is cheap, but infinite loops are not. If a delegate fails verification:
1. **Correct the briefing** (was the instruction ambiguous? Was the context missing?) and re-dispatch.
2. **Count failures.** After **N failed verifications** (default N=3), **stop looping**.
3. **Fallback:** Either do the work directly on the cloud model (if quality-critical) or park the item with a clear reason ("failed verification 3x, parked for manual review").

Do not keep retrying the same delegate with the same briefing. The compute is free, but your time is not.

## Universal application
This skill applies to **any** handoff: local models, cloud subagents, or external scripts. The principle is identical: capture truth, delegate, compare, and enforce a ceiling.

