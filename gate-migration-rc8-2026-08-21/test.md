# Test Engineer

## Role + severity counts
Blocker 0 / Critical 2 / Major 3 / Minor 2 / Nit 1

## Findings

**TE-1 — Critical — test-coverage-gap**
MIG1 cannot catch an `npx` revert in the two call sites that route the dsh package through a variable instead of a literal string.
- Evidence: `tests\Run-Tests.ps1:337-348` — the check is `if ($line -match 'npx' -and $line -match 'deepseek-ai(/|\\)dsh')`, requiring **both** substrings on the same physical line. `scripts\Deploy-ToLive.ps1:86` (`pnpm dlx $dshPkg web --dump-config 2>&1 | Out-Null`) and `:144` (`$dump = pnpm dlx $dshPkg web --dump-config 2>&1`) reference the package via `$dshPkg` (set once at `:12`), never repeating the literal string `deepseek-ai/dsh` on those lines. Repro: I mechanically replaced `pnpm dlx $dshPkg` → `npx $dshPkg` on those exact two lines and re-ran MIG1's own line-by-line logic against the mutated text — 0 matches, test stays green. (Script: verify-mig-gaps.ps1, output: "MIG1 DOES NOT CATCH THIS".) This mutated text is byte-for-byte what those two lines looked like *before* the migration (confirmed against `migration.diff`), i.e. it reproduces the exact npm-resolver-hang defect this whole migration exists to fix.
- Why it matters: these two call sites are inside `Resolve-JsYamlOrBootstrap` and `Invoke-DumpConfigGate` — the pre-validate and post-validate gates of the **production deploy script**. A partial revert here (e.g. a bad rebase, or someone "cleaning up" what looks like a leftover var) would make the deploy hang indefinitely on this Node 25 box, with MIG1 reporting green the whole time.
- Impact scope: Critical — the regression guard for the migration's core defect is blind in the one script that does real machine rebuilds.
- Fix path: change MIG1's per-file scan to resolve `$dshPkg`/similar variables first (or simply also flag any line matching `\bnpx\b` where the same file defines a `$dshPkg`/dsh-package variable used on that line), or — simpler and more robust — invert the check to assert the opposite: that every `npx ... (\$dshPkg|dsh)` invocation pattern is *absent*, using a value-blind regex like `npx\s+(\$dshPkg\b|"@deepseek-ai)` scoped per file.

**TE-2 — Critical — test-coverage-gap**
MIG2 finds zero version-pin matches in `mission-control.mjs`, so it provides no cross-check on that file at all.
- Evidence: `tests\Run-Tests.ps1:349-358`, regex `'dsh@?[''"]?(0\.\d+\.\d+-rc\.\d+)'` (case-sensitive by default in `[regex]::Matches`). `mission-control\mission-control.mjs:97` is `const DSH_VERSION_PIN = '0.1.1-rc.2';` — uppercase `DSH`, no lowercase `dsh` anywhere near the digits. The only other occurrence, `:2708`, is `'@deepseek-ai/dsh@' + DSH_VERSION_PIN` — concatenation, no literal digits on that line either. Repro: `[regex]::Matches((Get-Content mission-control.mjs -Raw), 'dsh@?[''"]?(0\.\d+\.\d+-rc\.\d+)')` → **0 matches** (verified live, verify-mig-gaps.ps1 output). I then simulated `DSH_VERSION_PIN` regressing to `'0.1.0-rc.7'` while the other 3 files stayed at `0.1.1-rc.2`, ran MIG2's actual aggregate logic across all 4 files: it still reports **one** distinct version (`0.1.1-rc.2`) because mission-control.mjs contributes nothing to the pool — MIG2 stays green.
- Why it matters: `mission-control.mjs` is the file the operator singled out as "the PE-1 RCE surface." MIG2's own name/docstring claims to catch "a partial version bump [that] leaves one file pinned to an older dsh" — it cannot do that for the one file most under scrutiny. A stale `DSH_VERSION_PIN` would make Mission Control validate against a different dsh release than the launcher/deploy actually run, silently.
- Impact scope: Critical — same class of defect as TE-1, in the file explicitly named as the security-sensitive surface.
- Fix path: match the constant by name instead of by adjacency to literal digits, e.g. add a second regex `DSH_VERSION_PIN\s*=\s*['"](0\.\d+\.\d+-rc\.\d+)['"]` for mission-control.mjs specifically (or generalize MIG2 to also resolve simple `const X = 'version'` bindings and follow their usages).

**TE-3 — Major — correctness (new migration code, untested)**
`Resolve-JsYamlOrBootstrap`'s new pnpm-store candidate resolves to a directory that isn't `require()`-able, and nothing tests it.
- Evidence: `scripts\Deploy-ToLive.ps1:78` — `Get-ChildItem "$U\AppData\Local\pnpm\store\*\links\@\js-yaml" -Directory`. Live repro on this machine: the glob resolves to `C:\Users\scott\AppData\Local\pnpm\store\v11\links\@\js-yaml`, which contains only a `4.3.1\` subfolder (the real module is 3 levels deeper, at `...\4.3.1\<hash>\node_modules\js-yaml`). `node -e "require('C:\...\links\@\js-yaml')"` → **`Cannot find module`**. Because the candidate list is filtered with `Test-Path` (true for any existing directory, content notwithstanding) and `Select-Object -First 1`, if this candidate is ever reached first, `$found` is non-empty, the `if (-not $found)` bootstrap-and-retry branch is **skipped entirely**, and the bad path gets handed straight to the YAML validator. `tests\Run-Tests.ps1` has zero references to `JsYaml`/`js-yaml`/`PNPM_MJS` (grep confirmed) — this resolver is entirely untested. On this box the bug is currently masked only because candidate 1 (`$U\.dsh\profiles\node_modules\js-yaml`) already exists and wins first.
- Why it matters: this is exactly the failure class the surrounding comment warns about ("a missing Node surfaced 200 lines later as 'No js-yaml install found'... instead of the actual missing item") — reintroduced by the migration's own new fallback, on precisely the fresh/non-halo-machine onboarding path the code exists to serve. (The second new candidate, the dlx-cache glob at `:79`, is comparatively harmless — it matched nothing on this real box and fails safe by falling through.)
- Impact scope: Major — narrow but real; live-reproduced, not hypothetical; affects the pre-validate stage of a first deploy to a new machine profile.
- Fix path: point the glob at the actual package directory (`...\js-yaml\*\*\node_modules\js-yaml`, `-Directory`, then verify a `package.json` exists before accepting), or drop the store-glob entirely and rely on the existing bootstrap-and-retry (which already works, since `.dsh\profiles\node_modules\js-yaml` is what dsh itself populates).

**TE-4 — Major — stale public claim, untested**
Both public surfaces still show the architecture diagram labelling the cockpit "pinned 0.1.0-rc.7," unchanged by the migration.
- Evidence: `site\index.html:121` and `docs\index.html:121` (identical text, embedded SVG): `pinned 0.1.0-rc.7 · halo-standard preset`. Confirmed via grep this is the only occurrence in each file. B1 (`tests\Run-Tests.ps1:285-303`) only checks a fixed list of banned phrases that doesn't include this. B2/B3 only compare the `<span class="pill">` value (a *project* version, `v0.5.0` — unrelated to the dsh pin) between the two pages and against CHANGELOG — they never look at this diagram text at all.
- Why it matters: this is the single most visible, most-inspected element on the two public pages (an architecture diagram a technical visitor reads carefully), stating the actual current dsh pin incorrectly. No existing or planned test touches it.
- Impact scope: Major — visible, current-tense, factually wrong, on the flagship public surface; not a functional or security defect.
- Fix path: update both diagrams to `0.1.1-rc.2`; add a B-series check (or extend MIG2) that greps `site\index.html`/`docs\index.html` for any `0\.\d+\.\d+-rc\.\d+` and asserts it matches the live functional-file pin.

**TE-5 — Major — test-methodology gap**
`Prove-TestsFailClosed.ps1`'s own MIG1/MIG2 mutations both target `scripts\Sync-FromLive.ps1` — the one file where neither blind spot (TE-1, TE-2) exists — so "all 18 mutations caught" gives false confidence about exactly the two areas that matter most.
- Evidence: `tests\Prove-TestsFailClosed.ps1:72-80` — the MIG1 `from`/`to` pair and the MIG2 `from`/`to` pair are both scoped to `scripts\Sync-FromLive.ps1`, which uses the literal string `"@deepseek-ai/dsh@0.1.1-rc.2"` directly (no mediating variable) — the one shape both bugs above don't affect. I ran the harness in full (`powershell -File tests\Prove-TestsFailClosed.ps1`, 34s, exit 0): `CAUGHT [MIG1]` and `CAUGHT [MIG2]` — true, but neither run ever exercises `Deploy-ToLive.ps1`'s `$dshPkg` lines or `mission-control.mjs`'s `DSH_VERSION_PIN`.
- Why it matters: a green "fails-closed" report reads as "the migration tests are adversarially proven end-to-end." They are not, for the two files this finding and TE-1/TE-2 concern.
- Impact scope: Major — undermines the specific guarantee this harness exists to provide.
- Fix path: add two more mutation entries — one reverting `Deploy-ToLive.ps1:86` or `:144` to `npx $dshPkg`, one regressing `mission-control.mjs:97`'s `DSH_VERSION_PIN` — expect both to be MISSED until TE-1/TE-2 are fixed, then CAUGHT afterward.

**TE-6 — Minor — coverage gap + confirmed real violation**
`scripts\Sync-FromLive.ps1` — one of the four migration-touched files — is absent from L4's PS-5.1-parse/ASCII-only file list, and it does in fact contain non-ASCII characters.
- Evidence: `tests\Run-Tests.ps1:226` lists only `'dsh\Start-DSH.ps1', 'dsh\Start-MissionControl.ps1', 'scripts\Deploy-ToLive.ps1', 'tests\Run-Tests.ps1'` for L4 — `scripts\Sync-FromLive.ps1` is missing. Direct check: `scripts\Sync-FromLive.ps1:9` and `:23` each contain an em-dash (U+2014) inside a `#` comment, file has no BOM (first 3 bytes `23 20 50...` = `"# P"`, not `EF BB BF`). This is exactly the failure class Run-Tests.ps1's own header comment warns about: *"ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation."*
- Why it matters: real, current, verifiable violation of the project's stated invariant, in a migration-relevant file, invisible to the suite. Caveat: running the same `[System.Management.Automation.Language.Parser]::ParseFile` API L4 uses directly against this file reports no parse errors today — so I could not prove this currently breaks execution, only that the stated policy is violated and unguarded.
- Impact scope: Minor.
- Fix path: add `'scripts\Sync-FromLive.ps1'` to L4's file list; replace both em-dashes with plain hyphens.

**TE-7 — Minor — stale doc, untested**
`docs\USER-MANUAL.md:537` still reads "Cold boot after a reboot takes 1–3 minutes (**npx** + 21 GB model)," describing current behavior inaccurately post-migration.
- Evidence: line 537, current tense, unqualified. MIG1 doesn't scan docs; B1's file list is `site\index.html`, `docs\index.html`, `README.md` only — `docs\USER-MANUAL.md` is outside every existing claim-consistency check. (By contrast, `docs\USER-MANUAL.md:305-307`'s rc.7 mention is honestly self-flagged as "re-verification... pending" — not a false claim, not counted here.)
- Impact scope: Minor.
- Fix path: change "npx" → "pnpm dlx" on that line; consider adding `docs\USER-MANUAL.md` to a doc-consistency test.

**TE-8 — Nit — dead code**
`mission-control.mjs`'s `EXE` dict still resolves an `npx` executable that is never called.
- Evidence: `mission-control\mission-control.mjs:111` — `npx: resolveExe('npx'),`. Grep for `EXE.npx`/`EXE['npx']`/`EXE["npx"]` across the file: 0 matches.
- Impact scope: Nit — harmless, but signals the migration cleanup wasn't fully swept.
- Fix path: delete the `npx:` line from `EXE`.

## What's working

- **The full suite is green and accurately reported.** `powershell -File tests\Run-Tests.ps1` (no flags): **33 passed, 0 failed, 0 skipped**, exit 0 (28 static + V1-V5 live). The claim "33 tests pass" is exactly right.
- **The mutation harness genuinely fails closed for what it tests.** `powershell -File tests\Prove-TestsFailClosed.ps1`: **all 18 mutations CAUGHT by their own test**, exit 0, ~34s. The TE6 robocopy `.git`-exclude fix works correctly — no error, no leaked `.git` observed across 18 fresh scratch copies.
- **MIG3's negative lookahead is sound.** Traced `Start-Process[^\r\n]*\s(pnpm)(?!\.cmd)\b` by hand and confirmed by the mutation run: it correctly passes on `pnpm.cmd` and correctly fires on bare `pnpm` (`Start-DSH.ps1:192`), because both tokens sit on one physical line.
- **I independently, live-verified the one claim that had zero automated coverage and mattered most.** I fetched Mission Control's action token from the running page (`http://127.0.0.1:3090/`) and POSTed directly to `/api/validate-config`: **HTTP 200, `{"ok":true,"warnings":[]}` in 2.58s.** This proves, end-to-end on this real Node 25 box, that `PNPM_MJS` resolves, `safeExecFile('node', [PNPM_MJS, 'dlx', ...])` runs shell-free, and dsh's config composes clean — exactly the "MC runs pnpm via node+pnpm.mjs shell-free" claim, currently true, currently unguarded by any test (see TE-2, TE-5).
- **The environment facts check out.** `node --version` → v25.9.0 (genuinely Node 25, as claimed); `pnpm --version` → 11.22.0; `pnpm.cmd` exists at the expected path; `PNPM_MJS` resolves to a real file on disk; `node --check mission-control.mjs` → clean syntax.
- **SEC1/SEC2 are real, not cosmetic.** Both caught their mutations (`shell:true` reintroduction, auth-check removal) in the same run.

## What I could not assess

- I did not run `tests\Run-Tests.ps1 -CleanClone` (the CC1 fresh-clone dry-run deploy) — it spawns a real `Deploy-ToLive.ps1 -DryRun` from a temp git clone, which is heavier and outside what I judged necessary once the static+live 33/33 and the 18/18 mutation proof were in hand. Its interaction with the migration (e.g., whether a truly clean clone's `pnpm dlx` cold path behaves as documented) is unverified by me.
- I did not exercise a genuinely **cold** `pnpm dlx` (empty dlx cache) — my live validate-config call ran warm (2.58s), consistent with a populated cache. The 300s cold-path timeout and "~190 packages" figure in `Start-DSH.ps1`/`mission-control.mjs` comments are unverified.
- I did not adversarially re-derive the pre-existing (non-migration) tests — S1/S1b/S2, A1-A5, C13/C14, SEC1/2, W1T/PE2T/W2T, G1 — beyond confirming they currently pass and that Prove-TestsFailClosed's mutations for them are genuinely caught. My adversarial focus, per the assignment, was MIG1/MIG2/MIG3 and the fail-closed harness.
- The "172 plugins compose with 0 failures and all subagent providers active" and "the stale-process regex matches the 3 pnpm-tree processes and excludes dump-config/plugin/MC" claims are outside what the test suite covers (no test asserts either) — I did not independently reproduce them; that's Deploy/Runtime-engineer territory. My one live signal (`ok:true, warnings:[]` from `/api/validate-config`) is consistent with clean composition but doesn't confirm the plugin count.
- For TE-6, I could not confirm whether the real `powershell.exe 5.1` console host's file-decoding path is identical to the `[System.Management.Automation.Language.Parser]::ParseFile` API L4 uses as its proxy — I can state the ASCII violation is real and unguarded, not that it necessarily breaks execution under true PS 5.1.
