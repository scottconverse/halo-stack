# halo-stack

**Version `v0.1.0`** — first versioned release, 2026-08-18. See
[`CHANGELOG.md`](CHANGELOG.md).

**A tested, reproducible local-AI workstation distribution built on DeepSeek
Harness** — the appliance layer, not another harness: hardware tuning, boot
orchestration, model lifecycle, Windows fixes, benchmarking, privacy
validation, and upgrade discipline on top of DeepSeek's runtime.

The complete configuration:
**DeepSeek Harness (`dsh` pinned `0.1.0-rc.7`) + LM Studio (Qwen3.8-27B Q5 brain,
Qwen3 Coder 30B MoE on-demand worker) + Mission Control v3 (tabbed console) +
OpenCode config**, as designed, benchmarked, and documented starting 2026-08-17,
now with a live-reconciling Cordis config layer, a transactional live deploy,
and hourly memory-graph snapshots (2026-08-18 — see
[`docs/AUDIT-cordis-concepts-2026-08-18.md`](docs/AUDIT-cordis-concepts-2026-08-18.md)).

**Landing page:** https://scottconverse.github.io/halo-stack/ · **Build log** (full design + measured results): https://quartz-entry-ptf2.here.now/ · **[User manual](docs/USER-MANUAL.md)** (see **[Technology stack](docs/USER-MANUAL.md#technology-stack--what-runs-why-and-the-proofs)** for the deep design specifics) · mirror: https://brave-willow-zrcc.here.now/

## Layout

| Path | What it is | Live location |
|---|---|---|
| `docs/` | Design docs (Codex v1, Claude v1, v2 FINAL), **USER-MANUAL.md** (incl. the [Technology stack](docs/USER-MANUAL.md#technology-stack--what-runs-why-and-the-proofs) deep-dive), phase records 1–4, `AUDIT-cordis-concepts-2026-08-18.md` (Cordis formal-model findings + live config reconciliation proof), `AUDIT-telemetry-2026-08-17.md`, `AUDIT-redundancy-2026-08-17.md`, and `build-log-snapshot-2026-08-17.html` (archived copy of the published build log — the full architecture record) | — |
| `site/` | Landing page source (self-contained; published to here.now) | — |
| `dsh/` | Harness config surface: `settings.yaml` (provider route), `cordis.patch.yml` (MCP + subagent rows), launchers, bench overlays, `memory/Snapshot-Memory.ps1` (hourly memory-graph snapshot) | `~\.dsh\` |
| `dsh/agent-presets/halo-standard/` | Default preset: standard + Codex/Claude/OpenCode subagent tools | `~\.dsh\.agent-presets\halo-standard\` |
| `lmstudio/` | Pinned model loaders (brain, worker) + MTP sweep tool | `~\.lmstudio\scripts\` |
| `mission-control/` | Mission Control v3 — single-file, zero-dep, 5-tab operator console (`overview/models/sessions/plugins/system`) + master alarm strip, `127.0.0.1:3090` | `~\.dsh\mission-control\` |
| `opencode/` | OpenCode config (local daily driver + cloud routes) | `~\.config\opencode\` |
| `scripts/` | `Sync-FromLive.ps1` (live → repo, ends with a `--dump-config` validation gate), `Deploy-ToLive.ps1` (repo → live, transactional: drift guard → YAML pre-validate → staged compose-validate in a `DSH_HOME` sandbox → timestamped backup → apply → live validate → automatic rollback on failure) |

`dsh/dot-env` deploys as `~\.dsh\.env` — it holds only the placeholder `lm-studio`
API key (LM Studio doesn't validate). No real secrets live in this repo; OpenCode
auth files are deliberately excluded from sync.

## Workflow

- After changing any live config: `scripts\Sync-FromLive.ps1`, review `git diff`, commit with the reason.
  Config changes apply live — the harness reconciles `cordis.patch.yml`/`settings.yaml`
  edits into running plugin fibers within ~20 seconds, no restart, sessions untouched
  (proven 2026-08-18: [`docs/AUDIT-cordis-concepts-2026-08-18.md`](docs/AUDIT-cordis-concepts-2026-08-18.md)).
- Deploying config **to** the machine (`scripts\Deploy-ToLive.ps1`) is transactional —
  staged YAML is validated, then compose-validated in a sandboxed `DSH_HOME`, live files
  are backed up to `~\.dsh\ConfigBackups\deploy-<stamp>\` before anything is overwritten,
  and a failed post-apply validation rolls everything back automatically. A deploy can be
  wrong, but it can't stay broken.
- The memory graph (`~\.dsh\memory\memory.json`) is the one thing the harness cannot
  revert on its own; the scheduled task **HALO Memory Snapshot** takes hourly
  change-detected snapshots (last 60 kept) as compensation.
- **Full machine rebuild — the canonical checklist.** This list is the whole
  spec: every step, in order, nothing sourced from anywhere else. The deploy
  script's final **audit stage** checks the resulting machine state row by row
  and prints PASS/MISSING — the [USER-MANUAL's system-state table](docs/USER-MANUAL.md)
  is the human-readable reference for the same rows.
  1. Install **Node 22+**, **pnpm 11**, and **LM Studio**.
  2. In LM Studio, download the two models:
     `unsloth/Qwen3.8-27B-UD-Q5_K_XL` and
     `unsloth/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S` (verify file hashes against
     the HF API before first use — a resumed download can be size-exact but
     corrupt).
  3. Set LM Studio to start its server at login (app settings → run as a
     login service; headless equivalent: a Startup-folder shortcut running
     `lms server start`).
  4. Bootstrap the harness once **before** the first deploy (creates
     `~\.dsh\profiles`, which the deploy's YAML validator needs — the deploy
     also self-bootstraps if you forget, but this makes it explicit):
     `npx @deepseek-ai/dsh@0.1.0-rc.7 web --dump-config`
  5. Clone this repo and run `scripts\Deploy-ToLive.ps1`. It deploys all
     files, registers the **HALO Memory Snapshot** hourly task itself, and
     ends with the state audit.
  6. Install the per-profile subagent plugins (exact command printed at the
     end of every deploy).
  7. Create desktop shortcuts **DeepSeek Harness** → `~\.dsh\Start-DSH.ps1`
     and **Mission Control** → `~\.dsh\Start-MissionControl.ps1`.
  8. Run `scripts\Deploy-ToLive.ps1` once more and confirm the audit prints
     **all PASS**. Then double-click **DeepSeek Harness**.

  Porting to non-HALO hardware? Read
  [docs/ports/tester-5070ti-bench-2026-08-18.md](docs/ports/tester-5070ti-bench-2026-08-18.md)
  first — engine tuning and model identity must be adapted per machine.

## Telemetry & privacy

Audited 2026-08-17 (full method and evidence: [docs/AUDIT-telemetry-2026-08-17.md](docs/AUDIT-telemetry-2026-08-17.md)):
all 199 installed DeepSeek packages swept (code + config), telemetry subsystem read at source,
live sockets inspected. **Nothing phones home.** Qwen GGUFs are inert weights executed by
LM Studio (no Qwen code runs). The harness's one telemetry exporter defaults to DISABLED —
verified in source to construct no SDK at all — and both enable switches are unset here.
Zero third-party analytics. Live harness processes hold exactly one connection: localhost
LM Studio. The `/delta-scan-halo` skill re-checks telemetry defaults on every future release
before any re-pin.

## Known rc.7 Windows issues (worked around in these configs)

1. `@browsermcp/mcp` crashes harness boot when port 9009 is free → row disabled.
2. Drive-root workspaces (`C:\`) never bind in the composer → use a normal directory.
3. Blank workspace titles render unclickable → set `title` in `storages\workspace.json`.
4. npm `.ps1` shims not spawnable by the ACP provider → `cmd /c opencode acp`.
5. Subagent provider plugins + `dsh-sdk-protocol` peer are per-profile installs.
6. Chrome auto-translate rewrites the live DOM and breaks streaming → disable for the site.
