// Mission Control — multi-tab operator console for the HALO local AI stack.
// v3: 7-card single page -> tabbed console (overview/models/sessions/plugins/system)
// with a master status strip. Zero deps, single file. Reads native surfaces plus
// a tiny bit of local state (mc-state.json, mc-history.jsonl) for trend/cadence
// tracking. Backup of the v2 cards page: mission-control.v2-cards.mjs.bak
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
const CORDIS_PATCH = path.join(HOME, '.dsh', 'cordis.patch.yml');
// Shared store first; per-profile node_modules (web/headless) hold the
// add-on packages (e.g. dsh-subagent-*) that only exist per-profile.
const DEEPSEEK_PKG_DIRS = [
  path.join(HOME, '.dsh', 'profiles', 'node_modules', '@deepseek-ai'),
  path.join(HOME, '.dsh', 'profiles', 'web', 'node_modules', '@deepseek-ai'),
  path.join(HOME, '.dsh', 'profiles', 'headless', 'node_modules', '@deepseek-ai'),
];
const MC_DIR = path.join(HOME, '.dsh', 'mission-control');
const STATE_FILE = path.join(MC_DIR, 'mc-state.json');
const HISTORY_FILE = path.join(MC_DIR, 'mc-history.jsonl');
const LMSTUDIO_LOGS = path.join(HOME, '.lmstudio', 'server-logs');
const LMSTUDIO_VERSION_FILE = path.join(HOME, '.lmstudio', '.internal', 'historical-version-info.json');
const LOADER_Q5 = path.join(HOME, '.lmstudio', 'scripts', 'Load-OpenCode-Qwen.mjs');
const LOADER_WORKER = path.join(HOME, '.lmstudio', 'scripts', 'Load-Worker-Coder.mjs');
const START_DSH = path.join(HOME, '.dsh', 'Start-DSH.ps1');
const DSH_VERSION_PIN = '0.1.0-rc.7';
// Machine has 128 GiB unified physical RAM (Strix Halo APU). Windows only sees
// its own pool via os.totalmem(); the rest is the GPU carveout. Compute the
// split at runtime — do NOT hardcode a fixed 64/64 number, it drifts.
const MACHINE_TOTAL_RAM = 128 * 1024 * 1024 * 1024;
const MEMORY_ENTITY_TRIPWIRE = 50;

function tcpCheck(port, timeout = 1500) {
  return new Promise((resolve) => {
    const s = net.connect({ host: '127.0.0.1', port, timeout });
    s.on('connect', () => { s.destroy(); resolve(true); });
    s.on('error', () => resolve(false));
    s.on('timeout', () => { s.destroy(); resolve(false); });
  });
}

function gb(bytes) { return Math.round((bytes || 0) / 1e9 * 10) / 10; }
// Binary (GiB) variant — used for RAM/GPU pools, which is what Adrenalin's VGM
// split and Windows' own reporting actually use. Disk stays decimal (gb()) —
// drive capacities are marketed in decimal GB.
function gib(bytes) { return Math.round((bytes || 0) / 1073741824 * 10) / 10; }

// ─────────────────────────── lms CLI surfaces ───────────────────────────

async function lmsPs() {
  try {
    const { stdout } = await execFileP('lms', ['ps', '--json'], { shell: true, timeout: 8000 });
    return JSON.parse(stdout || '[]');
  } catch { return null; }
}

async function lmsLs() {
  try {
    const { stdout } = await execFileP('lms', ['ls', '--json'], { shell: true, timeout: 10000 });
    return JSON.parse(stdout || '[]');
  } catch { return null; }
}

// `lms runtime ls --json` doesn't exist on this build — falls back to parsing
// the text table. Columns: LLM ENGINE (name@version) | SELECTED (✓) | MODEL FORMAT.
async function lmsRuntimeLs() {
  try {
    const { stdout } = await execFileP('lms', ['runtime', 'ls'], { shell: true, timeout: 8000 });
    const lines = stdout.split('\n').map(l => l.replace(/\r$/, '')).filter(l => l.trim());
    const rows = [];
    let selected = null;
    for (const line of lines) {
      if (/^LLM ENGINE/i.test(line)) continue;
      const m = line.match(/^(\S+)\s{2,}/);
      if (!m) continue;
      const engine = m[1];
      const isSelected = line.includes('\u2713');
      const fmtMatch = line.trim().match(/(\S+)\s*$/);
      const format = fmtMatch ? fmtMatch[1] : '';
      const at = engine.lastIndexOf('@');
      const row = { engine, name: at >= 0 ? engine.slice(0, at) : engine, version: at >= 0 ? engine.slice(at + 1) : '', selected: isSelected, format };
      rows.push(row);
      if (isSelected) selected = row;
    }
    return { rows, selected };
  } catch { return null; }
}

// `lms version` prints ASCII art first — hunt for a semver anywhere in the
// output; fall back to the CLI commit line; omit entirely if neither is there.
async function lmsVersionStr() {
  for (const args of [['version'], ['--version']]) {
    try {
      const { stdout } = await execFileP('lms', args, { shell: true, timeout: 5000 });
      const semver = stdout.match(/\b(\d+\.\d+\.\d+)\b/);
      if (semver) return semver[1];
      const commit = stdout.match(/CLI commit:\s*(\S+)/i);
      if (commit) return `commit ${commit[1]}`;
    } catch { /* try next form */ }
  }
  return null;
}

// LM Studio app version isn't exposed live anywhere we can query — the closest
// honest signal is the app's own migration-history file. Label it as such.
function lmStudioAppVersion() {
  try {
    const data = JSON.parse(fs.readFileSync(LMSTUDIO_VERSION_FILE, 'utf8'));
    const hist = data.targetHistories;
    const v = (Array.isArray(hist) && hist.length ? hist[hist.length - 1].lastRecordedAppVersion : null) || data.lastRecorderdAppVersion || null;
    return v ? `${v} (last recorded)` : null;
  } catch { return null; }
}

// ─────────────────────────── dsh cockpit RPC ───────────────────────────

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
    signal: AbortSignal.timeout(5000),
  });
  const msg = await res.json();
  if (!msg?.result?.ok) throw new Error(`${method}: ${msg?.result?.error?.code || res.status}`);
  return msg.result.value;
}

// ── Cordis fiber lifecycle classification ──────────────────────────────
// Each plugin config row is a fiber with states INACTIVE/LOADING/ACTIVE/
// UNLOADING/FAILED (inventory exposes it as fiberPhase, lower/mixed-case in
// the wild). We bucket every entry into exactly one of five UI buckets:
//   active        enabled && phase==='active'
//   disabled      !enabled
//   waiting       enabled, phase is inactive/null/unrecognized — BENIGN,
//                 will self-activate once its declared dependency appears
//   transitioning enabled, phase is loading/reloading/unloading — normal
//                 for a few seconds; only an alarm if STUCK (see below)
//   failed        enabled, phase is failed/error — TERMINAL, the calculus
//                 never auto-retries until config is touched. Always actionable.
function classifyPluginPhase(enabled, fiberPhaseRaw) {
  if (!enabled) return 'disabled';
  const phase = String(fiberPhaseRaw || '').toLowerCase();
  if (phase === 'active') return 'active';
  if (phase === 'loading' || phase === 'reloading' || phase === 'unloading') return 'transitioning';
  if (phase === 'failed' || phase === 'error') return 'failed';
  return 'waiting'; // '', 'inactive', null/undefined on an enabled row
}

function fmtDurationMs(ms) {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  return `${Math.round(m / 60)}h`;
}

// Server-side stickiness tracker for transitioning fibers. A LOADING/
// UNLOADING/RELOADING phase is normal for seconds; one that sits on the
// exact same phase-string for >60s is a diagnosable stall (a stuck
// UNLOADING specifically means the withdrawal guard is waiting on
// dependents) — flag it as stuck, but don't page on ordinary transitions.
const STUCK_MS = 60000;
const transitionTracker = new Map(); // entryId -> { phase, sinceMs }
function trackTransition(entryId, bucket, phaseLower) {
  const now = Date.now();
  if (bucket !== 'transitioning') {
    transitionTracker.delete(entryId);
    return { stuck: false, sinceMs: null };
  }
  const rec = transitionTracker.get(entryId);
  if (!rec || rec.phase !== phaseLower) {
    transitionTracker.set(entryId, { phase: phaseLower, sinceMs: now });
    return { stuck: false, sinceMs: now };
  }
  return { stuck: (now - rec.sinceMs) > STUCK_MS, sinceMs: rec.sinceMs };
}

// Classifies every entry, updates transition stickiness, and returns both a
// per-entryId lookup (for the /api/plugins table) and a summary object (for
// the status strip + plugins tab header).
function classifyPluginEntries(entries) {
  const byId = new Map();
  const counts = { active: 0, disabled: 0, waiting: 0, transitioning: 0, failed: 0, stuck: 0 };
  const failedIds = [], waitingIds = [], stuckList = [];
  for (const e of entries) {
    const phaseLower = String(e.fiberPhase || '').toLowerCase();
    const bucket = classifyPluginPhase(e.enabled, e.fiberPhase);
    const { stuck, sinceMs } = trackTransition(e.entryId, bucket, phaseLower);
    counts[bucket]++;
    if (stuck) {
      counts.stuck++;
      stuckList.push(`${e.entryId} stuck ${phaseLower.toUpperCase()} ${fmtDurationMs(Date.now() - sinceMs)}${phaseLower === 'unloading' ? ' — withdrawal guard waiting on dependents' : ''}`);
    }
    if (bucket === 'failed') failedIds.push(e.entryId);
    if (bucket === 'waiting') waitingIds.push(e.entryId);
    byId.set(e.entryId, { bucket, stuck, sinceMs, phaseLower });
  }
  return {
    byId,
    summary: {
      total: entries.length, ...counts,
      failedList: failedIds.slice(0, 12),
      waitingList: waitingIds.slice(0, 12),
      stuckList: stuckList.slice(0, 12),
    },
  };
}

// Slow-changing pulls, cached ~30 s: presets + full plugin inventory. Both the
// summary strip and the /api/plugins tab endpoint read off this same cache so
// switching tabs doesn't double-hit the cockpit.
const slowCache = { at: 0, presets: null, pluginEntries: null, pluginSummary: null, pluginById: null };
async function slowPulls() {
  if (Date.now() - slowCache.at < 30000 && slowCache.pluginEntries) return slowCache;
  try {
    const [pr, pi] = await Promise.all([dshRpc('agentPreset.list'), dshRpc('pluginInventory/list')]);
    slowCache.presets = (pr.presets || []).map(p => ({ id: p.id, trust: p.trust, isDefault: !!p.isDefault, broken: p.broken || null, name: p.name || p.id }));
    const entries = pi.entries || [];
    slowCache.pluginEntries = entries;
    const { byId, summary } = classifyPluginEntries(entries);
    slowCache.pluginById = byId;
    slowCache.pluginSummary = summary;
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

// ─────────────────────────── sessions ───────────────────────────

function isDriveRoot(p) { return typeof p === 'string' && /^[A-Za-z]:\\?$/.test(p.trim()); }

async function listSessionsApi(limit = 50) {
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
      const workspace = wsTitle.get(wsOfSession.get(s.sessionId)) || s.cwd || 'Ungrouped';
      return {
        workspace,
        driveRootBug: isDriveRoot(workspace) || isDriveRoot(s.cwd),
        id: s.sessionId.replace(/^session-/, '').slice(0, 8),
        sessionId: s.sessionId,
        title: v.title || null,
        goal: v.goal || null,
        mtime: s.updatedAt || 0,
        running: !!s.running,
        preset: s.agentPreset || '',
        turns: st.turns ?? null,
        kTokIn: Math.round(((tk.uncachedInputTokens || 0) + (tk.cacheReadTokens || 0)) / 1000 * 10) / 10,
        kTokOut: Math.round((tk.outputTokens || 0) / 1000 * 10) / 10,
        ttftS: st.ttftSteps ? Math.round(st.ttftMs / st.ttftSteps / 1000 * 10) / 10 : null,
        decodeTps: st.decodeMs ? Math.round(st.decodeTokens / (st.decodeMs / 1000) * 10) / 10 : null,
      };
    });
}

// Fallback only — dsh down means no API; a rough directory listing beats nothing.
function listSessionsScrape(limit = 50) {
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
          const workspace = wsRaw.replace(/^C-/, 'C:\\').replace(/-/g, '\\');
          out.push({
            workspace, driveRootBug: isDriveRoot(workspace), id: sess.replace(/^session-/, '').slice(0, 8),
            sessionId: sess, title: null, goal: null, mtime: st.mtimeMs, running: false, preset: '', turns: null,
            kTokIn: null, kTokOut: null, ttftS: null, decodeTps: null,
          });
        } catch { /* skip unreadable */ }
      }
    }
  } catch { /* sessions dir missing */ }
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}

// Shared 4 s cache so /api/status and /api/sessions don't double-hit dsh.
const sessionsCache = { at: 0, sessions: null, source: null };
async function getSessions(dshUp, limit = 50) {
  if (Date.now() - sessionsCache.at < 4000 && sessionsCache.sessions) return sessionsCache;
  let sessions, source;
  if (dshUp) {
    try { sessions = await listSessionsApi(limit); source = 'dsh api'; }
    catch { sessions = listSessionsScrape(limit); source = 'disk scan (api failed)'; }
  } else {
    sessions = listSessionsScrape(limit); source = 'disk scan (dsh down)';
  }
  sessionsCache.at = Date.now();
  sessionsCache.sessions = sessions;
  sessionsCache.source = source;
  return sessionsCache;
}

function todayStats(sessions) {
  const now = new Date();
  const y0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const todays = sessions.filter(s => s.mtime >= y0);
  return {
    count: todays.length,
    kTokIn: Math.round(todays.reduce((a, s) => a + (s.kTokIn || 0), 0) * 10) / 10,
    kTokOut: Math.round(todays.reduce((a, s) => a + (s.kTokOut || 0), 0) * 10) / 10,
  };
}

// ─────────────────────────── memory graph ───────────────────────────

function parseMemoryFile() {
  const entities = [];
  let relationCount = 0;
  try {
    const lines = fs.readFileSync(MEMORY_FILE, 'utf8').split('\n');
    for (const line of lines) {
      if (!line.trim()) continue;
      let obj;
      try { obj = JSON.parse(line); } catch { continue; }
      if (obj.type === 'entity') entities.push({ name: obj.name, entityType: obj.entityType, observations: obj.observations || [] });
      else if (obj.type === 'relation') relationCount++;
    }
  } catch { /* missing/unreadable */ }
  return { entities, relationCount };
}

function monitorDue(entities) {
  const mon = entities.find(e => e.name === 'halo-monitor-state');
  const obs = mon?.observations?.find(o => /^Last scan:/i.test(o));
  const m = obs && obs.match(/Last scan:\s*(\d{4}-\d{2}-\d{2})/);
  if (!m) return { lastScanDate: null, dueDate: null, dueInDays: null };
  const last = new Date(m[1] + 'T00:00:00');
  const due = new Date(last.getTime() + 7 * 86400000);
  const dueInDays = Math.round((due.getTime() - Date.now()) / 86400000);
  return { lastScanDate: m[1], dueDate: due.toISOString().slice(0, 10), dueInDays };
}

// entryIds patched at the *top level* of cordis.patch.yml (column-0 "- id:"
// lines only — nested ones under "- insert:" blocks are not machine-level
// overrides in the same sense) get a "HALO override" badge in the plugins tab.
function cordisOverrideIds() {
  const ids = new Set();
  try {
    const text = fs.readFileSync(CORDIS_PATCH, 'utf8');
    for (const m of text.matchAll(/^- id:\s*(\S+)/gm)) ids.add(m[1]);
  } catch { /* missing/unreadable */ }
  return ids;
}

// ─────────────────────────── plugin descriptions ───────────────────────────

// Small number of module ids that live outside the @deepseek-ai scope (built
// into cordis core rather than published as a dsh package). Verified by hand
// against the operator's own knowledge of the composition system — do NOT add
// entries here on a guess; unresolved ids fall through to "—".
const CORDIS_CORE_DESCRIPTIONS = {
  'cordis:include': 'Composition include: mounts a config subtree',
};

// package.json descriptions are static on disk and read once per process —
// scanned at startup and cached forever (no TTL, no re-scan on request).
function buildPluginDescriptions() {
  const map = new Map();
  for (const dir of DEEPSEEK_PKG_DIRS) {
    try {
      for (const pkg of fs.readdirSync(dir)) {
        if (map.has(`@deepseek-ai/${pkg}`)) continue;
        try {
          const pj = JSON.parse(fs.readFileSync(path.join(dir, pkg, 'package.json'), 'utf8'));
          if (pj.description && pj.description.trim()) map.set(`@deepseek-ai/${pkg}`, pj.description.trim());
        } catch { /* unreadable/malformed package.json — skip */ }
      }
    } catch { /* that profile dir missing — fine */ }
  }
  return map;
}
const pluginDescriptions = buildPluginDescriptions();

// moduleName sometimes carries a subpath export, e.g.
// "@deepseek-ai/dsh-tool-subagent-control/list-agents" — strip it to resolve
// the package, then note the export as a suffix on the description.
function resolveModuleDescription(moduleName) {
  if (!moduleName) return null;
  if (moduleName.startsWith('@deepseek-ai/')) {
    const rest = moduleName.slice('@deepseek-ai/'.length);
    const slashIdx = rest.indexOf('/');
    const pkg = slashIdx >= 0 ? rest.slice(0, slashIdx) : rest;
    const subpath = slashIdx >= 0 ? rest.slice(slashIdx + 1) : null;
    const base = pluginDescriptions.get(`@deepseek-ai/${pkg}`);
    if (!base) return null;
    return subpath ? `${base} · export: ${subpath}` : base;
  }
  return CORDIS_CORE_DESCRIPTIONS[moduleName] || null;
}

// Last colon-delimited segment of the entryId — used to distinguish rows that
// share one module (e.g. the four tool-subagent instances: codex, claude-code,
// fork, opencode) once we already know the module is duplicated.
function entryInstanceSuffix(entryId) {
  const parts = String(entryId || '').split(':');
  return parts[parts.length - 1];
}

// ─────────────────────────── GPU / disk / ram ───────────────────────────

const gpuCache = { at: 0, dedicatedBytes: 0, sharedBytes: 0, ok: false };
async function gpuMemory() {
  if (Date.now() - gpuCache.at < 10000 && gpuCache.at) return gpuCache;
  try {
    const cmd = "(Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Usage','\\GPU Adapter Memory(*)\\Shared Usage').CounterSamples | ForEach-Object { '{0}|{1}|{2}' -f $_.Path, $_.InstanceName, $_.CookedValue }";
    const { stdout } = await execFileP('powershell.exe', ['-NoProfile', '-Command', cmd], { timeout: 8000 });
    let dedicated = 0, shared = 0;
    for (const line of stdout.split('\n')) {
      const parts = line.trim().split('|');
      if (parts.length !== 3) continue;
      const p = parts[0].toLowerCase();
      const val = parseFloat(parts[2]) || 0;
      if (p.includes('dedicated usage')) dedicated += val;
      else if (p.includes('shared usage')) shared += val;
    }
    gpuCache.dedicatedBytes = dedicated;
    gpuCache.sharedBytes = shared;
    gpuCache.ok = true;
    gpuCache.at = Date.now();
  } catch { gpuCache.ok = false; gpuCache.at = Date.now(); }
  return gpuCache;
}

const diskCache = { at: 0, usedBytes: 0, freeBytes: 0, ok: false };
async function diskUsage() {
  if (Date.now() - diskCache.at < 60000 && diskCache.at) return diskCache;
  try {
    const cmd = "$d=Get-PSDrive C; '{0}|{1}' -f $d.Used,$d.Free";
    const { stdout } = await execFileP('powershell.exe', ['-NoProfile', '-Command', cmd], { timeout: 8000 });
    const [used, free] = stdout.trim().split('|').map(Number);
    diskCache.usedBytes = used || 0;
    diskCache.freeBytes = free || 0;
    diskCache.ok = true;
    diskCache.at = Date.now();
  } catch { diskCache.ok = false; diskCache.at = Date.now(); }
  return diskCache;
}

// ─────────────────────────── local state (mc-state.json) ───────────────────────────

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); }
  catch { return { lastEngine: null, lastValidation: null }; }
}
function writeState(patch) {
  try {
    fs.mkdirSync(MC_DIR, { recursive: true });
    const cur = readState();
    fs.writeFileSync(STATE_FILE, JSON.stringify({ ...cur, ...patch }, null, 2));
  } catch { /* best effort */ }
}

// ─────────────────────────── history (mc-history.jsonl) ───────────────────────────

async function appendHistory() {
  try {
    const [gpu, sess] = await Promise.all([gpuMemory(), getSessions(await tcpCheck(3080), 50)]);
    const withStats = (sess.sessions || []).filter(s => s.decodeTps != null).sort((a, b) => b.mtime - a.mtime);
    const decodeTps = withStats.length ? withStats[0].decodeTps : null;
    const row = {
      t: Date.now(),
      decodeTps,
      winFreeGiB: gib(os.freemem()),
      gpuDedGiB: gib(gpu.dedicatedBytes),
      gpuSharedGiB: gib(gpu.sharedBytes),
    };
    fs.mkdirSync(MC_DIR, { recursive: true });
    fs.appendFileSync(HISTORY_FILE, JSON.stringify(row) + '\n');
    const lines = fs.readFileSync(HISTORY_FILE, 'utf8').split('\n').filter(Boolean);
    if (lines.length > 6000) fs.writeFileSync(HISTORY_FILE, lines.slice(-5000).join('\n') + '\n');
  } catch { /* best effort, never crash the poller */ }
}

function readHistorySpark(n = 40) {
  try {
    const lines = fs.readFileSync(HISTORY_FILE, 'utf8').split('\n').filter(Boolean).slice(-n);
    return lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
}

// ─────────────────────────── model catalog ───────────────────────────

async function catalog() {
  const [lsAll, psAll] = await Promise.all([lmsLs(), lmsPs()]);
  if (lsAll === null) return { error: true, catalog: [], totalGB: 0 };
  const loadedByKey = new Map((psAll || []).map(m => [m.modelKey, m]));
  const loadedByPath = new Map((psAll || []).map(m => [m.path, m]));
  const rows = lsAll.map(m => {
    const loaded = loadedByKey.get(m.modelKey) || loadedByPath.get(m.path) || null;
    return {
      modelKey: m.modelKey,
      displayName: m.displayName,
      publisher: m.publisher,
      path: m.path,
      architecture: m.architecture,
      paramsString: m.paramsString,
      quant: m.quantization?.name || '?',
      sizeGB: gb(m.sizeBytes),
      maxContextLength: m.maxContextLength || null,
      loaded: !!loaded,
      identifier: loaded?.identifier || null,
      status: loaded?.status || null,
      contextLength: loaded?.contextLength || null,
      ttlMs: loaded?.ttlMs ?? null,
      lastUsedTime: loaded?.lastUsedTime ?? null,
      queued: loaded?.queued ?? null,
      parallel: loaded?.parallel ?? null,
    };
  });
  // Any loaded model somehow missing from `ls` (shouldn't normally happen, but
  // don't silently drop it) gets appended flagged loaded-only.
  const seenKeys = new Set(rows.map(r => r.modelKey));
  for (const m of (psAll || [])) {
    if (seenKeys.has(m.modelKey)) continue;
    rows.push({
      modelKey: m.modelKey, displayName: m.displayName, publisher: m.publisher, path: m.path,
      architecture: m.architecture, paramsString: m.paramsString, quant: m.quantization?.name || '?',
      sizeGB: gb(m.sizeBytes), maxContextLength: m.maxContextLength || null, loaded: true,
      identifier: m.identifier, status: m.status, contextLength: m.contextLength, ttlMs: m.ttlMs,
      lastUsedTime: m.lastUsedTime, queued: m.queued, parallel: m.parallel, loadedOnly: true,
    });
  }
  rows.sort((a, b) => (b.loaded - a.loaded) || a.displayName.localeCompare(b.displayName));
  const totalGB = Math.round(lsAll.reduce((a, m) => a + (m.sizeBytes || 0), 0) / 1e9 * 10) / 10;
  return { error: false, catalog: rows, totalGB };
}

// ─────────────────────────── status() — the 5 s poll ───────────────────────────

async function status() {
  const [dshUp, lmUp, models, runtime, lmsVer, gpu, disk] = await Promise.all([
    tcpCheck(3080), tcpCheck(1234), lmsPs(), lmsRuntimeLs(), lmsVersionStr(), gpuMemory(), diskUsage(),
  ]);
  const sc = await getSessions(dshUp, 50);
  const slow = dshUp ? await slowPulls() : slowCache;
  const mem = parseMemoryFile();
  const due = monitorDue(mem.entities);
  const today = todayStats(sc.sessions || []);

  const engineStr = runtime?.selected ? `${runtime.selected.name}@${runtime.selected.version}` : null;
  const state = readState();
  let engineChanged = false;
  if (engineStr) {
    if (state.lastEngine == null) { writeState({ lastEngine: engineStr }); }
    else if (state.lastEngine !== engineStr) { engineChanged = true; writeState({ lastEngine: engineStr }); }
  }

  const winTotal = os.totalmem(), winFree = os.freemem();
  const carveoutBytes = Math.max(0, MACHINE_TOTAL_RAM - winTotal);

  return {
    time: new Date().toISOString(),
    node: process.version,
    services: {
      cockpit: dshUp,
      lmstudio: lmUp,
      lmsCli: models !== null,
      dshVersionPin: DSH_VERSION_PIN,
      lmsCliVersion: lmsVer,
      lmStudioVersion: lmStudioAppVersion(),
      engine: engineStr,
      engineChanged,
    },
    models: (models || []).map(m => ({
      identifier: m.identifier,
      modelKey: m.modelKey,
      quant: m.quantization?.name || '?',
      context: m.contextLength,
      status: m.status,
      queued: m.queued,
      gb: gb(m.sizeBytes),
    })),
    sessions: (sc.sessions || []).slice(0, 8),
    sessionsSource: sc.source,
    today,
    presets: dshUp ? slow.presets : null,
    plugins: dshUp ? slow.pluginSummary : null,
    jobs: {
      streamConnected: mux.connected,
      lastFrameAgeS: mux.lastFrameAt ? Math.round((Date.now() - mux.lastFrameAt) / 1000) : null,
      active: [...mux.jobs.entries()].flatMap(([sid, list]) => (list || []).map(j => ({
        session: sid.replace(/^session-/, '').slice(0, 8),
        id: j.jobId || j.id || '?', kind: j.kind || '', state: j.state || j.status || (j.running ? 'running' : ''),
      }))),
      queuedInputs: [...mux.queues.values()].reduce((a, b) => a + b, 0),
    },
    memory: { entities: mem.entities.length, tripwire: MEMORY_ENTITY_TRIPWIRE, ...due },
    // RAM/GPU pools in GiB (binary) — matches AMD Adrenalin's VGM split units.
    // Disk stays decimal GB below — drives are marketed in decimal.
    ram: { totalGiB: gib(winTotal), freeGiB: gib(winFree), usedGiB: gib(winTotal - winFree) },
    gpu: { ok: gpu.ok, dedicatedGiB: gib(gpu.dedicatedBytes), sharedGiB: gib(gpu.sharedBytes), carveoutGiB: gib(carveoutBytes) },
    disk: { ok: disk.ok, usedGB: gb(diskCache.usedBytes), freeGB: gb(diskCache.freeBytes), totalGB: gb(diskCache.usedBytes + diskCache.freeBytes) },
    machineTotalRamGiB: Math.round(MACHINE_TOTAL_RAM / 1073741824),
    validation: state.lastValidation || null,
    historySpark: readHistorySpark(40).map(h => h.decodeTps),
  };
}

// ─────────────────────────── actions ───────────────────────────

const ACTIONS = {
  'start-cockpit': () => spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', START_DSH], { detached: true, stdio: 'ignore' }).unref(),
  'load-q5': () => spawn('node', [LOADER_Q5], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'load-worker': () => spawn('node', [LOADER_WORKER], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'unload-worker': () => spawn('lms', ['unload', 'qwen3-coder-30b-a3b-instruct'], { detached: true, stdio: 'ignore', shell: true }).unref(),
  'unload-all': () => spawn('lms', ['unload', '--all'], { detached: true, stdio: 'ignore', shell: true }).unref(),
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', c => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

// ─────────────────────────── HTML shell ───────────────────────────

const PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>HALO Mission Control</title><style>
:root{--bg:#0b0f14;--panel:#101c2a;--line:#27405c;--ink:#eef6ff;--mut:#9fb3c8;--teal:#4fd8c4;--green:#5fe39a;--amber:#ffc86b;--red:#ff8080}
*{box-sizing:border-box}body{margin:0;background:linear-gradient(180deg,#080c11,#0c1420);color:var(--ink);font:15px/1.5 Segoe UI,Arial,sans-serif;padding:18px 24px 40px}
h1{font-size:1.3rem;margin:0 0 2px}.sub{color:var(--mut);font-size:.82rem;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
.card h2{font-size:.92rem;margin:0 0 10px;color:#dcecff}
.row{display:flex;justify-content:space-between;gap:10px;padding:5px 0;border-bottom:1px solid #1a2c42;font-size:.87rem}
.row:last-child{border:none}.k{color:var(--mut);text-align:right}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;flex:none}
.up{background:var(--green)}.down{background:var(--red)}.busy{background:var(--amber)}.wait{background:#5f8fd9}
button{background:#12344c;color:#cfe8ff;border:1px solid #3c6284;border-radius:8px;padding:6px 11px;margin:3px 6px 0 0;cursor:pointer;font-size:.82rem}
button:hover{background:#164058}button:disabled{opacity:.5;cursor:default}a{color:var(--teal);text-decoration:none}a:hover{text-decoration:underline}
.mut{color:var(--mut);font-size:.8rem}.mono{font-family:Consolas,monospace;font-size:.82rem}
input[type=text],input[type=number]{background:#0c1620;border:1px solid var(--line);color:var(--ink);border-radius:6px;padding:4px 7px;font-size:.82rem;width:90px}
#actionMsg{color:var(--amber);font-size:.83rem;min-height:1.2em;margin:4px 0 10px}
/* status strip */
.strip{display:flex;align-items:center;gap:16px;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 16px;margin-bottom:14px;flex-wrap:wrap}
.light-item{display:flex;align-items:center;gap:6px;cursor:pointer;padding:4px 8px;border-radius:8px}
.light-item:hover{background:#16283c}
.light{width:13px;height:13px;border-radius:50%;flex:none;box-shadow:0 0 6px 0 currentColor}
.light.g{background:var(--green);color:var(--green)}.light.a{background:var(--amber);color:var(--amber)}.light.r{background:var(--red);color:var(--red)}
.light-label{font-size:.78rem;color:var(--mut);letter-spacing:.03em}
.alarm{flex:1 1 260px;font-size:.85rem;color:var(--mut);text-align:right}
.alarm.bad{color:var(--amber)}
/* tabs */
.tabs{display:flex;gap:4px;margin-bottom:14px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.tabbtn{background:none;border:none;color:var(--mut);padding:8px 14px;font-size:.88rem;cursor:pointer;border-bottom:2px solid transparent;margin:0;border-radius:0}
.tabbtn:hover{background:none;color:var(--ink)}
.tabbtn.current{color:var(--ink);border-bottom-color:var(--teal)}
.tabpanel{display:none}.tabpanel.active{display:block}
/* tables */
table.tbl{width:100%;border-collapse:collapse;font-size:.85rem}
.tbl th{text-align:left;color:var(--mut);font-weight:600;font-size:.75rem;text-transform:uppercase;letter-spacing:.04em;padding:6px 8px;border-bottom:1px solid var(--line)}
.tbl td{padding:6px 8px;border-bottom:1px solid #1a2c42;vertical-align:top}
.tbl tr:hover td{background:#132234}
.tbl tr.clickable{cursor:pointer}
.badge{display:inline-block;padding:1px 7px;border-radius:6px;font-size:.7rem;margin-left:6px;white-space:nowrap}
.badge-amber{background:#3a2c12;color:var(--amber)}.badge-red{background:#3a1414;color:var(--red)}.badge-teal{background:#123a34;color:var(--teal)}.badge-mut{background:#182636;color:var(--mut)}
.bar{background:#1a2c42;border-radius:6px;height:9px;overflow:hidden;margin-top:3px}
.bar>i{display:block;height:100%;background:var(--teal)}
.bar.amber>i{background:var(--amber)}.bar.red>i{background:var(--red)}
.filterbar{display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
.filterbar input[type=text]{width:220px}
.detail{background:#0c1620;border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:4px 0 10px;font-size:.82rem}
.spark{display:block}
.tabsection{margin-bottom:22px}
</style></head><body>
<h1>HALO Mission Control</h1><div class="sub">Reads native state every 5 s &middot; holds only trend/cadence state &middot; <span id="stamp"></span></div>
<div id="strip" class="strip"></div>
<div id="actionMsg"></div>
<nav class="tabs">
<button class="tabbtn" data-tab="overview">Overview</button>
<button class="tabbtn" data-tab="models">Models</button>
<button class="tabbtn" data-tab="sessions">Sessions</button>
<button class="tabbtn" data-tab="plugins">Plugins</button>
<button class="tabbtn" data-tab="system">System</button>
</nav>

<div id="tab-overview" class="tabpanel">
<div class="grid">
<div class="card"><h2>Services</h2><div id="ov-services"></div>
<button onclick="act('start-cockpit')">Start cockpit</button>
<a href="http://127.0.0.1:3080" target="_blank"><button type="button">Open cockpit</button></a>
<div class="mut" id="ov-versions" style="margin-top:8px"></div></div>
<div class="card"><h2>Active now</h2><div id="ov-active"></div></div>
<div class="card"><h2>Memory pools</h2><div id="ov-pools"></div></div>
<div class="card"><h2>Cadence &amp; drift</h2><div id="ov-cadence"></div></div>
<div class="card"><h2>Today</h2><div id="ov-today"></div></div>
<div class="card"><h2>Throughput</h2><div id="ov-throughput"></div></div>
</div>
</div>

<div id="tab-models" class="tabpanel">
<div class="card">
<div class="filterbar">
<button onclick="act('load-q5')">Load Brain (Q5)</button>
<button onclick="act('load-worker')">Load Worker (MoE)</button>
<button onclick="act('unload-worker')">Unload Worker</button>
<button onclick="act('unload-all')">Unload All</button>
</div>
<div id="models-table"></div>
<div class="mut" id="models-footer" style="margin-top:8px"></div>
</div>
</div>

<div id="tab-sessions" class="tabpanel">
<div class="card">
<div class="filterbar">
<label class="mut"><input type="checkbox" id="showDriveRoot" onchange="loadSessions()"> show drive-root-bug rows</label>
<span class="mut" id="sessions-agg"></span>
</div>
<div id="sessions-table"></div>
</div>
</div>

<div id="tab-plugins" class="tabpanel">
<div class="card">
<div class="filterbar">
<input type="text" id="pluginFilter" placeholder="filter entryId / module / phase / description" oninput="renderPlugins()">
<span class="mut" id="plugins-summary"></span>
</div>
<div id="plugins-table"></div>
</div>
</div>

<div id="tab-system" class="tabpanel">
<div class="grid">
<div class="card"><h2>Memory</h2><div id="sys-memory"></div></div>
<div class="card"><h2>Disk C:</h2><div id="sys-disk"></div></div>
<div class="card"><h2>Versions</h2><div id="sys-versions"></div></div>
<div class="card"><h2>Config validation</h2>
<button onclick="validateConfig()">Validate config</button>
<div id="sys-validate"></div></div>
</div>
<div class="card tabsection" style="margin-top:14px"><h2>Memory graph <button style="float:right" onclick="loadMemoryGraph()">Refresh</button></h2><div id="sys-memgraph"></div></div>
<div class="card tabsection"><h2>Log tail <button style="float:right" onclick="loadLogtail()">Refresh</button></h2><div id="sys-logtail" class="mono"></div></div>
</div>

<script>
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function fmtK(n){return n==null?'&mdash;':(Math.round(n/1024*10)/10)+'K'}
function fmtRel(ms){
  if(!ms) return '&mdash;';
  var d=Date.now()-ms; if(d<0) d=0;
  var s=Math.round(d/1000);
  if(s<60) return s+'s ago';
  var m=Math.round(s/60); if(m<60) return m+'m ago';
  var h=Math.round(m/60); if(h<24) return h+'h ago';
  return Math.round(h/24)+'d ago';
}
function fmtTtl(ttlMs,lastUsedTime){
  if(ttlMs==null||lastUsedTime==null) return 'on disk';
  var remain=ttlMs-(Date.now()-lastUsedTime); if(remain<0) remain=0;
  var mm=Math.floor(remain/60000), ss=Math.floor((remain%60000)/1000);
  return mm+':'+(ss<10?'0':'')+ss;
}

var currentTab='overview';
var lastStatus=null;

function showTab(name){
  document.querySelectorAll('.tabpanel').forEach(function(p){p.classList.remove('active')});
  var el=document.getElementById('tab-'+name); if(el) el.classList.add('active');
  document.querySelectorAll('.tabbtn').forEach(function(b){b.classList.toggle('current', b.dataset.tab===name)});
  currentTab=name;
  onTabShown(name);
}
function onTabShown(name){
  if(name==='models') loadModels();
  if(name==='sessions') loadSessions();
  if(name==='plugins') loadPlugins();
  if(name==='system'){ loadMemoryGraph(); loadLogtail(); }
}
document.querySelectorAll('.tabbtn').forEach(function(b){b.addEventListener('click', function(){ location.hash='#'+b.dataset.tab })});
window.addEventListener('hashchange', function(){ showTab((location.hash||'#overview').slice(1) || 'overview') });
showTab((location.hash||'#overview').slice(1) || 'overview');

async function act(a){
  document.getElementById('actionMsg').textContent='running: '+a+'...';
  await fetch('/api/action/'+a,{method:'POST'});
  setTimeout(function(){document.getElementById('actionMsg').textContent='';refreshStatus();if(currentTab==='models')loadModels()},2500);
}

// Rows are addressed by index into modelsCache, never by interpolating raw
// path/modelKey strings into onclick attributes — avoids any quoting hazard.
var modelsCache=[];
async function loadModel(i){
  var row=modelsCache[i]; if(!row) return;
  var ctxInput=document.getElementById('loadctx-'+i);
  var ctx=ctxInput?parseInt(ctxInput.value,10):32768;
  if(!ctx||ctx<512) ctx=32768;
  document.getElementById('actionMsg').textContent='loading '+row.modelKey+' (ctx '+ctx+')...';
  await fetch('/api/action/load-model',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({path:row.path,modelKey:row.modelKey,ctx:ctx})});
  setTimeout(function(){document.getElementById('actionMsg').textContent='';loadModels();refreshStatus()},3000);
}
async function unloadModel(i){
  var row=modelsCache[i]; if(!row||!row.identifier) return;
  document.getElementById('actionMsg').textContent='unloading '+row.identifier+'...';
  await fetch('/api/action/unload-model',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({identifier:row.identifier})});
  setTimeout(function(){document.getElementById('actionMsg').textContent='';loadModels();refreshStatus()},2500);
}
function showLoadRow(i){
  var el=document.getElementById('loadrow-'+i);
  if(el) el.style.display=(el.style.display==='none'?'flex':'none');
}

// ── master status strip ──
function computeLights(s){
  var lights={};
  // HARNESS — failed fibers are always actionable (red); a stuck transition
  // (>60s on the same LOADING/UNLOADING/RELOADING phase) is also an alarm
  // (amber). Plain "waiting" (no dependency yet) and ordinary in-flight
  // transitions are BENIGN and never trip this light.
  if(!s.services.cockpit) lights.HARNESS={level:'r',cause:'cockpit :3080 is down'};
  else if(s.plugins&&s.plugins.failed>0) {
    lights.HARNESS={level:'r',cause:s.plugins.failed+' plugin(s) failed: '+(s.plugins.failedList||[]).join(', ')};
  } else if(s.plugins&&s.plugins.stuck>0) {
    lights.HARNESS={level:'a',cause:(s.plugins.stuckList||[]).join('; ')};
  } else if(s.presets&&s.presets.some(function(p){return p.broken})) {
    lights.HARNESS={level:'a',cause:'a preset is broken'};
  } else lights.HARNESS={level:'g',cause:null};
  // MODELS
  if(!s.services.lmsCli) lights.MODELS={level:'r',cause:'lms CLI failed'};
  else if(s.models.length===0) lights.MODELS={level:'a',cause:'zero models loaded'};
  else if(s.models.some(function(m){return m.context>=200000})) lights.MODELS={level:'a',cause:'a loaded model has context \u2265 200K (silent-huge-context trap)'};
  else lights.MODELS={level:'g',cause:null};
  // MEMORY
  if(s.ram.freeGiB<3) lights.MEMORY={level:'r',cause:'Windows free RAM '+s.ram.freeGiB+' GiB < 3 GiB'};
  else if(s.gpu.sharedGiB>8) lights.MEMORY={level:'a',cause:'GPU shared usage '+s.gpu.sharedGiB+' GiB > 8 GiB (model bytes leaking into Windows pool)'};
  else if(s.ram.freeGiB<6) lights.MEMORY={level:'a',cause:'Windows free RAM '+s.ram.freeGiB+' GiB < 6 GiB'};
  else lights.MEMORY={level:'g',cause:null};
  // DISK
  if(!s.disk.ok) lights.DISK={level:'a',cause:'disk read failed'};
  else if(s.disk.freeGB<50) lights.DISK={level:'r',cause:'disk free '+s.disk.freeGB+' GB < 50 GB'};
  else if(s.disk.freeGB<150) lights.DISK={level:'a',cause:'disk free '+s.disk.freeGB+' GB < 150 GB'};
  else lights.DISK={level:'g',cause:null};
  // STREAM
  lights.STREAM=s.jobs.streamConnected?{level:'g',cause:null}:{level:'a',cause:'events WebSocket disconnected'};
  return lights;
}
var lightTab={HARNESS:'overview',MODELS:'models',MEMORY:'system',DISK:'system',STREAM:'overview'};
function renderStrip(s){
  var lights=computeLights(s);
  var order=['HARNESS','MODELS','MEMORY','DISK','STREAM'];
  var worst=null, cause=null;
  order.forEach(function(name){
    var lv=lights[name].level;
    if(lv==='r'&&worst!=='r'){worst='r';cause=name+': '+lights[name].cause}
    else if(lv==='a'&&worst==null){worst='a';cause=name+': '+lights[name].cause}
    else if(lv==='a'&&worst==='a'&&!cause){cause=name+': '+lights[name].cause}
  });
  var html=order.map(function(name){
    var l=lights[name];
    return '<span class="light-item" onclick="location.hash=\\'#'+lightTab[name]+'\\'"><span class="light '+l.level+'"></span><span class="light-label">'+name+'</span></span>';
  }).join('');
  html+='<span class="alarm'+(worst?' bad':'')+'">'+(worst?esc(cause):'All systems nominal')+'</span>';
  document.getElementById('strip').innerHTML=html;
}

// ── overview ──
function renderOverview(s){
  var svcRows=[
    ['Cockpit (:3080)',s.services.cockpit],
    ['LM Studio API (:1234)',s.services.lmstudio],
    ['lms CLI',s.services.lmsCli],
  ];
  document.getElementById('ov-services').innerHTML=svcRows.map(function(r){
    return '<div class="row"><span><span class="dot '+(r[1]?'up':'down')+'"></span>'+r[0]+'</span><span class="k">'+(r[1]?'up':'down')+'</span></div>';
  }).join('');
  var vparts=['dsh pin '+esc(s.services.dshVersionPin)];
  vparts.push('LM Studio '+esc(s.services.lmStudioVersion||'unknown'));
  vparts.push('lms '+esc(s.services.lmsCliVersion||'unknown'));
  vparts.push('engine '+esc(s.services.engine||'unknown')+(s.services.engineChanged?' <span class="badge badge-teal">changed since last look</span>':''));
  vparts.push('node '+esc(s.node));
  document.getElementById('ov-versions').innerHTML=vparts.join(' &middot; ');

  var activeHtml='';
  var running=s.sessions.filter(function(x){return x.running});
  activeHtml+='<div class="row"><span class="k">running sessions</span><span>'+running.length+'</span></div>';
  activeHtml+=running.map(function(x){return '<div class="row"><span><span class="dot busy"></span>'+esc(x.title||x.id)+'</span><span class="k">'+esc(x.preset||'')+'</span></div>'}).join('');
  activeHtml+='<div class="row"><span class="k">active jobs</span><span>'+s.jobs.active.length+'</span></div>';
  activeHtml+='<div class="row"><span class="k">queued inputs</span><span>'+s.jobs.queuedInputs+'</span></div>';
  document.getElementById('ov-active').innerHTML=activeHtml;

  var winPct=Math.min(100,Math.round(s.ram.usedGiB/s.ram.totalGiB*100));
  var gpuPct=Math.min(100,Math.round(s.gpu.dedicatedGiB/s.gpu.carveoutGiB*100));
  var sharedBad=s.gpu.sharedGiB>8;
  document.getElementById('ov-pools').innerHTML=
    '<div class="row"><span class="k">Windows pool</span><span>'+s.ram.usedGiB+' / '+s.ram.totalGiB+' GiB</span></div>'+
    '<div class="bar"><i style="width:'+winPct+'%"></i></div>'+
    '<div class="row" style="margin-top:8px"><span class="k">GPU dedicated</span><span>'+s.gpu.dedicatedGiB+' / '+s.gpu.carveoutGiB+' GiB carveout</span></div>'+
    '<div class="bar"><i style="width:'+gpuPct+'%"></i></div>'+
    '<div class="row" style="margin-top:8px"><span class="k">GPU shared</span><span'+(sharedBad?' style="color:var(--amber)"':'')+'>'+s.gpu.sharedGiB+' GiB</span></div>'+
    '<div class="mut" style="margin-top:2px">should stay near 0 &mdash; model bytes belong in the carveout</div>';

  var due=s.memory;
  var dueTxt=due.dueDate?('due '+(due.dueInDays<0?('overdue '+Math.abs(due.dueInDays)+'d'):due.dueInDays+'d')):'no scan recorded';
  document.getElementById('ov-cadence').innerHTML=
    '<div class="row"><span class="k">last delta-scan</span><span>'+esc(due.lastScanDate||'—')+'</span></div>'+
    '<div class="row"><span class="k">next scan</span><span'+(due.dueInDays!=null&&due.dueInDays<0?' style="color:var(--amber)"':'')+'>'+esc(dueTxt)+'</span></div>'+
    '<div class="row"><span class="k">engine</span><span>'+esc(s.services.engine||'unknown')+(s.services.engineChanged?' <span class="badge badge-teal">changed</span>':'')+'</span></div>'+
    '<div class="row"><span class="k">last config validation</span><span>'+(s.validation?(s.validation.ok?'<span style="color:var(--green)">ok</span>':'<span style="color:var(--red)">issues</span>')+' &middot; '+new Date(s.validation.when).toLocaleString():'never run')+'</span></div>';

  document.getElementById('ov-today').innerHTML=
    '<div class="row"><span class="k">sessions touched today</span><span>'+s.today.count+'</span></div>'+
    '<div class="row"><span class="k">kTok in / out</span><span>'+s.today.kTokIn+'K / '+s.today.kTokOut+'K</span></div>';

  var withStats=s.sessions.filter(function(x){return x.decodeTps!=null}).sort(function(a,b){return b.mtime-a.mtime});
  var latest=withStats[0];
  var spark=sparkSvg(s.historySpark);
  document.getElementById('ov-throughput').innerHTML= latest?
    '<div class="row"><span class="k">decode t/s</span><span>'+latest.decodeTps+' <span class="mut">(baseline 26.9)</span></span></div>'+
    '<div class="row"><span class="k">TTFT</span><span>'+(latest.ttftS!=null?latest.ttftS+'s':'&mdash;')+' <span class="mut">(prefill baseline 181 t/s)</span></span></div>'+
    spark
    : '<div class="mut">no session with stats yet</div>'+spark;
}
function sparkSvg(vals){
  var pts=(vals||[]).filter(function(v){return v!=null});
  if(pts.length<2) return '';
  var w=220,h=36,max=Math.max.apply(null,pts),min=Math.min.apply(null,pts);
  var range=(max-min)||1;
  var step=w/(pts.length-1);
  var d=pts.map(function(v,i){var x=i*step,y=h-((v-min)/range)*h; return (i===0?'M':'L')+x.toFixed(1)+','+y.toFixed(1)}).join(' ');
  return '<svg class="spark" width="'+w+'" height="'+h+'" viewBox="0 0 '+w+' '+h+'"><path d="'+d+'" fill="none" stroke="var(--teal)" stroke-width="1.5"/></svg>';
}

// ── models tab ──
async function loadModels(){
  try{
    var c=await (await fetch('/api/catalog')).json();
    if(c.error){ document.getElementById('models-table').innerHTML='<div class="mut">lms CLI down &mdash; no catalog</div>'; return }
    modelsCache=c.catalog;
    var rows=c.catalog.map(function(m,i){
      var ctxBadge=(m.loaded&&m.contextLength>=200000)?' <span class="badge badge-amber">ctx ≥ 200K</span>':'';
      var stateCell=m.loaded?('<span class="dot up"></span>'+esc(m.status||'loaded')+' &middot; '+fmtK(m.contextLength)+' &middot; TTL '+fmtTtl(m.ttlMs,m.lastUsedTime)):'<span class="mut">on disk</span>';
      var actionCell=m.loaded?
        '<button onclick="unloadModel('+i+')">Unload</button>'
        : ('<button onclick="showLoadRow('+i+')">Load</button>'+
           '<span id="loadrow-'+i+'" style="display:none;gap:4px;align-items:center;margin-top:4px">'+
           '<input type="number" id="loadctx-'+i+'" value="32768">'+
           '<button onclick="loadModel('+i+')">Confirm</button></span>');
      return '<tr>'+
        '<td>'+esc(m.displayName)+ctxBadge+'<br><span class="mono mut">'+esc(m.modelKey)+'</span></td>'+
        '<td>'+esc(m.architecture||'?')+' / '+esc(m.paramsString||'?')+'</td>'+
        '<td>'+esc(m.quant)+'</td>'+
        '<td>'+m.sizeGB+' GB</td>'+
        '<td>'+fmtK(m.maxContextLength)+'</td>'+
        '<td>'+stateCell+'</td>'+
        '<td>'+actionCell+'</td>'+
        '</tr>';
    }).join('');
    document.getElementById('models-table').innerHTML='<table class="tbl"><thead><tr><th>Model</th><th>Arch/Params</th><th>Quant</th><th>Size</th><th>Max ctx</th><th>State</th><th>Actions</th></tr></thead><tbody>'+rows+'</tbody></table>';
    document.getElementById('models-footer').textContent='catalog: '+c.totalGB+' GB total \\u00b7 engine: '+(lastStatus&&lastStatus.services.engine||'unknown');
  }catch(e){ document.getElementById('models-table').innerHTML='<div class="mut">catalog fetch failed</div>' }
}

// ── sessions tab ──
var openSession=null;
async function loadSessions(){
  try{
    var showBug=document.getElementById('showDriveRoot').checked;
    var r=await (await fetch('/api/sessions?all=1')).json();
    document.getElementById('sessions-agg').textContent='('+esc(r.source)+') sessions today: '+r.today.count+' \\u00b7 kTok in/out today: '+r.today.kTokIn+'K/'+r.today.kTokOut+'K';
    var list=r.sessions.filter(function(s){return showBug||!s.driveRootBug});
    var rows=list.map(function(s,i){
      var bug=s.driveRootBug?' <span class="badge badge-red">drive-root bug</span>':'';
      var main='<tr class="clickable" onclick="toggleSessionDetail('+i+')">'+
        '<td>'+esc(s.title||s.id)+bug+(s.goal?'<br><span class="mut">'+esc(s.goal.slice(0,80))+'</span>':'')+'</td>'+
        '<td>'+esc(s.workspace)+'</td>'+
        '<td>'+esc(s.preset||'—')+'</td>'+
        '<td><span class="dot '+(s.running?'busy':'up')+'"></span>'+(s.running?'running':'idle')+'</td>'+
        '<td>'+(s.turns!=null?s.turns:'&mdash;')+'</td>'+
        '<td>'+(s.kTokIn!=null?s.kTokIn+'K':'&mdash;')+'</td>'+
        '<td>'+(s.kTokOut!=null?s.kTokOut+'K':'&mdash;')+'</td>'+
        '<td>'+(s.ttftS!=null?s.ttftS+'s':'&mdash;')+'</td>'+
        '<td>'+(s.decodeTps!=null?s.decodeTps:'&mdash;')+'</td>'+
        '<td>'+fmtRel(s.mtime)+'</td>'+
        '</tr>';
      var detail='<tr id="sdetail-'+i+'" style="display:none"><td colspan="10"><div class="detail">'+
        '<div>sessionId: <span class="mono">'+esc(s.sessionId)+'</span></div>'+
        (s.goal?'<div>goal: '+esc(s.goal)+'</div>':'')+
        '<div><a href="http://127.0.0.1:3080" target="_blank">Open in cockpit</a></div>'+
        '</div></td></tr>';
      return main+detail;
    }).join('');
    document.getElementById('sessions-table').innerHTML='<table class="tbl"><thead><tr><th>Title</th><th>Workspace</th><th>Preset</th><th>State</th><th>Turns</th><th>kTok in</th><th>kTok out</th><th>TTFT</th><th>Decode t/s</th><th>Updated</th></tr></thead><tbody>'+rows+'</tbody></table>';
  }catch(e){ document.getElementById('sessions-table').innerHTML='<div class="mut">sessions fetch failed</div>' }
}
function toggleSessionDetail(i){
  var el=document.getElementById('sdetail-'+i);
  if(el) el.style.display=(el.style.display==='none'?'table-row':'none');
}

// ── plugins tab ──
var pluginsData=null;
async function loadPlugins(){
  try{
    pluginsData=await (await fetch('/api/plugins')).json();
    renderPlugins();
  }catch(e){ document.getElementById('plugins-table').innerHTML='<div class="mut">plugins fetch failed</div>' }
}
function renderPlugins(){
  if(!pluginsData){ document.getElementById('plugins-table').innerHTML='<div class="mut">loading&hellip;</div>'; return }
  if(pluginsData.error){ document.getElementById('plugins-table').innerHTML='<div class="mut">dsh down &mdash; no inventory</div>'; return }
  var filter=(document.getElementById('pluginFilter').value||'').toLowerCase();
  var rows=pluginsData.entries.filter(function(e){
    if(!filter) return true;
    return (e.entryId||'').toLowerCase().indexOf(filter)>=0 || (e.moduleName||'').toLowerCase().indexOf(filter)>=0 || (e.fiberPhase||'').toLowerCase().indexOf(filter)>=0 || (e.description||'').toLowerCase().indexOf(filter)>=0;
  });
  var sm=pluginsData.summary;
  var sumParts=[sm.active+' active', sm.disabled+' disabled'];
  if(sm.waiting>0) sumParts.push(sm.waiting+' waiting');
  if(sm.transitioning>0) sumParts.push(sm.transitioning+' transitioning');
  if(sm.failed>0) sumParts.push(sm.failed+' failed');
  if(sm.stuck>0) sumParts.push(sm.stuck+' stuck');
  sumParts.push(sm.total+' total');
  document.getElementById('plugins-summary').textContent=sumParts.join(' \\u00b7 ');
  var html=rows.map(function(e){
    var state, stateColor='', tip='';
    if(e.bucket==='failed'){ state='<span class="dot down"></span>failed'; stateColor=' style="color:var(--red)"'; }
    else if(e.bucket==='transitioning'){
      state='<span class="dot busy"></span>'+(e.stuck?'stuck '+esc((e.fiberPhase||'').toUpperCase()):esc(e.fiberPhase||'transitioning'));
      stateColor=' style="color:var(--amber)"';
    }
    else if(e.bucket==='waiting'){
      state='<span class="dot wait"></span>waiting';
      stateColor=' style="color:#7fa8d9"';
      tip=' title="waiting on dependency \\u2014 will self-activate"';
    }
    else if(e.bucket==='active'){ state='<span class="dot up"></span>active'; }
    else { state='<span class="dot"></span>disabled'; stateColor=' style="color:var(--mut)"'; }
    return '<tr'+tip+'>'+
      '<td class="mono">'+esc(e.entryId)+(e.haloOverride?' <span class="badge badge-teal">HALO override</span>':'')+'</td>'+
      '<td'+stateColor+'>'+state+(e.bucket==='waiting'?' <span class="mut">(waiting on dependency &mdash; will self-activate)</span>':'')+'</td>'+
      '<td>'+esc(e.fiberPhase||'—')+'</td>'+
      '<td class="mono mut">'+esc(e.moduleName||'—')+'</td>'+
      '<td class="mut" style="max-width:360px;white-space:normal">'+esc(e.description||'—')+'</td>'+
      '</tr>';
  }).join('');
  document.getElementById('plugins-table').innerHTML='<table class="tbl"><thead><tr><th>entryId</th><th>state</th><th>fiberPhase</th><th>module</th><th>description</th></tr></thead><tbody>'+html+'</tbody></table>';
}

// ── system tab ──
function renderSystem(s){
  var winPct=Math.min(100,Math.round(s.ram.usedGiB/s.ram.totalGiB*100));
  var gpuPct=Math.min(100,Math.round(s.gpu.dedicatedGiB/s.gpu.carveoutGiB*100));
  var sharedCls=s.gpu.sharedGiB>8?'amber':'';
  document.getElementById('sys-memory').innerHTML=
    '<div class="row"><span class="k">Windows pool</span><span>'+s.ram.usedGiB+' / '+s.ram.totalGiB+' GiB</span></div><div class="bar"><i style="width:'+winPct+'%"></i></div>'+
    '<div class="row" style="margin-top:10px"><span class="k">GPU carveout</span><span>'+s.gpu.dedicatedGiB+' / '+s.gpu.carveoutGiB+' GiB</span></div><div class="bar"><i style="width:'+gpuPct+'%"></i></div>'+
    '<div class="row" style="margin-top:10px"><span class="k">GPU shared</span><span'+(sharedCls?' style="color:var(--amber)"':'')+'>'+s.gpu.sharedGiB+' GiB</span></div><div class="bar '+sharedCls+'"><i style="width:'+Math.min(100,s.gpu.sharedGiB/8*100)+'%"></i></div>'+
    '<div class="mut" style="margin-top:6px">machine total: '+s.machineTotalRamGiB+' GiB unified</div>';
  var diskPct=s.disk.ok?Math.round(s.disk.usedGB/s.disk.totalGB*100):0;
  var diskCls=!s.disk.ok?'':(s.disk.freeGB<50?'red':(s.disk.freeGB<150?'amber':''));
  document.getElementById('sys-disk').innerHTML=s.disk.ok?
    ('<div class="row"><span class="k">used / free / total</span><span>'+s.disk.usedGB+' / '+s.disk.freeGB+' / '+s.disk.totalGB+' GB</span></div><div class="bar '+diskCls+'"><i style="width:'+diskPct+'%"></i></div>')
    : '<div class="mut">disk read failed</div>';
  var vv='<div class="row"><span class="k">dsh pin</span><span class="mono">'+esc(s.services.dshVersionPin)+'</span></div>'+
    '<div class="row"><span class="k">LM Studio</span><span>'+esc(s.services.lmStudioVersion||'unknown')+'</span></div>'+
    '<div class="row"><span class="k">lms CLI</span><span>'+esc(s.services.lmsCliVersion||'unknown')+'</span></div>'+
    '<div class="row"><span class="k">engine (selected)</span><span>'+esc(s.services.engine||'unknown')+(s.services.engineChanged?' <span class="badge badge-teal">changed</span>':'')+'</span></div>'+
    '<div class="row"><span class="k">node</span><span>'+esc(s.node)+'</span></div>';
  document.getElementById('sys-versions').innerHTML=vv;
  var val=s.validation;
  document.getElementById('sys-validate').innerHTML=val?
    ('<div class="row"><span class="k">last run</span><span>'+new Date(val.when).toLocaleString()+'</span></div>'+
     '<div class="row"><span class="k">result</span><span'+(val.ok?' style="color:var(--green)"':' style="color:var(--red)"')+'>'+(val.ok?'ok':'issues found')+'</span></div>'+
     (val.warnings&&val.warnings.length?'<div class="mut" style="margin-top:6px">'+val.warnings.map(esc).join('<br>')+'</div>':''))
    : '<div class="mut">never run</div>';
}
async function validateConfig(){
  document.getElementById('sys-validate').innerHTML='<div class="mut">running &mdash; this dumps the full config, can take up to 2 minutes&hellip;</div>';
  try{
    var r=await (await fetch('/api/validate-config',{method:'POST'})).json();
    renderSystem(lastStatus||{services:{},ram:{},gpu:{},disk:{}});
    document.getElementById('sys-validate').innerHTML=
      '<div class="row"><span class="k">last run</span><span>'+new Date(r.when).toLocaleString()+'</span></div>'+
      '<div class="row"><span class="k">result</span><span'+(r.ok?' style="color:var(--green)"':' style="color:var(--red)"')+'>'+(r.ok?'ok':'issues found')+'</span></div>'+
      (r.warnings&&r.warnings.length?'<div class="mut" style="margin-top:6px">'+r.warnings.map(esc).join('<br>')+'</div>':'');
    refreshStatus();
  }catch(e){ document.getElementById('sys-validate').innerHTML='<div class="mut">validation request failed</div>' }
}
async function loadMemoryGraph(){
  try{
    var g=await (await fetch('/api/memory-graph')).json();
    var html='<div class="mut" style="margin-bottom:8px">'+g.entities.length+'/'+g.tripwire+' entities (upgrade tripwire) \\u00b7 '+g.relationCount+' relations</div>';
    html+=g.entities.map(function(e,i){
      return '<div class="row clickable" onclick="toggleObs('+i+')"><span>'+esc(e.name)+' <span class="mut">['+esc(e.entityType)+']</span></span><span class="k">'+e.observations.length+' obs</span></div>'+
        '<div id="obs-'+i+'" class="detail" style="display:none">'+e.observations.map(function(o){return '<div style="margin-bottom:4px">'+esc(o)+'</div>'}).join('')+'</div>';
    }).join('');
    document.getElementById('sys-memgraph').innerHTML=html;
  }catch(e){ document.getElementById('sys-memgraph').innerHTML='<div class="mut">memory graph read failed</div>' }
}
function toggleObs(i){ var el=document.getElementById('obs-'+i); if(el) el.style.display=(el.style.display==='none'?'block':'none') }
async function loadLogtail(){
  try{
    var r=await (await fetch('/api/logtail')).json();
    if(r.error){ document.getElementById('sys-logtail').innerHTML='<div class="mut">no LM Studio log file found</div>'; return }
    document.getElementById('sys-logtail').innerHTML='<div class="mut" style="margin-bottom:6px">'+esc(r.file)+'</div><pre style="white-space:pre-wrap;font-size:.78rem;max-height:400px;overflow:auto;margin:0">'+esc(r.lines.join('\\n'))+'</pre>';
  }catch(e){ document.getElementById('sys-logtail').innerHTML='<div class="mut">log tail failed</div>' }
}

// ── master poll ──
async function refreshStatus(){
  try{
    var s=await (await fetch('/api/status')).json();
    lastStatus=s;
    document.getElementById('stamp').textContent=new Date(s.time).toLocaleTimeString();
    renderStrip(s);
    if(currentTab==='overview') renderOverview(s);
    if(currentTab==='system') renderSystem(s);
  }catch(e){ document.getElementById('stamp').textContent='status fetch failed' }
}
refreshStatus();
setInterval(function(){
  refreshStatus();
  if(currentTab==='models') loadModels();
  if(currentTab==='sessions') loadSessions();
  if(currentTab==='plugins') loadPlugins();
},5000);
</script></body></html>`;

// ─────────────────────────── HTTP server ───────────────────────────

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/') {
      // no-store: the app ships inline in this file — a cached copy silently
      // runs stale UI against a newer server after every MC update.
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(PAGE); return;
    }
    if (req.method === 'GET' && url.pathname === '/api/status') {
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(await status())); return;
    }
    if (req.method === 'GET' && url.pathname === '/api/catalog') {
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(await catalog())); return;
    }
    if (req.method === 'GET' && url.pathname === '/api/plugins') {
      const dshUp = await tcpCheck(3080);
      if (!dshUp) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: true, entries: [], summary: null })); return; }
      const slow = await slowPulls();
      const overrides = cordisOverrideIds();
      const rawEntries = slow.pluginEntries || [];
      const moduleCounts = new Map();
      for (const e of rawEntries) moduleCounts.set(e.moduleName, (moduleCounts.get(e.moduleName) || 0) + 1);
      // Sort: failed (red) first, then stuck-transitioning, then ordinary
      // transitioning (both amber), then waiting (dimmed — benign), then
      // active, then disabled.
      const bucketRank = (b, stuck) => {
        if (b === 'failed') return 0;
        if (b === 'transitioning') return stuck ? 1 : 2;
        if (b === 'waiting') return 3;
        if (b === 'active') return 4;
        return 5; // disabled
      };
      const entries = rawEntries.map(e => {
        let description = resolveModuleDescription(e.moduleName);
        if (description && (moduleCounts.get(e.moduleName) || 0) > 1) {
          description += ` · instance: ${entryInstanceSuffix(e.entryId)}`;
        }
        const cls = slow.pluginById?.get(e.entryId) || { bucket: classifyPluginPhase(e.enabled, e.fiberPhase), stuck: false };
        return {
          entryId: e.entryId, moduleName: e.moduleName, enabled: e.enabled, fiberPhase: e.fiberPhase,
          bucket: cls.bucket, stuck: !!cls.stuck,
          haloOverride: overrides.has(e.entryId),
          description: description || '—',
        };
      }).sort((a, b) => bucketRank(a.bucket, a.stuck) - bucketRank(b.bucket, b.stuck) || a.entryId.localeCompare(b.entryId));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: false, entries, summary: slow.pluginSummary }));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/sessions') {
      const dshUp = await tcpCheck(3080);
      const sc = await getSessions(dshUp, 50);
      const today = todayStats(sc.sessions || []);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ sessions: sc.sessions, source: sc.source, today }));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/memory-graph') {
      const { entities, relationCount } = parseMemoryFile();
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ entities, relationCount, tripwire: MEMORY_ENTITY_TRIPWIRE }));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/logtail') {
      try {
        const months = fs.readdirSync(LMSTUDIO_LOGS).filter(d => /^\d{4}-\d{2}$/.test(d)).sort();
        if (!months.length) throw new Error('no month dirs');
        const monthDir = path.join(LMSTUDIO_LOGS, months[months.length - 1]);
        const files = fs.readdirSync(monthDir).filter(f => f.endsWith('.log')).sort();
        if (!files.length) throw new Error('no log files');
        const file = path.join(monthDir, files[files.length - 1]);
        const lines = fs.readFileSync(file, 'utf8').split('\n');
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: false, file, lines: lines.slice(-80) }));
      } catch {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: true, file: null, lines: [] }));
      }
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/validate-config') {
      let result;
      try {
        const { stdout, stderr } = await execFileP('npx', ['@deepseek-ai/dsh@' + DSH_VERSION_PIN, 'web', '--dump-config'], { shell: true, timeout: 120000, maxBuffer: 16 * 1024 * 1024 });
        const combined = `${stdout}\n${stderr}`;
        const warnings = combined.split('\n').filter(l => /unmatched|warn/i.test(l)).map(l => l.trim()).filter(Boolean).slice(0, 50);
        result = { when: Date.now(), ok: warnings.length === 0, warnings };
      } catch (e) {
        result = { when: Date.now(), ok: false, warnings: [String(e.message || e).slice(0, 500)] };
      }
      writeState({ lastValidation: result });
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(result)); return;
    }
    if (req.method === 'POST' && url.pathname === '/api/action/load-model') {
      let body;
      try { body = await readBody(req); } catch { res.writeHead(400); res.end('bad json'); return; }
      const { path: modelPath, modelKey, ctx } = body || {};
      if (!modelPath || !modelKey) { res.writeHead(400); res.end('path and modelKey required'); return; }
      const ctxN = Number.isFinite(ctx) && ctx > 0 ? Math.round(ctx) : 32768;
      spawn('lms', ['load', modelPath, '--identifier', modelKey, '--context-length', String(ctxN), '-y'], { detached: true, stdio: 'ignore', shell: true }).unref();
      res.writeHead(200); res.end('ok'); return;
    }
    if (req.method === 'POST' && url.pathname === '/api/action/unload-model') {
      let body;
      try { body = await readBody(req); } catch { res.writeHead(400); res.end('bad json'); return; }
      const { identifier } = body || {};
      if (!identifier) { res.writeHead(400); res.end('identifier required'); return; }
      spawn('lms', ['unload', identifier], { detached: true, stdio: 'ignore', shell: true }).unref();
      res.writeHead(200); res.end('ok'); return;
    }
    if (req.method === 'POST' && url.pathname.startsWith('/api/action/')) {
      const a = url.pathname.split('/').pop();
      if (ACTIONS[a]) { ACTIONS[a](); res.writeHead(200); res.end('ok'); return; }
      res.writeHead(404); res.end('unknown action'); return;
    }
    res.writeHead(404); res.end('not found');
  } catch (e) { res.writeHead(500); res.end(String(e)); }
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`Mission Control on http://127.0.0.1:${PORT}`);
  appendHistory();
  setInterval(appendHistory, 60000);
});
