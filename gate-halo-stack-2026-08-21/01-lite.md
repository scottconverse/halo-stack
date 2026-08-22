# GauntletGate — Lite lane (feeder)

**Slice under review:** the 3 PRs merged today, `v0.5.0..master` = 8 commits,
22 files, +1414 / −102.

## TL;DR

**Ship-with-caveats.** The code changes are sound and genuinely verified — but the
*documentation surfaces have not moved with them*, and the changelog now
misrepresents what master contains.

## Findings

### L-1 — CHANGELOG's newest entry is the release that shipped the defects — **Major**

`CHANGELOG.md:6` is `## [0.5.0] - 2026-08-20`. Master is **8 commits** past that tag,
and those commits fix defects v0.5.0 shipped with — including a repository that could
not load a model on any machine but the author's.

Anyone reading the changelog concludes 0.5.0 is the state of the tree. It is not.
There is no `[Unreleased]` section.

**Compounding:** the new test `B3` asserts "the site version pill matches the newest
CHANGELOG entry". Both say 0.5.0, so it passes — while the tree is 8 commits beyond
both. The test cannot detect this class of staleness at all.

**Fix:** add an `[Unreleased]` section listing today's three PRs, and strengthen B3 to
compare against `git describe` rather than only pill-vs-changelog.

### L-2 — USER-MANUAL describes launcher behaviour that no longer exists — **Major**

Verified by grep against `docs/USER-MANUAL.md`:

| New behaviour | Mentions in the manual |
|---|---|
| per-run server logs `~\.dsh\logs\dsh-server-*.log` | **0** |
| STALLED session state | **0** |
| per-session stop control | **0** |

Worse than absence — line 789 is now actively wrong. Its troubleshooting row for
*":3080 listening but frozen"* says **"Kill + relaunch via desktop icon"**. The
launcher now *detects* that exact condition (identity-checked HTTP readiness) and
clears it automatically. The manual sends the user to do by hand what the product now
does for them, and offers no hint that the log location changed.

`docs/USER-MANUAL.md:102` still says failures land in `~\.dsh\launcher.log` — true but
now incomplete; the server's own output goes to a different, timestamped file.

### L-3 — No retention policy on the new per-run logs — **Minor**

Both launchers now write `~\.dsh\logs\<name>-<timestamp>.log` on **every** launch and
nothing prunes them. Unbounded growth in the user's profile. Small, but it is new debt
introduced today.

## Dimensions

- **Correctness & security** — no new issues at this level; deferred to the Engineering role.
- **First-run** — in scope and **owned by the Walkthrough lane**, which verified isolation and found W1 (Critical). Not duplicated here.
- **UX** — deferred to the UX role.
- **Docs** — L-1, L-2 above. This is where the slice is weakest.
- **Tests** — a suite now exists and its mutation harness proved it can fail. L-1 notes one test that cannot detect its own subject.
- **Runtime** — exercised live during the Walkthrough; both launchers, the deploy and both loaders ran on hardware.

## What's working

- The three PRs are each backed by an executed check, not an assertion — the loaders were proven with the vendored SDK physically renamed away.
- The mutation harness (`tests/Prove-TestsFailClosed.ps1`) caught three toothless tests written the same day. That is a real, working quality mechanism.
- The deploy's transactional core (stage → validate → backup → apply → validate) held across roughly a dozen runs today with no corruption.

## Escalation

**Escalate to `full`** — a first-run Critical (W1) was found by the Walkthrough lane,
which meets the escalation bar on its own. Full lane dispatched.
