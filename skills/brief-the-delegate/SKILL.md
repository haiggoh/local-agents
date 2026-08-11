---
name: brief-the-delegate
description: 'Use WHEN writing the instruction/prompt for a stateless dispatch. Triggered by the need to disambiguate task boundaries, ordering, or output format. Do NOT use for verifying output, guarding runtime, or composing payloads.'
---

# brief-the-delegate — spell out every ambiguity

A stateless dispatch inherits no context. If you do not specify it, the delegate will guess — and guess wrong.

## Disambiguate the task
1. **Ordering:** Specify if order matters (e.g., "process files in alphabetical order").
2. **Boundaries:** Define what is in scope and what is out.
3. **Locale/Format:** Specify date formats, number formats, or language.
4. **First-vs-last-write-wins:** If multiple sources conflict, specify which takes precedence.

## Use placeholders for bulk content
If the delegate needs to generate large amounts of text (e.g., boilerplate, lists):
1. **Use `{{FILLER}}`:** Ask the delegate to output a marker instead of the full content. The marker is a
   convention, not something the model knows — **define it explicitly in the prompt** ("emit the literal token
   `{{FILLER}}` where the body would go"), or it will either ignore it or write the bulk anyway.
2. **Fill later:** Replace the markers with actual content in a subsequent step.

## Name assertions that must be ground-truthed
1. **Identify risky claims:** Mark any assertion that requires verification (e.g., "this file exists", "this function is called").
2. **Require evidence:** Ask the delegate to provide the source or proof for these claims.

## Example
```json
{
  "messages": [
    {
      "role": "user",
      "content": "Extract all function names from the file. Output as a JSON array. If a function is defined in multiple files, use the definition in the file with the most recent modification date. Mark any function that calls 'exit()' with a 'critical' flag."
    }
  ]
}
```

## Fold in standing rules (if available)
If a standing-rules index for delegated work exists (e.g., from a separate plugin), fold the relevant lines into the prompt. This skill does not maintain the index; it only uses it.