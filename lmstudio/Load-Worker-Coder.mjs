import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";

// On-demand MoE worker for harness fan-out (v2 plan, Phase 2 verdict).
// TTL 2h: loads in ~1 min when needed, returns ~16 GB when idle.
const modelPath = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf";
const modelId = "qwen3-coder-30b-a3b-instruct";
const client = new LMStudioClient();

for (const model of await client.llm.listLoaded()) {
  if (model.identifier === modelId) {
    await client.llm.unload(model.identifier);
  }
}

const model = await client.llm.load(modelPath, {
  identifier: modelId,
  ttl: 7200,
  verbose: "info",
  config: {
    gpu: { ratio: "max", mainGpu: 0, splitStrategy: "evenly", disabledGpus: [] },
    gpuStrictVramCap: true,
    maxParallelPredictions: 1,
    contextLength: 32768,
    flashAttention: true,
    useFp16ForKVCache: true,
    keepModelInMemory: false,
    tryMmap: false,
  },
});

const config = await model.getLoadConfig();
if (config.contextLength !== 32768) {
  await client.llm.unload(model.identifier);
  throw new Error(`Worker load profile mismatch: contextLength=${config.contextLength}`);
}
console.log(JSON.stringify({ identifier: model.identifier, path: model.path, contextLength: config.contextLength }));
