# Bench Day 2 — 2026-08-17 (evening)

## Item 1: ROCm engine vs Vulkan — RESEARCHED, GATED (not benched)
Deep research verdict: the prize is real — on gfx1151, ROCm+rocWMMA holds
long-context throughput where Vulkan degrades (llm-tracker: tg@8K 51 vs 32 t/s),
and long context is our exact workload. But LM Studio's Windows ROCm runtime for
gfx1151 is not ripe today: lms #494 (crashes on non-small models — our 21 GB Q5
is the crash case), lms #589 (unified-memory mis-sizing; fixed upstream by
llama.cpp b10472's HIP UMA change, not yet shipped in an LM Studio engine),
ROCm/ROCm #5499 (upstream compute-corruption reports on Strix Halo). Fresh
Reddit corroborates: community Strix Halo guides remain Vulkan-based.
**Decision: Vulkan stays. Two ripeness gates added to /delta-scan-halo**
(#494 closed + b10472 in a shipped engine); bench when both clear.

## Item 2: bare llama-server --draft-mtp vs LM Studio — BENCHED, CLOSED
Same GGUF, same machine, llama.cpp b10472 win-vulkan, MTP verified engaged
(draft acceptance logged: 86.5% structured / 52.4% prose — content-dependent,
as our sweep predicted).

| Metric (identical prompts) | LM Studio v2.28.2 | bare llama-server b10472 |
|---|---|---|
| Fresh prefill, 19.5K tok | 181 t/s (108.6 s) | 177.8 t/s (110.0 s) |
| Cached follow-up turn | 13.4 s | 15.6 s |
| Decode (garden-512 prose) | 19.7 t/s | 20.2 t/s |

**Verdict: parity within noise; LM Studio's wrapper costs nothing and its
cached-turn handling is slightly better.** The community's "~72% faster"
claim only holds against unconfigured LM Studio defaults — our tuned config
already banked it. **LM Studio remains the inference layer. Question closed.**

## Item 3: Nemotron-3.5-Lightning-30B-A3B vs Qwen3 Coder 30B A3B — DNS, GATED
Downloaded UD-Q4_K_S (22.78 GB, size verified against HF). LM Studio v2.28.2
refuses to load it: "wrong number of tensors; expected 417, got 408" — its
bundled llama.cpp predates the `nemotron_h_moe` architecture. Diagnosis proven:
bare llama.cpp b10472 loads the same file cleanly in ~7 s. Not corruption;
engine lag. **Incumbent Qwen3 Coder retains the worker crown by walkover.**
GGUF kept on disk (23 GB) for the gated re-bench; delete if disk pressure.
Gate added to /delta-scan-halo: bench when an LM Studio engine update loads
nemotron_h_moe — same trigger class as the ROCm b10472 gate (one engine
release likely clears both).

## Bench Day 2 — final scoreboard
1. ROCm vs Vulkan: researched → Vulkan stays; two ripeness gates tripwired.
2. Bare llama-server vs LM Studio: benched → parity; LM Studio stays; "72%
   faster" community claim retired.
3. Nemotron vs Qwen Coder: DNS on engine lag → incumbent stays; gated.
Three questions in, zero changes to the stack — and that's the finding: the
current configuration survived every challenger the community could field
this week. Next LM Studio engine release re-opens items 1 and 3 automatically
via the delta scan.
