// 2026-08-21: was importing ./vendor/node_modules/@lmstudio/sdk, a directory
// never committed to this repository -- every clone failed with
// MODULE_NOT_FOUND. Stock public SDK, pinned and installed by Deploy-ToLive.
import { LMStudioClient } from "@lmstudio/sdk";

// MTP sweep loader: node Sweep-MTP.mjs <draftMaxTokens> <minContinueProbability>
const draftMax = Number(process.argv[2]);
const pMin = Number(process.argv[3]);
if (!Number.isFinite(draftMax) || !Number.isFinite(pMin)) {
  throw new Error("usage: node Sweep-MTP.mjs <draftMaxTokens> <pMin>");
}

const modelPath = "unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q5_K_XL.gguf";
const modelId = "qwen/qwen3.8-27b";
const client = new LMStudioClient();

for (const model of await client.llm.listLoaded()) {
  if (model.identifier === modelId) {
    await client.llm.unload(model.identifier);
  }
}

const model = await client.llm.load(modelPath, {
  identifier: modelId,
  ttl: 86400,
  config: {
    gpu: { ratio: "max", numCpuExpertLayersRatio: "off", mainGpu: 0, splitStrategy: "evenly", disabledGpus: [] },
    gpuStrictVramCap: true,
    maxParallelPredictions: 1,
    useUnifiedKvCache: true,
    offloadKVCacheToGpu: true,
    contextLength: 65536,
    evalBatchSize: 2048,
    physicalBatchSize: 512,
    flashAttention: true,
    contextCheckpoints: 32,
    reasoningBudgetMessage: "",
    speculativeDraftMtp: true,
    speculativeDraftSimple: false,
    speculativeDraftMaxTokens: draftMax,
    speculativeDraftMinTokens: 0,
    speculativeDraftMinContinueProbability: pMin,
    keepModelInMemory: false,
    useFp16ForKVCache: true,
    tryMmap: false,
    tryDirectIO: false,
    llamaKCacheQuantizationType: false,
    llamaVCacheQuantizationType: false,
  },
});
const config = await model.getLoadConfig();
console.log(JSON.stringify({ loaded: model.identifier, draftMax: config.speculativeDraftMaxTokens, pMin: config.speculativeDraftMinContinueProbability }));
