# Local AI System Design — v2 (FINAL)

**DeepSeek Harness + LM Studio + OpenCode on Windows 11 / AMD Strix Halo (HALO)**
**Design date:** August 17, 2026
**Author:** Claude (Fable 5). Base: Claude v1 source-level design, corrected and merged after cross-review by Codex and Grok. Convergence is unanimous.
**Status:** FINAL — approved for execution. Model layer verified live (`lms ps --json`). Harness not yet installed.

Changes from v1: provider config moved to `settings.yaml` (source-verified — the `llm-pi-ai` adapter mounts dormant and is activated there; row `id: llm` is the core registry and is never patched); speed claims replaced with this machine's measurements; worker model is on-demand, not resident; five-config concurrency bench added; Codex's queue policy, Hermes operations plane, and thin Mission Control adopted as late phases.

---

## 1. Executive decision

Install **DeepSeek Harness (`dsh`) pinned at `0.1.0-rc.7`** as the interactive coding cockpit. Keep **OpenCode untouched** as the independent coding UI. One LM Studio server feeds everything.

Model strategy:

- **Brain:** Qwen3.8-27B UD-Q5_K_XL (dense) under the stable identity `qwen/qwen3.8-27b`, 65,536 context — the daily cockpit model. Already loaded and pinned by `Load-OpenCode-Qwen.mjs`.
- **Worker (on demand):** Qwen3 Coder 30B A3B (MoE) as a second LM Studio identity for subagent, workflow, and Ralph fan-out. Measured decode on this machine is near parity (Q5 with MTP ≈ 28.3 tok/s; comparable A3B MoE ≈ 30–37 tok/s), so its value is **swap-free fan-out and turn overlap, not raw speed**. It loads on demand with a TTL and stays only if the Phase 2 bench proves complete-task wall-clock gains worth its footprint.

Permissions by **environment variable, not config patches**: `DSH_PERMISSION_MODE=danger-full-access` flips sandbox to full access and approval to `never` in one move (source-verified). The launcher starts from `C:\`, so the workspace root is the whole drive.

Later, in this order: **Hermes Agent as a bounded operations plane** (cold-session cron, messaging, skill learning — things Harness's session-scoped scheduler cannot do), then a **thin Mission Control page** last. Nothing custom gets built until a shipped extension point fails; 400+ community plugins exist under the `dsh-plugin` GitHub topic — search there first, always.

---

## 2. Why this harness fits HALO — the prefix-cache advantage, scoped

The harness enforces an invariant: **every request is a byte-exact extension of the previous request.** The session log is append-only; compaction, tool-result pruning, and plan-mode are engineered as cache-safe surface replacements; the tool catalog never changes between modes ("for request-cache stability" — their source comments). Their CI fails if cache-read tokens drop to zero. Even the compaction summarizer call is shaped as a prefix-extension of the already-warm request.

Your LM Studio config already runs `contextCheckpoints: 32` on a single slot. Stable prefixes + checkpoints means LM Studio almost never re-processes the prompt.

Scope the claim correctly. Prefix reuse eliminates repeated **prefill** (time-to-first-token on long sessions) and nothing else:

- It does not accelerate decode — decode stays bandwidth-bound.
- Compaction still costs one planned re-prefill (~every 52K tokens).
- A changed prefix still invalidates the cache.
- It does not make two-model concurrency free.

On HALO (~256 GB/s bandwidth vs a 5090's ~1,792 GB/s), repeated prefill is the most punishing cost, so removing it matters more here than on fast hardware. A real fit, not magic. **Phase 2 measures prefill speed and actual cache-hit behavior separately from decode — the argument lives or dies on those numbers.**

```text
Request N   : [system][tools][history........................][new turn]
Request N+1 : [system][tools][history........................][new turn][result][next turn]
              ^———————————— identical bytes = KV-cache hit ————————————^
Compaction  : [system][tools][checkpoint summary][retained tail][new turn]
              (one planned cache bust, ~every 52K tokens, instead of constant ones)
```

---

## 3. System architecture

```text
                                 SCOTT
                                   |
              +--------------------+----------------------+
   INTERACTIVE (now)                          OPERATIONS (Phase 5+)
              |                                          |
              v                                          v
   +--------------------------+            +---------------------------+
   | dsh Web UI 127.0.0.1:3080|            | Hermes gateway (optional) |
   | pinned 0.1.0-rc.7        |            | cold-session cron         |
   | cockpit · full C:\       |            | messaging · skills        |
   +------------+-------------+            | separate profile/home     |
                |                          +-------------+-------------+
   +------------v-------------+                          |
   | OpenCode — untouched     |                          |
   | independent fallback UI  |                          |
   +------------+-------------+                          |
                |                                        |
                +-------------------+--------------------+
                                    v
                     +------------------------------+
                     | Queue policy: interactive    |
                     | turns outrank background     |
                     +--------------+---------------+
                                    v
                     +------------------------------+
                     | LM Studio API 127.0.0.1:1234 |
                     +-------+--------------+-------+
                             |              |
                             v              v
              +-----------------+   +----------------------+
              | Qwen3.8 27B Q5  |   | Qwen3 Coder 30B MoE  |
              | dense BRAIN     |   | ON-DEMAND WORKER     |
              | 65,536 ctx      |   | TTL load, bench-gated|
              +-----------------+   +----------------------+

   dsh capability rows: pwsh(-NoProfile, UTF-8) · fs · jobs · skills ·
   compaction+pruner · subagents (spawn/fork/codex/claude-code/ACP) ·
   workflows · Ralph · MCP -> BrowserMCP + memory · JSONL sessions
   Mission Control (Phase 6): thin read-only status page over all of it
```

---

## 4. Source facts the plan stands on (tag `dsh-v0.1.0-rc.7`)

- **Install:** `npx @deepseek-ai/dsh@0.1.0-rc.7 web` → Web UI at `http://127.0.0.1:3080`. Node ≥22.19. `--host 0.0.0.0` rejected — local only. Home: `C:\Users\scott\.dsh` (profiles, sessions, skills, presets, `settings.yaml`, `.credentials.yaml`, `.env`, home patch).
- **Config layers, later wins:** bundles → profile patch → home `cordis.patch.yml` → `--patch` overlays. **A patch replaces the targeted row's entire config — no merge.** Verify with `dsh web --dump-config` vs `--dump-default-config`.
- **Providers:** the base bundle mounts the `llm-pi-ai` adapter **dormant**; a `llm-pi-ai:` section in `$DSH_HOME\settings.yaml` activates routes — hot-reloaded, no restart, the same surface the web Models page writes. Row `id: llm` is the core LLM registry (`@deepseek-ai/dsh-llm`) — never patched. `compat.thinkingFormat: qwen` exists for Qwen reasoning content. Compaction reads the route's declared `contextWindow`.
- **Permissions:** sandbox row reads `DSH_PERMISSION_MODE` (`read-only | workspace-write | danger-full-access`); approval derives `never` automatically for full access. Workspace root = `process.cwd()`. Runtime switch: `/permission`.
- **Presets:** `standard` (default), `code` (same registry + `run_code`), `minimal`, `cordis` (Creator — presets, not a general dashboard editor). User presets: `.dsh\.agent-presets\`.
- **Compaction at 65,536 ctx:** trigger 80% (52,428), retain 16% (10,485), summary cap 8,192; tool results >8,192 chars pruned first (head 4,096 / tail 1,024); overflow auto-recovers; `/compact` manual.
- **Scheduling is session-scoped** (verified in `dsh-schedule` source): reminder state lives in the session event log, a live root agent is required, fixed-rate floor is five minutes. **No cold-session cron service exists in v1** — this is the fact that earns Hermes its later lane.
- **Subagents:** in-process spawn/fork (model overridable per call), `codex` (`codex app-server --stdio`), `claude-code` (official SDK, native auth), generic ACP client, child-dsh. Workflows + Ralph ship in standard.
- **MCP:** one plugin row per server (stdio/http), tools exposed as `mcp__<server>__<tool>`. **No browser control ships** — BrowserMCP is the right first add.
- **Windows:** `pwsh -NoLogo -NoProfile -NonInteractive`, UTF-8 forced, PS7 first, `taskkill /T /F` tree kill, 64 MiB output spill. Native Win32 paths; no WSL.

---

## 5. Model layer

Verified now (truth source: `lms ps --json`, never the REST catalog):

```text
path:          unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf
quantization:  Q5_K_XL
identifier:    qwen/qwen3.8-27b        <- stable API id, pinned by loader script
contextLength: 65,536   parallel: 1   vision: true   tool-use: trained
loader:        C:\Users\scott\.lmstudio\scripts\Load-OpenCode-Qwen.mjs
```

Q4_K_M stays installed untouched as rollback. OpenCode already points at the same identity — zero OpenCode changes anywhere in this plan.

**Worker reality check (measured, this machine):** Q5 with MTP ≈ 28.3 tok/s; comparable A3B MoE ≈ 30–37 tok/s — a 1.1–1.3× decode difference, not "several times." Active-parameter arithmetic does not predict llama.cpp performance; MTP speculative decoding closes most of the dense penalty (accept rates are content-dependent — high on code, lower on prose — so the bench reports per task type). Two loaded models are two software queues on one iGPU sharing one memory bus: concurrent decoding contends. Co-residency buys **swap-free worker turns and overlap while the brain waits on results** — nothing more until measured. The true second-model footprint includes a second KV cache, compute buffers, the vision projector, and MTP state, and the machine must stay usable for Codex, Claude, browsers, and test environments. Hence: **on-demand TTL load, bench-gated residency.**

| Role | Model | Basis |
|---|---|---|
| Brain — cockpit sessions, review, architecture | Qwen3.8-27B Q5 dense, 65,536 ctx | Best local quality; prefill mostly cached after turn 1 |
| Worker — subagent/workflow/Ralph fan-out | Qwen3 Coder 30B A3B MoE, 32,768 ctx, on demand | Swap-free second queue; decode ≈ parity; bench decides |
| Escalation — hard problems, second opinions | Codex / Claude Code subagents | Existing auth; true concurrency off-box |

---

## 6. Configuration (complete)

### 6.1 Launcher — `Start-DSH.ps1` (desktop shortcut in Phase 4)

```powershell
$env:DSH_PERMISSION_MODE = 'danger-full-access'
node "$env:USERPROFILE\.lmstudio\scripts\Load-OpenCode-Qwen.mjs"   # idempotent Q5 pin
Set-Location C:\                                                    # workspace root = C:\
Start-Process "http://127.0.0.1:3080"
npx "@deepseek-ai/dsh@0.1.0-rc.7" web                               # exact version pin
```

### 6.2 Credential — `C:\Users\scott\.dsh\.env`

```text
LMSTUDIO_API_KEY=lm-studio
```

### 6.3 Provider config — `C:\Users\scott\.dsh\settings.yaml` (not the patch file)

```yaml
llm-pi-ai:
  providers:
    lmstudio:                      # permanent id — sessions embed it, never rename
      displayName: LM Studio (HALO)
      api: openai-completions
      baseURL: http://127.0.0.1:1234/v1
      apiKeyEnv: LMSTUDIO_API_KEY
      compat:
        thinkingFormat: qwen
        supportsReasoningEffort: true
      models:
        - id: qwen/qwen3.8-27b
          name: Qwen3.8 27B Q5 — daily brain
          contextWindow: 65536
          maxTokens: 8192
          input: [text, image]
        - id: qwen3-coder-30b-a3b-instruct
          name: Qwen3 Coder 30B MoE — on-demand worker
          contextWindow: 32768
          maxTokens: 8192
```

### 6.4 Home patch — `C:\Users\scott\.dsh\cordis.patch.yml` (MCP rows only, Phase 3)

New rows are added with `insert`; the replace-not-merge rule only bites when targeting existing ids.

```yaml
- insert:
    - id: mcp-browser
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: browser
        transport: stdio
        command: npx
        args: ['@browsermcp/mcp@latest']
    - id: mcp-memory
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: memory
        transport: stdio
        command: npx
        args: ['-y', '@modelcontextprotocol/server-memory']
```

### 6.5 User preset — `C:\Users\scott\.dsh\.agent-presets\halo-standard\`

Copy of the shipped `standard` preset with the `codex` and `claude-code` subagent rows enabled (they ship disabled). Later home for skills wiring and creator-mode additions. Stock install never modified.

### 6.6 Worker loader — `Load-Worker-Coder.mjs` (Phase 2, if the bench earns it)

Same pattern as the Q5 loader: pins the exact GGUF under a stable identifier, TTL so it unloads when idle, load-config verification with hard mismatch failure.

---

## 7. Routing and queue policy

| Work | Route | Basis |
|---|---|---|
| Daily coding, exploration, edits, tests | Brain (Q5 dense) | Cockpit default |
| Subagent / workflow / Ralph fan-out | Worker (MoE, on demand) | Swap-free second queue; bench-gated |
| Hard architecture, debugging, second opinion | Codex / Claude Code subagent | Existing auth; off-box concurrency |
| Signed-in browser tasks | BrowserMCP tools | Real Chrome profile |
| Cross-session facts | Memory MCP + visible Markdown | Inspectable, portable |
| Requested persistent loops | Ralph | Bounded rounds, explicit ask only |
| Unattended scheduled/messaging work | Hermes ops plane (Phase 5) | Harness scheduler is session-scoped |

**Queue policy** (resource management, adopted from Codex v1):

1. Interactive Harness/OpenCode turns outrank all background local inference.
2. Fixed-time background jobs use cloud/free routes when local coding may be active.
3. Local background inference runs only in idle windows or after a queue check.
4. Auxiliary small tasks (titles, extraction) go to cheaper routes, not the Q5 brain.
5. Every scheduled run records provider, model, start/end, result, failure state.
6. Never fire simultaneous turns at the same model identity from two apps when latency matters; never rename the `lmstudio` provider id or model identifiers (sessions embed them).

---

## 8. Implementation phases

```text
[1] Install & wire -> [2] Baseline + bench -> [3] Reach -> [4] Harden -> [5] Hermes ops -> [6] Mission Control
```

**Phase 1 — Install and wire (one sitting).**
Node 22+ check → confirm `npx @deepseek-ai/dsh@0.1.0-rc.7` still resolves and record the resolved package version + tarball hash beside the config dump (RC tags can move; the hash is the real pin) → pinned install → `.env` credential → `settings.yaml` provider → launcher → verify with `dsh web --dump-config` → smoke test: a fresh session at `C:\` discovers a repo, reads, edits, runs tests, prepares (doesn't push) a commit, **and** reads + edits a scratch file outside that repo — proof the full-drive boundary is what the config says it is. Community `dsh-plugin` packages are third-party code: read before installing any.

**Phase 2 — Baseline and bench.**
First a single-Q5 Standard-mode baseline. Validate real prefix-cache behavior: prefill tok/s and cache hits measured separately from decode. Then five load configurations: Q5 alone · Coder alone · both loaded idle · both generating concurrently · one complete coding task on each. Plus Standard vs Code mode on the winner. Judge on correctness, wall-clock, failed/repeated tool calls, recovery from one induced error, contention, and memory left for the rest of the machine. The worker stays loaded only if complete-task wall-clock justifies its footprint. Data picks every default.

**Phase 3 — Reach.**
BrowserMCP + Chrome extension → navigation, extraction, screenshot, one reversible signed-in action. Memory MCP → store a fact, recall it from a completely fresh session. Enable `halo-standard` preset with Codex/Claude rows → one task each on existing auth. Ten-minute OpenCode ACP probe: wire it only if OpenCode speaks ACP server-side — no custom bridge.

**Phase 4 — Harden.**
Restart + Windows reboot persistence; resume a session across a forced compaction boundary; background job start/kill; both models unload and memory returns; back up `C:\Users\scott\.dsh` to `C:\Users\scott\Documents\Codex\ConfigBackups\`; desktop launcher polish; autostart only after all of it passes.

**Phase 5 — Hermes operations plane (bounded, optional).**
Justified by one verified fact: Harness scheduling is session-scoped — no cold-session cron in v1. Hermes owns only what must run without an open Harness session: durable cron, messaging-channel delivery, background monitoring, procedural skill capture, cross-session operational memory. Separate pinned install, separate profile/home, same LM Studio identity, queue policy enforced, skills validated in a disposable profile before the production one, no autostart until cron persistence and restart behavior are proven. Decision gate at this phase: existing scheduled Claude agents on this machine already cover part of this lane — install Hermes only if the delta (messaging channels, skill learning) is worth a second gateway.

**Phase 6 — Mission Control (thin, last).**
One read-only browser page over native state: Harness/Hermes/OpenCode/LM Studio health, loaded model + quant + context + queue, active sessions, schedules and last/next runs, background jobs, links that open each native surface, and explicit Load Q5 / Load Worker / Unload controls. It duplicates no chat history, no routing, no scheduling. It can fail or be deleted without touching anything underneath.

---

## 9. Acceptance criteria

- Launcher opens the Web UI with no terminal steps; fresh session starts at `C:\` in `danger-full-access` / `never`.
- Brain selected via the stable id reports 65,536 context; vision and tool calls pass end-to-end.
- Standard mode completes the bench task; Code mode becomes default only if it wins.
- Prefill speed and cache-hit rate are measured and recorded; cache-read tokens are non-zero in steady state.
- A session crosses an automatic compaction and continues correctly.
- The five-config concurrency bench is recorded; the worker's residency decision cites its numbers.
- BrowserMCP drives the signed-in Chrome profile; memory recalls a fact in a brand-new session.
- Codex and Claude Code subagent tasks succeed on existing auth.
- OpenCode still works, unchanged, against the same Q5 identity.
- Everything survives app restart and a Windows reboot; models unload cleanly and memory returns.
- If Hermes is installed: scheduled jobs run with Harness closed, record auditable outcomes, survive restart without duplication, and never preempt an active interactive turn.
- Mission Control reports status and launches surfaces without becoming a required dependency.

---

## 10. Rollback

- Q4_K_M untouched; verified Q5 config backup retained.
- Harness pinned at `0.1.0-rc.7`; effective config dump saved beside the backup.
- All local behavior in `settings.yaml`, home patch, and user preset — stock install never modified.
- Deleting `C:\Users\scott\.dsh` removes the harness footprint completely; OpenCode unaffected throughout.
- Hermes (if installed) lives in its own profile/home, backed up independently, disablable without touching Harness.
- Mission Control holds no irreplaceable state; delete and rebuild freely.
- MCP server versions recorded when added.

---

## 11. Appendix — Phase 2 bench results (measured 2026-08-17)

Probe prompt 19.6K tokens; task = two-bug node repo, identical prompt per run, every result verified on disk.

| Metric | Q5 brain | Coder MoE worker |
|---|---|---|
| Fresh prefill | 181 tok/s (TTFT 108.6 s) | 615 tok/s (TTFT 31.8 s) |
| Cached TTFT | 13.4 s (**8.1×**) | 0.28 s (**115×**) |
| Decode solo / concurrent | 26.9 / 19.0 tok/s | 90.9 / 87.8 tok/s |
| Full harness task | 176 s (Standard) | **41 s** (Standard) · 65 s (Code mode) |
| Correctness | 4/4, staged, no commit | 4/4, staged, no commit (both modes) |

**Phase 3 (Reach), completed 2026-08-17:** memory MCP proven across sessions; Codex ✓, Claude Code ✓, OpenCode-via-ACP ✓ all verified live; Web UI cockpit proven end-to-end with `halo-standard` as default preset. Five rc.7 Windows bugs found and worked around (BrowserMCP boot-crash — integration deferred; drive-root workspaces never bind — use a normal directory; blank workspace titles unclickable; npm .ps1 shims need `cmd /c` for ACP; provider plugins are per-profile installs). Reasoning capped at `medium`; MTP sweep confirmed stock n=4 optimal. Full record: `ConfigBackups\DSH-Phase1-20260817-142954\phase3-reach-results.md`.

**Phase 4 (Harden), completed 2026-08-17:** backup taken; job lifecycle proven (kill verified by heartbeat flatline); compaction fails closed on empty sessions and checkpointed 9 items (~15K tokens) on a real session with **continuity proven across the boundary** (codename recalled tools-forbidden); prefix cache confirmed in production shape (TTFT 157 s cold → 13 s cached → 80 s post-compaction); unload returns memory and the launcher cold-start restores the exact pin; server kill + restart preserves sessions and settings; desktop launcher shipped (`Desktop\DeepSeek Harness.lnk`). Outstanding: the physical reboot test (user-timed), then autostart. Record: `ConfigBackups\DSH-Phase1-20260817-142954\phase4-harden-results.md`.

**Phase 6 (Mission Control), completed 2026-08-17 (taken ahead of Phase 5 by owner call):** one Node file at `127.0.0.1:3090` + desktop shortcut — health dots (cockpit/LM Studio/lms CLI), model card from `lms ps --json`, recent sessions, free RAM, memory count, harness pin, five action buttons (start cockpit / load brain / load worker / unload worker / unload all). 5 s refresh, localhost-only, zero state, deletable. **Phase 5 (Hermes) parked** — occasional remote need already covered by cloud-agent phone apps; revisit when messaging channels earn a second gateway. Post-reboot field fixes: launcher re-sequenced server-before-browser; OpenCode autostart removed; Chrome auto-translate disabled for the cockpit (it rewrote live DOM and broke streaming). **Web search wired (2026-08-17 evening):** keyless Exa public MCP (`https://mcp.exa.ai/mcp`) gives every session live search + read-any-URL-as-markdown — no account, ~150 calls/day; validated live (found Node v26.7.0 with cross-corroborated sources). The unkeyed built-in DeepSeek search backend and `tool-web` row are disabled. Self-hosted SearXNG evaluated as the uncapped sovereign alternative and parked by owner decision (recorded in the user manual).

**Telemetry audit (2026-08-17):** all 199 installed DeepSeek packages swept (code + config), telemetry subsystem source-read, live sockets inspected. Clean: Qwen GGUFs are inert weights (no Qwen code executes; LM Studio is the runtime); the harness's single telemetry exporter (default target `harness-telemetry.deepseeksvc.com`) ships **DISABLED** and its disabled path constructs no SDK at all; enable env vars unset; zero third-party analytics; live processes connect only to localhost LM Studio. `/delta-scan-halo` guards telemetry defaults on every future release. Full evidence: `halo-stack/docs/AUDIT-telemetry-2026-08-17.md`.

**Verdicts now locked into the defaults:** Q5 dense + Standard mode stays the cockpit (best reporting; prefill pain neutralized by the cache — 108.6 s → 13.4 s). The Coder MoE **wins the fan-out role at 4.3× wall-clock** and runs on demand with a 2 h TTL (`Load-Worker-Coder.mjs`; ~16 GB returns on idle). Code mode lost (65 vs 41 s) and is not default. The prefix-cache architecture is validated against LM Studio with hard numbers. Pre-bench "≈ parity" decode estimates did not survive measurement.

---

## 12. References

- Harness product page: https://deepseek.com/harness/en/
- Repository: https://github.com/deepseek-ai/deepseek-harness (tag `dsh-v0.1.0-rc.7`)
- Docs: https://deepseek-harness.github.io/deepseek-harness/en/guide/quickstart
- Reviewed clone: `C:\Users\scott\Documents\Codex\2026-08-16\i-j\deepseek-harness-review`
- Community plugins: GitHub topic `dsh-plugin`
- BrowserMCP: https://github.com/BrowserMCP/mcp
- Hermes Agent: https://github.com/NousResearch/hermes-agent · https://hermes-agent.nousresearch.com/docs/
- Predecessor documents: Codex v1 (`Local LLM\Codex-Harness-Halo v1.md`), Claude v1 (`Local LLM\Claude-Harness-HALO-Design.md`), Grok cross-review (chat)
- ResonantOS reference: https://resonantos.com/
