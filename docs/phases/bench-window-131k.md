# Bench: brain @ ctx 131072 / KV q8_0 window-expansion candidate — 2026-08-19

Decides "Phase 1 window expansion" of the output-wall plan: is running the brain
(`unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf`, trained max ctx 262144) at
context 131072 with KV cache q8_0/q8_0 livable on HALO, compared to the production
identity `qwen/qwen3.8-27b` (ctx 65536, KV f16, loaded by
`C:\Users\scott\.lmstudio\scripts\Load-OpenCode-Qwen.mjs`)?

Machine: HALO (Strix Halo APU), Windows 11 Pro 10.0.26200, 128 GiB unified RAM,
GPU carveout 64.2 GiB (Mission Control `gpu.carveoutGiB`). LM Studio 0.4.21, engine
`llama.cpp-win-x86_64-vulkan-avx2@2.28.2`. Server `127.0.0.1:1234`, SDK/`api/v0`
helpers in `C:\Users\scott\Desktop\Code\halo-bench-day3\scripts\lib.mjs`. Truth
source for residency/applied-context: `lms ps --json` only. GPU pool watched via
`http://127.0.0.1:3090/api/status` (`gpu.dedicatedGiB` / `sharedGiB`); shared-pool
baseline on this box is ~1.4-1.5 GiB, growth beyond that = spill = FAIL finding.

Scripts: `bench-loader-config.mjs` (shared config), `Load-Bench-131k.mjs` (standalone
loader, copied/adapted from `Load-OpenCode-Qwen.mjs` with soft, non-throwing config
checks since `gpuStrictVramCap:true` can auto-size context down), and
`window-131k-bench.mjs` (the actual orchestration: side-load attempt, fallback,
cells, restore trigger). Raw data:
`C:\Users\scott\Desktop\Code\halo-bench-day3\results\window-131k-raw.jsonl`; console:
`...\results\window-131k-console.log`.

## Verdict

**ADOPT-CANDIDATE**, with one operational caveat (below). All three criteria met:

| Criterion | Bar | Measured | Pass? |
|---|---|---|---|
| Applied context | ≥ ~120K | **131,072** (full request, zero auto-sizing) | Yes |
| Deep decode, 80-100K depth | ≥ ~8 tok/s | **9.02 tok/s** at 109,893 prompt tokens | Yes |
| Shared-pool growth during measurement | none | **0.0-0.2 GiB** noise across all 5 cells (1.5→1.6 GiB max) | Yes |

Caveat: this verdict is for the brain running **alone** at ctx 131072/q8_0 (the normal
production shape — one brain, one config). Side-loading a **second** copy of the
brain next to the production instance to test capacity headroom did **not** stay
clean — see Surprise #1. That path isn't part of normal operation, so it doesn't
block the verdict, but it does mean the "~27 GiB needed vs ~37 GiB free" capacity
napkin-math from the task brief was optimistic by a little over 1 GiB in practice.

## Five headline numbers

1. **Applied context: 131,072** — LM Studio granted the full requested context with
   `gpuStrictVramCap:true` on; no auto-sizing occurred (contrary to the expectation
   that it might shrink to fit VRAM).
2. **Fresh 19.5K prefill: 179.6 tok/s, TTFT 109.2 s** — statistical parity with the
   production baseline (181 tok/s, 108.6 s) despite double the context ceiling and
   quantized KV cache.
3. **Deep decode at ~110K depth: 9.02 tok/s** — matches production's own "~10 tok/s
   deep at 65K" citation, at nearly double the depth.
4. **Cached follow-up TTFT at ~110K depth: 29.7 s** — a real ~17.7× speedup over the
   528 s cold prefill at the same depth, but notably slower than the 13.4 s cached
   figure cited at 19.5K depth — cache-assisted cost is not flat with depth.
5. **Zero shared-pool growth across all 5 measurement cells** on the solo-load path
   (dedicated 27.7-27.9 GiB, shared 1.5-1.6 GiB throughout) — clean by the bench's
   own FAIL/PASS bar.

## Method

Probe content: `probes/prose-19_5k.txt` (~19.6K tok) + `probes/prose-depth-extra.txt`
(~10.5K tok), concatenated to build deeper prompts, per the existing harness
convention (`gen-probes.mjs`, reused unmodified from `halo-bench-day3`). Same prose
content family used throughout for internal consistency; not the literal real-
diagnostic-task prompt behind the phase-2 "26.9 tok/s short decode" figure (day 3's
report already flagged that as an open, unresolved apples-to-oranges gap — carried
forward here, not re-litigated). Decode = ~400 tokens per cell (200 for the cached
follow-up). MTP stock (`speculativeDraftMtp:true`, `n=4`), matching production.

Deep prompts share exact prefixes by construction (`block = short+extra` repeated),
so per the same caveat used in `bench-day-3-results.md`: deep-cell **prefill/TTFT are
partially cache-assisted** from the immediately preceding cell in the same session
(LM Studio prefix cache, `contextCheckpoints:32`) — **decode tok/s is the trustworthy
depth number**; TTFT/prefill-tok/s at depth should be read as "warm follow-up," not a
fully cold prefill, except cell b (genuinely cold/fresh) and the genuinely-cold
portion of cells c/d beyond their cached prefix.

## Pre-state

`lms ps --json`: `qwen/qwen3.8-27b` (production, local, ctx 65536, idle) and
`qwen/qwen3.8-27b-5070ti` (foreign, `deviceIdentifier` non-null, remote peer device
"NvideaBlackwell" — the RTX 5070 Ti tester box via LM Studio fleet — ctx 32768,
idle). MC gpu: `dedicatedGiB:27.4`, `sharedGiB:1.4`, `carveoutGiB:64.2`. The foreign
model stayed idle for the entire bench window — checked via `lms ps --json` before
and after every cell — never contaminated a measurement.

## Load: side-load attempt, then solo-load fallback

Attempted to load `bench/brain-131k` (ctx 131072, KV q8_0) **next to** the resident
production brain, per the task's capacity math (weights ~19.7 GiB + KV q8_0 at
131072 tok ≈ 131072 × 56 KB/tok ≈ 7 GiB ≈ 26-27 GiB more, against ~37 GiB headroom
under the 64.2 GiB carveout).

The load call itself **succeeded** (no exception, both models showed resident in
`lms ps`), but Mission Control's shared pool grew from the 1.4 GiB baseline to
**2.5 GiB** (+1.1 GiB) — a spill, past the discipline threshold. Per the task's stated
fallback rule, this was treated as a FAIL for the side-load path: unloaded
`bench/brain-131k`, then unloaded production `qwen/qwen3.8-27b`, then loaded
`bench/brain-131k` alone (**solo-load path**).

Solo-load: 9,520 ms, applied `contextLength: 131072` (no auto-sizing), KV config
confirmed `useFp16ForKVCache:false`, `llamaKCacheQuantizationType:"q8_0"`,
`llamaVCacheQuantizationType:"q8_0"`, `speculativeDraftMtp:true`,
`speculativeDraftMaxTokens:4`, `flashAttention:true`, `gpuStrictVramCap:true`,
`maxParallelPredictions:1`. Post-load MC: `dedicatedGiB:27.8`, `sharedGiB:1.5` — back
at baseline, clean.

## Cells (all against `bench/brain-131k`, solo-loaded, ctx 131072, KV q8_0)

| Cell | Label | Prompt tok | TTFT (s) | Prefill tok/s | Decode tok/s | Draft accept | Shared GiB (pre→post) | Dedicated GiB (pre→post) |
|---|---|---|---|---|---|---|---|---|
| a | short-decode | 76 | 6.56 | 11.58 | **15.65** | 173/365 (47.4%) | 1.5→1.5 | 27.8→27.8 |
| b | fresh-prefill-19.5k | 19,611 | 109.17 | 179.63 | **17.37** | 140/232 (60.3%) | 1.5→1.6 | 27.8→27.8 |
| c | deep-60k | 60,249 | 302.43\* | 199.22\* | **14.60** | 186/319 (58.3%) | 1.6→1.6 | 27.8→27.9 |
| d | deep-100k | 109,893 | 528.39\* | 207.98\* | **9.02** | 238/397 (59.9%) | 1.6→1.5 | 27.9→27.7 |
| e | cached-followup-100k | 109,905 | 29.73 | 3696.66\*\* | **14.19** | 56/79 (70.9%) | 1.5→1.5 | 27.7→27.7 |

\*cache-assisted (shares a prefix with the immediately preceding cell — see Method).
\*\*cell e's "prefill tok/s" is an artifact of the near-total prefix-cache hit
(only the short appended suffix was genuinely new); read TTFT and decode instead.

No cell was contaminated (`checkNoForeignGenerating` clean pre- and post- every cell;
foreign model `qwen/qwen3.8-27b-5070ti` stayed idle throughout). Final MC reading:
`dedicatedGiB:27.7`, `sharedGiB:1.5`, `carveoutGiB:64.2` — flat vs pre-state.

## Comparison to production baselines

| Metric | Production (ctx 65536, KV f16) | Bench (ctx 131072, KV q8_0) | Delta |
|---|---|---|---|
| Fresh prefill @ ~19.5K | 181 tok/s (TTFT 108.6 s) | 179.6 tok/s (TTFT 109.2 s) | parity (~1%) |
| Cached TTFT (shallow) | 13.4 s | — (not retested shallow; see cell e for depth) | — |
| Short decode | 26.9 tok/s (real diagnostic prompt, phase-2) | 15.65-17.37 tok/s (synthetic prose, this + day-3 sessions) | not apples-to-apples — day-3 already flagged this content-type gap as unresolved; same-content-family comparison is day-3's own 13.85-15.82 tok/s stock-n4 prose/structured short, which this bench modestly **beats** |
| Deep decode @ ~65K (production) / ~110K (bench) | ~10 tok/s | 9.02 tok/s | parity, at ~1.7× the depth |
| GPU shared pool | ~1.4 GiB baseline | 1.5-1.6 GiB across all cells | clean |

KV q8_0 continues to show **no measured throughput penalty** vs f16 on this
Vulkan/AMD engine build, consistent with `bench-day-3-results.md`'s locked verdict
("KV q8_0 does NOT become the brain's default" was about *no upside*, not a
penalty) — now extended to double the context length, where the upside (reaching
depths production's ctx ceiling cannot physically hold) is real and load-bearing.

## Surprises

1. **Side-loading next to production spilled the shared pool** (1.4 → 2.5 GiB) even
   though the naive weights+KV capacity math said it should fit with ~10 GiB to
   spare. The gap is likely compute-buffer/scratch overhead (batch buffers,
   `contextCheckpoints:32` bookkeeping, etc.) that the simple weights+KV formula
   doesn't account for. Solo-load worked cleanly. This is a capacity-margin finding,
   not a blocker — normal production operation runs one brain config, not two
   simultaneous copies.
2. **Applied context needed zero auto-sizing** — `gpuStrictVramCap:true` granted the
   full 131,072 requested tokens on the solo-load path without shrinking it, contrary
   to the task brief's stated expectation that it might come back lower.
3. **Decode speed held up better than expected at depth**: 14.6 tok/s at 60K and
   9.0 tok/s at 110K are both in the same range as (or better than) production's own
   same-content-family numbers at shallower depths in `bench-day-3-results.md`
   (13.85-19.88 tok/s at 30K). The context-length doubling plus KV quantization did
   not compound into a decode-speed cliff.
4. **Cached-turn TTFT is not depth-invariant**: 29.7 s at ~110K depth vs the 13.4 s
   figure cited at ~19.5K depth, even with a near-total prefix-cache hit. Worth
   setting UX expectations accordingly if this window ever ships — "cached" at deep
   context is fast relative to cold (17.7×), but not free.

## Restoration

`bench/brain-131k` unloaded at the end of the bench run (script-driven). Ran
`C:\Users\scott\.lmstudio\scripts\Load-OpenCode-Qwen.mjs` unmodified — loaded clean,
**zero** config mismatches against its own strict `expected` assertions (the script
would have thrown and unloaded on any mismatch; it didn't). Verified via
`lms ps --json`: `qwen/qwen3.8-27b` resident, `contextLength:65536`, `status:"idle"`,
`unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf`. Final MC gpu reading:
`dedicatedGiB:20.5`, `sharedGiB:1.2`, `carveoutGiB:64.2` (lower dedicated than the
pre-bench 27.4 GiB reading because KV cache allocates lazily/idle right after a
fresh load, before any generation touches it — expected, not a discrepancy). No
commits made; no changes outside `halo-bench-day3/` and this report.
