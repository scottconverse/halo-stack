# Principal Engineer

## Role + severity counts

Blocker 0 / Critical 0 / Major 3 / Minor 5 / Nit 1

## Findings

### PE-M1 (Major) — The composed-config validation gate has a proven blind spot; a live, currently-inert safety cap demonstrates it

**Evidence.** I ran the actual composed-config dump myself, twice, directly against live `~/.dsh` state:
- `node C:\Users\scott\AppData\Roaming\npm\node_modules\pnpm\bin\pnpm.mjs dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --dump-config` → exit 0, first line of output: `dsh: [C:\Users\scott\.dsh\cordis.patch.yml] patch: entry "jobs-local" not found`
- Same command against `@deepseek-ai/dsh@0.1.0-rc.7` (the pre-migration pin) → **identical** line, identical wording. So this is pre-existing, not caused by this diff.

Root cause, nailed down from the same dump: `dsh/cordis.patch.yml:30` writes `- id: jobs-local`, but the base plugin it's trying to patch composes under `- id: jobs` / `name: '@deepseek-ai/dsh-jobs-local'` (confirmed at line 48-49 of the 0.1.1-rc.2 dump). The id in the patch file doesn't match the id cordis actually assigns — a one-token typo (`jobs-local` vs `jobs`). The config this patch was supposed to install is `maxConcurrentJobsPerOwner: 1`, and per the file's own comment (`dsh/cordis.patch.yml:21-29`) it exists specifically to prevent a repeat of "the 2026-08-20 failure (five subagents, three dead on idle timeout...)". That cap has never attached, on either version.

Nobody would know, because none of the three independent gates that exist to catch exactly this class of problem catch this specific phrasing:
- `scripts\Deploy-ToLive.ps1:147`: `Select-String -Pattern "warn|unmatched|error"` — doesn't match "not found"
- `scripts\Sync-FromLive.ps1:51`: `Select-String -Pattern "warn|unmatched"` — same gap, and doesn't even check for "error"
- `mission-control\mission-control.mjs:2710`: `/unmatched|warn/i.test(l)` — same gap
- `tests\Run-Tests.ps1:113-117` (test A2) only regexes `dsh\cordis.patch.yml`'s **source text** for `maxConcurrentJobsPerOwner:\s*1\b` — it never checks the setting actually attaches. It would pass even with the id wrong.

I called Mission Control's real `/api/validate-config` endpoint (with a legitimately extracted per-boot token, mirroring a normal UI click) and got `{"ok":true,"warnings":[]}` — a clean bill of health, on a config with a real unattached safety cap sitting in its own stdout, one line up.

**Why it matters.** This is the exact question the audit asked me to answer ("does composing a 0.1.1 dump-config against rc.7 profiles validate honestly?") and the answer, with hard evidence, is no — not because of anything this migration changed, but because the migration's whole premise (route every dump-config invocation through pnpm dlx and trust the resulting `ok`/`warnings`) inherits a real, silent gap in what "clean" means. The specific instance is a currently-live, currently-armed repeat path to a named, already-expensive incident.

**Impact scope.** Not migration-caused (identical under rc.7), so it doesn't block this diff's advancement on its own — I'm keeping it at Major rather than Critical for that reason. On pure exposure grounds (an armed, undetected safety-cap defeat with a documented incident precedent, invisible to every existing gate) it would be Critical in a general reliability review; flagging that calibration explicitly rather than picking one and hiding the reasoning.

**Fix path.** Two independent fixes, both cheap: (1) `dsh/cordis.patch.yml:30` — change `id: jobs-local` to `id: jobs`, then re-run dump-config and confirm the "not found" line disappears and `maxConcurrentJobsPerOwner` shows attached in the composed output for id `jobs`. (2) Broaden the warning filters in the three files above to also catch dsh's actual "not found"/"patch:" phrasing (or, better, assert on it structurally: parse the dump-config output for `patch:.*not found` as a hard failure, not a hopeful substring match) — and make A2 assert the composed effect, not just the source text.

---

### PE-M2 (Major) — A launcher timeout orphans the whole pnpm-dlx tree instead of cleaning it up, and the migration made that path more likely to trigger

**Evidence.** `dsh\Start-DSH.ps1:55-61` (`Fail-Loud`) does `Add-Content`, `Release-Mutex`, `Start-Process notepad`, `exit 1` — it never touches `$dsh` or any child process. Both call sites that fire after a real launch attempt — `Start-DSH.ps1:219` (wrapper exited early, nothing serving) and `Start-DSH.ps1:229` (300s deadline exceeded, `Start-DSH.ps1:209`) — inherit that same no-cleanup behavior. On a timeout, the entire 4-process pnpm-dlx tree (cmd → pnpm.mjs → cmd → bin.js; see PE-M1's sibling finding PE-N1 below for the real shape) is left running, unkilled, in the background — a still-downloading `pnpm dlx` on a slow first pull is not stopped, just abandoned by the script that gave up on it.

This isn't new to the migration (the same `Fail-Loud` shape existed with `npx` and a 180s deadline). What's new is the migration's own stated reasoning: `Start-DSH.ps1:87-92` and `:206-207` explicitly reframe a slow **cold** install (~190 packages, first pull) as an expected, anticipated case worth a 120-second budget increase — which raises the real-world odds of hitting this exact path on any machine (or store) that isn't already warm, which is every fresh machine and every store wipe.

**Why it matters.** The self-heal story here ("next launch's stale-sweep cleans it up," verified correct in PE-1 below) only works on a **third** attempt: run 1 times out and orphans a half-downloaded tree; run 2's stale-sweep force-kills that half-finished install (wasting the download) and starts a fresh one, which itself may not finish inside 300s either on a slow link — a user could plausibly retry twice, see two "Startup failed" Notepad windows, and give up, without ever coming up. No new download-progress reuse exists across attempts.

**Impact scope.** Bounded to first-run-on-a-cold-store scenarios (this box is already warm and unaffected right now), but that's precisely the scenario a first-time user or a freshly provisioned machine hits — Major, not Blocker, because the current live box isn't exposed and the failure is self-diagnosing (Notepad shows the real cause), just wasteful and potentially repeat-failing.

**Fix path.** In both `Fail-Loud` call sites (or inside `Fail-Loud` itself, gated on whether `$dsh` was assigned), add `if ($dsh -and -not $dsh.HasExited) { Stop-Process -Id $dsh.Id -Force -ErrorAction SilentlyContinue }` plus a sweep of its still-alive children by the same stale-process pattern already in the file, so a failed launch leaves nothing behind for the next attempt to inherit.

---

### PE-M3 (Major) — Core/plugin version skew (0.1.1-rc.2 core vs 0.1.0-rc.7 plugins) is never detected or reconciled — only printed as a suggestion

**Evidence.** Live package.json reads, both profiles:
```
~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-sdk-protocol/package.json       -> 0.1.0-rc.7
~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-subagent-acp/package.json       -> 0.1.0-rc.7
~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-subagent-claude-code/package.json -> 0.1.0-rc.7
~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-subagent-codex/package.json     -> 0.1.0-rc.7
```
(identical for `headless`). Core is `0.1.1-rc.2` everywhere else (confirmed by MIG2 + live grep). `~/.dsh/profiles` is a real directory (`Attributes` = `Directory`, no reparse point), and `scripts\Deploy-ToLive.ps1:110` junctions it wholesale (`New-Item -ItemType Junction -Path "$StagingRoot\profiles" -Target "$U\.dsh\profiles"`) into the staging home used for the "staged config composes clean" gate — so that gate validates the new core against these exact, un-reinstalled rc.7 plugin packages every run.

The only place this is addressed at all is `scripts\Deploy-ToLive.ps1:617`, a `Write-Host` printing a suggested manual command — never executed:
```
Write-Host "Subagent plugins per profile: pnpm dlx @deepseek-ai/dsh@0.1.1-rc.2 plugin --profile <web|headless> add ..."
```
And the deploy's own audit row for this (`Deploy-ToLive.ps1:596-600`) checks only `Test-Path "$U\.dsh\profiles\$profile\node_modules\@deepseek-ai\$_"` — directory existence, never version — so it reports **PASS** regardless of the skew I just measured.

**Partial mitigation, verified**: at the config-composition level the skew is not currently breaking anything I could detect — the live dump-config output shows `subagent-codex`, `subagent-claude-code`, `subagent-opencode-acp` all composing cleanly with no "not found"/error (the *only* such line in either dump is the unrelated `jobs-local` one from PE-M1). That's real evidence against gross breakage, but it says nothing about deeper runtime/IPC-protocol compatibility between an rc.7-built subagent worker and a 0.1.1-rc.2 host, which config composition can't exercise (see "What I could not assess").

**Why it matters.** This is exactly the question the audit asked me to answer, and the answer is: no reconciliation exists, and the one detector that exists (existence-only) would not notice a real skew.

**Impact scope.** Major — currently non-breaking by the evidence I could gather, but entirely undetected and entirely manual to fix; a future dsh minor/patch bump that does introduce a real protocol break would sail through every gate in this repo unnoticed.

**Fix path.** Make the audit row at `Deploy-ToLive.ps1:596-600` compare installed plugin `package.json` version against `$dshPkg`'s pin (not just presence), and either auto-run the `pnpm dlx ... plugin ... add` reconciliation when they drift, or fail the audit loudly (matching the existing pattern for W2's "points elsewhere" check two rows up) so a human has to act instead of trusting a green row that isn't checking what it claims to check.

---

### PE-N1 (Minor) — Inline comment misidentifies which process `$dsh` is, and undercounts the process tree

**Evidence.** `Start-DSH.ps1:212-213` states, marked "(verified)": *"$dsh is the `pnpm dlx` launcher process, which spawns a cmd wrapper and then the node server (verified: pnpm.mjs -> cmd -> bin.js)"*, and `Start-DSH.ps1:140-142` describes "the pnpm dlx process tree has **three** parts."

Live process capture (traced parentage all the way back to the actual `Start-DSH.ps1` invocation, PID 35524) shows **four** levels, and `$dsh.Id` (the `Start-Process -PassThru` handle at `Start-DSH.ps1:192`) is the **outermost cmd.exe**, not the pnpm.mjs node process:
```
35524 powershell.exe  Start-DSH.ps1                         (the script itself)
└─ 7844  cmd.exe    /c "pnpm.cmd dlx ... web --no-open"      ← THIS is $dsh
   └─ 25144 node.exe   pnpm.mjs dlx ... web --no-open        (the actual "pnpm dlx launcher")
      └─ 32732 cmd.exe /c "dsh web --no-open"
         └─ 28148 node.exe  ...\@deepseek-ai\dsh\lib\bin.js web --no-open   (the real server)
```
This is standard, documented Windows behavior: `CreateProcess`/`.NET Process.Start` cannot exec a `.cmd` directly and transparently wraps it in `cmd.exe /c`, which is why `pnpm.cmd` (a batch file) produces an extra level `npx.cmd` also would have.

**Why it matters — but doesn't, functionally.** I checked whether this changes the "is `HasExited` a safe early-abort signal" answer: it doesn't. `cmd /c` batch-executes `pnpm.cmd`'s body inline and synchronously waits on the child it spawns; `pnpm dlx` for a long-running command likewise waits on its own child chain. So `$dsh.HasExited` becoming true still means the *entire* chain down to `bin.js` has unwound — the practical guarantee the code relies on holds, just not for the reason the comment states. I also confirmed (regex test below) that the extra, uncounted 4th level doesn't create an orphan risk: the stale-process sweep matches all four levels independently by PID, not by cascade-killing from "launcher+server," so "three parts" being wrong doesn't produce a functional gap today.

**Impact scope.** Minor — no proven behavioral bug, but a maintainer trusting the "(verified)" tag at face value (e.g., to correlate `$dsh.Id` against `Get-Process` for diagnostics) would be looking at the wrong process.

**Fix path.** Correct the comment to describe the real 4-level chain (cmd → pnpm.mjs → cmd → bin.js) and note `$dsh` is the outermost cmd.exe wrapper Windows creates for the `.cmd` launch, not pnpm.mjs itself.

---

### PE-N2 (Minor) — TOCTOU between the top-level serving check and the stale-process kill loop

**Evidence.** `Start-DSH.ps1:137-165`: the decision to enter the cleanup branch is made once, from a single `Test-CockpitServing` call at the top of the `if/else`. Everything inside the `else` (the `Get-CimInstance` snapshot, the per-candidate port-guard, the `Stop-Process -Force` calls) runs afterward without re-checking whether 3080 has since started answering. A server mid-way through a slow cold start that finishes and starts serving in that window (typically well under a second on this box, but not bounded) would still be force-killed.

**Why it matters.** Narrow and self-healing (the single-instance mutex at `Start-DSH.ps1:70-75` already rules out two script *invocations* racing; only a still-starting *previous* server process can be caught mid-transition), but it's a real window, not a hypothetical one — nothing re-validates "is it serving now" immediately before the kill.

**Impact scope.** Minor — low probability, and a killed-while-just-becoming-healthy server just gets relaunched by the same script moments later.

**Fix path.** Re-run `Test-CockpitServing` immediately before the `foreach ($c in $candidates)` loop and skip the whole sweep if it just turned true.

---

### PE-N3 (Minor) — `npm` dropped from the prerequisite check, but the deploy still shells out to bare `npm` later

**Evidence.** `scripts\Deploy-ToLive.ps1:23-27`: the migration removed the explicit `npm`/`npx` prereq entries, leaving only `node`, `pnpm`, `lms`. But `Deploy-ToLive.ps1:495` still runs `& npm install --no-audit --no-fund` (unrelated to dsh — it's the `@lmstudio/sdk` install for the loader scripts) with no equivalent named-prereq guard.

**Why it matters.** `npm` ships with Node by default, so on any normal install this is inert. But the entire point of the named-prereq block (per its own comment at `Deploy-ToLive.ps1:14-18`, "a missing Node surfaced 200 lines later as... sending a newcomer after a third-party YAML library instead of the actual missing item") was to convert exactly this class of failure into an immediate, named message. If `npm` is ever missing from an otherwise-present Node install (stripped by a corporate image, a `nodejs-slim`-style package, etc.), the failure now resurfaces 480 lines later as a raw `npm : The term 'npm' is not recognized` instead of the friendly prereq message the script was explicitly designed to produce.

**Impact scope.** Minor — low likelihood (npm ships with Node), and self-diagnosing if hit, just a regression in error-message quality relative to the stated design intent.

**Fix path.** Either add `npm` back to the `$prereqs` array, or note explicitly in a comment that `npm`'s presence is assumed as a Node corollary and intentionally unchecked.

---

### PE-N4 (Minor) — One of the four js-yaml discovery globs is dead code

**Evidence.** `Deploy-ToLive.ps1:78` (`...\pnpm\store\*\links\@\js-yaml`) — verified **correct** against the real on-disk pnpm v11 store: `Get-ChildItem` against that literal glob returned a real hit, `C:\Users\scott\AppData\Local\pnpm\store\v11\links\@\js-yaml\4.3.1` (pnpm v11 buckets even unscoped packages under a literal `@` directory — confirmed by listing `links\` directly, which shows `@`, `@anthropic-ai`, `@aws`, etc. as siblings).

`Deploy-ToLive.ps1:79` (`...\pnpm-cache\dlx\*\*\node_modules\js-yaml`) — verified **dead**: a recursive search of the entire live `pnpm-cache` tree for any `js-yaml*` directory returned nothing. This matches pnpm's own non-hoisting `.pnpm` virtual-store isolation: js-yaml is a transitive dependency of dsh (not declared directly), so it's never linked to a top-level `node_modules\js-yaml` inside the ephemeral dlx working directory — only inside `node_modules\.pnpm\js-yaml@...\node_modules\js-yaml`, which this glob doesn't reach.

**Why it matters.** Not a correctness bug in practice — the resolver's other three candidates (the live `.dsh\profiles` copy, the legacy npx-cache glob, and the working pnpm-store glob above) already cover every case I could produce, including a cold-bootstrap scenario, since the persistent CAS store (not the ephemeral dlx cache) is where `pnpm dlx`'s own dependencies land durably. But the dead glob adds false confidence to the "checked... + pnpm store" message at `Deploy-ToLive.ps1:321` and will never do anything.

**Impact scope.** Minor — cosmetic/dead-code, no observed functional consequence.

**Fix path.** Either remove the dlx-cache glob, or point it at the real nested shape (`pnpm-cache\dlx\*\*\node_modules\.pnpm\js-yaml@*\node_modules\js-yaml`) if the intent was genuinely to cover the ephemeral cache too.

---

### PE-T1 (Nit) — Two historical design docs still instruct the pre-migration `npx` command

**Evidence.** `docs\Claude-Harness-HALO-Design.md:89,162` and `docs\Claude-Harness-HALO-Design-v2.md:100,146,242` still read `npx @deepseek-ai/dsh@0.1.0-rc.7 web`. Neither file is in this migration's changed-file list (they're dated historical design records, not live instructions), and the actually-updated user-facing docs (`README.md`, `docs\USER-MANUAL.md`) are fully consistent with the new pin and mechanism — confirmed via grep, zero stale `npx`+`dsh` combinations in either.

**Why it matters.** Low — a reader following these specific historical docs literally would reproduce the exact npm-resolver hang this migration exists to fix, but they aren't the primary onboarding path.

**Impact scope.** Nit.

**Fix path.** A one-line note at the top of each historical doc pointing to the current README, or a follow-up edit if/when those docs are next touched.

---

### PE-N5 (Minor) — The "172 plugins" figure doesn't reproduce with the most direct counting method

**Evidence.** Counting `^- id:` entries in the raw `--dump-config` output (`web` profile) gives **141**, identically under both `0.1.1-rc.2` and `0.1.0-rc.7` on this machine — not 172, and (notably) unchanged by the version bump either way.

**Why it matters.** Minor precision/traceability gap in an otherwise well-evidenced claim ("172 plugins compose with 0 failures" in the CHANGELOG). I can't rule out a different, legitimate counting method (e.g., both profiles combined, or a UI-level count from Mission Control's plugin-inventory tool that counts differently than raw `- id:` lines) — I'm not asserting the number is wrong, only that I couldn't reproduce it by the obvious method and the "0 failures" half of that same sentence needs the PE-M1 caveat above regardless.

**Impact scope.** Minor — doesn't change the compose-succeeds verdict, just flags an unverified specific number.

**Fix path.** State the counting methodology next to the number (or drop the specific count and just say "composes clean, N total plugin entries via `dsh --dump-config`" with N computed by a script, not typed by hand).

## What's working

- **The stale-process regex is correct**, verified two ways: (1) live capture of the real 4-process pnpm-dlx tree on this machine and manual trace, then (2) an 11-case programmatic regex test (`match`/`-notmatch` run against both the real captured cmdlines and constructed dump-config/plugin/unrelated-process cases) — **0 failures out of 11**. It correctly matches all four real tree members (not just the three the comment claims), correctly excludes `--dump-config` and `plugin` invocations via the new exclusion clause, correctly leaves Mission Control's own persistent process and unrelated `npx`-based MCP servers alone, and — importantly — still sweeps a hypothetical pre-migration `npx`-era leftover, so a machine mid-upgrade isn't left with an orphan the new regex can't see.
- **The port-guard is correctly scoped**: it only protects a process listening on a port *other than* 3080; a wedged 3080-holder (the actual failure mode it needs to catch) is not protected and remains killable. No bug found here.
- **`pnpm.cmd` vs bare `pnpm`**: correct, and backed by a real test + mutation proof (MIG3, caught).
- **Mission Control's shell-free pnpm invocation is genuinely solid engineering.** `safeExecFile` (`mission-control.mjs:47-50`) spreads `opts` first and hardcodes `shell: false` *last*, so a caller cannot re-enable a shell even by accident; `PNPM_MJS` is a fixed, `fs.existsSync`-checked path with no request-derived input; the dump-config argv contains only constants. This fully closes the Node-25 `.cmd`/EINVAL problem without reopening the shell-injection surface PE-1 fixed — verified by reading the code, not just trusting the comment.
- **Version pin consistency**: MIG2 plus my own grep across every functional file confirms a single, identical `0.1.1-rc.2` string everywhere — no partial bump.
- **The js-yaml resolver's core glob is structurally correct** against pnpm v11's real on-disk layout (confirmed the literal `@` bucket directory for unscoped packages, which I did not assume going in and had to verify empirically).
- **Live claims verified true**: cockpit at :3080 → 200 with the `__DSH_BOOT__` marker; Mission Control at :3090 → 200; `tests\Run-Tests.ps1` → 33 passed, 0 failed, 0 skipped; `tests\Prove-TestsFailClosed.ps1` → all 18/18 historical-defect mutations caught, including MIG1/MIG2/MIG3. I ran all of these myself rather than trusting the claim.
- **README/USER-MANUAL are honest about their own gaps**: `docs\USER-MANUAL.md:303-307` explicitly flags that the five documented Windows-bug workarounds were verified on rc.7 and re-verification against 0.1.1-rc.2 is "pending" — that's the right way to carry a known gap forward, and it's the kind of self-disclosure I'd rather see more of.

## What I could not assess

- **Deep runtime/protocol compatibility** between the rc.7-built subagent plugin packages and the 0.1.1-rc.2 core (PE-M3). Config composition succeeds cleanly, which is real partial evidence, but I did not spawn an actual subagent to exercise the IPC/protocol path end-to-end — doing so would create live background work on the operator's machine beyond a read-only check, which I avoided.
- **True cold-machine behavior** (empty `~/.dsh/profiles`, empty pnpm store/cache from scratch). I verified the relevant globs and bootstrap logic structurally against pnpm's real, documented store layout, but did not wipe this machine's store to run a literal from-empty test — that would have meant destructive changes to live state I was told not to make.
- **"Reuse path spawns nothing"** — verified by static code-path analysis only (the spawn logic at `Start-DSH.ps1:140-231` is structurally inside the `else` branch and unreachable when `Test-CockpitServing` returns true at `Start-DSH.ps1:137`). I deliberately did not re-invoke the production launcher against the operator's live, in-use cockpit to dynamically confirm this, given the explicit instruction not to stop services and the (small but nonzero) risk of exercising a bug in exactly the kill logic under review.
- **The exact methodology behind "172 plugins"** (PE-N5) — flagged, not resolved.
- **CC1** (`tests\Run-Tests.ps1:517`, the fresh-clone dry-run-deploy test) is gated behind an opt-in `-CleanClone` switch I did not pass; I read its logic but did not additionally execute it, and it isn't specific to the pnpm/npx mechanism.
