# HALO 2.0 — Implementation Plan

**Companion to:** `SPEC.md` (v2). This is the *how/when/order*; the spec is the *what/why*.
**Version basis:** dsh 0.1.1-rc.2 (live, shipped v0.6.0).
**Date:** 2026-08-21
**Gating rule (spec §7 G8):** the verification matrix must be complete before build. This plan reports it complete-enough to start: 9 of 11 probes resolved from package source this session; the 2 open ones are sequenced as gated steps inside the build, and neither blocks the single-machine core.

---

## 1. Verification matrix — status (spec §8)

Resolved this session by reading **package source** (`npm pack @deepseek-ai/…@0.1.1-rc.2`) and the composed `web --dump-config`, not READMEs or auditor claims.

| V | Question | Status | Evidence |
|---|---|---|---|
| V1 | rc catalog | ✅ Resolved | 143 composed `- id:` entries enumerated |
| V2 | pin decision | ✅ Resolved | 0.1.1-rc.2 = npm `latest`+`next`; live |
| V3 | Ralph/timeout/subagent-control present | ✅ Resolved | all present in dump |
| **V4** | workflow concurrency key + default | ✅ Resolved | `dsh-tool-workflow/lib/index.js:848-880`: `maxConcurrentAgents` default 0 → `min(16,CPU-2)`; `maxTotalAgents` default **1000**; enforced in `worker.cjs:384,408` |
| V5 | two-machine simultaneous decode | ⛔ **Blocked** | needs 5070Ti up on LM Link; box is the stale clone, not live. External dependency |
| **V6** | context-pressure injectable | ✅ Resolved | `system-prompt` persona interpolates `{{model}}`/`{{cwd}}` — a template-variable seam exists |
| **V7** | per-session cancel endpoint | ✅ Resolved | `POST /api/session.cancel` via the same RPC envelope MC uses for `session.list` |
| V8 | continuable subagent under headless | ⏳ Open | needs one live headless run (slow, local brain). Sequenced in WP2 |
| **V9** | child model/reasoning inheritance | ✅ Resolved | children default to `agent-default-model` (lmstudio/qwen) via `subagentProvider: spawn`; no native `reasoningEfforts` — reasoning must be set per child |
| V10 | skill discovery path | ✅ Resolved | `skill-filesystem` present; exact path confirmed in WP2 |
| **V-A** | do the preset caps attach at runtime (PE-M1 risk) | ✅ Resolved (static, high-confidence) | preset `- id: workflow-worker-thread` + keys `maxConcurrentAgents/maxTotalAgents` **exactly match** `WorkerThreadWorkflowEngine.Config`; value `1`≠`0` so the cap resolves and holds. Belt-and-suspenders: the WP2 2-agent probe confirms at runtime |

**Two open items, neither blocking the core:**
- **V5 (federation)** is additive. The single-machine build proceeds; G6 already permits removing the federation claim if it can't be proven. Action to unblock: bring the 5070Ti up on LM Link (needs that box pulled + deployed — the stale-clone fix).
- **V8 (headless continuable)** is a cheap-to-specify, slow-to-run live probe. It rides along with the first real workflow run in WP2.

---

## 2. Build sequence (work packages)

Ordered by dependency. Each WP names its files, the native seam it uses, its acceptance gate, and what it depends on. "Done" = its gate's proof script is green on the live stack.

### WP0 — T0 config *(DONE, shipped v0.6.0)*
The caps and budgets from spec §1. Residual folded into WP6: set `maxResultChars`; add the runtime-attach 2-agent check (V-A) to WP2.

### WP1 — The deterministic core: `halo-size` + `halo-plan` + `halo-coverage`
- **Files:** `scripts/halo/Halo-Size.ps1` (or `.mjs`), `Halo-Plan.*`, `Halo-Coverage.*`; unit fixtures under `tests/halo/`.
- **Seam:** none — this is the genuine-gap code (spec §4.2.1/.2/.8). Pure functions, no model calls.
- **Contract:** `sizing.json`, `runs/<id>/manifest.json`, `units/unit-NNN.json`, coverage recompute + the E5 log-check.
- **Gate:** unit tests (same input → same units; nothing silently dropped; overhead-aware estimate); wired into `tests/Run-Tests.ps1` and a fail-closed mutation in `Prove-TestsFailClosed.ps1`.
- **Depends on:** nothing. **Start here.**

### WP2 — The `large-job` skill + canonical MAP template
- **Files:** `skills/large-job/SKILL.md`, `skills/large-job/map.workflow.js` (the canonical template), the selection rule + physics.
- **Seam:** `tool-workflow` + `workflow-worker-thread` (dsh API — `meta` is a tool param, **no** `export const meta`, E6); `skill-filesystem` for discovery.
- **In this WP:** run the **V8** probe (a continuable child under headless) and the **V-A** runtime check (a 2-agent script must show the 2nd agent queue, proving `maxConcurrentAgents:1` holds live).
- **Gate:** a scoped LJP run over a small fixture tree completes with report + coverage; parent context stays < 25K; zero compactions.
- **Depends on:** WP1, WP3.

### WP3 — The restricted LJP child preset (E5)
- **Files:** `dsh/agent-presets/halo-ljp-child/agent.cordis.yml` — the halo-standard preset minus `subagent-codex`, `subagent-claude-code`, `subagent-opencode-acp`.
- **Seam:** agent-preset composition; children spawn under this preset.
- **Gate:** **G9** — a child attempting an external provider is blocked by the preset; a planted out-of-policy call in a child log turns `halo-coverage` red.
- **Depends on:** WP1 (coverage log-check).

### WP4 — Mission Control: truth
- **Files:** `mission-control/mission-control.mjs` (+ its UI).
- **Seam:** the session JSONL the harness writes; `client-ui-workflow-run` records; `jobs-local`; `POST /api/session.cancel` (V7).
- **Scope:** derived liveness (STALLED from log progress, P6); per-session STOP; workflow/jobs/LJP-run panels (spec §4.6). Frame-walk the concatenated zstd session files.
- **Gate:** **G3** — a frozen session shows STALLED within N+1 min; STOP ends it without killing the server.
- **Depends on:** WP2 (for the LJP-run panel to have artifacts to render).

### WP5 — Mission Control: Settings tab
- **Files:** MC UI + a whitelisted line-level `settings.yaml` writer driving the existing Deploy/Sync machinery (no new editor in MC).
- **Scope:** live math, refusal-before-write, comment-preserving scalar edits, machine-profile check against every `machines/*.yml`, window/loader pairing (PR #38 class), drift record (spec §4.7).
- **Gate:** **G5** (refuses invalid states) + **G7** (operator changes window + compaction entirely from MC, no assistant).
- **Depends on:** WP4 (shares the MC app + deploy plumbing).

### WP6 — Config layer
- **Files:** `dsh/settings.yaml` `halo:` block (budgets, shape profiles, breaker K, stall N, routing table, per-machine ratios, **`maxResultChars`**), summarization route.
- **Seam:** `compaction-basic.summarizationProvider/-Model`; the routing table read by `halo-plan` and the MAP template.
- **Gate:** **G6** — summarization measured on the 5070Ti + two-machine map decode. **Federation half is gated on V5** (5070Ti up); the single-machine half (maxResultChars, shape profiles, halo: block) ships now.
- **Depends on:** WP1, WP5. **Federation sub-gate depends on the 5070Ti being live.**

### WP7 — Deletions
- Delete `pipeline/repo-review/`; shrink `AGENTS.md` orchestration prose to the skill pointer (spec §4.3).
- **Gate:** repo builds; no reference to the deleted paths; the skill pointer resolves.
- **Depends on:** WP2 (the skill must exist before AGENTS.md points at it).

### WP8 — G1 keystone: the job that failed, completed
- Re-run the 2026-08-20 whole-repo review brief end-to-end via LJP on the live stack, **unattended**.
- **Gate:** **G1** — report + coverage; **zero compaction events; zero idle-timeout retries**; parent < 25K; wall-clock recorded, target < 2 h (recompute from measured per-unit times).
- **Depends on:** WP1–WP4, WP6 (single-machine).
- This is the gate that defines "HALO 2.0 works." G2 (breaker) and G4 (reasoning share) are proven in the same run harness.

### WP9 — v2.1 first plugin: `halo-context-pressure` *(post-G1, sequenced)*
- ~40-line cordis plugin injecting the token-meter reading into the `system-prompt` seam (V6 confirmed the seam).
- **Ships only if** G1 shows budget-by-construction alone leaves the brain blind. The first genuine *plugin* — the proof the layer model works for a second operator.

---

## 3. Critical path & parallelism

```
WP1 ─┬─> WP3 ─> WP2 ─┬─> WP4 ─> WP5 ─┐
     │                │             ├─> WP8 (G1 keystone) ─> WP9 (v2.1)
     └────────────> WP6 (single) ───┘
                     WP6 (federation) … gated on 5070Ti (V5)
                     WP7 after WP2
```
- **WP1 is the unblocker** — start it first; everything downstream needs the scripts.
- **WP4+WP5 (Mission Control)** can proceed in parallel with WP2/WP3 once WP1's artifact contracts are fixed, since MC only *reads* the artifacts.
- **The only external blocker is the 5070Ti** (V5/federation). It gates one sub-part of WP6 and the federation half of G6 — nothing else.

## 4. Risks & open decisions

- **R1 — V-A runtime confirmation.** Static id/schema match is strong but the PE-M1 lesson says prove it live. Mitigation: the WP2 2-agent probe is a hard gate, not optional.
- **R2 — Reasoning control (spec Q4).** No native `reasoningEfforts` mapping exists. WP2 must pick and *measure* a mechanism (G4) — not assume `enable_thinking` works end-to-end (it was never proven).
- **R3 — 5070Ti availability.** Federation (V5/G6) can't be proven until that box is pulled, deployed, and on LM Link. Decision for the operator: bring it up now, or ship v2.0 single-machine and prove G6 later. The plan assumes the latter.
- **R4 — MC zero-dependency constraint vs comment-preserving YAML.** Spec Q5 (line-edit vs vendored CST library) is decided in WP5; default is line-level scalar replacement.

## 5. First action

**WP1.** Write `halo-size` / `halo-plan` / `halo-coverage` with unit tests + a fail-closed mutation, on a `feat/halo2-wp1` branch off master. It has no dependencies and unblocks the critical path.
