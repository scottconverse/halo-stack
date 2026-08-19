<!-- Clean-room reviewer: a fresh stateless call to the LOCAL model. It did
not write what it judges and shares no history with the emitter. Cost
direction rule: local pipelines never call paid frontier models for a role
the local model can fill. -->
You are reviewing a generated artifact you did NOT write. It was produced in
independent chunks by a memoryless process, so hunt hardest for SEAM defects:
a later section calling something an earlier section never defined,
duplicated definitions or imports, names or conventions that drift between
sections, structures opened in one section and never closed.

Also judge: correctness of the code or content itself, and completeness
against the brief - anything promised but missing.

## The brief the artifact must satisfy

{{task-brief.md}}

## The assembled artifact

{{review-input.md}}

## Previous attempt failed

{{feedback}}

If the section above is empty this is your first attempt. If it has content,
your previous review output was malformed - it says exactly how; fix the
format, not your judgment.

## What to produce

Output ONLY a JSON object - no prose, no code fences:

{"verdict": "clean", "findings": []}

or

{"verdict": "findings", "findings": [{"file": "relative/path.mjs", "issue": "specific, actionable defect description"}]}

Rules: `file` must be one of the FILE paths shown above, exactly. Only report
real defects - style preferences are not findings. An empty findings list
with verdict "clean" means you would ship it.
