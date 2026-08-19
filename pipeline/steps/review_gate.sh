#!/usr/bin/env bash
# Step `review_gate` - deterministic guard on the reviewer's own output:
# JSON parses (a truncated review cannot), verdict field is sane, every
# finding names a real artifact file.
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs"), path = require("path");
const run = process.argv[1];
let raw = fs.readFileSync(run + "/review.json", "utf8");
raw = raw.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
const fence = raw.match(/```(?:json)?\s*([\s\S]*?)```/);
if (fence) raw = fence[1].trim();
const start = raw.indexOf("{");
if (start > 0) raw = raw.slice(start);
let rev;
try { rev = JSON.parse(raw); } catch (e) {
  fs.writeFileSync(run + "/review-gate.txt", "FAIL: review is not valid JSON: " + e.message);
  console.error("review is not valid JSON (truncated or prose): " + e.message + ". Output ONLY the JSON object."); process.exit(1);
}
const errs = [];
if (!["clean", "findings"].includes(rev.verdict)) errs.push("verdict must be clean|findings");
if (!Array.isArray(rev.findings)) errs.push("findings must be an array");
if (rev.verdict === "clean" && (rev.findings || []).length) errs.push("verdict clean but findings non-empty");
if (rev.verdict === "findings" && !(rev.findings || []).length) errs.push("verdict findings but findings empty");
(rev.findings || []).forEach((f, i) => {
  if (!f.file || !f.issue) errs.push("finding " + i + ": needs file and issue");
  else if (!fs.existsSync(path.join(run, "artifacts", f.file))) errs.push("finding " + i + ": references nonexistent file " + f.file);
});
if (errs.length) {
  fs.writeFileSync(run + "/review-gate.txt", "FAIL:\n" + errs.join("\n"));
  console.error(errs.join("\n")); process.exit(1);
}
fs.writeFileSync(run + "/review.json", JSON.stringify(rev, null, 2));
fs.writeFileSync(run + "/review-gate.txt", "OK: verdict=" + rev.verdict + ", findings=" + rev.findings.length);
// Contract: stdout becomes the pass-edge payload (review.json) - print
// exactly the cleaned review and nothing else.
console.log(JSON.stringify(rev, null, 2));
' "$RUN"
