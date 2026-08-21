# GauntletGate Full lane — Test Engineer

## Role + severity counts

Blocker 0 / Critical 4 / Major 5 / Minor 2 / Nit 1

I read `00-walkthrough.md` first and built on it rather than re-walking first-run. Ground truth below comes from three sources: reading every line of both test files, running the real suite (`Run-Tests.ps1 -Static`, 20/20 pass) and the real mutation harness (`Prove-TestsFailClosed.ps1`, 10/10 caught) against the actual repo, and — where reading left doubt — building isolated throwaway mutants in `%TEMP%` and running the actual test code against them. Nothing in the repository was modified.

## Findings

---

**TE1 — CRITICAL — toothless-test.** `V1` ("the deployed loaders resolve their SDK import") never reads the loader file it claims to test.

*Evidence:* `tests/Run-Tests.ps1:330-339`. The test writes its **own** hardcoded probe (`Set-Content ... 'import { LMStudioClient } from "@lmstudio/sdk"; ...'`) into the deployed-scripts directory and runs that — it never opens `Load-OpenCode-Qwen.mjs` itself. Proven, not inferred: I built an isolated `%TEMP%` directory containing (a) a loader file with the exact historical defect reintroduced (`import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs"`) and (b) a stub `node_modules/@lmstudio/sdk` so the bare specifier resolves.
- Running the loader directly: `Error [ERR_MODULE_NOT_FOUND] ... vendor\node_modules\@lmstudio\sdk\dist\index.mjs` — it is completely broken.
- Running V1's exact probe logic against the same directory: prints `ok`.

V1 would report PASS on a directory whose real loader cannot run. (V2, by contrast, greps the deployed file itself for `./vendor/` imports and genuinely catches this same mutation — confirmed. And `scripts/Deploy-ToLive.ps1:472-481` contains the same synthetic-probe pattern as its own post-install check, so this blind spot isn't confined to the test suite.)

*Why it matters:* V1 is the direct regression test for the exact defect this whole audit exists because of ("five releases shipped ... could NOT load a model on any machine but the author's"). It provides zero protection against that defect recurring in deployed (as opposed to committed-source) state.

*Impact scope:* Any drift between committed source and a machine's actual deployed `~/.lmstudio/scripts/*.mjs` (stale deploy, hand-edit, partial sync) is invisible to V1 forever. V1 is also a live-only test, so it is never exercised by the mutation harness either (see TE9) — nothing has ever verified it, including the "prove it fails closed" self-check.

*Fix path:* Regex-extract the loader's own bare import specifier (S1/S1b already do this for repo source) and feed that into the probe, or `node --check` the real file plus a resolution probe built from its actual import line, not a hand-typed string.

---

**TE2 — CRITICAL — no gating.** The 26-check suite is not wired into anything that runs automatically.

*Evidence:* No `.github/workflows` directory exists. The only active git hook is `.githooks/pre-push` (confirmed active: `git config core.hooksPath` → `.githooks`), which execs `scripts/Check-Publication.ps1` — a secret/policy-leak gate that never references `Run-Tests.ps1` or `Prove-TestsFailClosed.ps1` (grepped, zero hits). No `CONTRIBUTING.md` exists. `README.md` has zero mentions of the tests directory or how/when to run it.

*Why it matters:* This repo's entire premise is "verification was claimed but not actually done." A well-designed suite that only runs when a human remembers to type the command by hand reproduces exactly that failure mode at the process level — it is not a gate, it is an opt-in diagnostic.

*Impact scope:* Every other finding in this report (and every future regression the suite is capable of catching) is only caught if someone chooses to run it before pushing. Nothing stops a broken commit from reaching the public repo strangers are cloning right now.

*Fix path:* Add the suite (`-Static` at minimum) to `.githooks/pre-push`, or add a GitHub Actions workflow on push/PR, and say so in the README.

---

**TE3 — CRITICAL — missing test.** Zero coverage of W1's failure mode, despite the walkthrough specifying the exact test needed.

*Evidence:* `lmstudio/Load-OpenCode-Qwen.mjs:107` and the identical pattern at `lmstudio/Load-Worker-Coder.mjs:57` (`execSync("lms ps --json")`, uncaught) are the walkthrough's W1 Critical finding. `00-walkthrough.md:70` proposes: *"make `lms` return non-zero (rename it on PATH) after a successful load; assert the loader exits 0 with an UNVERIFIED notice and the model stays resident."* No test in `tests/Run-Tests.ps1` touches loader verification-failure behavior at all — I read all 26 test cases and none construct this condition.

*Why it matters:* This is a confirmed-live Critical product defect (a working model gets reported as failed, triggering a redundant 21GB reload) with a ready-to-implement test spec already written down, and the spec was never implemented. Both loaders share the identical unguarded pattern, so one missing test category covers two live defect sites.

*Impact scope:* The fix for W1 (whenever it lands) has no regression protection — it can silently regress, or Load-Worker-Coder.mjs's copy of the same bug can go unfixed indefinitely, with the suite green throughout.

*Fix path:* Implement the walkthrough's proposed test as a static or live check: wrap `lms ps --json` in try/catch in both loaders, classify a throw as `UNVERIFIED` not `FAILED`, and add a test that asserts the loader source does this (e.g., no bare `execSync("lms ps` outside a try block) plus, if feasible, a live test using a PATH-shadowed fake `lms`.

---

**TE4 — CRITICAL — toothless-test (new variant).** `L3`'s structural guard-check can be defeated by an unrelated exit token sitting nearby, causing a real "opens browser on dead port" regression to pass.

*Evidence:* `tests/Run-Tests.ps1:174-203`. L3 already survived one hardening round (its own comment describes catching `if ($false)` replacing the guard condition). I tested a *different* bypass: keep the real guard condition (`if (-not $serving) {...}`) but remove its `exit 1`, and place an unrelated, always-dead `if ($false) { ...; exit 1 }` a few lines later. Repro:
1. Mutated `dsh/Start-MissionControl.ps1` so `if (-not $serving)` only logs and no longer exits; added a dead `if ($false) { ...; exit 1 }` immediately after; `Start-Process "http://127.0.0.1:3090"` now runs unconditionally.
2. Ran the real `tests/Run-Tests.ps1 -Static` against this mutant.
3. **Observed:** `PASS [L3] no launcher opens a browser without first proving the service serves`. **Expected:** FAIL — the browser now opens on every failure, unconditionally.

The check scans raw line ranges (`$j` to `$j+20`) for `Fail-Loud|exit 1` with no brace/control-flow awareness, so any exit-shaped token in the vicinity — related or not — satisfies it.

*Why it matters:* This is the regression test for "no browser opened on a dead port," a property the walkthrough verified as a working strength today. I've shown the test protecting that property can be defeated by a small, plausible edit (adding an unrelated early-exit branch nearby) without touching the vulnerable code path at all.

*Impact scope:* Both launchers (`Start-DSH.ps1`, `Start-MissionControl.ps1`) share this check; either could regress to opening a browser on a dead/unhealthy port with L3 still green.

*Fix path:* Parse brace nesting (or use the PowerShell AST, already available via `[System.Management.Automation.Language.Parser]` as L4 does) so the exit/Fail-Loud must be lexically inside the guard's own block, not merely nearby.

---

**TE5 — MAJOR — toothless-test.** `L1`'s whole-file fallback is currently carrying 100% of its passing verdict; a second unredirected process launch is invisible.

*Evidence:* `tests/Run-Tests.ps1:149-163`: `if ($line -notmatch 'RedirectStandardOutput' -and $t -notmatch 'RedirectStandardOutput')`. In both real files the legitimate `-RedirectStandardOutput` argument sits on a backtick continuation line (`dsh/Start-DSH.ps1:168-170`, `dsh/Start-MissionControl.ps1:49-50`), which the single-line regex `Start-Process[^\r\n]*-PassThru[^\r\n]*` never reaches — so today the *whole-file* `$t -notmatch` clause is the only thing keeping this test green, not the per-line check. Repro: inserted `Start-Process -PassThru diag-helper.exe -ArgumentList "--check"` (no redirect) before the final browser-open line in a mutant `Start-DSH.ps1`, ran the real suite. **Observed:** `PASS [L1]`. **Expected:** FAIL.

*Why it matters:* Any future second `Start-Process -PassThru` call added to either launcher (a debug helper, a diagnostic tool) ships with silently-swallowed output — exactly the "launcher hides failure" class this suite exists to prevent — undetected.

*Impact scope:* `dsh/Start-DSH.ps1`, `dsh/Start-MissionControl.ps1`.

*Fix path:* Require the redirect on the same logical statement (join continuation lines before matching, or check per-`Start-Process`-call rather than per-file).

---

**TE6 — MAJOR — test-harness correctness.** `Prove-TestsFailClosed.ps1`'s `Copy-Item -Exclude '.git'` does not exclude `.git`.

*Evidence:* `tests/Prove-TestsFailClosed.ps1:78`: `Copy-Item $repo $tmp -Recurse -Force -Exclude '.git'`. This is the well-known PowerShell trap where `-Exclude` is only honored when `-Path` itself is wildcarded. Proven on this machine's actual Windows PowerShell 5.1 (5.1.26100.9168, the same interpreter the scripts target per their own ASCII-only comments): built a test tree with a top-level and a nested `.git`, ran the identical invocation. **Observed:** both `.git` directories, all files, fully present in the destination. **Expected:** `.git` excluded. I also confirmed the "obvious" fix (`-Path "$repo\*"`) only partially works — it excludes a *top-level* `.git` but still lets a *nested* one through, because `-Recurse` doesn't re-apply `-Exclude` at deeper levels.

*Why it matters:* Every one of the 10 mutation runs silently copies the repo's full `.git` (currently 3.1MB/350 files) into a throwaway scratch dir, contrary to what the safety comment ("nothing here touches the working tree") implies about isolation scope. No current test reads `.git` content (G1 explicitly excludes `\.git\`; confirmed no wrong verdict results today), so the present harm is wasted copy time/disk rather than a wrong verdict — but it's a second concrete instance, inside the very tool built to catch "verification claimed but not done," of a claim that was never checked against reality.

*Impact scope:* `tests/Prove-TestsFailClosed.ps1` only; grows worse if the repo's `.git` history grows (per user memory, this exact class of problem has bitten a sibling project via LFS/history bloat).

*Fix path:* `Copy-Item $repo $tmp -Recurse -Force; Remove-Item (Join-Path $tmp '.git') -Recurse -Force` — or use `robocopy $repo $tmp /E /XD .git`, which does honor directory exclusion.

---

**TE7 — MAJOR — missing test / confirmed current regression.** `machines\5070ti.yml` is rotted against the rewritten loader files, and no test touches any non-base machine profile at all.

*Evidence:* `machines/5070ti.yml` declares 16 `replacements:` entries against `dsh/settings.yaml`, `dsh/cordis.patch.yml`, `dsh/Start-DSH.ps1`, `opencode/opencode.json`, and the two loader `.mjs` files. I grepped every one of the 16 `find:` literals against current source. 13 match; 3 do not:
- `machines/5070ti.yml:79` → `"contextLength: [config.contextLength, 131072],"` — 0 matches in `Load-OpenCode-Qwen.mjs`
- `machines/5070ti.yml:85` → `"speculativeDraftMtp: [config.speculativeDraftMtp, true],"` — 0 matches
- `machines/5070ti.yml:89` → `"if (config.contextLength !== 32768) {"` — 0 matches in `Load-Worker-Coder.mjs`

These reference the *old* array-tuple verification shape (`[actual, expected]`) that today's rewritten loaders (the `checks = { contextLength: live?.contextLength === ... }` object pattern, confirmed by direct reading) no longer contain. `scripts/Deploy-ToLive.ps1:234-236` does have a real rot guard (`if (-not $text.Contains($r.find)) { Write-Error ...; exit 1 }`), so a `MACHINE=5070ti` deploy today would abort loudly rather than silently ship broken config — credit where due, that part is well-built. But `CC1` (`tests/Run-Tests.ps1:392-416`), the only test that ever invokes `Deploy-ToLive.ps1`, never sets `$env:MACHINE`, so it only ever exercises the trivial `'halo'` byte-for-byte path (`Deploy-ToLive.ps1:183` gate).

*Why it matters:* This isn't hypothetical — it's the current state, caused by today's own loader rewrite (the fix for the headline defect) not being propagated to the one other machine profile in the repo. Nothing in 26 checks would have caught this when it was introduced, and nothing will catch the next one.

*Impact scope:* The 5070Ti port — a documented, explicitly-supported secondary machine tier with its own bench doc (`docs/ports/tester-5070ti-bench-2026-08-18.md`) — cannot currently be redeployed/refreshed via its profile.

*Fix path:* Add a test that renders every `machines\*.yml` in dry-run/parse mode (loop `Get-ChildItem machines\*.yml`, run the render stage's find/replace logic against current source, assert every anchor is found) — this is cheap and would have caught today's rot immediately.

---

**TE8 — MAJOR — overclaimed generality.** `A5` ("compaction can actually converge, and **scales to every machine profile**") tests exactly three hardcoded window literals, not `machines/*.yml` itself.

*Evidence:* `tests/Run-Tests.ps1:138`: `foreach ($w in 131072, 40448, 32768)`. These happen to cover the two currently-known machines (HALO 131072; 5070Ti's requested 32768 / auto-sized 40448, per `machines/5070ti.yml:14` and `dsh/settings.yaml:84`), so today's result is a correct PASS for the right underlying math — I verified the ratios by hand (131072 window → 2.67:1, well clear of the 4:1 boundary; the historical 8192 value would trip at exactly 4.0, correctly caught via `-ge`, confirmed by the real mutation run). But the list is a literal array with no connection to `machines/*.yml`, the actual source of truth.

*Why it matters:* A third machine profile with any other context window is invisible to this test by construction, while its name and its own comment ("scales to every machine profile") claim otherwise — exactly the "test that can't fail because it isn't testing the general case" pattern this audit was asked to hunt for.

*Impact scope:* Any future `machines\*.yml` addition gets zero compaction-ratio protection unless someone remembers to also edit this hardcoded list.

*Fix path:* Derive the window list from `machines\*.yml` (parse each profile's `contextWindow`/`contextLength` after replacements) rather than hardcoding it, so a new profile is covered automatically.

---

**TE9 — MAJOR — mutation-harness scope.** The "10/10 mutations caught" result covers 10 of the suite's 26 named checks; the other 16 have never been proven to fail closed by anything.

*Evidence:* `tests/Prove-TestsFailClosed.ps1:19-69` defines mutations for exactly `S1, S2, A1, A2, A3, A5, L3, C13, B1, G1` (10 IDs; I ran it for real — `10 historical defects... all 10 mutations caught by their own test`). `tests/Run-Tests.ps1` has 26 named `Test-Case` IDs total (20 static + `V1-V5` + `CC1`, confirmed by running it and counting the PASS lines). The uncovered 16 — `S1b, L1, L2, L4, C14, MC1, B2, B3, R1, R2, V1, V2, V3, V4, V5, CC1` — include the two I independently proved broken above (TE1/V1, TE5/L1) and the one I proved broken by a novel mutation (TE4/L3, which the harness's own S1-style mutation-per-ID design never generated). Separately: the harness always runs the mutant with `-Static` (`Prove-TestsFailClosed.ps1:90`), so even for IDs it does cover, it can say nothing about `V1-V5` or `CC1` regardless.

*Why it matters:* "The suite fails closed" is stated by the harness as a blanket property (`Write-Host "all {0} mutations caught... the suite fails closed"`). What's actually been shown is narrower: 10 specific historical defects, in `-Static` mode, are caught by their named test. That's real and valuable, but it's not the same claim, and the gap between the claim and the evidence is precisely where TE1, TE4, and TE5 live.

*Impact scope:* False confidence in the suite as a whole; the headline "all N mutations caught" line is easy to read as "the suite works," when 62% of its checks (16/26) have zero such proof.

*Fix path:* Add mutation entries for the remaining static checks at minimum (L1's second-unredirected-call case, L3's dead-code-adjacency case, L2, L4, C14, R1, R2, B2, B3, S1b are all cheap to construct), and add a separate (non-`-Static`) mutation pass — even a manual/documented one — for `V1-V5` and `CC1`.

---

**TE10 — MINOR — presence-anywhere checks.** `A1`, `A2`, `A3`, `L2`, `C14`, `R1` assert only that a token or short phrase appears *somewhere* in a target file's raw, comment-inclusive text, not that it appears in the operative location.

*Evidence:* e.g. `tests/Run-Tests.ps1:107-112` (`A1`, matches `maxConcurrentAgents:\s*1\b` anywhere in `dsh/agent-presets/halo-standard/agent.cordis.yml`, no comment-stripping unlike `A5`'s careful `Where-Object { $_ -notmatch '^\s*#' }` at line 132); `tests/Run-Tests.ps1:164-173` (`L2`, `Invoke-WebRequest` and a marker string each just need to appear anywhere in the file, with no check that the one actually gates the other). Not currently exploitable — I checked each target file directly and each has exactly one relevant occurrence today (`agent.cordis.yml` has one `maxConcurrentAgents:`, `cordis.patch.yml` has one `maxConcurrentJobsPerOwner:`, etc.) — so today's PASS is for the right reason.

*Why it matters:* None of these checks would notice a second, differently-configured occurrence added later (e.g., a second workflow-engine row with an uncapped default sitting alongside the correctly-capped one), or a stray comment mentioning the safe value while the real value regressed.

*Fix path:* Where practical, reuse A5's comment-stripping approach and/or anchor to the specific known-good block (id/key), not the whole file.

---

**TE11 — MINOR.** `S2`'s hardcoded-profile-path regex cannot match a Windows username containing a space.

*Evidence:* `tests/Run-Tests.ps1:99`: `'C:\\Users\\[A-Za-z0-9._-]+\\'`. This character class excludes spaces, so `C:\Users\John Doe\...` — a very common real Windows profile-folder shape — would not be flagged. Today's author profile is `scott` (no space), so the check currently passes for the right reason on this machine; the gap is latent, not active.

*Fix path:* Broaden to `'C:\\Users\\[^\\]+\\'`.

---

**TE12 — NIT.** `S2` has no guard against its own source-list extraction coming back empty (unlike `R1`, which explicitly checks `if (-not $names) { return '...' }` at `tests/Run-Tests.ps1:304`). Today `Deploy-ToLive.ps1`'s `src = "..."` regex match yields 13 entries, so this doesn't currently matter, but if that quoting convention ever changed, S2 would silently pass having checked nothing, with no signal that it stopped checking.

---

## What's working

- **The mutation-harness *concept*, where it has coverage, is real and I verified it myself, not just by reading.** I ran `Prove-TestsFailClosed.ps1` against the live repo: all 10 of its defined mutations were genuinely caught by their named test, including the subtle A5 boundary math (I hand-verified the ratio arithmetic independently) and the C13 anchored regex (I confirmed it correctly ignores the legitimate `claimsRunning: !!s.running,` sibling line while catching the real regression).
- **L4** uses the actual PowerShell AST parser (`[System.Management.Automation.Language.Parser]::ParseFile`) for syntax validation — genuine static analysis, not text matching.
- **MC1** actually spawns `node` against `mission-control.mjs` and inspects real stderr for `FATAL`/`EADDRINUSE` — a genuine dynamic check, and correctly placed so it runs even under `-Static`.
- **L3's underlying design intent** (require a real branching condition *and* a real terminating action, not just either token in isolation) is a legitimate, more sophisticated approach than plain substring search, and it did successfully catch its own documented predecessor bug. TE4 shows a different way through it, not that the approach is worthless.
- **`Deploy-ToLive.ps1`'s machine-profile rot guard** (`$text.Contains($r.find)` → loud `exit 1`, `scripts/Deploy-ToLive.ps1:234-236`) is well-built: I confirmed the currently-rotted `machines/5070ti.yml` (TE7) would fail *loudly and safely* at deploy time, not silently ship broken config. The mechanism is sound even though nothing exercises it automatically.
- **G1**'s recursive AGENTS.md scope check correctly excludes `node_modules`/`.git` and checks a real structural property (first 10 lines).
- Every test names the specific historical defect it exists to catch, in its own comment. This made the audit faster and more targeted than an unannotated suite would have — a genuinely good practice even though (as shown above) naming the defect isn't the same as reliably catching it.
- `V2` (as opposed to V1) does correctly read deployed file content for `./vendor/` imports — confirmed via the same mutant I used to break V1.

## What I could not assess

- I did not run `V2-V5` or `CC1` against this machine's real `$env:USERPROFILE\.lmstudio\scripts\` or live ports, to avoid touching state outside the repo beyond what my task explicitly sanctioned (`-Static`). My V1 finding instead rests on a fully isolated synthetic reproduction of V1's exact code, which I'm confident is equivalent evidence, but I did not observe V1-V5's real pass/fail state on this specific deployed machine.
- I did not execute a real (even dry-run) `MACHINE=5070ti` deploy to watch the rot guard fire live; TE7 rests on precise static string comparison (grep of all 16 `find:` literals against current source), which I'm highly confident in but did not watch execute.
- I did not audit the external `@deepseek-ai/dsh-*` plugin packages' actual runtime behavior (e.g., whether `maxConcurrentAgents: 0` truly resolves to CPU count, whether `jobs-local`'s undocumented default really is 10) — those claims live in comments referencing upstream package behavior I can't inspect from this repo.
- I did not check GitHub-side branch protection rules (needs network + repo auth), though this is moot for TE2 since no workflow YAML exists in the tree for any such rule to reference.
- Given the explicit high-value targets in scope (mutation-boundary review, the `Copy-Item` trap, `-Static` blind spots, the five named missing-test scenarios, `-CleanClone`'s real reach), I prioritized depth on those plus what they led me to (V1, L1, L3, the machine-profile rot) over building individual mutants for every one of the remaining untested static checks (`S1b`, `L2`, `L4`, `C14`, `MC1`, `B2`, `B3`, `R1`, `R2`). It's possible one or two of those harbor a similar gap I didn't surface.
