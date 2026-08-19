# budgeted-emit-pipeline

Produce arbitrarily large generated artifacts (plugins, modules, documents) on the HALO stack without ever hitting the output-token wall: every emit is sized to measured context room before it is requested, retries always land in fresh context, and the run never stalls waiting for a human 'continue'

- **Trigger:** A generative task brief (task-brief.md) lands in the run directory
- **Isolation:** `worktree (declared in the spec; this package does not create it)`

Generated from `spec.json`. The diagram and design doc come from the same file, so
edit the spec and regenerate rather than editing outputs by hand.

## Layout

| Path | Regenerated? | What it is |
|---|---|---|
| `workflow.py` | yes, overwritten | Orchestration: the node table, the driver, retry bounds |
| `runner.py` | yes, overwritten | The only place the workflow leaves the Python process |
| `prompts/*.md` | no, yours | One prompt per agent node |
| `steps/*.sh` | no, yours | One script per code node |
| `spec.json` | source | Edit this, then regenerate |
| `runs/` | — | Payloads from each run |

## Before it will run

- [ ] `steps/measure_room.sh` — GET the dsh apiproxy sessions tail for the target session; read projections.contextPressure {contextWindow, projectedTokens}; room = contextWindow - projectedTokens; write room.json. This projection exists today (dsh-token-meter -> dsh-host-apiproxy sessions endpoint) - Mission Control already speaks this API.
- [ ] `steps/fresh_session_start.sh` — Start a new dsh --profile headless session (cold context = maximum room: ~55K usable of the 65,536 window after the ~10K boot prefix); write room.json from its measured pressure.
- [ ] `prompts/plan_chunks.md` — Read task-brief.md and room.json. Produce emit-plan.json: an ordered list of chunks, each targeting one file region, with est_tokens <= cap where cap = min(0.5 * room, 12000). The 0.5 factor reserves output budget for thinking tokens, which spend from the same per-reply budget (measured on this stack). Chunks are written with the harness's incremental file tools (create / insert / str_replace), never as one giant tool-call argument.
- [ ] `steps/plan_check.sh` — Schema-check emit-plan.json; assert every chunk est_tokens <= cap, file regions disjoint, order dependency-safe. Exit non-zero with reasons in plan-check.txt.
- [ ] `prompts/emit_chunk.md` — Generate the current chunk only, writing with create/insert/str_replace so no single tool-call argument exceeds the chunk cap. On rework, the incoming report says exactly what failed - fix that, do not regenerate the artifact. max_attempts is high ON PURPOSE: the driver counts every fail-edge re-entry, and route_next's next-chunk routing arrives on a fail edge, so this ceiling bounds chunks+rework, not genuine retries - those are bounded by refresh_context (3), and the run-level agent_calls budget is the global stop.
- [ ] `steps/emit_check.sh` — Two checks, both deterministic: (1) read the session's last turn/end reason from the apiproxy event tail - reason kind 'max-tokens' is a HARD FAIL even if the file looks plausible, because the harness silently DROPS truncated tool-call blocks (dsh-llm BlockAssembler: max-token truncation discards tool calls); (2) node --check / linter on touched files. Write emit-check.txt.
- [ ] `steps/refresh_context.sh` — Park the current session, start a fresh headless session, re-measure room, shrink remaining chunk caps if room changed. Encodes the traced harness behavior: 'continue' after truncation is a brand-new generation against a fuller window, and a truncated tool call is unrecoverable - so never retry a failed emit in the same session.
- [ ] `steps/route_next.sh` — Router: exit 0 (pass) when emit-state.json shows every chunk emitted and checked; exit 1 (fail) with next-chunk.json otherwise. A code decision - no model call to decide what a file already says.
- [ ] `steps/integrate.sh` — Run the project's full check suite over the assembled artifact (syntax, tests, compose-validation where config is involved); git commit on the run branch. Write integrate-report.txt and review-input.md (the assembled artifact/diff inlined for the stateless reviewer).
- [ ] `prompts/review.md` — Adversarial review by the LOCAL brain in a fresh clean-room call: the reviewer receives ONLY task-brief.md plus review-input.md (the assembled artifact) - zero generation history, so it did not write what it judges. Targets: correctness, completeness vs the brief, and seams between chunks (the failure mode chunked generation adds). Findings to review.json; empty findings = clean. Cost-direction rule: an autonomous local pipeline never calls a paid frontier model for a role the local model can fill.
- [ ] `steps/review_gate.sh` — Schema-check review.json: verdict field present, every finding references a real file/line in the worktree. Deterministic guard against malformed reviewer output.
- [ ] `steps/verdict_route.sh` — Router: exit 0 (pass) when review.json has zero findings; exit 1 (fail) otherwise, forwarding the findings to the PLANNER - rework is a replan (a fresh repair plan whose chunks recreate the affected files with fixes), never a blind re-emit against a spent chunk list.
- [ ] `steps/open_pr.sh` — git push, gh pr create with emit-plan.json + review.json summarized in the body. Repo doctrine: branch + PR into master, never direct.
- [ ] Open question: Chunk cap constants (0.5 * room, 12K ceiling) are engineering estimates from measured thinking-token overhead - the first two real runs should record actual per-chunk output spend and tune them.
- [ ] Open question: The truncation detector reads turn/end reasons from the apiproxy sessions event tail; confirmed present in the API surface, but the exact tail-pagination call needs one probe against a live headless session before the check is coded.
- [ ] Open question: Window expansion (Phase 1 of the fix plan) raises room from ~55K to ~120K usable and roughly doubles the chunk cap; the pipeline needs no structural change when that lands - only room.json values move.
- [ ] Open question: budget.agent_calls=24 assumes artifacts up to ~15 chunks with modest rework; raise it for book-sized artifacts or the run will hand off mid-work by design.

## Running it

```bash
python3 workflow.py                  # full run
python3 workflow.py --delegate       # park at each agent node instead of spawning a CLI
python3 workflow.py --only plan_chunks   # one node against the last run's payloads
python3 workflow.py --from plan_chunks   # resume partway through
python3 workflow.py --report         # summarise past runs; reads only, runs nothing
python3 workflow.py --run-dir ./run  # where payloads and the event log live
python3 workflow.py --workdir ..     # where steps and agents actually execute
python3 workflow.py --report --runs ./runs   # report against a different run root
```

`--only` is the reason payloads are files rather than variables: you can rerun one
node against a fixed input instead of replaying the whole workflow to reach it.

**`--delegate` is the mode to use if you are reading this from inside an assistant
rather than a terminal.** Instead of spawning an agent CLI, the run stops at each agent
node, writes the fully composed prompt to `<run-dir>/<node>.prompt.md`, and exits 76.
You do that work, save the answer to `<node>.result.md` beside it, and run the same
command again with the same `--run-dir` to continue. Human gates work the same way
through `<node>.decision.md` and `<node>.answer.md`, exiting 75. Attempt counts, the
retry ceiling and the budget all persist across the pause, so parking costs nothing and
neither mode can quietly get more retries than the spec allows. `WORKFLOW_DELEGATE=1` is
the same switch from the environment.

**`--run-dir` is the flag those park messages mean when they say "the same
`--run-dir`".** It defaults to `runs/latest`. Every payload, prompt, decision, output
and the append-only `run.jsonl` land there, so pointing a run at a fresh directory keeps
its record separate, and pointing a resumed run at the previous one is what lets it pick
up where it stopped. `--workdir` is different and independent: it is where step scripts
and agents actually execute, defaulting to the current directory.

`--report` reads every `run.jsonl` under `runs/` and counts runs, attempts, successes,
failures and missing evidence per node, grouped by the backend each node ran on. One
run cannot tell you a node is unreliable; twenty can -- and runs sit beside attempts
because eight failures inside one run is a node that looped, while eight across eight
runs is a node that does not work. It reports rather than routes --
the same numbers would drive an automatic model choice and deliberately do not, since
a run that silently re-routes itself is a different kind of program. What to do about
a node that keeps failing stays your call, and belongs in `spec.json` where the next
reader can see it.

## Knobs

Environment variables, all optional:

- `WORKFLOW_AGENT_TIMEOUT` (default 1800s)
- `WORKFLOW_STEP_TIMEOUT` (default 3600s)
- `WORKFLOW_PERMISSION_MODE` (default `acceptEdits`)
- `WORKFLOW_AGENT_CLI` (default `claude`; may carry arguments, e.g. a stub for tests)
- `WORKFLOW_CODEX_CLI` (default `codex`) and `WORKFLOW_AGY_CLI` (default `agy`) --
  the binaries for nodes with those backends. Antigravity is usually not on PATH; on
  Windows it installs to `%LOCALAPPDATA%\agy\bin\agy.exe`.
- `WORKFLOW_CODEX_SANDBOX` (default `read-only`). Codex's own default is
  workspace-write with approvals off, which edits files without asking -- not
  something to inherit silently in a workflow whose premise is that each node's
  effects are declared.
- `WORKFLOW_AGY_PROMPT_LIMIT` (default 28000). Antigravity takes its prompt on the
  command line and ignores stdin, so a longer prompt is refused rather than
  truncated.
- `WORKFLOW_OPENAI_MAX_TOKENS` (default 4096) for `openai-compat` nodes. Raise it if
  a reasoning-style self-hosted model returns nothing: those spend hidden thinking
  tokens before any visible output.
- `WORKFLOW_DELEGATE` (unset). Set to `1` for delegate mode; the same switch as
  `--delegate`, so a shell that always wants it can export it once.
- `WORKFLOW_BASH` (Windows only: which bash runs the step scripts)

## A note on the shape

Checks are separate nodes from the things they check. That costs a little plumbing
and buys four things: attempts you can count and cap, check output you can read and
diff, failures you can route somewhere other than back to the same agent, and halves
you can swap independently. Folding a check into its producer's prompt gives all four
back.
