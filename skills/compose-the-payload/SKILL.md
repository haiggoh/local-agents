---
name: compose-the-payload
description: 'Use WHEN assembling the MATERIAL for a stateless dispatch — file contents, large corpora, or structured data — so the source never enters the orchestrator context. Do NOT use for writing the instructions about that material, verifying output, guarding runtime, or isolating work.'
---

# compose-the-payload — build self-contained dispatch inputs

A stateless dispatch inherits nothing. The payload must contain all necessary context, sourced from disk, not from the orchestrator’s memory.

## Build from files on disk — and never read them yourself
The point is not merely that the payload comes from disk. It is that **you never load the source into your own
context**: a script reads the files, serializes them, and hands them to the delegate. Reading a 60 KB corpus to
"prepare" it spends exactly what offloading was supposed to save.

1. **Concatenate on disk:** assemble the corpus with shell redirection, not by reading files into your context.
2. **Serialize with a JSON-aware tool.** Never build JSON by interpolating file contents into `echo` — any
   quote, backslash, newline, tab, or control character in the source produces invalid JSON, so the failure is
   silent and total on almost any real file.

   ```bash
   # assemble the corpus without ever reading it
   { cat header.md; cat body/*.md; } > /tmp/corpus.txt

   # serialize it safely — python does the escaping
   python3 - <<'PY'
   import json
   corpus = open('/tmp/corpus.txt', errors='ignore').read()
   body = {"messages": [{"role": "user", "content": "INSTRUCTIONS HERE\n\n" + corpus}],
           "max_tokens": 2000, "temperature": 0}
   json.dump(body, open('/tmp/body.json', 'w'))
   PY
   ```

## Size the corpus
1. **Trim irrelevant content:** Remove headers, footers, or unrelated sections — on disk, with a filter.
2. **Measure before dispatching:** check the byte count so you know whether it fits the context window.
3. **Chunk if necessary:** If the content exceeds the model’s context window, split it into logical chunks and dispatch separately.

## Keep the answer small
The corpus can be large; the answer must not be, because **the answer is what you pay for**.
1. **Specify output format:** Use JSON, YAML, or a strict template.
2. **Limit tokens:** Set `max_tokens` deliberately, and be aware that hitting the cap truncates mid-structure.
3. **Avoid bulk generation:** If the delegate needs to emit large amounts of boilerplate, have it emit
   placeholders (`{{FILLER}}`) and expand them in code afterwards.

## Never hardcode a model name
Resolve the model from its **role** using the plugin's role-resolution helper, and take the port from whatever
the warm-up step printed. A literal model alias in a skill is someone else's machine config: rosters change,
aliases differ per install, and the wrong alias fails in a way that looks like a model problem.

```bash
# WRONG — a machine-specific alias and an assumed port
"model": "some-local-alias-27b" ... --port 8000

# RIGHT — role-resolved model, port captured from warm-up
MODEL="$(la-roles.sh operator | head -1)"   # role -> an on-disk alias, via the plugin's resolver
PORT="$SUCCESS_PORT"                        # from the warm-up script's SUCCESS_PORT= line; never assumed
```

