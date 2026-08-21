# HALO 2.0 — Autonomy Redesign Specification

**Status:** DRAFT for external audit (non-Claude reviewers). Do not implement from this document until the audit passes and the implementation plan exists.
**Date:** 2026-08-21
**Author:** Claude (Opus/Fable), under operator direction
**Supersedes:** `docs/design/autonomous-large-job/` (the external-driver design — see §2.3 for why it was wrong)
**Companion evidence:** PR #41 (compaction/timeout retune), issues #35/#39/#40, the 2026-08-20 failed-run session logs

---

## 0. One-paragraph summary

HALO 1.x shipped a working local inference platform and a working install/deploy system, but its "autonomy" was an operator illusion: every large job succeeded only because a frontier-model assistant decomposed it by hand, and the one job run without that help ran 4 h 41 m and produced nothing. The redesign is not to build an orchestration layer. The harness already ships one — subagents, a programmable workflow engine, goals, Ralph loops, a headless one-shot runner, loop guards, spill/prune/compaction context control — and HALO 1.x used almost none of it. HALO 2.0 is a **thin, deterministic layer on top of the harness's own autonomy primitives**: sizing and unit-planning scripts, one skill that teaches the brain the Large-Job Protocol, federation-aware routing config, and a Mission Control that tells the truth and gives the operator real controls. Build only what the harness verifiably lacks.

---

## 1. Evidence: what actually failed (all measured 2026-08-20)

| # | Failure | Measurement |
|---|---------|-------------|
| F1 | Whole-repo review attempted as ONE conversation turn | 1 turn, 35 steps, 4 h 41 m, no result |
| F2 | Retry re-prefilled the full context on every idle timeout | 2,396,400 input tokens on that single turn; 13 identical `pi-ai stream idle timeout after 300000ms` |
| F3 | Compaction could not converge | 5 identical failures: "summarization truncated at the token cap"; ~84K tokens into an 8,192 budget (10:1); cycles of 11.5/13.5/16.6/20.1 min; ~95 min of treadmill |
| F4 | 5 subagents fanned out onto a 1-slot model | All queued; 3 died on idle timeout; 1 never received a single token |
| F5 | Reasoning burned the budget | 4,320 reasoning chunks vs 391 text chunks (91% thinking) |
| F6 | Console reported the dead run as alive | `running: true` with frozen counters for 4 h 41 m; console trusted an upstream flag |
| F7 | Nothing stopped a non-progressing loop | 5 byte-identical compaction errors + 13 byte-identical timeouts, zero halts |
| F8 | The operator has no config surface | Every tunable required the assistant editing YAML |

Already fixed in config (v0.5.0 + PR #41) and **kept by this design**: `streamIdleTimeoutMs` 300000→1200000; compaction `thresholdRatio` 0.75, `retainRatio` 0.5 (ratio, not absolute — issue #39), summary `maxTokens` 12288 (2.7:1).

---

## 2. Principles

**P1 — The harness is the platform.** dsh ships 81 configured plugin entries in its stock autonomous composition, including a subagent family, a workflow engine, goals, Ralph, a headless runner, loop guards, and context-control policies. HALO adds a capability only after showing the harness lacks it. Every HALO component in this spec cites the native seam it builds on or the verified gap it fills. (Root cause of the 1.x failure: the assistant read 5 of 185 plugin packages before building a rival orchestrator.)

**P2 — Deterministic where determined.** Anything whose output is a pure function of its input is code, never a model call: inventory, token estimation, unit planning, routing, coverage accounting, liveness derivation. Model calls are reserved for judgment (what a unit *means*, what the findings *imply*).

**P3 — Bounded by construction.** No context is ever allowed to approach the compaction threshold as part of normal operation. Work is decomposed so each context stays small. Compaction remains configured as a safety net; **any compaction event during a protocol run is an alarm, not a mechanism.**

**P4 — Fresh context beats big context.** The window is a ceiling, not a target. Window size costs KV memory at load; *used depth* costs speed (measured: TTFT 259–403 s, decode ~9–11 tok/s deep). Forty 25K contexts finish; one 110K context dies. `subagent` spawn children (fresh context, shared workspace) are the bounded work cell.

**P5 — One decode lane per machine.** The brain serves `maxParallelPredictions: 1`. Concurrency equals the number of *machines* holding a usable model, never the number of agents. Fan-out beyond that queues callers into their own idle timeouts (F4).

**P6 — Corroborate everything observable.** No surface may repeat an upstream liveness claim without checking wall-clock progress against the durable session log (F6).

**P7 — Operator control is a product surface.** If the operator cannot change it from Mission Control, it is not configurable. YAML-by-assistant is the failure mode, not the fallback (F8).

**P8 — Record and continue; halt only on repetition.** A failed unit is recorded and the run continues (operator decision, 2026-08-21). K consecutive identical failures halt the run with a report. Silence is never success; coverage gaps are stated in the deliverable, machine-checked.

**P9 — Local models do the work.** The frontier model designs, reviews, audits. If a run needs a frontier model in the loop to *complete*, the design has failed. (Standing mandate, unchanged.)

---

### 2.3 Why the previous redesign is superseded

`docs/design/autonomous-large-job/` specified an **external Node driver** calling LM Studio directly. It was designed before the plugin inventory was read. It rebuilt, outside the harness: fan-out (`dsh-tool-workflow` has it), structured child results (`agent(prompt,{schema})` has it), run caps (`maxTotalAgents`, `AGENT_CAP`), cancellation (`worker.terminate()`), progress UI (`dsh-client-ui-workflow-run`), and background-job tracking (`dsh-jobs-local` + `dsh-tool-jobs`). It also threw away the harness's tools, session log, memory, and permission model. Its two useful ideas — deterministic sizing/planning and coverage accounting — are carried forward in §4. The external scripts (`pipeline/repo-review/`) are deleted by the implementation, not maintained.

---

## 3. Capability map: need → native seam → verified gap

The harness's own selection rule (rc.8 docs), adopted verbatim as HALO doctrine:

> Use **subagents** for bounded delegation. Use **workflow** for programmable fan-out/fan-in orchestration. Use **goals** for repeated work in the same conversation. Use **Ralph** for repeated fresh-agent attempts using the workspace as memory. Use **plan mode** when a human must review the plan before implementation. Use **headless** when one process should run one task and exit.

| Need (from §1) | Native capability | What HALO adds |
|---|---|---|
| Bounded work cell | `dsh-subagent` + `spawn` provider: fresh in-process child, no inherited history, full tool set, shared workspace | Nothing structural. A planning step that guarantees the child's *input* is bounded (§4.2), and a prompt contract for its output schema |
| Deterministic fan-out/fan-in driver | `dsh-workflow` + `dsh-workflow-worker-thread` + `dsh-tool-workflow`: model-written JS with `agent()`, `pipeline()`, `parallel()`, `phase()`, `log()`, schema-validated returns, `maxTotalAgents`, fatal `AGENT_CAP`/`ITEM_CAP`, real cancellation | A **canonical, audited workflow script template** shipped in the skill (§4.3), so the model fills in parameters instead of authoring orchestration from scratch each time |
| Pre-flight sizing | **None found** — the loop starts work with no fit check; token-meter feeds compaction, not planning | `halo-size` (code, §4.2.1) — the genuine gap #1 |
| Token-budget unit planning | **None found** — workflow scripts have no filesystem API; nothing chunks input to fit windows | `halo-plan` (code, §4.2.2) — the genuine gap #2 |
| Loop / repeat guard | `dsh-repeat-tool-reminder` (3/5/8 thresholds, active) | Config review only |
| Per-tool timeouts | `dsh-tool-call-timeout-policy` (rc.8; **verify presence in rc.7** — V3) | Nothing if present |
| Identical-failure circuit breaker | Partial (`repeat-tool-reminder` covers identical *tool calls* only) | Breaker counters inside the canonical workflow script (plain JS, deterministic); MC stall alarm as backstop (§4.6) |
| Oversized tool output control | `dsh-spill-policy` (50 KB divert) + `dsh-compaction-tool-result-pruner` (8,192-char prune) — both active | Config review; keep |
| Background work visibility | `dsh-jobs-local` + `dsh-tool-jobs` + `list_agents` / `send_message` / `interrupt_agent` (subagent-control) | MC rendering of the same data (§4.6) |
| Repeated same-session objective | `dsh-goal` + `dsh-goal-round-driver` + `/goal` + goal tools | Use as-is for maintenance objectives (§4.5) |
| Fresh-attempt iteration on a stubborn task | `dsh-tool-ralph` (rc.8; **verify in rc.7** — V3) | Use as-is where present |
| Batch / scheduled one-shot runs | `dsh-headless` bundle: one process, one task, prints result, exits with turn status | MC job launcher + Windows Task Scheduler entries (§4.5) |
| Human plan review | `dsh-plan-mode` | Use as-is; not central |
| Summarization off the brain | `dsh-compaction-basic` config: `summarizationProvider` / `summarizationModel` | **Config only**: route summaries to the idle 5070Ti identity over LM Link (§4.4) |
| Per-child model routing | `agent(prompt,{model})` in workflow scripts | Routing table in settings (§4.4) |
| Honest liveness | **None** — `running` flag is uncorroborated (F6) | MC derives STALLED from session-file progress (§4.6) — genuine gap #3 |
| Operator config surface | dsh web has model-selection settings UI only; compaction/timeout/window budgets live in `settings.yaml` | MC Settings tab (§4.7) — genuine gap #4 |
| Model sees its own budget | `dsh-token-meter` measures; `contextPressure` is exposed to *humans* via apiproxy; **nothing injects it into prompts** in rc.7 (verify — V6) | Budget-by-construction (planner caps inputs) now; prompt-injection of pressure is a v2.1 candidate, possibly via a tiny local plugin (§6) |

**The honest total: HALO 2.0 builds four things.** Two scripts (size, plan), one skill wrapping them plus a canonical workflow template, and two Mission Control capabilities (truthful liveness + settings). Everything else is configuration of what already runs.

---

## 4. Architecture

### 4.1 Job lanes

Every job enters one of four lanes. The skill (§4.3) states the selection rule; the sizing script makes the lane choice for anything tree-scale.

| Lane | Vehicle | Example |
|---|---|---|
| **Interactive small** | Ordinary turn, no protocol | "fix this function" |
| **Large-Job Protocol (LJP)** | §4.2 | "review this repository", "audit these docs", "summarize this corpus" |
| **Standing objective** | `goal` + round driver | "keep the manual in sync with the code until done" |
| **Batch / scheduled** | `headless` profile, launched by MC or Task Scheduler | nightly delta-scan; LJP runs launched unattended |
| **Stubborn retry** | `ralph` (if present in rc.7) | "make this flaky test pass" — fresh attempts, workspace as memory |

### 4.2 The Large-Job Protocol

The protocol is five phases. Phases 1, 2, and 5 are deterministic scripts run via the `pwsh` tool. Phase 3 is one `workflow` tool call. Phase 4 is inside that same call. **The parent conversation makes ~4 tool calls total and never grows past ~20K tokens — no compaction can occur by construction (P3).**

```
SIZE (code) → PLAN (code) → MAP (workflow: spawn children) → REDUCE (child, schema) → COVERAGE (code) → report
```

#### 4.2.1 SIZE — `halo-size` (deterministic)

Input: target paths. Walks the tree (skip list: `.git`, `node_modules`, `dist`, `vendor`, `__pycache__`, …), estimates tokens (chars/3.5, pessimistic), reads the **live** window and the machine's LJP settings from `settings.yaml`. Output `sizing.json`: estimated tokens, window, verdict.

Verdict rule: estimate ≤ 60% of window → `single-pass` allowed. Above → `decompose` required. Above the decompose ceiling (units × budget × safety) → `refuse` with the numbers, telling the operator what to change (MC Settings, §4.7).

Enforcement is honest-soft: the skill instructs the model to run SIZE first for any tree-scale ask and obey the verdict. Hard enforcement (a guard plugin that watches read-token accumulation and injects a protocol reminder) is a v2.1 candidate (§6). Auditors: challenge this softness (Q7).

#### 4.2.2 PLAN — `halo-plan` (deterministic)

Groups files into **units** under a per-unit prompt budget (default 24K tokens; per-machine override). Same input → same units, always. Writes `runs/<id>/units/unit-NNN.json` (file list + per-file byte caps + truncation record) and `runs/<id>/manifest.json`. Nothing is silently dropped: every file not fully included is listed with a reason (carried through to COVERAGE).

Unit contents are **file references, not file bodies** — children read their own files with their own tools. This keeps the workflow script's `args` tiny and sidesteps the worker's lack of filesystem access.

#### 4.2.3 MAP — one `workflow` tool call, canonical template

The skill ships a canonical script template; the model fills in the run id, unit count, and the finding schema. The template (audited once, reused always) implements:

- `pipeline(unitIds, ...)` with **engine concurrency matched to available machines** (§4.4); on a single-machine day that is 1 — sequential by design (P5/F4)
- each `agent()` call: a standalone prompt (spawn children inherit nothing) naming exactly one unit file, the brief, the output schema, and the instruction to read only the listed files
- `{schema}` on every call → validated structured findings; child writes `runs/<id>/findings/unit-NNN.json` and returns a ≤1K summary
- **record-and-continue** (operator decision): a `null` child (ordinary failure) is recorded as a failed unit and the run continues
- **breaker** (plain JS): ≥3 consecutive failures, or ≥K total with identical error text → stop mapping, return partial results flagged `halted`
- `phase()` / `log()` narration → the native workflow session events MC renders (§4.6)
- `maxTotalAgents` set from the manifest (units + reduce + margin) — the native hard cap backs the soft plan

#### 4.2.4 REDUCE — final `agent()` in the same script

One fresh child reads **only** `findings/` (never the sources), writes `runs/<id>/REPORT.md` answering the brief, with a mandatory coverage section. If the findings digest would exceed the child budget, the template runs a two-level reduce (group summaries → final). Reduce input size is a planner output, so this branch is decided deterministically, not improvised.

#### 4.2.5 COVERAGE — `halo-coverage` (deterministic)

Recomputes coverage from the manifest and findings on disk: units attempted/succeeded/failed, files truncated/omitted, breaker events. Fails (non-zero) if `REPORT.md` does not name every gap. A report that hides a gap is the most expensive artifact this system can produce (F6 generalized); the gate is code, not a prompt request.

### 4.3 Delivery vehicle: a skill, not a wrapper

The protocol ships as a **dsh skill** (`large-job`), discovered by the native `dsh-skill-filesystem` provider and loaded via the native `skill` tool — the harness's own mechanism for teaching procedures. The skill contains: the selection rule, the SIZE/PLAN/COVERAGE script invocations, the canonical MAP template, the record-and-continue and breaker policies, and the physics one-liners (window is a ceiling; one decode lane; compaction is an alarm). `AGENTS.md` shrinks to a pointer: *"for any job over one file's worth of reading, load the `large-job` skill first."* Scripts live in the deployed stack and are versioned/deployed by the existing Deploy-ToLive machinery like everything else.

### 4.4 Federation and routing (config, not code)

- **Summarization off the brain:** `compaction-basic.summarizationProvider/-Model` → the 5070Ti identity (`qwen/qwen3.8-27b-5070ti`) resolved over LM Link through the same local endpoint. The safety-net compactor stops competing with the brain's decode lane. One settings block.
- **Map-phase parallelism across machines:** workflow engine concurrency = number of machines with a usable idle model (verify the engine's concurrency config key — V4). The routing table in settings maps lanes to identities: sweeps may run on the 5070Ti/worker identities; synthesis stays on the brain. `agent(…,{model})` carries it per child.
- **Per-endpoint unit budgets:** a unit routed to the 5070Ti must fit *its* 40,448 window, not HALO's. `halo-plan` takes the routing table as input and sizes units per destination. (Issue #39's lesson as a design rule: every absolute budget scales by the machine that pays it.)
- **Verify before relying on it (V5):** that two federated identities genuinely decode simultaneously under LM Link, measured, not assumed.

### 4.5 Standing objectives, batch, and retry lanes

- **Goals:** long-running same-session objectives (doc-sync passes, migration checklists) use native `goal` + `goal-round-driver`; MC shows goal phase/round from the session projection. The round driver has no resource policy of its own — LJP's SIZE gate and the settings caps are the policy.
- **Headless batch:** MC gets a "Run job" launcher that shells `dsh --profile headless "<task>"` per run (native one-shot lifecycle: submit → idle → flush → print → exit). Scheduled work (nightly delta-scan) moves to Task Scheduler entries invoking the same, registered by Deploy-ToLive like the memory-snapshot task.
- **Ralph:** where present (V3), the sanctioned lane for "keep attempting until green" with fresh contexts and the workspace as memory — replacing 1.x's tendency to grind one session forever.

### 4.6 Mission Control 2.0 — truth first

- **Derived liveness (gap #3):** a session shown RUNNING must have appended to its durable log within N minutes (default 5). Otherwise it shows **STALLED — no progress for H:MM** and trips the alarm strip. The upstream `running` flag is displayed but never trusted (P6). Liveness derives from the same JSONL the harness itself writes.
  - *Implementation note carried from evidence:* session files are concatenated zstd frames; Node's `zlib` zstd APIs return only the first frame. MC's reader must walk frames (mtime+size suffice for liveness; frame-walk needed for content).
- **Per-session STOP:** a stop control per running session. Path: host-plane cancel via the apiproxy (verify the exact endpoint in rc.7 — V7); fallback documented if none exists. The 2026-08-20 run could only be stopped by killing the whole server process; that is not an operator control.
- **Workflow runs panel:** render the native workflow session records (run start/members/end): name, phase, per-child status, agents started vs cap, breaker state (from `log()` narration). The data already exists in the session log; MC displays it.
- **Jobs panel:** surface `dsh-jobs-local` state (the native background-job registry) instead of 1.x's ad-hoc process guessing.
- **LJP run view:** `runs/<id>/manifest.json` + findings on disk give MC a real progress bar — units done/failed/remaining, current unit, ETA from measured per-unit times. Honest because it is derived from artifacts, not from claims.

### 4.7 Mission Control Settings — the real config surface (gap #4)

The operator constraint, verbatim: he will not hand-edit `settings.yaml`, and a design that assumes he will has already failed.

- **Scope (v2.0):** context window + KV quant (per model), reasoning default, compaction budgets (`thresholdRatio`, `retainRatio`, summary `maxTokens`, retries), `streamIdleTimeoutMs`, LJP budgets (unit tokens, output tokens, breaker K, concurrency), routing table (lane → identity), summarization route.
- **Live math, refusal before write:** the tab shows derived consequences as the operator types — `compact at 98,304 · retain 65,536 · summarize 32,768 into 12,288 = 2.7:1 ✓` — and refuses invalid states: retain ≥ threshold; harness window ≠ loader window; absolute values that break any machine profile (the #39 check, run against every `machines/*.yml`); summary ratio > 4:1 flagged with the measured failure that motivates the limit.
- **Write path honoring doctrine:** MC edits **whitelisted scalar keys by line-level replacement** in `settings.yaml` — preserving the file's explanatory comments (a doctrine constraint; naive YAML re-serialization destroys them). Sequence: backup → edit lines → parse-validate (js-yaml) → machine-profile check → write → confirm hot-reload (~20 s) → mark **live-ahead-of-repo** drift with a one-click "commit to repo" that drives the existing Sync-FromLive path. The deploy drift guard already understands this state.
- **Window changes are compound:** changing the window queues the paired loader change (`contextLength` in the LM Studio loader script) and tells the operator a model reload is required — the two-surface mismatch is the exact bug class of PR #38, so the tab treats them as one operation.
- Every change writes an audit line (old → new, timestamp) MC can display. Rollback = restore from the backup the write created.

### 4.8 Settings additions (one home for HALO knobs)

A commented `halo:` block in `settings.yaml` (deployed, machine-profiled, MC-edited) holds: LJP budgets and shape profiles (`wide-sweep`: low reasoning, 24K/3K; `deep-dive`: medium, 48K/6K; `synthesis`: medium, 32K/8K), breaker K, stall threshold N, the routing table, and per-machine scaling ratios. Scripts and skill read this block — one source of truth for model, scripts, and operator.

**Reasoning control (open):** per-child reasoning effort is not in the workflow `agent()` options. Candidate mechanisms: session default via `reasoningEfforts` mapping; prompt-level soft switch (Qwen `/no_think`); LM Studio per-model preset; `chat_template_kwargs.enable_thinking` (worked at the raw API in one probe; **never verified end-to-end** — the patched smoke test was not re-run). This is a **measured decision for the implementation plan** (Q4). The F5 evidence (91% thinking) makes it load-bearing; the spec refuses to guess.

---

## 5. Traceability: failure → countermeasure → gate

| Failure | Countermeasure | Acceptance gate |
|---|---|---|
| F1 monolith turn | SIZE verdict + LJP decomposition | G1 |
| F2 timeout/re-prefill storm | Kept PR #41 config + small contexts by construction | G1 (zero retries in map), G5 |
| F3 compaction treadmill | Kept ratios + P3 (compaction event during LJP = alarm) | G1 (zero compactions), G3 alarm test |
| F4 fan-out onto 1 slot | P5: engine concurrency = machines; sequential default | G1, G6 |
| F5 reasoning burn | Shape profiles + measured reasoning-control decision | G4 |
| F6 lying console | Derived liveness; artifact-based progress | G3 |
| F7 no breaker | Script breaker + MC stall alarm | G2 |
| F8 no config surface | MC Settings tab | G7 |

---

## 6. Non-goals and deferred items

- **Forking dsh.** Everything here is config, skills, scripts, or MC code. If a need requires forking the harness, the need is redesigned. (Writing a *small local cordis plugin* is permitted-in-principle but deferred: candidates are a read-accumulation guard and a context-pressure prompt section — v2.1, only with measurements showing the soft mechanisms insufficient.)
- **Security sandboxing of workflow scripts.** The worker is containment, not a boundary (harness's own statement); scripts come from our own model under existing permissions. Out of scope.
- **The budgeted-emit pipeline** (`pipeline/`) stays as-is for large single-artifact emission; folding it into the skill family is v2.1.
- **Multi-operator, cloud, non-Windows.** Out of scope.
- **`pipeline/repo-review/`** is deleted, not maintained (superseded prototype; never completed a unit).

---

## 7. Acceptance gates (each ships as a runnable proof script, not a promise)

- **G1 — The job that failed, completed.** The 2026-08-20 review brief re-run end-to-end via LJP on the live stack, unattended: report + coverage produced; **zero compaction events; zero idle-timeout retries**; parent context < 25K; wall-clock recorded and < 2 h on current hardware (target, not guess — recompute from measured per-unit times in the plan).
- **G2 — Breaker proof.** Injected identical child failures halt the map at K, produce a `halted` partial result and a coverage report naming every unattempted unit.
- **G3 — Stall proof.** A deliberately frozen session shows STALLED in MC within N+1 minutes; alarm trips; per-session STOP ends it without killing the server.
- **G4 — Reasoning control proof.** The chosen mechanism measurably cuts reasoning share on a sweep unit (target: <30% of output tokens, from 91%).
- **G5 — Config safety proof.** MC Settings refuses: retain ≥ threshold; window mismatch with loader; any value breaking any `machines/*.yml` render (the #39 case, re-tested).
- **G6 — Federation proof.** Summarization measured running on the 5070Ti; two-machine map measured decoding simultaneously (or the claim is removed from docs).
- **G7 — Operator autonomy proof.** The operator changes window + compaction budgets entirely from MC — no assistant involvement — and the stack keeps working. This is the gate for the failure that motivated the redesign.
- **G8 — Capability verification matrix complete** (§8) before any build starts.

---

## 8. Verification matrix (fill during implementation planning — no build until done)

| V | Question | Method |
|---|---|---|
| V1 | Exact rc.7 live catalog vs the rc.8 list in this spec — which entries are absent/different? | Query the live plugin inventory API; diff |
| V2 | **Pin decision:** stay rc.7 or bump to rc.8 first? (This spec's source list is rc.8; rc.8 adds at least Ralph and timeout-policy naming.) | delta-scan + changelog review + sandboxed rc.8 trial; operator decides |
| V3 | `dsh-tool-ralph`, `dsh-tool-call-timeout-policy`, `subagent-control/list-agents` present in rc.7? | Inventory + tool catalog probe |
| V4 | Workflow engine concurrency config key + per-run `maxTotalAgents` behavior in rc.7 | README + live probe with a 3-agent script |
| V5 | Two LM Link identities decode simultaneously (brain + 5070Ti)? Real throughput both lanes? | Timed concurrent requests |
| V6 | Is any context-pressure value injectable into prompts in rc.7 (system-prompt runtime variables)? | `dsh-system-prompt` docs + probe |
| V7 | Host-plane per-session cancel endpoint for MC's STOP | apiproxy surface probe |
| V8 | `subagent` (continuable, background) vs one-shot semantics under headless — does the parent idle-wait cover continuable children? | Headless probe run |
| V9 | Spawn-child default model/reasoning inheritance — what exactly does `agent-default-model` give a child? | Probe + settings variation |
| V10 | Skill auto-discovery paths for `dsh-skill-filesystem` on this deployment | Config + probe |

---

## 9. Open questions for the external auditors

1. **Lane boundaries:** Is the §4.1 mapping of the harness's selection rule onto HALO's lanes correct, or are there jobs it misroutes?
2. **Sequential-by-default map:** With one machine, LJP is strictly sequential. Do you see a safe way to overlap prefill/decode on one endpoint, or is sequential correct?
3. **Two-level reduce:** Decided deterministically by the planner. Is the threshold logic sound, or should reduce always be hierarchical?
4. **Reasoning control:** Which of the §4.8 candidate mechanisms would you pick first, and why?
5. **Comment-preserving line edits** (§4.7) vs vendoring a CST-preserving YAML library into a deliberately zero-dependency MC — which risk is smaller?
6. **Soft SIZE enforcement** (§4.2.1): acceptable for v2.0 with G1 as the proof, or must the guard plugin be v2.0?
7. **Record-and-continue** with K-identical breaker: right defaults? (K, stall N, 60% fit threshold, 4:1 summary ceiling.)
8. **rc.8 bump before or after** building on rc.7? (V2.)
9. **What is missing** from the capability map — anything in the 81-entry composition this design should use and does not?
10. **What should be deleted** from this spec as still-too-much? P1 says build only the verified gap; hold the four build items to that standard.

---

## 10. What gets built, in one list (the whole of HALO 2.0's new code)

1. `halo-size` + `halo-plan` + `halo-coverage` — three deterministic scripts (~code, no model calls)
2. `skills/large-job/` — one skill: selection rule, protocol, canonical MAP template, physics
3. Mission Control: derived liveness + STOP + workflow/jobs/LJP panels (§4.6)
4. Mission Control: Settings tab with live math, refusal, comment-preserving writes, drift record (§4.7)
5. Config only: summarization route, routing table, `halo:` settings block, engine concurrency, machine-profile ratios
6. Deletions: `pipeline/repo-review/`; AGENTS.md orchestration prose shrinks to a skill pointer

Everything else in this document is the harness, used as shipped.
