# Redundancy audit — halo-stack vs DeepSeek Harness (2026-08-17)

Two independent audits of the claim "nothing custom in this stack was redundant":
a doc-level external review, and an adversarial source-level audit against the
dsh-v0.1.0-rc.7 tree. The claim did **not** fully survive. Verdicts:

| Finding | Verdict | Status |
|---|---|---|
| `Start-DSH.ps1` launcher | HOLDS — dsh ships no daemon/readiness/browser orchestration | keep |
| delta-scan & reddit-search skills | HOLDS — sanctioned extension surface; shipped scheduler is session-scoped and couldn't do the job | keep |
| Stock MCP memory server | HOLDS — no native memory capability exists in dsh | keep (upgrade watch in delta-scan) |
| `halo-standard` preset, bench overlays | HOLDS — config surfaces used as intended; Minimal mode benches raw models, not realistic tasks | keep |
| **Mission Control** | **REFUTED as claimed.** dsh ships session/workspace/job/plugin-inventory RPCs (`apiproxy`) and a client UI-extension architecture (`ui-slots`); MC hand-parses the sessions dir instead of consuming them. Legitimately outside dsh: the LM Studio model card, RAM, and the start-when-dsh-is-dead role | **refactor tracked** (below) |
| EXA key in `.env` vs `.credentials.yaml` | PARTIALLY REFUTED — `.env` is visible to every model-spawned subprocess; `.credentials.yaml` is the blessed isolated store | **accepted as deliberate** (below) |
| No `AGENTS.md` at workspace root | PARTIALLY REFUTED — dsh auto-loads it (64KB budget); sessions started blind to the stack's own bug list | **fixed** — `workspace/AGENTS.md` written and deployed |
| No `--dump-config` gate on config changes | PARTIALLY REFUTED — shipped validator catches silently no-op'd patch rows | **fixed** — Sync-FromLive now runs it and surfaces warnings |

## Remediations

1. **AGENTS.md** (fixed): `C:\Users\scott\Desktop\Code\AGENTS.md` now carries the
   operational contract — workspace rule, the six bug workarounds, search-stack
   facts, memory conventions, conduct rules. Auto-injected into every cockpit
   session by dsh's shipped instruction loading. Synced as `workspace/AGENTS.md`.
2. **Config validation** (fixed): every `Sync-FromLive.ps1` run now ends with
   `dsh web --dump-config` and surfaces unmatched-patch warnings.
3. **Credential placement** (deliberate trade-off, documented): the Exa key is
   the *model's own tool credential* — the reddit-search skill and MCP row read
   it from env by design, so moving it to `.credentials.yaml` (never exported to
   env) would break both consumers. Risk accepted for a free-tier search key.
   Rule going forward: any credential the model should NOT be able to read goes
   in `.credentials.yaml` via the Settings UI; `.env` is only for keys the model
   is meant to use.
4. **Mission Control refactor** (DONE, same night): MC now consumes dsh's
   shipped `apiproxy` RPCs (`workspace.list` + `session.list` via
   `POST /api/<method>` with the client-request envelope) when the cockpit is
   up — gaining real session titles, presets, running state, turn counts, and
   correct workspace names — and falls back to the directory scrape only when
   dsh is down (its watchdog role). The UI badges which source is live. The
   build log's "duplicates nothing" claim is retracted; corrected here.

## Third audit (doc-level, independent) — adopted findings
A third review reached the same verdicts and added two accepted points:
- **Positioning**: halo-stack is not a harness and shouldn't read like one —
  it is *"a tested, reproducible local-AI workstation distribution built on
  DeepSeek Harness"*: the appliance layer (hardware tuning, boot orchestration,
  model lifecycle, Windows fixes, benchmarking, privacy validation, upgrade
  discipline) on top of DeepSeek's runtime. README updated accordingly.
- **Memory reclassified**: DSH's docs now list `@modelcontextprotocol/server-memory`
  as an official third-party interoperability example — so our memory choice is
  neither duplicated code nor a novel integration; it's the sanctioned pattern.

## Method note
The refuted claim was originally self-graded by the builder. This audit exists
because the operator challenged the self-grade. Lesson kept: claims about one's
own work get the same adversarial verification as vendor claims.
