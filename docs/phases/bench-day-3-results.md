# Bench day 3 results — 2026-08-19

Machine: HALO (Strix Halo APU), Windows 11 Pro 10.0.26200, 128 GiB unified RAM (64/64
GPU/system VGM split as configured), GPU carveout 64.2 GiB (Mission Control
`gpu.carveoutGiB`). LM Studio 0.4.21, engine `llama.cpp-win-x86_64-vulkan-avx2@2.28.2`,
`lms` CLI commit 71bd99c. Server: `127.0.0.1:1234` (`/api/v0`, LM Studio SDK). Truth
source for residency: `lms ps --json` only. GPU shared-pool watched via
`http://127.0.0.1:3090/api/status` (`gpu.sharedGiB`); abort/DNS threshold 8 GiB, per the
Strix Halo deep-dive's documented spill failure mode.

Method mirrors `docs/phases/phase2-bench-results.md` and
`docs/ports/tester-5070ti-bench-2026-08-18.md`: probe prompt calibrated to the loaded
model's own tokenizer (target ~19.5K tokens short, ~30K tokens resident at depth — see
per-model prompt-token counts in the tables below, all measured, not assumed), decode
= 500-token generation, two-bug-repo coding task on a **copy** of `dsh-bench-lab` (never
the original) with the `Math.ceil→Math.floor` bug in `daysUntilEmpty` planted by hand in
each copy before the model ever sees it. Raw data: `C:\Users\scott\Desktop\Code\halo-bench-day3\results\part1-raw.jsonl`
and `part2-raw.jsonl`; scripts in `...\halo-bench-day3\scripts\`.

## Contention incident (read this before the numbers)

Partway through Part 1, foreign LM Studio traffic from the operator's other machine (the
RTX 5070 Ti box; local identity `bench/qwen3.8-27b`, seen cycling Q3_K_XL/Q4_K_XL, plus
one load labeled `qwen3-coder-30b-a3b-instruct`) loaded and actively generated on this
same LM Studio instance, concurrently with three of my cells (`mmap-on`, `mmap-off`,
`brain-coding-task`), 2026-08-19T00:24:26Z–00:30:10Z. Two models were resident at once,
violating single-model exclusivity for those three cells. Confirmed live via `lms ps`
showing `bench/qwen3.8-27b` with `status:"generating"` when I checked.

I held Part 2, polled `lms ps --json` every 60 s, and proceeded only after 15
consecutive clean minutes (00:34–00:49Z, `gpu-wait.log`). The three original
contaminated rows are **retained, not deleted**, in `part1-raw.jsonl`, tagged with a
`CONTAMINATION_NOTE` marker; clean reruns (tagged `rerun:true`) replace them in every
table below. I declined a mid-task instruction to force-unload the foreign model while
it was actively generating, since destroying another live session's in-progress work
isn't something I can undo, and a live `lms ps` check was already telling me the risk
was real, not theoretical, at the moment I was asked.

**Operator decision item (not an action taken):** if this box is meant to be a
controlled bench/serving environment, HALO's LM Studio federation acceptance may deserve
a settings review — uncoordinated cross-machine load contention during a bench window is
exactly the failure mode this incident demonstrated live.

A second, unrelated harness bug surfaced in Part 2: the two MoE bake-off candidates both
initially "failed" the coding task, but on inspection both had actually diagnosed and
fixed the correct bug — my `maxTokens:1200` cap truncated their response before the code
fence (these models don't separate chain-of-thought into `reasoningContent` the way the
brain does), and after raising the cap, a second bug in my code-fence extraction grabbed
an early per-function reasoning snippet instead of the final full-file answer. Both bugs
are now fixed in `coding-task.mjs`; both candidates were rerun and both **passed**
cleanly (`eosFound`, not truncated). Final numbers below reflect the corrected reruns.

## Part 1 — Brain sweep (`qwen/qwen3.8-27b`, UD-Q5_K_XL, ctx 65536)

### 1a. MTP × content × depth

`prefillTps`/`ttft` for the **deep** rows are cache-assisted, not cold: each MTP config's
deep cell ran in the same loaded session immediately after its matching short cell, so
LM Studio's prefix cache (`contextCheckpoints:32`) reused the shared prefix. Treat deep
`decodeTps` as the trustworthy depth number; treat deep `prefillTps`/`ttft` as "warm
follow-up," not a cold 30K prefill (the KV-sweep table below has genuine cold 30K
numbers for comparison). Also note: both probe types are generated content (code tiled
from real repo files, prose built from templated sentence patterns) rather than fully
organic text — likely more predictable to the MTP draft model than diverse real text, so
draft-acceptance / MTP-benefit numbers here are probably an upper bound.

| MTP | Content | Depth | Prompt tok | Prefill tok/s | TTFT (s) | Decode tok/s | Draft accept |
|---|---|---|---|---|---|---|---|
| off | structured | short | 19,570 | 195.44 | 100.13 | **9.79** | — |
| off | prose | short | 19,611 | 195.20 | 100.47 | **7.31** | — |
| off | structured | deep | 30,078 | 452.07* | 66.53* | **6.91** | — |
| off | prose | deep | 30,155 | 449.83* | 67.04* | **7.38** | — |
| n=2 | structured | short | 19,570 | 184.65 | 105.98 | **12.20** | 171/233 (73.4%) |
| n=2 | prose | short | 19,611 | 185.88 | 105.50 | **13.16** | 137/180 (76.1%) |
| n=2 | structured | deep | 30,078 | 409.32* | 73.48* | **15.96** | 187/227 (82.4%) |
| n=2 | prose | deep | 30,155 | 410.50* | 73.46* | **16.01** | 229/297 (77.1%) |
| n=4 (stock) | structured | short | 19,570 | 183.09 | 106.89 | **15.82** | 165/253 (65.2%) |
| n=4 (stock) | prose | short | 19,611 | 184.29 | 106.41 | **13.85** | 148/230 (64.3%) |
| n=4 (stock) | structured | deep | 30,078 | 407.27* | 73.85* | **19.88** | 165/224 (73.7%) |
| n=4 (stock) | prose | deep | 30,155 | 407.91* | 73.93* | **16.83** | 262/405 (64.7%) |

\*cache-assisted, see note above.

Load times: off 12,888 ms; n=2 13,888 ms; n=4 14,033 ms.

### 1b. KV cache sweep at depth (MTP off, structured content, genuine cold 30K prefill — single cell per load, no prior warm-up call)

| KV | Prompt tok | Prefill tok/s | TTFT (s) | Decode tok/s |
|---|---|---|---|---|
| f16 (default) | 30,078 | 188.61 | 159.47 | **5.81** |
| q8_0 | 30,078 | 181.81 | 165.44 | **5.74** |
| q4_0 | 30,078 | 182.02 | 165.24 | **5.66** |

Cold-prefill TTFT here (~160–165 s for 30K) scales consistently with phase-2's cold
19.5K TTFT (108.6 s): 108.6 × (30/19.5) ≈ 167 s — sanity-checks against the prior.

### 1c. mmap on vs off (stock MTP n=4, KV f16, structured short; clean reruns after contamination)

| mmap | Load ms | Prompt tok | Prefill tok/s | TTFT (s) | Decode tok/s |
|---|---|---|---|---|---|
| on | 14,611 | 19,570 | 179.86 | 108.81 | **17.23** |
| off (current default) | 9,524 | 19,570 | 182.75 | 107.09 | **20.71** |

Single paired run each (not repeated). mmap off loaded ~35% faster and decoded ~20%
faster in this sample — directionally supports the existing `tryMmap:false` production
default; not enough repeats to call this a locked verdict on its own.

### 1d. Brain coding task, API-loop wrapper (stock config: MTP n=4, KV f16, mmap on, ctx 65536; clean rerun)

Wall-clock **25.6 s** (25,577 ms), **passed** (4/4 tests), 390 predicted tokens
(`eosFound`), decode 23.06 tok/s, draft accept 267/368 (72.6%). This is a lighter
single-shot wrapper against `/api/v0`, not the dsh harness (phase-2's 176 s figure) — it
is the correct baseline for comparing against the Part 2 candidates below, which used
the identical wrapper.

**Open question, not resolved this session:** even at the best MTP config, absolute
decode here (15.82 short / 19.88 deep on structured content) sits below the phase-2/deep-dive
citation of "26.9 short / ~10 deep." The likely cause is probe-content difference — my
synthetic tiled/templated probes vs. phase-2's real diagnostic-task prompt — affecting
MTP draft-acceptance rather than an engine regression, but this wasn't independently
verified this session. Worth a follow-up rebench against phase-2's literal prompt text
before treating today's absolute numbers as the new baseline.

## Part 2 — Bake-off round 1

### Load-fit story

| Candidate | Size | ctx attempted | Shared GiB | Load ms | Result |
|---|---|---|---|---|---|
| qwen/qwen3.6-35b-a3b (Q4_K_M MoE) | 22.1 GB | 65,536 | 0.8 | 13,191 | fit clean |
| unsloth/gemma-4-26b-a4b-it (Q4_K_S MoE) | 18.8 GB | 65,536 | 0.8 | 12,678 | fit clean |
| gpt-oss-120b (MXFP4) | 63.4 GB | 8,192 | **11.1** | 116,741 | **DNS** |

gpt-oss-120b: weights alone at the smallest tested context (8,192, minimal KV) already
spilled 11.1 GiB into the GPU shared pool against the 64.2 GiB carveout — over the 8 GiB
abort threshold — so the planned 16,384 escalation was never attempted (per the stated
rule: only escalate ctx if the smaller one fit clean). This box's current 64/64 VGM split
cannot host gpt-oss-120b; it would need the 96 GB Windows VGM path (deep-dive finding #7,
parked) to have a chance.

### Inference (structured content; deep rows partly cache-assisted, same caveat as 1a — each candidate's deep cell followed its own short cell in the same session)

| Candidate | Depth | Prompt tok | Prefill tok/s | TTFT (s) | Decode tok/s |
|---|---|---|---|---|---|
| qwen3.6-35b-a3b | short | 19,528 | 792.26 | 24.65 | **61.74** |
| qwen3.6-35b-a3b | deep | 30,036 | 1582.64* | 18.98 | **56.42** |
| gemma-4-26b-a4b-it | short | 21,400 | 268.11 | 79.82 | **40.73** |
| gemma-4-26b-a4b-it | deep | 32,817 | 319.17* | 102.82 | **31.47** |

\*cache-assisted.

(Note gemma's tokenizer is denser than Qwen's — 21,400/32,817 tokens for the same raw
text vs. Qwen's 19,528/30,036 for the brain's probes.)

### Coding task (API-loop wrapper, same task as brain baseline; final clean numbers after the extraction-bug fix)

| Candidate | Wall-clock | Passed | Predicted tokens | Notes |
|---|---|---|---|---|
| **Brain (qwen/qwen3.8-27b)** | **25.6 s** | Yes (4/4) | 390 | stock config, baseline |
| qwen3.6-35b-a3b | 43.4 s | Yes (4/4) | 2,952 | correct fix, far more verbose reasoning |
| gemma-4-26b-a4b-it | 43.3 s | Yes (4/4) | 1,881 | correct fix, more verbose than brain |
| gpt-oss-120b | — | DNS | — | never loaded cleanly, task not attempted |

Both MoE candidates decode 2.7–4× faster than the brain in raw tok/s, but both lost the
coding-task wall-clock race by ~1.7× because they used 5–7.5× more output tokens for the
same task — raw decode speed didn't translate into task-completion speed here, echoing
phase-2's own finding that verbosity dominates wall-clock on small interactive tasks.

## Verdicts

1. **MTP stays ON for the brain, at n=4 (stock) — locked verdict.** Monotonic
   improvement off→n=2→n=4 on every content/depth combination measured (structured short:
   9.79→12.20→15.82 tok/s; structured deep: 6.91→15.96→19.88 tok/s). Confirms the
   deep-dive's community prior that MTP helps at `parallel:1` on Vulkan/RADV-class
   backends — and is the mirror image of the CUDA sibling study, where MTP hurt across
   the board. Engine-specific, as predicted; no change needed to the production loader
   profile. Caveat: the deep-content numbers likely get a real but unquantified boost
   from probe repetition inflating draft acceptance (see 1a note) — the *direction* (MTP
   helps here) is solid; the exact magnitude at depth is probably optimistic.

2. **KV q8_0 does NOT become the brain's default — locked verdict, opposite of the CUDA finding.** Depth decode is flat across f16/q8_0/q4_0 (5.81/5.74/5.66 tok/s — a 2.6%
   spread, within run-to-run noise), versus the CUDA sibling's 2.4× unlock (17.8→42.3
   tok/s) from the same quantization on a 16 GB card. This Vulkan/AMD engine build
   evidently doesn't get the same KV-quant fast path llama.cpp's CUDA backend does.
   Recommendation: keep f16 KV; there's no measured upside to taking on quantization
   risk for zero benefit.

3. **mmap: gated, lean toward keeping the current OFF default.** Single paired run
   showed mmap off ~20% faster decode (20.71 vs 17.23 tok/s) and ~35% faster load
   (9.5 s vs 14.6 s). Not repeated enough for a locked verdict, but there is no evidence
   to flip the existing `tryMmap:false` production setting.

4. **Does any candidate threaten the brain's crown? No, for the cockpit/reasoning role.**
   Nothing beat the brain's 25.6 s coding-task wall-clock; the MoE candidates' large raw
   decode-speed edge (2.7–4×) was fully absorbed by their far more verbose responses on
   this small task. **qwen3.6-35b-a3b is a real candidate for the worker/fan-out role**
   (61.7/56.4 tok/s decode, correct fix once the harness bug was fixed) — consistent with
   phase-2's existing decision to run a fast MoE as the on-demand worker, not the cockpit
   voice. gemma-4-26b-a4b-it showed no advantage on either axis (weaker decode, denser
   tokenizer, same task time) — no case for adoption in any role from this session.
   gpt-oss-120b is a hard DNS on this box's current memory split. None of this is a full
   verdict on worker-role *replacement* — that needs a multi-task bake-off, not the
   single coding task run here.

## Restoration

`lms unload --all` run at the end of Part 1/2 work; `Load-OpenCode-Qwen.mjs` re-run to
reload the production brain; verified via `lms ps --json`: `qwen/qwen3.8-27b`
(unsloth/Qwen3.8-27B-GGUF, UD-Q5_K_XL) resident at ctx 65,536, stock config
(`speculativeDraftMtp:true`, `speculativeDraftMaxTokens:4`, `useFp16ForKVCache:true`,
`tryMmap:false`), status idle. No commits made; no changes to `C:\Users\scott\.dsh\`; dsh
cockpit was not driven at any point.
