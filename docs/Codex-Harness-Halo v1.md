# Local AI Coding System Design

**DeepSeek Harness + OpenCode + LM Studio + Qwen3.8-27B on Windows 11 / AMD Strix Halo**  
**Design date:** August 17, 2026  
**Status:** Revised architecture after source-level review of DeepSeek Harness and official Hermes Agent documentation, incorporating `transcript2.txt`. Q5 model installation and the OpenCode default switch are complete. Harness, Hermes, browser and memory integrations have not yet been implemented.

---

## 1. Executive decision

Use **DeepSeek Harness Web UI** as the prospective primary interactive coding cockpit, while preserving **OpenCode Desktop** as an independent coding interface and cloud-model fallback. Both connect to one tuned **LM Studio** inference service. The local daily model is **Unsloth Qwen3.8-27B UD-Q5_K_XL** at a 65,536-token context. The existing Q4_K_M model remains installed as the fast rollback option.

Add **Hermes Agent** later as a separate optional **operations plane**: persistent scheduled jobs, messaging channels, procedural skill learning, cross-session memory and background automations. Hermes should not replace Harness for repository coding or become a third always-open chat application. Its value is doing unattended operational work that Harness's session-local scheduler cannot do.

Do not build a replacement harness. DeepSeek Harness already supplies the orchestration layer described in the reference transcript: native Windows shell and filesystem tools, background jobs, subagents, workflows, automatic compaction, session replay, skills, and MCP integration. Add browser control and cross-session memory through existing MCP servers before considering custom plugins.

Start Qwen in Harness **Standard mode**. Benchmark Harness Code mode later; do not assume that model-written TypeScript orchestration will outperform ordinary tool calls until it is measured on this machine. Add Hermes only after the Harness baseline is stable, then expose both through one lightweight mission-control page rather than forcing Scott to juggle interfaces.

---

## 2. System architecture drawing

```text
                                   SCOTT
                                     |
                          +----------+----------+
                          | Mission Control Web |
                          | status, queues, logs|
                          +----+-----------+----+
                               |           |
                  interactive  |           | operations
                               v           v
             +----------------------+   +----------------------+
             | DeepSeek Harness Web |   | Hermes Agent Service |
             | primary coding agent |   | schedules / channels |
             +----------+-----------+   | memory / learned skill|
                        |               +----------+-----------+
                        |                          |
             +----------v-----------+              |
             | OpenCode Desktop     |              |
             | alternate coding UI  |              |
             +----------+-----------+              |
                        |                          |
                        +------------+-------------+
                                     v
                       +----------------------------+
                       | Model Router / Queue Policy|
                       | one local turn at a time   |
                       +-------------+--------------+
                                     |
                       +-------------v--------------+
                       | LM Studio OpenAI API       |
                       | 127.0.0.1:1234/v1          |
                       +-------------+--------------+
                                     |
                   +-----------------+-----------------+
                   v                                   v
        +------------------------+          +------------------------+
        | Qwen Q5_K_XL daily     |          | Qwen Q4_K_M fallback  |
        | quality / coding       |          | speed / rollback       |
        +------------------------+          +------------------------+

   Shared capabilities
   -------------------
     - Native PowerShell, filesystem, Git and tests across C:\
     - BrowserMCP controlling the existing signed-in Chrome profile
     - Harness session log/compaction plus Hermes operational memory/skills
     - Codex, Claude, ACP and cloud model routes
     - Explicit receipts, service health, queue state and job history
```

---

## 3. Findings from the DeepSeek Harness source review

The design is based on a direct review of the official DeepSeek Harness repository, including its architecture, production profile composition, Windows PowerShell provider, filesystem and shell permission layers, Standard and Code agent presets, compaction subsystem, MCP client, subagent implementations, workflow engine, Ralph loop, jobs, and OpenAI-compatible LLM provider.

### 3.1 Composition

Harness builds an effective configuration from ordered bundles, a profile patch, a home patch, and an optional overlay. Everything is represented as a plugin, service, or event. A user-specific installation can therefore remain an overlay on the official product instead of a fork.

An important operational detail is that a patch targeting a row replaces that row's entire `config`; it is not a recursive merge. Configuration changes must therefore be generated from the effective profile and validated with Harness's config dump.

### 3.2 Standard mode already provides a complete coding agent

The shipped Standard preset includes:

- Native PowerShell on Windows
- Filesystem read, write, edit and search tools
- Managed foreground and background processes
- Background job output, listing and termination
- Skills and skill discovery
- Goal and planning tools
- Automatic compaction and `/compact`
- Deterministic pruning of oversized tool results
- Spawned and forked subagents
- Workflow execution
- Ralph-style iterative worker loops
- User questions and task tracking
- Web-search integration

This is the correct initial Qwen profile because every tool action is explicit and independently observable.

### 3.3 Code mode is an optimization experiment, not the starting default

Code mode presents tools through a generated TypeScript SDK and lets the model batch several operations into one `run_code` turn. This may reduce inference round trips. Its worker runtime uses a fresh Node worker per invocation, a 512 MB heap cap, a 60-second compute default, a 600-second wall cap, and a 64 MiB output cap.

It is containment, not a security boundary. Large intermediate values can still consume memory, and operating-system processes spawned by model code can survive worker termination. Code mode should become the default only if Qwen Q5 consistently writes and repairs its orchestration code and improves end-to-end task time.

### 3.4 Native Windows execution

Harness selects PowerShell on Windows and invokes it without a profile. Native Win32 paths pass through unchanged; WSL is not required. Shell jobs have managed process trees, timeouts, background execution and output spilling.

### 3.5 Full-drive permission model

The persistent Harness configuration will use:

- Workspace: `C:\`
- Permission mode: `danger-full-access`
- Approval policy: `never`
- Native Windows PowerShell
- Network and process execution enabled

In this mode Harness does not impose workspace-only filesystem or shell confinement. The running agent has the capabilities of the signed-in Windows account across `C:\`. Remaining limits are Windows ACLs, UAC/elevation, locked files, and provider-enforced limits. Existing sessions pin their permission state when created, so new sessions must be created after changing the default.

---

## 4. LM Studio and model layer

### 4.1 Stable API contract

Both applications use the same server:

- Base URL: `http://127.0.0.1:1234/v1`
- Stable API model ID: `qwen/qwen3.8-27b`
- Context: `65,536`
- Normal output ceiling: `8,192`
- Parallel slots: `1`

Harness should receive a permanent provider ID such as `lmstudio`. Saved sessions embed provider identity, so it should not be renamed casually. Harness's OpenAI-compatible provider expects an Authorization value even when a local server does not validate it; a harmless placeholder such as `LMSTUDIO_API_KEY=lm-studio` should be stored through Harness's credential mechanism.

### 4.2 Current Q5 implementation status

The model layer is already complete and validated:

- Installed exact Unsloth `Qwen3.8-27B-UD-Q5_K_XL.gguf`
- Model size: 20,218,178,624 bytes
- SHA-256: `176A6A3F034E9CDC447C10CD00329FC9B31002E6589B9295F2AD4F1EEFE0F6AB`
- Matching F16 vision projector installed
- Q4_K_M remains installed and untouched
- LM Studio reports Q5_K_XL, vision enabled, context 65,536 and parallel 1
- Persistent API identity remains `qwen/qwen3.8-27b`
- OpenCode display name is `Qwen3.8 27B UD-Q5_K_XL — Local Daily Driver`
- Direct tool-call smoke test succeeded
- End-to-end OpenCode test returned `Q5-READY`

Persistent load settings:

- Full/max GPU offload with strict VRAM cap
- Flash Attention enabled
- Unified GPU F16 KV cache
- Batch 2,048 / micro-batch 512
- Context checkpoints 32
- MTP draft depth 4, probability floor 0.5
- Memory mapping disabled
- Keep-model-in-memory disabled so it can be unloaded cleanly

Configuration backup: `C:\Users\scott\Documents\Codex\ConfigBackups\Qwen-Q5-20260817-124847`

---

## 5. Context and compaction design

Harness's native compaction is better grounded than a manually selected reserve:

- Automatic compaction near 80% of the route's actual context
- Approximately 16% retained after compaction
- Summary allowance up to 8,192 tokens
- Oversized tool outputs pruned before summarization
- Stable prefix replayed to improve provider KV-cache reuse
- Old history replaced with a checkpoint instead of duplicated
- Retry after an overflow is supported

At a 65,536-token context, compaction begins around 52,428 tokens and preserves roughly 10,485 tokens. Leave these defaults unchanged during the baseline. Add a separate 131K profile only if real work demonstrates a recurring need; do not burden every ordinary coding turn with maximum theoretical context.

The transcript's very large cumulative token counts represent tokens processed over many compaction cycles, not one simultaneously resident context window.

---

## 6. Browser agent design

DeepSeek Harness does not ship a production interactive browser controller. Playwright in its repository is used to test the Harness Web UI. Its Web UI does not implicitly pass a page DOM or screenshot to the model. The transcript's Augmentor-style browser worker was therefore an additional integration.

### Recommended order

1. **BrowserMCP first.** It controls the existing Chrome profile locally and preserves signed-in sessions. This best matches work involving YouTube, authenticated dashboards, comments, admin screens, research tabs, and the user's real browser state.
2. **Browser Use/browser-harness second.** Use it for longer self-healing tasks, isolated browsers, repeatable automation or situations where BrowserMCP is insufficient.
3. **Custom Harness plugin only after a demonstrated MCP limitation.** Do not create a parallel browser framework preemptively.

### Browser flow drawing

```text
Harness agent
     |
     | MCP tool call
     v
BrowserMCP server + Chrome extension
     |
     v
Existing Chrome profile
  - signed-in accounts
  - real cookies/session
  - tabs and browser fingerprint
     |
     v
Structured result + screenshot returned to Harness
```

The browser integration should be tested with navigation, page inspection, screenshot capture, structured extraction, and one reversible authenticated action before it is considered complete.

---

## 7. Subagents and model routing

Harness supports in-process subagents, an external Codex provider, an external Claude Code provider, generic ACP agents, and full child Harness processes.

### Initial routing policy

| Work type | Preferred worker |
|---|---|
| Normal repository coding, exploration, edits and tests | Local Qwen Q5 |
| Fast mechanical operations | Local Qwen Q4 fallback |
| Hard architecture, debugging or independent review | Codex or Claude |
| Browser interaction | BrowserMCP worker |
| Large explicit parallel fan-out | Harness workflow with cloud workers |
| Persistent iterative task requested by Scott | Ralph loop with explicit completion condition |

OpenCode delegation should use Harness's ACP provider if the installed OpenCode version exposes a compatible ACP endpoint. The official Harness source contains no ready-made OpenCode subagent adapter. ACP support must be verified before writing a custom bridge.

LM Studio has one inference slot. Multiple local Qwen agents will queue rather than truly run concurrently, so local fan-out should be sequential or limited to one active model turn. Cloud agents can work concurrently without competing for the local inference slot.

Workflows should be used for explicit multi-item fan-out. Ralph should be used only for a requested persistent loop with a concrete completion condition; it is not an independent quality evaluator.

---

## 8. Memory and research archive

Harness's append-only session log already provides resume, fork, replay and search inside saved sessions. Cross-session memory should be added through one existing MCP memory server.

Recommended rollout:

1. Start with MCP Reference Memory for simple local persistent facts.
2. Evaluate Memorix if richer retrieval and heuristic memory creation are needed.
3. Save substantive research, evidence, plans and decisions as visible Markdown or JSONL files in an ordinary user directory.
4. Add embeddings only after there is enough material for semantic search to improve actual retrieval.

This keeps important knowledge inspectable and portable instead of hiding it exclusively in an opaque database.

---

## 9. Transcript 2 reassessment and Hermes operations plane

`transcript2.txt` compares DeepSeek Harness with Nous Research's Hermes Agent. The useful conclusion is not that one replaces the other. Their strongest capabilities occupy different lanes.

### 9.1 Claims retained, corrected or rejected

| Transcript claim | Design judgment |
|---|---|
| DeepSeek is plugin-composed and highly moldable | Confirmed by the Cordis composition and official Harness source. Preserve customization as overlays/presets instead of forking core. |
| Creator mode can customize Harness | Partly confirmed. Creator mode drafts custom **agent presets**. It is not, by itself, a general no-code editor for arbitrary production dashboard widgets. UI work still uses Harness client plugins or a separate web surface. |
| DeepSeek can schedule recurring work | Partly confirmed. The shipped schedule package supports delayed, absolute and fixed-rate reminders, but delivery is **session-local**. The original session must be live; there is no cold-session service, external notification delivery or calendar/cron expression in v1. |
| Hermes learns through memory and reusable skills | Confirmed by official Hermes source and documentation. This is its strongest differentiator and warrants a bounded operations role. |
| Hermes supports messaging and scheduled automation | Confirmed. Its long-running gateway supports numerous messaging platforms and first-class cron delivery. |
| DeepSeek is always faster and more reliable | Anecdotal. Speed depends on the selected model, prompt size, tools and workload. Decide with on-box end-to-end benchmarks. |
| Running both is best | Accepted only with lane separation. Do not run two agents against the same task or the single local inference slot without an explicit reason. |
| GitHub star counts prove product maturity | Rejected as an architectural signal. Version pinning, source inspection, tests and restart behavior matter more. |

### 9.2 Hermes's bounded responsibility

Hermes should own work that must continue without an open Harness session:

- Durable cron and scheduled agent jobs
- Delivery to selected messaging channels
- Background research or monitoring
- Procedural skill capture and controlled skill improvement
- Cross-session operational memory and user/profile context
- Optional remote access to operational agents

DeepSeek Harness should continue to own:

- Interactive repository exploration and coding
- Full-drive Windows shell and filesystem work
- Tests, Git and build/debug loops
- Visible plans, tool traces, compaction and session forks
- Subagent orchestration during an active development task

OpenCode remains an independent coding UI and a convenient route to its cloud model catalog. It is not subordinated to Hermes unless a future tested integration proves useful.

### 9.3 Shared LM Studio policy

Hermes can connect natively to LM Studio through its OpenAI-compatible custom/LM Studio provider at `http://127.0.0.1:1234/v1`. It should use the same stable API model identity and 65,536-token declaration.

However, LM Studio has one active inference slot. The operations plane therefore needs a queue policy:

1. Interactive Harness or OpenCode work has priority over background local inference.
2. Hermes scheduled work uses cloud/free routes when it must run at a fixed time while local coding may be active.
3. Local Hermes jobs run only during configured idle windows or after an explicit queue check.
4. Auxiliary tasks such as titles, compression or lightweight extraction may use smaller/cheaper routes rather than consuming Qwen Q5.
5. Every scheduled run records provider, model, start/end time, result and failure state.

### 9.4 Mission-control surface

The transcript's strongest interface idea is one browser page that makes the system legible. Build this only after the underlying services work independently.

The first version should be a thin control and observability layer, not another agent framework. It should show:

- Harness, Hermes, OpenCode and LM Studio health
- Loaded model, quantization, context, queue and memory status
- Active and recent Harness sessions
- Hermes schedules, last run, next run and delivery target
- Background jobs and subagents
- Links that open each native interface
- BrowserMCP connection state
- Recent failures and a plain-language diagnostic
- Explicit Load Q5, Load Q4 and Unload Model controls

It should not duplicate chat history databases, model routing logic, schedulers or permissions. Those remain owned by their respective systems.

### 9.5 Revised two-plane drawing

```text
                     +-----------------------+
                     | Mission Control       |
                     | observe + launch      |
                     +-----+------------+----+
                           |            |
         INTERACTIVE PLANE |            | OPERATIONS PLANE
                           v            v
             +-------------------+   +-------------------+
             | DeepSeek Harness  |   | Hermes Gateway    |
             | coding / tests    |   | cron / messaging  |
             | active-session    |   | memory / skills   |
             +---------+---------+   +---------+---------+
                       |                       |
             +---------v---------+             |
             | OpenCode Desktop  |             |
             | alternate UI      |             |
             +---------+---------+             |
                       +------------+----------+
                                    v
                         +-------------------+
                         | Local queue policy|
                         +---------+---------+
                                   v
                         +-------------------+
                         | LM Studio / Qwen  |
                         +-------------------+

 BrowserMCP, cloud specialists and filesystem services are shared capability
 providers. Each plane keeps its own sessions, logs and native responsibility.
```

## 10. Resource and concurrency rules

- Retain the current 64 GB system / 64 GB VGM split.
- Run one loaded Qwen model and share it between Harness and OpenCode.
- Do not submit simultaneous Qwen turns from both applications when low latency matters.
- Keep `parallel: 1` for single-agent response time and cache reuse.
- Q5 is the daily quality profile; Q4 is the speed/rollback profile.
- Keep the model unloadable so other local AI systems and Windows workloads can reclaim memory.
- Do not autostart Harness until its baseline and restart tests pass.
- Avoid running multiple browser-agent instances unless the task genuinely benefits; Chrome itself can consume substantial memory.
- Do not autostart Hermes until its local-model queue, cron persistence, restart behavior and unload behavior are validated.
- A running Hermes gateway does not automatically receive permission to monopolize Qwen; interactive coding has local inference priority.
- Mission Control should poll lightweight health endpoints and logs, not keep extra model sessions alive.

---

## 11. Implementation sequence

```text
[1] Pin and install Harness
          |
[2] Configure C:\ + danger-full-access + never-ask
          |
[3] Connect LM Studio Q5 and validate full coding
          |
[4] Benchmark Standard mode against Code mode
          |
[5] Add BrowserMCP and validate signed-in Chrome
          |
[6] Add persistent memory MCP and fresh-session recall test
          |
[7] Enable Codex / Claude subagents; test OpenCode ACP
          |
[8] Install Hermes as a separate operations profile; validate cron/memory
          |
[9] Endurance, restart, cleanup and rollback audit
          |
[10] Add thin Mission Control page and desktop launchers
```

### Phase 1 — Harness foundation

- Install a pinned Harness release into a versioned home directory.
- Preserve the stock installation and place all local behavior in a home patch or overlay.
- Configure the Web UI and a stable desktop launcher.
- Configure `C:\`, `danger-full-access`, `never`, native PowerShell and network/process execution.
- Dump and validate the effective configuration.

### Phase 2 — Local model integration

- Add permanent `lmstudio` provider route.
- Store placeholder local API credential correctly.
- Match context and output limits exactly.
- Validate text, vision, tool calling, edits, PowerShell, tests, Git and GitHub access.
- Verify that a new session inherits full access.

### Phase 3 — Standard versus Code benchmark

Use the same representative repository task in both modes. Select the winner by:

- Correctness and test results
- End-to-end wall-clock completion
- Number of failed/repeated tool actions
- Ability to recover from an error
- Memory and process cleanup
- Quality of the final handoff

### Phase 4 — Browser and memory

- Install and pin BrowserMCP plus its Chrome extension.
- Validate the actual signed-in browser profile.
- Add one memory MCP.
- Test recall from a completely fresh Harness session.

### Phase 5 — External agents

- Enable official Harness Codex and Claude providers using existing authentication.
- Test task isolation, inherited working directory and final-result return.
- Verify OpenCode ACP capability; add it only if supported cleanly.
- Add cloud LLM routes selectively rather than duplicating every provider immediately.

### Phase 6 — Hermes operations plane

- Install the pinned native Windows Hermes Desktop/runtime only after Harness is stable.
- Configure a separate Hermes profile and persistent data home.
- Connect to the stable LM Studio endpoint without changing the Harness/OpenCode model identity.
- Configure a queue/idle policy before enabling local scheduled inference.
- Validate procedural skill creation in a disposable test profile before enabling automatic skill improvement in the production profile.
- Validate memory recall, cron persistence, job history and one selected messaging delivery channel.
- Keep terminal/filesystem capability at the signed-in Windows-user level when Scott requests the same access.

### Phase 7 — Production audit and Mission Control

- Test cold start and second response.
- Test C:\ discovery and a temporary create/edit/execute/delete cycle.
- Run a real repository test suite.
- Test Git status/diff/commit preparation without unintended changes.
- Force a compaction boundary and verify continuity.
- Resume and fork a saved session.
- Run and terminate a background job.
- Complete a signed-in browser task.
- Verify cross-session memory.
- Confirm child processes and model memory are released after exit.
- Reboot Windows and repeat the critical tests.
- Verify that Hermes cron jobs survive restart, do not duplicate, and do not preempt active local coding.
- Build the thin Mission Control surface only after all native health/status interfaces are known.
- Verify Mission Control can fail or close without interrupting Harness, Hermes, OpenCode or LM Studio.

---

## 12. Acceptance criteria

The system is production-ready only when all of the following pass:

- Harness opens from a desktop launcher without a terminal workflow.
- A fresh session starts at `C:\` with persistent full Windows-user capability.
- Qwen Q5 is selected through the stable API ID and reports 65,536 context.
- The agent can discover a repository anywhere on `C:\` without Scott locating it first.
- It can edit files, install dependencies, run tests, execute Git and use the network.
- Standard mode completes a representative coding task reliably.
- Code mode is enabled as default only if its benchmark is better.
- Automatic compaction preserves task state across a long session.
- BrowserMCP operates the intended signed-in Chrome session.
- Persistent memory is recalled from a new session.
- Codex and Claude subagent tasks succeed with existing authentication.
- OpenCode remains independently functional.
- Closing/unloading the stack returns memory to other Windows applications.
- All configuration survives an application restart and a Windows reboot.
- If Hermes is enabled, scheduled jobs run while Harness is closed and record an auditable outcome.
- Hermes memory and learned skills remain isolated, inspectable and reversible.
- A scheduled Hermes job cannot silently contend with an active interactive Qwen task.
- Mission Control reports status and launches native surfaces without becoming a required single point of failure.

---

## 13. Rollback and recoverability

- Keep Q4_K_M installed and untouched.
- Preserve the verified Q5 configuration backup.
- Pin the Harness version and retain its effective config dump.
- Put local behavior in overlays instead of modifying official source.
- Keep OpenCode functional throughout Harness deployment.
- Do not enable Harness autostart until the full audit passes.
- Record installed MCP versions and their configuration.
- Back up the Harness home directory before each structural configuration change.
- Keep Hermes in a separate profile/home and back up its config, memory and skills independently.
- Disable the Hermes gateway and schedules without affecting Harness/OpenCode.
- Mission Control contains no irreplaceable state and can be deleted/rebuilt from service-native data.

---

## 14. Final recommendation

Proceed with this architecture:

1. DeepSeek Harness Standard mode as the initial primary local-agent cockpit.
2. OpenCode Desktop retained as an independent coding interface and rollback.
3. LM Studio serving the verified Qwen Q5 daily model and retained Q4 fast model.
4. Full signed-in Windows-user capability across `C:\` through Harness `danger-full-access` with `never` approval mode.
5. BrowserMCP controlling the existing signed-in Chrome profile.
6. Native Harness compaction and session history, plus one MCP memory server for cross-session recall.
7. Official Codex and Claude subagent providers, with OpenCode connected through ACP only if its installed build supports it cleanly.
8. Hermes added only as an operations plane for cold-session scheduling, messaging, memory and procedural skill learning—not as a competing coding loop.
9. A thin browser-based Mission Control added last, reading native service state rather than duplicating it.
10. No custom Harness, browser or orchestration framework until the existing extension points demonstrate a specific limitation.

This design gives Qwen a complete coding environment without making OpenCode expendable, adds genuinely unattended operations without abusing Harness reminders as cron, avoids duplicated inference servers and unnecessary custom plumbing, and preserves a clean rollback path at every layer.

---

## 15. Primary references

- DeepSeek Harness: https://deepseek.com/harness/en/
- Official repository: https://github.com/deepseek-ai/deepseek-harness
- Official documentation: https://deepseek-harness.github.io/deepseek-harness/en/guide/quickstart
- Local reviewed clone: `C:\Users\scott\Documents\Codex\2026-08-16\i-j\deepseek-harness-review`
- BrowserMCP: https://github.com/BrowserMCP/mcp
- Browser Use: https://github.com/browser-use/browser-use
- Browser Harness: https://github.com/browser-use/browser-harness
- ResonantOS architectural reference: https://resonantos.com/
- Transcript incorporated as reference material: `C:\Users\scott\Desktop\transcript2.txt`
- Hermes Agent official repository: https://github.com/NousResearch/hermes-agent
- Hermes Agent official documentation: https://hermes-agent.nousresearch.com/docs/
- Hermes native Windows guide: https://hermes-agent.nousresearch.com/docs/user-guide/windows-native
- Hermes architecture: https://hermes-agent.nousresearch.com/docs/developer-guide/architecture
