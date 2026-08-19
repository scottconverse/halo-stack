#!/usr/bin/env bash
# Step `route_next` - router: pass when every chunk is done, fail (= "next
# chunk, please") otherwise. No model call to decide what a file already says.
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs");
const run = process.argv[1];
const state = JSON.parse(fs.readFileSync(run + "/emit-state.json", "utf8"));
if (state.done >= state.total) { console.log("all " + state.total + " chunks emitted"); process.exit(0); }
fs.writeFileSync(run + "/next-chunk.json", JSON.stringify(state.current, null, 2));
console.log("next: chunk " + state.current.index + " of " + state.total + " -> " + state.current.file);
process.exit(1);
' "$RUN"
