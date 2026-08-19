#!/usr/bin/env bash
# Step `verdict_route` - router: pass on a clean review, fail with the
# findings as the rework payload otherwise.
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs");
const run = process.argv[1];
const rev = JSON.parse(fs.readFileSync(run + "/review.json", "utf8"));
if (rev.verdict === "clean") { console.log("review clean"); process.exit(0); }
fs.writeFileSync(run + "/rework.json", JSON.stringify(rev.findings, null, 2));
console.log("REWORK - reviewer findings:\n" + rev.findings.map((f) => f.file + ": " + f.issue).join("\n"));
process.exit(1);
' "$RUN"
