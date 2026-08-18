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

function listSessions(limit = 8) {
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
          // projectKey is an escaped path; rough human form for display only.
          const wsRaw = proj.replace(/^-+|-+$/g, '');
          const ws = wsRaw.replace(/^C-/, 'C:\\').replace(/-/g, '\\');
          out.push({ workspace: ws, id: sess.replace(/^session-/, '').slice(0, 8), mtime: st.mtimeMs, sizeKB: Math.round(st.size / 1024) });
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
    sessions: listSessions(),
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
<div class="card"><h2>Recent sessions</h2><div id="sessions" class="mono"></div></div>
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
  document.getElementById('sessions').innerHTML=s.sessions.length?s.sessions.map(x=>'<div class="row"><span>'+esc(x.workspace)+'</span><span class="k">'+esc(x.id)+' · '+x.sizeKB+' KB · '+new Date(x.mtime).toLocaleTimeString()+'</span></div>').join(''):'<div class="mut">none</div>';
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
