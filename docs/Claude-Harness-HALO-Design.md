# Local AI System Design — Claude Plan

**DeepSeek Harness + LM Studio two-model routing + OpenCode on Windows 11 / AMD Strix Halo (HALO)**
**Design date:** August 17, 2026
**Author:** Claude (Fable 5), from a source-level dive of `dsh-v0.1.0-rc.7` (three parallel subagent sweeps: kernel/config, agent runtime, integrations)
**Status:** Proposed. Model layer verified live (`lms ps --json`). Harness not yet installed.

---

## 1. Executive decision

Install **DeepSeek Harness (`dsh`) pinned at `0.1.0-rc.7`** as the local-agent cockpit. Keep **OpenCode** untouched as the independent coding UI. Both share the one LM Studio server.

Run **two local models, not one**:

- **Brain:** Qwen3.8-27B UD-Q5_K_XL (dense) under the stable identity `qwen/qwen3.8-27b` — the daily cockpit model. Already loaded and pinned by `Load-OpenCode-Qwen.mjs`.
- **Worker:** Qwen3 Coder 30B A3B (MoE) as a second, **on-demand** LM Studio identity — subagent, workflow, and Ralph fan-out. Measured decode on this machine is near parity (Q5 with MTP ≈ 28.3 tok/s; comparable A3B MoE ≈ 30–37 tok/s), so the worker's value is swap-free fan-out and turn overlap, not raw speed. The Phase 2 bench decides whether it earns residency.

Set permissions by **environment variable, not config patches**: `DSH_PERMISSION_MODE=danger-full-access` flips sandbox to full access and approval to `never` in one move (source-verified in the base bundle). Workspace root follows the launch directory, so the launcher starts from `C:\`.

Do not build any custom harness, browser framework, or plugin until a shipped extension point fails. 400+ community plugins exist under the `dsh-plugin` GitHub topic — search there first, always.

---

## 2. Why this harness fits HALO — the prefix-cache insight

This is the load-bearing finding from the source dive, and the reason the "38 million tokens, still going strong" claim in the reference video is believable.

The harness enforces an invariant: **every request is a byte-exact extension of the previous request.** The session log is append-only; compaction, tool-result pruning, and even plan-mode are engineered as cache-safe surface replacements. The tool catalog never changes between modes ("for request-cache stability" — their words, in source). Their CI fails if cache-read tokens drop to zero. Even the compaction summarizer call is shaped as a prefix-extension of the already-warm request, so the provider reuses cached tokens instead of re-processing the shadowed history.

Your LM Studio load config already runs `contextCheckpoints: 32` on a single slot. Stable prefixes + context checkpoints means **LM Studio almost never re-processes the prompt**. Scope the claim correctly: prefix reuse eliminates repeated prefill (time-to-first-token on long sessions) and nothing else — decode stays bandwidth-bound, compaction still costs one planned re-prefill, and a changed prefix still invalidates the cache. On HALO (~256 GB/s vs a 5090's ~1,792 GB/s) repeated prefill is the most punishing cost, so removing it matters more here than on fast hardware. A real fit, not magic.

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
                  +----------------+-----------------+
                  |                                  |
                  v                                  v
      +--------------------------+       +--------------------------+
      | dsh Web UI  (127.0.0.1:  |       | OpenCode                 |
      | 3080) — cockpit          |       | untouched, independent   |
      | pinned 0.1.0-rc.7        |       | fallback UI              |
      +------------+-------------+       +------------+-------------+
                   |                                  |
                   +----------------+-----------------+
                                    v
                     +------------------------------+
                     | LM Studio API                |
                     | 127.0.0.1:1234/v1            |
                     +-------+--------------+-------+
                             |              |
                             v              v
              +-----------------+   +----------------------+
              | Qwen3.8 27B Q5  |   | Qwen3 Coder 30B MoE  |
              | dense BRAIN     |   | fast WORKER          |
              | 65,536 ctx      |   | 32,768 ctx           |
              | main sessions   |   | subagents/workflows  |
              +-----------------+   +----------------------+

     dsh capability rows (all plugins in one entry tree)
     --------------------------------------------------
       | pwsh -NoLogo -NoProfile -NonInteractive, UTF-8 forced
       | fs / fs-search / jobs / skills / goal / plan / todo
       | compaction-basic + tool-result pruner + /compact
       | subagents: spawn, fork, codex, claude-code, ACP, child dsh
       | workflows + Ralph loop
       | MCP rows -> BrowserMCP (signed-in Chrome), memory server
       | sessions: append-only JSONL at C:\Users\scott\.dsh\sessions
```

---

## 4. What the source dive established (facts, with meaning)

### 4.1 Install and layout

- Install/run: `npx @deepseek-ai/dsh@0.1.0-rc.7 web` — CLI package `@deepseek-ai/dsh`, binary `dsh`, Web UI at `http://127.0.0.1:3080`. Node `^22.19 || >=24` required. `--host 0.0.0.0` is deliberately rejected; local-only.
- Harness home: `$DSH_HOME`, default `C:\Users\scott\.dsh`. Everything lives under it: `profiles/`, `sessions/`, `skills/`, `.agent-presets/`, `settings.yaml`, `.credentials.yaml`, `.env`, and the home patch `cordis.patch.yml`.
- Config layers, later wins: **bundle patches → profile `cordis.patch.yml` → home `cordis.patch.yml` → `--patch` overlays**.
- **A patch replaces the targeted row's entire `config`. It does not merge.** Any override must restate every field it keeps. Verify with `dsh web --dump-config` (shows provenance comments) against `dsh web --dump-default-config`.

### 4.2 Permissions

- Base bundle: sandbox row reads `DSH_PERMISSION_MODE` (values `read-only | workspace-write | danger-full-access`); approval row derives `never` automatically when the mode is `danger-full-access`. Workspace root defaults to `process.cwd()`.
- So: **no config rows are patched for permissions.** The launcher sets the env var and starts in `C:\`. Runtime switch per session: `/permission danger-full-access`.

### 4.3 Presets

Four ship: **standard** (default; full tool set), **code** (same registry + `run_code` TypeScript presentation), **minimal** (persistent PTY + editor only), **cordis** (Creator mode — the agent can edit compositions; shell-equivalent trust). User presets live in `C:\Users\scott\.dsh\.agent-presets\` — the supported way to enable the shipped-but-disabled Codex and Claude Code subagent rows without forking.

### 4.4 Compaction (ship the defaults)

At 65,536 context: trigger at 80% (**52,428 tokens**), retain 16% verbatim tail (**10,485**), summarizer output cap **8,192**. Oversized tool results pruned first (threshold 8,192 chars → head 4,096 + tail 1,024). Overflow errors trigger prune+compact+retry automatically. `/compact` for manual. Nothing to tune until real sessions prove otherwise.

### 4.5 Model providers

- Generic route: `@deepseek-ai/dsh-llm-pi-ai`, `api: openai-completions`, per-model `contextWindow`/`maxTokens`/`input`, credentials by env-var reference (`apiKeyEnv`) resolved from process env → `.credentials.yaml` → cwd `.env` → `$DSH_HOME\.env`.
- **`compat.thinkingFormat: qwen` exists in source** — a dedicated Qwen reasoning-content dialect. Set it on the LM Studio route.
- Compaction learns the context budget from the route's declared `contextWindow` — declaring 65,536 keeps its math exact.

### 4.6 Subagents and fan-out

Shipped providers: in-process **spawn** and **fork** (inherit parent model unless overridden), **codex** (`codex app-server --stdio`), **claude-code** (official Agent SDK, uses native Claude settings), generic **ACP** client (spawns any ACP-speaking command — the 10-minute OpenCode integration test), and **child dsh**. Workflows (JS orchestration over agent fan-out) and the Ralph loop (fresh worker per round, explicit-ask only, bounded handoffs) ship in the standard preset.

### 4.7 MCP and browser

One plugin row per MCP server (`stdio` or `streamable-http`), tools exposed as `mcp__<server>__<tool>`. **No browser control ships at all** (Playwright in the repo is test-only) — BrowserMCP against your signed-in Chrome is the right first add, exactly as the Codex paper argued.

### 4.8 Windows execution

PowerShell invoked as `pwsh -NoLogo -NoProfile -NonInteractive -Command` with UTF-8 forced; PS7 resolved first. Tree kill via `taskkill /T /F`. Shell timeout default 120 s (cap 600 s), output 64 KB in memory with 64 MiB spill files. Native Win32 paths end to end; no WSL anywhere.

---

## 5. Model layer

### 5.1 Verified now (truth source: `lms ps --json`, never the REST catalog)

```text
path:          unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf
quantization:  Q5_K_XL
identifier:    qwen/qwen3.8-27b        <- stable API id, pinned by loader script
contextLength: 65,536   parallel: 1   vision: true   tool-use: trained
loader:        C:\Users\scott\.lmstudio\scripts\Load-OpenCode-Qwen.mjs
```

Q4_K_M remains installed untouched as rollback. OpenCode already points at the same identity — zero OpenCode changes in this plan.

### 5.2 The two-model design (main break from the Codex paper)

| Role | Model | Why |
|---|---|---|
| Brain — cockpit sessions, architecture, review | Qwen3.8-27B Q5 dense, 65,536 ctx | Best local quality; prefix-cache makes its slow prefill mostly a one-time cost |
| Worker — subagents, workflows, Ralph rounds | Qwen3 Coder 30B A3B MoE, 32,768 ctx | Swap-free fan-out on a second queue; measured decode ≈ parity with Q5+MTP — bench decides; tool-trained coder |
| Escalation — hard debugging, second opinion | Codex / Claude Code subagent rows | Existing auth; true concurrency without touching the local slots |

Two loaded models are two software queues on one iGPU — they share the same memory bandwidth, and concurrent decoding contends. What co-residency buys is swap-free worker turns and overlap while the brain waits on results, not doubled throughput. The worker loads **on demand** through a pinned loader (`Load-Worker-Coder.mjs`, same pattern as the Q5 loader, TTL-based, unloads when idle). The true footprint is more than weights: two KV caches, compute buffers, the vision projector, and MTP state. The Phase 2 bench measures all of it and decides whether the worker earns its memory; the machine must stay usable for everything else.

---

## 6. Configuration (complete)

### 6.1 Launcher — `Start-DSH.ps1` (desktop shortcut later)

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

Source-verified correction: the base bundle mounts the `llm-pi-ai` adapter **dormant**, and its comments name `settings.yaml` as the surface that activates provider routes — hot-reloaded, no restart, the same file the web Models page writes. The row `id: llm` is the core LLM registry (`@deepseek-ai/dsh-llm`) and is never patched.

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

New rows are added with `insert` (patch-replaces-row semantics only bite when targeting existing ids).

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

Copy of the shipped `standard` preset with the `codex` and `claude-code` subagent rows enabled (they ship disabled). Later home for skills wiring and creator-mode additions. No source forked.

---

## 7. Routing policy

| Work | Route | Notes |
|---|---|---|
| Daily coding, exploration, edits, tests | Brain (Q5 dense) | Cockpit default |
| Subagent/workflow/Ralph grunt work | Worker (MoE coder) | Model override on spawn |
| Fast mechanical sweeps when brain is busy | Worker (MoE coder) | Second queue, no waiting |
| Hard architecture / debugging / review | Codex or Claude Code subagent | Existing auth, true concurrency |
| Signed-in browser tasks | BrowserMCP tools | Real Chrome profile |
| Cross-session facts | Memory MCP + visible Markdown files | Inspectable, portable |
| Requested persistent loops | Ralph | Explicit ask only, bounded rounds |

Rules: never rename the `lmstudio` provider id or model identifiers (sessions embed them). Keep `parallel: 1` per model. Don't fire simultaneous turns at the same model from both apps when latency matters.

---

## 8. Implementation phases

```text
[1] Install & wire  ->  [2] Bench day  ->  [3] Reach  ->  [4] Harden
```

**Phase 1 — Install and wire (one sitting).**
Node 22+ check → pinned install → `.env` credential → home patch → launcher → `dsh web --dump-config` verification → smoke test: a fresh session at `C:\` discovers a repo, reads, edits, runs tests, prepares (doesn't push) a commit.

**Phase 2 — Bench day.**
First a single-Q5 Standard-mode baseline, and validate real prefix-cache behavior (measure prefill tok/s and cache hits separately from decode — the cache argument lives or dies on prefill numbers). Then five load configurations: Q5 alone · Coder alone · both loaded idle · both generating concurrently · one complete coding task on each. Plus {Standard vs Code mode} on the winner. Judge on correctness, wall-clock, failed/repeated tool calls, recovery from one induced error, contention, and memory left for the rest of the machine. Data — not the reference videos — picks the defaults; the worker stays loaded only if complete-task wall-clock justifies its footprint.

**Phase 3 — Reach.**
BrowserMCP + Chrome extension → validate navigation, extraction, screenshot, one reversible signed-in action. Memory MCP → store a fact, recall it from a completely fresh session. Enable `halo-standard` preset with Codex/Claude rows → one task each on existing auth. Ten-minute OpenCode ACP probe: if OpenCode speaks ACP server-side, wire it as a subagent; if not, drop the idea (no custom bridge).

**Phase 4 — Harden.**
Restart + Windows reboot persistence; resume a session across a forced compaction boundary; background job start/kill; verify both models unload and memory returns; back up `C:\Users\scott\.dsh` to `C:\Users\scott\Documents\Codex\ConfigBackups\`; then desktop launcher polish, autostart, and a creator-mode mission-control panel (tasks + fleet view) as the first Creator experiment.

---

## 9. Acceptance criteria

- Launcher opens the Web UI with no terminal steps; fresh session starts at `C:\` in `danger-full-access`/`never`.
- Brain selected via stable id reports 65,536 context; vision and tool calls work end-to-end.
- Standard mode completes the bench task; Code mode becomes default only if it wins the bench.
- A session crosses at least one automatic compaction and continues the task correctly.
- Cache-hit rate is visibly non-zero after the first turns (prefix invariant holding against LM Studio).
- Worker model serves a subagent turn while the brain is mid-turn (two-queue proof).
- BrowserMCP drives the signed-in Chrome; memory recalls across a fresh session.
- Codex and Claude Code subagent tasks succeed with existing auth.
- OpenCode still works, unchanged, against the same Q5 identity.
- Everything survives app restart and a Windows reboot; models unload cleanly.

---

## 10. Rollback

- Q4_K_M stays installed and untouched; the verified Q5 config backup stays where it is.
- Harness pinned at `0.1.0-rc.7`; effective config dump saved beside the backup.
- All local behavior in home patch + user preset — the stock install is never modified.
- OpenCode functional through every phase; deleting `C:\Users\scott\.dsh` fully removes the harness footprint.
- MCP server versions recorded when added.

---

## 11. References

- Harness product page: https://deepseek.com/harness/en/
- Repository: https://github.com/deepseek-ai/deepseek-harness (tag `dsh-v0.1.0-rc.7`)
- Docs: https://deepseek-harness.github.io/deepseek-harness/en/guide/quickstart
- Reviewed clone: `C:\Users\scott\Documents\Codex\2026-08-16\i-j\deepseek-harness-review`
- Community plugins: GitHub topic `dsh-plugin`
- BrowserMCP: https://github.com/BrowserMCP/mcp
- Codex predecessor design: `C:\Users\scott\Desktop\DeepSeek-Harness-OpenCode-Local-AI-Design.md`
- ResonantOS reference: https://resonantos.com/
