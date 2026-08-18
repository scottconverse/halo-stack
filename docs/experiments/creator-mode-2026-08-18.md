# Experiment record: Creator-mode plugin authorship on local silicon
**Date:** 2026-08-18 · **Status:** final section pending (32K one-shot verdict + Mission Control acceptance)

## Question
Can the stack's local brain (Qwen3.8-27B UD-Q5_K_XL, Vulkan, ~10–27 tok/s)
do what the Creator-mode demos show big cloud models doing: author and mount
a working UI plugin onto the RUNNING harness from a plain-English request?
Secondary question (operator-framed): what is the honest wall-clock cost —
"the full picture of what it's capable of, and what the cost of that is."

## Task
"Build a memory graph view INSIDE DSH itself" — an Obsidian-style visual
graph of the knowledge-graph memory file: nodes colored by entity type,
pan/zoom, click-without-drag opens observations, re-read on open,
dependency-free.

## Verdict up front
**YES — with a price tag and a ceiling.** The local model autonomously chose
the correct architecture, authored SEVEN package iterations, and mounted two
working versions (v1 counts panel, v2 colored SVG graph + legend) onto the
live cockpit. Every architectural decision it made was correct. The cost was
~4.5 hours of wall clock, dominated by deliberation at ~10 tok/s deep-context
decode, six output-cap truncations (five of which were self-inflicted by our
own conservative reply budget), and several operator steering interventions.

## The good
- **Turn 1, unprompted, correct problem classification:** "a dynamic Cordis
  plugin task, specifically a client-side plugin that registers UI into a
  slot of the existing page" — then loaded the harness's own
  cordis-plugin-development skill and inspected the live composition.
- **Correct mount point discovered by inspection:** the `conversation.view`
  slot ("one list entry per view tab"), plus the client/host split
  (React + slots.register client-side; harness.handle/fs.readText host-side).
- **Engineering judgment throughout:** verified the memory file honestly
  (5 entities, 0 relations — true); read uncertain fs contracts defensively
  ("only use mtime if the field exists"); scope-trimmed ("skip mtime; the
  user didn't ask"); checked THEME TOKENS so the panel matched the cockpit's
  chrome; mouse-anchored zoom math derived correctly in-head.
- **Real iterative debugging:** v1's client half revealed the need for the
  host-side read-memory RPC → v3 "both halves"; SVG rendering issues walked
  through v4→v7. `cordis_inspect_self` used to verify its own mounted state.
- **The harness machinery held:** two clean compactions mid-build with
  working knowledge preserved; the person-in-the-loop plugin approval gate
  appeared exactly as the Cordis paper specifies (and survives even
  danger-full-access — the one gate that does); "Allow future versions"
  covered all seven iterations with one approval.
- **v1 and v2 ran, live, with correct data** — verified end to end
  (client tab → host RPC → real memory.json → correct counts and entities).

## The bad
- **~10–11 tok/s deep-context decode set the tempo.** TTFT averaged ~60s per
  turn; single thinking passes ran 20–50 minutes. Totals at the end of the
  session-proper: **9 turns · 33 steps · 4h14m LLM time · 1.1M tokens in ·
  148K out · cache-hit 0% (cosmetic) · six output-cap hits.**
- **The model over-deliberates for its hardware.** The judgment quality was
  senior-engineer; the deliberation style was trained on silicon where
  thinking is nearly free. On 256 GB/s it is not free. (This is the
  ThinkingCap watch item's entire justification.)
- **`cordis_define` semantics compound the cost:** every define re-emits the
  WHOLE plugin source — no deltas — so as the plugin grows, each iteration's
  reply gets bigger, and a growing artifact eventually collides with any
  reply cap.
- **Dynamic plugins are process-memory-only** (as the paper says): a browser
  refresh dropped the running fiber; packages remained defined ("Ready") and
  one Run re-mounts, but nothing survives without permanent registration.

## The ugly (operator-side failures, on the record)
1. **The reply cap was ours, and we ratcheted instead of fixing.** maxTokens
   is a LENGTH cap with zero speed cost. We started at 8,192 and raised it
   8K→16K→24K reactively, causing repeated 20–50-minute truncated passes.
   The correct move — set it generously up front — was taken only at the
   end (32,768). Most of the "six cap hits" line above is this mistake.
2. **An unmeasured assertion was presented as fact.** After the 24K cap hit,
   the orchestrator claimed full v3 "exceeds any reply budget — it's
   architectural" without measuring the actual source size. The honest state
   was "bigger than 24K, untested at 32K." The 32K one-shot (verdict below)
   is the measurement that should have preceded the claim.
3. **A stale browser view was reported as live state.** The orchestrator told
   the operator the plugin "is still running" while the operator's own screen
   showed 0 running — the automated browser tab had cached pre-refresh state.
   Rule reinforced: verify from the operator's vantage point, never from a
   cached one.
4. **The operator's sequencing instruction was inverted.** "HALO first — if
   it can't, you do it" was executed as "Sonnet immediately, HALO retro-
   actively." The cloud-built Mission Control graph is good and wanted, but
   the local model deserved its uncrippled attempt first, as ordered.
5. **A phantom measurement:** a "1 relation" reading came from PowerShell's
   `@($null).Count == 1` artifact in the verification probe, not from data.
   Caught before it entered the record — barely.

## Where it lands (wiring)
- **Cockpit (HALO's work):** the plugin packages pkg-1…pkg-7 remain defined
  in the session; v2 re-mounts with one Run click. The 32K one-shot v3
  attempt answers the operator's "would 32,768 have continued?" —
  **[VERDICT PENDING — appended below when the run completes]**
- **Mission Control (permanent home):** a new **Memory** tab — full
  interactive force-directed graph (wheel-zoom at cursor, drag-pan, node
  drag, click→detail panel with observations + clickable connections),
  reading the same memory.json via /api/memory-graph. Built by a Sonnet
  agent against an operator-approved spec in minutes, versioned in this
  repo, survives refreshes — because a GRAPH belongs on the glass, not
  hidden in a chat tab. **[ACCEPTANCE PENDING — verified interactions
  appended below]**
- Division of labor, recorded plainly: the local model proved it CAN author
  live plugins (and what it costs); the dashboard got the durable,
  always-visible implementation via the orchestration tier. Both are the
  stack working as designed — the mistake was the order, not the outcome.

## Standing lessons adopted
- maxTokens generous by default; it is not a throttle. (settings.yaml now
  32,768 with a comment saying why.)
- Sweeps and claims include the null config / the actual measurement —
  "assert after measuring" applies to ourselves, not just vendors.
- Verify UI state from the operator's vantage point (fresh navigation, not
  cached automation tabs); DOM-click, not coordinate-click, in the cockpit.
- Dynamic-plugin keepers must be permanently registered AND synced to the
  repo like any other config surface (manual §Creator mode).

---
## Appendix A — 32K one-shot verdict (measured, 2026-08-18 evening)
The operator's question — "would 32,768 have continued?" — got its empirical
answer: **no, and for a more interesting reason than the cap.** With
maxTokens raised to 32,768, the one-shot reply truncated at ~25.1K tokens —
**below the configured budget**. The binding constraint had moved: the
session sat at ~54% of its 65,536-token window, leaving ~25K of room, and a
reply can only be as large as the space remaining. The harness's compaction
fires BETWEEN turns at 80% — nothing can rescue a single reply that
outgrows the window mid-emit.

Findings this hardens:
1. The earlier caps (8K/16K/24K) were self-inflicted and cost real hours —
   that stands. But even a generous cap cannot beat the window: the
   effective reply budget is always `min(maxTokens, context room)`, and a
   mature session simply cannot host a monolithic ~30K+ emit.
2. Full-v3-in-one-shot on this stack requires a YOUNG session (fresh
   context ≈ 50K of room after system+tools). Untested here — predicted
   viable — but by this point the Mission Control implementation had
   superseded the deliverable, so burning another hour of GPU to prove a
   corollary wasn't worth it. Recorded as the expected result, clearly
   labeled unverified.
3. The durable lesson for creator-mode work: **incremental packages sized
   well under the remaining window are the only strategy that scales with
   session age** — which is what the split-increment steering had converged
   on before the question was re-opened.
4. Total experiment bill at close: **10 turns · 34 steps · 4h59m LLM time ·
   1.1M tokens in · 173K out · seven cap/window truncations · two clean
   compactions.** The capability verdict from the main body stands
   unchanged: the local brain CAN author and mount live plugins; the
   monolithic-emit pattern is what cannot survive a long session.

## Appendix B — Mission Control Memory tab acceptance (PASSED, 2026-08-18 evening)
Built by a Sonnet agent against an operator-approved spec (~6 min build);
accepted by independent orchestrator verification, not the builder's word:
- Render: 5 nodes + 5 labels + full type legend + correct header counts
  ("Memory Graph · 5 entities · 0 relations") — structural check on the
  live page.
- Wheel-zoom, cursor-anchored: transform re-solved translate AND scale
  together (measured: scale 0.990→1.109 with translate shifting
  40.4,7.5 → 28.7,−9.6 — zoom toward pointer, not origin).
- Click-node → detail panel: opened with the entity's REAL observation
  text; connections list is index-addressed (no name-interpolation
  injection surface).
- Node drag: verified — node moved 46×40 px on screen via the bound
  mousedown/document-mousemove sequence. (First two drag probes failed
  from tester error — wrong event type, then a null==null comparison —
  a miniature rerun of the day's lesson: verify the test before trusting
  its verdict.)
- Refresh + tab-open re-fetch, and the labeled degraded state on API
  failure, verified by the builder; relations parsing extended
  backward-compatibly ({entities, relations, relationCount, tripwire}).
- Visual appearance: pixel-verified by the operator directly ("WHOA").
Placement rationale, per operator directive: a graph belongs on the
dashboard glass, not hidden as a tab above a chat. This is the permanent,
versioned, refresh-surviving home; the cockpit plugin remains the
capability proof.
