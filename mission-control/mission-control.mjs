// Mission Control — thin read-only status page for the HALO local AI stack.
// v2 plan Phase 6. Holds no state; reads native surfaces; deletable without consequence.
import http from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import os from 'node:os';

const execFileP = promisify(execFile);
const PORT = 3090;
const HOME = os.homedir();
const DSH_SESSIONS = path.join(HOME, '.dsh', 'sessions');
const MEMORY_FILE = path.join(HOME, '.dsh', 'memory', 'memory.json');
const LOADER_Q5 = path.join(HOME, '.lmstudio', 'scripts', 'Load-OpenCode-Qwen.mjs');
const LOADER_WORKER = path.join(HOME, '.lmstudio', 'scripts', 'Load-Worker-Coder.mjs');
const START_DSH = path.join(HOME, '.dsh', 'Start-DSH.ps1');

function tcpCheck(port, timeout = 1500) {
  return new Promise((resolve) => {
    const s = net.connect({ host: '127.0.0.1', port, timeout });
    s.on('connect', () => { s.destroy(); resolve(true); });
    s.on('error', () => resolve(false));
    s.on('timeout', () => { s.destroy(); resolve(false); });
  });
}

async function lmsPs() {
  try {
    const { stdout } = await execFileP('lms', ['ps', '--json'], { shell: true, timeout: 8000 });
    return JSON.parse(stdout || '[]');
  } catch { return null; }
}

// DSH state comes from DSH's own apiproxy RPCs (post-audit boundary fix,
// 2026-08-17): POST /api/<method> with a client-request envelope. The disk
// scrape below survives ONLY as the fallback for when dsh itself is down.
async function dshRpc(method, payload = {}) {
  // Remote-contributed methods (slash names, e.g. pluginInventory/list) wrap
  // their payload in an args field; ordinary gateway methods take it flat.
  const body = method.includes('/') ? { args: payload } : payload;
  const res = await fetch(`http://127.0.0.1:3080/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId: `mc-${Date.now()}`, method, payload: body }),
    signal: AbortSignal.timeout(3000),
  });
  const msg = await res.json();
  if (!msg?.result?.ok) throw new Error(`${method}: ${msg?.result?.error?.code || res.status}`);
  return msg.result.value;
}

// ── Full-telemetry additions (operator directive 2026-08-18: "add them all") ──

// Slow-changing pulls, cached ~30 s.
const slowCache = { at: 0, presets: null, plugins: null };
async function slowPulls() {
  if (Date.now() - slowCache.at < 30000 && slowCache.presets) return slowCache;
  try {
    const [pr, pi] = await Promise.all([dshRpc('agentPreset.list'), dshRpc('pluginInventory/list')]);
    slowCache.presets = (pr.presets || []).map(p => ({ id: p.id, trust: p.trust, isDefault: !!p.isDefault, broken: p.broken || null }));
    const entries = pi.entries || [];
    const active = entries.filter(e => e.enabled && e.fiberPhase === 'active');
    const disabled = entries.filter(e => !e.enabled);
    const abnormal = entries.filter(e => e.enabled && e.fiberPhase !== 'active');
    slowCache.plugins = {
      total: entries.length, active: active.length, disabled: disabled.length, abnormal: abnormal.length,
      disabledList: disabled.map(e => e.entryId).slice(0, 12),
      abnormalList: abnormal.map(e => `${e.entryId} (${e.fiberPhase ?? 'no phase'})`).slice(0, 12),
    };
    slowCache.at = Date.now();
  } catch { /* keep last good cache; dsh may be down */ }
  return slowCache;
}

// Persistent mux stream: one connection carries session/jobs (and queue)
// frames for every session. Snapshot semantics: each frame replaces that
// session's job set. Reconnects with backoff; state marks liveness honestly.
// The events endpoints are WebSockets (GET answers 426): on connect the mux
// auto-subscribes to every visible session and pushes server-request frames.
const mux = { connected: false, lastFrameAt: 0, jobs: new Map(), queues: new Map() };
function muxConnect() {
  let ws;
  try { ws = new WebSocket('ws://127.0.0.1:3080/api/events.mux'); }
  catch { setTimeout(muxConnect, 10000); return; }
  ws.onopen = () => { mux.connected = true; };
  ws.onmessage = (e) => {
    try {
      const frame = JSON.parse(String(e.data));
      mux.lastFrameAt = Date.now();
      const m = frame.method;
      const p = frame.payload || {};
      if (m === 'session/jobs' && p.sessionId) mux.jobs.set(p.sessionId, p.jobs || p.items || []);
      if (m === 'session/queue' && p.sessionId) mux.queues.set(p.sessionId, (p.queue || p.items || []).length);
    } catch { /* ignore malformed frame */ }
  };
  const down = () => { mux.connected = false; setTimeout(muxConnect, 10000); };
  ws.onclose = down;
  ws.onerror = () => { try { ws.close(); } catch { /* already closed */ } };
}
muxConnect();

async function listSessionsApi(limit = 8) {
  const [ws, sess] = await Promise.all([dshRpc('workspace.list'), dshRpc('session.list')]);
  const wsTitle = new Map(ws.items.map(w => [w.workspaceId, w.title || w.path]));
  const wsOfSession = new Map();
  for (const w of ws.items) for (const id of (w.sessionIds || [])) wsOfSession.set(id, w.workspaceId);
  const archived = new Set(ws.archivedSessionIds || []);
  return sess.items
    .filter(s => !s.blank && !archived.has(s.sessionId))
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
    .slice(0, limit)
    .map(s => {
      const v = s.projections?.values || {};
      const st = v.sessionStats || {};
      const tk = v.tokenUsage || {};
      return {
        workspace: wsTitle.get(wsOfSession.get(s.sessionId)) || s.cwd || 'Ungrouped',
        id: s.sessionId.replace(/^session-/, '').slice(0, 8),
        sessionId: s.sessionId,
        title: v.title || null,
        goal: v.goal || null,
        mtime: s.updatedAt || 0,
        running: !!s.running,
        preset: s.agentPreset || '',
        turns: st.turns ?? null,
        kTokIn: Math.round(((tk.uncachedInputTokens || 0) + (tk.cacheReadTokens || 0)) / 1000),
        kTokOut: Math.round((tk.outputTokens || 0) / 1000 * 10) / 10,
        ttftS: st.ttftSteps ? Math.round(st.ttftMs / st.ttftSteps / 1000) : null,
        decodeTps: st.decodeMs ? Math.round(st.decodeTokens / (st.decodeMs / 1000) * 10) / 10 : null,
      };
    });
}

// Fallback only — dsh down means no API; a rough directory listing beats nothing.
function listSessionsScrape(limit = 8) {
  const out = [];
  try {
    for (const proj of fs.readdirSync(DSH_SESSIONS)) {
      const projDir = path.join(DSH_SESSIONS, proj);
      if (!fs.statSync(projDir).isDirectory()) continue;
      for (const sess of fs.readdirSync(projDir)) {
        const sessDir = path.join(projDir, sess);
        try {
          const log = fs.readdirSync(sessDir).find(f => f.startsWith('session.jsonl'));
          if (!log) continue;
          const st = fs.statSync(path.join(sessDir, log));
          const wsRaw = proj.replace(/^-+|-+$/g, '');
          const ws = wsRaw.replace(/^C-/, 'C:\\').replace(/-/g, '\\');
          out.push({ workspace: ws, id: sess.replace(/^session-/, '').slice(0, 8), title: null, mtime: st.mtimeMs, running: false, preset: '', turns: null });
        } catch { /* skip unreadable */ }
      }
    }
  } catch { /* sessions dir missing */ }
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}

function memoryCount() {
  try {
    return fs.readFileSync(MEMORY_FILE, 'utf8').split('\n').filter(l => l.includes('"type":"entity"')).length;
  } catch { return 0; }
}

async function status() {
  const [dshUp, lmUp, models] = await Promise.all([tcpCheck(3080), tcpCheck(1234), lmsPs()]);
  let sessions, sessionsSource;
  if (dshUp) {
    try { sessions = await listSessionsApi(); sessionsSource = 'dsh api'; }
    catch { sessions = listSessionsScrape(); sessionsSource = 'disk scan (api failed)'; }
  } else {
    sessions = listSessionsScrape(); sessionsSource = 'disk scan (dsh down)';
  }
  return {
    time: new Date().toISOString(),
    services: {
      cockpit: dshUp,
      lmstudio: lmUp,
      lmsCli: models !== null,
    },
    models: (models || []).map(m => ({
      identifier: m.identifier,
      quant: m.quantization?.name || '?',
      context: m.contextLength,
      status: m.status,
      queued: m.queued,
      gb: Math.round((m.sizeBytes || 0) / 1e9 * 10) / 10,
    })),
    sessions, sessionsSource,
    presets: dshUp ? (await slowPulls()).presets : null,
    plugins: dshUp ? (await slowPulls()).plugins : null,
    jobs: {
      streamConnected: mux.connected,
      lastFrameAgeS: mux.lastFrameAt ? Math.round((Date.now() - mux.lastFrameAt) / 1000) : null,
      active: [...mux.jobs.entries()].flatMap(([sid, list]) => (list || []).map(j => ({
        session: sid.replace(/^session-/, '').slice(0, 8),
        id: j.jobId || j.id || '?', kind: j.kind || '', state: j.state || j.status || (j.running ? 'running' : ''),
      }))),
      queuedInputs: [...mux.queues.values()].reduce((a, b) => a + b, 0),
    },
    memoryEntities: memoryCount(),
    freeRamGB: Math.round(os.freemem() / 1e9 * 10) / 10,
  };
}

const ACTIONS = {
  'start-cockpit': () => spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', START_DSH], { detached: true, stdio: 'ignore' }).unref(),
  'load-q5': () => spawn('node', [LOADER_Q5], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'load-worker': () => spawn('node', [LOADER_WORKER], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'unload-worker': () => spawn('lms', ['unload', 'qwen3-coder-30b-a3b-instruct'], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'unload-all': () => spawn('lms', ['unload', '--all'], { detached: true, stdio: 'ignore', shell: true }).unref(),
};

const PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>HALO Mission Control</title><style>
:root{--bg:#0b0f14;--panel:#101c2a;--line:#27405c;--ink:#eef6ff;--mut:#9fb3c8;--teal:#4fd8c4;--green:#5fe39a;--amber:#ffc86b;--red:#ff8080}
*{box-sizing:border-box}body{margin:0;background:linear-gradient(180deg,#080c11,#0c1420);color:var(--ink);font:15px/1.5 Segoe UI,Arial,sans-serif;padding:24px}
h1{font-size:1.4rem;margin:0 0 4px}.sub{color:var(--mut);font-size:.85rem;margin-bottom:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
.card h2{font-size:.95rem;margin:0 0 10px;color:#dcecff}
.row{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid #1a2c42;font-size:.9rem}
.row:last-child{border:none}.k{color:var(--mut)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px}
.up{background:var(--green)}.down{background:var(--red)}.busy{background:var(--amber)}
button{background:#12344c;color:#cfe8ff;border:1px solid #3c6284;border-radius:8px;padding:7px 12px;margin:4px 6px 0 0;cursor:pointer;font-size:.85rem}
button:hover{background:#164058}a{color:var(--teal)}
.mut{color:var(--mut);font-size:.8rem}.mono{font-family:Consolas,monospace;font-size:.82rem}
#msg{color:var(--amber);font-size:.85rem;min-height:1.2em;margin-top:6px}
</style></head><body>
<h1>HALO Mission Control</h1><div class="sub">Reads native state every 5 s · holds nothing · <span id="stamp"></span></div>
<div class="grid">
<div class="card"><h2>Services</h2><div id="services"></div>
<button onclick="act('start-cockpit')">Start cockpit</button>
<a href="http://127.0.0.1:3080" target="_blank"><button>Open cockpit</button></a></div>
<div class="card"><h2>Models (lms ps — truth source)</h2><div id="models"></div>
<button onclick="act('load-q5')">Load Brain (Q5)</button><button onclick="act('load-worker')">Load Worker (MoE)</button><br>
<button onclick="act('unload-worker')">Unload Worker</button><button onclick="act('unload-all')">Unload All</button>
<div id="msg"></div></div>
<div class="card"><h2>Recent sessions <span id="ssrc" class="mut"></span></h2><div id="sessions" class="mono"></div></div>
<div class="card"><h2>Plugin health</h2><div id="plugins"></div></div>
<div class="card"><h2>Background jobs <span id="jsrc" class="mut"></span></h2><div id="jobs" class="mono"></div></div>
<div class="card"><h2>Agent presets</h2><div id="presets"></div></div>
<div class="card"><h2>System</h2><div id="system"></div></div>
</div>
<script>
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
async function act(a){document.getElementById('msg').textContent='running: '+a+'…';
  await fetch('/api/action/'+a,{method:'POST'});
  setTimeout(()=>{document.getElementById('msg').textContent='';refresh()},2500)}
async function refresh(){try{
  const s=await (await fetch('/api/status')).json();
  document.getElementById('stamp').textContent=new Date(s.time).toLocaleTimeString();
  const svc=[['Harness cockpit (:3080)',s.services.cockpit],['LM Studio API (:1234)',s.services.lmstudio],['lms CLI',s.services.lmsCli]];
  document.getElementById('services').innerHTML=svc.map(([n,up])=>'<div class="row"><span><span class="dot '+(up?'up':'down')+'"></span>'+n+'</span><span class="k">'+(up?'up':'down')+'</span></div>').join('');
  document.getElementById('models').innerHTML=s.models.length?s.models.map(m=>'<div class="row"><span><span class="dot '+(m.status==='idle'?'up':'busy')+'"></span>'+esc(m.identifier)+'</span><span class="k">'+esc(m.quant)+' · '+(m.context/1024|0)+'K · '+m.gb+' GB · '+esc(m.status)+(m.queued?' · queue '+m.queued:'')+'</span></div>').join(''):'<div class="mut">no models loaded</div>';
  document.getElementById('ssrc').textContent='('+(s.sessionsSource||'')+')';
  document.getElementById('sessions').innerHTML=s.sessions.length?s.sessions.map(x=>'<div class="row"><span><span class="dot '+(x.running?'busy':'up')+'"></span>'+esc(x.title||x.id)+(x.preset?' <span class="mut">['+esc(x.preset)+']</span>':'')+'</span><span class="k">'+esc(x.workspace)+(x.turns!=null?' · '+x.turns+' turns':'')+(x.kTokIn?' · '+x.kTokIn+'K in/'+x.kTokOut+'K out':'')+(x.decodeTps?' · '+x.decodeTps+' t/s':'')+' · '+new Date(x.mtime).toLocaleTimeString()+'</span></div>').join(''):'<div class="mut">none</div>';
  if(s.plugins){document.getElementById('plugins').innerHTML='<div class="row"><span><span class="dot '+(s.plugins.abnormal?'down':'up')+'"></span>'+s.plugins.active+' active · '+s.plugins.disabled+' disabled · '+s.plugins.abnormal+' abnormal</span><span class="k">of '+s.plugins.total+' rows</span></div>'+(s.plugins.abnormalList.length?s.plugins.abnormalList.map(p=>'<div class="row"><span style="color:var(--red)">'+esc(p)+'</span></div>').join(''):'')+(s.plugins.disabledList.length?'<div class="row"><span class="mut">disabled: '+esc(s.plugins.disabledList.join(', '))+'</span></div>':'')}else{document.getElementById('plugins').innerHTML='<div class="mut">dsh down — no inventory</div>'}
  document.getElementById('jsrc').textContent=s.jobs.streamConnected?'(stream live)':'(stream down)';
  document.getElementById('jobs').innerHTML=(s.jobs.active.length?s.jobs.active.map(j=>'<div class="row"><span><span class="dot busy"></span>'+esc(j.kind||'job')+' '+esc(j.id)+'</span><span class="k">'+esc(j.session)+' · '+esc(j.state)+'</span></div>').join(''):'<div class="mut">no active jobs</div>')+(s.jobs.queuedInputs?'<div class="row"><span class="k">queued inputs: '+s.jobs.queuedInputs+'</span></div>':'');
  if(s.presets){document.getElementById('presets').innerHTML=s.presets.map(p=>'<div class="row"><span><span class="dot '+(p.broken?'down':'up')+'"></span>'+esc(p.id)+(p.isDefault?' <span style="color:var(--teal)">★ default</span>':'')+'</span><span class="k">'+esc(p.trust)+(p.broken?' · <span style=\"color:var(--red)\">'+esc(String(p.broken))+'</span>':'')+'</span></div>').join('')}else{document.getElementById('presets').innerHTML='<div class="mut">dsh down — no roster</div>'}
  document.getElementById('system').innerHTML='<div class="row"><span class="k">Free RAM</span><span>'+s.freeRamGB+' GB</span></div><div class="row"><span class="k">Memory entities</span><span>'+s.memoryEntities+'</span></div><div class="row"><span class="k">Harness pin</span><span class="mono">dsh 0.1.0-rc.7</span></div>';
}catch(e){document.getElementById('stamp').textContent='status fetch failed'}}
refresh();setInterval(refresh,5000);
</script></body></html>`;

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === '/' ) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(PAGE); return; }
    if (req.url === '/api/status') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(await status())); return; }
    if (req.method === 'POST' && req.url.startsWith('/api/action/')) {
      const a = req.url.split('/').pop();
      if (ACTIONS[a]) { ACTIONS[a](); res.writeHead(200); res.end('ok'); return; }
      res.writeHead(404); res.end('unknown action'); return;
    }
    res.writeHead(404); res.end('not found');
  } catch (e) { res.writeHead(500); res.end(String(e)); }
});
server.listen(PORT, '127.0.0.1', () => console.log(`Mission Control on http://127.0.0.1:${PORT}`));
