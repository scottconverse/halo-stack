# Changelog

All notable changes to this repository are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Window doubled: brain now runs ctx 131072 with KV q8_0**
  (`docs/phases/bench-window-131k.md`, ADOPT verdict): same GPU footprint
  as the old 65536/f16 config (q8_0 halves KV bytes), prefill parity at
  19.5K (179.6 vs 181 tok/s), 9.0 tok/s decode at ~110K depth, zero
  shared-pool growth. Phase 1 of the output-wall plan: reply room roughly
  doubles, the budgeted-emit chunk cap rises with it automatically. Found
  along the way: the model's trained max is 262144 - the old 65536 was a
  config choice, not a ceiling. `machines/5070ti.yml` updated in the same
  change (its KV replacements are now inherited from base; ctx finds
  re-pointed) so the profile cannot rot against the new loader.
- **Budgeted-emit pipeline** (`pipeline/`, from
  `docs/design/budgeted-emit-pipeline.spec.json`): generative work of any
  size without ever hitting the output-token wall - room measured before
  every emit, chunks capped deterministically, sentinel truncation
  detection, retries always in fresh context, clean-room LOCAL review
  (cost-direction rule: local pipelines never call paid frontier models).
  Upstream resilience proposals filed as deepseek-harness discussion #3303.
- **Per-machine profiles** (`machines/`, issue #6): master's files stay
  HALO-canonical literals; a non-HALO box deploys with `MACHINE=<name>` and
  the deploy renders `machines/<name>.yml` replacements over the base files
  (fail-loud when a replacement no longer matches master). `machines/5070ti.yml`
  captures the port's measured config; the box remembers its name via
  `~\.dsh\machine`. Portable fixes now land once and every machine inherits.
- **Self-enforcing install** (PR #8, closes #4): Deploy-ToLive registers the
  hourly memory-snapshot task itself (idempotent, self-heals deletion) and
  ends with a machine-state audit — every USER-MANUAL system-state row
  printed PASS/MISSING against the live machine. js-yaml resolution globbed
  + self-bootstrapping on clean machines. README carries the one canonical
  8-step rebuild checklist.
- **Launcher hardened** (PR #1, from the port session): waits for LM Studio's
  API, runs the brain check on every launch (evicted brain reloads even with
  the cockpit already up), logs to `~\.dsh\launcher.log` with retry + Notepad
  on failure, federation-safe brain check (`deviceIdentifier` null). Smoke-
  verified on HALO both ways before merge.
- **Eviction JIT-reload alarm** (PR #9, closes #5): Mission Control alarms
  MODELS amber when the loaded local brain's quant/context diverge from the
  deployed loader profile; 16GB-class advisory added to the manual.

### Fixed
- Mission Control on foreign hardware (issues #2, #3): GPU carveout read
  from the driver registry instead of a hardcoded 128 GiB; remote fleet
  models lose Load/Unload controls and the unload endpoint refuses them
  server-side; quick-action labels derive from the deployed loader scripts.

Prior history — every design iteration, bench run, and decision that led
here — is preserved in full in [`docs/phases/`](docs/phases/) (Phase 1
install/wire, Phase 2 baseline/bench, Phase 3 reach, Phase 4 harden,
`bench-day-2-results.md`, `pin-record.txt`) and archived in
[`docs/build-log-snapshot-2026-08-17.html`](docs/build-log-snapshot-2026-08-17.html).
This entry summarizes what the stack *is* at this version, not a
chronological diff.

## [0.2.0] - 2026-08-18

### Added
- **Bench Day 3** (`docs/phases/bench-day-3-results.md`): MTP stays ON at
  stock n=4 on HALO's Vulkan (locked — mirror image of the CUDA sibling);
  KV q8_0 flat on Vulkan (locked NO — vs CUDA's 2.4× unlock; per-engine
  doctrine proven from both directions); brain keeps the cockpit crown —
  MoE candidates decoded 2.7–4× faster but lost wall-clock via 5–7.5×
  more output tokens; qwen3.6-35b-a3b remains a worker candidate;
  gpt-oss-120b DNS at the 64/64 split. Includes a live federation-
  contention incident, handled and documented.
- **Port PROVEN: full stack installed on an RTX 5070 Ti 16GB box**
  (`docs/ports/tester-5070ti-bench-2026-08-18.md`): `Deploy-ToLive.ps1`
  clean three times, live loaders/launcher/icons/plugins/Mission Control
  serving; installed config = UD-Q3_K_XL all-GPU, KV q8_0, MTP off —
  1,668 tok/s prefill, 0.33 s cached TTFT, 42 tok/s @30K, harness task
  73 s vs HALO's 176 s, worker fan-out task 2.5 s vs 41 s. Three
  measurement passes replicated. Port-discovered stack fixes shipped:
  Mission Control carveout math de-hardcoded (VRAM capacity from driver
  registry), remote fleet models stripped of Load/Unload controls with a
  server-side refusal guard, clean-machine deploy-order bug documented,
  eviction JIT-downgrade trap documented, sha256 model-file gate adopted
  as policy.
- **Fleet: LM Link** — LM Studio multi-device pooling adopted deliberately
  with discipline: device-suffixed identities (HALO canonical unsuffixed),
  bench-guard rule (no benches with foreign models active), Mission
  Control origin labels + fleet card + cross-origin contention alarm;
  documented in the manual, AGENTS.md, and delta-scan watches.
- **Mission Control "Memory" tab** — interactive force-directed knowledge
  graph (cursor-anchored wheel-zoom, drag-pan, draggable nodes, click-node
  detail panel with observations + clickable connections, live refresh);
  `/api/memory-graph` now returns relation edges (backward compatible).
  First prototyped live by the local brain as a Creator-mode cockpit
  plugin — full experiment record with the good/bad/ugly in
  `docs/experiments/creator-mode-2026-08-18.md`.
- Strix Halo deep-dive research report
  (`docs/research/strix-halo-deep-dive-2026-08-18.md`) + refined
  delta-scan watches (MTP parallel=1 finding, NPU-hybrid SKU correction,
  ThinkingCap sighting, engine-regression re-bench rule).

### Changed
- Brain `maxTokens` 8192 → 49152 ("config is never the limit; the context
  window is") after reply caps repeatedly truncated creator-mode plugin
  emissions.
- Composer "High" reasoning effort maps to medium (xhigh opt-in only).
- Bench overlays isolate memory writes to a scratch graph; deploys are
  transactional with drift-guard; hourly memory-graph snapshots
  (scheduled task "HALO Memory Snapshot").

## [0.1.0] - 2026-08-18

First versioned release. Everything below is running, measured, and
documented on one AMD Strix Halo machine (128 GiB unified memory,
~256 GB/s bandwidth) as a reproducible, source-controlled configuration —
not a from-scratch design.

### Core

- **DeepSeek Harness (`dsh`) pinned at `0.1.0-rc.7`** as the interactive
  coding cockpit at `127.0.0.1:3080`, `danger-full-access` permission mode,
  `halo-standard` as the default agent preset.
- **Cordis kernel formal-model audit**: full read of the Cordis paper
  ("A Programming Paradigm for Spatiotemporal Composability"), six
  improvements derived and applied — see
  `docs/AUDIT-cordis-concepts-2026-08-18.md`.
- **Config reconciliation proven live**: toggling a `cordis.patch.yml` row
  against a serving harness reconciles the plugin fiber in ~20 seconds,
  both directions, zero restart, zero session disturbance. Restarts are now
  needed only for harness upgrades and one known Windows session-log
  deadlock.
- **Config layering discipline documented and enforced**: bundles → profile
  patch → home `cordis.patch.yml` → `--patch` overlays (stackable); patch
  rows replace their target's config wholesale (no deep merge — the
  footgun to know about); `--dump-config` is the validation gate on every
  sync and deploy; `DSH_HOME` overrides the config root and is used to
  validate staged config in an isolated sandbox before it goes live.
- **OpenCode** kept as an independent, untouched sibling coding UI against
  the same local model identity.

### Models & inference

- **Brain**: Qwen3.8-27B UD-Q5_K_XL (unsloth dynamic quant), dense,
  65,536-token context, vision-capable, identity `qwen/qwen3.8-27b`,
  resident ~19.7–21 GB. Measured: 181 tok/s fresh prefill (108.6 s TTFT on
  a 19.6K-token probe) → 13.4 s cached (8.1×); decode 26.9 tok/s solo,
  19.0 tok/s under concurrent load.
- **Worker**: Qwen3-Coder-30B-A3B MoE Q4_K_S, on-demand with a 2-hour TTL,
  ~16.3 GB resident. Measured: 615 tok/s fresh prefill, 90.9 tok/s decode,
  4.3× faster wall-clock than the brain on a real two-bug repair task
  (41 s vs. 176 s) at equal correctness — the fan-out workhorse for
  subagents, workflows, and Ralph.
- **Inference server**: LM Studio + llama.cpp Vulkan engine. ROCm evaluated
  and rejected on measured evidence (gfx1151 crashes on non-small models,
  `lms` #494; unified-memory mis-sizing, `lms` #589) with ripeness gates
  tripwired in `delta-scan-halo` to re-open the question automatically. A
  bare `llama-server` benchmark at parity confirmed LM Studio's management
  layer costs nothing measured.
- **MTP speculative decoding**: stock configuration (n=4 draft tokens,
  p=0.5 continue-probability) confirmed optimal by sweep; draft acceptance
  52.4%–86.5% depending on content.
- **Reasoning-effort mapping**: composer "High" maps to the model's
  `medium` tier (Qwen3.8 has no real high tier); `xhigh` is explicit
  opt-in only, given its 17–22K thinking-token cost per turn.
- **Truth-source discipline**: `lms ps --json` is the only trusted report
  of what's loaded; the REST catalog is known to misreport quantization
  for aliased identifiers. Both models are pinned under stable API
  identities by loader scripts — a service-broker pattern that lets model
  swaps happen without perturbing any consumer.

### Reach

- **Web search**: Exa MCP, keyed (~1,400 funded searches/month), key
  env-referenced and never committed. Built-in DeepSeek search and the
  unkeyed Exa tier retired in favor of this.
- **Reddit research**: `reddit-search` skill using Reddit's own RSS feeds —
  the only path that works from this machine (Exa serves zero reddit.com,
  Jina is blocked, the JSON API 403s) — paced at ≥8 s between requests.
- **Subagent trio**: Codex, Claude Code, and OpenCode (via ACP), all on
  existing local auth. Windows fix: the ACP provider spawns via
  `cmd /c opencode acp` (npm's `.ps1`/`.cmd` shims aren't directly
  spawnable).
- **Skills as the extension surface**: `delta-scan-halo` runs a weekly
  self-audit of the stack's own upstream; skills live in a shared root
  (`~\.agents\skills`) visible to both Claude Code and the harness.
- **Memory**: MCP knowledge-graph server backed by
  `~\.dsh\memory\memory.json`, recalling facts across sessions and
  reboots. Identified as an out-of-boundary "emission" the harness cannot
  revert; compensated with hourly change-detected snapshots (last 60
  kept) and bench/overlay sessions isolated to a scratch graph so
  experiments never touch the production memory.

### Mission Control

- **v3**: single-file (1,308 lines), zero-dependency, five-tab operator
  console (Overview / Models / Sessions / Plugins / System) behind a
  master alarm strip at `127.0.0.1:3090`.
- **Refactored onto native harness RPCs**: an earlier self-graded
  "duplicates nothing" claim was refuted by adversarial audit — Mission
  Control now consumes the harness's own `apiproxy` RPCs and `events.mux`
  WebSocket stream for sessions, plugin health, and background jobs,
  falling back to a directory scrape only when the harness is down.
- **Plugin card speaks the Cordis lifecycle**: active / disabled / waiting
  / transitioning / failed, plus stuck detection (>60 s in the same
  transitional phase) — failed fibers are always actionable since Cordis
  never auto-retries them without a config touch.
- **GPU shared-pool leak alarm**: model bytes appearing in the GPU shared
  pool rather than the dedicated carveout is the failure mode behind an
  out-of-memory incident on 2026-08-16; the pool is now alarmed if it
  doesn't stay near zero.
- Serves with `Cache-Control: no-store` since the app ships inline in the
  file it serves.

### Operations

- **`Sync-FromLive.ps1`** (live → repo) ends every run with a
  `--dump-config` validation gate.
- **`Deploy-ToLive.ps1`** (repo → live) made fully transactional: drift
  guard → YAML pre-validation (tolerating the `cordis.patch.yml` `!!js`
  tag) → staged compose-validation in a `DSH_HOME` sandbox → timestamped
  backup → apply → live re-validation → automatic rollback on failure.
- **Drift-guard incident, documented honestly**: the transactional
  deploy's own first live test overwrote six files' worth of unsynced live
  edits with older repo copies; the backup stage had already captured
  every one of them, so recovery was a copy-back. The missing drift
  *detection* was then added as the deploy's stage 1 and verified
  against the real incident state.
- **Telemetry audit, clean**: all 199 installed DeepSeek-authored packages
  swept for external hosts, the telemetry exporter's disabled code path
  read at source (constructs no SDK object at all), live process sockets
  inspected (exactly one connection: localhost LM Studio). Zero
  third-party analytics.
- **Backup coverage**: `~\.dsh` home backups, timestamped
  `ConfigBackups\deploy-<stamp>\` on every deploy, and hourly memory-graph
  snapshots — no single point of unrecoverable config or memory loss.

### Documentation & audits

- `docs/USER-MANUAL.md` gains a full **Technology stack** section: one
  subsection per layer (silicon, inference server, models, kernel, reach,
  observability, operations), each stating what it is, why it was chosen
  over the alternative, and where the proof lives — closed with a
  proof-index table.
- `docs/AUDIT-cordis-concepts-2026-08-18.md` — Cordis formal-model findings
  and the live config-reconciliation proof.
- `docs/AUDIT-telemetry-2026-08-17.md` — full privacy sweep, verdict clean.
- `docs/AUDIT-redundancy-2026-08-17.md` — adversarial audit of what in this
  stack is genuinely custom vs. redundant with the harness; one finding
  refuted the original self-grade and drove the Mission Control refactor
  above.
- `docs/phases/` — the complete Phase 1–4 record (install/wire, baseline
  bench, reach, harden) plus `bench-day-2-results.md` and
  `pin-record.txt`, all superseding nothing: this changelog summarizes
  them, it doesn't replace them.
