#!/usr/bin/env python3
"""tests/test_model_manifest_fixtures.py — contract tests for portable manifest v1 fixtures.

Standard library ONLY, deliberately: docs/model-manifest-v1.md requires runtime manifest handling to
stay stdlib-only, and `jsonschema` is not installed here. The JSON Schema in docs/schema/ exists for
INTEROPERABILITY (other consumers, editors, CI elsewhere); this file encodes the same rules in the
one language every consumer of this repo already has.

WHY the rules are duplicated here rather than imported: the writer/validator tool is a LATER step
(plan Commit 2). Until it exists, the fixtures would be inert data with nothing asserting they mean
what the spec says. Each invalid fixture must fail for its OWN stated reason — a fixture that fails
for the wrong reason is not evidence, so the expected reason is asserted too. When the real validator
lands, it should be pointed at these same fixtures and this file's rule table retired.

Run: python3 tests/test_model_manifest_fixtures.py
"""
import json
import pathlib
import sys

FIXTURES = pathlib.Path(__file__).parent / "fixtures" / "model-manifests"
SCHEMA = pathlib.Path(__file__).parent.parent / "docs" / "schema" / "local-model-manifest-v1.schema.json"

MIN_CONTEXT = 1024
MAX_CONTEXT = 10_485_760
NON_SESSION_KINDS = {"draft_model", "tts_model", "depth_estimation_model", "adapter", "processor"}


def effective_context(caps):
    """Minimum of the limits that are actually present. None when nothing is declared."""
    limits = [
        caps.get("configured_context_tokens"),
        caps.get("native_context_tokens"),
    ]
    rq_server = caps.get("_server_context_tokens")
    if rq_server is not None:
        limits.append(rq_server)
    present = [v for v in limits if isinstance(v, int)]
    return min(present) if present else None


def validate(doc):
    """Return a list of rule violations. Empty list == valid."""
    errors = []

    if doc.get("schema_version") != 1:
        errors.append("schema_version")
        return errors  # shape past this point is not ours to interpret

    art = doc.get("artifact") or {}
    caps = dict(doc.get("capabilities") or {})
    rq = doc.get("runtime_qualification") or {}
    acq = doc.get("acquisition") or {}
    if rq.get("server_context_tokens") is not None:
        caps["_server_context_tokens"] = rq["server_context_tokens"]

    name = art.get("directory_name", "")
    if not name or "/" in name or "\\" in name:
        errors.append("directory_name")

    kind = art.get("kind")
    if kind == "draft_model":
        if art.get("launchable") is not False:
            errors.append("drafter_launchable")
        if not art.get("target_directory_name"):
            errors.append("drafter_target")
    if kind in NON_SESSION_KINDS and art.get("session_eligible") is not False:
        errors.append("session_eligible")

    for key in ("native_context_tokens", "configured_context_tokens", "extended_context_tokens"):
        val = caps.get(key)
        if isinstance(val, int) and not (MIN_CONTEXT <= val <= MAX_CONTEXT):
            errors.append("context_range")
            break

    candidates = caps.get("context_candidates") or []
    distinct = {c.get("value") for c in candidates if isinstance(c.get("value"), int)}
    if len(distinct) > 1 and not caps.get("context_conflict_resolution"):
        errors.append("unresolved_conflict")

    eff = effective_context(caps)
    if eff is not None:
        expected_floor = (eff // 100_000) * 100_000
        expected_ac = None if expected_floor < 100_000 else min(1_000_000, expected_floor)

        if "context_floor_100k_tokens" in caps and caps["context_floor_100k_tokens"] != expected_floor:
            errors.append("derived_floor")
        if "claude_autocompact_tokens" in caps and caps["claude_autocompact_tokens"] != expected_ac:
            errors.append("derived_autocompact")

        ac = caps.get("claude_autocompact_tokens")
        if isinstance(ac, int):
            if ac % 100_000 or not (100_000 <= ac <= 1_000_000):
                errors.append("autocompact_increment")
            if ac > eff:
                errors.append("autocompact_exceeds_context")

    if acq.get("status") == "complete" and art.get("payload_bytes") == 0:
        errors.append("complete_without_payload")

    return errors


# fixture stem -> the violation it exists to demonstrate
EXPECTED = {
    "invalid-absolute-path": "directory_name",
    "invalid-autocompact-increment": "autocompact_increment",
    "invalid-autocompact-exceeds-context": "autocompact_exceeds_context",
    "invalid-drafter-launchable": "drafter_launchable",
    "invalid-drafter-missing-target": "drafter_target",
    "invalid-tts-session-eligible": "session_eligible",
    "invalid-conflict-without-resolution": "unresolved_conflict",
    "invalid-derived-floor-mismatch": "derived_floor",
    "invalid-unknown-schema-version": "schema_version",
    "invalid-metadata-only-claims-complete": "complete_without_payload",
    "invalid-tokenizer-sentinel-context": "context_range",
}

# The published arithmetic table in docs/model-manifest-v1.md §4.3, asserted directly.
AUTOCOMPACT_TABLE = [
    (99_999, None),
    (100_000, 100_000),
    (131_072, 100_000),
    (199_999, 100_000),
    (200_000, 200_000),
    (262_144, 200_000),
    (393_216, 300_000),
    (999_999, 900_000),
    (1_000_000, 1_000_000),
    (1_048_576, 1_000_000),
    (10_485_760, 1_000_000),
]


def main():
    passed = failed = 0

    def check(ok, label):
        nonlocal passed, failed
        if ok:
            passed += 1
            print(f"  PASS: {label}")
        else:
            failed += 1
            print(f"  FAIL: {label}")

    print("== the schema ships and is parseable JSON ==")
    try:
        schema = json.loads(SCHEMA.read_text())
        check(schema.get("$schema", "").startswith("https://json-schema.org/"), "schema declares its dialect")
        check(schema.get("properties", {}).get("schema_version", {}).get("const") == 1, "schema pins schema_version to 1")
    except Exception as exc:  # noqa: BLE001
        check(False, f"schema loads ({exc})")

    print("== the published autocompaction table is what the rule computes ==")
    for eff, want in AUTOCOMPACT_TABLE:
        floor = (eff // 100_000) * 100_000
        got = None if floor < 100_000 else min(1_000_000, floor)
        check(got == want, f"{eff:,} -> {want!r}")

    print("== valid fixtures pass ==")
    valid = sorted(FIXTURES.glob("valid-*.json"))
    check(len(valid) >= 6, f"found {len(valid)} valid fixtures")
    for path in valid:
        errs = validate(json.loads(path.read_text()))
        check(not errs, f"{path.name} valid (got {errs})")

    print("== invalid fixtures fail, each for its OWN reason ==")
    invalid = sorted(FIXTURES.glob("invalid-*.json"))
    check(len(invalid) >= 11, f"found {len(invalid)} invalid fixtures")
    for path in invalid:
        stem = path.stem
        errs = validate(json.loads(path.read_text()))
        want = EXPECTED.get(stem)
        check(want is not None, f"{stem} has a declared expected reason")
        if want:
            check(want in errs, f"{stem} fails on {want} (got {errs})")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
