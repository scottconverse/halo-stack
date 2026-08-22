# GauntletGate report — halo-stack — public release readiness

**Date:** 2026-08-21 · **Commit:** `b1cb22a` (master) · **Run by:** Claude (Opus orchestrator + Sonnet 5-role panel)
**Lanes run:** lite · walkthrough · full (all) · **Lanes NOT run:** none
**Environment:** clean-cloned to a temp dir; deployed into an isolated `USERPROFILE`; dependencies walked present AND absent. Attestation below is VERIFIED with on-disk artifacts.

---

## Verdict (read first)

> # ⛔ DO NOT ADVANCE

- **First-run:** reaches the core feature ✅ **but the product reports its own success as failure** (W1). First-run coverage: **VALID.**
- **Severity roll-up (all lanes):** **Blocker 1 · Critical 9 · Major 22 · Minor 8 · Nit 4**
- **One-line why:** a fresh clone can now genuinely install and run — the fatal defect is fixed — but Mission Control ships an **unauthenticated, CSRF-reachable remote-code-execution hole** (reproduced), and the test suite meant to prevent regressions **is not gated to run and contains checks that pass with the defect present** (reproduced). This is not fit to advance to a release.

The single most important sentence: **the fixes are real, but the safety net has holes I verified by hand, and there is a new security Blocker I introduced today.**

---

## Environment provisioning — VERIFIED

| What | State used | How VERIFIED |
|---|---|---|
| `USERPROFILE` / app-data isolation | temp `%TEMP%\halo-gate-020414\home` | deploy wrote **918 files** there; `home\.dsh\machine`=`halo` created in the sandbox; real profile marker **unchanged**. → `artifacts/isolation-proof.txt` |
| Repo state | fresh `git clone` of master | `HEAD b1cb22a`; `lmstudio/` = 4 files, **no `vendor/`**. → `artifacts/firstrun-deploy.log` |
| Node | present v25.9.0 | `node --version` |
| `lms` CLI | present, **and walked ABSENT** | `Get-Command`; absent cell with `.lmstudio` stripped from PATH → `artifacts/firstrun-lms-absent.log` |
| LM Studio server | present, **and walked ABSENT** | `GET :1234` → 200; stopped, re-probed ABSENT, restored → `artifacts/firstrun-lmstudio-down.log` |
| Network | online | npm install succeeded in the isolated home |

**Isolation verified?** YES · **First-run coverage:** VALID
**Artifacts:** `isolation-proof.txt` · `isolated-home-tree.txt` · `firstrun-deploy.log` · `firstrun-lms-absent.log` · `firstrun-lmstudio-down.log` · `firstrun-happy-path.log` · `sandbox-path.txt`

---

## The blocking punch list (must clear to advance)

Ordered by what most endangers or misleads a stranger.

| ID | Sev | Title | Verified | Fix size |
|---|---|---|---|---|
| **PE-1** | **Blocker** | Mission Control `/api/action/{load,unload}-model` pass request-body strings into `spawn(..., {shell:true})` with **no auth and no Origin check** → RCE by CSRF from any page the operator's browser has open | **Reproduced** — injected `& echo PROVEN >file &` executed | M |
| **QA2/QA1** | Critical | Every MC action endpoint is unauthenticated; and the **live console is running stale code so the new stop button 404s right now** | **Reproduced** — live POST → `404 unknown action`; PID predates the file | S (restart) + M (auth) |
| **W1 / TE3** | Critical | Loader reports a **successful** model load as failed (verification `execSync` throws), causing a redundant 21 GB reload; both loaders; **no test exists** | **Reproduced** in the walkthrough | S |
| **PE-2** | Critical | `~/.dsh/machine` marker written outside the backup/rollback transaction → a failed non-halo deploy leaves a poisoned identity for the next run (issue #35 shape) | Static, traced | S |
| **TW-1** | Critical | USER-MANUAL states the **pre-incident** compaction config as current fact, cost figure off ~13× | Static | S |
| **TW-2 / L-1** | Critical | CHANGELOG's newest entry is 0.5.0 — the release that shipped the fatal defect; master is 8 commits past it with no `[Unreleased]` | Static | S |
| **TE1** | Critical | Test `V1` never reads the loader it claims to test — writes its own probe; the historical vendor-import defect **passes** it | **Reproduced** by the panel | S |
| **TE2** | Critical | The 25-check suite **is not wired to run** — no CI, not in the pre-push hook, not in the README. "Verification claimed but not gated" at the process level | Static, grepped | M |
| **TE4** | Critical | Test `L3` still bypassable: keep the real guard, drop its `exit 1`, add a dead `if($false){exit 1}` nearby → a real dead-port-browser regression **passes** | **Reproduced** by the panel | S |

---

## Cross-role findings (the same defect seen by several roles — highest leverage)

- **RCE (PE-1 = QA2):** Engineering and QA independently landed on the unauthenticated `shell:true` endpoints. Two roles, reproduced twice. This is the Blocker.
- **W1 (walkthrough = PE-5 = TE3):** three roles. Engineering adds that on the *Mission-Control-triggered* load path the same failure is **un**reported, not just misreported. Test adds that no regression test exists.
- **Doc staleness (L-1 = TW-2 = TW-3 = UX-6 = UX-7):** the changelog, the manual, and the landing-page screenshot all predate today's fixes. Four roles. The product's own record of itself is wrong.
- **My own tests (TE1/TE4/TE6):** the test role reproduced three holes in the suite I wrote and "proved" this session. My mutation harness missed them because it only mutates product files, never the tests, and its `.git` exclude silently fails (TE6, reproduced on PS 5.1).

---

## Next-stage watchlist (structural, fix before or with the next release)

- **PE-3 / QA4:** no concurrency guard on `Deploy-ToLive.ps1`; and `Start-DSH.ps1`'s stale-process sweep can force-kill the deploy's own `--dump-config` validation subprocess (both match `deepseek-ai/dsh` + `web`). A deploy and a launch racing can corrupt each other.
- **QA5 / TW / L-3:** `~/.dsh/ConfigBackups` (25 dirs already) and the new per-run `~/.dsh/logs` grow **unbounded** — no retention anywhere.
- **PE-4:** the wire-shim's injected keys (MTP etc.) have **no coverage in the loader's own success signal** — a silent issue-#14-class regression would be undetectable. Matches the operator's own "MTP is inferred, not measured."
- **UX-1..5:** the STALLED dot has no CSS rule (renders invisible), the hero line contradicts the alarm strip, the stop feedback is disconnected from the row, keyboard-unreachable controls, and 240 s of silent launcher startup.
- **PE-2 / #39 / #40 / #15:** the machine-profile system remains fragile (already-filed issues, unchanged).
- **rc.7 → rc.8** migration (operator-decided, not yet done).

---

## What's working (credited, specific — verified, not assumed)

- **The fatal defect is genuinely fixed.** A fresh clone with the vendored SDK physically renamed away loads both models. This was the whole point and it holds.
- **Both dependency-absent first-run cells behave correctly** — `lms` missing and LM Studio stopped each abort loudly, name the fix, and refuse to open a browser on a dead port. This is a real improvement over the shipped behaviour.
- **The deploy's transactional core** (stage → validate → backup → apply → validate → rollback) is sound for the files it tracks; Engineering confirmed the restore logic reverses both modify and create correctly.
- **The mutation harness caught three toothless tests** earlier today — the mechanism works even though the panel then found more it doesn't reach.
- **Isolation held** — this is the first verified-isolated first-run test in the project's history, and it passed.

---

## Sign-off checklist

- [x] Verdict matches the lanes run (all three ran; DO NOT ADVANCE on 1 Blocker / 9 Critical).
- [x] Environment attestation filled with verified facts, linked to on-disk artifacts.
- [x] First-run reachability stated: reaches core feature but reports false failure (W1).
- [x] All 5 roles ran (parallel, Sonnet), deep-dives on disk (`01-engineering`…`05-qa`), cross-role findings noted.
- [x] Every Blocker/Critical has evidence; the Blocker and three Criticals were **reproduced**, not asserted.
- [x] What's-working present and specific.
```
