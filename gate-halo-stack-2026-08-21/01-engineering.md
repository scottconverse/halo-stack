# GauntletGate Full lane — Principal Engineer

## Role + severity counts

Blocker 1 / Critical 1 / Major 4 / Minor 1 / Nit 0

## Findings

### PE-1 — Unauthenticated, CSRF-reachable command injection in Mission Control's model load/unload endpoints — **Blocker**

**Category:** Security (RCE)

**Evidence:**
- `mission-control/mission-control.mjs:2623-2631` (`/api/action/load-model`): `modelPath`/`modelKey` come straight from the parsed JSON body with only a truthiness check (line 2627), then flow unmodified into `spawn('lms', ['load', modelPath, '--identifier', modelKey, '--context-length', String(ctxN), '-y'], { detached: true, stdio: 'ignore', shell: true })` (line 2629).
- `mission-control/mission-control.mjs:2632-2647` (`/api/action/unload-model`): `identifier` comes straight from the body (2635); the one server-side guard present (2640-2644, an LM-Link remote-device check) only fires when `identifier` matches an *already-loaded* model. For any attacker-crafted string, `target` is `undefined` and execution falls straight through to `spawn('lms', ['unload', identifier], {..., shell:true})` (2645), unchecked.
- `mission-control/mission-control.mjs:922-929` (`readBody`): parses the raw body as JSON unconditionally — it never inspects `Content-Type`.
- `mission-control/mission-control.mjs:2515-2517` and a repo-wide grep for `Authorization|Bearer|apiKey|X-Auth|token`: no auth, session, or Origin check exists anywhere in this file, before or inside route dispatch.
- Line 2716: server binds `127.0.0.1` only — this stops remote network attackers but does nothing against a request originating from the operator's own browser, which is the actual delivery path.
- **I directly reproduced the injection primitive.** In an isolated Node v25.9.0 script (matching this box's `node --version`), I called `spawn(cmd, args, {detached:true, stdio:'ignore', shell:true})` — the exact shape used at line 2645 — with one array element crafted as `"whatever & echo COMMAND-INJECTION-PROVEN > marker.txt & echo "`. The chained command executed; I read the resulting file back and it contained `COMMAND-INJECTION-PROVEN`. Node itself flagged the mechanism unprompted: `[DEP0190] DeprecationWarning: Passing args to a child process with shell option true can lead to security vulnerabilities, as the arguments are not escaped, only concatenated.`

**Why it matters:** any web page the operator's browser has open — an ad, a compromised site, a malicious link — can POST JSON to `127.0.0.1:3090/api/action/{load,unload}-model` while Mission Control runs, via the standard `<form enctype="text/plain">` technique (a CORS-"simple" content type that skips preflight; since `readBody` never checks `Content-Type`, the server accepts it regardless). This is not classic SSRF — no endpoint takes an attacker-chosen destination, every outbound target in this file is hardcoded to `127.0.0.1` — the real vector is CSRF (zero origin/token check) chained into `shell:true` injection. It requires no clicks, no confirmation, nothing beyond "Mission Control is running."

**Impact scope:** every user who runs Mission Control as intended (a background console left open) is continuously exposed for as long as it runs — on a public repo strangers are downloading right now.

**Fix path:** never pass request-derived strings through `shell:true`; switch to `shell:false` with an argv array (pin `lms` to its resolved absolute path for Windows `.cmd` resolution). Validate `modelPath`/`modelKey`/`identifier` against real catalog output (`lms ls --json` / `lms ps --json`) before use, applying the LM-Link-style guard unconditionally rather than only on a match. Add real local authentication (a shared token issued at deploy time) plus an Origin check — `127.0.0.1` binding is not an auth boundary against browser CSRF. Add a regression test that POSTs a shell-metacharacter payload and asserts no second-command side effect occurs.

---

### PE-2 — Deploy-ToLive.ps1's machine-identity marker is written outside the backup/rollback transaction — **Critical**

**Category:** Architecture / correctness (the transactional guarantee)

**Evidence:**
- `scripts/Deploy-ToLive.ps1:41-63` (`$map`): the file inventory backup/rollback operates on. `$U\.dsh\machine` is not in it.
- `scripts/Deploy-ToLive.ps1:397-398`, inside `apply`: `Set-Content -Path "$U\.dsh\machine" -Value $machine -Encoding ascii` — unconditional, before post-apply validation.
- `scripts/Deploy-ToLive.ps1:366-383` (`backup`) and `:406-414` (`rollback`): both iterate `$map`/`$backedUp` only — the marker is never captured or restored.
- `scripts/Deploy-ToLive.ps1:173-175`: the marker is exactly what the *next* unlabeled deploy trusts to pick a machine profile and its file-swap/replacement rules.

**Direct answer to "does rollback actually restore?":** for everything tracked in `$map`, yes — the restore-or-remove logic correctly reverses both the modify and create cases (nothing in `$map` is ever deleted by `apply`). The one piece of live state this deploy mutates that rollback does *not* cover is the machine marker.

**Why it matters:** a deploy run with `$env:MACHINE='5070ti'` (or any non-`halo` value) that fails post-apply validation for an unrelated reason (e.g. PE-3 below, or a transient npx hiccup) correctly rolls back every config file to its pre-deploy content — but `~\.dsh\machine` is left saying `5070ti`. The next unlabeled deploy (the normal case, since the marker exists precisely so operators don't have to keep repeating `$env:MACHINE`) resolves `$machine='5070ti'` from the poisoned marker on a box whose actual content is still `halo`'s, and renders `halo`'s files through `machines\5070ti.yml`'s replacements/swaps. That is exactly the shape of issue #35 (a machine-specific file landing where it doesn't belong) — self-inflicted by the rollback path, and silent.

**Impact scope:** triggered by a failed post-apply validation on any run where the resolved machine differs from the box's actual state — a real, reachable path given this repo's explicit multi-machine design (`halo`, `5070ti`), not a manufactured corner case.

**Fix path:** add `$U\.dsh\machine` to `$map` (routing its write through the same backup bookkeeping), or defer the marker write until after the post-apply validate succeeds, so a failed deploy never advances the recorded identity.

---

### PE-3 — Start-DSH.ps1's stale-process sweep can kill Deploy-ToLive.ps1's own validation subprocess — **Major**

**Category:** Concurrency / ordering hazard

**Evidence:**
- `dsh/Start-DSH.ps1:137-149`: candidate selection is `Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='cmd.exe'" | Where-Object { CommandLine -match 'deepseek-ai(/|\\)dsh' -and CommandLine -match '\bweb\b' }`; anything not listening on a port other than 3080 is `Stop-Process -Force`'d as "stale," with no age check and no check of trailing flags.
- `scripts/Deploy-ToLive.ps1:136` and `:79`: both run `npx "@deepseek-ai/dsh@0.1.0-rc.7" web --dump-config` (up to four times in one deploy run — bootstrap, staged-validate, live-validate, rollback-validate). On Windows this spawns through `cmd.exe`/`npx.cmd` with a command line containing both `deepseek-ai/dsh` and the standalone word `web` — indistinguishable, by this regex, from Start-DSH.ps1's own server invocation at line 168-170. `--dump-config` never binds a port, so by Start-DSH's own criterion it reads as stale on first sight.

**Why it matters:** if Start-DSH.ps1's sweep (which fires whenever the cockpit is not currently answering — common right after a deploy, or on any relaunch) runs while one of Deploy-ToLive's `dump-config` calls is in flight, the deploy's validation subprocess gets force-killed by an unrelated process. Deploy-ToLive treats the resulting garbled/non-zero result as `Clean=$false` (`scripts/Deploy-ToLive.ps1:140`), either aborting the deploy before it applies anything or triggering a spurious rollback of an otherwise-valid deploy. The error message ("Staged config fails compose-validation") gives no hint a concurrent launcher was the actual cause.

**Impact scope:** requires temporal overlap between a deploy and a launch/relaunch while the cockpit is down — plausible on an active dev workstation where redeploy-then-relaunch is the normal sequence.

**Fix path:** exclude candidates whose command line contains `--dump-config` (or require the command line to end in exactly `web`, no trailing flags); better, have Start-DSH.ps1 only ever target the specific PID pattern it itself spawns rather than pattern-matching all matching processes system-wide.

---

### PE-4 — The wire-level shim's injected fields have no coverage in the loader's own success signal — issue #14 regression would be undetectable — **Major**

**Category:** Architecture / dependency coupling / data provenance

**Evidence:**
- `lmstudio/Load-OpenCode-Qwen.mjs:44-63`: monkey-patches `Object.getPrototypeOf(client.llm).loadConfigToKVConfig` to push 11 hardcoded wire keys (MTP/speculative decoding, `contextCheckpoints`, `physicalBatchSize`, `numParallelSessions`, `useUnifiedKvCache`, `offloadKVCacheToGpu`, `gpuStrictVramCap`) that the public SDK "accepts... and SILENTLY DROPS" per the file's own comment (lines 12-18).
- `lmstudio/Load-OpenCode-Qwen.mjs:109-114`, the *entire* post-load verification:
  ```
  const checks = { loadedLocally: !!live, contextLength: ..., parallel: ..., quant: ... };
  ```
  None of the four checks reference MTP/speculative decoding, `contextCheckpoints`, `physicalBatchSize`, `useUnifiedKvCache`, or `offloadKVCacheToGpu` — the fields the shim exists to inject. `parallel` covers one of issue #14's three named failure modes; the other two ("MTP off, no context checkpoints, the wrong physical batch size" — `docs/audits/AUDIT-first-run-and-launchers-2026-08-21.md:61`) are checked nowhere.
- `lmstudio/Load-Worker-Coder.mjs:26-63`: same pattern, narrower scope, same gap.

**Why it matters:** this is not merely "inferred, not measured" (the known open item's framing) — it is *structurally unmeasurable* through the loader's own pass/fail signal. The coupling is to LM Studio's private, unversioned wire protocol, not the public SDK's typed surface. If a future LM Studio/SDK update renames `loadConfigToKVConfig` outright, the next `client.llm.load()` throws (`origMap` is `undefined`) — a loud, safe-by-accident crash. But if the method's *shape* survives while the *wire key names* it expects change, the shim keeps pushing old, now-ignored keys; the load still succeeds; `lms ps --json` still reports context length/parallelism/quant/residency correctly (none of which depend on MTP/checkpoint/batch settings); and the loader prints success — reproducing issue #14's exact original symptom, inside the code shipped today specifically to end it.

**Impact scope:** dormant today (pinned to `@lmstudio/sdk@1.5.0`) — a forward-looking risk, but the first thing that will silently regress on the next SDK/LM Studio bump. Nothing in `tests/` exercises this path.

**Fix path:** extend `checks` to assert on whatever `lms` can observe about active speculative decoding, if such a surface exists; failing that, emit an explicit "UNVERIFIED: cannot confirm MTP/checkpoint/batch settings took effect" distinct from a clean pass. At minimum, CI-gate the pinned SDK version against a recorded hash of `loadConfigToKVConfig`'s source so an `npm update` that changes it fails a build step instead of shipping unnoticed.

---

### PE-5 — W1's blast radius is worse on the Mission-Control-triggered path: failure isn't misreported there, it's unreported — **Major**

**Category:** Correctness / observability (extends walkthrough W1)

**Evidence:**
- `mission-control/mission-control.mjs:916-917`: `'load-q5': () => spawn('node', [LOADER_Q5], { detached: true, stdio: 'ignore', shell: true }).unref()` and the equivalent for `load-worker` — both invoke the exact loaders W1 found unreliable, with `stdio:'ignore'` and `.unref()`.
- `mission-control/mission-control.mjs:2670-2673`: the `/api/action/*` dispatcher calls `ACTIONS[a]()` and responds `200 ok` immediately, never awaiting the child or inspecting its exit code — it structurally can't, since stdio is discarded and the process is unref'd.

**Why it matters:** on the auto-launch path, W1's bug at least surfaces as a false "BRAIN LOAD FAILED TWICE" banner in `launcher.log` plus a Notepad popup — wrong, but visible. On the Mission-Control-triggered path (an operator clicking "load worker"/"load Q5"), success and failure are indistinguishable: the button shows "ok" the instant the child is spawned, regardless of outcome. This is strictly worse for this trigger path — it's not "the tool lies about failure," it's "the tool cannot report anything," including a *genuine* failure (bad path, OOM) unrelated to W1.

**Impact scope:** every on-demand load/reload triggered from Mission Control — the console an operator specifically reaches for to manage models mid-session.

**Fix path:** capture stdio to the same per-run log files Start-DSH.ps1 already uses; have these actions return only once the child's exit code is known, or expose a status the UI polls, rather than reporting success at spawn time.

---

### PE-6 — `sessionId` is escaped for the wrong context in an inline `onclick` handler (latent JS injection; real-world reachability unconfirmed) — **Major**

**Category:** Security (defense-in-depth gap)

**Evidence:**
- `mission-control/mission-control.mjs:1151`: `esc()` is an HTML-entity escaper (`&<>"'` → entities) — correct for HTML content/attributes, not for text that will also be parsed as JavaScript after the browser decodes the attribute.
- `mission-control/mission-control.mjs:1781`: `onclick="event.stopPropagation();stopSession(&quot;'+esc(s.sessionId)+'&quot;,&quot;'+esc((s.title||s.id).replace(/"/g,'')) +'&quot;)"` — `s.sessionId` gets `esc()` only. `s.title` gets `.replace(/"/g,'')` (stripping literal `"` outright) **and then** `esc()`.
- Mechanism: inline event-handler attributes compile into a JS function body from the *entity-decoded* attribute value. `esc()` turns a raw `"` into `&quot;`, which keeps the HTML attribute boundary intact — but decoding it back to `"` for JS compilation lets it terminate the enclosing JS string early. A `sessionId` of `x","y);<JS>;//` decodes to `stopSession("x","y);<JS>;//","title")` — injected, executable JavaScript. `title` is not exploitable this way specifically because its extra `.replace` removes the one character this delimiter depends on — proving the author was aware of the hazard for one field and didn't apply the same treatment to the other.

**Why Major, not Blocker/Critical:** exploitation needs (a) some producer of a dsh session's `sessionId` able to embed `"` and JS syntax in it, and (b) the operator clicking "stop" on that specific row (inline `onclick` fires only on interaction, not render). `sessionId` comes from `@deepseek-ai/dsh`, an external, non-vendored dependency I cannot inspect from this repo — I could not confirm whether it is ever anything but an opaque server-generated token.

**Impact scope:** if `sessionId` is ever influenced by untrusted text, this becomes a same-severity sibling of PE-1, gated behind one click instead of zero.

**Fix path:** never build inline event-handler strings by concatenation — use a `data-session-id` attribute plus a delegated `addEventListener`, or at minimum `JSON.stringify()` (not HTML-escape) values destined for a JS string-literal context.

---

### PE-7 — "OK" banner prints three stages early; failed non-`halo` deploys leak a render-root temp dir — **Minor**

**Category:** UX / hygiene

**Evidence:**
- `scripts/Deploy-ToLive.ps1:427-428`: `"OK. staged -> validated -> backed up -> applied -> validated -> OK." ... "Backups retained at: $backupRoot"` prints before the lmstudio-SDK (440-481, can still `exit 1` at 462/478), register (483-502), and audit (504-563) stages run.
- Line 565: `if ($renderRoot) { Remove-Item -Recurse -Force $renderRoot ... }` is the only cleanup of the non-`halo` render-root (created line 194); every failure exit between line 194 and 565 (scope gate, drift guard, pre-validate, staged-validate, SDK install, audit-caused) skips it, leaving `%TEMP%\dsh-deploy-render-<timestamp>` behind permanently.

**Fix path:** move (or duplicate) the "OK" banner to after the audit stage; wrap render-root use in `try/finally`, mirroring the staging-home pattern already used correctly at lines 351-358.

## What's working

- **Deploy-ToLive.ps1's file transaction is genuinely sound** for everything it tracks: I traced the backup/restore/remove logic precisely, and it correctly reverses both the "modified an existing file" and "created a new file" cases (PE-2 is the one specific state that falls outside this design, not a flaw in the mechanism).
- The **SCOPE: gate** on AGENTS.md (lines 246-267) is a real, targeted fix for a documented incident (#35), run against the *rendered* source so it sees exactly the bytes about to ship.
- The **baseSha256 rot-guard** on machine-profile file swaps (lines 221-227) is a clever, non-obvious mechanism: it fails a deploy the moment a machine copy silently stops inheriting base improvements, rather than shipping stale content quietly.
- The **lmstudio-SDK resolution probe** (lines 467-481) gets a genuinely easy-to-miss detail right: the probe file is placed *inside* `$scriptsDir`, not %TEMP%, because ESM resolves bare specifiers from the importing file's own directory — a "looks equivalent" shortcut here would have passed while the real loaders still failed.
- **Start-DSH.ps1's single-instance mutex is more robust than it looks.** I specifically tested the failure mode I expected to break it — force-killing a process while it holds `Local\HaloStackLauncher`, simulating a user killing a hung/hidden launcher — and it does **not** wedge later launches: `WaitOne(0)` against an abandoned mutex on this box's actual PowerShell 5.1 runtime (confirmed `5.1.26100.9168`) returns `True` with no exception. I'm flagging this credit explicitly since it's exactly the kind of thing that looks fragile on paper and I confirmed, empirically, that it is not.
- Start-DSH.ps1's **identity-checked HTTP readiness** (`__DSH_BOOT__`) is a real fix for "a TCP listen check reports a wedged server healthy," and the stale-kill sweep correctly leaves alone any candidate listening on a port other than 3080 — PE-3 is a false-positive against a sibling script's subprocess, not a flaw in how this logic treats dsh instances themselves.
- The **`deviceIdentifier` null-check** in both lmstudio loaders (guarding against a federated LM-Link device satisfying a naive identity match) is a real, non-obvious correctness fix, applied consistently.
- **mission-control.mjs binds `127.0.0.1` only**, correctly limiting remote-network exposure — PE-1's hole is local/CSRF, not remote-network.
- **mission-control.mjs's boot-time self-checks** (`validatePageContent`/`validatePageScript`, lines 2682-2714), refusing to start if the inline UI script would render blank or a Windows path lost its backslashes, is genuinely defensive engineering most projects this size wouldn't bother with.
- **settings.yaml's compaction math checks out**: I independently recomputed it — 131072 × 0.75 = 98,304; × 0.5 = 65,536; 98,304 − 65,536 = 32,768; ÷ 12,288 ≈ 2.7:1 — exactly as documented.
- The **"ONE DECODE LANE PER MACHINE" cap is enforced in two independent places that agree**: `dsh/agent-presets/halo-standard/agent.cordis.yml:254` (`maxConcurrentAgents: 1`) and `dsh/cordis.patch.yml:32` (`maxConcurrentJobsPerOwner: 1`) — I confirmed both files actually contain the values the comments claim, genuinely closing "both doors" as described.

## What I could not assess

- I did not stand up mission-control.mjs's real server and fire an actual cross-origin browser POST at it. PE-1's injection *primitive* is empirically proven (I executed the exact `spawn`/`shell:true` pattern and observed the side effect) and the absence of any auth/CSRF defense is confirmed by reading the complete request path — but the specific `text/plain`-form CSRF delivery is asserted from well-established web-platform behavior, not independently fired against the live server in a browser.
- I could not confirm what `lms ps --json` is even capable of reporting (whether MTP/speculative-decoding status is retrievable at all) — no live LM Studio instance with a model loaded in this audit session. This affects the *shape* of the right fix for PE-4, not whether the gap exists.
- I could not confirm whether `sessionId` (PE-6) is ever attacker- or user-influenced text — session-ID generation lives in `@deepseek-ai/dsh`, external and not vendored into this repo.
- PE-2 (machine-marker rollback gap) and PE-3 (cross-script kill) are traced precisely from source — exact line-level reasoning cross-referencing both scripts — but not fired end-to-end against a real `~\.dsh`; I judge both sound, not speculative, but they are deductions rather than live reproductions.
- I read mission-control.mjs's ~2700 lines selectively: thoroughly on the action/exec/auth surface named in my brief (full spawn/execFile inventory enumerated, one representative rendering path checked for escaping correctness), but I did not audit all ~50 `innerHTML` call sites for PE-6's class of bug — there may be more instances I did not find.
- I did not test Deploy-ToLive.ps1 against an offline/restricted registry (already flagged as a coverage gap, W4, by the walkthrough lane) beyond reading the pinned version string in `lmstudio/package.json`.
