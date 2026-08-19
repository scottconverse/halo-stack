#!/usr/bin/env bash
# Step `plan_check` - validate emit-plan.json deterministically and initialize
# emit-state.json. A plan that parses is also proof the planner was not
# truncated (cut JSON does not parse).
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs");
const run = process.argv[1];
let raw = fs.readFileSync(run + "/emit-plan.json", "utf8");
raw = raw.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
const fence = raw.match(/```(?:json)?\s*([\s\S]*?)```/);
if (fence) raw = fence[1].trim();
const start = raw.indexOf("{");
if (start > 0) raw = raw.slice(start);
let plan;
try { plan = JSON.parse(raw); } catch (e) {
  fs.writeFileSync(run + "/plan-check.txt", "FAIL: plan is not valid JSON (truncated or malformed): " + e.message);
  console.error("plan is not valid JSON: " + e.message); process.exit(1);
}
const room = JSON.parse(fs.readFileSync(run + "/room.json", "utf8"));
const errs = [];
if (!Array.isArray(plan.chunks) || plan.chunks.length === 0) errs.push("no chunks array");
const created = new Set();
(plan.chunks || []).forEach((c, i) => {
  if (!c.file || typeof c.file !== "string") errs.push("chunk " + i + ": missing file");
  if (/\.\.|^\/|^[A-Za-z]:/.test(c.file || "")) errs.push("chunk " + i + ": unsafe path " + c.file);
  if (!["create", "append"].includes(c.mode)) errs.push("chunk " + i + ": mode must be create|append");
  if (c.mode === "create" && created.has(c.file)) errs.push("chunk " + i + ": second create for " + c.file);
  if (c.mode === "append" && !created.has(c.file)) errs.push("chunk " + i + ": append before create for " + c.file);
  if (c.mode === "create") created.add(c.file);
  if (!Number.isFinite(c.est_tokens) || c.est_tokens <= 0) errs.push("chunk " + i + ": bad est_tokens");
  if (c.est_tokens > room.cap) errs.push("chunk " + i + ": est_tokens " + c.est_tokens + " exceeds cap " + room.cap);
  if (!c.description) errs.push("chunk " + i + ": missing description");
});
if (errs.length) {
  fs.writeFileSync(run + "/plan-check.txt", "FAIL:\n" + errs.join("\n"));
  console.error(errs.join("\n")); process.exit(1);
}
fs.writeFileSync(run + "/emit-plan.json", JSON.stringify(plan, null, 2));
const state = { total: plan.chunks.length, done: 0,
  current: Object.assign({ index: 0, file_tail: "" }, plan.chunks[0]) };
fs.writeFileSync(run + "/emit-state.json", JSON.stringify(state, null, 2));
const ok = "OK: " + plan.chunks.length + " chunks, all under cap " + room.cap;
fs.writeFileSync(run + "/plan-check.txt", ok);
console.log(ok);
' "$RUN"
