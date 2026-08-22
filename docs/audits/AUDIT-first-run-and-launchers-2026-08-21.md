# Audit: first-run viability and launcher reliability

**Date:** 2026-08-21
**Trigger:** operator report — "why won't the halo stack load?"
**Method:** two independent clean-context adversarial agents (no project history, instructed to assume the author was not competent), plus independent verification of every finding by the primary agent before any fix.
**Scope:** `dsh/Start-DSH.ps1`, `dsh/Start-MissionControl.ps1`, `scripts/Deploy-ToLive.ps1`, `lmstudio/*`, `README.md`, and the first-run path a stranger follows.
**Outcome:** 3 ship-stoppers and 16 further defects. 14 fixed and verified on hardware (PR #43, merged). 5 open, ranked in §6.

---

## 1. Headline

**The repository has never worked for anyone who downloaded it.** Not "worked with rough edges" — the brain could not load at all, on any machine that was not the author's, since the repository was first published. Five releases shipped over that period, each described as verified.

The proximate cause was a dependency that existed only on the author's disk. The systemic cause is that every verification was performed on the one machine where the missing piece was present.

---

## 2. Method note, stated because it changes how the rest should be read

Both audits were run by agents with **no conversation history**, explicitly told not to trust the author's comments or documentation. That mattered:

- Audit A proved a double-click race **by running it**, not by reasoning about it.
- Audit A caught that the orphan-cleanup code queried `node.exe` while the comment directly above it named `cmd.exe` as the orphaned process — the fix did not target the bug its own text described.
- Audit B read `git ls-files` rather than the import statement, which is how the missing SDK surfaced.

Three defects in this report were introduced **by the primary agent during this session, while fixing the others** (§5.4). All three were caught by verification rather than by review. That is the strongest available evidence that the verification step is what carries the weight here, not care or intent.

---

## 3. Ship-stoppers

### S1 — Loader scripts imported an SDK that is not in the repository

All three scripts in `lmstudio/` began:

```js
import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";
```

**Verified:** `git ls-files lmstudio/` returns exactly three files. No `vendor/` directory is tracked, it was absent from `Deploy-ToLive.ps1`'s file map, and `.gitignore` excludes `node_modules/` so it could not have been committed as written. The directory exists on the author's machine only.

**Effect:** every clone fails here with `MODULE_NOT_FOUND`. `Start-DSH.ps1` retries twice, writes "BRAIN LOAD FAILED TWICE", opens Notepad on a raw Node stack trace referencing a path no documentation mentions — and then **continues**, opening a cockpit with no model loaded.

**Aggravating discovery:** the vendored copy was not stock either. Same version string (`1.5.0`), **794,178 bytes against npm's 749,089**, and it understands eleven load-config keys the published package does not:

| Key | Vendored | Public 1.5.0 |
|---|---|---|
| `maxParallelPredictions` | ✓ | dropped |
| `useUnifiedKvCache` | ✓ | dropped |
| `physicalBatchSize` | ✓ | dropped |
| `contextCheckpoints` | ✓ | dropped |
| `reasoningBudgetMessage` | ✓ | dropped |
| `speculativeDraftMtp` | ✓ | dropped |
| `speculativeDraftSimple` | ✓ | dropped |
| `speculativeDraftMaxTokens` | ✓ | dropped |
| `speculativeDraftMinTokens` | ✓ | dropped |
| `speculativeDraftMinContinueProbability` | ✓ | dropped |
| `tryDirectIO` | ✓ | dropped |

The published SDK **accepts these keys and silently discards them**. So the obvious remedy — `npm i @lmstudio/sdk@1.5.0` — would have loaded the brain with MTP off, no context checkpoints, the wrong physical batch size and the wrong parallelism, **while reporting success**. This is issue #14, which had been filed as a port-box annoyance. It was never a port-box problem.

**Fix:** stock public SDK pinned in a committed `lmstudio/package.json`; a new deploy stage that installs it *and* proves the loaders can resolve the bare specifier on that machine; a wire-level shim (`loadConfigToKVConfig`) pushing the discarded fields directly into the KV config the server receives; verification switched from `getLoadConfig()` to `lms ps --json`.

`getLoadConfig()` on public 1.5.0 returns a shape whose fields all read `undefined`, so the previous assert would throw and **unload a model that had loaded correctly** — the failure mode issue #14 described.

**Evidence:** `vendor/` renamed away entirely, then both loaders run clean:

```
brain : {"contextLength":131072,"quant":"Q5_K_XL","parallel":1}   exit 0
worker: {"contextLength":32768,"parallel":1}                       exit 0
```

`parallel: 1` is the decisive value — it originates from `llm.load.numParallelSessions`, a field the public SDK discards. Its presence proves the shim is doing the work.

### S2 — The author's username hardcoded into four deployed files

```yaml
MEMORY_FILE_PATH: 'C:\Users\scott\.dsh\memory\memory.json'
```

In `dsh/cordis.patch.yml` and three bench overlays. The default machine profile is `halo`, which deploys byte-for-byte; the `5070ti` profile does not patch it (`grep -c` → 0). On any other machine the path does not exist and is not writable by another Windows profile. Per this project's own README, a misbehaving MCP row can crash the harness boot rather than merely degrade.

`dsh/memory/Snapshot-Memory.ps1` already used `$env:USERPROFILE` correctly, so this was a defect against the codebase's own convention, not a design decision.

**Fix:** derived from `$USERPROFILE` using the `!!js` form already present elsewhere in the same file.

### S3 — Both launchers concealed the failures they existed to report

`Start-DSH.ps1` started the server with `Start-Process -WindowStyle Hidden` and **no output redirection**, discarding stdout and stderr. `launcher.log` therefore ended at `LM Studio API up: True` with no further information — precisely what the operator saw.

That line shipped in commit `210aa5a` (2026-08-18), titled **"Harden Start-DSH.ps1: no silent failures, brain check on every launch."** Everything was hardened except the one process that serves the application.

---

## 4. Further defects

### 4.1 `Start-DSH.ps1` — from adversarial review

| # | Defect | Status |
|---|---|---|
| L1 | Readiness was a TCP listen check. rc.7 can deadlock with `:3080` held open and every request hanging, so listening ≠ serving — a wedged server read as healthy | Fixed (HTTP check) |
| L2 | No identity check: any unrelated dev server answering 200 on 3080 was adopted as "the cockpit" and the browser opened onto it | Fixed (`__DSH_BOOT__` marker) |
| L3 | A missed deadline logged nothing and opened a browser on the dead port | Fixed (loud, exit 1, no browser) |
| L4 | No single-instance guard. A second double-click during the up-to-240s hidden startup force-killed the first run's still-starting server. **Reproduced by audit** | Fixed (named mutex) |
| L5 | Concurrent launches overwrote each other's log file — the diagnostic file the fix existed to create. **Reproduced by audit** | Fixed (per-run timestamped logs) |
| L6 | Stale-process cleanup queried only `node.exe`, while the comment above it named the `cmd.exe` running `npx.cmd` as the orphan | Fixed (matches both; `cmd.exe` wrapper confirmed live, PID 25044) |
| L7 | Cleanup could kill a second, deliberate instance serving a different port | Fixed (skips anything listening elsewhere) |
| L8 | Missing `lms`/`node`/`npx` bypass `2>$null` and `*>>` entirely — command-discovery failures are not capturable that way — so the script timed out for 60s and blamed the wrong component | Fixed (`Get-Command` preflight with named messages) |
| L9 | Workspace fell back to `$env:USERPROFILE` when `Desktop\Code` was absent — silently widening a `danger-full-access` agent to the entire home directory, on exactly the fresh-machine case | Fixed (creates the intended workspace) |
| L10 | `$dsh` is the `cmd.exe` wrapper, not the node server, so `HasExited` watches the wrong process | Mitigated: serving is always decided by the HTTP check; documented in-file |

**Audit A also verified as correct** (recorded so these are not re-litigated): `$dsh` scoping across `if`/`else` is sound in PowerShell; `@(...)` around `Get-CimInstance` correctly yields Count 0; the file parses clean under real PowerShell 5.1.26100.9168 with zero non-ASCII bytes and no PS7-only constructs; `Start-Process` on a `.cmd` target with both redirects works under 5.1.

### 4.2 `Start-MissionControl.ps1`

Line 1 read *"idempotent, hidden, browser only when serving."* Line 9 opened the browser unconditionally, never checking `$up`. No log file, no captured output, no exit code, and TCP-listen readiness. The same defect class as S3, in the sibling launcher created by the same README step. **Fixed** — identity-checked readiness on `/api/status`, captured output, loud failure, no browser on a dead port.

### 4.3 First-run defects (Audit B) — not all fixed

| # | Defect | Status |
|---|---|---|
| F1 | The vendored SDK (= S1) | **Fixed** |
| F2 | Hardcoded username (= S2) | **Fixed** |
| F3 | README step 7 tells the user to create a desktop shortcut to a `.ps1`. Windows 11 associates `.ps1` with **Edit**, not Run — a shortcut made the obvious way opens the script in a text editor. Requires `powershell.exe -ExecutionPolicy Bypass -File "..."` | **OPEN** |
| F4 | Default profile assumes Strix Halo, 128 GiB, a 21 GB Q5 brain at 131,072 context. No hardware probe, no warning, no confirmation. A stranger on ordinary hardware gets HALO's tuning and discovers the mismatch only when the model fails to load | **OPEN** |
| F5 | `lms` CLI presence assumed; the README never mentions its bootstrap step, and `2>$null` discarded the one diagnostic line that would have named it | **Partly fixed** — preflight now names `lms` explicitly; README step still missing |
| F6 | Missing Node/npx surfaces as *"No js-yaml install found"* — misdirecting toward a third-party YAML library instead of the actual missing prerequisite | **OPEN** |
| F7 | `Start-MissionControl.ps1` (= 4.2) | **Fixed** |
| F8 | README deploys (step 5) before installing subagent plugins (step 6), while `cordis.patch.yml` `insert:`-registers those plugin rows. If compose emits anything matching `warn\|unmatched\|error`, the first deploy's own validation trips and auto-rolls-back before the user reaches step 6. Medium confidence — depends on dsh compose behaviour for an uninstalled `insert:` row | **OPEN, unverified** |

**Audit B also verified as sound:** the transactional deploy pipeline (stage → pre-validate → sandbox compose-validate → timestamped backup → apply → post-validate → auto-rollback) is correct, no-ops properly on a virgin machine, and is honest when rollback itself cannot be verified clean.

---

## 5. Verification record

### 5.1 Fixes proven on hardware

| Test | Result |
|---|---|
| Loaders with `vendor/` renamed away | Both exit 0 with correct context, quant, parallelism |
| Launcher, cockpit already healthy | Reused; spawned zero processes |
| Launcher, cold from zero dsh processes | Serves, identity-checked `__DSH_BOOT__` |
| Listening-but-silent port | Correctly judged **not** serving (old code called it healthy) |
| Full `Deploy-ToLive.ps1` | Exit 0; every audit row PASS; new SDK stage green |
| `launcher.log` after fixes | Plain readable ASCII, no false error |

### 5.2 Not proven, stated as such

- **MTP injection is unverified.** `lms ps --json` does not expose speculative-decoding state, so there is no cheap check. The injection *mechanism* is proven (`parallel: 1` can only arrive through the shim) and the wire-key prefix comes from a mapping proven on the 5070Ti box — but MTP itself being active is inferred, not measured. A decode-rate benchmark would settle it.
- **F8** (deploy/plugin step order) was not reproduced; it needs a genuinely clean machine.
- The **orphan-recovery path** in the new launcher is still not covered by a test that actually reaches it (see 5.4).

### 5.3 Where an auditor was wrong

Audit B reported the hardcoded path as present in four files and blocking. Correct. My **first verification grep returned nothing** and I nearly recorded the finding as false — the pattern used the wrong backslash escaping under Git-Bash, a trap this project already has a written note about. Re-run with correct escaping, all four files confirmed. **An auditor finding was nearly dismissed on the strength of my own tooling error.**

### 5.4 Defects introduced during this session's fixes

1. **Test mislabelled.** A test intended to prove orphan recovery printed `orphans left behind: 0` — killing the listener took the whole process tree, so the orphan branch never executed. It was a second cold-start test wearing the wrong label, and was nearly reported as a pass.
2. **Deploy probe in the wrong directory.** The new SDK-resolution probe was written to `%TEMP%`; ESM resolves bare specifiers from the *importing file's* directory, not the process working directory, so the probe failed while the real loaders resolved fine. Caught because the new stage failed closed.
3. **Log encoding regression.** `lms server start *>> $log` appended UTF-16 into a UTF-8 log and wrapped `lms`'s stderr success banner as a PowerShell `NativeCommandError` — a healthy start read as a failure. Introduced while fixing exactly this class of defect; caught by re-reading the log rather than the verdict line.

---

## 6. Open items, ranked

1. **F4 — no hardware check before applying the HALO profile.** Highest remaining risk to a newcomer: silent mis-tuning discovered only at model-load time.
2. **F3 — `.ps1` shortcut instructions.** Terminal step of the documented install; fails for anyone without PowerShell background.
3. **F6 — missing Node/npx misreported as a js-yaml problem.**
4. **F8 — README step order vs. `insert:` plugin rows.** Needs a clean-machine reproduction.
5. **F5 remainder — `lms` CLI bootstrap missing from README step 1.**
6. Pre-existing and unrelated to first-run: **#39** (profiles silently inherit base changes), **#40** (5070ti worker advertises 32,768 against a ~19K crash point), **#15** (fleet origin badges inverted).

---

## 7. Conclusions

**On the code.** The transactional deploy machinery is genuinely good and repeatedly caught real problems, including three of this session's own. The launchers were the weak layer, and the loaders were broken outright.

**On the process.** Every one of these defects was discoverable at any time in the last three days by a check that costs seconds: `git ls-files`, a grep for the author's username, a clone into a clean directory. None was run, because the stack worked on the machine where it was written and that was accepted as evidence that it worked.

The single highest-value change is not in this diff: **verification must happen from outside the developing machine's state.** A clean-clone smoke test — clone to a temp directory, deploy into a throwaway home, load a model, start both launchers, assert HTTP identity — would have caught S1, S2, F3, F4 and F6 on the day each was introduced.

That test does not exist yet. It is the recommended next build item, ahead of any further feature work.
