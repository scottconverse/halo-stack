# Strix Halo deep dive — 2026-08-18

One-off wide sweep (four parallel scouts: AMD official channels, community
wiki/forums, GitHub trackers, Reddit/HN) hunting for stack-relevant nuggets
beyond the weekly delta-scan's feeds. Every claim carries its source; community
claims labeled; SNIPPET-ONLY = seen via search snippet, primary unreachable.
Scored against THIS stack (Windows 11, LM Studio Vulkan, Qwen3.8-27B Q5 brain,
Qwen3-Coder-30B MoE worker; pains: prefill/TTFT, decode-at-depth, thinking
cost).

## Headline findings

### 1. The MTP mystery is (probably) resolved — parallelism is the hinge
The "known-good stack" author (llama.cpp discussion #20856, updated
2026-07-31) measured on gfx1151: Vulkan/RADV decode 47.7→60.9 t/s from
backend choice alone, then →~85 t/s (+39%) with MTP `draft-mtp, n-max 2` —
**but only at `-np 1`; at `-np 2` MTP inverts to ~38 t/s**. Speculative
decode across parallel slots destroys the benefit — an architectural
finding, not OS-specific. Our brain runs `parallel: 1`, which predicts MTP
HELPS us (consistent with our 52–87% logged acceptance), while the Reddit
regression reporter (Lemonade stack) plausibly differed in np/config.
Corroborating: sleepingrobots.com (2026-08-15, Q6_K, Fedora/RADV) found
n-max 2 beats n-max 5. Two open llama.cpp PRs touch this: #25666 (don't
enable MMVQ for spec-decode on AMD — contested, mixed regression reports,
unmerged) and #27210 (adaptive MTP draft depth, brand new 2026-08-17).
**Action: MTP A/B v2 = off / n=2 / n=4(stock) at np=1, structured + prose,
shallow + deep.** Sources: github.com/ggml-org/llama.cpp/discussions/20856;
sleepingrobots.com/dreams/qwen38-mtp-strix-halo/.

### 2. Vulkan MoE flash-attention refactor: possible free +25% on the worker
llama.cpp PRs #19625 (Wave32 FA) + #20551 (graphics-queue) — ~March 2026 —
reported +25% for MoE models on Vulkan (via hogeheer499 strix-halo-guide /
strixhalo.wiki). Whether LM Studio engine v2.28.2's base includes them is
unknown. **Action: check LM Studio's engine update channel; on any engine
update, re-bench worker decode (and note finding 10's regression warning).**

### 3. KV-cache quantization is Qwen-friendly
Community: Qwen models tolerate q8_0 KV far better than Gemma-class (~3.5×
difference in quality loss; strixhalo.wiki). sleepingrobots ran q8_0 KV on
this chip. Combined with the overbring post's q4_0-KV success on the same
model family: **Action: add KV q8_0 (and q4_0) at-depth legs to the bench —
decode-at-depth is KV-bandwidth pain, and this directly shrinks bytes/token.**

### 4. NPU hybrid mode: officially NOT supported on this SKU (correction)
AMD's Ryzen AI 1.8 docs list hybrid (NPU prefill + iGPU decode) hardware as
Ryzen AI 300 (Strix Point/Krackan) ONLY — Ryzen AI Max+ 395/Strix Halo is
absent. One AMD playbook uses ambiguous "Max 300 series" language; the docs
table excludes us. The excited Reddit owner-report conflicts with the docs.
Largest hybrid example model anywhere: Qwen3-4B-Hybrid. **Action: keep the
queued Lemonade probe as the empirical tiebreaker, expectations LOW; the
delta-scan tripwire is now "hybrid support lands for THIS SKU," before any
model-size question.** Sources: ryzenai.docs.amd.com/en/latest/llm/overview.html;
developer.amd.com/playbooks/lemonade-getting-started/.

### 5. ThinkingCap exists — for 3.6, not yet 3.8
ThinkingCap-Qwen3.6-27B: ~46% fewer thinking tokens across 12 benchmarks,
accuracy tracking base (>60% thinking-token cut on GPQA-Diamond). Exactly
the class of tune we tripwired for; the 3.8 version does not exist yet.
**Watch confirmed correctly aimed; check HF for GGUF quants of the 3.6 tune
and for any 3.8 successor.** Sources: bottlecapai.com/post/thinkingcap-qwen3-6-27b/.

### 6. Community FP4+MTP quants of OUR brain claim 2.8× decode at depth
kingjones777/Qwen3.8-27B-ROCmFP4-STRIX-MTP-GGUF (HF, 2026-08-14, 9.2K
downloads) + julianmb/q38rocm repo (89 stars): claimed 30.3 t/s at 8K
context w/ tuned MTP vs 10.7 baseline, perplexity-matched to Q4_K_M at 22%
smaller. Measured on Linux/RADV/Mesa 26; "ROCmFP4" format may not load on
our Windows Vulkan engine at all. **Action: loadability test + on-box bench
+ our own quality check before any adoption; treat all claims as unverified
until reproduced here.**

### 7. Windows 96 GB VGM path confirmed; one spill bug to watch
Adrenalin UI reaches 96 GB GPU allocation on Windows (jdhodges.com; the
dual-box video confirms 96 is the Windows ceiling vs Linux TTM 120).
ROCm/ROCm#5940 (hipMalloc spills to shared memory above 32 GB with 96 GB
VGM, Win11) is closed without a visible explanation — ROCm-path, so our
Vulkan engine is likely unaffected, and MC's shared-pool alarm watches
exactly this failure. **Enables the gpt-oss-120b single-box test (bake-off
Round 2, parked).**

### 8. LM Studio VRAM survey is broken on this box — known and traced
lms#589 (active 2026-08-04): llama.cpp fixed VRAM enumeration (engine
2.27.0, upstream #26089 closed), but LM Studio's own hardware-survey layer
still gets nothing on Strix Halo → "Strict GPU VRAM cap" silently disables.
Also on that thread: with a VRAM cap smaller than the model and mmap ON,
LM Studio double-loads into RAM+VRAM on unified systems (gfx1150 report).
**Validates our `lms ps` + perf-counter discipline; adds a cheap mmap-OFF
test leg to the bench.**

### 9. Decode-at-depth: our pain is the Windows-driver column
RADV (Linux/Mesa) holds long-context decode far better than AMDVLK-class
drivers (17.24 vs 10.75 t/s at 130K ctx; separate report: RADV 24 vs
AMDVLK 5 t/s prompt processing). Windows' proprietary Vulkan ICD behaves
like the weak column. llm-tracker: HIP+rocWMMA+FA holds 50.97 t/s at 8K
where Vulkan drops to 32.03. **No Windows action available — this is the
measured ceiling we're paying for the Windows-native mandate; ROCm-on-
Windows maturing (below) is the eventual fix for the depth pain
specifically.**

### 10. Engine updates are not automatically upgrades on this GPU
#20856's author pinned b9870 after b9871 regressed decode ~8%. **New
standing rule: any engine update triggers a decode re-bench before
adoption (delta-scan already re-benches on engine updates — now explicitly
including a regression check, not just the gated rematches).**

### 11. ROCm-on-Windows gate: first real movement
TheRock SUPPORTED_GPUS.md now shows Windows gfx1151 = build passing +
sanity tested (release-ready column still empty); TheRock's Windows doc
still says "not yet mature." Directionally the two delta-scan ROCm gates
are getting closer. Correction from verification: the mmap->64GB issue is
ROCm/ROCm#6501 (Vulkan unaffected) — an earlier citation of TheRock#2591
(in the bench-overlay comments) was a mis-reference; #2591 is an unrelated
MIOpen logging thread.

### 12. Clustering (dual-box) reality check
AMD playbooks (Linux-only): llama.cpp RPC ~8 t/s single-stream on GLM-4.7
358B UD-Q4_K_XL, collapsing at 2K+ prompts; vLLM+RCCL TP=2 ~7.8 t/s
single / ~18 t/s at concurrency 4 on Qwen3.5-397B (110 GB/box). A Framework
-forum RDMA cluster build posted no numbers. An independent-sounding value
verdict ("single box remains the better value for chat/coding; clustering
pays for long-context/RAG") matches the playbook numbers. **Decision
recorded: no second box until single-box big-MoE (Round 2) data exists.**

## Noise filtered (so it stays filtered)
- Lucebox DeepSeek-V4-Flash numbers: vendor marketing for a $6,499 box.
- rocWMMA "Phase 2 flashprefill 2.2–5×" claim: absent from actual ROCm
  release notes — unverified secondary noise.
- "gpt-oss-120b ≈50 t/s on Strix Halo": no traceable primary source.
- Lemonade v11.6 "TheNoise" backend: image-gen only.
- Exa `includeDomains: reddit.com` scripts: refuted on-box (Exa serves zero
  reddit content) — the /reddit-search RSS skill remains the only real path.

## Revised bench queue (GPU frees → in order)
1. **Combined bench session:** MTP off/n=2/n=4 × structured/prose ×
   shallow/deep; + KV q8_0/q4_0 at-depth legs; + mmap-OFF leg. One script.
2. **NPU hybrid probe** (expectation low — SKU support question is the
   real test).
3. **FP4-STRIX quant loadability + bench** (community claims, our numbers).
4. **Bake-off Round 1** (on-disk models; awaiting operator go) →
   **Round 2** gpt-oss-120b with VGM 96 (Adrenalin; MC shared-pool alarm
   armed).
