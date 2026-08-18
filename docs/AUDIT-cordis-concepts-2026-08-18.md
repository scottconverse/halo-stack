# Cordis paper → HALO stack improvements (2026-08-18)

Source: *"A Programming Paradigm for Spatiotemporal Composability"* (Shi, Zhang,
Cui — Peking University / DeepSeek-AI; github.com/cordiverse/paper). This is the
formal theory under the harness's Cordis kernel: **revertible effects** (every
change carries a tracked inverse; teardown is derived, not written; unloading
provably leaves no trace) and **reactive coeffects** (declared dependencies
drive activation/deactivation automatically). Its confluence theorem guarantees
the running system always settles into the state a from-scratch assembly of the
final config would produce — history leaves no trace.

Full read of all 88 pages, then six improvements derived and applied the same
day. Each entry below states the concept, the evidence gathered **on this
machine**, and what changed.

## 1. Config reconciliation is LIVE — the restart ritual is dead (§5.2.1)

**Proven by experiment:** toggled `web-search-deepseek` in
`~\.dsh\cordis.patch.yml` while the harness served production sessions. The
fiber activated ~20 s after save (plugin inventory 136→137 active), and the
revert withdrew it cleanly (137→136) — both directions, zero restart, zero
session disturbance. Every restart this stack ever did for a config change was
unnecessary. Ops now: edit → watch Mission Control's plugin card → done.
Restarts remain only for harness upgrades and the >1 MB-session deadlock
workaround.

## 2. Transactional deploys (modeled on §5.2.2's HMR reload)

Finding 1 raises the stakes: a bad edit reaches the live harness in seconds.
`scripts\Deploy-ToLive.ps1` is now a five-stage transaction:
pre-validate staged YAML (js-yaml with a custom `!!js` tag type) →
**compose-validate the staged config in a sandbox home** (the harness's own
`DSH_HOME` override + a junctioned `profiles/` tree, so `--dump-config` runs
against staged files without touching live) → timestamped backup to
`~\.dsh\ConfigBackups\deploy-<stamp>\` → apply → re-validate live, with
**automatic rollback** restoring every backed-up file on failure. Rollback
path proven with a deliberately corrupted staging file; live config verified
SHA256-identical after the clean-path test.

## 3. Mission Control speaks the lifecycle calculus (§4.3, Fig. 2)

The old plugin card called anything enabled-but-not-active "abnormal." The
calculus distinguishes states with different meanings, and MC now models all
of them: **active / disabled / waiting / transitioning / failed** + a
**stuck** flag (same transitional phase >60 s). Semantics encoded: waiting
(dependency unsatisfied) is benign — the fiber self-activates when a provider
appears, no alarm; a stuck UNLOADING is the withdrawal guard waiting on
dependents — named alarm; FAILED is terminal until config is touched (the
calculus never auto-retries, by design — L-Begin requires a clean Inactive) —
always-actionable red. The HARNESS light now trips only on failed/stuck.

## 4. Bench-overlay memory isolation (§3.2.3 realms — and their limit)

Source dive verdict: `isolate` **is** implemented and wired in rc.7
(`cordis-plugin-loader`, `EntryOptions.isolate`, installed on every Loader) —
but it isolates *injected-service resolution*, and the memory MCP's actual
state boundary is an `env.MEMORY_FILE_PATH` handed to a spawned subprocess:
**outside the realm machinery** (a live illustration of the paper's §6.1
system boundary). So all three `bench-overlay-*.yml` files instead carry a
wholesale-replacement `mcp-memory` row pointing at
`~\.dsh\memory\bench-scratch-memory.json`. Bench and experiment sessions can
no longer write the production knowledge graph. All overlays validated with
`dsh --patch <overlay> --dump-config` (which stacks — itself a useful
discovery for future gates).

## 5. Architecture bar for future plugins (§6.1 boundary + §6.3 interception)

Added to `/delta-scan-halo`'s memory-layer upgrade gate: candidates that load
as **Cordis components** are preferred over external MCP processes — in-
paradigm plugins get guaranteed-clean removal (revertible effects) and
runtime capability attenuation (`intercept` — confirmed present in the same
loader hook as `isolate`, config-level override per context subtree; needs
its own investigation into which dsh services consult it before we rely on
it). External MCP processes sit outside the composability boundary: dsh can
revert nothing they do, and a native crash escapes the paradigm's failure
isolation entirely — which is the formal explanation for why one bad
BrowserMCP row could kill an entire boot.

## 6. Compensation for the unrevertible (§6.1 acquisition vs. emission)

The knowledge graph (`~\.dsh\memory\memory.json`) is an *emission*: a write
the harness cannot undo. Per the paper, the remedy for out-of-boundary
locations is **compensation** — so the scheduled task **HALO Memory
Snapshot** now takes hourly change-detected snapshots into
`~\.dsh\memory\snapshots\` (SHA256 dedup, last-60 rotation,
`Snapshot-Memory.ps1`). A bad memory write by any session or plugin now has
an undo path.

## Validated-by-theory (no change needed)

- **Stable model identifiers behind :1234** = the paper's *service broker*
  pattern (§6.2): model swaps never perturb consumers. Our loader-script
  pinning discipline is the broker pattern by another name — keep it.
- **`disabled:` toggles instead of row deletion** is the sanctioned reversible
  operation; the confluence theorem is why the config file alone determines
  the quiescent system, no matter the toggle history.

## Method note

Finding 1 was proven by live experiment before anything was built on it;
finding 4's mechanism was chosen only after the preferred mechanism was
ruled out *from source, with citations* (comment blocks in the overlays carry
the file/line evidence). Implementation: three Sonnet agents (deploy, MC,
isolation) + direct edits (docs, delta-scan gate, snapshots); all verified on
the box against the running harness.

**Incident during this work — and what it added.** The transactional deploy's
own live test ran while four sets of fresh live edits (MC upgrade, overlay
isolation, skill + AGENTS.md edits) had not yet been synced to the repo — and
overwrote them all with older repo copies. Two lessons landed as code: (a) the
new backup stage had captured every clobbered file seconds before the
overwrite, so recovery was a copy-back — the transactional design paid for
itself against its own test; (b) the missing check was *drift detection*, so
the deploy now has a first stage that aborts (naming the files) whenever a
live target is newer than and different from its repo source — "run
Sync-FromLive first, or set DEPLOY_FORCE=1." The guard was verified against
the real post-incident state: it caught exactly the six affected files.
