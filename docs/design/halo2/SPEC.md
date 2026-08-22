# HALO 2.0 — Autonomy Redesign Specification (v2)

**Status:** Audit-incorporated draft. Three external audits folded in; every capability claim re-verified against live 0.1.1-rc.2 source (§0.1). One more external pass is planned before build (the order in §0.2). Do not implement past the T0 fixes already shipped until that pass and the implementation plan exist.
**Version basis:** dsh **0.1.1-rc.2** — settled, live, and shipped (v0.6.0). The v1 "rc.7 vs rc.8 pin decision" is closed; see §0.1.
**Date:** 2026-08-21
**Author:** Claude, under operator direction
**Distribution decision:** **Layer, sequenced** (operator, 2026-08-21) — HALO 2.0 is an installable layer other single operators can add on top of dsh, shipped as a skill + scripts + Mission Control + config + a sequenced set of small plugins. Not an appliance for one box. See §11.
**Supersedes:** SPEC v1 (this file's prior revision, PR #42) and `docs/design/autonomous-large-job/` (the external-driver design — §2.3).
**Companion evidence:** the 2026-08-20 failed-run session logs; v0.6.0 (migration + gate remediation); issues #35/#39/#40.

---

## 0. One-paragraph summary

HALO 1.x shipped a working local inference platform and a working install/deploy system, but its "autonomy" was an operator illusion: every large job succeeded only because a frontier-model assistant decomposed it by hand, and the one job run without that help ran 4 h 41 m and produced nothing. The redesign is not to build an orchestration layer. The harness already ships one — subagents, a programmable workflow engine, goals, Ralph loops, a headless one-shot runner, loop guards, spill/prune/compaction context control — and HALO 1.x used almost none of it. HALO 2.0 is a **thin, deterministic layer on top of the harness's own autonomy primitives**: sizing and unit-planning scripts, one skill that teaches the brain the Large-Job Protocol, a restricted child preset that keeps local work local, federation-aware routing config, and a Mission Control that tells the truth and gives the operator real controls. Build only what the harness verifiably lacks — and the verification is now done (§3).

---

## 0.1 What changed since v1 (the auditable delta)

v1 went to three external reviewers (two returned independent audits; the third merged both, against instructions, and is not counted). All three approved the core architecture — build on dsh-native primitives — and the source-verified reviewer found seven defects. Every one is dispositioned here, and every capability claim was re-checked against the composed 0.1.1-rc.2 config, not trusted from an auditor or from memory (that habit is exactly what caused the 1.x failure).

**Audit defects E1–E7 — disposition:**

| # | Defect (auditor) | Disposition in v2 |
|---|---|---|
| E1 | `maxTotalAgents` is engine config, not a workflow-script value | **Fixed + shipped (v0.6.0).** `maxTotalAgents: 64` lives in the agent preset, not a script. §1, §4.2.3. |
| E2 | Workflow concurrency defaults to CPU count **and** background jobs allow 10 children — F4 armed live, two doors | **Both doors shut + shipped (v0.6.0).** `maxConcurrentAgents: 1` (preset) and `maxConcurrentJobsPerOwner: 1` (cordis patch). The jobs cap is **verified to attach** in the composed 0.1.1-rc.2 config — it silently did not attach for months under a mis-typed patch id (the PE-M1 finding). §1, §3. |
| E3 | The v1 rc.7→rc.8 delta was wrong | **Corrected by source.** The version basis is now 0.1.1-rc.2 (newer than rc.8). Verified against the composed config: **`agent-team` is absent** — the v1 plan to use it as a resume path is dead (E4). `pwsh-persistent`, `file-reference`, `session-projection`, `goal-round-driver` **are present**. §3, §8. |
| E4 | The workflow engine has no native resume; fix = skip units with findings on disk | **Adopted as the mechanism.** There is no native resume/durability plugin in 0.1.1-rc.2 (verified absent). HALO's resume is deterministic: a re-run skips any unit whose `findings/unit-NNN.json` already exists. `session-projection` (present) feeds MC progress. §4.2.6. |
| E5 | LJP children can silently call Codex/Claude/OpenCode subagents — P9 is unenforceable without a restricted preset + a coverage check that reads child logs | **New build item.** A restricted LJP child preset bars the external subagent providers; mechanical-coverage reads child logs and fails the run if any child reached for a non-local provider. §3, §4.2.7. |
| E6 | The workflow tool's own system prompt discourages its use; the skill must override explicitly; dsh's `meta` is a tool parameter — there is no `export const meta` in dsh | **Corrected.** The canonical template and skill are written to dsh's actual workflow API (meta as a tool param), and the skill explicitly instructs the brain to prefer the template for tree-scale work. §4.2.3, §4.3. |
| E7 | `retryPolicy` silently defaults to 5 retries — F2's real mechanism still armed | **Fixed + shipped (v0.6.0).** `maxRetries: 1` in `settings.yaml`. §1. |

**Audit-2 corrections adopted:** rename "coverage" to **mechanical coverage** (it is code, not a model asking nicely); **honest scope count** — v1's "builds four things" undersold the work, the real surface is ~20 sub-items across scripts, skill, preset, MC, config, and deletions (§10); **overhead-aware token estimates** (planner accounts for prompt + schema + tool overhead, not just file bytes); **normalized breaker signatures** (compare error text after normalizing volatile substrings — ids, timestamps, paths); **size-driven hierarchical reduce** as the default shape, not an exception (§4.2.5); **token-based trigger**, not file-count, for lane selection (§4.1).

**Migration reconciliation (this session):** the whole stack moved rc.7 → 0.1.1-rc.2 via `pnpm dlx` (npm's resolver hangs on this Node 25 box for anything past rc.7). That closed the v1 pin question (V2/Q8) and shipped the T0 fixes. It also means the capability map below is verified against the version we actually run, not the version the audit assumed.

## 0.2 The order (T0 done; the rest gated)

0. ~~Verify audit claims against source~~ — **done** (§3, §8, this session).
1. ~~T0 config fixes~~ — **done + shipped in v0.6.0** (E1, E2, E7, compaction). Residual: `maxResultChars` (§4.8), runtime-attach proof for the preset/retry caps (§8 V-A).
2. ~~Site truth pass~~ — **done** (v0.6.0 gate remediation removed the unsupported claims; the mutation suite now fails closed if any return).
3. **SPEC v2** — this document.
4. **Implementation plan** — next; fills the §8 matrix, sequences §11.
5. **One external pass on v2, then build.**

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

**Already fixed in config and verified on 0.1.1-rc.2 — the T0 layer (v0.5.0 + v0.6.0):**
- `streamIdleTimeoutMs` 300000 → **1200000** (confirmed in `settings.yaml`).
- Compaction `thresholdRatio` 0.8, `retainRatio` ratio-not-absolute (issue #39), summary `maxTokens` 12288 — converges (2.7:1), no treadmill.
- **`maxConcurrentAgents: 1`** (agent preset) — F4 door 1.
- **`maxConcurrentJobsPerOwner: 1`** (cordis patch, **verified attaches** in the composed config) — F4 door 2. This is the door the PE-M1 finding proved had been open for months under a mis-typed id.
- **`maxTotalAgents: 64`** (agent preset) — the native hard backstop (E1).
- **`maxRetries: 1`** — F2's re-prefill storm (E7).

These are the countermeasures for F2/F3/F4 at the config level. HALO 2.0 keeps them and adds the *structural* countermeasures (decomposition, breaker, honest liveness) so the config caps are a floor, never the plan.

---

## 2. Principles

**P1 — The harness is the platform.** The stock 0.1.1-rc.2 web composition is **143 configured plugin entries**, including a subagent family (`tool-subagent`, `-control`, `-list-agents`), a workflow engine + worker-thread + run UI, goals (`goal`, `goal-round-driver`, `command-goal`), Ralph (`tool-ralph`), a headless bundle, loop guards (`repeat-tool-reminder`), per-tool timeouts (`timeout-policy`), spill (`spill-local`), plan mode, skill discovery (`skill-filesystem`), and a token meter — all verified present this session (§3). HALO adds a capability only after showing the harness lacks it. (Root cause of the 1.x failure: the assistant read 5 of ~185 plugin packages before building a rival orchestrator.)

**P2 — Deterministic where determined.** Anything whose output is a pure function of its input is code, never a model call: inventory, token estimation, unit planning, routing, coverage accounting, liveness derivation. Model calls are reserved for judgment.

**P3 — Bounded by construction.** No context is ever allowed to approach the compaction threshold as part of normal operation. Work is decomposed so each context stays small. Compaction remains configured as a safety net; **any compaction event during a protocol run is an alarm, not a mechanism.**

**P4 — Fresh context beats big context.** The window is a ceiling, not a target. Window size costs KV memory at load; *used depth* costs speed (measured: TTFT 259–403 s, decode ~9–11 tok/s deep). Forty 25K contexts finish; one 110K context dies. `subagent` spawn children (fresh context, shared workspace) are the bounded work cell.

**P5 — One decode lane per machine.** The brain serves `maxParallelPredictions: 1`. Concurrency equals the number of *machines* holding a usable model, never the number of agents. Fan-out beyond that queues callers into their own idle timeouts (F4).

**P6 — Corroborate everything observable.** No surface may repeat an upstream liveness claim without checking wall-clock progress against the durable session log (F6).

**P7 — Operator control is a product surface.** If the operator cannot change it from Mission Control, it is not configurable. YAML-by-assistant is the failure mode, not the fallback (F8).

**P8 — Record and continue; halt only on repetition.** A failed unit is recorded and the run continues (operator decision). K consecutive identical failures (signatures normalized) halt the run with a report. Silence is never success; coverage gaps are stated in the deliverable, machine-checked.

**P9 — Local models do the work, and are *kept* local.** The frontier model designs, reviews, audits. If a run needs a frontier model in the loop to *complete*, the design has failed. A local child that quietly delegates to Codex/Claude/OpenCode breaks this silently — so P9 is now *enforced*, not just stated (§4.2.7, E5).

---

### 2.3 Why the previous redesign is superseded

`docs/design/autonomous-large-job/` specified an **external Node driver** calling LM Studio directly. It was designed before the plugin inventory was read. It rebuilt, outside the harness: fan-out (`tool-workflow` has it), structured child results (`agent(prompt,{schema})` has it), run caps (`maxTotalAgents`), cancellation, progress UI (`client-ui-workflow-run`, verified present), and background-job tracking (`jobs-local` + `tool-jobs`). It also threw away the harness's tools, session log, memory, and permission model. Its two useful ideas — deterministic sizing/planning and coverage accounting — are carried forward in §4. The external scripts (`pipeline/repo-review/`) are deleted by the implementation, not maintained.

---

## 3. Capability map: need → native seam (verified) → gap HALO fills

The harness's own selection rule, adopted verbatim as HALO doctrine:

> Use **subagents** for bounded delegation. Use **workflow** for programmable fan-out/fan-in orchestration. Use **goals** for repeated work in the same conversation. Use **Ralph** for repeated fresh-agent attempts using the workspace as memory. Use **plan mode** when a human must review the plan before implementation. Use **headless** when one process should run one task and exit.

Presence column legend: **✓** = verified in the composed 0.1.1-rc.2 config this session; **✓(dep)** = present as a profile/dependency not in the web-profile dump (e.g. headless); **✗** = verified absent (a genuine gap).

| Need (from §1) | Native seam | Present? | What HALO adds |
|---|---|:--:|---|
| Bounded work cell | `tool-subagent` + `spawn`: fresh in-process child, no inherited history, shared workspace | ✓ | A planning step guaranteeing the child's *input* is bounded (§4.2.2) + an output-schema contract |
| Deterministic fan-out/fan-in | `tool-workflow` + `workflow-worker-thread` + `client-ui-workflow-run`: model-written JS with `agent()`, `pipeline()`, `parallel()`, schema returns, `maxTotalAgents` | ✓ | A **canonical, audited workflow template** in the skill (§4.2.3), written to dsh's real API, so the brain fills parameters instead of authoring orchestration each time (E6) |
| Pre-flight sizing | none — the loop starts work with no fit check; token-meter feeds compaction, not planning | ✗ | **`halo-size`** (code, §4.2.1) — **genuine gap #1** |
| Token-budget unit planning | none — workflow scripts have no filesystem API; nothing chunks input to fit windows | ✗ | **`halo-plan`** (code, §4.2.2) — **genuine gap #2** |
| Mechanical coverage accounting | none | ✗ | **`halo-coverage`** (code, §4.2.8) — **genuine gap #3** |
| Cross-run resume | no native resume/durability plugin (`agent-team` absent) | ✗ | Deterministic skip-if-findings-exist (§4.2.6) — **genuine gap #4** |
| Keep local work local | subagent providers include external Codex/Claude/OpenCode; no native restriction | ✗ | **Restricted LJP child preset** + coverage log-check (§4.2.7, E5) — **genuine gap #5** |
| Loop / repeat guard | `repeat-tool-reminder` (3/5/8 thresholds) | ✓ | Config review only |
| Per-tool timeouts | `timeout-policy` / `tool-call-timeout-policy` | ✓ | Nothing — use as-is |
| Identical-failure breaker | partial (`repeat-tool-reminder` covers identical *tool calls* only) | ✓ | Normalized-signature breaker inside the canonical template (plain JS); MC stall alarm backstop (§4.6) |
| Oversized tool-output control | `spill-local` + `compaction-tool-result-pruner` | ✓ | Config review; keep. Plus set `maxResultChars` (§4.8) |
| Background work visibility | `jobs-local` + `tool-jobs` + `tool-subagent-control` (list-agents/interrupt/send) | ✓ | MC rendering of the same data (§4.6) |
| Repeated same-session objective | `goal` + `goal-round-driver` + `command-goal` | ✓ | Use as-is for maintenance objectives (§4.5) — no longer "build our own" |
| Fresh-attempt iteration | `tool-ralph` | ✓ | Use as-is (§4.5) — v1's "verify in rc.7" is resolved: present |
| Batch / scheduled one-shot | `headless` bundle: one process, one task, print, exit | ✓(dep) | MC job launcher + Task Scheduler entries (§4.5) |
| Human plan review | `plan-mode` | ✓ | Use as-is; not central |
| Summarization off the brain | `compaction-basic`: `summarizationProvider` / `-Model` | ✓ | **Config only**: route summaries to the idle 5070Ti identity over LM Link (§4.4) |
| Per-child model routing | `agent(prompt,{model})` | ✓ | Routing table in settings (§4.4) |
| Honest liveness | none — `running` flag uncorroborated (F6) | ✗ | MC derives STALLED from session-log progress (§4.6) — **genuine gap #6** |
| Operator config surface | web has model-selection UI only; budgets live in `settings.yaml` | ✗ | MC Settings tab (§4.7) — **genuine gap #7** |
| Model sees its own budget | `system-prompt` plugin present (injection point exists); `token-meter` measures; **no context-pressure value is injected into prompts** | ✗ (the value) | Budget-by-construction now; a tiny **`halo-context-pressure` plugin** is the first sequenced layer piece (§11) — **genuine gap #8** |

**Honest total (audit-2 correction).** HALO 2.0 is **not** "four things." It is roughly twenty sub-items: three deterministic scripts; one skill with a canonical template and policies; one restricted child preset; six-plus Mission Control capabilities (liveness, STOP, workflow panel, jobs panel, LJP run view, Settings tab with live-math/refusal/comment-preserving writes/drift); a config layer (summarization route, routing table, `halo:` block, engine concurrency, machine ratios, `maxResultChars`); deletions; and a sequenced plugin (`halo-context-pressure`). §10 lists them. Everything else in this document is the harness, used as shipped.

---

## 4. Architecture

### 4.1 Job lanes

Every job enters one lane. The skill states the selection rule; `halo-size` makes the choice for anything tree-scale. **The trigger is estimated tokens, not file count** (audit-2): a 200-file config tree may fit one context; a 3-file corpus may not.

| Lane | Vehicle | Example |
|---|---|---|
| **Interactive small** | Ordinary turn, no protocol | "fix this function" |
| **Large-Job Protocol (LJP)** | §4.2 | "review this repository", "audit these docs", "summarize this corpus" |
| **Standing objective** | `goal` + `goal-round-driver` | "keep the manual in sync with the code until done" |
| **Batch / scheduled** | `headless` profile, launched by MC or Task Scheduler | nightly delta-scan; unattended LJP runs |
| **Stubborn retry** | `tool-ralph` | "make this flaky test pass" — fresh attempts, workspace as memory |

### 4.2 The Large-Job Protocol

Six phases. Phases 1, 2, 6 are deterministic scripts run via the `pwsh` tool. Phase 3 is one `workflow` tool call; phases 4–5 are inside that call. **The parent conversation makes ~4 tool calls total and never grows past ~20K tokens — no compaction can occur by construction (P3).**

```
SIZE (code) → PLAN (code) → MAP (workflow: spawn children) → REDUCE (child, schema) → COVERAGE (code) → report
                                   ↑ resume: skip units whose findings already exist on disk
```

#### 4.2.1 SIZE — `halo-size` (deterministic)

Input: target paths. Walks the tree (skip `.git`, `node_modules`, `dist`, `vendor`, `__pycache__`, …), estimates tokens **overhead-aware** (file bytes ÷ 3.5, plus a fixed per-unit allowance for prompt + schema + tool framing — audit-2), reads the **live** window and the machine's LJP settings from `settings.yaml`. Output `sizing.json`: estimated tokens, window, verdict.

Verdict rule: estimate ≤ 60% of window → `single-pass` allowed. Above → `decompose`. Above the decompose ceiling (units × budget × safety) → `refuse` with the numbers and what to change (MC Settings, §4.7).

Enforcement is honest-soft in v2.0: the skill instructs the brain to run SIZE first for any tree-scale ask and obey the verdict. Hard enforcement (a read-accumulation guard plugin) is a sequenced layer piece (§11), built only if G1 shows the soft path insufficient. Auditors: challenge this (Q6).

#### 4.2.2 PLAN — `halo-plan` (deterministic)

Groups files into **units** under a per-unit prompt budget (default 24K; per-machine and per-destination override, §4.4). Same input → same units, always. Writes `runs/<id>/units/unit-NNN.json` (file list + per-file byte caps + truncation record) and `runs/<id>/manifest.json`. Nothing is silently dropped: every file not fully included is listed with a reason, carried to COVERAGE.

Unit contents are **file references, not file bodies** — children read their own files with their own tools. This keeps the workflow `args` tiny and sidesteps the worker's lack of filesystem access.

#### 4.2.3 MAP — one `workflow` tool call, canonical template

The skill ships a canonical script the brain parameterizes (run id, unit count, finding schema). Written to **dsh's actual workflow API** — `meta` is a tool parameter, there is no `export const meta` (E6). The template (audited once, reused always) implements:

- `pipeline(unitIds, …)` with **engine concurrency matched to available machines** (§4.4); single-machine day = 1, sequential by design (P5/F4)
- each `agent()` call: a standalone prompt (children inherit nothing) naming exactly one unit file, the brief, the output schema, and "read only the listed files"
- `{schema}` on every call → validated structured findings; child writes `runs/<id>/findings/unit-NNN.json`, returns a ≤1K summary
- **record-and-continue**: a `null` child is recorded as a failed unit; the run continues
- **normalized-signature breaker** (audit-2): ≥3 consecutive failures, or ≥K total with identical error text *after normalizing ids/timestamps/paths* → stop, return partial flagged `halted`
- `phase()` / `log()` narration → native workflow session events MC renders (§4.6)
- `maxTotalAgents` set from the manifest (units + reduce + margin) — the native hard cap backs the soft plan
- children run under the **restricted LJP preset** (§4.2.7) — no external subagent providers

The skill's prose explicitly tells the brain to **prefer this template** for tree-scale work, overriding the workflow tool's own use-discouraging preamble (E6).

#### 4.2.4 REDUCE — final `agent()` in the same script

One fresh child reads **only** `findings/` (never the sources), writes `runs/<id>/REPORT.md` answering the brief, with a mandatory coverage section.

#### 4.2.5 Hierarchical reduce by default (audit-2)

Reduce is **hierarchical by default**, not as an exception: findings are grouped (by unit range or theme) → group summaries → final. The planner decides the grouping deterministically from the findings' measured size, so the shape is never improvised. A tiny run collapses to a single level automatically. (Audit-2 Q3: always-hierarchical is safer than a threshold branch; adopted.)

#### 4.2.6 RESUME — skip units with findings on disk (E4)

The workflow engine has no native resume (`agent-team` absent). HALO's resume is deterministic and needs no plugin: on a re-run of the same `runs/<id>`, MAP skips any unit whose `findings/unit-NNN.json` already exists and is schema-valid. A killed or halted run resumes by re-invoking with the same id; only unattempted units run. `session-projection` (present) supplies MC's live progress across the resume.

#### 4.2.7 Child containment — the restricted LJP preset (E5)

P9 ("local models do the work") was unenforceable in v1: a spawned child has the full tool set, including the Codex/Claude/OpenCode subagent providers, and could silently escalate a "local" run to a frontier API. v2 closes this two ways:

- **Restricted preset:** LJP children run under an agent preset that omits the external subagent providers (`subagent-codex`, `subagent-claude-code`, `subagent-opencode-acp`) from the child's composition. The child physically cannot call them.
- **Coverage log-check:** `halo-coverage` (§4.2.8) reads each child's session log and fails the run (non-zero) if any child invoked a non-local provider. Defense in depth — the preset is the wall, the check is the tripwire.

#### 4.2.8 COVERAGE — `halo-coverage` (deterministic, "mechanical coverage")

Recomputes coverage from the manifest + findings on disk: units attempted/succeeded/failed, files truncated/omitted, breaker events, and (E5) any out-of-policy provider call in a child log. Fails (non-zero) if `REPORT.md` does not name every gap, or if containment was breached. A report that hides a gap is the most expensive artifact this system can produce (F6 generalized); the gate is code, not a prompt request. Named **mechanical coverage** (audit-2) to keep it distinct from a model claiming it covered everything.

### 4.3 Delivery vehicle: a skill, not a wrapper

The protocol ships as a **dsh skill** (`large-job`), discovered by `skill-filesystem` (verified present) and loaded via the native `skill` tool. It contains: the selection rule, the SIZE/PLAN/COVERAGE invocations, the canonical MAP template, the record-and-continue + normalized breaker policies, the restricted-preset requirement, and the physics one-liners (window is a ceiling; one decode lane; compaction is an alarm). `AGENTS.md` shrinks to a pointer: *"for any job over one file's worth of reading, load the `large-job` skill first."* Scripts deploy via the existing Deploy-ToLive machinery.

### 4.4 Federation and routing (config, not code)

- **Summarization off the brain:** `compaction-basic.summarizationProvider/-Model` → the 5070Ti identity resolved over LM Link. The safety-net compactor stops competing with the brain's decode lane. One settings block.
- **Map-phase parallelism across machines:** workflow engine concurrency = machines with a usable idle model. The routing table maps lanes to identities: sweeps may run on 5070Ti/worker identities; synthesis stays on the brain. `agent(…,{model})` carries it per child.
- **Per-endpoint unit budgets:** a unit routed to the 5070Ti must fit *its* window, not HALO's. `halo-plan` takes the routing table as input and sizes units per destination (issue #39's lesson as a design rule).
- **Verify before relying on it (V5):** that two federated identities genuinely decode simultaneously under LM Link — measured, not assumed.

### 4.5 Standing objectives, batch, and retry lanes

- **Goals** (verified present): long-running same-session objectives use `goal` + `goal-round-driver`; MC shows goal phase/round from `session-projection`. The round driver has no resource policy of its own — LJP's SIZE gate and the settings caps are the policy.
- **Headless batch:** MC gets a "Run job" launcher shelling `dsh --profile headless "<task>"` per run. Scheduled work (nightly delta-scan) moves to Task Scheduler entries invoking the same, registered by Deploy-ToLive like the memory-snapshot task.
- **Ralph** (verified present): the sanctioned lane for "keep attempting until green" with fresh contexts and the workspace as memory — replacing 1.x's grind-one-session-forever.

### 4.6 Mission Control 2.0 — truth first

MC stays an **external watchdog, never a cockpit plugin** (operator constraint): the 4h41m stall was diagnosed *only* because MC lived outside the wedged harness. Putting it inside would blind it to exactly the failure it exists to catch.

- **Derived liveness (gap #6):** a session shown RUNNING must have appended to its durable log within N minutes (default 5). Otherwise **STALLED — no progress for H:MM** + alarm strip. The upstream `running` flag is displayed but never trusted (P6).
  - *Implementation note:* session files are concatenated zstd frames; Node `zlib` returns only the first frame. MC's reader walks frames (mtime+size for liveness; frame-walk for content).
- **Per-session STOP:** a stop control per running session via the host-plane cancel endpoint (exact endpoint is V7). The 2026-08-20 run could only be stopped by killing the whole server; that is not an operator control.
- **Workflow runs panel:** render native `client-ui-workflow-run` session records: name, phase, per-child status, agents started vs cap, breaker state (from `log()`). The data already exists in the session log.
- **Jobs panel:** surface `jobs-local` state instead of 1.x's process guessing.
- **LJP run view:** `manifest.json` + findings on disk give a real progress bar — units done/failed/remaining, current unit, ETA from measured per-unit times. Honest because derived from artifacts.

### 4.7 Mission Control Settings — the real config surface (gap #7)

The operator will not hand-edit `settings.yaml`, and a design that assumes he will has already failed (F8). **The Settings tab is fully interactive, but Apply drives the existing Deploy/Sync machinery under the hood — no new text editor in MC** (operator constraint; keeps G7 and the deploy drift-guard intact).

- **Scope (v2.0):** context window + KV quant (per model), reasoning default, compaction budgets, `streamIdleTimeoutMs`, LJP budgets (unit tokens, output tokens, breaker K, concurrency), routing table, summarization route, `maxResultChars`.
- **Live math, refusal before write:** derived consequences shown as the operator types — `compact at 98,304 · retain 65,536 · summarize 32,768 into 12,288 = 2.7:1 ✓` — and refusal of invalid states: retain ≥ threshold; harness window ≠ loader window; any absolute that breaks a `machines/*.yml` profile (the #39 check, run against every profile); summary ratio > 4:1 flagged with the measured failure behind the limit.
- **Write path honoring doctrine:** MC edits **whitelisted scalar keys by line-level replacement**, preserving the file's explanatory comments (naive YAML re-serialization destroys them). Sequence: backup → edit lines → parse-validate (js-yaml) → machine-profile check → write → confirm hot-reload (~20 s) → mark **live-ahead-of-repo** drift with one-click "commit to repo" driving Sync-FromLive.
- **Window changes are compound:** a window change queues the paired loader change (`contextLength` in the LM Studio loader script) and tells the operator a reload is required — the two-surface mismatch is the PR #38 bug class, so the tab treats them as one operation.
- Every change writes an audit line (old → new, timestamp). Rollback = restore from the backup.

### 4.8 Settings additions (one home for HALO knobs)

A commented `halo:` block in `settings.yaml` (deployed, machine-profiled, MC-edited) holds: LJP budgets and shape profiles (`wide-sweep`: low reasoning, 24K/3K; `deep-dive`: medium, 48K/6K; `synthesis`: medium, 32K/8K), breaker K, stall threshold N, the routing table, per-machine scaling ratios, and **`maxResultChars`** (residual T0 item: not currently set, so tool results still return at the stock default; set it here — the ~2K target is a tuning call with a truncation tradeoff, so it lands as an operator-visible knob, not a silent slam).

**Reasoning control (open, verified genuinely unset):** no `reasoningEfforts` mapping appears in the composed config, so per-child reasoning is not a solved native knob. Candidate mechanisms: session default via a `reasoningEfforts` map (if the provider honors it); prompt-level soft switch (Qwen `/no_think`); LM Studio per-model preset; `chat_template_kwargs.enable_thinking` (worked at the raw API once; **never verified end-to-end**). A **measured decision for the implementation plan** (Q4). F5 (91% thinking) makes it load-bearing; the spec refuses to guess.

---

## 5. Traceability: failure → countermeasure → gate

| Failure | Countermeasure | Acceptance gate |
|---|---|---|
| F1 monolith turn | SIZE verdict + LJP decomposition | G1 |
| F2 timeout/re-prefill storm | `maxRetries: 1` (shipped) + small contexts by construction | G1 (zero retries in map), G5 |
| F3 compaction treadmill | Kept ratios + P3 (compaction during LJP = alarm) | G1 (zero compactions), G3 alarm test |
| F4 fan-out onto 1 slot | Both caps shipped + P5 engine concurrency = machines | G1, G6 |
| F5 reasoning burn | Shape profiles + measured reasoning-control decision | G4 |
| F6 lying console | Derived liveness; artifact-based progress | G3 |
| F7 no breaker | Normalized-signature script breaker + MC stall alarm | G2 |
| F8 no config surface | MC Settings tab (Apply → deploy machinery) | G7 |
| E5 silent frontier escalation | Restricted child preset + coverage log-check | G9 |

---

## 6. Non-goals and deferred items

- **Forking dsh.** Everything here is config, skills, scripts, a preset, MC code, or *small local cordis plugins* shipped as sequenced layer pieces (§11). If a need requires forking the harness core, the need is redesigned.
- **Security sandboxing of workflow scripts.** The worker is containment, not a boundary (harness's own statement); scripts come from our own model under existing permissions. The E5 preset restriction is about *provider policy*, not sandboxing. Out of scope otherwise.
- **The budgeted-emit pipeline** (`pipeline/`) stays as-is for large single-artifact emission; folding it into the skill family is a later layer piece.
- **Multi-operator and cloud tenancy.** "Layer" (§11) means *another single operator can install the same stack on their own Windows box* — not multi-tenant, not hosted. Those stay out of scope.
- **Non-Windows.** Out of scope for v2.0; the layer's scripts are PowerShell + Node.
- **`pipeline/repo-review/`** is deleted, not maintained.

---

## 7. Acceptance gates (each ships as a runnable proof script, not a promise)

- **G1 — The job that failed, completed.** The 2026-08-20 review brief re-run end-to-end via LJP on the live stack, unattended: report + coverage produced; **zero compaction events; zero idle-timeout retries**; parent context < 25K; wall-clock recorded and < 2 h on current hardware (recompute from measured per-unit times in the plan).
- **G2 — Breaker proof.** Injected identical child failures halt the map at K, produce a `halted` partial and a coverage report naming every unattempted unit.
- **G3 — Stall proof.** A deliberately frozen session shows STALLED in MC within N+1 minutes; alarm trips; per-session STOP ends it without killing the server.
- **G4 — Reasoning control proof.** The chosen mechanism measurably cuts reasoning share on a sweep unit (target: <30% of output tokens, from 91%).
- **G5 — Config safety proof.** MC Settings refuses: retain ≥ threshold; window mismatch with loader; any value breaking any `machines/*.yml` render.
- **G6 — Federation proof.** Summarization measured on the 5070Ti; two-machine map measured decoding simultaneously (or the claim is removed from docs).
- **G7 — Operator autonomy proof.** The operator changes window + compaction budgets entirely from MC — no assistant — and the stack keeps working. This is the gate for the failure that motivated the redesign.
- **G8 — Capability verification matrix complete** (§8) before build.
- **G9 — Containment proof (E5).** An LJP child attempting an external subagent provider is blocked by the preset; a planted out-of-policy call in a child log turns COVERAGE red.

---

## 8. Verification matrix

Most of v1's matrix is resolved this session against the composed 0.1.1-rc.2 config. Remaining probes are the ones needing a *runtime measurement*, not a presence check.

| V | Question | Status |
|---|---|---|
| ~~V1~~ | rc.7 vs rc.8 catalog delta | **Resolved** — basis is 0.1.1-rc.2; 143 composed entries enumerated |
| ~~V2~~ | Pin decision rc.7 vs rc.8 | **Resolved** — 0.1.1-rc.2 (npm `latest`+`next`), live + shipped |
| ~~V3~~ | Ralph, timeout-policy, subagent-control present? | **Resolved — all present** (verified in dump) |
| V4 | Workflow engine concurrency config key + per-run `maxTotalAgents` behavior | **Probe** — 3-agent script on the live engine |
| V5 | Two LM Link identities decode **simultaneously** (brain + 5070Ti)? | **Probe** — timed concurrent requests |
| V6 | Is a context-pressure value injectable via the `system-prompt` plugin (present)? | **Probe** — the injection point exists; confirm runtime variable path (drives §11 plugin) |
| V7 | Host-plane per-session cancel endpoint for MC STOP | **Probe** — apiproxy surface |
| V8 | `subagent` continuable/background vs one-shot under headless — does the parent idle-wait cover continuable children? | **Probe** — headless run |
| V9 | Spawn-child default model/reasoning inheritance from `agent-default-model` | **Probe** |
| ~~V10~~ | Skill auto-discovery path (`skill-filesystem`) | **Resolved — present**; exact path confirmed in impl plan |
| **V-A** | Do `maxConcurrentAgents`/`maxTotalAgents`/`maxRetries` **attach at runtime** at 0.1.1 (preset + retry-policy compose separately from `web --dump-config`)? | **Probe** — the PE-M1 lesson: present-in-file ≠ attaches. Verify via a composed-preset dump or a live 2-agent probe |

---

## 9. Open questions for the external auditors (v2)

1. **Lane boundaries:** Is the §4.1 token-triggered mapping correct, or are there jobs it misroutes?
2. **Sequential-by-default map:** With one machine, LJP is strictly sequential. A safe way to overlap prefill/decode on one endpoint, or is sequential correct?
3. ~~Two-level reduce threshold~~ — **resolved:** hierarchical by default (§4.2.5).
4. **Reasoning control:** Which §4.8 candidate first, and why? (No native `reasoningEfforts` mapping exists — verified.)
5. **Comment-preserving line edits** (§4.7) vs vendoring a CST-preserving YAML library into a zero-dependency MC — which risk is smaller?
6. **Soft SIZE enforcement** (§4.2.1): acceptable for v2.0 with G1 as proof, or must the guard plugin ship in v2.0?
7. **Record-and-continue defaults:** K, stall N, 60% fit threshold, 4:1 summary ceiling — right numbers?
8. ~~rc.8 bump before or after~~ — **resolved:** on 0.1.1-rc.2.
9. **Containment (E5):** is preset-omission of the external providers sufficient, or can a child re-enable a provider at runtime? What else must the log-check catch?
10. **Layer packaging (§11):** is the sequenced-plugin plan the right distribution shape, and what is missing from the capability map that a second operator would need?

---

## 10. What gets built, in one list (the whole of HALO 2.0's new surface)

1. `halo-size` + `halo-plan` + `halo-coverage` — three deterministic scripts (no model calls); coverage includes the E5 log-check.
2. `skills/large-job/` — one skill: selection rule, protocol, canonical MAP template (dsh API, E6), hierarchical reduce, resume, normalized breaker, restricted-preset requirement, physics.
3. The **restricted LJP child preset** — an agent preset omitting the external subagent providers (E5).
4. Mission Control: derived liveness + per-session STOP + workflow/jobs/LJP panels (§4.6).
5. Mission Control: Settings tab — live math, refusal, comment-preserving writes via the deploy machinery, drift record (§4.7).
6. Config: summarization route, routing table, `halo:` block, `maxResultChars`, engine concurrency, machine-profile ratios.
7. Deletions: `pipeline/repo-review/`; AGENTS.md orchestration prose → skill pointer.
8. Sequenced layer plugin (post-G1): `halo-context-pressure` (§11) — the first shippable layer piece; built only if V6 confirms the injection path and G1 shows budget-by-construction alone is insufficient.

Everything else in this document is the harness, used as shipped.

---

## 11. Distribution model — the layer (operator decision, 2026-08-21)

HALO 2.0 ships as a **layer another single operator can install on top of stock dsh**, not a private appliance. The public repo already has downloaders; an appliance-for-one throws that away.

**What the layer is:** the deploy machinery installs, over a stock dsh, the §10 surface — scripts, the `large-job` skill, the restricted preset, the Mission Control app, and the `halo:` config block — pinned to a known dsh version (currently 0.1.1-rc.2, installed via `pnpm dlx` because npm's resolver hangs past rc.7 on Node 25). Nothing here forks dsh; it is additive config, skills, a preset, and an external app.

**Sequenced, not all-at-once.** The layer ships in order of proven need:
1. **v2.0 core** — LJP (scripts + skill + restricted preset), MC truth + STOP + panels, MC Settings, the config layer. Gated by G1–G9.
2. **v2.1 first plugin** — `halo-context-pressure` (~40 lines): injects the token-meter's pressure reading into the system prompt via the present `system-prompt` seam (gap #8). Ships only after V6 confirms the injection path and G1 shows budget-by-construction alone leaves the brain blind. This is the first piece that is genuinely a *plugin*, and the proof the layer model works for others.
3. **Later** — read-accumulation guard (hard SIZE enforcement) if G1 shows the soft path leaks; budgeted-emit pipeline folded into the skill family.

**What "layer" does not mean:** not multi-tenant, not hosted, not cross-OS. A second operator installs the same single-operator Windows stack on their own machine. Multi-operator/cloud/non-Windows stay non-goals (§6).

**Portability the layer must earn (for auditors, Q10):** every absolute budget already scales by machine profile (§4.4, issue #39). The open portability risks for a second operator are: hardcoded identity names in the routing table (must become profile config), the 5070Ti-specific federation defaults (must degrade cleanly to single-machine), and the LM Studio loader-script coupling (§4.7 window/loader pairing). The implementation plan resolves these before the layer is called installable-by-others.
