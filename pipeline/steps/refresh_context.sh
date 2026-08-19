#!/usr/bin/env bash
# Step `measure_room` - Measure context room.
# Stateless-backend variant: the orchestrator composes every prompt, so room =
# model context window - the prompt budget we allow ourselves - safety margin.
# (In the dsh-session variant this instead reads the apiproxy contextPressure
# projection; see docs/design/budgeted-emit-pipeline-design.md.)
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
MODEL_ID="${PIPELINE_MODEL:-qwen/qwen3.8-27b}"
node -e '
const http = require("http");
const fs = require("fs");
const run = process.argv[1], modelId = process.argv[2];
http.get("http://127.0.0.1:1234/api/v0/models", (res) => {
  let b = ""; res.on("data", (c) => b += c);
  res.on("end", () => {
    let ctx = 65536;
    try {
      const m = JSON.parse(b).data.find((x) => x.id === modelId);
      if (m && m.loaded_context_length) ctx = m.loaded_context_length;
      else if (m && m.max_context_length) ctx = Math.min(m.max_context_length, 65536);
    } catch (e) { console.error("model list parse failed: " + e.message); process.exit(1); }
    const promptBudget = 24000, safety = 2000;
    const room = ctx - promptBudget - safety;
    const cap = Math.min(Math.floor(room / 2), 12000);
    const out = { contextWindow: ctx, promptBudget, room, cap, modelId };
    fs.writeFileSync(run + "/room.json", JSON.stringify(out, null, 2));
    console.log(JSON.stringify(out));
  });
}).on("error", (e) => { console.error("LM Studio unreachable: " + e.message); process.exit(1); });
' "$RUN" "$MODEL_ID"
