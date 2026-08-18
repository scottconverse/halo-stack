# Phase 3 (Reach) results — 2026-08-17

## Validated
- **Memory MCP**: entity stored by one headless session, file verified on disk (`C:\Users\scott\.dsh\memory\memory.json`), recalled verbatim by a completely fresh session ("TEAL HORIZON 47").
- **Codex subagent**: `subagent_codex` → `CODEX-OK` (spawns `codex app-server --stdio`, existing auth).
- **Claude Code subagent**: `subagent_claude_code` → `CLAUDE-OK` (official Agent SDK, native auth).
- **OpenCode subagent (ACP)**: `subagent_opencode` → `OPENCODE-OK` after Windows fix (see bugs).
- **Web UI cockpit end-to-end**: session under `Desktop-Code` workspace, HALO Standard preset, Full access badge, Medium reasoning, thinking + reply + stats bar (10.2K input, TTFT queued behind concurrent headless run — single-slot queueing behaved as designed).
- **Default preset** set to `halo-standard` via Settings (persisted in `settings.yaml`: `agent-presets: default: halo-standard`).
- **Reasoning effort**: route default `medium` with per-model `reasoningEfforts` map (low/medium→medium, high/xhigh→xhigh). Validated live after fixing UNSUPPORTED_REASONING_EFFORT.

## Bugs found (rc.7, all documented workarounds)
1. **BrowserMCP `@browsermcp/mcp` crashes on Windows** when port 9009 is free (cmd `FOR` port-kill throws → promise-rejection recursion → harness boot dies). Row disabled in `cordis.patch.yml`. Revisit on a fixed release; Chrome extension also not yet installed.
2. **Drive-root workspace paths fail silently**: a `C:\` workspace never binds in the composer (no server call, no console error). Normal directories work instantly. Workaround: workspace `Desktop-Code` (`C:\Users\scott\Desktop\Code`); full-drive permission unaffected (sandbox mode is independent of workspace root). `C:\` entry kept in `workspace.json` as repro.
3. **Workspace created with empty title** renders as a blank, unclickable menu item. Fixed by setting `title` in `storages\workspace.json` (server stopped).
4. **npm `.ps1` shims not spawnable** by the ACP provider: `spawn opencode ENOENT`. Fix: `command: cmd, args: ['/c','opencode','acp']`.
5. **Subagent provider plugins are profile-scoped**: must be `dsh plugin add`-ed per profile (web AND headless), plus explicit peer `@deepseek-ai/dsh-sdk-protocol` (profile pnpm has autoInstallPeers off). pnpm 11 installed globally for this.

## Deferred
- BrowserMCP (bug + extension). Alternatives when revisited: newer @browsermcp/mcp, or Browser Use.
- Upstream bug reports for items 1–3 (drafts in this folder when filed).
