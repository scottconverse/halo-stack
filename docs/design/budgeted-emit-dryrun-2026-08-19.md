# Budgeted-emit pipeline — first dry-run record (2026-08-19)

Task brief: generate `halo-notify.mjs` (a 4-export Windows notification /
retry / JSONL utility, ~400 lines) entirely through the pipeline, local brain
only, against the freshly adopted 131,072-token window.

## Verdict on the machinery: PASSED

Across six invocations (four were deliberate stop-fix-resume cycles on
orchestration bugs, below): **19 chunk emissions, 19 truncation/syntax gates,
5 plans, 4 clean-room reviews, 5 integrations — zero agent failures, zero
missing evidence, zero stalls.** Every stop was a bounded, explicit park with
a decision record, never a silent hang. The wall never appeared: no emission
was ever requested beyond measured room, and the sentinel gate never fired on
a real truncation (chunks sized at 2-6K simply do not hit a 12K cap).

`workflow.py --report`:

| node | backend | attempts | ok | failed |
|---|---|---|---|---|
| emit_chunk | openai-compat (local brain) | 19 | 19 | 0 |
| emit_check | code | 19 | 19 | 0 |
| plan_chunks | openai-compat | 5 | 5 | 0 |
| review | openai-compat | 4 | 4 | 0 |
| route_next / verdict_route | code | 23 | routing-by-design | — |

## The reviewer earned its place

The clean-room local reviewer (fresh stateless call, zero generation history)
caught, across cycles: a clobbered artifact (orchestration bug it had no way
to know about — it just read what it was given and called it garbage); a
semantic contract violation (`JsonlLogger.log` stamping over an existing `ts`
field while its own JSDoc promised not to); dead broken WinRT code; a
PowerShell brace-escaping syntax error; and an API-availability concern.
Each finding fed a repair replan. Findings shrank every cycle. This is the
cost-direction rule vindicated: the local model reviews local work, $0.

## Orchestration lessons (all fixed in this change)

1. **Payload contract:** the driver writes a node's stdout over the traversed
   edge's payload file. Any step on an edge naming a JSON payload must print
   exactly that JSON; human-readable status goes in the evidence file. Missed
   this on plan_check, emit_check, review_gate, and integrate; each bit once.
2. **Attempt semantics:** every fail-edge re-entry counts against the target's
   ceiling — and routers route iteration through fail edges. Ceilings on
   loop-hub nodes (emit_chunk 30, plan_chunks 6, review 8) bound cycles, not
   genuine retries; genuine per-failure retry stays bounded at
   refresh_context (3); the run-level agent_calls budget (24) is the global
   stop.
3. **Evidence + stateless agents don't mix:** an agent node's payload file is
   written on edge traversal, after the evidence check — a stateless agent
   can never satisfy `evidence`. Validate agent output in the next code node
   instead (review_gate).
4. **Rework is a replan:** review findings route to the planner, which emits a
   repair plan recreating affected files — never back into a spent chunk
   list.

## Honest remainder

The artifact itself was not accepted within this run's budget: the reviewer
kept finding real-but-shrinking defects in the hardest requirement (a blind
WinRT toast one-liner without BurntToast — a genuinely finicky corner of
Windows). That is produce/check convergence economics, not a machinery
failure; the run parked exactly as designed. Options for the next run: soften
that one requirement, allow the reviewer a severity threshold, or spend a
bigger budget.
