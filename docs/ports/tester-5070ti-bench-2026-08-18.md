# Port: RTX 5070 Ti 16GB ("TESTER") — full stack install + bench

**Status: REAL install proven.** `Deploy-ToLive.ps1` ran clean end-to-end three
times on the target box; the live stack (loaders, launcher, desktop icons,
Mission Control, subagent plugins) is installed and serving there. This
supersedes the earlier sandbox-only version of this document, which
was correctly rejected as not testing the product.

Report below is the TESTER box's own record, verbatim (operator-prompted,
independent agent, measured on-box 2026-08-18). Stack-side fixes it forced —
Mission Control's hardcoded-carveout defect and the federated-Unload footgun —
are fixed in this repo's Mission Control (portable VRAM detection via driver
registry; remote fleet models get no Load/Unload controls in the UI **and**
the unload endpoint refuses them server-side, verified against the live
remote model).

---

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
**Server behavior (corrected):** this LM Studio build **auto-sizes context to
leftover VRAM** — a 32,768 request became 32,000 applied with f16 KV and
**40,448** with q8_0 KV (`lms ps --json` is the truth source). An earlier draft
of this report called it a fixed clamp; the q8_0 upsize refuted that.

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
test suite on disk. The 59.4 s row is a scripted single-shot fix loop against
`api/v0`; the harness-proper run is below.

## The stack itself runs here — dsh rc.7 proof

The pinned harness was installed and booted on this box (same session,
follow-up run): `npx @deepseek-ai/dsh@0.1.0-rc.7 web` in a sandboxed
`DSH_HOME` with the repo's `dsh/` configs adapted (provider → local LM Studio
identity `bench/qwen3.8-27b` at 32K; memory graph isolated to the sandbox;
subagent trio omitted — needs the per-profile plugin installs; browser MCP
kept disabled per known issue 1; Exa keyless).

- **Boot:** cold `npx` (package download included) → cockpit serving on
  `127.0.0.1:3080` in **183 s**; web UI renders (composer, workspace picker,
  preset selector); boot log clean apart from npm deprecation warnings;
  sandboxed Knowledge-Graph memory MCP came up on stdio.
- **Harness task run (headless profile), same two-bug repo:** `dsh --profile
  headless` found both planted bugs, fixed `inventory.js` without touching
  `test.js`, ran the tests itself, and reported both root causes correctly —
  **79 s** wall-clock, exit 0, `ALL TESTS PASSED` verified on disk after the
  run. Local model confirmed as the server (`lms ps` last-used timestamp;
  the federated HALO device untouched). HALO's same-shape harness run: 176 s.
- **Windows quirks encountered:** none beyond the repo's documented list —
  the two applicable workarounds (browser-MCP row disabled, non-drive-root
  workspace) were applied preemptively and nothing new surfaced.
- **Config adaptation that matters on a federated box:** the repo's model
  identity `qwen/qwen3.8-27b` resolves to the *remote HALO device* through LM
  Studio federation here — an unadapted deploy would silently run the cockpit
  on HALO's compute. The local deploy must use a distinct local identity.

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

## Round 2 — REAL install (Deploy-ToLive) and full re-run

Done after the sandbox proof was (rightly) rejected as not testing the
product. Everything below ran on the **live install**: `~\.dsh`, deployed
loaders, Mission Control, desktop icons — no sandbox.

### Install record

- `Deploy-ToLive.ps1` ran clean end-to-end THREE times (initial + two
  adaptation redeploys): drift-guard → YAML pre-validate → staged
  compose-validate → backup → apply → live validate. All 19 files live;
  timestamped backups under `~\.dsh\ConfigBackups\`. `.env` correctly
  preserved on redeploy.
- Subagent plugins installed for both profiles (web, headless) per the
  deploy's printed command. Upstream packaging warning on all three subagent
  packages ("declares no dsh.bundle — installed as plain dependency"); the
  cordis patch rows still mount them.
- Both desktop icons created: **DeepSeek Harness**, **Mission Control**.
- Launcher (icon path) boots to a serving cockpit in **20 s** warm.
- Mission Control serves at :3090: services panel correct (cockpit up, LM
  Studio up, CUDA engine string right), alarm strip nominal, GPU shared-pool
  alarm logic working.

### Adaptations required (the full "tweaked for this Blackwell box" list)

1. Model identity suffixed `-5070ti` everywhere (settings.yaml, cordis patch,
   loaders, opencode.json, launcher): the stock identity resolves to the
   **federated HALO machine** on this box — an unadapted deploy silently runs
   the cockpit on HALO's compute over the network.
2. Brain loader: Q5_K_XL→UD-Q3_K_XL, KV q8_0, MTP off, gpu max + strict cap,
   parallel 1 (wire-injected over public SDK 1.5.0; the repo's vendored SDK
   isn't in the repo).
3. Worker loader: same SDK/wire treatment; context check loosened to ≥24K
   (auto-sizing).
4. `Start-DSH.ps1` brain check: must filter `deviceIdentifier -eq null` or the
   federated remote satisfies it and the local brain never loads.
5. `AGENTS.md`: hardware/speed facts rewritten for this box + scope header so
   non-HALO agents in `Desktop\CODE` ignore it.
6. `opencode.json`: model route → local identity, ctx 32000. NOTE: this box
   already had a live `opencode.jsonc`; the deployed `opencode.json` now sits
   beside it (backup retained) — verify which one opencode honors before
   daily-driving.

### Findings from the real install (things the sandbox could not see)

- **Clean-machine order bug:** README says deploy → launch, but
  `Deploy-ToLive.ps1`'s YAML validator borrows js-yaml from the dsh profile
  install, which doesn't exist until dsh has run once. On a virgin box, run
  `npx @deepseek-ai/dsh@0.1.0-rc.7 web --dump-config` once, then deploy.
- **Launcher swallows loader failures** (`| Out-Null`): a failed brain load
  still yields a "working" cockpit with no local model. Surfaced by finding 4
  above; worth an upstream fix.
- **Eviction silently downgrades config:** if the brain is evicted (TTL,
  memory pressure, worker load), the next API call JIT-reloads it with
  LM Studio defaults — not the loader profile — and decode drops (measured
  17.5 vs 49 tok/s). The launcher re-check covers reboot, not eviction.
- **Two-model residency resolves by eviction:** loading the worker beside the
  brain does not fail — LM Studio silently evicts the brain. The stack's
  on-demand worker pattern works here, but "both resident" (HALO's normal
  state) is physically impossible; every brain↔worker switch costs a reload
  plus the JIT-downgrade trap above.
- **Mission Control on non-HALO hardware:** one real defect — GPU carveout
  math hardcodes 128 GiB unified memory ("14.9 / 96.4 GiB carveout" on a
  16 GiB discrete card). And one footgun — the Models tab lists the
  **federated remote device's models with live Load/Unload buttons**,
  indistinguishable from local ones; an Unload click here would kill the HALO
  box's active brain. *(Both fixed in the repo's Mission Control:
  VRAM capacity now read from the driver registry, remote models show no
  controls, and the unload endpoint refuses remote identities server-side.)*
- **Download integrity:** two 17 GB worker-GGUF downloads came back
  size-exact but hash-corrupt (symptom: garbage `???` output, mid-inference
  tensor-bounds crashes). Root cause: an earlier suspended-then-resumed
  background download was still writing the same file while later resumes
  interleaved. Fix: single-writer download + **sha256 gate against the HF API
  (`?blobs=true` lfs.oid) before any model is benched or shipped** — worth
  adopting as stack policy.

### As-installed numbers (product config: Q3_K_XL, KV q8_0, MTP off, ctx 40448)

| Metric | Installed brain | Installed worker (Coder MoE) | HALO brain | HALO worker |
|---|---|---|---|---|
| Cold prefill 19.5K | **1,668 tok/s** (TTFT 11.7 s) | 2,580 tok/s (TTFT 7.5 s) † | 181 (108.6 s) | 615 (31.8 s) |
| Cached TTFT | **0.33 s** | 0.13 s † | 13.4 s | 0.28 s |
| Decode short | **49.0 tok/s** | 59.4–88.9 tok/s † | 26.9 | 90.9 |
| Decode @30K | **42.1 tok/s** | 52 tok/s † (once; see stability) | ~10 (deep) | — |
| Two-bug task (script) | **28.7 s** | **2.5–3.1 s** (3/3 pass) | — | — |
| Two-bug task (via dsh headless) | **73 s** | — | 176 s | 41 s |

† hash-verified file, but see the stability finding: long-context worker runs
die; treat every worker number above except the coding-task row as
single-measurement.

**Worker stability on 16 GB (important):** Q4_K_S (16.3 GB weights + ~4.6 GB
forced into the GPU shared pool) is **rock-solid in its designed role** —
short-context fan-out coding tasks: three consecutive two-bug repairs in
2.5–3.1 s each, instance stable throughout, absurdly faster than HALO's 41 s.
But it **reliably crashed the instance at ~19.5K+ context** (three deaths
across three load configs, including CPU-expert-ratio hybrid; the repeated
crashes eventually took the whole engine host down, dropping all models until
a server restart). Verdict: keep the worker for what the stack uses it for
(fan-out), cap its requests well below 19K context here, and consider a
Q3-class MoE quant if long-context worker use ever matters on this box.

The installed product config beats every ad-hoc bench config measured earlier
in this report: q8_0 KV helps short-context decode too (49 vs 25 tok/s — the
earlier "decode short" rows ran f16 KV).

### Matrix pass 3 (same cells as rounds 1–2, through the installed engine)

Replication held across all cells: A-f16 battery 1,523 prefill / 0.95 s cached
/ 24.4 short / 16.9 deep; A depth q8_0 42.1, q4_0 30.0 (vs 42.3/30.0 prior);
B battery 1,134 prefill / 2.23 s cached / 9.0 short / 5.4 deep; B depth q8_0
5.9, q4_0 7.2 (vs 6.1/7.7); B coding task 160 s pass (vs 126 s — hybrid
variance). Three independent passes agree; the numbers are stable.

## Verdict (5 lines)

1. **Prefill/compute is a rout:** 1,547 tok/s vs 181 — 8.5× HALO; this box's *cold* 19.5K TTFT (12.6 s) beats HALO's *cached* TTFT (13.4 s), and its cached turn is ~1 s — the prefix-cache architecture HALO depends on is a nice-to-have here, not load-bearing.
2. **Deep-context decode, the right way:** with KV q8_0, 42 tok/s at 30K — ~1.6× HALO's short-context rate and ~4× its deep rate; the CUDA card turns HALO's worst case into this box's best case.
3. **What it can't do:** the stack's actual brain (21 GB Q5_K_XL at 65K ctx) and two-model residency are physically impossible in 16 GB — quality ceiling is Q3/Q4-class weights at 32K, and the Q4 hybrid costs ~3–5× decode for one quant step of quality.
4. **Config that transfers, config that doesn't:** flash attention + parallel 1 + contextCheckpoints transfer fine; Vulkan-era MTP defaults must be dropped, and KV must be quantized to q8_0 — the HALO loader profile is not portable as-is.
5. **Best-value config — now the INSTALLED config:** UD-Q3_K_XL, 100% GPU, KV q8_0, MTP off, flash attention, ctx auto-sized 32–40K — 1,668 tok/s prefill / 11.7 s cold TTFT / 0.33 s cached / 49 tok/s short / 42 tok/s @30K / 28.7 s coding task (73 s through the installed dsh cockpit vs HALO's 176 s; worker fan-out task 2.5 s vs HALO's 41 s). The full stack — deploy, launchers, icons, plugins, Mission Control — is installed and running on this box under that config; the remaining rough edges are the Mission Control carveout math, the federated-Unload footgun, and the worker's long-context crashes, all documented above.
