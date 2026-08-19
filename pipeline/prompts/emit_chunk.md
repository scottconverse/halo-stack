<!-- Emitter prompt. Stateless call: everything it needs is inlined here.
The sentinel line is the truncation detector - a cut-off reply cannot end
with it. Deterministic code applies the content to the file; the model never
touches the filesystem. -->
You are generating ONE chunk of a larger artifact. The full plan is below for
context; generate ONLY the current chunk.

## The full plan

{{emit-plan.json}}

## Current chunk and file state

{{emit-state.json}}

The `current` object is your assignment. If `file_tail` is non-empty, it is
the last lines already written to your target file - your output must
continue seamlessly from it (do not repeat it, do not re-open structures it
already opened).

## Feedback channel

{{feedback}}

If the section above is empty, this is your first attempt. If it starts with
"NOT A FAILURE - routing", it is only your assignment pointer - proceed
normally. Anything else describes exactly what was wrong with a previous
attempt - fix that; do not redesign the chunk.

## What to produce

The raw content of the current chunk and nothing else:
- No code fences, no prose before or after, no explanations.
- Implement exactly what `current.description` specifies - respect the names
  and signatures the plan promises to other chunks.
- Stay within `current.est_tokens` worth of output.
- End your output with this exact line, alone on its own line:

<<CHUNK-COMPLETE>>
