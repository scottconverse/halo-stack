# halo-stack

The complete, reproducible configuration of the HALO local AI stack:
**DeepSeek Harness (`dsh` pinned `0.1.0-rc.7`) + LM Studio (Qwen3.8-27B Q5 brain,
Qwen3 Coder 30B MoE on-demand worker) + Mission Control + OpenCode config**,
as designed, benched, and hardened on 2026-08-17.

**Landing page:** https://scottconverse.github.io/halo-stack/ · **Build log** (full design + measured results): https://quartz-entry-ptf2.here.now/ · **[User manual](docs/USER-MANUAL.md)** · mirror: https://brave-willow-zrcc.here.now/

## Layout

| Path | What it is | Live location |
|---|---|---|
| `docs/` | Design docs (Codex v1, Claude v1, v2 FINAL), **USER-MANUAL.md**, phase records 1–4, and `build-log-snapshot-2026-08-17.html` (archived copy of the published build log — the full architecture record) | — |
| `site/` | Landing page source (self-contained; published to here.now) | — |
| `dsh/` | Harness config surface: `settings.yaml` (provider route), `cordis.patch.yml` (MCP + subagent rows), launchers, bench overlays | `~\.dsh\` |
| `dsh/agent-presets/halo-standard/` | Default preset: standard + Codex/Claude/OpenCode subagent tools | `~\.dsh\.agent-presets\halo-standard\` |
| `lmstudio/` | Pinned model loaders (brain, worker) + MTP sweep tool | `~\.lmstudio\scripts\` |
| `mission-control/` | One-file status page, `127.0.0.1:3090` | `~\.dsh\mission-control\` |
| `opencode/` | OpenCode config (local daily driver + cloud routes) | `~\.config\opencode\` |
| `scripts/` | `Sync-FromLive.ps1` (live → repo), `Deploy-ToLive.ps1` (repo → live) |

`dsh/dot-env` deploys as `~\.dsh\.env` — it holds only the placeholder `lm-studio`
API key (LM Studio doesn't validate). No real secrets live in this repo; OpenCode
auth files are deliberately excluded from sync.

## Workflow

- After changing any live config: `scripts\Sync-FromLive.ps1`, review `git diff`, commit with the reason.
- Full machine rebuild: install Node 22+, pnpm 11, LM Studio + the two GGUFs
  (`unsloth/Qwen3.8-27B-UD-Q5_K_XL`, `unsloth/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S`),
  run `scripts\Deploy-ToLive.ps1`, create desktop shortcuts to the two launchers,
  install the per-profile subagent plugins (command printed by the deploy script),
  double-click **DeepSeek Harness**. Ten minutes to a working cockpit.

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
