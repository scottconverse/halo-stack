// On-demand MoE worker for harness fan-out (v2 plan, Phase 2 verdict).
// TTL 2h: loads in ~1 min when needed, returns ~16 GB when idle.
//
// 2026-08-21: same two defects as the brain loader, fixed the same way.
// (1) This imported ./vendor/node_modules/@lmstudio/sdk, a directory that was
//     never in the repository, so every clone failed with MODULE_NOT_FOUND.
//     Now the stock public SDK, pinned and installed by Deploy-ToLive.ps1.
// (2) Public 1.5.0 silently drops maxParallelPredictions, and its
//     getLoadConfig() returns a shape whose fields all read undefined -- so
//     the old assert on line 32 would throw and unload a model that had
//     loaded correctly. Wire-level injection below; verification from
//     `lms ps --json`, the stack's own truth source.
import { LMStudioClient } from "@lmstudio/sdk";
import { execSync } from "node:child_process";

const modelPath = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf";
const modelId = "qwen3-coder-30b-a3b-instruct";
const client = new LMStudioClient();

for (const model of await client.llm.listLoaded()) {
  if (model.identifier === modelId) {
    await client.llm.unload(model.identifier);
  }
}

// Fields the published SDK accepts and then discards. Keep in sync with the
// `config` block below.
const proto = Object.getPrototypeOf(client.llm);
const origMap = proto.loadConfigToKVConfig;
proto.loadConfigToKVConfig = function (cfg) {
  const kv = origMap.call(this, cfg);
  kv.fields.push(
    { key: "llm.load.numParallelSessions", value: 1 },
    { key: "load.gpuStrictVramCap", value: true },
  );
  return kv;
};

await client.llm.load(modelPath, {
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

// deviceIdentifier must be null: on an LM Link federated LM Studio another box
// can publish this same identity and satisfy a naive check.
// GATE-2026-08-21 / W1 (Critical): same fix as the brain loader. A verification
// that cannot RUN is UNVERIFIED, never FAILED -- the load already succeeded, so
// do not make Start-DSH retry it or unload a working model. SDK first (no
// subprocess), lms ps fallback for fields the SDK omits.
let live = null, verifiedBy = null;
try {
  const loaded = await client.llm.listLoaded();
  const m = loaded.find((x) => x.identifier === modelId);
  if (m) { live = m; verifiedBy = "sdk"; }
} catch { /* fall through */ }
if (!live) {
  try {
    const ps = JSON.parse(execSync("lms ps --json").toString());
    live = ps.find((m) => m.identifier === modelId && !m.deviceIdentifier) || null;
    if (live) verifiedBy = "lms-ps";
  } catch (e) {
    console.log(JSON.stringify({ identifier: modelId, verification: "UNVERIFIED", reason: String(e.message || e) }));
    process.exit(0);
  }
}
const checks = {
  loadedLocally: !!live,
  contextLength: live?.contextLength == null || live.contextLength === 32768,
  parallel: live?.parallel == null || live.parallel === 1,
};
const bad = Object.entries(checks).filter(([, ok]) => !ok);
if (bad.length > 0) {
  await client.llm.unload(modelId);
  throw new Error(`Worker load profile mismatch: ${JSON.stringify({ bad, live }, null, 2)}`);
}
console.log(JSON.stringify({
  identifier: modelId,
  verifiedBy,
  path: live.path,
  contextLength: live.contextLength ?? null,
  parallel: live.parallel ?? null,
}));
