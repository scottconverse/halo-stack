# HALO Stack — User Manual

Daily operation of the local AI stack. For design rationale and bench data, see the
[build log](https://quartz-entry-ptf2.here.now/) (archived in this repo as
`docs/build-log-snapshot-2026-08-17.html`).

## The pieces and their addresses

| Piece | Where | Started by |
|---|---|---|
| Cockpit (DeepSeek Harness) | `http://127.0.0.1:3080` | Desktop icon **DeepSeek Harness** |
| Mission Control dashboard | `http://127.0.0.1:3090` | Desktop icon **Mission Control** |
| LM Studio inference server | `http://127.0.0.1:1234` | Runs as a service at login |
| OpenCode | its own app | On demand (autostart removed on purpose) |

## Starting and stopping

**Start:** double-click **DeepSeek Harness**. The launcher checks LM Studio, loads the
Q5 brain if it isn't resident, starts the harness, and opens the browser only when the
page will actually load. Cold boot after a reboot takes 1–3 minutes (npx + 21 GB model);
if it's already running, the icon just opens the page. Nothing to babysit.

**Stop:** close the browser tab (session is safe — it lives on the server), and if you
want the memory back, open Mission Control → **Unload All**. The harness server itself
is a hidden process; it dies with logoff/reboot, or leave it running — it idles free.

## Using the cockpit

- **New session:** pick workspace **Desktop-Code** (not C-Drive — known rc.7 bug: drive
  roots never bind; your sessions have full-drive permission regardless of workspace).
  Preset defaults to **HALO Standard**; model defaults to the local Q5 at **Medium**
  reasoning. Both changeable per-session in the composer.
- **First turn is the slow one.** A fresh session pre-reads ~10K tokens of system prompt
  and tools (up to ~2 min). Every later turn rides the prefix cache — expect seconds of
  wait, not minutes. The one planned slow turn afterward is right after a compaction.
- **Reading the stats bar** (bottom): high TTFT = it was reading (prefill); low TTFT with
  a long run = it was thinking/writing. "Cache hit 0%" is cosmetic — LM Studio doesn't
  report cache fields; trust the TTFT.
- **Slash commands:** `/compact` squeezes history into a checkpoint (continuity is
  proven — it keeps working knowledge). `/permission <mode>` switches access mid-session.
- **Subagents** (HALO Standard preset): the model can call `subagent_codex`,
  `subagent_claude_code`, and `subagent_opencode` — ask it to "get a second opinion from
  Claude" or "hand this to Codex" in plain language. They run on your existing logins.
- **Memory:** say "remember this: …" and it stores a fact in the knowledge graph
  (`~\.dsh\memory\memory.json`) that any future session can recall — survives reboots.
  Ask "what's in your memory about X" to retrieve.
- **Web search & page reading:** every session has `mcp__exa__` tools — live web
  search plus fetch-any-URL-as-markdown — via Exa's keyless public MCP endpoint
  (free tier ≈150 calls/day, 3/sec). Ask naturally: "search the web for…" /
  "read this page…". To lift the cap later: free Exa key → `~\.dsh\.env` and
  re-enable the native `tool-web` row. The built-in DeepSeek search stays
  disabled (needs a paid cloud key).
- **Session log:** top-right button downloads the full append-only log of any session.

## Model operations

- **Truth source:** `lms ps --json` (or just look at Mission Control's model card —
  it uses exactly that). Never trust the REST catalog's quantization field.
- **Load/unload:** Mission Control buttons — *Load Brain*, *Load Worker*, *Unload
  Worker*, *Unload All*. The worker auto-unloads after 2 h idle and returns ~16 GB.
- **Sharing:** the cockpit and OpenCode share one brain slot. Simultaneous turns queue —
  nothing breaks, the second one just waits. Watch queue depth in Mission Control.

## When something looks wrong

| Symptom | Cause | Fix |
|---|---|---|
| "Connection refused" at :3080 | Server not started | Desktop icon, or Mission Control → *Start cockpit* |
| Typing doesn't paint / text overwrites itself | Stale pre-restart tab, or Chrome auto-translate | Close tab, open fresh one; keep translate disabled for the site |
| "Deep diving…" for minutes | First-turn prefill, or queued behind another local request | Check Mission Control queue; it finishes — patience, not restart |
| OpenCode on a cloud model unexpectedly | It raced the boot before the model loaded | Click the model name → pick "Local Daily Driver" |
| Workspace won't select in composer | You picked C-Drive | Use Desktop-Code (rc.7 bug; permissions unaffected) |
| Harness won't boot at all | A bad MCP/plugin row (e.g. BrowserMCP) | Check the row `disabled: true` flags in `~\.dsh\cordis.patch.yml` |

Full bug list with root causes: README §Known issues and `docs/phases/phase3-reach-results.md`.

## Maintenance

- **Weekly delta scan:** paste [`HALO-Stack-Monitor-Prompt.md`](HALO-Stack-Monitor-Prompt.md)
  into a fresh cockpit session. The stack audits its own upstream (harness
  releases, your five known bugs, new quants, llama.cpp changes, community
  findings) and tracks scan state in its memory graph. Written by the stack's
  own model; improved and maintained here.

- **After any live config change** (settings.yaml, patch, preset, launcher, loader):
  run `scripts\Sync-FromLive.ps1`, review `git diff`, commit with the reason. That's the
  whole discipline — it keeps every tuning decision diffable.
- **Backups:** point-in-time snapshots live in
  `Documents\Codex\ConfigBackups\` (pin record, config dumps, phase results, `.dsh` home).
- **Upgrading the harness:** deliberate act, never casual. Change the pin
  (`0.1.0-rc.7`) in both launchers, re-run the Phase 1 smoke tests (repo discovery,
  edit, test, outside-repo write), and re-check the six known bugs — preview releases
  move fast in both directions.
- **Rebuild from nothing:** README §Workflow — install Node 22+, pnpm 11, LM Studio +
  the two GGUFs, run `scripts\Deploy-ToLive.ps1`, recreate the two desktop shortcuts,
  install per-profile subagent plugins (deploy script prints the command).

## Parked, by choice

- **Hermes operations plane** — cold-session cron + phone messaging; revisit when
  remote workflows outgrow the cloud-agent apps.
- **BrowserMCP** — blocked on an upstream Windows crash; config row ships disabled.
- **Cockpit autostart** — cleared to enable (reboot test passed); currently manual by
  preference.
- **Self-hosted SearXNG** — evaluated 2026-08-17 as the fully sovereign search option
  (uncapped, VPN-covered, runs in the existing WSL2 Ubuntu, no Docker needed). Passed
  over in favor of keyless Exa for zero moving parts. Revisit if the 150/day cap
  pinches or the Exa dependency chafes.
