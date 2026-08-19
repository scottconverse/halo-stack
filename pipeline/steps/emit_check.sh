#!/usr/bin/env bash
# Step `emit_check` - the truncation + syntax gate, and the ONLY writer of
# artifact files. The model produces bounded text; deterministic code wields
# the file tools. Truncation detection: the emitter must end with the
# sentinel line <<CHUNK-COMPLETE>> - a cut-off reply cannot.
set -euo pipefail
RUN="${WORKFLOW_RUN_DIR:-runs/latest}"
node -e '
const fs = require("fs"), path = require("path"), cp = require("child_process");
const run = process.argv[1];
const state = JSON.parse(fs.readFileSync(run + "/emit-state.json", "utf8"));
const cur = state.current;
let out = fs.readFileSync(run + "/emit_chunk.out", "utf8");
out = out.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
const fence = out.match(/^```[a-z]*\s*([\s\S]*?)```\s*(<<CHUNK-COMPLETE>>)?\s*$/);
if (fence) out = (fence[1] || "").trim() + (fence[2] ? "\n<<CHUNK-COMPLETE>>" : "");
if (!/<<CHUNK-COMPLETE>>\s*$/.test(out)) {
  const msg = "FAIL chunk " + cur.index + " (" + cur.file + "): completion sentinel missing - output truncated or emitter ignored the contract. Re-emit this chunk COMPLETELY and end with <<CHUNK-COMPLETE>> on its own line.";
  fs.writeFileSync(run + "/emit-check.txt", msg);
  console.error(msg); process.exit(1);
}
const content = out.replace(/<<CHUNK-COMPLETE>>\s*$/, "").replace(/\s+$/, "") + "\n";
if (/\.\.|^\/|^[A-Za-z]:/.test(cur.file)) { console.error("unsafe path " + cur.file); process.exit(1); }
const target = path.join(run, "artifacts", cur.file);
fs.mkdirSync(path.dirname(target), { recursive: true });
if (cur.mode === "create") fs.writeFileSync(target, content);
else fs.appendFileSync(target, content);
if (/\.(mjs|js|cjs)$/.test(cur.file) && state.done + 1 === state.total) {
  const r = cp.spawnSync(process.execPath, ["--check", target], { encoding: "utf8" });
  if (r.status !== 0) {
    const msg = "FAIL chunk " + cur.index + ": file complete but node --check failed:\n" + r.stderr.slice(0, 1500);
    fs.writeFileSync(run + "/emit-check.txt", msg);
    console.error(msg); process.exit(1);
  }
}
state.done += 1;
if (state.done < state.total) {
  const plan = JSON.parse(fs.readFileSync(run + "/emit-plan.json", "utf8"));
  const next = plan.chunks[state.done];
  const nt = path.join(run, "artifacts", next.file);
  let tail = "";
  if (fs.existsSync(nt)) tail = fs.readFileSync(nt, "utf8").split("\n").slice(-60).join("\n");
  state.current = Object.assign({ index: state.done, file_tail: tail }, next);
} else {
  state.current = null;
}
fs.writeFileSync(run + "/emit-state.json", JSON.stringify(state, null, 2));
const ok = "OK chunk " + cur.index + " -> " + cur.file + " (" + cur.mode + ", " + content.length + " chars); done " + state.done + "/" + state.total;
fs.writeFileSync(run + "/emit-check.txt", ok);
console.log(ok);
' "$RUN"
