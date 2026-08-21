# GauntletGate — Walkthrough lane

**Target:** halo-stack @ master `b1cb22a` · **Date:** 2026-08-21
**Product model:** a reproducible local-AI coding workstation. Core feature for a new
user = *the cockpit is serving AND a local model is loaded and answering*. Everything
else (Mission Control, benchmarks, fleet) is secondary.

---

## Environment provisioning — attestation (VERIFIED)

| What | State used | How VERIFIED — not assumed |
|---|---|---|
| Profile / `USERPROFILE` / app-data isolation | clean temp dir `%TEMP%\halo-gate-020414\home` | Deploy run with `USERPROFILE` redirected wrote **918 files** into the isolated home; `home\.dsh\machine` created there reading `halo`; the real profile's `~\.dsh\machine` LastWriteTime was **unchanged** across the run. Artifacts: `isolation-proof.txt`, `isolated-home-tree.txt` |
| Repository state | fresh `git clone` of master, not the working tree | `clone HEAD = b1cb22a`; `lmstudio/` contains exactly 4 files; **`vendor/` absent** (confirms the stranger's view). Artifact: `firstrun-deploy.log` |
| First-run flags | unset (no prior `~\.dsh` in the isolated home) | isolated home created empty immediately before the run |
| Dependency: Node | present v25.9.0 | `node --version` |
| Dependency: `lms` CLI | present, and separately walked ABSENT | `Get-Command lms` → `C:\Users\scott\.lmstudio\bin\lms.exe`; ABSENT cell run with `.lmstudio` stripped from `PATH`. Artifact: `firstrun-lms-absent.log` |
| Dependency: LM Studio server | present (200), and separately walked ABSENT | `GET :1234/v1/models` → 200; ABSENT cell constructed with `lms server stop`, re-probed → ABSENT, then restored. Artifact: `firstrun-lmstudio-down.log` |
| Data store | empty | isolated `~\.dsh` created by the run itself |
| Network | online | package install from npm succeeded in the isolated home |

**Isolation verified?** **YES** — the app provably wrote to the isolated path and the real profile marker was untouched.
**First-run coverage:** **VALID**

**Evidence artifacts:** `artifacts/isolation-proof.txt` · `artifacts/isolated-home-tree.txt` · `artifacts/firstrun-deploy.log` · `artifacts/firstrun-lms-absent.log` · `artifacts/firstrun-lmstudio-down.log` · `artifacts/firstrun-happy-path.log` · `artifacts/sandbox-path.txt`

---

## Provisioning matrix — cells walked

| Cell | Walked | Result |
|---|---|---|
| first-run × `lms` ABSENT | ✅ | **Correct.** Deploy and launcher both abort *before touching anything*, naming the missing tool and the README step. Exit 1, no browser. |
| first-run × LM Studio server ABSENT | ✅ | **Correct.** 60 s probe, then a loud, actionable message ("open LM Studio once by hand and check its Developer/Server tab"), exit 1, **no browser opened on a dead port**. |
| first-run × all dependencies present | ✅ | **Core feature reached, but the product reports failure.** See W1. |
| first-run × empty data | ✅ | Deploy created a complete `~\.dsh` from nothing; SDK installed and resolved in the isolated home. |
| returning user × everything present | ✅ | Reuse path: launcher detects a serving cockpit and spawns nothing. |
| offline | ❌ NOT WALKED | The SDK install stage needs npm. A stranger installing offline is untested — **coverage gap**, not a pass. |

---

## First-run verdict

**Reaches the core feature: ✅ — but the product tells the user it failed.**

The brain loaded successfully, twice. The launcher then declared
`BRAIN LOAD FAILED TWICE ... The cockpit will still open, but with no local model
loaded.` That statement was false at the moment it was written.

---

## Findings

### W1 — Loader reports a successful model load as a failure, and reloads 21 GB because of it — **Critical**

**Where:** `lmstudio/Load-OpenCode-Qwen.mjs:107` (`execSync("lms ps --json")`), same pattern at `lmstudio/Load-Worker-Coder.mjs`.

**Expected:** the model loads → the loader confirms it → exit 0.
**Actual:** the model loaded (`Successfully loaded model unsloth/qwen3.8-27b in 16072ms`), then the *verification* threw, the loader exited non-zero, and `Start-DSH.ps1` treated that as a failed load — retried, **loaded the entire 21 GB model a second time**, verification threw again, and it told the user there is no model. `lms ps` afterwards showed the brain resident at ctx 131072 / Q5_K_XL. The claim was false.

**Cause:** `execSync` throws on *any* non-zero exit from `lms ps`. The loader cannot distinguish "the model did not load" from "the tool I use to check could not run". Any transient CLI failure — LM Studio restarting, CLI not yet authenticated, a missing key file, a locked store — is reported as a load failure.

**Reachable by a real stranger:** yes. A fresh LM Studio that has never been opened and authenticated has no CLI key; `client.llm.load` works over the API while `lms ps` fails. That is a first-run condition, not an artifact of this sandbox.

**Impact:** a new user is told their stack is broken when it is working, and pays a full redundant model load (16 s here on an APU with the file cached; minutes on a cold disk). It also burns the launcher's two retries, so a genuinely-failed load gets no attempts left.

**Fix:** wrap the verification in try/catch and classify. A verification that cannot run is `UNVERIFIED`, not `FAILED` — report it, keep the loaded model, do not retry the load. Prefer the SDK's own `listLoaded()` (already imported, no subprocess) with `lms ps` only as a cross-check.

**Test:** make `lms` return non-zero (rename it on PATH) after a successful load; assert the loader exits 0 with an UNVERIFIED notice and the model stays resident.

### W2 — `Register-ScheduledTask` is machine-global and silently repoints an existing task — **Major**

**Where:** `scripts/Deploy-ToLive.ps1`, register stage.

**Actual:** deploying from an isolated home rewrote the *real machine's* `HALO Memory Snapshot` task to run
`%TEMP%\halo-gate-020414\home\.dsh\memory\Snapshot-Memory.ps1` — a directory that was about to be deleted. Verified before/after; restored by re-running the real deploy.

**Why it matters:** the deploy presents itself as transactional with backup and rollback, but Task Scheduler is outside that guarantee. Any second deploy from a different home (a test, a second checkout, a port box sharing a login) silently breaks hourly memory snapshots, and nothing reports it. The audit stage then prints **PASS** because the task exists and is Ready — it never checks *where it points*.

**Fix:** have the audit assert the task's action path equals the current `$U` path, and treat a mismatch as MISSING.

### W3 — The launcher waits the full 60 s even when `lms server start` has already errored — **Minor**

`lms: ENOENT ...` was captured (the capture fix works), but the launcher ignores the error and polls for a minute before reporting. Fail fast when the start command itself errors, then poll only for a slow-but-healthy start.

### W4 — Offline install untested — **coverage gap, not a finding**

The new SDK stage requires npm reachability. Nothing documents this and nothing was walked. A stranger on a restricted network hits it at deploy time.

---

## Readiness by area

| Area | State |
|---|---|
| Fresh-clone integrity (no phantom files) | ✅ verified from a real clone |
| Prerequisite detection | ✅ both dependency-absent cells fail loudly and name the fix |
| Deploy transactionality (files) | ✅ stage → validate → backup → apply → validate |
| Deploy side-effects outside the transaction | ❌ W2 |
| Model load | ⚠️ works; **verification is less reliable than the thing it verifies** (W1) |
| Launcher failure honesty | ✅ no browser on a dead port; output captured per run |
| Offline | ❌ not covered |
