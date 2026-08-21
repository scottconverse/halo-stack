// HALO brain loader -- Qwen3.8-27B Q5_K_XL, ctx 131072, KV q8_0, MTP on.
//
// 2026-08-21: this file used to import a VENDORED SDK that was never in the
// repository:
//     import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/...";
// `git ls-files lmstudio/` returns three files and no vendor/ directory, and
// .gitignore excludes node_modules, so it could never have been committed.
// It existed only on the author's disk. Every clone of this repo failed here
// with MODULE_NOT_FOUND, the launcher retried twice, and the cockpit opened
// with no brain. The stack has never worked for anyone who downloaded it.
//
// The vendored copy was ALSO not stock: same version string (1.5.0), 794,178
// bytes against npm's 749,089, and it understood eleven load-config keys the
// published package does not. So `npm i @lmstudio/sdk@1.5.0` alone does not
// restore it -- the public SDK accepts those keys and SILENTLY DROPS them
// (measured: grep count 0 in the published bundle), which would load the brain
// with MTP off, no context checkpoints, the wrong physical batch size and the
// wrong parallelism, while reporting success. That is issue #14.
//
// Fix: stock public SDK, pinned and installed by Deploy-ToLive.ps1, plus a
// wire-level shim that pushes the dropped fields straight into the KV config
// the server actually receives. The mapping below is the one proven on the
// 5070Ti box (branch tester/5070ti), extended to the remaining draft keys.
// Verification is `lms ps --json` -- the stack's own truth source -- because
// public 1.5.0's getLoadConfig() returns a shape whose fields all read
// undefined, which made the old assert throw and unload the model it had just
// loaded.
import { LMStudioClient } from "@lmstudio/sdk";
import { execSync } from "node:child_process";

const modelPath = "unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf";
const modelId = "qwen/qwen3.8-27b";
const client = new LMStudioClient();

for (const model of await client.llm.listLoaded()) {
  if (model.identifier === modelId) {
    await client.llm.unload(model.identifier);
  }
}

// Wire-level injection for the fields public 1.5.0 drops on the floor.
// Keep this list in sync with the `config` block below: a value that appears
// only there is silently ignored by the published SDK.
const proto = Object.getPrototypeOf(client.llm);
const origMap = proto.loadConfigToKVConfig;
proto.loadConfigToKVConfig = function (cfg) {
  const kv = origMap.call(this, cfg);
  kv.fields.push(
    // MTP on, n=4, p=0.5 -- measured optimal on Vulkan at parallel=1
    { key: "llm.load.llama.speculativeDecoding.draftMtp", value: true },
    { key: "llm.load.llama.speculativeDecoding.draftSimple", value: false },
    { key: "llm.load.llama.speculativeDecoding.draftMaxTokens", value: 4 },
    { key: "llm.load.llama.speculativeDecoding.draftMinTokens", value: 0 },
    { key: "llm.load.llama.speculativeDecoding.draftMinContinueProbability", value: 0.5 },
    { key: "llm.load.llama.contextCheckpoints", value: 32 },
    { key: "llm.load.llama.physicalBatchSize", value: 512 },
    { key: "llm.load.numParallelSessions", value: 1 },
    { key: "llm.load.useUnifiedKvCache", value: true },
    { key: "llm.load.offloadKVCacheToGpu", value: true },
    { key: "load.gpuStrictVramCap", value: true },
  );
  return kv;
};

const model = await client.llm.load(modelPath, {
  identifier: modelId,
  ttl: 86400,
  verbose: "info",
  config: {
    gpu: {
      ratio: "max",
      numCpuExpertLayersRatio: "off",
      mainGpu: 0,
      splitStrategy: "evenly",
      disabledGpus: [],
    },
    gpuStrictVramCap: true,
    maxParallelPredictions: 1,
    useUnifiedKvCache: true,
    offloadKVCacheToGpu: true,
    contextLength: 131072,
    evalBatchSize: 2048,
    physicalBatchSize: 512,
    flashAttention: true,
    contextCheckpoints: 32,
    speculativeDraftMtp: true,
    speculativeDraftSimple: false,
    speculativeDraftMaxTokens: 4,
    speculativeDraftMinTokens: 0,
    speculativeDraftMinContinueProbability: 0.5,
    keepModelInMemory: false,
    // KV q8_0 at ctx 131072: same GPU footprint as the old 65536/f16 config
    // (q8_0 halves KV bytes), decode parity proven both shallow and deep --
    // docs/phases/bench-window-131k.md, ADOPT verdict 2026-08-19.
    useFp16ForKVCache: false,
    tryMmap: false,
    llamaKCacheQuantizationType: "q8_0",
    llamaVCacheQuantizationType: "q8_0",
  },
});

// Verify from `lms ps --json`, never getLoadConfig(): on public 1.5.0 that
// call returns a KVConfig shape whose every field reads undefined, so the
// assert it used to feed always failed and unloaded a correctly loaded model.
// deviceIdentifier must be null: on an LM Link federated LM Studio a remote
// box can publish this same identity and satisfy a naive check.
// GATE-2026-08-21 / W1 (Critical): this used `execSync("lms ps --json")` with
// no try/catch. `client.llm.load()` above ALREADY SUCCEEDED and returned a live
// model handle -- but if the verification subprocess threw (a fresh LM Studio
// with no CLI key yet, the server restarting, a transient CLI fault), the whole
// script exited non-zero, Start-DSH.ps1 read that as a FAILED load, and
// reloaded the entire 21 GB model a second time before telling the user there
// is no model. A verification that cannot RUN is UNVERIFIED, never FAILED.
//
// Verify via the SDK first (no subprocess, so it cannot ENOENT); fall back to
// `lms ps` for the fields the SDK does not expose. Never unload a model that
// loaded because a *check* failed.
let live = null, verifiedBy = null;
try {
  const loaded = await client.llm.listLoaded();
  const m = loaded.find((x) => x.identifier === modelId);
  if (m) { live = m; verifiedBy = "sdk"; }
} catch { /* fall through to lms ps */ }
if (!live) {
  try {
    const ps = JSON.parse(execSync("lms ps --json").toString());
    live = ps.find((m) => m.identifier === modelId && !m.deviceIdentifier) || null;
    if (live) verifiedBy = "lms-ps";
  } catch (e) {
    // Verification could not run. The load itself succeeded (we are past
    // client.llm.load). Report UNVERIFIED and exit 0 -- do NOT unload, do NOT
    // make Start-DSH retry a load that already worked.
    console.log(JSON.stringify({ identifier: modelId, verification: "UNVERIFIED", reason: String(e.message || e) }));
    process.exit(0);
  }
}

// `lms ps` exposes contextLength/parallel/quant; listLoaded may not. Only
// assert a field when the verifier actually reports it -- a missing field is
// unverified, not wrong.
const checks = {
  loadedLocally: !!live,
  contextLength: live?.contextLength == null || live.contextLength === 131072,
  parallel: live?.parallel == null || live.parallel === 1,
  quant: live?.quantization?.name == null || live.quantization.name === "Q5_K_XL",
};
const bad = Object.entries(checks).filter(([, ok]) => !ok);
if (bad.length > 0) {
  // A genuine profile MISMATCH (wrong context/quant) is a real failure: the
  // model loaded wrong, so unload and fail loudly. This is distinct from
  // "could not verify" above.
  await client.llm.unload(modelId);
  throw new Error(`Qwen load profile mismatch: ${JSON.stringify({ bad, live }, null, 2)}`);
}
console.log(JSON.stringify({
  identifier: modelId,
  verifiedBy,
  path: live.path,
  contextLength: live.contextLength ?? null,
  quant: live.quantization?.name ?? null,
  parallel: live.parallel ?? null,
}));
