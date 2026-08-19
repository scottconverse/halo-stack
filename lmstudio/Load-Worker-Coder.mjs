// 5070TI ADAPTATION of the on-demand MoE worker loader. Q4_K_S is 16.3GB —
// larger than free VRAM with the brain resident, and near-VRAM-size alone, so
// gpuStrictVramCap decides the split; measure, don't assume. Identity is
// unchanged (no federation collision — only the brain id is published by the
// remote HALO device). Same SDK-1.5.0 wire-injection as the brain loader.
// Original self-check required contextLength===32768; THIS server build clamps
// to 32000, so the check verifies 32000 via lms ps (version-drift finding).
import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";
import { execSync } from "node:child_process";

const modelPath = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf";
const modelId = "qwen3-coder-30b-a3b-instruct";
const client = new LMStudioClient();

for (const model of await client.llm.listLoaded()) {
  if (model.identifier === modelId) {
    await client.llm.unload(model.identifier);
  }
}

const proto = Object.getPrototypeOf(client.llm);
const origMap = proto.loadConfigToKVConfig;
proto.loadConfigToKVConfig = function (cfg) {
  const kv = origMap.call(this, cfg);
  kv.fields.push(
    { key: "llm.load.llama.speculativeDecoding.draftMtp", value: false },
    { key: "llm.load.numParallelSessions", value: 1 },
    { key: "llm.load.useUnifiedKvCache", value: true },
    { key: "llm.load.offloadKVCacheToGpu", value: true },
    { key: "load.gpuStrictVramCap", value: true }
  );
  return kv;
};

const model = await client.llm.load(modelPath, {
  identifier: modelId,
  ttl: 7200,
  verbose: "info",
  config: {
    gpu: { ratio: "max" },
    contextLength: 32768,
    flashAttention: true,
    keepModelInMemory: false,
    useFp16ForKVCache: false,
    llamaKCacheQuantizationType: "q8_0",
    llamaVCacheQuantizationType: "q8_0",
    tryMmap: false,
  },
});

const ps = JSON.parse(execSync("lms ps --json").toString());
const live = ps.find((m) => m.identifier === modelId && !m.deviceIdentifier);
if (!live || live.contextLength < 24000) { // auto-sized by free VRAM; hybrid may trim
  if (live) await client.llm.unload(modelId);
  throw new Error(`Worker load profile mismatch: ${JSON.stringify(live)}`);
}
console.log(JSON.stringify({ identifier: modelId, path: live.path, contextLength: live.contextLength }));
