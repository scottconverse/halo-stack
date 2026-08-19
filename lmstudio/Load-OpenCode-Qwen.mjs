import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";

// Pin the exact on-disk quant while keeping the API identity stable for OpenCode.
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
    reasoningBudgetMessage: "",
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
    tryDirectIO: false,
    llamaKCacheQuantizationType: "q8_0",
    llamaVCacheQuantizationType: "q8_0",
  },
});

const config = await model.getLoadConfig();
const expected = {
  modelPath: [model.path, modelPath],
  "gpu.ratio": [config.gpu?.ratio, "max"],
  "gpu.numCpuExpertLayersRatio": [config.gpu?.numCpuExpertLayersRatio, "off"],
  gpuStrictVramCap: [config.gpuStrictVramCap, true],
  maxParallelPredictions: [config.maxParallelPredictions, 1],
  useUnifiedKvCache: [config.useUnifiedKvCache, true],
  offloadKVCacheToGpu: [config.offloadKVCacheToGpu, true],
  contextLength: [config.contextLength, 131072],
  evalBatchSize: [config.evalBatchSize, 2048],
  physicalBatchSize: [config.physicalBatchSize, 512],
  flashAttention: [config.flashAttention, true],
  contextCheckpoints: [config.contextCheckpoints, 32],
  speculativeDraftMtp: [config.speculativeDraftMtp, true],
  speculativeDraftMaxTokens: [config.speculativeDraftMaxTokens, 4],
  speculativeDraftMinContinueProbability: [config.speculativeDraftMinContinueProbability, 0.5],
  keepModelInMemory: [config.keepModelInMemory, false],
  useFp16ForKVCache: [config.useFp16ForKVCache, false],
  llamaKCacheQuantizationType: [config.llamaKCacheQuantizationType, "q8_0"],
  llamaVCacheQuantizationType: [config.llamaVCacheQuantizationType, "q8_0"],
  tryMmap: [config.tryMmap, false],
};
const mismatches = Object.entries(expected)
  .filter(([, [actual, wanted]]) => actual !== wanted)
  .map(([name, [actual, wanted]]) => ({ name, actual, wanted }));
if (mismatches.length > 0) {
  await client.llm.unload(model.identifier);
  throw new Error(`Qwen load profile mismatch: ${JSON.stringify(mismatches)}`);
}

console.log(JSON.stringify({ identifier: model.identifier, path: model.path, config }));
