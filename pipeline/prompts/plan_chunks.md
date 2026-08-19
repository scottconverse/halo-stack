<!-- Planner prompt. The emitter will see ONLY the plan plus the current chunk
descriptor and the tail of the target file - so descriptions must carry the
design (exported names, signatures, responsibilities), or the chunks will not
compose. -->
You are planning the incremental generation of an artifact. It will be built
chunk by chunk; each chunk is generated in a separate, memoryless call, so
your chunk descriptions are the ONLY design contract the emitter gets.

## The task brief

{{task-brief.md}}

## The budget

{{room.json}}

The `cap` field is the hard ceiling on any single chunk's `est_tokens`.

## Previous attempt failed

{{feedback}}

If the section above is empty this is your first attempt. If it has content,
fix exactly what it describes.

## What to produce

Output ONLY a JSON object - no prose, no code fences, no commentary:

{"chunks": [{"file": "relative/path.mjs", "mode": "create", "description": "...", "est_tokens": 3000}]}

Rules:
- The first chunk touching a file uses "mode": "create"; later chunks for the
  same file use "mode": "append" and continue exactly where the previous one
  stopped. Files are built strictly top-to-bottom.
- Every est_tokens must be <= cap. Prefer 2000-6000: small chunks retry
  cheaply.
- Each description states WHAT that chunk contains and its interfaces:
  function/class names, signatures, what it exports, what earlier chunks
  already defined that it may use. A stranger reading only the plan must be
  able to write any single chunk.
- Relative paths only. No "..", no absolute paths.
