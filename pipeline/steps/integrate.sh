#!/usr/bin/env bash
# Step `integrate` - full verification over the assembled artifacts, plus
# review-input.md: the whole artifact inlined for the stateless clean-room
# reviewer (a raw API call cannot read files; the payload IS the interface).
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs"), path = require("path"), cp = require("child_process");
const run = process.argv[1];
const art = path.join(run, "artifacts");
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (e.isDirectory()) walk(path.join(d, e.name));
    else files.push(path.join(d, e.name));
  }
})(art);
if (!files.length) { console.error("no artifacts produced"); process.exit(1); }
const report = [];
let failed = false;
for (const f of files) {
  const rel = path.relative(art, f);
  if (/\.(mjs|js|cjs)$/.test(f)) {
    const r = cp.spawnSync(process.execPath, ["--check", f], { encoding: "utf8" });
    report.push((r.status === 0 ? "ok  " : "FAIL") + " node --check " + rel + (r.status === 0 ? "" : "\n" + r.stderr.slice(0, 1200)));
    if (r.status !== 0) failed = true;
  } else {
    report.push("ok   (no checker) " + rel);
  }
}
let review = "";
for (const f of files) {
  const rel = path.relative(art, f);
  review += "\n\n===== FILE: " + rel + " =====\n" + fs.readFileSync(f, "utf8");
}
if (review.length > 90000) review = review.slice(0, 90000) + "\n[... truncated for reviewer prompt budget - flag if the visible portion already has findings ...]";
fs.writeFileSync(run + "/review-input.md", review.trim() + "\n");
fs.writeFileSync(run + "/integrate-report.txt", report.join("\n"));
console.log(report.join("\n"));
process.exit(failed ? 1 : 0);
' "$RUN"
