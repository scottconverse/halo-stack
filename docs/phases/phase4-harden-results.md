# Phase 4 (Harden) results — 2026-08-17

## Passed, all independently verified
- **`.dsh` home backup**: `DSH-home-backup-20260817-162234` (0.4 MB, node_modules excluded).
- **Background jobs**: start → list → output → kill lifecycle via headless; heartbeat file proved the process tree dead after `job_kill` (29 lines, zero growth post-kill).
- **Compaction fail-closed**: manual `/compact` on a near-empty session correctly refused ("could not produce a useful summary"), conversation unchanged, attempt logged.
- **Compaction for real**: after inflating the session to ~20K real tokens, `/compact` shadowed 9 history items (~15,017 tokens) into a checkpoint.
- **Continuity across the boundary**: with tools forbidden, the session answered the pre-compaction codename ("VIOLET ANCHOR 9") purely from the checkpoint. Bonus observation: told to "remember" the codename, the agent had also stored it in memory MCP unprompted.
- **Prefix cache in production shape**: TTFT 157 s (turn 1, cold) → 13 s (turn 2, cached 20K+ prefix) → 80 s (turn 3, the one planned post-compaction re-prefill). Matches probe numbers. Note: the UI's "Cache hit 0%" is cosmetic — LM Studio's API doesn't report cached-token usage fields; TTFT is the truth.
- **Model unload/reload**: Q5 unload returned ~10 GB instantly; launcher cold-start reloaded the exact pinned Q5_K_XL config.
- **Server restart persistence**: server killed, cold-started via `Start-DSH.ps1` (the desktop-shortcut path) — session history fully intact and continuable, settings (default preset `halo-standard`, permission, model) all preserved.
- **Desktop launcher**: `Desktop\DeepSeek Harness.lnk` → hidden-window `Start-DSH.ps1`, double-click-safe (just opens the page if the server is already up).

## Reboot test — PASSED (2026-08-17, user-confirmed by screenshot)
Full Windows reboot: LM Studio auto-restored Q5 under the stable id; harness restarted; session history fully intact (compaction checkpoint and recall answer visible); settings and default preset preserved. One launcher flaw found and fixed post-reboot: original script opened the browser before the server was up (guaranteed "connection refused" on cold boot). `Start-DSH.ps1` now sequences LM Studio server → model-if-missing → harness → browser-only-when-listening, all hidden. Also noted: OpenCode races the boot (opens before the 21 GB model finishes loading) and falls back to cloud models — session-level model pick, two clicks to restore, not a fault.

## Outstanding
- **Autostart**: cleared to enable now that reboot passed. Awaiting Scott's yes/no.
