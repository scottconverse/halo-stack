# Security & Performance Engineer

# Security & Performance Engineer — Deep-Dive Report
## GauntletGate Full Lane — halo-stack migrate/rc8 @ bb0f782

## Role + severity counts

Blocker 0 / Critical 0 / Major 0 / Minor 3 / Nit 4

## Findings

**M1 — Minor — hardening / PATH-poisoning surface**
`mission-control.mjs:109-113`:
```js
const EXE = {
  lms: resolveExe('lms', path.join(HOME, '.lmstudio', 'bin')),
  npx: resolveExe('npx'),
  node: resolveExe('node') || process.execPath,
};
```
The new `dump-config` call runs `safeExecFile('node', [PNPM_MJS, ...])`, i.e. it trusts `EXE.node` to be the real Node interpreter. Unlike `lms`, `node` is resolved via `resolveExe('node')` with **no `fixedDir`** — it walks `process.env.PATH` in order (per the `resolveExe` algorithm at lines 27-43) and returns the first `node.COM`/`.EXE`/`.BAT`/`.CMD`/bare-`node` match. A directory placed earlier than the real Node install in `PATH` containing a malicious `node.exe`/`node.bat` would be executed instead, for *every* `safeExecFile('node', …)` call in the file (this one, plus the pre-existing `load-q5`/`load-worker`). This exact line is unchanged by the migration diff (pre-existing), but the migration is the first place `node` is used to launch a path that lives under a third-party package (`PNPM_MJS`), which is exactly the comparison the audit asked for against the `lms` pattern.
Observed vs expected: expected — a hardened lookup mirroring `lms`'s fixedDir pattern, or better, the already-present `process.execPath` fallback used as primary. Actual — PATH-search-first, safe fallback second.
Why it matters: this is the one place in the reviewed surface where a poisoned PATH is a real (if high-precondition) redirection vector.
Impact scope: contained to Minor — exploiting it requires an attacker who can already write an executable earlier in this Windows user's own `PATH`, which is a local-compromise precondition equivalent to already running code as the user (the file's own stated threat model is remote/CSRF, not local-already-compromised). Not Critical/Blocker under the audit's "genuinely theoretical" carve-out. Pre-existing, not migration-introduced.
Fix path: swap the fallback order — `node: process.execPath` (drop the `resolveExe('node')` PATH search entirely; `process.execPath` is already the exact interpreter currently executing this file, so it is trivially correct and cannot be redirected).

**M2 — Minor — test-coverage gap on the new resolution hardening**
`tests/Run-Tests.ps1` (migration diff, MIG1/MIG2/MIG3 added at lines 337-366) checks: no functional file runs dsh via `npx` (MIG1), a single consistent version pin (MIG2), and `Start-DSH.ps1` launches `pnpm.cmd` not bare `pnpm` (MIG3). None of these — nor the pre-existing `SEC1` (`shell:\s*true` file-wide regex) — assert *how* `mission-control.mjs` locates `pnpm.mjs`. A future edit that quietly replaced the fixed-path `PNPM_MJS` lookup (lines 105-108) with `resolveExe('pnpm')` (reintroducing PATH search, undoing the hardening credited in "What's working" below) would pass every current test and the full mutation suite unchanged.
Observed vs expected: expected a MIG4-shaped test pinning the resolution strategy; none exists.
Why it matters: the one genuinely good hardening decision in this diff (fixed-path, no-PATH-fallback resolution) has no regression protection.
Impact scope: Minor — today's code is correct (verified); this is a future-regression risk with no test net, not a live defect.
Fix path: add a static test asserting `mission-control.mjs` builds `PNPM_MJS` from `NPM_GLOBAL`/`process.env.APPDATA` + `fs.existsSync`, and does **not** call `resolveExe('pnpm'` anywhere.

**M3 — Minor — no pnpm dlx cache eviction story**
Confirmed empirically: `%LOCALAPPDATA%\pnpm-cache\dlx` currently holds exactly one entry (`0a1fda382d1b4709ecb272f1f72ee377`, 1.8 MB, timestamped today), and the shared content-addressable store `%LOCALAPPDATA%\pnpm\store\v11` is already 2.8 GB across 69,933 files. pnpm's dlx cache is keyed by exact spec string with **no automatic TTL/pruning** (`pnpm config get side-effects-cache` → `undefined`; no `.npmrc` override). `DSH_VERSION_PIN` just moved from `0.1.0-rc.7` to `0.1.1-rc.2` — that is a new spec string, so this migration's own pattern guarantees every future version bump adds a permanent new dlx-cache directory that nothing in this repo ever cleans up.
Observed vs expected: expected some maintenance note or scheduled prune; found none in README.md/USER-MANUAL.md/Deploy-ToLive.ps1 (grepped; no `pnpm store prune` anywhere in the repo).
Why it matters: not urgent — today's footprint is small and the CAS store is deduplicated and shared machine-wide (not dsh-exclusive, so most of that 2.8 GB predates this migration) — but the pattern is genuinely unbounded over a long release cadence.
Impact scope: Minor, operational/long-horizon, not a functional or security defect today.
Fix path: document `pnpm store prune` as an occasional maintenance step in `docs/USER-MANUAL.md`, or add it as a non-blocking cleanup line in `Deploy-ToLive.ps1`.

**N1 — Nit — no in-flight guard on `/api/validate-config`**
`mission-control.mjs:2700-2717`. Nothing prevents two overlapping authorized POSTs from spawning two concurrent `pnpm dlx … --dump-config` subprocesses (each with a 300 s timeout / 16 MB buffer). A double-click or a retried script call is the realistic trigger, not an attacker (the endpoint is still auth-gated).
Fix path: a module-level in-flight promise, returning the same pending result to a concurrent caller instead of spawning a second subprocess.

**N2 — Nit — hardcoded npm-prefix assumption**
`mission-control.mjs:99,105-108`. `NPM_GLOBAL` assumes pnpm was installed at the default npm global prefix (`%APPDATA%\npm`). Verified correct on this box (`npm config get prefix` → `C:\Users\scott\AppData\Roaming\npm`; `pnpm.mjs` present there). It would silently (but cleanly — caught, HTTP 200, `ok:false`, readable message) go stale if pnpm were later installed via corepack, the standalone pnpm installer (which targets `%LOCALAPPDATA%\pnpm`), Scoop, or a customized npm prefix.
Fix path: add `%LOCALAPPDATA%\pnpm\pnpm.mjs`-shaped candidates, or shell out once to `npm config get prefix` at startup as a second candidate root.

**N3 — Nit — SEC1 regex is narrower than the property it's meant to guarantee**
`tests/Run-Tests.ps1:373`: `if ($code -match 'shell:\s*true')`. This would not catch `shell: 'cmd.exe'` (Node's `shell` option also accepts a shell-path string, which equally re-enables command-line concatenation) or a computed `opts.shell = true` assignment. Not a live issue — I read every subprocess call site directly and confirmed none exist in any form — and it's structurally backstopped anyway (`safeExecFile`/`safeSpawn` spread `...opts` *before* a hardcoded `shell: false`, at `mission-control.mjs:49` and `:54`, so a caller literally cannot make either wrapper pass a truthy/string shell through). Flagging purely to widen the regression net.
Fix path: broaden to `shell\s*:\s*(true|['"])`.

**N4 — Nit — timeout failure message unverified**
`mission-control.mjs:2708-2713`. On a genuine 300 s timeout, `execFileP`'s rejection is caught generically (`String(e.message||e)`); I did not reproduce a live 300 s timeout (deliberately, to avoid a 5-minute low-value wait against the operator's live process) so I can't confirm the resulting string clearly reads as "timed out" rather than a generic subprocess-failure string, which would leave an operator guessing after a long wait.
Fix path: special-case `e.killed && e.signal === 'SIGTERM'` to prepend an explicit "validation timed out after 300s" to the warnings array.

## What's working

- **shell:false is fully intact, no regression.** Full-file grep for `shell\s*:\s*true|shell:true` and for bare `exec(`/`execSync`/`spawnSync` returns nothing outside explanatory comments (`mission-control.mjs:20,23,51,102`); only `execFile`/`spawn` are imported (line 7). `safeExecFile`/`safeSpawn` (lines 47-55) structurally override any caller-supplied `shell` value — `{ ...opts, shell: false }` — so even a mistaken future call can't leak a truthy/string shell through the wrapper.
- **PNPM_MJS is not attacker-influenceable, and its resolution is stricter than the `lms` pattern it's compared against.** It never touches `resolveExe`/PATH search at all — it's a single hardcoded candidate under `NPM_GLOBAL` (`process.env.APPDATA`, a process-start value no HTTP request can reach), gated by `fs.existsSync`, fail-closed to a caught, clean error if absent (mission-control.mjs:105-108, 2706). `lms`'s `resolveExe(name, fixedDir)` still falls back to a full PATH search if the fixed-dir copy is missing (lines 27-43) — PNPM_MJS's design is strictly tighter.
- **`DSH_VERSION_PIN` is a genuine constant** (`const DSH_VERSION_PIN = '0.1.1-rc.2'`, line 97), read in exactly two places (status readout at line 895, exec arg at line 2708), never reassigned.
- **No request input reaches the exec call.** `/api/validate-config` (lines 2700-2717) reads no body and no query params — the handler's only external input is the auth header pair, which gates the call but never feeds its value into args. The `/api/action/*` dispatch (lines 2783-2793) uses `Object.prototype.hasOwnProperty.call(ACTIONS, a)` against a fixed table of zero-argument closures — no request data threads into any exec call anywhere in the file.
- **The EINVAL rationale is real, reproduced independently, on this exact box/Node version.** `execFile('...\npm\pnpm.cmd', ['--version'], {shell:false})` throws `Error: spawn EINVAL` (errno -4071) on Node v25.9.0 — confirmed with a standalone probe script. Wrapped exactly as the real code wraps it (`promisify(execFile)`, `await` inside `try/catch`), the EINVAL becomes a normal caught rejection, not a process crash — so the fix is necessary to make the feature work at all, not to prevent a server crash.
- **The chosen substitute is functionally exact, not an approximation.** `pnpm.cmd`'s own contents (`C:\Users\scott\AppData\Roaming\npm\pnpm.cmd`) are `... "%_prog%" "%dp0%\node_modules\pnpm\bin\pnpm.mjs" %*` — i.e. pnpm's official Windows wrapper does the identical `node + pnpm.mjs` invocation internally. The migration just skips the redundant `.cmd` layer that trips Node's CVE-2024-27980 hardening. Verified `node <pnpm.mjs> --version` returns `11.22.0`, matching `pnpm --version` directly.
- **Live end-to-end proof, not a claim.** Extracted the live boot token from the served MC page and fired a real, fully-authorized `POST /api/validate-config` against the running Mission Control (`:3090`): `{"when":...,"ok":true,"warnings":[]}`, HTTP 200, **3.981 s wall time** — consistent with a warm dlx-cache hit (not the ~50 s cold path), directly confirming "does every launcher start re-resolve" → **no, the cache is reused**, and confirming "MC runs migrated code" against the live process, not just the file on disk. `/api/status` on the same live process independently reports `"dshVersionPin":"0.1.1-rc.2"`.
- **Auth gate has no migration regression.** Three live negative tests against `:3090`: no token → 403, wrong token → 403, valid token + forged `Origin` → 403. The PE-1 CSRF fix is intact.
- **Both dlx entry points share one cache, confirmed.** Start-DSH.ps1's `pnpm.cmd dlx … web --no-open` and Mission Control's `node <pnpm.mjs> dlx … web --dump-config` resolve to the same `node_modules\pnpm\bin\pnpm.mjs`, writing into the same `%LOCALAPPDATA%\pnpm-cache\dlx` / `pnpm\store\v11` — a launcher cold-start and a validate-config click warm each other's cache.
- **300 s is a hard, Node-enforced ceiling**, not an extension of the original problem — the prior state was a literally unbounded `npm install` hang; 300 s gives 6x headroom over the author's measured ~50 s cold baseline and always resolves (success, error, or timeout) within 5 minutes.
- **Tests and mutations verified first-hand, not trusted.** Ran `tests\Run-Tests.ps1 -Static`: **28/28 pass**, including SEC1, SEC2, MIG1, MIG2, MIG3. Ran `tests\Prove-TestsFailClosed.ps1`: **18/18 mutations caught**, including reintroducing npx-for-dsh (MIG1), a partial version-pin bump (MIG2), bare `pnpm` instead of `pnpm.cmd` (MIG3), and a reintroduced `shell:true` (SEC1) — the fail-closed guarantee is real, not decorative.
- `node --check mission-control/mission-control.mjs` → syntax OK.

## What I could not assess

- Whether `pnpm dlx` for an exact pinned spec still performs *any* registry round-trip on a full cache hit, versus resolving purely offline — my 3.98 s live measurement is strong indirect evidence of cache reuse but I did not packet-capture or run with networking disabled to confirm zero network I/O.
- NTFS ACLs on `%APPDATA%\npm` were not explicitly enumerated (`icacls`) — I relied on Windows' default per-user-profile permission model (own-user-writable only) rather than confirming this machine has no non-default grant.
- A genuine cold dlx run (empty cache, ~190 fresh packages) was not reproduced — doing so would require clearing the operator's real pnpm store, which I judged unnecessarily destructive to a machine in active use; I'm relying on the author's own measured "~50 s cold" figure plus my own confirmed ~4 s warm figure.
- The exact error text Node produces when `execFile`'s `timeout` option actually fires (N4) — not reproduced live to avoid a 5-minute low-value wait against the operator's process; reasoned from documented Node semantics instead.
- The stale-process regex in `Start-DSH.ps1` (PE-3 exclusion of `--dump-config`/`plugin` from the kill sweep) is visible in the diff and looked sound on read, but live process-tree matching against real pnpm-dlx/cmd/bin.js processes is outside my assigned checklist for this role and I did not independently drive it.
- README.md, docs/USER-MANUAL.md, and CHANGELOG.md changes (part of the 9-file migration per `git diff --stat`) were not reviewed — outside Security & Performance scope; deferred to whichever role owns documentation accuracy.
