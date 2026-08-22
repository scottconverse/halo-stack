# Technical Writer

## Role + severity counts

**Role:** Technical Writer — accuracy/honesty of the doc changes (README.md, docs/USER-MANUAL.md, CHANGELOG.md, design docs, and every operational surface a repo-wide grep for `rc.7`/`npx` touches).

Blocker 0 / Critical 0 / Major 2 / Minor 6 / Nit 2

**Headline verdict:** The migration's own nine changed files (README.md, docs/USER-MANUAL.md, CHANGELOG.md, dsh/Start-DSH.ps1, mission-control/mission-control.mjs, scripts/Deploy-ToLive.ps1, scripts/Sync-FromLive.ps1, tests/Run-Tests.ps1, tests/Prove-TestsFailClosed.ps1) were updated thoroughly and — where I could check — accurately. But the task's own bar ("nothing operational still says npx or rc.7") is repo-wide, not file-list-scoped, and a broader sweep finds seven more operational surfaces the migration didn't touch: the public landing page (both copies), the pin-record evidence file the manual cites as proof, an active self-audit skill, two deployed AGENTS.md prompt files other agents read as instructions, and a launcher log string. None are Critical — the core install/run flow documented in README works and is internally consistent — but "0 Minor / 0 Nit" is not yet true.

## Findings

### TW-1 — Major — doc-accuracy (public surface)
**Public landing page still says "pinned rc.7," duplicated in two byte-identical files.**

Evidence:
- `site/index.html:104` — `<h3><em>The cockpit</em>DeepSeek Harness · pinned rc.7</h3>`
- `site/index.html:121` — `pinned 0.1.0-rc.7 · halo-standard preset` (inside the inline architecture SVG)
- `docs/index.html:104` and `:121` — identical text. `diff site/index.html docs/index.html` returns **zero differences** — the two files are byte-for-byte the same, so the staleness exists in both copies of whichever one GitHub Pages actually serves at the README's linked URL (`https://scottconverse.github.io/halo-stack/`).
- Neither file was touched anywhere in `git diff master..HEAD` — confirmed by file list (9 files, no `index.html`).
- Confirmed **not caught by the existing test suite**: `tests/Run-Tests.ps1` `B1` (line 285) only checks a fixed list of banned overclaim phrases (e.g. "Frontier-class," "fan-out at 4.3") unrelated to version pins; `B2`/`B3` (lines 304, 311) only compare the *repo release* version pill (`v0.1.0`/`v0.5.0`-style) between the two files and against CHANGELOG's top bracketed entry — a completely different number from the dsh harness pin. I ran the full suite myself (33/33 pass) and none of these exercise this text.

Observed: "pinned rc.7" / "pinned 0.1.0-rc.7". Expected: "pinned 0.1.1-rc.2" (what every other current operational doc, and the live stack, actually runs).

Why it matters: this is literally the page README calls "**Landing page**" — a new visitor's first external touchpoint states the exact fact this migration just changed, and states it wrong, in two places, contradicting README's own headline two lines below the link.

Impact scope: Major — visible, public, directly contradicts the subject of this migration, but doesn't block the install flow (a new user follows the README checklist, not the landing page, to install).

Fix path: Update both spots in both files to `0.1.1-rc.2`. Longer-term: stop hand-duplicating `site/index.html`/`docs/index.html`, or add a `B4` test asserting the dsh-pin text on both public surfaces matches the pin used elsewhere (e.g. cross-check against `mission-control.mjs`'s `DSH_VERSION_PIN` or the README pin) the same way `B2` already guards the release-version pill.

### TW-2 — Major — doc-accuracy (evidence integrity)
**`docs/phases/pin-record.txt` — the file USER-MANUAL cites by name as the pin's proof — was never updated.**

Evidence: `docs/phases/pin-record.txt:1-6`, unchanged by this migration:
```
DeepSeek Harness Phase 1 pin record — 2026-08-17T14:29:54
package:   @deepseek-ai/dsh@0.1.0-rc.7
tarball:   https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.7.tgz
integrity: sha512-ZceDCJ8FAywih+USW/OMk9jEhunlvJBGEz4kqrhau23hPzbciOazZrywH0nBRsaalSeAJ1JGBmjtw4OSjToStw==
```
`docs/USER-MANUAL.md:525` (updated by this migration) points at it as the authoritative evidence: `| Harness pin | \`0.1.1-rc.2\` | \`docs/phases/pin-record.txt\` |`.

Observed vs expected: the manual's proof-index row claims `0.1.1-rc.2`; the cited proof file still records `0.1.0-rc.7` with that version's own tarball URL, integrity hash, and shasum, timestamped 2026-08-17 ("Phase 1").

Why it matters: this manual's whole design (per its own CHANGELOG entry) is "what it is, why it was chosen... and **where the proof lives**." For this one row, the proof a reader is pointed to contradicts the claim. It's also a supply-chain-adjacent artifact — a stale, unlabeled integrity hash next to a claim of a different installed version is exactly the kind of gap the project's own telemetry-audit discipline elsewhere is careful to avoid.

Impact scope: Major — undermines the manual's core "verify me" mechanism for the specific fact this migration changed; not exploitable, nothing blocked.

Fix path: append a new dated block for `@deepseek-ai/dsh@0.1.1-rc.2` (`npm view @deepseek-ai/dsh@0.1.1-rc.2 dist.tarball dist.integrity dist.shasum`, or pull from pnpm's resolved store), keeping the rc.7 block as history rather than overwriting it.

### TW-3 — Minor — doc-consistency + process risk
**USER-MANUAL's known-bug language is stale at the audited commit (bb0f782) — and the fix that exists sits uncommitted.**

Evidence — at `HEAD` (`git show HEAD:docs/USER-MANUAL.md`), four spots still read as flat, unqualified rc.7 claims with no hedge, even though the same document's headline/kernel/pin-table sections (correctly updated by this diff) already say `0.1.1-rc.2`:
- `git show HEAD:docs/USER-MANUAL.md` line 303: *"**(f) Five known rc.7 Windows bugs and their workarounds** are already listed in the README..."* (no caveat)
- similarly at the "New session" bullet, the idle-sessions paragraph, and the troubleshooting-table row (all say bare "known rc.7 bug").

But: `git status --short` shows ` M docs/USER-MANUAL.md` — **the working tree has an uncommitted fix already applied**, verified via `git diff HEAD -- docs/USER-MANUAL.md`, touching all four spots. Currently on disk (not yet committed):
- `docs/USER-MANUAL.md:303-307`: *"**(f) Five known Windows bugs and their workarounds** are already listed... **These were verified on `0.1.0-rc.7`; re-verification against the current `0.1.1-rc.2` pin is pending (2026-08-21 migration) — some may already be fixed upstream. The workarounds are harmless if a bug is gone, so they stay documented until each is re-checked live.**"*
- `docs/USER-MANUAL.md:546`: *"not C-Drive — known Windows bug, verified on rc.7: drive roots never bind"*
- `docs/USER-MANUAL.md:706`: *"a known Windows bug (verified on rc.7) and cannot bind a workspace at all"*
- `docs/USER-MANUAL.md:794`: *"Use Desktop-Code (known bug, verified on rc.7; permissions unaffected)"*

This is genuinely good, honest documentation — exactly the right pattern for a bug list surviving a version bump. But it is **not part of the migration commit under audit**: if it never gets committed, the shipped artifact is the unhedged, self-contradicting version above, and the fix is at risk of being silently lost.

Why it matters: two distinct problems — (a) at the literal audited SHA, one document asserts both "pinned 0.1.1-rc.2" and "known rc.7 bug" about the same subsystem with no reconciling text; (b) work that already fixes this is sitting outside version control.

Impact scope: Minor (the correct fix already exists; risk is process, not content, once committed).

Fix path: `git add docs/USER-MANUAL.md && git commit` — fold these four hedges into this migration (or a same-day fast-follow) rather than leaving them uncommitted.

### TW-4 — Minor — doc-consistency
**README's "Known rc.7 Windows issues" header carries no re-verification caveat, unlike (the fixed, uncommitted) USER-MANUAL.**

Evidence: `README.md:151` — `## Known rc.7 Windows issues (worked around in these configs)` — untouched by this migration (confirmed: not present in `git diff master..HEAD -- README.md`), immediately followed by six numbered items with no hedge, in the same document whose line 12 says `dsh` pinned `0.1.1-rc.2`.

Why it matters: README is the first document a new user reads (it's the step-by-step install checklist). It should not carry a *weaker* honesty standard on this exact question than the deep-dive manual once TW-3 is committed — right now, before TW-3 lands, neither document hedges this at all.

Impact scope: Minor — content is likely still valid (author's own reasoning: workarounds are harmless if a bug is already fixed), but the missing caveat is a real inconsistency the task specifically asked me to check for.

Fix path: one sentence on the header or its lead-in, e.g. "(verified on 0.1.0-rc.7; re-verification against 0.1.1-rc.2 is pending — see USER-MANUAL §4(f))," copied from TW-3's language once committed.

### TW-5 — Minor — doc-accuracy (active tooling)
**The `delta-scan-halo` skill and its source prompt still baseline on rc.7 — the very thing this migration should have advanced.**

Evidence:
- `dsh/skills/delta-scan-halo/SKILL.md:3` (frontmatter, `user-invocable: true`): *"Audit the HALO stack's upstream for changes worth acting on — harness releases **past rc.7**..."*
- `dsh/skills/delta-scan-halo/SKILL.md:29-34`: *"Cockpit: DeepSeek Harness `dsh` pinned **0.1.0-rc.7**"*, *"Known rc.7 Windows bugs to check for upstream fixes..."*
- `dsh/skills/delta-scan-halo/SKILL.md:50, 78`: *"anything newer than dsh-v0.1.0-rc.7?"*, *"ACTIONABLE = ... a dsh release past rc.7"*
- `docs/HALO-Stack-Monitor-Prompt.md:30, 33-35, 49-51, 73-75` — near-identical text; this is clearly the skill's authored source, not a separate historical record.

Why it matters: README (line 148-149) says *"The `/delta-scan-halo` skill re-checks telemetry defaults on every future release before any re-pin."* This migration **is** a re-pin the skill exists to police, yet the skill's own baseline wasn't advanced by it — its next run would reason from "is anything newer than rc.7 out yet?" when 0.1.1-rc.2 is already installed and the real open question is "is anything newer than **0.1.1-rc.2** out yet?"

Impact scope: Minor — no live defect, but the tool meant to catch exactly this class of drift is itself drifted.

Fix path: bump the pin references in both files to `0.1.1-rc.2` and reframe the "five known bugs" re-check list to match TW-3/TW-4's pending-verification status.

### TW-6 — Minor — doc-accuracy (deployed agent prompt)
**Deployed AGENTS.md files still tell other agent sessions they're on rc.7.**

Evidence:
- `workspace/AGENTS.md:7`: *"You are running inside the HALO stack: DeepSeek Harness (pinned 0.1.0-rc.7)..."*
- `workspace/AGENTS.md:17-18, 23-26`: *"known rc.7 bug"*, *"Known rc.7 Windows bugs..."*
- `machines/files/5070ti/AGENTS.md:7, 18, 25-28` — same pattern for the 5070Ti profile.
- Neither file appears in `git diff master..HEAD --stat` — untouched by the migration.

Why it matters: per this repo's own CHANGELOG `[0.5.0]` entry, a deployed `AGENTS.md` in `~\Desktop\Code` is read as an **operating prompt** by any Codex/Claude Code session working there — that release exists specifically because a stale fact in this file once caused a running session to believe wrong things about its own machine. This is the same failure class recurring in miniature (a wrong version fact, not a wrong hardware fact — lower blast radius, same root cause: a deployed prompt file the migration didn't touch).

Impact scope: Minor — informational staleness only in this instance, but matches a pattern this project has already treated as serious once.

Fix path: update the pin in both machine-profile sources and redeploy via `scripts\Deploy-ToLive.ps1`, using the `files:`/`baseSha256` swap mechanism `machines/README.md` already documents for exactly this kind of edit.

### TW-7 — Minor — doc-accuracy + recurring UX gap
**The launcher's dead-server log message is stale (rc.7) on top of a UX gap already flagged pre-migration and still open.**

Evidence: `dsh/Start-DSH.ps1:227`:
```
if ($listening) { "  Port is held but the page does not answer - wedged server (known rc.7 defect with sessions >1MB), or a different app owns 3080." | Add-Content $log }
```
This exact line was already flagged in the prior walkthrough gate — `gate-halo-stack-2026-08-21/02-ux.md:132-140`, finding #9 (Minor, "Failure-message copy is uneven in actionability"): *"A newcomer who gets the... 'wedged server' message... cannot [self-serve], without already knowing what `rc.7`, `>1MB sessions`... mean."* That report predates this migration (commit `608075a`, 2026-08-21 02:02, vs. migration commit `bb0f782`, 2026-08-21 12:01 — same day, ~10 hours earlier).

Why it matters: this string is the first thing an operator reads in `~\.dsh\launcher.log` on a failed cold start — worst-case first-run moment — and it now states "known rc.7 defect" as flat fact while USER-MANUAL (once TW-3 is committed) admits this is unverified against the actual running version, 0.1.1-rc.2. The migration had a natural opportunity to fix the pre-flagged jargon issue while touching this exact function (it did touch surrounding lines — the 180s→300s timeout change is two lines above) and didn't.

Impact scope: Minor — doesn't block launch (the HTTP-serving check below it is what actually gates the browser open), but degrades first-run self-service, twice over now.

Fix path: reword to version-neutral and actionable, matching the pattern already used two lines earlier in the same file for the `lms` prerequisite check, e.g.: *"wedged server — a known Windows deadlock with large session logs on some dsh builds (unverified on 0.1.1-rc.2); try launching again, or clear `~\.dsh\sessions\` if it recurs."*

### TW-8 — Minor — test-coverage gap (CHANGELOG claim accuracy)
**`MIG2` doesn't actually check Mission Control's version pin, despite the CHANGELOG's claim.**

CHANGELOG (`CHANGELOG.md:26`) states: *"Tests MIG1/MIG2/MIG3 guard the mechanism."* `MIG2` (`tests/Run-Tests.ps1:349`) is titled "the dsh version pin is identical across every functional file" and scans four files including `mission-control\mission-control.mjs`, using the regex `'dsh@?[''"]?(0\.\d+\.\d+-rc\.\d+)'` against `Get-Content -Raw`.

Evidence — I simulated this exact regex against the live file (`mission-control/mission-control.mjs`) and got **zero matches**:
```
$pattern = 'dsh@?[''"]?(0\.\d+\.\d+-rc\.\d+)'
[regex]::Matches($text, $pattern).Count   # => 0
```
Reason: the constant is declared at `mission-control/mission-control.mjs:97` — `const DSH_VERSION_PIN = '0.1.1-rc.2';` — where "dsh" isn't immediately adjacent to the version digits (`_VERSION_PIN = '` sits between them, more than the regex's one-optional-char tolerance). Its only other use, at `mission-control/mission-control.mjs:2708`, is a string concatenation (`'@deepseek-ai/dsh@' + DSH_VERSION_PIN`), which also has no literal version text on that line.

Why it matters: `MIG2` currently reports PASS only because the other 3 files (`Start-DSH.ps1`, `Deploy-ToLive.ps1`, `Sync-FromLive.ps1`) agree with each other — Mission Control's own pin is invisible to it. I ran the full suite myself and confirmed `MIG2` currently passes (33/33 overall), which is correct today (MC's actual value, `0.1.1-rc.2`, is right) — but a future typo in `DSH_VERSION_PIN` alone would ship silently green, contrary to what the test's name and the CHANGELOG's summary both promise.

Impact scope: Minor — latent gap, not a live defect (verified MC's current value is correct).

Fix path: add a second pattern targeting the declaration directly, e.g. `DSH_VERSION_PIN\s*=\s*['"]([\d.]+-rc\.\d+)['"]`, and fold its match into the same `$pins` set `MIG2` already builds.

### TW-9 — Nit — dead code
**Leftover unused `npx` resolver in Mission Control.**

Evidence: `mission-control/mission-control.mjs:111` — `npx: resolveExe('npx'),` inside the `EXE` lookup table. Grepped for `EXE.npx` across the whole file: zero other references.

Fix path: delete the line as part of the pnpm cutover — harmless today, but works against "nothing operational still says npx."

### TW-10 — Nit — pre-existing (not introduced by this migration)
**"Five known bugs" is counted inconsistently across docs.**

`README.md:151-158` lists **six** numbered items (including Chrome auto-translate); `docs/USER-MANUAL.md:303`, `workspace/AGENTS.md:23-26`, and `dsh/skills/delta-scan-halo/SKILL.md:3` all say "**five**," with slightly different membership (e.g., whether drive-root-workspace or subagent-plugin-per-profile counts among the five). Confirmed via `git show master:...` that this predates the migration — flagging only because the task's grep sweep surfaced it and the operator's bar is 0 Nit.

Fix path: pick one canonical five- (or six-) item enumeration and reference it by number everywhere instead of re-describing membership in prose in four places.

## What's working

- **README.md's four migration touch-points are complete and accurate**, verified against the actual diff line-by-line: the intro tagline, the expanded step-1 pnpm rationale (with real measured numbers — "~50 s," "npm install never completes, --dry-run included"), the step-4 bootstrap command, and the deploy script's printed subagent-plugin install line all correctly say `0.1.1-rc.2` / `pnpm dlx`.
- **Both USER-MANUAL.md mermaid diagrams are fully clean** — I grepped every mermaid fence in the file for `npx`/`rc.7`/`rc7` and found zero remaining hits; the architecture diagram's pin label and the launcher flowchart's `"Start harness (pnpm dlx, pinned)"` node were both correctly updated.
- **USER-MANUAL.md's proof-index table row, kernel-section heading, and "upgrading the harness" runbook step** all correctly bumped to `0.1.1-rc.2`.
- **The uncommitted USER-MANUAL fix (TW-3) is genuinely good writing** — "verified on 0.1.0-rc.7; re-verification against the current 0.1.1-rc.2 pin is pending... workarounds are harmless if a bug is gone" is exactly the right way to carry a bug list across a version bump without false confidence or discarding real information. Worth committing, then reusing verbatim in README/AGENTS.md/delta-scan-halo.
- **CHANGELOG's `[Unreleased]` entry is accurate** — every specific, checkable claim in it (which 4 files moved to pnpm, the two named Windows-specific gotchas — `pnpm.cmd` vs `pnpm.ps1`, and the CVE-2024-27980 `.cmd`-spawn-via-node workaround — and the two named test IDs) verified true against the real code diff.
- **The 33-test suite runs clean end to end** — I ran it myself: `33 passed, 0 failed, 0 skipped`, including all three new `MIG` tests and all five live-machine checks, matching the task brief exactly.
- **Live services independently confirmed**: `curl` to `http://127.0.0.1:3080` → `200`, `http://127.0.0.1:3090` → `200`.
- **Mission Control's own live status API is internally consistent** — `mission-control.mjs:895` exposes `dshVersionPin: DSH_VERSION_PIN` dynamically from the single constant at line 97 (correctly `0.1.1-rc.2`); grepped the whole file for both version literals and found exactly one occurrence of either, at the correct value. The problem is in static docs/prompts elsewhere, not in this file's own runtime behavior.
- **Design docs are correctly treated as frozen history**, and this is a real, deliberate distinction, not an oversight: `docs/Claude-Harness-HALO-Design.md`/`-v2.md` (+ their `.html` exports) are explicitly dated ("Design date: August 17, 2026") and status-stamped ("Harness not yet installed"); README's own Layout table names them as historical design records. Their untouched "rc.7" text is appropriate.
- **`docs/audits/AUDIT-first-run-and-launchers-2026-08-21.md` and `gate-halo-stack-2026-08-21/`** are legitimately pre-migration audit records — committed `608075a` at 02:02, ten hours before the migration commit `bb0f782` at 12:01 the same day — correctly archival, not stale operational docs.

## What I could not assess

- Did not execute the full 18-mutation `tests/Prove-TestsFailClosed.ps1` proof run (time cost, and squarely the QA lane's territory). I confirmed the mutation count (18, by grep) and independently verified `MIG1`–`MIG3`'s actual coverage by direct inspection and a live regex simulation instead — which is how TW-8 was found.
- Did not perform a live external fetch of `https://scottconverse.github.io/halo-stack/` to 100%-confirm which file GitHub Pages actually serves. I inferred `docs/index.html` is the live source from README's link, the byte-identical match with `site/index.html`, and GitHub Pages' common `/docs`-folder convention — but didn't remove all doubt with an external request, and either way both copies are stale.
- Did not re-run `npm i -g pnpm` from a clean state to test README's exact instruction on a blank machine — pnpm 11.22.0 is already installed and demonstrably working here (it's what's serving the live cockpit); a redundant reinstall wouldn't add evidence while touching global state on a machine the operator is actively using.
- Did not verify the deeper engineering claim inside `dsh/overlays/*.yml` comments (whether Cordis's `isolate` field is still "present and wired" the same way in `0.1.1-rc.2`'s package tree as it was confirmed in `0.1.0-rc.7`'s) — that's an Engineering-lane question about the new package's internals, not a documentation-consistency one; the comment reads as a defensible point-in-time verification note either way.
- Did not independently reproduce the CHANGELOG's specific runtime figures ("172 plugins compose with 0 failures," "reuse path spawns nothing," "all subagent providers active") — I corroborated only the two live-endpoint HTTP-200 claims myself via curl; the rest sit in Engineering/QA's verification scope.
