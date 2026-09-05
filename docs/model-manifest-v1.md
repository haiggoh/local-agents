# Portable local-model manifest, version 1

**Status:** specification. The schema and fixtures in this commit are the contract; the tooling that
writes and validates manifests, the downloader integration, and the roster backfill are separate,
later steps. Nothing in this commit reads or writes anything under `~/.models`.

Schema: [`docs/schema/local-model-manifest-v1.schema.json`](schema/local-model-manifest-v1.schema.json)
Fixtures: [`tests/fixtures/model-manifests/`](../tests/fixtures/model-manifests/)

---

## 1. What this is for

`~/.models` is a **shared dependency**, not the property of any one repository. `local-agents` uses
it, a future AGY consumer will use it, and other tools may. Today, everything a consumer knows about
an installed artifact lives in this repo's `config.local.sh` and `model-catalog.psv` — so a second
consumer either duplicates that knowledge or does without it.

The fix is to make the model store **self-describing**: each completed artifact carries its own
metadata, beside its weights, as data.

```text
~/.models/KAT-Coder-V2.5-Dev-OptiQ-4bit/.local-model-manifest.json
```

The filename is fixed. A consumer scanning `~/.models` can then list what is installed, what may be
launched, what may drive a Claude Code session, and what context each artifact actually supports —
with no checkout of this repository.

## 2. Three rules that are not negotiable

**A manifest is untrusted data.** Parse it as strict JSON. Never `source`, import, evaluate or
execute a manifest, and never execute anything else found in a model directory. A model directory is
third-party content that arrived over the network.

**Never store an absolute path.** Store `directory_name` only. The consumer knows which directory it
is scanning and derives the path from that. A manifest containing `/Users/<someone>/.models/...` is
broken the moment it is read on another machine, by another user, or from a different mount.

**Declaration is not qualification.** An architectural maximum is not a tested safe limit, and a
tested safe limit is not what the live server was actually given. These are separate fields on
purpose; see §4.

## 3. Artifact kind vs. launchability vs. session eligibility

Three different questions, deliberately three fields:

| Field | Question |
|---|---|
| `kind` | What IS it? |
| `launchable` | May it be served as an endpoint at all? |
| `session_eligible` | May it be offered as a Claude Code *session* model? |

They genuinely differ:

- A normal MLX text model: `kind: model`, launchable, session-eligible.
- A speculative MTP drafter: `kind: draft_model`, **not** launchable, not session-eligible. It is a
  real artifact that exists only to accelerate a named target, and it must never appear in a picker.
  Its manifest names that target via `target_directory_name`.
- A TTS asset: launchable by its own tooling, **never** session-eligible. Its token limits describe
  speech input, not conversational context, and must not be read as a context window.
- A depth-estimation asset: not an LLM at all.
- An `mlx_lm`-served text model: launchable for *dispatch*, but **not** session-eligible — it serves
  OpenAI-style routes under a path-shaped id and has no `/v1/messages` surface.
- `.DS_Store`: not an artifact. It is ignored, not manifested.

## 4. Context: six states, one of them derived

Collapsing these into a single `context_length` is the specific mistake this schema exists to
prevent, because every one of them is the *right* answer to a different question.

```text
native_context_tokens        what the architecture declares
configured_context_tokens    what THIS artifact's config.json says
extended_context_tokens      what an explicit RoPE/YaRN setup could reach
tested_safe_context_tokens   what has actually been measured here, with evidence
server_context_tokens        what the LIVE server was allocated
effective_context_tokens     the MINIMUM of whichever limits are active
```

`effective_context_tokens` is what a session may actually use. It is the minimum of the applicable
hard limits, so:

- a 262,144 model served at 131,072 is effectively 131,072;
- a 1M-capable model served at 262,144 is effectively 262,144 — **not** 1M;
- a 10M model served at 1M is effectively 1M.

A theoretical extended context never overrides a smaller live server allocation.

### 4.1 Extraction order

Read the first plausible integer, in this order:

1. `config.json` → `/text_config/max_position_embeddings`
2. `config.json` → `/max_position_embeddings`
3. `config.json` → `/text_config/model_max_length`
4. `config.json` → `/model_max_length`
5. `config.json` → `/max_sequence_length`
6. `tokenizer_config.json` → `/model_max_length` — **fallback only**

Plausibility window: **1,024 to 10,485,760**. The upper bound is set by the largest audited artifact
(Llama 4 Scout) and must not be tightened below it. Tokenizer sentinel values are rejected even when
numerically inside the window — a tokenizer that claims a billion tokens is declaring "no limit
here", not a context length.

### 4.2 Conflicts fail closed

Real artifacts in this store disagree with themselves: a language-model context differs from a
tokenizer's, and a multimodal processor's image limit differs from the text limit. So:

- keep **every** candidate in `context_candidates`;
- never silently take the largest;
- record an explicit `context_conflict_resolution` with a reason;
- a validator that finds disagreement with no recorded resolution **fails**.

### 4.3 The two derived values

Claude Code accepts an explicit autocompaction threshold only in 100,000-token increments, minimum
100,000, maximum 1,000,000.

```python
context_floor_100k_tokens = (effective_context_tokens // 100_000) * 100_000

if context_floor_100k_tokens < 100_000:
    claude_autocompact_tokens = None          # below the minimum; set nothing
else:
    claude_autocompact_tokens = min(1_000_000, context_floor_100k_tokens)
```

| Effective context | `claude_autocompact_tokens` |
|---:|---:|
| 99,999 | none — unsupported |
| 100,000 | 100,000 |
| 131,072 | 100,000 |
| 199,999 | 100,000 |
| 200,000 | 200,000 |
| 262,144 | 200,000 |
| 393,216 | 300,000 |
| 999,999 | 900,000 |
| 1,000,000 | 1,000,000 |
| 1,048,576 | 1,000,000 |
| 10,485,760 | 1,000,000 |

Both are **derived**. The exact context is the authoritative fact; these are conveniences. They may
be persisted so a consumer need not reimplement the arithmetic, but a validator MUST recompute and
compare, and a mismatch is an error. They must never become independently editable facts — 50,000,
150,000 and 250,000 are all invalid, and a value exceeding the effective context is invalid.

## 5. One artifact, several aliases

Aliases that share one physical directory belong in **one** manifest, as multiple `profiles` entries.
Duplicating the artifact facts once per alias creates exactly the drift this design removes: a
thinking and a non-thinking alias are the same weights with different serve flags, and their context
is a property of the weights.

An override/alias entry that resolves to a *different* installed artifact uses
`alias_of_directory_name` and inherits context from its target unless explicitly restated.

## 6. Completion is a transaction

`acquisition.status` is `complete` only after the payload has been verified. Specifically, a writer
must: finish the download, verify the payload files, verify no partial files remain, resolve the
repository and revision, extract context candidates, build and validate a **temporary** manifest,
write the completion marker atomically, then atomically rename the manifest into place.

Two consequences: a metadata-only shell must never claim `complete`, and an interruption between the
completion marker and the manifest rename must be repairable by re-running the writer **without
re-downloading**.

## 7. The researched YAML's role

`config/model-catalogue-context-list.yaml` is a reviewed, hand-audited catalogue of the 44 entries
currently in this store. Its role is **input and provenance**, not truth:

- it seeds and cross-checks manifests during backfill;
- where it supplied a value, the manifest records that via `acquisition.catalogue_provenance`, so a
  reviewed value is never mistaken for direct artifact evidence;
- where it disagrees with the artifact, validation **fails closed** and asks for an explicit,
  recorded resolution.

Once an artifact has a manifest, the manifest is the truth for that artifact. The YAML is not a
second editable source, and `model-catalog.psv` remains what it already is — acquisition and
launcher configuration.

## 8. What a consumer should do

1. Scan the model directory for `*/.local-model-manifest.json`.
2. Refuse any `schema_version` it does not recognise, rather than guessing.
3. List only `launchable` artifacts; offer only `session_eligible` ones as session models.
4. Exclude drafters, TTS, depth and filesystem metadata from session pickers.
5. Show the **exact** context, and derive any autocompaction value rather than trusting a stored one.
6. Treat a missing manifest as a legacy artifact and fall back to conservative existing behaviour —
   never as a reason to refuse a model that works today.
