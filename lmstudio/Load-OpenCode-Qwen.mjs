// 5070TI ADAPTATION of the HALO brain loader (original: Q5_K_XL @65536, Vulkan,
// vendored SDK). Changes, all measured-and-forced (TESTER-5070ti-bench.md):
//   - Q5_K_XL (20.2GB) cannot fit 16GB VRAM -> UD-Q3_K_XL, 100% GPU.
//   - Identity suffixed -5070ti: the unsuffixed id resolves to the FEDERATED
//     HALO device on this box.
//   - ctx 32768 requested; this LM Studio build AUTO-SIZES context to leftover
//     VRAM (f16 KV -> 32000, q8_0 KV -> 40448 measured). Verify >=32000.
//   - KV q8_0 (f16 KV overflows at 32K; q8_0 doubles depth decode, no visible
//     quality change) and MTP OFF (halves decode on the CUDA engine).
//   - Public SDK 1.5.0 lacks the newer load fields -> wire-level injection.
import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";
import { execSync } from "node:child_process";

const modelPath = "unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q3_K_XL.gguf";
const modelId = "qwen/qwen3.8-27b-5070ti";
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
    { key: "llm.load.llama.speculativeDecoding.draftSimple", value: false },
    { key: "llm.load.llama.contextCheckpoints", value: 32 },
    { key: "llm.load.llama.physicalBatchSize", value: 512 },
    { key: "llm.load.numParallelSessions", value: 1 },
    { key: "llm.load.useUnifiedKvCache", value: true },
    { key: "llm.load.offloadKVCacheToGpu", value: true },
    { key: "load.gpuStrictVramCap", value: true }
  );
  return kv;
};

const model = await client.llm.load(modelPath, {
  identifier: modelId,
  ttl: 86400,
  verbose: "info",
  config: {
    gpu: { ratio: "max" },
    contextLength: 32768,
    evalBatchSize: 2048,
    flashAttention: true,
    keepModelInMemory: false,
    useFp16ForKVCache: false,
    tryMmap: false,
    llamaKCacheQuantizationType: "q8_0",
    llamaVCacheQuantizationType: "q8_0",
  },
});

// SDK 1.5.0's getLoadConfig is not usable for verification -> lms ps is the
// stack's truth source anyway.
const ps = JSON.parse(execSync("lms ps --json").toString());
const live = ps.find((m) => m.identifier === modelId && !m.deviceIdentifier);
const checks = {
  loadedLocally: !!live,
  contextLength: (live?.contextLength ?? 0) >= 32000, // auto-sized by free VRAM
  parallel: live?.parallel === 1,
  quant: live?.quantization?.name === "Q3_K_XL",
};
const bad = Object.entries(checks).filter(([, ok]) => !ok);
if (bad.length > 0) {
  if (live) await client.llm.unload(modelId);
  throw new Error(`Qwen 5070ti load profile mismatch: ${JSON.stringify({ bad, live })}`);
}
console.log(JSON.stringify({ identifier: modelId, path: live.path, contextLength: live.contextLength }));
