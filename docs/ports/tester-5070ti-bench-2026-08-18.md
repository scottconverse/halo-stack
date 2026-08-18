# Port study: HALO stack config on an RTX 5070 Ti 16GB (Blackwell)

**Status: model/engine layer benched thoroughly; the HARNESS layer was NOT
deployed** — the dispatch prompt from the orchestrator mislabeled the dsh
install "optional, only if time allows," inverting the operator's actual
purpose (testing halo-stack portability). The bench below is the engine
half of the answer; a follow-up run owes the harness half. Recorded as the
second purpose-inversion of 2026-08-18 (see
`docs/experiments/creator-mode-2026-08-18.md`, "the ugly").

What this run DID establish, in one line each:
- **Prefill is a rout on CUDA:** 1,547 tok/s vs HALO's 181 (8.5×); this
  box's COLD 19.5K TTFT (12.6 s) beats HALO's CACHED turn (13.4 s).
- **KV q8_0 is the unlock on 16 GB:** depth decode 17.8 → **42.3 tok/s**
  at 30K with no visible quality change; q4_0 is SLOWER than q8_0
  (dequant overhead) — q8_0 is the sweet spot.
- **MTP must be dropped on this CUDA engine** (decode roughly thirds;
  one nuance: high-acceptance code tasks on the hybrid config still
  benefited — engine- and workload-specific, not universal).
- **Two silent killers for NVIDIA deploys:** driver memory-clock parking
  (P3 @7,001 MHz halves decode — check `nvidia-smi
  --query-gpu=clocks.mem,pstate` under load) and the server's default
  4 parallel slots (KV ×4 → spill → halved decode; `parallel: 1` needs a
  wire-level key on current builds).
- **The ceiling:** the actual HALO brain (21 GB Q5 @65K) is physically
  impossible in 16 GB; Q3/Q4-class @32K (clamped to 32,000 by the server)
  is the box's quality ceiling, and the Q4 hybrid costs 3–5× decode.
- **Best-value config found:** UD-Q3_K_XL · 100% GPU · 32K ctx · KV q8_0 ·
  MTP off · FA on → 12.6 s cold TTFT / 0.9 s cached / 42 tok/s @30K /
  59 s coding task.

Portability verdict so far: flash attention, parallel 1, and
contextCheckpoints transfer; Vulkan-era MTP defaults and f16 KV do NOT —
**the loader profile needs a per-engine overlay, not a copy.**

---

The full report as filed by the TESTER session (verbatim):

# TESTER bench — RTX 5070 Ti 16GB vs HALO baselines

Date: 2026-08-18. Bench harness: `Desktop\CODE\halo-bench-5070ti\` (bench.mjs /
fixtask.mjs, raw per-run JSONs alongside). Method mirrors
`docs/phases/phase2-bench-results.md`: ~19.5K-token probe prompt, `api/v0`
stats + wall-clock, `lms ps --json` as the only residency truth source,
two-bug node repo verified on disk. Every number below was measured on this
machine during this session; nothing is quoted from spec sheets except where
labeled.

## Machine (as measured)

| Component | Measured |
|---|---|
| CPU | AMD Ryzen 7 7800X3D, 8C/16T |
| RAM | 31.6 GiB usable (32 GB) |
| GPU | NVIDIA GeForce RTX 5070 Ti, 16,303 MiB VRAM, driver 596.36 |
| OS | Windows 11 Pro 26200.9168 |
| Server | LM Studio headless service, port 1234; CLI commit 07b7252 |
| Engine | `llama.cpp-win-x86_64-nvidia-cuda12-avx2@2.28.2` (CUDA, not Vulkan), flash attention ON |
| Node | v24.15.0 |

Models (byte-verified against HF listing after download):
`unsloth/Qwen3.8-27B-GGUF` → UD-Q3_K_XL 13,441,059,904 B; UD-Q4_K_XL 17,923,394,624 B.

Load profile mirrored from `lmstudio/Load-OpenCode-Qwen.mjs` (flash attention,
contextCheckpoints 32, parallel 1, KV on GPU), except context 32,768 not 65,536.
**Server quirk:** every load path (CLI and SDK) clamps the requested 32,768 to
an applied **32,000** — reported by `lms ps --json`; all "32K" rows below ran at
32,000 applied context.

## Configs tested

- **A — fits-in-VRAM:** UD-Q3_K_XL (13.44 GB), 100% GPU offload, strict VRAM cap.
  Verified true fit: 15.1–15.4 GiB dedicated VRAM, GPU shared pool flat at the
  ~0.6–0.7 GB desktop baseline with q8_0/q4_0 KV. **Caveat:** with **f16 KV** at
  32K the working set slightly exceeds the card — ~0.8 GB sits in the GPU shared
  pool (the exact spill failure mode Mission Control alarms on) and depth decode
  pays for it. IQ4_XS (15.71 GB) was rejected up front: weights alone ≈ usable VRAM.
- **B — quality parity, hybrid:** UD-Q4_K_XL (17.92 GB), GPU ratio 0.7
  (~15.2 GiB dedicated + ~2.7 GB of weights in system RAM, clean split, shared
  pool at baseline). LM Studio's "auto" instead produced a driver-managed spill
  (~4.5 GB in shared pool) — measured decode was identical (8.6 vs 8.7 tok/s),
  so the hybrid's ceiling is the CPU-resident slice either way.

MTP speculative decoding at stack defaults (n=4, p=0.5) was measured in full and
**turned off for the headline rows** — see finding 2.

## Results (MTP off, as-shipped clocks; HALO baselines from phase-2 record)

| Metric | A: Q3_K_XL all-GPU | B: Q4_K_XL hybrid | HALO (Q5, 65K ctx) |
|---|---|---|---|
| Cold prefill, 19.5K probe | **1,547 tok/s** | 1,124 tok/s | 181 tok/s |
| TTFT cold, 19.5K | **12.6 s** | 17.4 s | 108.6 s |
| TTFT cached follow-up | **0.93 s** (13.6×) | 2.6 s (6.8×) | 13.4 s (8.1×) |
| Decode short ctx | **25.4 tok/s** | 9.2 tok/s | 26.9 tok/s |
| Decode @ ~30K, KV f16 | 17.8–18.2 tok/s | 4.8 tok/s | ~10 @ 65K deep |
| Decode @ ~30K, KV q8_0 | **42.3 tok/s** | 6.1 tok/s | — (f16 only) |
| Decode @ ~30K, KV q4_0 | 30.0 tok/s | 7.7 tok/s | — |
| 30K cold prefill TTFT | 19.0–20.3 s | 24.9–25.7 s | — |
| Coding task (two-bug repo, to verified fix) | **59.4 s** | 125.8 s | 176 s (Q5 brain) |

Coding task passed on attempt 1 in every configuration, verified by running the
test suite on disk. (HALO's 176 s was via the dsh harness; here a scripted
single-shot fix loop against `api/v0` — same task shape, lighter wrapper.
The optional dsh-harness install was skipped; session time went to the
performance diagnosis below.)

KV-sweep quality check (code-explanation at 30K depth, all three KV levels):
all three produced technically correct debounce explanations; no
KV-quantization-attributable degradation was visible. Amusingly q4_0 gave the
cleanest finished answer — f16 and q8_0 burned their token budget
word-counting inside the reasoning block (model behavior, not KV corruption).

## Findings the numbers forced

1. **KV q8_0 is the unlock on 16 GB, not a compromise.** At 32K, f16 KV
   overflows the card by ~0.8 GB and depth decode drops to ~18 tok/s; q8_0 KV
   fits everything and depth decode **more than doubles to 42.3 tok/s** — with
   no visible quality change. q4_0 is slower than q8_0 (30.0; dequant overhead)
   — classic llama.cpp behavior, q8_0 is the sweet spot.
2. **MTP (stack default on HALO) actively hurts on this CUDA engine.** Full
   battery both ways: MTP-on cut decode from 25.4→7.9 (short) and 18→4 (deep),
   prefill 1,547→1,040, and pushed ~2.5 GB into the shared pool. One nuance:
   on config B the coding task ran *faster* with MTP on (98.3 s vs 125.8 s —
   code has high draft acceptance); every other cell got worse. On A it was
   worse there too (136.2 s vs 59.4 s). Single runs, but the direction is
   unambiguous: **MTP off on CUDA/16 GB.**
3. **Driver clock-parking can silently halve decode.** Early runs measured
   3–10 tok/s with GDDR7 parked at 7,001 MHz (P3) under load; later runs
   boosted correctly (13,801+ MHz, P1) at stock settings. A memory-clock lock
   via nvidia-smi was tested (needs admin) and then reverted; final numbers
   are as-shipped driver behavior. If a HALO-stack deploy on NVIDIA measures
   absurdly low decode, check `nvidia-smi --query-gpu=clocks.mem,pstate` under
   load before blaming the stack.
4. **`parallel: 1` matters.** The server defaults to 4 parallel slots; at 32K
   that multiplies KV reservation, spills several GB to the shared pool, and
   halves decode. The stack's `maxParallelPredictions: 1` must survive the
   port to this box (wire key `llm.load.numParallelSessions` on current
   server builds; public SDK 1.5.0 predates it — bench.mjs documents the
   wire-level injection).

## Verdict (5 lines)

1. **Prefill/compute is a rout:** 1,547 tok/s vs 181 — 8.5× HALO; this box's *cold* 19.5K TTFT (12.6 s) beats HALO's *cached* TTFT (13.4 s), and its cached turn is ~1 s — the prefix-cache architecture HALO depends on is a nice-to-have here, not load-bearing.
2. **Deep-context decode, the right way:** with KV q8_0, 42 tok/s at 30K — ~1.6× HALO's short-context rate and ~4× its deep rate; the CUDA card turns HALO's worst case into this box's best case.
3. **What it can't do:** the stack's actual brain (21 GB Q5_K_XL at 65K ctx) and two-model residency are physically impossible in 16 GB — quality ceiling is Q3/Q4-class weights at 32K, and the Q4 hybrid costs ~3–5× decode for one quant step of quality.
4. **Config that transfers, config that doesn't:** flash attention + parallel 1 + contextCheckpoints transfer fine; Vulkan-era MTP defaults must be dropped, and KV must be quantized to q8_0 — the HALO loader profile is not portable as-is.
5. **Best-value config found:** UD-Q3_K_XL, 100% GPU, 32K ctx, KV q8_0, MTP off, flash attention on — 1,547 tok/s prefill / 12.6 s cold TTFT / 0.9 s cached / 25 tok/s short / 42 tok/s @30K / 59 s coding task, all with ~1 GB VRAM to spare.
