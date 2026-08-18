# Phase 2 bench results — 2026-08-17

Machine: HALO (Strix Halo). LM Studio single server, `api/v0` stats + wall-clock timing.
Probe prompt: 19.6K tokens. Task: two-bug node repo (`dsh-bench-lab`), identical prompt per run, verified on disk after each run.

## Inference probes

| Metric | Q5 brain (qwen/qwen3.8-27b) | Coder MoE (qwen3-coder-30b-a3b-instruct) |
|---|---|---|
| Fresh prefill | 181 tok/s (TTFT 108.6 s) | 615 tok/s (TTFT 31.8 s) |
| Cached TTFT | 13.4 s (8.1× speedup) | 0.28 s (115× speedup) |
| Decode solo | 26.9 tok/s | 90.9 tok/s |
| Decode concurrent | 19.0 tok/s (−29%) | 87.8 tok/s (−3%) |
| Resident memory | 19.7 GB | 16.3 GB (free RAM 35.7 → 19.0 GB) |

## Harness task runs (headless, same task, verified on disk)

| Run | Wall-clock | Correct | Notes |
|---|---|---|---|
| Q5, Standard | 176 s | Yes (4/4, staged, no commit) | Complete requested reporting |
| Coder, Standard | 41 s | Yes (4/4, staged, no commit) | Skipped requested printouts |
| Coder, Code mode | 65 s | Yes (4/4, staged, no commit) | run_code overhead > batching gain |

## Verdicts (data-driven, per v2 plan)

1. **Cockpit default: Q5 dense, Standard mode.** Best reporting discipline; prefill pain neutralized by prefix cache (108.6 s → 13.4 s TTFT).
2. **Worker: Coder MoE earns the fan-out role decisively.** 4.3× faster end-to-end at equal correctness. Codex's "≈ parity (30–37 tok/s)" figure did not survive measurement — 90.9 tok/s decode, 3.4× prefill.
3. **Residency: on-demand with 2 h TTL** (`Load-Worker-Coder.mjs`). Load cost ~1 min; idle unload returns ~16 GB. Not pinned permanently — 19 GB free with both resident is workable but not generous.
4. **Code mode: not default.** Lost 65 s vs 41 s on a representative small task. Revisit only for large mechanical batch operations.
5. **Prefix-cache claim: validated** against LM Studio (contextCheckpoints 32). The 8.1×/115× TTFT speedups are the measured basis of the whole architecture.
6. Coder's weak narration is acceptable in the worker role (parent session owns reporting); it reinforces Q5 as the cockpit voice.
