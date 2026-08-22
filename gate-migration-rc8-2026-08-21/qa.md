# QA Engineer

# QA Engineer — Deep-Dive Report
## Migration Slice: dsh rc.7→0.1.1-rc.2, npx→pnpm dlx (halo-stack, migrate/rc8 @ bb0f782)

## Role + severity counts
Blocker 0 / Critical 0 / Major 0 / Minor 2 / Nit 1

## Findings

### QA-RC8-1 — Minor — documentation-drift / supply-chain-provenance
**Evidence:** `docs/phases/pin-record.txt:1-5` (unchanged by this migration — confirmed via `git diff master..migrate/rc8 -- docs/phases/pin-record.txt`, empty diff):
```
package:   @deepseek-ai/dsh@0.1.0-rc.7
tarball:   https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.7.tgz
integrity: sha512-ZceDCJ8FAywih+USW/OMk9jEhunlvJBGEz4kqrhau23hPzbciOazZrywH0nBRsaalSeAJ1JGBmjtw4OSjToStw==
shasum:    8a69013c06179d7af437de92fb4a9a2e1fd7d410
```
`docs/USER-MANUAL.md` (post-diff, this migration) cites that exact file as the source of truth for the pin:
```
| Harness pin | `0.1.1-rc.2` | `docs/phases/pin-record.txt` |
```
Observed: the cited file's package name, tarball URL, integrity hash, and shasum are **all** for the old rc.7 tarball. Expected: a provenance record matching the version the table claims it backs.
**Why it matters:** the file's own shape (package/tarball/integrity/shasum) marks it as a supply-chain verification artifact, not incidental prose — exactly the kind of thing an operator checks before trusting a new binary blob from the registry. This is the identical failure class the migration's own MIG2 test was written to catch ("a partial version bump leaves one file pinned to an older dsh") — it just landed in a doc/provenance file outside MIG2's scanned-file list (`dsh\Start-DSH.ps1`, `scripts\Deploy-ToLive.ps1`, `scripts\Sync-FromLive.ps1`, `mission-control\mission-control.mjs`), so the test suite's own safety net didn't cover it.
**Impact scope:** Minor — confirmed via `grep -r "pin-record"` that no script reads this file back (only `docs/USER-MANUAL.md` and `CHANGELOG.md` reference the filename), so there is zero runtime/functional blast radius. Purely a stale audit-trail claim.
**Fix path:** regenerate the record for 0.1.1-rc.2 in the same format (e.g. `pnpm view @deepseek-ai/dsh@0.1.1-rc.2 dist.tarball dist.integrity dist.shasum`), or add `docs/phases/pin-record.txt` to MIG2's scan so a future partial bump fails CI instead of surviving to the next audit.

### QA-RC8-2 — Minor — process-lifecycle / resource-leak
**Evidence (reasoned from code + live process-tree measurement, not live-reproduced — see caveat below):** `mission-control/mission-control.mjs:2708` sets a hard timeout on the dump-config child: `safeExecFile('node', [PNPM_MJS, 'dlx', ..., '--dump-config'], { timeout: 300000, ... })`. Node's `child_process` timeout kills only the **direct child** (here, the `node pnpm.mjs` process) — it does not cascade to descendants, and no Job Object or tree-kill is used anywhere in this file. I measured live (for the equivalent `web` launch, same tree shape minus the outer `pnpm.cmd` hop that MC's direct `node <pnpm.mjs>` call skips) that this spawn produces two further descendants: a `cmd /c "dsh ... --dump-config"` wrapper, then a `node .../bin.js ... --dump-config` process. On Windows, killing the top parent does not kill these.

Meanwhile `dsh/Start-DSH.ps1:155` — the only cleanup mechanism in this codebase for orphaned dsh-tree processes — permanently excludes anything matching `--dump-config`:
```powershell
Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern -and $_.CommandLine -notmatch '(--dump-config|\bplugin\b)' }
```
I verified this exclusion is unconditional (no time bound) by constructing the exact argv shapes MC's call and Deploy-ToLive.ps1's `plugin add` call produce and running them through the live regex object (not by hand-tracing):
```
MatchPattern=True Excluded=True WOULD_KILL=False
  "C:\Program Files\nodejs\node.exe" "...\pnpm.mjs" dlx @deepseek-ai/dsh@0.1.1-rc.2 web --dump-config
MatchPattern=True Excluded=True WOULD_KILL=False
  cmd.exe /q /d /s /c "dsh ^^^"web^^^" ^^^"--dump-config^^^""
MatchPattern=True Excluded=True WOULD_KILL=False
  node "...\lib\bin.js" "web" "--dump-config"
```
So if a dump-config run times out at 300s, its two orphaned descendants are invisible to the sweep forever, by design of the same exclusion that correctly protects a *healthy in-flight* validation run.
**Why it matters:** this is a real gap, not a theoretical one — the 300s timeout exists specifically because a cold `dlx` pull (~190 packages) is an anticipated slow case, per the code's own comment. Each timeout leaks up to two OS processes with no recovery path; repeated retries (e.g. an operator clicking "Validate Config" again after each failure) compound the leak. It does not corrupt data or expose anything — the HTTP caller still gets a clean `{ok:false, warnings:[...]}` from the `catch` block at line 2712-2713 either way.
**Impact scope:** Minor. Requires an actual ≥300s stall to trigger (measured warm case is ~50s), bounded leak per incident, no security or correctness exposure, self-limiting in the common case (a merely-slow-but-completing grandchild still exits on its own).
**Fix path:** capture the descendant PID chain at spawn (WMI/`Get-CimInstance` parent-walk, or a Windows Job Object) and kill the whole tree on timeout; or make the launcher's `--dump-config` exclusion time-bound (e.g. only protect it if the process's start time is <310s old) so a genuine orphan re-enters the sweep.
**Caveat on confidence:** I did not trigger a real 300s timeout to reproduce this directly — the task instructed not to unless safe and fast, and a genuine cold-pull stall is neither. This finding rests on documented Node.js `child_process` timeout semantics (kills only the direct child) plus the live-measured shape of this specific process tree, not a live repro.

### QA-RC8-3 — Nit — documentation-accuracy
**Evidence:** `dsh/Start-DSH.ps1:140-144` comment: *"the pnpm dlx process tree has three parts — the `pnpm.mjs dlx ... web` launcher, a `cmd /c dsh web` wrapper, and the `...bin.js web` server."* Live process listing during this audit (`Get-CimInstance Win32_Process`, cross-checked against `Get-NetTCPConnection -LocalPort 3080`) showed **four** real OS processes for one `web` launch:
```
PID 7844  cmd.exe   /c ""...\pnpm.cmd" dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --no-open "
PID 25144 node.exe  "...\pnpm.mjs" dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --no-open
PID 32732 cmd.exe   /q /d /s /c "dsh ^^^"web^^^" ^^^"--no-open^^^""
PID 28148 node.exe  "...\lib\bin.js" "web" "--no-open"   <- owns :3080 (confirmed via Get-NetTCPConnection)
```
The comment's "three parts" omits the outermost `cmd.exe` wrapper (PID 7844) that Windows requires to invoke `pnpm.cmd` itself — the same structural hop the old `npx.cmd` path had.
**Why it matters:** purely cosmetic today — I live-tested the regex against all four real PIDs plus Mission Control's own PID (23068) and it correctly sweeps all four dsh-tree processes while correctly leaving Mission Control alone. But the comment is the map a future maintainer will use when this sweep misbehaves, and it's one process short.
**Impact scope:** Nit.
**Fix path:** reword to "four processes" (or "the launcher's own cmd.exe wrapper, plus three more") so the count matches what `Get-CimInstance` actually returns.

## What's working

**The core migration claim is true and independently corroborated, not just self-reported.** Four independent evidence sources agree the live cockpit is genuinely running 0.1.1-rc.2, not merely configured to claim it: (1) the resolved pnpm store path in the live server process's own command line literally contains `@deepseek-ai\dsh\0.1.1-rc.2\...`; (2) Mission Control's `/api/status` reports `"dshVersionPin":"0.1.1-rc.2"`; (3) the live test suite's `V5` check ("the cockpit, if up, is the harness and not something else on 3080") passes right now; (4) `GET /` returns `__DSH_BOOT__` with a full, coherent 46-module plugin manifest.

**The dsh backend is a fully live, functioning API, not a static shell.** I loaded the real cockpit in a browser and captured its actual boot traffic: all 46 plugin client bundles load 200 OK, followed by 20 distinct RPC calls (`host.describe`, `session.list`, `session.history`, `subagent.list`, `workspace.list`, `settings.describe`, `credentials.describe`, `skill.list`, `commands/list`, `agentPreset.list`, `session.models`, `llm.providers`, `dynamicCordisRunner/*`) — every one 200 OK with well-formed, semantically correct payloads (e.g. `llm.providers` reports the `lmstudio` provider as `"routable":true` with the actual loaded model `qwen/qwen3.8-27b`; `host.describe` reports the correct workspace `cwd`).

**172 plugins, 0 failures, subagent providers active — confirmed by full JSON parse, not a summary glance.** `/api/status`: `"plugins":{"total":172,"active":142,"disabled":30,...,"failed":0,"failedList":[]}`. I parsed the full `/api/plugins` payload (172 entries) directly: `failedList` empty, and all five subagent-provider plugins individually confirmed `enabled:true, bucket:"active"` — `dsh-subagent-claude-code`, `dsh-subagent-codex`, `dsh-subagent-acp`, `dsh-subagent-fork-in-process`, `dsh-subagent-spawn-in-process`.

**The stale-process regex — the riskiest part of this diff, since a wrong match kills Mission Control or a live deploy, and a wrong exclusion leaks orphans forever — is correct.** I didn't take the code comment's word for it: I ran the actual `$pattern`/exclusion regex objects (not hand-traced) against both the real live PIDs (launch case) and carefully constructed synthetic command lines matching the exact argv shape of MC's dump-config call and Deploy-ToLive.ps1's plugin-add call. Every dsh-tree process is caught; Mission Control, in-flight dump-config runs, and in-flight plugin-add runs are all correctly excluded.

**Mission Control's PE-1 posture survived the rewrite.** `POST /api/validate-config` still gates on the exact `x-mc-token` before touching any subprocess — I confirmed live with a no-token and a fake-token POST, both instant `403 unauthorized`, zero delay, no subprocess spawned. The new `PNPM_MJS` resolution is a fixed-path join (not a PATH search), matching the file's existing "poisoned PATH cannot redirect us" philosophy, and `safeExecFile`'s `{ ...opts, shell: false }` ordering makes `shell:true` structurally unreachable regardless of caller opts. `node --check` confirms the file parses; the live `SEC1`/`SEC2` tests re-confirm no `shell:true` and universal token-gating.

**Mission Control is provably running the migrated code, not a stale in-memory copy.** The live-deployed file at `~/.dsh/mission-control/mission-control.mjs` is byte-identical to the repo's post-migration copy (`Compare-Object` count 0, same `LastWriteTime`), and the running MC process started 46 seconds after that file was last written to disk.

**Double-launch protection and the reuse path are structurally untouched and still correct.** The named mutex (`Local\HaloStackLauncher`) and the `Test-CockpitServing` reuse branch at `dsh/Start-DSH.ps1:137-138` are unmodified by this diff; the pnpm spawn logic lives entirely inside the `else` branch, so the reuse path cannot reach it — confirmed by static read, not inference.

**Both test suites genuinely pass, not just report green.** Ran live: `tests/Run-Tests.ps1` → **33 passed, 0 failed, 0 skipped**, including the 3 new `MIG1`/`MIG2`/`MIG3` tests and 5 live checks against the actual running :3080 service. `tests/Prove-TestsFailClosed.ps1` → **all 18 mutations caught**, including all 3 migration-specific mutations (reintroducing npx, a mismatched version pin, or bare `pnpm` instead of `pnpm.cmd` each correctly fails its test).

**Indirect but real evidence toward the key session/tool-execution question.** I did not spend tokens creating a new session (out of scope per instructions), but I found a historical session (`session-f7142abe`, "/delta-scan-halo") whose event log shows the exact tool-calling mechanism — `tool/call` → `tool/result` pairs for both an MCP tool (`mcp__memory__open_nodes`) and the `pwsh` shell tool — completing successfully end-to-end in this same stack's session schema. Nothing in this migration's diff touches dsh's session/tool-execution code (the diff is entirely install/launch mechanism), so this is meaningful evidence the mechanism is sound, short of a fresh live rep on this exact process.

## What I could not assess

- **A fresh, live, token-spending agent turn on this exact 0.1.1-rc.2 process.** I did not send a prompt or create a session, per the explicit instruction not to mutate/spend tokens without a safe sandbox. What I have instead: the full RPC surface responding correctly, `llm.providers` reporting a routable model, and a historical session in the same stack proving the tool-call mechanism works end-to-end (details above) — but that history predates this server's boot (11:54:15 AM) by hours, so it is not a direct rep on this instance. A full test would require sending one real prompt asking for a small, verifiable tool call (e.g. "list files here") through the authenticated session API and confirming a `tool/call`/`tool/result` pair appears — this needs token-spend/session-mutation authorization this read-only QA pass did not have.
- **Deploy-ToLive.ps1 was not re-run by me.** It writes into the live `~/.dsh` directories while the operator is actively using the machine — outside "read-only," and likely another role's territory in this Full-lane gate. Substitute evidence: the live `V3` test ("live config matches the repository — no undeclared drift") passed, meaning whatever deploy last ran already reflects this migration with no drift.
- **A true cold start from a fully-stopped state was not witnessed** — would require stopping the live service, explicitly forbidden. I'm relying on the live process tree exactly matching the launch code path (including the `--no-open` flag only Start-DSH.ps1 passes), timing evidence, and the live `V4`/`V5` tests passing right now.
- **QA-RC8-2 (dump-config timeout orphan) was not live-reproduced** — forcing a real 300s stall was out of scope per the task's own instruction. That finding is static/reasoned, clearly labeled as such above.
- **The underlying "npm's resolver hangs on Node 25 for dsh past rc.7" root cause was not independently reproduced** — I did not run a real `npm install`/`npx` against dsh 0.1.1-rc.2 and watch it hang. No evidence contradicts the claim; I simply didn't spend the time to watch a multi-minute-plus hang confirm itself.

**Key files referenced:** `C:\Users\scott\Desktop\Code\halo-stack\dsh\Start-DSH.ps1`, `C:\Users\scott\Desktop\Code\halo-stack\mission-control\mission-control.mjs`, `C:\Users\scott\Desktop\Code\halo-stack\scripts\Deploy-ToLive.ps1`, `C:\Users\scott\Desktop\Code\halo-stack\scripts\Sync-FromLive.ps1`, `C:\Users\scott\Desktop\Code\halo-stack\docs\phases\pin-record.txt`, `C:\Users\scott\Desktop\Code\halo-stack\docs\USER-MANUAL.md`, `C:\Users\scott\Desktop\Code\halo-stack\tests\Run-Tests.ps1`, `C:\Users\scott\Desktop\Code\halo-stack\tests\Prove-TestsFailClosed.ps1`.
