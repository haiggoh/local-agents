# Opt-in integration diagnostics

These diagnostics exercise installed client or backend behavior and are not
part of the normal fast unit suite.

## Claude Code Auto Mode Stage-2 parser probe

`claude_auto_mode_stage2_parser_probe.py` is a backend-free black-box
integration diagnostic for the installed Claude Code binary. It runs two
isolated cases through a loopback Anthropic-compatible proxy:

1. a clean Stage-2 severity verdict control;
2. the same verdict preceded by one complete thinking section.

Each case must complete the full sequence: main-model Bash proposal, Auto Mode
Stage 1, Auto Mode Stage 2, private marker execution, tool-result delivery, and
final main-model response. The experiment is interpreted only if the clean
control passes.

The artifact preserved here is byte-identical to the probe that produced:

- `CONTROL_PASS=1`
- `EXPERIMENT_EXECUTES=1`
- `PARSER_CONCLUSION=CLAUDE_ACCEPTS_REASONING_PREFIX`

The built-in protocol test starts no Claude Code process:

    python3 tests/integration/claude_auto_mode_stage2_parser_probe.py --self-test

A live opt-in run requires a fresh path that does not already exist:

    parent="$(mktemp -d "${TMPDIR:-/tmp}/claude-parser-probe.XXXXXX")"
    python3 tests/integration/claude_auto_mode_stage2_parser_probe.py \
        --run-root "$parent/run"

The live diagnostic writes only below its private run root. It starts no model
server and does not access or mutate the repository.
