# GauntletGate Full lane — Technical Writer

## Role + severity counts

Blocker 0 / Critical 2 / Major 5 / Minor 0 / Nit 0

## Findings

### TW-1 — USER-MANUAL.md states the pre-incident compaction config as current fact, with a cost figure now off by ~13× — **Critical**

**Evidence:** `docs/USER-MANUAL.md:293-297`:
> "Compaction is the one planned exception: at the 131,072-context brain's compaction settings (**80% trigger / 16% retain / 8,192-token summary cap**), a compaction event costs one deliberate re-prefill, **measured at ~80 s** in production shape (TTFT sequence: 157 s cold → 13 s cached → 80 s post-compaction)."

Repeated in the reference table at `docs/USER-MANUAL.md:516-517`: `Compaction settings | 80% trigger / 16% retain / 8,192-token summary | ...` / `Compaction re-prefill cost | ~80 s | docs/phases/phase4-harden-results.md`.

Both citations trace to `docs/phases/phase4-harden-results.md`, dated **2026-08-17** — measured at the *old* 65,536-token context, before the window was doubled (2026-08-19). The live shipping config is different: `dsh/settings.yaml:85-93` (deployed byte-for-byte to every HALO install) now reads `thresholdRatio: 0.75`, `retainRatio: 0.5`, `maxTokens: 12288`, with the file's own comment at lines 61-77 stating why: *"The stock defaults (threshold 0.8, retain 0.16, summary maxTokens 8192) were sized for a small window. At 131,072 they ask the summarizer to fold ~84,000 tokens into 8,192 — 10:1. It cannot... Measured: 5 consecutive failed compactions in ONE turn, 11.5 / 13.5 / 16.6 / 20.1 minutes each, ~95 minutes of pure treadmill... Achievable in one pass, ~18 min worst case."*

So the manual describes, as current and safe, the *exact* configuration that produced the ~95-minute compaction-failure storm behind the site's own "Honest status" disclosure (`site/index.html:201`: *"unattended, a whole-repo review ran 4 h 41 m and produced nothing"*) — and states a cost 13-17× lower than the retuned worst case actually documented in the fix's own commit (`d5b12c5`). Neither the retuned ratios nor the incident are mentioned anywhere in the manual (grepped: zero hits for `12,288`, `0.75`, `streamIdleTimeout`, `compactionRetries`, `treadmill`).

**Why it matters:** this is the primary "how it works" reference the README explicitly points strangers to for the "deep design specifics." It gives an operator a materially wrong mental model of the single subsystem that has already caused the project's worst production incident, in the direction of *understating* risk.

**Impact scope:** anyone consulting the manual to understand compaction behavior at the shipped 131,072 window, or anyone who copies the manual's cited ratios into a hand-rolled config, reintroduces the exact defect that was just fixed.

**Fix:** update both citations to the retuned values and the ~18-minute worst case, and add one sentence naming the 2026-08-20 incident and the fix, mirroring what the manual already does well elsewhere (e.g., §6's honest "an adversarial audit refuted that" framing).

### TW-2 — CHANGELOG.md is silent on the entire correction wave; the newest entry misrepresents the tree's current state — **Critical**

**Evidence:** `CHANGELOG.md:6` is `## [0.5.0] - 2026-08-20`, with no `[Unreleased]` section anywhere (`grep "^## "` returns exactly 5 bracketed headers, 0.5.0 down to 0.1.0). `git log --merges f5674e8..HEAD` shows **4 merged PRs / 8 commits** since that entry: #38 (5070Ti context override), #41 (compaction/idle-timeout retune, the fix behind TW-1), #43 *"Fix the three defects that made this repo unusable by anyone who downloaded it"*, and #44 *"Disarm the live defects, correct the false public claims, add a test suite that fails closed."*

None of this is in the changelog. Specifically absent: that `git ls-files lmstudio/` returns 3 files with no `vendor/`, so every non-author clone hit `MODULE_NOT_FOUND` — meaning the 0.1.0 entry's own claim, *"Everything below is running, measured, and documented... as a reproducible, source-controlled configuration"* (`CHANGELOG.md:218-222`), was false for the intervening three days, unqualified anywhere in the document (grepped `vendor|MODULE_NOT_FOUND|never worked|could not load|unusable` against the whole file: 0 hits). Also absent: that five subagents queuing on one decode lane produced a 2,396,400-input-token runaway, and that multiple site claims (fan-out speed, compaction continuity, "one screen that tells you the truth") were found false and rewritten the same day.

The gap isn't accidental slack — it's untested. `tests/Run-Tests.ps1:292-297` (test `B3`) asserts only that the site's version pill matches the CHANGELOG's newest entry; both currently say `0.5.0`, so it passes while the tree sits 8 commits past both.

**Why it matters:** for a public repository strangers are downloading right now, the changelog is a primary trust surface — the place a technical evaluator checks "what is the current state of this." It currently omits the single most important fact in the project's history (it never worked for a stranger, across five releases) on the same day that fact was privately corrected everywhere else. "Assess whether the changelog misrepresents the state" — yes, materially.

**Impact scope:** every stranger evaluating the repo via CHANGELOG.md (a very standard diligence step) forms an incorrect, more-favorable picture of project maturity and gets no warning about the autonomy/compaction/concurrency caveats that *are* disclosed on the website.

**Fix:** add an `[Unreleased]` section covering the four PRs, written with the same directness as the 0.1.0-0.5.0 entries (which are otherwise good changelog hygiene — dated, specific, honest about what changed and why). Strengthen B3 to compare against `git describe`/commit count rather than only pill-vs-changelog, so this class of drift can't recur silently.

### TW-3 — USER-MANUAL.md predates both of today's merged PRs: STALLED detection and per-session Stop are undocumented, tab/line counts are stale — **Major**

**Evidence:** the manual's last substantive Mission-Control edit is 2026-08-19 19:33 (`v0.4.0: annotated console screenshots`); PRs #43 and #44 (2026-08-21) both touch `dsh/Start-DSH.ps1`/`dsh/Start-MissionControl.ps1`/`mission-control/mission-control.mjs`, unreflected:

- `docs/USER-MANUAL.md:364-366`: *"a single Node file (**1,308 lines** as of this release)... serving a **five-tab** operator console (**Overview / Models / Sessions / Plugins / System**)"* — omits the Memory tab by name entirely, and the file is now **2,720 lines** (`wc -l mission-control/mission-control.mjs`), not 1,308. Repeated at line 524's reference table.
- Grepped `docs/USER-MANUAL.md` case-insensitively for `stalled|session.cancel|claimsRunning|per-session stop`: **0 hits**. The code (`mission-control/mission-control.mjs:434-440, 1271-1280, 2658`) implements both: STALLED is derived from wall-clock progress and *"outranks every other harness condition"* for the top HARNESS alarm, and a genuine per-session Stop now calls `/api/session.cancel`. The manual's alarm-strip reference table (`line 598`) lists HARNESS-red triggers as *":3080 is down, a plugin failed..., or one is stuck mid-transition >60 s"* — no stalled session, despite that being the code's #1 case. The Sessions-tab section (`lines 681-699`) documents only the Context column; nothing about the STALLED badge or Stop control the site advertises as the fix for *"Mission Control displayed that dead run as healthy"* (`site/index.html:201`).
- `docs/USER-MANUAL.md:792`'s troubleshooting row for *":3080 listening but frozen"* still says **"Kill + relaunch via desktop icon"** — the new launcher's stale-process cleanup (`dsh/Start-DSH.ps1:134-149`, matched against `Test-CockpitServing`'s content-check rather than TCP-listen) now clears exactly that condition automatically on the next double-click. Line 102 still names only `~\.dsh\launcher.log`; the new per-run `~\.dsh\logs\dsh-server-<timestamp>.log`/`.err.log` files (`Start-DSH.ps1:43-44`) aren't mentioned.

**Why it matters:** the manual describes a Mission Control that predates the exact feature the project's own honesty narrative hinges on. A reader following the troubleshooting table does unnecessary manual work; a reader checking "what does the alarm strip watch" doesn't learn about its top-priority condition.

**Impact scope:** every reader of the manual's Mission Control and troubleshooting sections, and anyone using the file-size/tab-count figures as a specificity/trust signal (they're the kind of concrete numbers meant to prove rigor, and here they don't hold).

**Fix:** regenerate the six screenshots (also 2026-08-19, so none show STALLED/Stop either), add STALLED and Stop to the Sessions section and the HARNESS alarm row, update the line/tab counts, update the two stale troubleshooting rows.

### TW-4 — Site's "proven on hardware" claim does not currently hold for one of its three named defects — **Major**

**Evidence:** `site/index.html:201` (identical in `docs/index.html`): *"Those three defects are fixed and the fixes are proven on hardware..."* — referring to the vendored-SDK/loader family, the autonomy-decomposition gap, and Mission Control's dead-run misreport. The Walkthrough lane's isolated-home test (W1, Critical) found the loader's success/failure *reporting* itself still broken at HEAD: `lmstudio/Load-OpenCode-Qwen.mjs:107` wraps its only verification, `execSync("lms ps --json")`, with no try/catch, so any transient CLI failure (an unauthenticated fresh LM Studio CLI is a first-run condition, not a sandbox artifact) makes a *successful* load report as `BRAIN LOAD FAILED TWICE`, triggering a redundant 21 GB reload. This is the same symptom class the commit that added this claim (`9bba0ee`) says it fixed for `getLoadConfig()`'s always-undefined bug — fixed for that trigger, not for `lms ps` itself throwing.

**Why it matters:** this is a specific, checkable public claim ("proven on hardware") made the same day as the correction pass this audit exists to verify, and it is currently false for exactly the class of defect it names.

**Impact scope:** every reader of the honest-status section forms an accurate impression of the SDK/loader problem's *history* but an inaccurate one of its *current* state. Resolves automatically once W1 is fixed — flagged here because the wording itself is a distinct, in-scope claim, not to duplicate the Walkthrough's code-level finding.

**Fix:** none needed beyond fixing W1; if W1 isn't fixed before this ships further, soften "proven on hardware" to name the residual gap explicitly, the same way the site already handles "designed but not yet measured" elsewhere.

### TW-5 — README requires pnpm in the same breath as Node, but the deploy's own named-prerequisite gate — and its regression test — don't check for it — **Major**

**Evidence:** `README.md:72`: *"Install **Node 22+**, **pnpm 11**, and **LM Studio**."* `scripts/Deploy-ToLive.ps1:19-24`'s `$prereqs` array — built, per its own comment at lines 14-18, specifically so *"a missing Node [doesn't surface] 200 lines later as 'No js-yaml install found'"* — checks only `node`, `npm`, `npx`, `lms`. `pnpm` never appears in the script (grepped the whole repo: it's real only in a header comment at `Deploy-ToLive.ps1:9` and in historical/manual prose, never invoked). `docs/phases/phase3-reach-results.md:17` indicates it's a real transitive need: *"profile pnpm has autoInstallPeers off... pnpm 11 installed globally for this,"* i.e. `dsh plugin add` (README step 7) appears to shell out to pnpm internally to install into each profile's `node_modules`.

The regression suite has a matching blind spot: `tests/Run-Tests.ps1:300-308` (`R1`, *"README documents every prerequisite the deploy enforces"*) walks the deploy's `$prereqs` array and asserts each name appears in the README — the correct direction to catch a repeat of the exact bug this whole test file exists to prevent, but it never checks the reverse: that every tool the README *requires* is also *enforced*. Pnpm satisfies "mentioned in README" trivially and the test never notices it's absent from the gate.

**Why it matters:** if pnpm truly gates step 7, a user missing it sails cleanly through steps 1-6 (nothing names it) and only then hits an unexplained failure — the exact "surfaces 200 lines later, misattributed" failure mode this file was rewritten today specifically to eliminate for four other tools.

**Impact scope:** any first-time installer without pnpm already on PATH; I could not verify from this repo alone whether `dsh` genuinely requires it (dsh itself isn't vendored here) — see "could not assess."

**Fix:** add `pnpm` to the `$prereqs` array (or remove it from the README if it's genuinely no longer required — the loader/plugin stages visible in this repo use `npm`, not `pnpm`, so it's worth confirming which is true), and extend `R1` to check both directions.

### TW-6 — The audit document committed alongside today's fixes already misstates its own open-items list — **Major**

**Evidence:** `docs/audits/AUDIT-first-run-and-launchers-2026-08-21.md` was added in commit `608075a` — the *same* commit that edited `README.md` and `scripts/Deploy-ToLive.ps1`. Its §6 "Open items, ranked" (`lines 168-173`) lists five items as unresolved. Checked against the README/script shipped in that identical commit:
- **F4** ("no hardware check before applying the HALO profile") — README step 5 (`README.md:91-101`) now is exactly this check, with a 40 GB budget note and a pointer to `machines/5070ti.yml`.
- **F3** (".ps1 shortcut instructions") — README step 8 (`README.md:111-123`) now gives explicit `powershell.exe -File` targets and calls out the Edit-not-Run trap by name.
- **F5 remainder** ("`lms` CLI bootstrap missing from README step 1") — README step 1 (`README.md:72-78`) now documents `lms.exe bootstrap` explicitly.
- **F6** ("missing Node/npx misreported as a js-yaml problem") — `Deploy-ToLive.ps1:19-30`'s named prereq gate (and `Start-DSH.ps1:86-88`'s `Require-Command`) is precisely this fix, and both were introduced in this same commit.

Only **F8** (deploy-before-plugins step order vs. `insert:` plugin rows in `cordis.patch.yml`) is honestly self-flagged as unverified (`§5.2: "was not reproduced; it needs a genuinely clean machine"`) and remains a real open question — I traced `dsh/cordis.patch.yml:8-19`'s `insert:` rows for `dsh-subagent-codex`/`claude-code`/`acp` and could not determine from this repo alone whether an uninstalled plugin row trips the deploy's own `warn|unmatched|error` compose-validation gate; that needs the clean-machine run the audit itself calls for.

**Why it matters:** this is committed, public documentation of "what's still broken," produced by the same fix pass it ships beside. Four of its five ranked risks are already resolved by content in the identical commit — a future contributor or a later audit trusting this file's status column would misdirect effort re-verifying fixed items, or under-weight the one item (F8) that's genuinely still open.

**Impact scope:** internal/developer-facing, not end-user-facing — but it's committed to the public repo, and this GauntletGate process explicitly depends on prior audit trails being trustworthy, so it's on-point for exactly the "verify from evidence, not from a comment" standard this run is held to.

**Fix:** update §6's status column for F3/F4/F5/F6 to "Fixed" before merge, leaving F8 as the one genuinely open item — or fold the still-open F8 into a live issue instead of a point-in-time audit file if the intent is a durable tracker.

## What's working

- **`site/index.html` and `docs/index.html` are byte-identical**, including their `images/` directories (`diff` and `diff -rq` both report no differences). The explicit "must be identical in substance" bar is met exactly, not approximately.
- **Every performance number on the landing page traces cleanly to a docs/ measurement file, word-for-word.** The full "Measured, not believed" table (181/615 tok/s prefill, 108.6s/31.8s TTFT, 13.4s/0.28s cached TTFT at 8.1×/115×, 26.9/19.0 and 90.9/87.8 tok/s decode, 41s/176s task time, 4.3×) matches `docs/phases/phase2-bench-results.md:10-13` exactly. The 131,072-context claims match `docs/phases/bench-window-131k.md`'s headline numbers, including honestly-flagged caveats (cache-assisted TTFT at depth, the side-load spill that forced a solo-load fallback). This is genuinely disciplined sourcing for a marketing page, not just "traceable" in a technical sense — the docs read like the actual lab notebook.
- **The correction pass itself is real, not cosmetic.** Every specific fix the `608075a` commit message claims for the two landing pages and the README checklist — 5-tab→6-tab, "fan-out" reworded to "one job at a time," the new hardware-check and lms-bootstrap and shortcut-target steps, the Honest Status section's addition — is independently verifiable in the current files. The gap this report identifies is propagation (some surfaces missed), not that the correction didn't happen.
- **The rebuild checklist otherwise tracks the deploy script closely and accurately**: file destinations, the literal PowerShell shortcut-target strings, the "PASS/MISSING" audit framing, and the step-1 prerequisite list (minus pnpm) all match `Deploy-ToLive.ps1`'s real behavior. Step numbering (1-9) is sequential with no gaps or dangling cross-references within the README itself.
- **The mutation-tested suite is a real quality mechanism.** `tests/Prove-TestsFailClosed.ps1` reintroduces ten historical defects and confirms each is caught; the two blind spots I found (B3, R1) are precisely the kind of thing that test-writing catches next, not evidence the effort is hollow.
- **The Known Issues list is consistent** between `README.md:148-153` and the site's buglist (6 items, matching substance).
- **The Honest Status section itself, where it appears, is well-written**: specific, unminimizing ("could not load a model on any machine but the author's"), and linked directly from the top nav on both landing pages rather than left for scroll-and-hope.

## What I could not assess

- Whether `pnpm` is genuinely required by `dsh plugin add` (README step 7) — `dsh` is an external npm package, not vendored in this repo, so I could only infer this from a historical doc's prose (`docs/phases/phase3-reach-results.md:17`), not from source.
- Whether LM Studio's "run as login service" toggle (README step 3) also starts the server immediately in the current session, or only takes effect on next login — this is external-app UI behavior I cannot verify by reading this repo, and it bears on whether README step 9's audit-must-show-PASS instruction has a gap.
- F8 (deploy runs before subagent-plugin install, against `cordis.patch.yml`'s `insert:` rows) — the audit itself flags this as needing a clean-machine reproduction I did not run; I could read the config shape but not the compose-time behavior of the external `dsh` package.
- The raw data behind some phase benchmarks (e.g. `docs/phases/bench-window-131k.md` cites `C:\Users\scott\Desktop\Code\halo-bench-day3\results\window-131k-raw.jsonl`) lives in a sibling directory outside this repository, not in what a stranger clones. The prose reports are detailed and internally consistent enough that I did not treat this as a finding, but I could not verify the underlying raw numbers myself.
- I did not review `docs/Claude-Harness-HALO-Design*.md`, `docs/Codex-Harness-Halo*.md`, or the `docs/experiments/`/`docs/research/` directories for currency — they read as point-in-time design/research records rather than live references, and the task scope named the higher-traffic surfaces specifically.
