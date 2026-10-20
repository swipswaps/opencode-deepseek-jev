// dashboard.mjs — thin read-only observability sidecar for the opencode
// SQLite database. Serves a single HTML page plus JSON endpoints:
//
//   GET /               dashboard (session header, cost + balance cards,
//                       per-session table, live activity, todos)
//   GET /api/cost       totals + per-session breakdown + live flag
//   GET /api/balance    DeepSeek balance (reads DEEPSEEK_API_KEY env)
//   GET /api/activity   recent step/tool/reasoning/text/patch parts
//   GET /api/todos      todos of the latest session
//
// Read-only: opens the database with readOnly:true per request. No writes.
// Binds 127.0.0.1 by default. No external dependencies (node:http,
// node:sqlite, node:fs only). Use scripts/dashboard.sh as the entry point
// (this file needs the --experimental-sqlite flag).
//
// Usage: node --experimental-sqlite dashboard.mjs <db-path> [port] [host]

import http from "node:http";
import { DatabaseSync } from "node:sqlite";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { healthReport, handoffAdvice, budgetRisks, applyLiveAdjudication, liveStatus } from "./session-health.mjs";
import { annotateReport, modelLedger } from "./quirks.mjs";
import { apiSignalsFresh as signalsFresh, apiPatternsFresh as patternsFresh, apiWordsFresh as wordsFresh, apiSemanticFresh as semanticFresh, apiTrendsFresh,
         apiSearchFresh as searchFresh, apiIntegrationsFresh as integrationsFresh, apiCostFresh as costFresh, apiActivityFresh as activityFresh,
         loadJsonCache, saveJsonCache } from "./query-lib.mjs";
import { redact } from "./redact.mjs";

const execFileP = promisify(execFile);

const dbPath = process.argv[2];
const port = Number(process.argv[3] || 5099);
const host = process.argv[4] || "127.0.0.1";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
let SERVED_REV = "";
try {
  SERVED_REV = execFileSync("git", ["-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
} catch {
  SERVED_REV = "";
}

const RUNBOOKS = JSON.parse(
  readFileSync(new URL("./runbooks.json", import.meta.url), "utf8")
);

const TOOLS = JSON.parse(
  readFileSync(new URL("./tools.json", import.meta.url), "utf8")
);

// Shared, consistent, sticky navigation across every served page. The CSV link
// is a download endpoint; docs renders the repo's own markdown/text in-UI so
// the rules and handoff are reachable without leaving the browser.
const NAV_CSS =
  ".nav{position:sticky;top:0;z-index:30;display:flex;gap:6px;flex-wrap:wrap;" +
  "align-items:center;background:#0d1117;border-bottom:1px solid #30363d;" +
  "padding:8px 0;margin:-20px 0 14px}" +
  ".nav .brand{font-weight:600;color:#e6edf3;margin-right:8px;font-size:13px}" +
  ".nav a{font-size:12px;padding:4px 10px;border-radius:6px;border:1px solid #30363d;" +
  "color:#8b949e;text-decoration:none}" +
  ".nav a:hover{border-color:#58a6ff;color:#58a6ff}" +
  ".nav a.active{background:#1f6feb;border-color:#1f6feb;color:#fff}";
const CMDK_CSS =
  "#cmdk{display:none;position:fixed;inset:0;z-index:100;background:rgba(1,4,9,0.7);" +
  "align-items:flex-start;justify-content:center;padding-top:12vh}" +
  "#cmdk.open{display:flex}" +
  "#cmdk-box{width:min(560px,92vw);background:#0d1117;border:1px solid #30363d;" +
  "border-radius:10px;overflow:hidden}" +
  "#cmdk-input{width:100%;box-sizing:border-box;background:#0d1117;color:#e6edf3;" +
  "border:0;border-bottom:1px solid #30363d;padding:12px 14px;font-size:14px}" +
  "#cmdk-list{max-height:300px;overflow:auto;padding:6px}" +
  ".cmdk-group{font-size:11px;color:#8b949e;padding:8px 10px 2px}" +
  ".cmdk-item{padding:8px 10px;border-radius:6px;font-size:13px;color:#e6edf3;cursor:pointer}" +
  ".cmdk-item .muted{font-size:11px}" +
  ".cmdk-item.active{background:#1f6feb33}" +
  ".cmdk-empty{padding:12px 10px;color:#8b949e;font-size:13px}";
const NAV_ITEMS = [["/", "dashboard"], ["/explore", "explore"], ["/models", "models"],
                   ["/runbooks", "runbooks"], ["/manage", "manage"], ["/docs", "docs"],
                   ["/api/export", "csv"]];

// Design tokens (DESIGN.md): one accent, 8px grid, Material elevation. Injected
// on every page via nav(); overrides page CSS on equal specificity because it
// comes later in document order (the <style> is in <body>).
const THEME_CSS =
  ":root{--bg:#0d1117;--surface:#161b22;--fg:#e6edf3;--muted:#8b949e;" +
  "--border:#30363d;--accent:#2ea043;--danger:#ff7b72;--radius:8px;" +
  "--pill:999px;--space:8px;--e1:0 1px 3px rgba(0,0,0,.35);--e2:0 4px 10px rgba(0,0,0,.45)}" +
  "html.light{--bg:#ffffff;--surface:#f6f8fa;--fg:#1f2328;--muted:#57606a;" +
  "--border:#d0d7de;--accent:#1f883d;--danger:#cf222e;" +
  "--e1:0 1px 2px rgba(0,0,0,.08);--e2:0 4px 10px rgba(0,0,0,.12)}" +
  "body{background:var(--bg);color:var(--fg)}" +
  ".card,.chart{background:var(--surface);border:1px solid var(--border);" +
  "border-radius:var(--radius);box-shadow:var(--e1)}" +
  ".card:hover,.chart:hover{box-shadow:var(--e2)}" +
  "h1{font-size:18px}h2{font-size:13px;letter-spacing:.02em}" +
  "th{color:var(--muted)}th,td{border-bottom:1px solid var(--border)}" +
  "input,select{background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:var(--radius)}" +
  "button{border-radius:var(--pill);min-height:24px;min-width:24px}" +
  ".tab,.tag,.badge{border-radius:var(--pill)}" +
  ".tab.active{background:var(--accent);border-color:var(--accent);color:var(--bg)}" +
  ".nav a.active{background:var(--accent);border-color:var(--accent);color:var(--bg)}" +
  ".stat{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--e1)}" +
  ".card{overflow-x:auto}" +
  ".skip-link{position:absolute;left:-9999px;top:8px;background:var(--accent);color:var(--bg);padding:8px 12px;border-radius:var(--radius);z-index:200;text-decoration:none;font-size:13px}" +
  ".skip-link:focus{left:8px}";

function nav(active) {
  let h = "<style>" + NAV_CSS + THEME_CSS + CMDK_CSS + "</style><a class=\"skip-link\" href=\"#main\">Skip to main content</a><nav class=\"nav\" aria-label=\"Primary\"><span class=\"brand\">opencode observability</span>";
  for (const it of NAV_ITEMS) {
    h += "<a href=\"" + it[0] + "\"" + (it[1] === active ? " class=\"active\" aria-current=\"page\"" : "") + ">" + it[1] + "</a>";
  }
  h += "<button id=\"theme\" class=\"tab\" title=\"toggle light/dark\" aria-label=\"toggle light or dark theme\" style=\"margin-left:auto\">&#9680; theme</button><span id=\"rev\" class=\"muted\" style=\"font-size:11px\"></span>";
  h += "</nav><script>fetch('/api/rev').then(function(r){return r.json();}).then(function(d){var e=document.getElementById('rev');if(!e)return;e.textContent=d.stale?('STALE served '+(d.served||'?')+' vs HEAD '+(d.head||'?')):('rev '+(d.served||'?'));if(d.stale)e.style.color='#ff7b72';}).catch(function(){});</script>";
  h += "<script>(function(){try{var de=document.documentElement;if(!de||!de.classList)return;var t=null;try{t=localStorage.getItem('theme');}catch(e){}var q=(location.search.match(/[?&]theme=(light|dark)/)||[])[1];if(q)t=q;if(t==='light')de.classList.add('light');var b=document.getElementById('theme');if(b){b.textContent=(de.classList.contains('light')?'\\u25D1 light':'\\u25D0 dark');b.addEventListener('click',function(){var on=de.classList.toggle('light');try{localStorage.setItem('theme',on?'light':'dark');}catch(e){}b.textContent=on?'\\u25D1 light':'\\u25D0 dark';});}}catch(e){}})();</script>";
  h += "<div id=\"cmdk\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Command palette\"><div id=\"cmdk-box\"><input id=\"cmdk-input\" placeholder=\"jump to a page or tab... (Esc closes)\" aria-label=\"Command palette\" autocomplete=\"off\"><div id=\"cmdk-list\" role=\"listbox\"></div></div></div>";
  h += "<script>(function(){if(typeof document==='undefined')return;";
  h += "var overlay=document.getElementById('cmdk');if(!overlay)return;";
  h += "var input=document.getElementById('cmdk-input');var list=document.getElementById('cmdk-list');";
  h += "if(!input||!list)return;";
  h += "var invoker=null,shown=[],sel=0;";
  h += "function items(){var it=[";
  h += "{label:'dashboard',hint:'home · stats · sessions',href:'/'},";
  h += "{label:'explore',hint:'sessions · charts · signals',href:'/explore'},";
  h += "{label:'models',hint:'catalog · policy',href:'/models'},";
  h += "{label:'runbooks',hint:'procedures · filter',href:'/runbooks'},";
  h += "{label:'manage',hint:'tools · agents',href:'/manage'},";
  h += "{label:'docs',hint:'guides · readme',href:'/docs'}];";
  h += "var tabs=[['overview','sessions table'],['charts','burn · scatter'],['signals','health · stalls'],['patterns','ngrams · pivot'],['code','files'],['data','dupes · ab'],['ocr','screenshots'],['ops','failures · gates']];";
  h += "for(var i=0;i<tabs.length;i++){it.push({label:'explore: '+tabs[i][0],hint:tabs[i][1],href:'/explore#'+tabs[i][0]});}";
  h += "if(document.getElementById('brush-reset')){it.push({label:'reset filter',hint:'clear brush selection',act:'reset'});}";
  h += "return it;}";
  h += "function render(q){q=(q||'').toLowerCase();shown=[];var all=items();";
  h += "var i,t,lbl,hnt;";
  h += "for(i=0;i<all.length;i++){lbl=all[i].label.toLowerCase();if(!q||lbl.indexOf(q)>=0)shown.push(all[i]);}";
  h += "for(i=0;i<all.length;i++){lbl=all[i].label.toLowerCase();hnt=(all[i].hint||'').toLowerCase();if(q&&lbl.indexOf(q)<0&&hnt.indexOf(q)>=0)shown.push(all[i]);}";
  h += "sel=0;var h='';var lastGroup='';";
  h += "for(var j=0;j<shown.length;j++){var it2=shown[j];var g=it2.href?'Navigation':'Actions';";
  h += "if(g!==lastGroup){h+='<div class=\"cmdk-group\">'+g+'</div>';lastGroup=g;}";
  h += "h+='<div class=\"cmdk-item'+(j===0?' active':'')+'\" role=\"option\" aria-selected=\"'+(j===0?'true':'false')+'\" data-idx=\"'+j+'\">'+it2.label+' <span class=\"muted\">'+it2.hint+'</span></div>';}";
  h += "if(!shown.length)h='<div class=\"cmdk-empty\">no matches</div>';";
  h += "list.innerHTML=h;}";
  h += "function mark(){var rows=list.querySelectorAll('.cmdk-item');for(var i=0;i<rows.length;i++){var on=i===sel;if(on){rows[i].classList.add('active');rows[i].setAttribute('aria-selected','true');}else{rows[i].classList.remove('active');rows[i].setAttribute('aria-selected','false');}}}";
  h += "function open(){invoker=document.activeElement;overlay.classList.add('open');input.value='';render('');if(input.focus)input.focus();}";
  h += "function close(){overlay.classList.remove('open');if(invoker&&invoker.focus)invoker.focus();}";
  h += "function go(){var it=shown[sel];if(!it)return;close();if(it.act==='reset'){var b=document.getElementById('brush-reset');if(b)b.click();return;}location.href=it.href;}";
  h += "document.addEventListener('keydown',function(ev){var k=(ev.key||'').toLowerCase();if((ev.ctrlKey||ev.metaKey)&&k==='k'){ev.preventDefault();if(overlay.classList.contains('open'))close();else open();}});";
  h += "input.addEventListener('input',function(){render(input.value);});";
  h += "input.addEventListener('keydown',function(ev){";
  h += "if(ev.key==='ArrowDown'){ev.preventDefault();sel=(sel+1)%Math.max(1,shown.length);mark();}";
  h += "else if(ev.key==='ArrowUp'){ev.preventDefault();sel=(sel-1+Math.max(1,shown.length))%Math.max(1,shown.length);mark();}";
  h += "else if(ev.key==='Enter'){ev.preventDefault();go();}";
  h += "else if(ev.key==='Escape'){ev.preventDefault();close();}});";
  h += "list.addEventListener('click',function(ev){var c=ev.target&&ev.target.closest?ev.target.closest('[data-idx]'):null;if(!c)return;sel=+c.getAttribute('data-idx');go();});";
  h += "overlay.addEventListener('click',function(ev){if(ev.target===overlay)close();});";
  h += "})();</script>";
  return h;
}

// Docs reachable from the UI. Whitelisted — never read arbitrary paths.
const DOC_FILES = ["HANDOFF.md", "RULES.md", "README.md", "scripts/README.txt", "HANDOFF-PROMPT.txt"];
function apiDoc(name) {
  if (!DOC_FILES.includes(name)) return null;
  try {
    return readFileSync(new URL("../" + name, import.meta.url), "utf8");
  } catch {
    return null;
  }
}

function apiModels() {
  try {
    return JSON.parse(readFileSync(new URL("../data/observability/models.json", import.meta.url), "utf8"));
  } catch {
    return { available: false, models: [] };
  }
}

function apiTools() {
  return TOOLS;
}

function apiProviders() {
  let cfg = {};
  try { cfg = JSON.parse(readFileSync(new URL("../opencode.json", import.meta.url), "utf8")); } catch { cfg = {}; }
  let policy = {};
  try { policy = JSON.parse(readFileSync(new URL("../models.policy.json", import.meta.url), "utf8")); } catch { policy = {}; }
  const providers = Object.entries(cfg.provider || {}).map((e) => {
    const id = e[0], p = e[1] || {};
    return { id, name: p.name || id, npm: p.npm || "(models.dev)", env: p.env || [], models: Object.keys(p.models || {}) };
  });
  return { default_model: cfg.model || null, providers, allow: policy.allow || [], deny: policy.deny || [] };
}

function apiCode(limit) {
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/code.db", import.meta.url)), { readOnly: true });
    const files = db.prepare("SELECT path, ext, bytes, lines, symbols, flags_n FROM code ORDER BY flags_n DESC, bytes DESC LIMIT ?").all(limit || 200);
    const flags = db.prepare("SELECT name, COUNT(*) n FROM code_flag GROUP BY name ORDER BY n DESC").all();
    db.close();
    return { available: true, files, flags };
  } catch {
    return { available: false, files: [], flags: [] };
  }
}

let revCache = { at: 0, data: null };
function apiRev() {
  if (revCache.data && Date.now() - revCache.at < 10000) return revCache.data;
  let head = "";
  try {
    head = execFileSync("git", ["-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
  } catch {
    head = "";
  }
  const data = { served: SERVED_REV, head, stale: !!(head && SERVED_REV && head !== SERVED_REV) };
  revCache = { at: Date.now(), data };
  return data;
}

async function apiExportPatterns() {
  const p = await apiPatterns(500);
  let body = "kind,key,n\n";
  for (const g of p.ngrams) body += '"bigram","' + String(g.gram).replace(/"/g, '""') + '",' + g.n + "\n";
  for (const e of p.errorTools) body += '"error_tool","' + String(e.tool).replace(/"/g, '""') + '",' + e.n + "\n";
  return redact(body);
}

function apiExportGuard() {
  const g = apiGuard(5000);
  let body = "ts,verdict,patterns,command\n";
  for (const a of g.actions) {
    body += '"' + String(a.ts || "") + '","' + String(a.verdict || "") + '","' +
      String((a.patterns || []).join(" ")).replace(/"/g, '""') + '","' +
      String(a.command || "").replace(/"/g, '""').replace(/\s+/g, " ") + '"\n';
  }
  return redact(body);
}

function apiSolutions() {
  try {
    return JSON.parse(readFileSync(new URL("../data/observability/solutions.json", import.meta.url), "utf8"));
  } catch {
    return { available: false, issues: [] };
  }
}

if (!dbPath) {
  console.error("usage: node dashboard.mjs <db-path> [port] [host]");
  process.exit(2);
}

// Module-level read-only handle for the opencode.db read path (query()).
// WAL mode permits concurrent readers without blocking writers; one handle
// removes per-call open/close churn across query()'s call sites. SQLite WAL:
// https://www.sqlite.org/wal.html. Never written — the DB stays
// read-only for the whole session. Observability/code.db call sites keep
// their own handles (untouched).
const READ_DB = new DatabaseSync(dbPath, { readOnly: true });
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    try {
      READ_DB.close();
    } catch {}
    process.exit(0);
  });
}
function query(sql, ...args) {
  return READ_DB.prepare(sql).all(...args);
}

// Poll-endpoint TTL: the home page refreshes cost/activity/todos every
// 2 s. Uncached, apiCost (~24 correlated scans) and apiActivity (full
// part-table sort) recompute on every tick and saturate the
// single-threaded loop. 10 s staleness is invisible on glanceable panels.
const POLL_TTL_MS = Number(process.env.POLL_TTL_MS || 10000);
async function apiTrends() {
  // Time-series the dashboard lacked (cost/sessions per day) from the session
  // table. Off the event loop: a cold miss runs in query-worker via the shared
  // query-lib body (apiTrendsFresh); the inline fallback keeps the same shape.
  // The sentinel flagged a 10.7 s GET /api/trends under a capture burst — a
  // sync cold compute queued behind other work, so this is the #72 fix.
  return asyncCached("trends", CACHE_TTL_MS, "trends", [], () => apiTrendsFresh(dbPath));
}
async function apiCost() {
  // Polling endpoint (home every 2 s): compute in the worker so a TTL expiry
  // cannot block the loop. Same payload, same 10 s TTL.
  return asyncCached("cost", POLL_TTL_MS, "cost", [], () => costFresh(dbPath));
}

let budgetCache = { at: 0, usd: null };
function budgetUsd() {
  if (budgetCache.usd != null && Date.now() - budgetCache.at < 60000) return budgetCache.usd;
  let usd = 5.0;
  try {
    const yml = readFileSync(new URL("../docker/litellm.config.yaml", import.meta.url), "utf8");
    const m = yml.match(/max_budget:\s*([0-9.]+)/);
    if (m) usd = Number(m[1]);
  } catch {}
  budgetCache = { at: Date.now(), usd };
  return usd;
}

// apiOverview/apiSchema are cached (measured uncached 0.13-1.06s / 0.31-1.38s);
// apiCode is deliberately NOT cached (measured 12-29ms — caching would be
// cargo-cult). The overview key includes the request param, so limit=5 and
// limit=200 never share an entry.
function apiOverview(limit, offset) {
  const key = "overview:" + (Number(limit) || 500) + ":" + (Number(offset) || 0);
  return ttlCached(key, CACHE_TTL_MS, () => apiOverviewFresh(limit, offset));
}
function apiOverviewFresh(limit, offset) {
  return { budget: budgetUsd(), sessions: apiSessions(limit, offset) };
}

function apiSchema() {
  return ttlCached("schema", CACHE_TTL_MS, apiSchemaFresh);
}
function apiSchemaFresh() {
  const tnames = query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
  const tables = [];
  for (const t of tnames) {
    const n = query('SELECT COUNT(*) c FROM "' + t.name + '"')[0].c;
    const cols = query('PRAGMA table_info("' + t.name + '")');
    tables.push({ name: t.name, rows: n, cols: cols.map((c) => c.name) });
  }
  const edges = query(
    "SELECT m.name AS src, fk.\"table\" AS dst, fk.\"from\" AS col " +
    "FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk " +
    "WHERE m.type='table' AND fk.\"table\" IS NOT NULL"
  );
  return { tables, edges };
}

async function apiIntegrations() {
  // Measured 8.6 s on the live store (json_extract over every part). Static
  // enough for 60 s; run it in the worker so the loop never pays for it.
  return asyncCached("integrations", 60000, "integrations", [], () => integrationsFresh(dbPath));
}

function apiAb(limit) {
  let rows = [];
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)), { readOnly: true });
    const cols = "ts, model, jev_status, jev_latency, jev_ok, laya_status, laya_latency, laya_ok, same, jev_correctness, jev_safe, jev_confidence, laya_correctness, laya_safe, laya_confidence, jev_model, laya_model";
    try {
      rows = db.prepare("SELECT " + cols + " FROM ab_run ORDER BY id DESC LIMIT ?").all(limit);
    } catch {
      rows = db.prepare("SELECT ts, model, jev_status, jev_latency, jev_ok, laya_status, laya_latency, laya_ok, same FROM ab_run ORDER BY id DESC LIMIT ?").all(limit);
    }
    db.close();
  } catch {
    rows = [];
  }
  const n = rows.length;
  const avg = (k) => (n ? rows.reduce((a, r) => a + (Number(r[k]) || 0), 0) / n : 0);
  const avgScore = (k) => {
    const vals = rows.map((r) => r[k]).filter((v) => v != null).map((v) => Number(v)).filter((v) => !isNaN(v));
    return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
  };
  return {
    runs: rows,
    summary: {
      n,
      jevOk: rows.filter((r) => r.jev_ok).length,
      layaOk: rows.filter((r) => r.laya_ok).length,
      same: rows.filter((r) => r.same === 1).length,
      differ: rows.filter((r) => r.same === 0).length,
      jevLatency: avg("jev_latency"),
      layaLatency: avg("laya_latency"),
      jevCorrectness: avgScore("jev_correctness"),
      layaCorrectness: avgScore("laya_correctness"),
      comparable: rows.filter((r) => Number(r.jev_correctness) != null || Number(r.laya_correctness) != null).length,
    },
  };
}

function ocrRows(limit) {
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)), { readOnly: true });
    const rows = db.prepare("SELECT id, ts, image, engine, lang, text FROM ocr_run ORDER BY id DESC LIMIT ?").all(limit || 2000);
    db.close();
    return rows;
  } catch {
    return [];
  }
}

function apiOcr(limit) {
  const runs = ocrRows(limit || 100);
  return {
    count: runs.length,
    runs: runs.map((r) => ({ id: r.id, ts: r.ts, image: r.image, engine: r.engine, lang: r.lang, snippet: String(r.text || "").slice(0, 240), text: r.text })),
  };
}

function apiDuplicates() {
  const rows = query("SELECT id, title, cost, tokens_input, time_created FROM session ORDER BY time_created DESC");
  const groups = new Map();
  for (const r of rows) {
    const key = String(r.title || "").toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
    if (!key) continue;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  const out = [];
  for (const [key, list] of groups) {
    if (list.length > 1) {
      out.push({ title: list[0].title, key, count: list.length, cost: list.reduce((a, r) => a + (Number(r.cost) || 0), 0), ids: list.map((r) => r.id) });
    }
  }
  out.sort((a, b) => b.count - a.count);
  return out.slice(0, 30);
}

// Generic TTL wrapper for heavy read-only endpoints (same pattern as
// apiHealth's cache): first call computes, repeats within ttlMs serve from
// memory with cached/age_ms observability. DB is never written.
// Derived-data caching in the sense of Kleppmann, Designing Data-Intensive
// Applications (O'Reilly, 2017, ISBN 978-1449373320), ch. 11: the served
// payloads are materialized views over the opencode.db log, refreshed on a
// TTL because recomputation is cheaper than invalidation here (small DB,
// idempotent aggregations, staleness measured in seconds is acceptable).
//
// Stale-while-revalidate, RFC 5861 (https://httpwg.org/specs/rfc5861.html):
// serve the stale payload immediately with a freshness warning (here the
// stale:true flag + age_ms), refresh once in the background. Singleflight
// deduplication follows Go's x/sync (https://pkg.go.dev/golang.org/x/sync/singleflight):
// concurrent misses share one in-flight recompute instead of stampeding.
// Why it matters here: the aggregations below are synchronous and
// multi-second, and this process is single-threaded — a recompute on the
// request path blocks EVERY other request (measured: cold /api/health
// ~10 s, /api/signals ~5 s, /api/words ~4.7 s). Past the TTL we therefore
// serve the stale payload immediately (stale:true) and recompute once in
// the background; a refresh already in flight is never duplicated. Only
// a true-cold start (no stale value yet) computes inline. The boot
// pre-warm fills the health entry so
// the first visitor rarely pays cold.
//
// List payloads (apiActivity) bypass the cached/age_ms/stale flags: extra
// props on an array do not survive JSON.stringify, and wrapping the payload
// would change the API shape clients parse. Dict payloads keep the flags.
const TTL_CACHE = {};
const TTL_REFRESHING = {};
// Latency ring for the ops view: Date.now() deltas around expensive cache
// computations only (hits are ~0ms by definition and already visible via
// the cached flag). Capped at 200 entries; two syscalls per recorded call
// is unmeasurable overhead by construction. Records COMPUTE cost, not
// queueing — a request answered from cache never touches this path.
const PERF_RING = [];
function perfNote(path, ms) {
  PERF_RING.push({ path, ms, at: Date.now() });
  if (PERF_RING.length > 200) PERF_RING.splice(0, PERF_RING.length - 200);
}
function ttlCached(key, ttlMs, fn) {
  const now = Date.now();
  const hit = TTL_CACHE[key];
  if (hit && hit.value && now - hit.at < ttlMs) {
    if (Array.isArray(hit.value)) return hit.value.slice();
    return Object.assign({}, hit.value, { cached: true, age_ms: now - hit.at });
  }
  if (hit && hit.value) {
    if (!TTL_REFRESHING[key]) {
      TTL_REFRESHING[key] = true;
      // Deferred past this tick: fn() is synchronous multi-second work and
      // an async wrapper would still run its sync prefix inline, blocking
      // THIS response. Set the flag now (singleflight), compute next tick.
      setImmediate(() => {
        try {
          const t0 = Date.now();
          const value = fn();
          perfNote(key, Date.now() - t0);
          if (!Array.isArray(value)) { value.cached = false; value.age_ms = 0; }
          TTL_CACHE[key] = { at: Date.now(), value };
        } catch {
          // keep serving stale on refresh failure; next miss retries
        }
        TTL_REFRESHING[key] = false;
      });
    }
    if (Array.isArray(hit.value)) return hit.value.slice();
    return Object.assign({}, hit.value, { cached: true, age_ms: now - hit.at, stale: true });
  }
  const t0 = Date.now();
  const value = fn();
  perfNote(key, Date.now() - t0);
  if (!Array.isArray(value)) { value.cached = false; value.age_ms = 0; }
  value.age_ms = 0;
  TTL_CACHE[key] = { at: Date.now(), value };
  return value;
}
// Worker-thread cure for sync aggregations (backend-overload doctrine):
// the scans above are multi-second and single-threaded — every TTL expiry
// froze ALL concurrent requests. Heavy computes now run in query-worker.mjs
// (same query-lib bodies, own read-only handles); this thread only awaits.
// Worker threads reference: https://nodejs.org/api/worker_threads.html
// (dedicated V8 isolate + event loop; node:sqlite handles cannot cross
// threads, hence per-call read-only opens inside the worker).
// Two pools: a FAST worker for interactive queries (semantic/trends/cost/...)
// and a HEAVY one for health/board (10-30 s builds). A single worker let a
// health refresh time out a 16 ms trends query; separating them keeps the
// interactive path responsive. 60 s timeout per call; every failure path falls
// back or keeps stale — a dead worker degrades to inline, never a failed
// request. Results cross the boundary by structured clone (plain JSON only):
// https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Structured_clone_algorithm
let QWARNED = false;
function workerWarn(msg) {
  if (!QWARNED) { QWARNED = true; console.log("worker: " + msg); }
}
const HEAVY_FNS = new Set(["healthSync", "board", "signals"]);
function makePool(name) { return { name, worker: null, seq: 0, pend: {} }; }
const FAST_POOL = makePool("fast");
const HEAVY_POOL = makePool("heavy");
function callPool(pool, fn, args, resolve, reject) {
  try {
    if (!pool.worker) {
      // QUERY_WORKER_PATH overrides the worker entry (operability knob and
      // fault-injection seam: point it at a missing file to prove the inline
      // fallback keeps every request at 200).
      const qurl = process.env.QUERY_WORKER_PATH || "./query-worker.mjs";
      pool.worker = new Worker(new URL(qurl, import.meta.url), { env: { ...process.env } });
      pool.worker.on("message", (m) => {
        const p = pool.pend[m.id];
        if (!p) return;
        delete pool.pend[m.id];
        if (m.ok) p.res(m.value); else p.rej(new Error(m.error));
      });
      const failAll = (e) => {
        for (const k of Object.keys(pool.pend)) {
          try { pool.pend[k].rej(e); } catch { /* settle once */ }
          delete pool.pend[k];
        }
        pool.worker = null;
      };
      pool.worker.on("error", failAll);
      pool.worker.on("exit", () => { failAll(new Error(pool.name + " worker exited")); });
    }
    const id = ++pool.seq;
    const to = setTimeout(() => {
      if (pool.pend[id]) { delete pool.pend[id]; reject(new Error(pool.name + " worker timeout")); }
    }, 60000);
    pool.pend[id] = {
      res: (v) => { clearTimeout(to); resolve(v); },
      rej: (e) => { clearTimeout(to); reject(e); },
    };
    pool.worker.postMessage({ id, fn, dbPath, args });
  } catch (e) { reject(e); }
}
function workerCall(fn, ...args) {
  return new Promise((resolve, reject) =>
    callPool(HEAVY_FNS.has(fn) ? HEAVY_POOL : FAST_POOL, fn, args, resolve, reject));
}
// Async SWR shell mirroring ttlCached semantics (fresh/cached/stale +
// singleflight), but compute happens off-thread. Cold path falls back to
// the inline body when the worker is unavailable — same values, main
// thread pays (rare: pre-warmed; observable via missing stale flag).
const ACACHE = {};
const AREFRESH = {};
// Seed slow panels from their durable snapshot: the first request after a
// restart serves stale instantly while the worker refreshes (pi-durable #74).
const SIGNALS_CACHE_PATH = fileURLToPath(new URL("../data/observability/signals-cache.json", import.meta.url));
const BOARD_CACHE_PATH = fileURLToPath(new URL("../data/observability/board-cache.json", import.meta.url));
try {
  const seed = loadJsonCache(SIGNALS_CACHE_PATH);
  if (seed && seed.value) ACACHE["signals"] = { at: Number(seed.at) || Date.now(), value: seed.value };
  const bseed = loadJsonCache(BOARD_CACHE_PATH);
  if (bseed && bseed.value) ACACHE["board"] = { at: Number(bseed.at) || Date.now(), value: bseed.value };
} catch { /* no snapshot: normal cold path */ }
async function asyncCached(key, ttlMs, workerFn, workerArgs, inlineFn, persist) {
  const now = Date.now();
  const hit = ACACHE[key];
  if (hit && hit.value && now - hit.at < ttlMs) {
    const v = hit.value;
    return Array.isArray(v) ? v.slice() : Object.assign({}, v, { cached: true, age_ms: now - hit.at });
  }
  if (hit && hit.value) {
    if (!AREFRESH[key]) {
      AREFRESH[key] = true;
      workerCall(workerFn, ...workerArgs).then((value) => {
        if (!Array.isArray(value)) { value.cached = false; value.age_ms = 0; }
        ACACHE[key] = { at: Date.now(), value };
        if (persist) persist(value);
        AREFRESH[key] = false;
      }, () => { AREFRESH[key] = false; });
    }
    const v = hit.value;
    return Array.isArray(v) ? v.slice() : Object.assign({}, v, { cached: true, age_ms: now - hit.at, stale: true });
  }
  try {
    const value = await workerCall(workerFn, ...workerArgs);
    if (!Array.isArray(value)) { value.cached = false; value.age_ms = 0; }
    ACACHE[key] = { at: now, value };
    if (persist) persist(value);
    return value;
  } catch (e) {
    // Inline fallback (same query-lib bodies the worker runs): slower on
    // this thread, but byte-identical values. Logged once per process so
    // a dead worker is visible in logs instead of silent.
    workerWarn("cold compute fell back inline (" + String((e && e.message) || e).slice(0, 100) + ")");
    const value = inlineFn();
    if (!Array.isArray(value)) { value.cached = false; value.age_ms = 0; }
    ACACHE[key] = { at: now, value };
    if (persist) persist(value);
    return value;
  }
}
const SIGNALS_TTL_MS = Number(process.env.SIGNALS_TTL_MS || 30000);
const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS || 15000);
async function apiSignals() {
  // Persist each successful build; a restart re-serves it as stale (instant)
  // while the worker recomputes, so the ~32 s first hit disappears.
  return asyncCached("signals", SIGNALS_TTL_MS, "signals", [], () => signalsFresh(dbPath),
    (v) => saveJsonCache(SIGNALS_CACHE_PATH, v));
}
async function apiPatterns(limit) {
  limit = Number(limit) || 30;
  return asyncCached("patterns:" + limit, CACHE_TTL_MS, "patterns", [limit], () => patternsFresh(dbPath, limit));
}
// Ops aggregate for the 8th explore tab: failures, successes, bottlenecks
// as visualized data. Cheap by construction: signals via its TTL cache,
// ledger via indexed read-only queries, timings from the PERF ring.
// Never throws (a missing observability db yields empty sections).
async function apiOps() {
  let errors_by_tool = [];
  try {
    // errorTools lives in apiPatterns (grouped by tool); the limit only
    // caps ngrams, and key "patterns:30" shares the UI's own cache entry.
    const pat = await apiPatterns(30);
    errors_by_tool = (pat.errorTools || []).map(e => ({ tool: e.tool, n: e.n, example_sid: e.example_sid || null }));
  } catch { errors_by_tool = []; }
  let per_model_errors = [];
  try {
    // Own 60 s TTL via apiModelErrors (not coupled to the health recompute).
    const rows = await apiModelErrors();
    per_model_errors = (Array.isArray(rows) ? rows : []).map(r => ({ model: r.model, sessions: r.sessions, tool_parts: r.tool_parts, errors: r.errors, error_rate: r.error_rate ?? null }));
  } catch { per_model_errors = []; }
  let gate_runs = [], guard_n = 0, guard_top = [], ledger_summary = {};
  try {
    const odb = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)), { readOnly: true });
    gate_runs = odb.prepare("SELECT ts, verdict, detail FROM ledger WHERE type IN ('GATE','GATE_REPORT') ORDER BY id DESC LIMIT 20").all();
    const gb = odb.prepare("SELECT COUNT(*) n FROM ledger WHERE type='GUARD' AND verdict='block'").get();
    guard_n = gb ? gb.n : 0;
    guard_top = odb.prepare("SELECT tool pattern, COUNT(*) n FROM ledger WHERE type='GUARD' AND verdict='block' GROUP BY tool ORDER BY n DESC LIMIT 5").all();
    for (const r of odb.prepare("SELECT type, COUNT(*) n FROM ledger GROUP BY type").all()) ledger_summary[r.type] = r.n;
    odb.close();
  } catch { /* observability db absent: sections stay empty */ }
  const latest = {};
  for (const e of PERF_RING) latest[e.path] = e;
  const slow_endpoints = Object.values(latest).map(e => ({ path: e.path, ms: e.ms })).sort((a, b) => b.ms - a.ms).slice(0, 10);
  return { errors_by_tool, per_model_errors, gate_runs, guard_blocks: { n: guard_n, top: guard_top }, slow_endpoints, ledger_summary };
}
function apiGuard(limit) {
  try {
    const lines = readFileSync(new URL("../data/observability/guard.log", import.meta.url), "utf8")
      .split("\n").filter(Boolean);
    const rows = lines.slice(-limit).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    const counts = {};
    for (const r of rows) counts[r.verdict] = (counts[r.verdict] || 0) + 1;
    return { count: rows.length, counts, actions: rows.reverse() };
  } catch {
    return { count: 0, counts: {}, actions: [] };
  }
}

// /api/health is the panel's hot path and does ~7s of synchronous work
// (healthReport + modelLedger over the DB). Because the dashboard is a single
// Node process, that blocks EVERY other request too (a trivial /api/rev was
// measured at 4.8s while health computed). So cache the payload for a TTL and
// serve repeats from memory; a `cached`/`age_ms` pair makes it observable and
// gateable. TTL is tunable via HEALTH_TTL_MS.
let HEALTH_CACHE = { at: 0, value: null };
const HEALTH_TTL_MS = Number(process.env.HEALTH_TTL_MS || 15000);
let HEALTH_REFRESHING = false;
// Seed the health panel from its durable snapshot (same pi-durable #74 pattern
// as /api/signals): a restart serves the last good report instantly and
// refreshes in the worker, instead of a cold ~10-30 s aggregation.
const HEALTH_CACHE_PATH = fileURLToPath(new URL("../data/observability/health-cache.json", import.meta.url));
try {
  const seed = loadJsonCache(HEALTH_CACHE_PATH);
  if (seed && seed.value) HEALTH_CACHE = { at: Number(seed.at) || Date.now(), value: seed.value, ttl: 5000 };
} catch { /* no snapshot: normal cold path */ }
async function apiHealth() {
  const now = Date.now();
  const v = HEALTH_CACHE.value;
  if (v && now - HEALTH_CACHE.at < (HEALTH_CACHE.ttl || HEALTH_TTL_MS)) {
    return Object.assign({}, v, { cached: true, age_ms: now - HEALTH_CACHE.at });
  }
  if (v) {
    // Stale-while-revalidate (see ttlCached doctrine): serve stale now,
    // refresh once in the background. A cold /api/health blocks the loop
    // ~10 s; without this every TTL expiry replays that stall onto a live
    // request and everything queued behind it.
    if (!HEALTH_REFRESHING) {
      HEALTH_REFRESHING = true;
      // Deferred past this tick: refreshHealthCache is async, but an async
      // call still runs its synchronous prefix (multi-second aggregation)
      // inline, which would block THIS stale response. Flag now for
      // singleflight, compute next tick.
      setImmediate(() => {
        refreshHealthCache().then(
          () => { HEALTH_REFRESHING = false; },
          () => { HEALTH_REFRESHING = false; }
        );
      });
    }
    return Object.assign({}, v, { cached: true, age_ms: now - HEALTH_CACHE.at, stale: true });
  }
  return refreshHealthCache(); // true-cold: no stale value exists yet
}
async function refreshHealthCache() {
  try {
    // Heavy sync prefix runs in the worker (same query-lib/pure bodies);
    // inline fallback keeps the old behavior when the worker is down.
    // perfNote measures the sync portion only: the liveStatus await below
    // is network wait, not loop-blocking work.
    const t0 = Date.now();
    let r;
    try {
      r = await workerCall("healthSync");
    } catch {
      r = healthReport(dbPath);
      Object.assign(r, annotateReport(r));
      r.per_model = modelLedger(dbPath);
      try {
        r.handoff = handoffAdvice(dbPath);
      } catch {
        r.handoff = { available: false };
      }
      try {
        r.risks = budgetRisks(dbPath);
      } catch {
        r.risks = { available: false };
      }
    }
    // perfNote measures aggregation cost, not loop blockage: on the worker
    // path the loop stays free (only the inline fallback blocks).
    // liveStatus below is network wait in both cases.
    perfNote("health", Date.now() - t0);
    // Adjudicate against the live server (dead_tool / dead_blank). Fail-safe:
    // if live status is unavailable (no password / server down / timeout) the
    // report is returned unchanged, so a finding stays a stall/blank rather than
    // being silently exonerated. A longer timeout survives a loaded host.
    try {
      r.live = await liveStatus({ timeoutMs: 8000 });
    } catch {
      r.live = { available: false, reason: "liveStatus threw" };
    }
    applyLiveAdjudication(r, r.live);
    r.cached = false;
    r.age_ms = 0;
    // Validity starts when the value lands, not when the compute started:
    // a shorter TTL than the compute time would otherwise birth an
    // already-expired entry (permanent recompute storm saturating the loop).
    const ttl = r.live && r.live.available ? HEALTH_TTL_MS : 5000;
    HEALTH_CACHE = { at: Date.now(), value: r, ttl };
    saveJsonCache(HEALTH_CACHE_PATH, r);
    return r;
  } catch (e) {
    return { available: false, error: String(e && e.message ? e.message : e), counts: {}, findings: [], known_issues: [], by_model: {}, per_model: [], cached: false };
  }
}

async function apiActivity() {
  // Polling endpoint (home every 2 s). Off-loop + 10 s TTL; the scoped body
  // (12 newest sessions) lives in query-lib with the same shape.
  return asyncCached("activity", POLL_TTL_MS, "activity", [], () => activityFresh(dbPath));
}

function apiTodos() {
  const latest = query("SELECT id FROM session ORDER BY time_created DESC LIMIT 1")[0];
  if (!latest) return [];
  return query(
    "SELECT content, status, priority, position FROM todo WHERE session_id = ? ORDER BY position ASC",
    latest.id
  );
}

function qs(req) {
  const out = {};
  const i = req.url.indexOf("?");
  if (i < 0) return out;
  for (const kv of req.url.slice(i + 1).split("&")) {
    const eq = kv.indexOf("=");
    if (eq < 0) out[decodeURIComponent(kv)] = "";
    else out[decodeURIComponent(kv.slice(0, eq))] = decodeURIComponent(kv.slice(eq + 1));
  }
  return out;
}

function apiSessions(limit, offset) {
  // No correlated subqueries: MIN/MAX over part per session measured 130x
  // slower than the plain scan (1.045s vs 0.008s at 82 sessions). The UI
  // already falls back to session times (span()/dur()), so p_start/p_end
  // are dropped, not moved. limit/offset are clamped to ints (injection
  // cannot ride a string into LIMIT/OFFSET).
  const lim = Math.max(1, Math.min(2000, Number(limit) || 200));
  const off = Math.max(0, Number(offset) || 0);
  return query(
    "SELECT s.id, s.title, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning, s.tokens_cache_read, s.model, s.agent, s.directory, p.worktree AS project, s.time_created, s.time_updated " +
    "FROM session s LEFT JOIN project p ON p.id=s.project_id ORDER BY s.time_created DESC LIMIT ? OFFSET ?",
    lim, off
  );
}

function apiParts(sessionId, limit) {
  if (!sessionId) {
    const l = query("SELECT id FROM session ORDER BY time_created DESC LIMIT 1")[0];
    sessionId = l ? l.id : null;
  }
  if (!sessionId) return [];
  const rows = query(
    "SELECT time_created, time_updated, data FROM part WHERE session_id = ? ORDER BY time_created ASC LIMIT ?",
    sessionId, limit
  );
  const items = [];
  for (const r of rows) {
    let d;
    try { d = JSON.parse(r.data); } catch { continue; }
    const it = { ts: r.time_created, te: r.time_updated || r.time_created, type: d.type };
    if (d.type === "tool") {
      it.tool = d.tool;
      it.status = (d.state && d.state.status) || "?";
      const inp = d.state && d.state.input;
      it.cmd = (inp && (inp.command || inp.description)) || "";
    } else if (d.type === "reasoning" || d.type === "text") {
      it.text = d.text || "";
    } else if (d.type === "patch") {
      it.files = (d.files || []).join(",");
    }
    items.push(it);
  }
  return items;
}

function sessionRow(id) {
  return query(
    "SELECT id, title, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, time_created, time_updated, model, agent, directory FROM session WHERE id = ?",
    id
  )[0] || null;
}

function apiSessionDetail(id, limit) {
  const s = sessionRow(id);
  if (!s) return { error: "session not found" };
  const mm = query("SELECT COUNT(*) n FROM message WHERE session_id = ?", id)[0];
  return { session: s, messages: mm ? mm.n : 0, parts: apiParts(id, limit) };
}

function transcript(id) {
  const rows = query(
    "SELECT m.time_created mt, json_extract(m.data,'$.role') role, p.data pdata, p.time_created pt " +
    "FROM message m JOIN part p ON p.message_id = m.id WHERE m.session_id = ? ORDER BY m.time_created, p.time_created",
    id
  );
  const out = [];
  for (const r of rows) {
    let d;
    try { d = JSON.parse(r.pdata); } catch { continue; }
    const role = r.role || "?";
    const ts = r.mt || r.pt;
    if (d.type === "text") out.push({ role, ts, kind: "text", text: d.text || "" });
    else if (d.type === "reasoning") out.push({ role, ts, kind: "reasoning", text: d.text || "" });
    else if (d.type === "tool") {
      const inp = d.state && d.state.input;
      out.push({ role, ts, kind: "tool", tool: d.tool, cmd: (inp && (inp.command || inp.description)) || "" });
    } else if (d.type === "patch") out.push({ role, ts, kind: "patch", files: d.files || [] });
  }
  return out;
}

function apiExportSession(id, format) {
  const s = sessionRow(id);
  if (!s) return null;
  const turns = transcript(id);
  const spanS = Math.max(0, Math.round((Number(s.time_updated || 0) - Number(s.time_created || 0)) / 1000));
  if (format === "json") return redact(JSON.stringify({ session: s, turns }, null, 2));
  const head =
    "# " + (s.title || "(untitled)") + "\n" +
    "session: " + s.id + "\n" +
    "cost: $" + (Number(s.cost) || 0).toFixed(4) + "\n" +
    "tokens: in=" + s.tokens_input + " out=" + s.tokens_output + " reasoning=" + s.tokens_reasoning + "\n" +
    "span: " + spanS + "s\n" +
    "created: " + new Date(s.time_created).toISOString() + "\n\n";
  let body = "";
  for (const x of turns) {
    if (x.kind === "text") body += "### " + x.role + "\n" + x.text + "\n\n";
    else if (x.kind === "reasoning") body += "_(reasoning)_\n" + x.text + "\n\n";
    else if (x.kind === "tool") body += "_[tool: " + x.tool + "]_ `" + String(x.cmd || "").replace(/`/g, "'") + "`\n\n";
    else if (x.kind === "patch") body += "_[patch]_ " + (x.files || []).join(", ") + "\n\n";
  }
  // Redact at the egress boundary: the transcript can contain a leaked value.
  if (format === "md") return redact(head + body);
  return redact(head + body.replace(/^### /gm, "").replace(/^_\(reasoning\)_\n/gm, "[reasoning] ").replace(/^_\[/gm, "["));
}

async function apiSearch(q, limit) {
  // Legacy substring search (measured 6.8 s). Cache by query and run in the
  // worker; /api/semantic is the fast FTS5 path for interactive search.
  const needle = String(q || "").replace(/[%_\\]/g, "");
  const lim = Number(limit) || 20;
  return asyncCached("search:" + needle + ":" + lim, CACHE_TTL_MS, "search",
    [needle, lim], () => searchFresh(dbPath, needle, lim));
}

// The FTS index build runs in query-worker.mjs (apiSemanticFresh in
// query-lib.mjs) so the multi-second sync scan no longer blocks this event
// loop. FTS_MIN_REBUILD_MS (query-lib) is the rebuild window / env knob.
// Async shell: on worker failure the identical query-lib body runs inline.
async function apiSemantic(q, limit) {
  const raw = String(q || "");
  limit = Number(limit) || 20;
  try {
    return await workerCall("semantic", raw, limit);
  } catch (e) {
    workerWarn("semantic fell back inline (" + String((e && e.message) || e).slice(0, 100) + ")");
    return semanticFresh(dbPath, raw, limit);
  }
}

// Board — one read-only payload for the Kanban (state) + Gantt (time) view.
// Three provenance classes, labelled per datum so an estimate never reads as a
// measurement: db = the opencode `todo` table joined to `session` (measured
// state + resource use); md = TODO.md queue marks (declared intent, no span);
// milestones = the observability `ledger` (GATE/GATE_START/ADVISORY). Estimates
// are a median over completed db cards — heuristic, flagged estimates.heuristic.
const TODO_PATH = fileURLToPath(new URL("../TODO.md", import.meta.url));
const OBS_DB_PATH = fileURLToPath(new URL("../data/observability/observability.db", import.meta.url));
function apiBoardFresh() {
  let cards = [];
  try {
    const rows = query(
      "SELECT t.session_id sid, t.content, t.status, t.priority, t.position, t.time_created tc, t.time_updated tu, " +
      "s.title, s.model, s.cost, s.tokens_input " +
      "FROM todo t LEFT JOIN session s ON s.id = t.session_id " +
      "ORDER BY t.time_created DESC LIMIT 500"
    );
    cards = rows.map((r) => {
      let mid = r.model;
      try { mid = (JSON.parse(r.model) || {}).id || r.model; } catch { mid = r.model; }
      const start = Number(r.tc) || 0, end = Number(r.tu) || 0;
      return {
        id: r.sid + "#" + r.position, title: String(r.content || "").replace(/\s+/g, " ").slice(0, 160),
        state: r.status || "unknown", priority: r.priority || "", source: "db",
        session: r.sid, session_title: r.title || "", model: mid || "",
        cost: Number(r.cost) || 0, tokens_in: Number(r.tokens_input) || 0,
        start, end, duration: end > start ? end - start : 0,
      };
    });
  } catch { cards = []; }
  let md = "";
  try { md = readFileSync(TODO_PATH, "utf8"); } catch { md = ""; }
  const re = /^- \[([ x~])\]\s+(.+)$/gm;
  let mm, mdi = 0;
  while ((mm = re.exec(md))) {
    const mark = mm[1];
    cards.push({
      id: "md:" + (mdi++), title: mm[2].replace(/\s+/g, " ").slice(0, 160),
      state: mark === "x" ? "completed" : mark === "~" ? "in_progress" : "pending",
      priority: "", source: "md", session: "", session_title: "", model: "",
      cost: 0, tokens_in: 0, start: 0, end: 0, duration: 0,
    });
  }
  let milestones = [];
  try {
    const db = new DatabaseSync(OBS_DB_PATH, { readOnly: true });
    milestones = db.prepare("SELECT ts, type, verdict, source FROM ledger ORDER BY id DESC LIMIT 200").all()
      .map((r) => ({ ts: r.ts, type: r.type, verdict: r.verdict || "", source: r.source || "" }));
    db.close();
  } catch { milestones = []; }
  // The Gantt uses real session spans (time_created -> time_updated): todo rows
  // are written in one instant (duration 0), so a task-span Gantt would be
  // empty. Sessions are the realized schedule; each carries its own resources.
  let sessions = [];
  try {
    sessions = query(
      "SELECT id, title, model, agent, cost, tokens_input, time_created, time_updated " +
      "FROM session ORDER BY time_created DESC LIMIT 150"
    ).map((r) => {
      let mid = r.model;
      try { mid = (JSON.parse(r.model) || {}).id || r.model; } catch { mid = r.model; }
      const start = Number(r.time_created) || 0, end = Number(r.time_updated) || 0;
      return {
        id: r.id, title: r.title || "", model: mid || "", agent: r.agent || "",
        cost: Number(r.cost) || 0, tokens_in: Number(r.tokens_input) || 0,
        start, end, duration: end > start ? end - start : 0,
      };
    });
  } catch { sessions = []; }
  const median = (a) => {
    if (!a.length) return 0;
    const s = [...a].sort((x, y) => x - y), m = Math.floor(s.length / 2);
    return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
  };
  // Estimates over realized sessions (a session ~ one work unit): heuristic,
  // flagged. Not a promise for an unstarted task's real duration/cost.
  const spent = sessions.filter((s) => s.duration > 0);
  return {
    generated_at: new Date().toISOString(),
    states: ["pending", "in_progress", "completed"],
    cards, sessions, milestones,
    estimates: {
      n: spent.length,
      median_duration_ms: median(spent.map((s) => s.duration)),
      median_cost_usd: median(spent.map((s) => s.cost)),
      heuristic: true,
    },
  };
}
async function apiBoard() {
  // Persist the last board payload: the first board tab after a restart is
  // instant while the heavy worker recomputes (same #74 pattern as signals).
  return asyncCached("board", CACHE_TTL_MS, "board", [TODO_PATH, OBS_DB_PATH], () => apiBoardFresh(),
    (v) => saveJsonCache(BOARD_CACHE_PATH, v));
}



async function apiWords(limit) {
  limit = Number(limit) || 80;
  return asyncCached("words:" + limit, CACHE_TTL_MS, "words", [limit], () => wordsFresh(dbPath, limit));
}
// Per-model error rates for the ops tab. Own 60 s TTL (not coupled to the
// health recompute): modelLedger is read-only over the recent window.
async function apiModelErrors() {
  return asyncCached("models", 60000, "models", [], () => modelLedger(dbPath));
}
function apiExport() {
  const rows = query("SELECT title, cost, tokens_input, tokens_output, tokens_reasoning, time_created, time_updated FROM session ORDER BY time_created ASC");
  let body = "title,cost_usd,tokens_input,tokens_output,tokens_reasoning,duration_ms,created_iso\n";
  for (const r of rows) {
    const title = String(r.title || "").replace(/"/g, '""');
    const dur = Number(r.time_updated || 0) - Number(r.time_created || 0);
    const iso = new Date(r.time_created).toISOString();
    body += '"' + title + '",' + r.cost + "," + r.tokens_input + "," + r.tokens_output + "," + r.tokens_reasoning + "," + dur + "," + iso + "\n";
  }
  return redact(body);
}

let balanceCache = { at: 0, data: { available: false } };
let configCache = { at: 0, data: null };

let configInflight = null;
async function apiConfig() {
  const script = process.argv[5];
  if (!script) return { findings: [], summary: { ok: 0, warn: 0, error: 0, fatal: 0, skip: 0 } };
  if (configCache.data && Date.now() - configCache.at < 60000) return configCache.data;
  // The audit is an external bash process (up to 45 s): run it non-blocking
  // with single-flight, so a cold request cannot freeze the served pages.
  if (configInflight) return configInflight;
  configInflight = execFileP("bash", [script, "--json"], { timeout: 45000, encoding: "utf8" })
    .then((r) => {
      const j = JSON.parse(String(r.stdout).trim());
      configCache = { at: Date.now(), data: j };
      return j;
    })
    .catch(() => ({ error: "config audit failed to run" }))
    .finally(() => { configInflight = null; });
  return configInflight;
}
async function apiBalance() {
  const key = process.env.DEEPSEEK_API_KEY;
  if (!key) return { available: false };
  if (Date.now() - balanceCache.at < 60000) return balanceCache.data;
  try {
    const r = await fetch("https://api.deepseek.com/user/balance", {
      headers: { Authorization: "Bearer " + key },
      signal: AbortSignal.timeout(10000),
    });
    if (!r.ok) return { available: false };
    const j = await r.json();
    const info = (j.balance_infos || []).find((b) => b.currency === "USD");
    const data = { available: true, usd: info ? info.total_balance : null };
    balanceCache = { at: Date.now(), data };
    return data;
  } catch {
    return { available: false };
  }
}

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode observability</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 8px}
 .row{display:flex;flex-wrap:wrap;gap:10px}
 .card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:12px;margin:10px 0}
 .card h2{margin:0 0 8px;font-size:13px;color:#8b949e;font-weight:600}
 .stat{flex:1;min-width:120px;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:10px}
 .stat b{display:block;font-size:20px;font-weight:600}
 .stat span{color:#8b949e;font-size:12px}
 .item{padding:4px 0;border-bottom:1px solid #21262d;font-size:13px;word-break:break-word;cursor:default}
 .tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;margin-right:6px;vertical-align:top}
 .TOOL{background:#1f6feb33;color:#58a6ff}.REASON{background:#8957e533;color:#d2a8ff}
 .TEXT{background:#2ea04333;color:#7ee787}.STEP{background:#30363d;color:#8b949e}
 .PATCH{background:#b6232433;color:#ff7b72}
 .ERR{background:#b6232433;color:#ff7b72;font-weight:600}.RUN{background:#d2992233;color:#d29922}
 .muted{color:#8b949e}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:3px 8px;border-bottom:1px solid #21262d}
 th{color:#8b949e;font-weight:600}
 .num{text-align:right;font-variant-numeric:tabular-nums}
 .srow{cursor:default}
 .srow:hover{background:#1f6feb22}
 .srow .exp{cursor:pointer;color:#8b949e;user-select:none;width:18px;text-align:center}
 .srow .exp:hover{color:#e6edf3}
 .sopen{color:#e6edf3;text-decoration:none}
 .sopen:hover{color:#58a6ff;text-decoration:underline}
 .sdetail-cell{padding:8px 10px;background:#0d1119;border-bottom:1px solid #21262d}
 .sdetail-cell .stat{margin-right:16px}
 input#q{width:100%;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px;box-sizing:border-box}
 .card a{font-size:12px;margin-right:6px}
 .live{color:#3fb950}.idle{color:#8b949e}
 #session{font-size:13px;margin-bottom:4px}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("dashboard")}
<main id="main" tabindex="-1">
<h1>opencode observability</h1>
<div id="session" class="muted" aria-live="polite"><span class="muted" data-loading>loading...</span></div>
<div class="row" id="stats" aria-live="polite"><span class="muted" data-loading>loading...</span></div>
<div class="card" id="flags-card" style="border-color:#d29922"><h2>Flags <span class="muted">(bottlenecks · cost · slowdowns · stalls — click an example)</span></h2><div id="flags" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Search <span class="muted">(ranked FTS: title · text · commands)</span></h2><input id="q" placeholder="search across sessions..." aria-label="Search sessions" aria-keyshortcuts="/"><div id="searchres" aria-live="polite"></div></div>
<div class="card"><h2>Config audit <span class="muted">(actual vs expected)</span></h2><div id="config" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Sessions <span class="muted">(▸ expands inline · title opens the session in a new tab)</span> <span class="muted" data-tz></span></h2><div id="sessions" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Session detail <span class="muted" id="drill-id"></span></h2><div id="drill"><span class="muted">click a session row to drill down</span></div></div>
<div class="card"><h2>Live activity <span class="muted">(click to expand)</span> <span class="muted" data-tz></span></h2><div id="activity" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Todos</h2><div id="todos" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
</main>
<script>
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function fmt(n){n=Number(n)||0;return n>=1000?(n/1000).toFixed(1)+'k':''+n;}
// Times are shown in the VIEWER's local timezone (browser clock), not UTC, so
// they match the operator's wall clock; tzname() labels the zone on screen.
function tzname(){try{return Intl.DateTimeFormat().resolvedOptions().timeZone||'local';}catch(e){return 'local';}}
function pad3(n){n=String(n);return n.length<3?('00'+n).slice(-3):n;}
function ts(t){var d=new Date(Number(t));return d.toLocaleTimeString(undefined,{hour12:false,hour:'2-digit',minute:'2-digit',second:'2-digit'})+'.'+pad3(d.getMilliseconds());}
// Bounded fetch: ms sets AbortSignal.timeout, so a caller that cares about
// latency aborts a slow/hung endpoint instead of stalling (guarded where
// AbortSignal is absent, e.g. the headless UI shim).
async function j(u,ms){try{var o=(ms&&typeof AbortSignal!=='undefined')?{signal:AbortSignal.timeout(ms)}:undefined;var r=await fetch(u,o);return r.ok?r.json():null;}catch(e){return null;}}
function failIfPristine(id,msg){var el=document.getElementById(id);if(el&&el.querySelector('[data-loading]'))el.innerHTML='<span class="muted" data-error>'+msg+'</span>';}
var expanded={};
function item(x){
  var cls=String(x.type||'').toUpperCase();
  var tag=(x.type==='step-start'||x.type==='step-finish')?'STEP':cls;
  if(x.type==='tool'&&x.status==='error'){tag=tag+' ERR';}
  else if(x.type==='tool'&&x.status==='running'){tag=tag+' RUN';}
  var short='',full='';
  if(x.type==='tool'){short=esc(x.tool)+' ['+esc(x.status)+'] '+esc((x.cmd||'').slice(0,90));full=esc(x.tool)+' ['+esc(x.status)+'] '+esc(x.cmd||'');}
  else if(x.type==='reasoning'||x.type==='text'){short=esc((x.text||'').slice(0,140));full=esc(x.text||'');}
  else if(x.type==='patch'){short=esc(x.files||'');full=short;}
  var click=(full&&full!==short)?' style="cursor:pointer" onclick="tog('+x.ts+')" title="'+(expanded[x.ts]?'click to collapse':'click to expand')+'"':'';
  var body=expanded[x.ts]?full:short;
  return '<div class="item"'+click+'><span class="tag '+tag+'">'+esc(x.type)+'</span>'+body+' <span class="muted">'+ts(x.ts)+'</span></div>';
}
function tog(ts){expanded[ts]=expanded[ts]?0:1;refreshActivity();}
function dur(s){
  var a=Number(s.p_start||0), b=Number(s.p_end||0);
  if(b>a){return ((b-a)/1000).toFixed(0)+'s';}
  var d=Number(s.time_updated||0)-Number(s.time_created||0);
  return d>0?(d/1000).toFixed(0)+'s':'';
}
function localt(ms){if(!ms)return '';try{return new Date(Number(ms)).toLocaleString();}catch(e){return String(ms);}}
function sessOpenHref(id){
  try{
    var srv=location.protocol+'//'+location.hostname+':4096';
    var b64=btoa(srv).replace(/=+$/,'');
    return 'https://'+location.hostname+':4096/server/'+b64+'/session/'+encodeURIComponent(id);
  }catch(e){return 'https://'+location.hostname+':4096/';}
}
var sessDetailLoaded={},sessOpenCount=0;
async function toggleSessRow(id){
  var dr=document.querySelector('tr.sdetail[data-for="'+id+'"]');
  if(!dr){return;}
  var cb=document.querySelector('.exp[data-exp="'+id+'"]');
  if(!dr.hasAttribute('hidden')){dr.setAttribute('hidden','');if(cb)cb.textContent='▸';if(sessOpenCount>0)sessOpenCount--;return;}
  dr.removeAttribute('hidden');if(cb)cb.textContent='▾';sessOpenCount++;
  var cell=dr.querySelector('.sdetail-cell');
  if(sessDetailLoaded[id]){return;}
  cell.innerHTML='<span class="muted">loading…</span>';
  var d=await j('/api/session?id='+encodeURIComponent(id)+'&limit=60');
  if(!d||d.error){cell.innerHTML='<span class="muted">'+esc((d&&d.error)||'no data')+'</span>';return;}
  var s=d.session||{};
  var href=sessOpenHref(id);
  cell.innerHTML='<div class="row">'
    +'<div class="stat"><b>$'+(+s.cost).toFixed(4)+'</b><span>cost</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_input)+'</b><span>in</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_output)+'</b><span>out</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_reasoning)+'</b><span>reasoning</span></div>'
    +'<div class="stat"><b>'+esc(d.messages||0)+'</b><span>messages</span></div>'
    +'</div>'
    +'<div class="muted" style="font-size:12px">download: '
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=txt">[txt]</a> '
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=md">[md]</a> '
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=json">[json]</a>'
    +' &nbsp;·&nbsp; <a href="'+esc(href)+'" target="_blank" rel="noopener">open in opencode web ↗</a></div>';
  sessDetailLoaded[id]=1;
}
function sessRow(s){
  var c=+s.cost||0;
  var cls=c>=0.10?' class="num" style="color:#ff7b72"':' class="num"';
  var dir=String(s.directory||'');if(dir.length>42)dir='…'+dir.slice(-41);
  var upd=localt(s.time_updated);
  var mid=(function(m){if(!m)return '(none)';try{var o=JSON.parse(m);return o.id||m;}catch(e){return String(m);}})(s.model);
  var id=esc(s.id||'');
  var href=esc(sessOpenHref(s.id||''));
  return '<tr class="srow" data-id="'+id+'">'
    +'<td class="exp" data-exp="'+id+'" role="button" tabindex="0" title="expand details">▸</td>'
    +'<td><a class="sopen" href="'+href+'" target="_blank" rel="noopener" title="open session in new tab">'+esc(s.title||'(untitled)')+'</a></td>'
    +'<td>'+esc(mid)+'</td>'
    +'<td class="muted">'+esc(dir)+'</td>'
    +'<td class="num">'+esc(upd)+'</td>'
    +'<td'+cls+'>$'+c.toFixed(4)+'</td>'
    +'<td class="num">'+fmt(s.tokens_input)+'</td>'
    +'<td class="num">'+fmt(s.tokens_output)+'</td>'
    +'<td class="num">'+fmt(s.tokens_reasoning)+'</td>'
    +'<td class="num">'+dur(s)+'</td></tr>'
    +'<tr class="sdetail" data-for="'+id+'" hidden><td></td><td colspan="9" class="sdetail-cell"></td></tr>';
}
var bal=null;
function renderCost(c){
  if(c){var t=c.totals;
    document.getElementById('session').innerHTML=
      'session: '+esc(c.latest||'(none)')+' — '+
      (c.active?'<span class="live">● LIVE</span>':'<span class="idle">○ idle</span>');
    var balCell=bal&&bal.available?'<div class="stat"><b>$'+esc(bal.usd)+'</b><span>balance</span></div>':'';
    document.getElementById('stats').innerHTML=
      '<div class="stat"><b>$'+(+t.c).toFixed(4)+'</b><span>total cost</span></div>'+
      balCell+
      '<div class="stat"><b>'+t.n+'</b><span>sessions</span></div>'+
      '<div class="stat"><b>'+fmt(t.i)+'</b><span>tokens in</span></div>'+
      '<div class="stat"><b>'+fmt(t.o)+'</b><span>tokens out</span></div>'+
      '<div class="stat"><b>'+fmt(t.r)+'</b><span>reasoning</span></div>';
    if(sessOpenCount===0){
    var sh='<table><tr><th class="exp">↕</th><th>title</th><th>model</th><th>directory</th><th class="num">updated</th><th class="num">cost $</th><th class="num">in</th><th class="num">out</th><th class="num">reasoning</th><th class="num">dur</th></tr>';
    for(var i=0;i<c.sessions.length;i++){sh+=sessRow(c.sessions[i]);}
    sh+='</table><div class="muted" style="font-size:11px;margin-top:4px">in = tokens sent as context (the cost driver) · out = tokens generated · reasoning = chain-of-thought. Red = cost &ge; $0.10. click a row to drill down · <a href="/explore#board">Gantt of sessions over time ▸</a></div>';
    var sel=document.getElementById('sessions');
    sel.innerHTML=sh;
    if(drillId){var row=sel.querySelector('tr[data-id="'+drillId+'"]');if(row){row.style.background='#1f6feb33';}}
    }
  }else{failIfPristine('session','(status unavailable)');failIfPristine('stats','(cost unavailable)');failIfPristine('sessions','(sessions unavailable)');}
}
async function refreshCost(){ renderCost(await j('/api/cost')); }
function renderActivity(a){
  if(a){var h='';for(var i=0;i<a.length;i++){h+=item(a[i]);}
    document.getElementById('activity').innerHTML=h||'<div class="item">(no activity)</div>';}
  else{failIfPristine('activity','(activity unavailable)');}
}
async function refreshActivity(){ renderActivity(await j('/api/activity')); }
function renderTodos(td){
  if(td){var h2='';for(var k=0;k<td.length;k++){h2+='<div class="item"><span class="tag">'+esc(td[k].status)+'</span>'+esc(td[k].content)+'</div>';}
    document.getElementById('todos').innerHTML=h2||'<div class="item">(no todos)</div>';}
  else{failIfPristine('todos','(todos unavailable)');}
}
async function refreshTodos(){ renderTodos(await j('/api/todos')); }
async function refreshFlags(){
  // Rollup/flag strip: the four primitives the LLM-observability tools share
  // (trace drill, cost/latency rollups, annotations, sessions), rendered as
  // counts + example drill targets. Built from existing endpoints (no new
  // server code); each example links to its session via drill().
  var el=document.getElementById('flags');if(!el)return;
  var rr=await Promise.all([j('/api/cost'),j('/api/ops'),j('/api/health')]);
  var c=rr[0],o=rr[1],h=rr[2];
  var rows=[];
  if(c&&c.sessions){var hi=c.sessions.filter(function(s){return (+s.cost)>=0.10;});if(hi.length)rows.push(['cost',hi.length+' session(s) \u2265 $0.10',hi.slice(0,3).map(function(s){return {go:s.id,label:s.title||s.id,extra:'$'+(+s.cost).toFixed(3)};})]);}
  if(h&&h.risks&&h.risks.available){var ov=h.risks.over||[],dn=h.risks.denied||[];if(ov.length||dn.length)rows.push(['risk',ov.length+' over budget \u00b7 '+dn.length+' deny-listed',ov.slice(0,3).map(function(r){return {go:r.session,label:r.session,extra:Math.round((r.ratio||0)*100)+'%'};})]);}
  if(h&&h.findings){var st=h.findings.filter(function(f){return f.kind==='running_tool';});if(st.length)rows.push(['stall',st.length+' tool(s) stuck running',st.slice(0,3).map(function(f){return {go:f.session,label:f.session,extra:(f.tool||'?')+' '+(f.age_s||0)+'s'};})]);}
  if(o&&o.slow_endpoints&&o.slow_endpoints.length)rows.push(['slow',o.slow_endpoints.length+' slow endpoint(s)',o.slow_endpoints.slice(0,3).map(function(s){return {label:s.path,extra:s.ms+'ms'};})]);
  if(o&&o.errors_by_tool&&o.errors_by_tool.length){var te=0;for(var q=0;q<o.errors_by_tool.length;q++)te+=(o.errors_by_tool[q].n||0);rows.push(['error',te+' tool error(s)',o.errors_by_tool.slice(0,3).map(function(e){return {go:e.example_sid,label:e.tool,extra:'x'+e.n};})]);}
  var hh='';
  if(!rows.length){hh='<div class="item"><span class="tag">ok</span>no flags \u2014 nothing over budget, no stalls, no slow endpoints, no tool errors</div>';}
  for(var i=0;i<rows.length;i++){var r=rows[i];hh+='<div class="item"><span class="tag ERR">'+esc(r[0])+'</span><b>'+esc(r[1])+'</b>';
    for(var k=0;k<r[2].length;k++){var ex=r[2][k];hh+=' <span class="muted">'+(ex.go?('<a href="#" data-go="'+esc(ex.go)+'">'+esc(ex.label)+'</a>'):esc(ex.label))+(ex.extra?(' ('+esc(ex.extra)+')'):'')+'</span>';}
    hh+='</div>';}
  el.innerHTML=hh;
}
async function refreshBalance(){
  bal=await j('/api/balance');
  await refreshCost();
}
async function refreshConfig(){
  var c=await j('/api/config');
  var el=document.getElementById('config');
  if(!c){el.innerHTML='(no config audit)';return;}
  if(c.error){el.innerHTML='<span class="muted">'+esc(c.error)+'</span>';return;}
  var s=c.summary||{};
  var drift=(c.findings||[]).filter(function(f){return f.status!=='OK'&&f.status!=='SKIP';});
  var h='<span class="muted">ok='+s.ok+' warn='+s.warn+' error='+s.error+' fatal='+s.fatal+' skip='+s.skip+'</span>';
  if(drift.length){for(var i=0;i<drift.length;i++){var f=drift[i];h+='<div class="item"><span class="tag STEP">'+esc(f.status)+'</span>'+esc(f.key)+' — '+esc(f.actual)+' <span class="muted">→ '+esc(f.fix||'')+'</span></div>';}}
  else{h+='<div class="item">all settings match expected</div>';}
  el.innerHTML=h;
}
var drillId=null;
function drillItem(x){
  var cls=String(x.type||'').toUpperCase();
  var tag=(x.type==='step-start'||x.type==='step-finish')?'STEP':cls;
  if(x.type==='tool'&&x.status==='error'){tag=tag+' ERR';}
  else if(x.type==='tool'&&x.status==='running'){tag=tag+' RUN';}
  var body='';
  if(x.type==='tool'){body=esc(x.tool)+' ['+esc(x.status)+'] '+esc(x.cmd||'');}
  else if(x.type==='reasoning'||x.type==='text'){body=esc(String(x.text||'').slice(0,600));}
  else if(x.type==='patch'){body=esc(x.files||'');}
  var dur=Math.max(0,(x.te||x.ts||0)-(x.ts||0));
  return '<div class="item"><span class="tag '+tag+'">'+esc(x.type)+'</span>'+body+' <span class="muted">'+ts(x.ts)+(dur>0?(' +'+Math.round(dur)+'ms'):'')+'</span></div>';
}
async function drill(id){
  drillId=id;
  var d=await j('/api/session?id='+encodeURIComponent(id)+'&limit=60');
  var el=document.getElementById('drill');
  if(!d||d.error){el.innerHTML='<span class="muted">'+esc((d&&d.error)||'no data')+'</span>';return;}
  var s=d.session;
  document.getElementById('drill-id').textContent=s.title||'';
  var h='<div class="row">'
    +'<div class="stat"><b>$'+(+s.cost).toFixed(4)+'</b><span>cost</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_input)+'</b><span>in</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_output)+'</b><span>out</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_reasoning)+'</b><span>reasoning</span></div>'
    +'<div class="stat"><b>'+d.messages+'</b><span>messages</span></div>'
    +'<div class="stat"><b>'+dur(s)+'</b><span>span</span></div>'
    +'</div>';
  h+='<div class="muted" style="font-size:12px;margin:6px 0">download: '
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=txt">[txt]</a>'
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=md">[md]</a>'
    +'<a href="/api/export/session?id='+encodeURIComponent(id)+'&format=json">[json]</a></div>';
  var sp=d.parts.map(function(x){return Math.max(0,(x.te||x.ts||0)-(x.ts||0));});
  var totms=sp.reduce(function(a,b){return a+b;},0),slowms=Math.max.apply(null,[0].concat(sp));
  h+='<div class="muted" style="font-size:12px;margin:4px 0">spans: '+d.parts.length+' \u00b7 total '+Math.round(totms)+'ms \u00b7 slowest '+Math.round(slowms)+'ms (per-part te\u2212ts)</div>';
  for(var i=0;i<d.parts.length;i++){h+=drillItem(d.parts[i]);}
  el.innerHTML=h;
}
async function doSearch(){
  var q=document.getElementById('q').value.trim();
  var el=document.getElementById('searchres');
  if(!q){el.innerHTML='';return;}
  el.innerHTML='<span class="muted" data-loading>searching…</span>';
  var h='';
  var r=await j('/api/semantic?q='+encodeURIComponent(q)+'&limit=20',8000);
  if(r&&r.mode==='fts'){
    if(r.sessions&&r.sessions.length){h+='<div class="muted" style="font-size:11px">sessions</div>';
      for(var i=0;i<r.sessions.length;i++){var s=r.sessions[i];
        h+='<div class="item" data-go="'+esc(s.id)+'" style="cursor:pointer"><span class="tag STEP">session</span>'+esc(s.title)+' <span class="muted">$'+(+s.cost).toFixed(4)+'</span></div>';}}
    if(r.results&&r.results.length){h+='<div class="muted" style="font-size:11px">ranked matches</div>';
      for(var k=0;k<r.results.length;k++){var x=r.results[k];
        h+='<div class="item"'+(x.ocr?'':' data-go="'+esc(x.session)+'" style="cursor:pointer"')+'><span class="tag STEP">'+esc(x.ocr?'screenshot':(x.type||'part'))+'</span><span class="muted">'+esc(x.title||x.session)+'</span> — '+esc(x.snippet||'')+'</div>';}}
  } else {
    var f=await j('/api/search?q='+encodeURIComponent(q)+'&limit=20',8000);
    if(f&&f.sessions){for(var a=0;a<f.sessions.length;a++){var ss=f.sessions[a];
      h+='<div class="item" data-go="'+esc(ss.id)+'" style="cursor:pointer"><span class="tag STEP">session</span>'+esc(ss.title)+'</div>';}}
    if(f&&f.hits){for(var b=0;b<f.hits.length;b++){var y=f.hits[b];
      h+='<div class="item" data-go="'+esc(y.session)+'" style="cursor:pointer"><span class="tag STEP">'+esc(y.type)+'</span>'+esc(y.snippet)+'</div>';}}
  }
  el.innerHTML=h||'<span class="muted">no matches</span>';
}
document.getElementById('q').addEventListener('keydown',function(ev){if(ev.key==='Enter'){doSearch();}});
document.getElementById('searchres').addEventListener('click',function(ev){
  var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;
  if(t){drill(t.getAttribute('data-go'));}
});
document.getElementById('sessions').addEventListener('click',function(ev){
  var a=ev.target&&ev.target.closest?ev.target.closest('a.sopen'):null;
  if(a){return;}
  var ex=ev.target&&ev.target.closest?ev.target.closest('[data-exp]'):null;
  if(ex){toggleSessRow(ex.getAttribute('data-exp'));return;}
  var tr=ev.target&&ev.target.closest?ev.target.closest('tr.srow'):null;
  if(tr){toggleSessRow(tr.getAttribute('data-id'));}
});
document.getElementById('sessions').addEventListener('keydown',function(ev){
  var ex=ev.target&&ev.target.closest?ev.target.closest('[data-exp]'):null;
  if(ex&&(ev.key==='Enter'||ev.key===' ')){ev.preventDefault();toggleSessRow(ex.getAttribute('data-exp'));}
});
document.getElementById('flags').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){ev.preventDefault();drill(t.getAttribute('data-go'));}});
var want=new URLSearchParams(location.search).get('session');
if(want){drill(want);}
refreshBalance();
refreshConfig();
// Keyboard: '/' focuses search, Escape blurs. Never hijacks typing.
document.addEventListener('keydown',function(ev){
  var t=ev.target&&(ev.target.tagName||'').toLowerCase();
  if(t==='input'||t==='textarea'||t==='select')return;
  if(ev.key==='/'){var q=document.getElementById('q');if(q){ev.preventDefault();q.focus();}}
  else if(ev.key==='Escape'&&document.activeElement&&document.activeElement.blur){document.activeElement.blur();}
});
// Polling: 5 s glance cadence (server TTLs are coarser, so this is cheap).
// The in-flight guard never stacks a second request. The first tick fires
// immediately, and polling does NOT pause when the tab reports hidden — an
// embedded/preview viewer often reports hidden and never fires
// visibilitychange, which made the page look frozen until a manual reload.
function poll(fn,ms){
  var inflight=false;
  function tick(){
    if(inflight)return;
    inflight=true;
    Promise.resolve().then(fn).catch(function(){}).then(function(){inflight=false;});
  }
  tick();
  setInterval(tick,ms);
  document.addEventListener('visibilitychange',function(){tick();});
}
if(typeof EventSource!=='undefined'){
  // snapshot -> deltas (durable-pi): one server-side loop feeds every client;
  // reconnect gets a fresh snapshot. Falls back to polling if SSE is absent.
  var _es=new EventSource('/api/stream');
  var _onflow=function(ev){try{var p=JSON.parse(ev.data);}catch(e){return;}
    // One stale/malformed pane must not starve the other two into "loading...".
    try{renderCost(p.cost);}catch(e){}
    try{renderActivity(p.activity);}catch(e){}
    try{renderTodos(p.todos);}catch(e){}
  };
  _es.addEventListener('snapshot',_onflow);
  _es.addEventListener('delta',_onflow);
}else{
  poll(refreshCost,8000);
  poll(refreshActivity,8000);
  poll(refreshTodos,15000);
}
poll(refreshFlags,30000);
poll(refreshBalance,60000);
poll(refreshConfig,60000);
document.querySelectorAll('[data-tz]').forEach(function(e){e.textContent='(times '+tzname()+')';});
</script></body></html>`;

const exploreHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode explore</title>
<script src="/vendor/d3.min.js"></script>
<script src="/vendor/d3-sankey.min.js"></script>
<script src="/vendor/plot.umd.min.js"></script>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 4px} h2{font-size:13px;color:#8b949e;margin:16px 0 6px}
 a{color:#58a6ff;text-decoration:none;font-size:13px}
 .chart{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;margin:6px 0;overflow-x:auto}
 #stable{max-height:58vh;overflow:auto}
 .tip{position:absolute;background:#21262d;border:1px solid #30363d;padding:6px 8px;border-radius:4px;font-size:12px;pointer-events:none;opacity:0;max-width:420px;z-index:10}
 .muted{color:#8b949e;font-size:12px}
 button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:3px 9px;font-size:12px;cursor:pointer}
 svg text{font-family:system-ui,monospace}
 .axis path,.axis line{stroke:#30363d}
 .grid line{stroke:#21262d;stroke-dasharray:2 3}
 .grid path{display:none}
 .lbl{font-size:11px;fill:#8b949e}
 .card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:12px;margin:8px 0}
 input{background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px;width:100%;box-sizing:border-box}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:3px 8px;border-bottom:1px solid #21262d;white-space:nowrap}
 th{color:#8b949e;font-weight:600;cursor:pointer;user-select:none}
 .num{text-align:right;font-variant-numeric:tabular-nums}
  tr.row{cursor:pointer}
  tr.row:hover{background:#1f6feb22}
  tr.row.selected{background:#1f6feb33}
 .item{padding:4px 0;border-bottom:1px solid #21262d;font-size:12px;cursor:pointer}
 .item:hover{background:#1f6feb22}
 .tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;margin-right:6px;background:#30363d;color:#8b949e}
 .ERR{background:#b6232433;color:#ff7b72;font-weight:600}
 .tabs{display:flex;gap:6px;flex-wrap:wrap;position:sticky;top:40px;z-index:25;background:#0d1117;padding:6px 0;margin:6px 0;border-bottom:1px solid #30363d}
 .tab{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:5px 14px;font-size:12px;color:#8b949e;cursor:pointer}
 .tab.active{background:#1f6feb;color:#fff;border-color:#1f6feb}
 .tbadge{display:inline-block;min-width:18px;text-align:center;font-size:10px;background:#30363d;color:#e6edf3;border-radius:9px;padding:0 5px;margin-left:5px}
 .tbadge:empty{display:none}
 #detail-card.collapsed #detail{display:none}
 #detail-head{cursor:pointer}
 #scatter circle{cursor:pointer}
 #gantt rect{cursor:pointer}
 .row{display:flex;flex-wrap:wrap;gap:10px;margin:6px 0}
 .stat{flex:1;min-width:90px;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:8px}
 .stat b{display:block;font-size:16px}
 .stat span{color:#8b949e;font-size:11px}
 .kanban{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
 .kcol{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:8px;min-height:60px}
 .khead{font-size:12px;color:#8b949e;font-weight:600;margin-bottom:6px}
 .kcard{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:5px 7px;margin:4px 0;font-size:12px;word-break:break-word}
 .kcard .tag{font-size:10px;padding:0 5px}
 .pane[hidden]{display:none}
 h3{font-size:12px;color:#8b949e;margin:14px 0 6px}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("explore")}
<main id="main" tabindex="-1">
<h1>opencode explore</h1>
<div class="muted" id="filter">filter: all time</div> <button id="brush-reset">reset filter</button>
<div class="tabs" id="tabs" role="tablist" aria-label="Explore views">
  <button class="tab active" data-tab="overview" role="tab" id="tab-overview" aria-selected="true" aria-controls="pane-overview">overview <span class="tbadge" data-badge="overview"></span></button>
  <button class="tab" data-tab="board" role="tab" id="tab-board" aria-selected="false" aria-controls="pane-board">board · gantt <span class="tbadge" data-badge="board"></span></button>
  <button class="tab" data-tab="charts" role="tab" id="tab-charts" aria-selected="false" aria-controls="pane-charts">charts <span class="tbadge" data-badge="charts"></span></button>
  <button class="tab" data-tab="signals" role="tab" id="tab-signals" aria-selected="false" aria-controls="pane-signals">signals <span class="tbadge" data-badge="signals"></span></button>
  <button class="tab" data-tab="patterns" role="tab" id="tab-patterns" aria-selected="false" aria-controls="pane-patterns">patterns <span class="tbadge" data-badge="patterns"></span></button>
  <button class="tab" data-tab="code" role="tab" id="tab-code" aria-selected="false" aria-controls="pane-code">code <span class="tbadge" data-badge="code"></span></button>
  <button class="tab" data-tab="data" role="tab" id="tab-data" aria-selected="false" aria-controls="pane-data">data <span class="tbadge" data-badge="data"></span></button>
  <button class="tab" data-tab="ocr" role="tab" id="tab-ocr" aria-selected="false" aria-controls="pane-ocr">ocr <span class="tbadge" data-badge="ocr"></span></button>
  <button class="tab" data-tab="ops" role="tab" id="tab-ops" aria-selected="false" aria-controls="pane-ops">ops <span class="tbadge" data-badge="ops"></span></button>
</div>
<div class="muted" id="landing" style="margin:2px 0 8px"><span class="muted" data-loading>loading...</span></div>
<div class="card" id="detail-card" hidden style="border-color:#d29922"><h2 style="margin-top:0" id="detail-head">Session detail <button id="detail-close">close</button></h2><div id="detail"></div></div>
<div class="pane" data-pane="overview" id="pane-overview" role="tabpanel" aria-labelledby="tab-overview">
<div class="card"><h2 style="margin-top:0">Search everything</h2><input id="q2" placeholder="search titles, message text, and tool commands (ranked)" aria-label="Search everything"><div id="sres"></div></div>
<h2>Sessions — sortable, filterable, click to open</h2>
<div class="chart"><input id="tfilter" placeholder="filter sessions by title, model, directory or project..." aria-label="Filter sessions by title, model, directory or project" style="max-width:360px"> <span id="tcount" class="muted"></span><div id="stable"><span class="muted" data-loading>loading...</span></div></div>
</div>
<div class="pane" data-pane="code" id="pane-code" role="tabpanel" aria-labelledby="tab-code" hidden>
<h2>Code — repo files flagged by the database (scripts/code-index.py)</h2>
<div class="chart" id="code"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="data" id="pane-data" role="tabpanel" aria-labelledby="tab-data" hidden>
<h2>Duplicates — near-identical sessions</h2>
<div class="chart" id="dupes"><span class="muted" data-loading>loading...</span></div>
<h2>Integrations — Jev (hosted) vs Laya (self-hosted)</h2>
<div class="chart" id="integrations"><span class="muted" data-loading>loading...</span></div>
<h2>Jev vs Laya — A/B runs (persisted)</h2>
<div class="chart" id="ab"><span class="muted" data-loading>loading...</span></div>
<h2>Database map — tables sized by rows, edges = foreign keys</h2>
<div class="chart" id="dmap"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="charts" id="pane-charts" role="tabpanel" aria-labelledby="tab-charts" hidden>
<h2>Where the money goes — sessions sized by cost, grouped by model</h2>
<div class="chart" id="treemap"><span class="muted" data-loading>loading...</span></div>
<h2>Cumulative spend vs budget — drag to filter the views below</h2>
<h3>Trends — sessions &amp; cost per day</h3>
<div class="chart" id="trends" role="img" aria-label="Sessions and cost per day"><span class="muted" data-loading>loading...</span></div>
<div class="chart" id="burn"><span class="muted" data-loading>loading...</span></div>
<h2>Latency x cost — radius = tokens, colour = model (outliers are bottlenecks)</h2>
<div class="chart" id="scatter"><span class="muted" data-loading>loading...</span></div>
<h2>Token flow — where the tokens go, by model</h2>
<div class="chart" id="sankey"><span class="muted" data-loading>loading...</span></div>
<h2>Sessions over time — bar colour = cost (click to load the part timeline)</h2>
<div class="chart" id="gantt"><span class="muted" data-loading>loading...</span></div>
<h2>Part timeline — <span id="tl-title">latest session</span> <button id="tl-reset">reset</button></h2>
<div class="chart" id="timeline"><span class="muted" data-loading>loading...</span></div>
<h2>Word cloud — recurring terms in reasoning &amp; text</h2>
<div class="chart" id="cloud"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="signals" id="pane-signals" role="tabpanel" aria-labelledby="tab-signals" hidden>
<h2>Session health — stalled / blank turns (read-only, browser-independent)</h2>
<div class="chart" id="health"><span class="muted" data-loading>loading...</span></div>
<h2>Signals — mistakes, rule mentions, churn</h2>
<div class="chart" id="signals"><span class="muted" data-loading>loading...</span></div>
<h2>Blacklist guard — blocked / fixed during "Thinking" <a href="/api/export/guard" aria-label="[csv] guard blocks">[csv]</a></h2>
<div class="chart" id="guard"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="patterns" id="pane-patterns" role="tabpanel" aria-labelledby="tab-patterns" hidden>
<h2>Patterns — recurring tool-sequence n-grams <a href="/api/export/patterns" aria-label="[csv] patterns">[csv]</a></h2>
<div class="chart" id="patterns"><span class="muted" data-loading>loading...</span></div>
<h2>Pivot — from tool &times; to tool (bigram matrix, Observable Plot)</h2>
<div class="chart" id="pivot"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="ocr" id="pane-ocr" role="tabpanel" aria-labelledby="tab-ocr" hidden>
<h2>OCR — screenshot text (searchable)</h2>
<div class="chart" id="ocr"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="ops" id="pane-ops" role="tabpanel" aria-labelledby="tab-ops" hidden>
<h2>Ops — hotspots, bottlenecks, failures, successes (click a row to drill down)</h2>
<div class="chart" id="ops"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="pane" data-pane="board" id="pane-board" role="tabpanel" aria-labelledby="tab-board" hidden>
<h2>Board — Kanban (state) + Gantt (time), straight from the databases</h2>
<div class="muted" style="font-size:11px">provenance — <b>db</b> = opencode todo ⨝ session (measured) · <b>md</b> = TODO.md queue (declared) · <b>derived</b> = heuristic estimate (labelled, not a promise)</div>
<h3>Kanban — task state (pending / in-progress / completed)</h3>
<div id="kanban" class="kanban" role="list" aria-label="Kanban columns"><span class="muted" data-loading>loading...</span></div>
<h3>Gantt — realized sessions over time (time_created → time_updated), resources per bar (click a bar to drill in)</h3>
<div class="chart" id="boardgantt" role="img" aria-label="Gantt of realized sessions over time"><span class="muted" data-loading>loading...</span></div>
<div class="muted" id="board-estimates" style="font-size:11px"></div>
<h3>Projected schedule — outstanding tasks (heuristic estimate, not a promise)</h3>
<div class="chart" id="board-estimategantt" role="img" aria-label="Estimated schedule of outstanding tasks"><span class="muted" data-loading>loading...</span></div>
<h3>Milestones — gate / advisory events (observability ledger)</h3>
<div id="board-tables"><span class="muted" data-loading>loading...</span></div>
</div>
<div class="tip" id="tip" role="note"></div>
</main>
<script>
function fmt(n){n=Number(n)||0;return n>=1000?(n/1000).toFixed(1)+'k':''+n;}
async function j(u){try{var r=await fetch(u);return r.ok?r.json():null;}catch(e){return null;}}
var colors={tool:'#58a6ff',reasoning:'#d2a8ff',text:'#7ee787','step-start':'#8b949e','step-finish':'#8b949e',patch:'#ff7b72'};
function tip(html){var t=d3.select('#tip');if(html==null){t.style('opacity',0);return;}t.html(html).style('opacity',1);}
function moveTip(ev){d3.select('#tip').style('left',(ev.clientX+14)+'px').style('top',(ev.clientY+14)+'px');}
// Keyboard twin of moveTip: position the tooltip at the focused mark, so a
// screen-reader/keyboard user gets the same text a hover shows.
function focusTip(ev,html){try{var r=ev.currentTarget.getBoundingClientRect();d3.select('#tip').style('left',(r.left+8)+'px').style('top',(r.top+8)+'px');tip(html);}catch(e){tip(html);}}
function timeFmt(d){var x=new Date(Number(d));return x.toLocaleTimeString(undefined,{hour12:false,hour:'2-digit',minute:'2-digit'});}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function ts(t){var d=new Date(Number(t));return d.toLocaleTimeString(undefined,{hour12:false,hour:'2-digit',minute:'2-digit',second:'2-digit'})+'.'+((function(n){n=String(n);return n.length<3?('00'+n).slice(-3):n;})(d.getMilliseconds()));}
function modelId(m){if(!m)return '(none)';try{var o=JSON.parse(m);return o.id||o.modelID||m;}catch(e){return String(m);}}
function span(d){var a=Number(d.p_start||0),b=Number(d.p_end||0);if(b>a)return b-a;return Math.max(0,Number(d.time_updated||0)-Number(d.time_created||0));}
var MODEL_COLOR=null,COST=null;
var DATA=[],BUDGET=0,FILTER=[0,Infinity];
function inFilter(d){var t=d.time_created;return t>=FILTER[0]&&t<=FILTER[1];}
function setFilterText(){
  var el=document.getElementById('filter');
  if(!el)return;
  el.textContent=(FILTER[1]===Infinity)?'filter: all time':('filter: '+new Date(FILTER[0]).toLocaleString(undefined,{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false})+' to '+new Date(FILTER[1]).toLocaleString(undefined,{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}));
}
var HEALTH_SUMMARY='';
function setBadge(name,text){var el=document.querySelector('[data-badge="'+name+'"]');if(el)el.textContent=text;}
function renderLanding(){
  // One-line answer to "where do I start": totals from already-loaded
  // DATA, health verdict from the last /api/health render, filter state
  // from #filter. No new fetches — called after table/health renders
  // and on every filter change.
  var el=document.getElementById('landing');if(!el||!DATA)return;
  var cost=0,i;for(i=0;i<DATA.length;i++){cost+=(+DATA[i].cost||0);}
  var f=document.getElementById('filter');
  el.textContent=DATA.length+' sessions · $'+cost.toFixed(2)+' total'+(HEALTH_SUMMARY?' · '+HEALTH_SUMMARY:'')+(f&&f.textContent?' · '+f.textContent:'');
}
var SORT={col:'cost',dir:-1},TFILTER='';
async function renderIntegrations(){
  var el=d3.select('#integrations');el.selectAll('*').remove();
  var d=await j('/api/integrations');
  if(!d){el.text('(no data)');return;}
  var max=Math.max(1,d.jev,d.laya);
  var W=1000,H=132;
  var x=d3.scaleLinear().domain([0,max]).range([0,600]);
  var rows=[['Jev (hosted)',d.jev,'#d2a8ff'],['Laya (self-hosted)',d.laya,'#7ee787']];
  var svg=el.append('svg').attr('width',W).attr('height',H);
  var g=svg.selectAll('g').data(rows).enter().append('g').attr('transform',function(d,i){return 'translate(140,'+(28+i*32)+')';});
  g.append('text').attr('x',-12).attr('text-anchor','end').attr('dy','0.35em').attr('class','lbl').text(function(d){return d[0];});
  g.append('rect').attr('height',16).attr('rx',2).attr('width',function(d){return Math.max(1,x(d[1]));}).attr('fill',function(d){return d[2];}).attr('fill-opacity',0.7);
  g.append('text').attr('x',function(d){return x(d[1])+6;}).attr('dy','0.35em').attr('class','lbl').text(function(d){return d[1]+' calls';});
  if(d.laya===0){svg.append('text').attr('x',140).attr('y',H-8).attr('class','lbl').text('Laya self-host not configured yet — run the "laya" runbook to enable the A/B comparison.');}
}
async function renderAb(){
  var el=d3.select('#ab');el.selectAll('*').remove();
  var d=await j('/api/ab?limit=200');
  if(!d||!d.runs||!d.runs.length){el.text('no A/B runs yet — run ./scripts/test-jev-laya-ab.sh to populate');return;}
  var s=d.summary;
  var rows=d.runs.slice().reverse();
  var H=Math.max(150,70+rows.length*18);
  var W=1000;
  var y=d3.scaleBand().domain(rows.map(function(r){return r.ts;})).range([24,H-6]).padding(0.25);
  var max=Math.max(0.001,d3.max(rows,function(r){return Math.max(Number(r.jev_latency)||0,Number(r.laya_latency)||0);})||0.001);
  var x=d3.scaleLinear().domain([0,max]).range([0,660]);
  var svg=el.append('svg').attr('width',W).attr('height',H);
  svg.append('text').attr('x',0).attr('y',12).attr('class','lbl').text('runs '+s.n+' · jev ok '+s.jevOk+' · laya ok '+s.layaOk+' · identical '+s.same+' / differ '+s.differ+' · avg latency jev '+s.jevLatency.toFixed(2)+'s / laya '+s.layaLatency.toFixed(2)+'s · correctness jev '+(s.jevCorrectness==null?'—':s.jevCorrectness.toFixed(2))+' / laya '+(s.layaCorrectness==null?'—':s.layaCorrectness.toFixed(2))+' (n='+s.comparable+')');
  var g=svg.selectAll('g.run').data(rows).enter().append('g').attr('transform',function(r){return 'translate(300,'+y(r.ts)+')';});
  g.append('text').attr('x',-8).attr('text-anchor','end').attr('class','lbl').text(function(r){return String(r.ts).slice(5,19);});
  g.append('rect').attr('height',6).attr('rx',1).attr('width',function(r){return Math.max(1,x(Number(r.jev_latency)||0));}).attr('fill','#d2a8ff').attr('fill-opacity',0.85);
  g.append('rect').attr('y',8).attr('height',6).attr('rx',1).attr('width',function(r){return Math.max(1,x(Number(r.laya_latency)||0));}).attr('fill','#7ee787').attr('fill-opacity',0.85);
  g.append('text').attr('x',function(r){return x(Math.max(Number(r.jev_latency)||0,Number(r.laya_latency)||0))+8;}).attr('y',8).attr('class','lbl').text(function(r){var c=function(v){return v==null?'—':(+v).toFixed(2);};return (r.same===1?'identical':(r.same===0?'differ':'n/a'))+' · jev '+c(r.jev_correctness)+' / laya '+c(r.laya_correctness);});
}
async function renderSchema(){
  var el=d3.select('#dmap');el.selectAll('*').remove();
  var s=await j('/api/schema');
  if(!s||!s.tables||!s.tables.length){el.text('(no schema)');return;}
  var W=1000,H=420;
  var nodes=s.tables.map(function(t){return {id:t.name,rows:t.rows,r:4+Math.sqrt(t.rows+1)};});
  var idx={};nodes.forEach(function(n,i){idx[n.id]=i;});
  var links=s.edges.filter(function(e){return idx[e.src]!=null&&idx[e.dst]!=null;}).map(function(e){return {source:idx[e.src],target:idx[e.dst]};});
  var svg=el.append('svg').attr('width',W).attr('height',H);
  var link=svg.append('g').selectAll('line').data(links).enter().append('line').attr('stroke','#30363d');
  var node=svg.append('g').selectAll('g').data(nodes).enter().append('g');
  node.append('circle').attr('r',function(d){return d.r;}).attr('fill','#1f6feb').attr('fill-opacity',0.45).attr('stroke','#79c0ff');
  node.append('text').attr('x',function(d){return d.r+3;}).attr('dy','0.35em').attr('class','lbl').text(function(d){return d.id+'  '+d.rows;});
  var sim=d3.forceSimulation(nodes)
    .force('link',d3.forceLink(links).distance(72).strength(0.6))
    .force('charge',d3.forceManyBody().strength(-260))
    .force('center',d3.forceCenter(W/2,H/2))
    .force('collide',d3.forceCollide().radius(function(d){return d.r+24;}))
    .on('tick',function(){
      link.attr('x1',function(d){return d.source.x;}).attr('y1',function(d){return d.source.y;}).attr('x2',function(d){return d.target.x;}).attr('y2',function(d){return d.target.y;});
      node.attr('transform',function(d){return 'translate('+d.x+','+d.y+')';});
    });
  sim.alpha(1).restart();
}
function tableRows(){
  var rows=DATA.filter(inFilter);
  if(TFILTER){var q=TFILTER.toLowerCase();rows=rows.filter(function(d){return String(d.title||'').toLowerCase().indexOf(q)>=0||modelId(d.model).toLowerCase().indexOf(q)>=0||String(d.directory||'').toLowerCase().indexOf(q)>=0||String(d.project||'').toLowerCase().indexOf(q)>=0;});}
  var col=SORT.col,dir=SORT.dir;
  rows.sort(function(a,b){
    var x,y;
    if(col==='model'){x=modelId(a.model);y=modelId(b.model);}
    else{x=a[col];y=b[col];}
    if(typeof x==='number'||typeof y==='number'){x=+x||0;y=+y||0;}
    else{x=String(x||'').toLowerCase();y=String(y||'').toLowerCase();}
    return (x>y?1:x<y?-1:0)*dir;
  });
  return rows;
}
function renderTable(){
  var el=d3.select('#stable');el.selectAll('*').remove();
  var rows=tableRows();
  var tc=document.getElementById('tcount');if(tc)tc.textContent=rows.length+' of '+DATA.length+' sessions';
  setBadge('overview',rows.length);renderLanding();
  var cols=[['title','title'],['model','model'],['directory','dir'],['project','project'],['time_updated','updated'],['cost','cost $'],['tokens_input','in'],['tokens_output','out'],['tokens_reasoning','reason'],['tokens_cache_read','cache'],['_span','span']];
  var table=el.append('table');
  table.append('caption').text('sessions — activate a column header to sort');
  var sortBy=function(c){if(SORT.col===c)SORT.dir=-SORT.dir;else{SORT.col=c;SORT.dir=-1;}renderTable();};
  table.append('tr').selectAll('th').data(cols).enter().append('th')
    .text(function(d){return (d[0]===SORT.col?'▾ ':'')+d[1];})
    .attr('scope','col')
    .attr('tabindex','0')
    .attr('aria-sort',function(d){return d[0]===SORT.col?(SORT.dir===-1?'descending':'ascending'):null;})
    .style('text-decoration',function(d){return d[0]===SORT.col?'underline':'none';})
    .on('click',function(ev,d){sortBy(d[0]);})
    .on('keydown',function(ev,d){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();sortBy(d[0]);}});
  var tr=table.selectAll('tr.row').data(rows).enter().append('tr').attr('class','row')
    .attr('data-od-id',function(d){return 'session:'+d.id;})
    .on('click',function(ev,d){document.querySelectorAll('#stable tr.selected').forEach(function(r){r.classList.remove('selected');});if(ev.currentTarget&&ev.currentTarget.classList)ev.currentTarget.classList.add('selected');detail(d.id);});
  tr.append('td').text(function(d){return d.title||'(untitled)';});
  tr.append('td').text(function(d){return modelId(d.model);});
  tr.append('td').text(function(d){var s=String(d.directory||'');return s.length>48?'…'+s.slice(-47):s;});
  tr.append('td').text(function(d){var s=String(d.project||'');return s.length>48?'…'+s.slice(-47):s;});
  tr.append('td').attr('class','num').text(function(d){return d.time_updated?new Date(Number(d.time_updated)).toLocaleString():'';});
  tr.append('td').attr('class','num').text(function(d){return '$'+(+d.cost).toFixed(4);});
  tr.append('td').attr('class','num').text(function(d){return fmt(d.tokens_input);});
  tr.append('td').attr('class','num').text(function(d){return fmt(d.tokens_output);});
  tr.append('td').attr('class','num').text(function(d){return fmt(d.tokens_reasoning);});
  tr.append('td').attr('class','num').text(function(d){return fmt(d.tokens_cache_read);});
  tr.append('td').attr('class','num').text(function(d){return (d._span/1000).toFixed(0)+'s';});
}
async function doSearch2(){
  var q=(document.getElementById('q2').value||'').trim();
  var el=document.getElementById('sres');
  if(!q){el.innerHTML='';return;}
  var r=await j('/api/semantic?q='+encodeURIComponent(q)+'&limit=15');
  var h='';
  if(r&&r.results){for(var i=0;i<r.results.length;i++){var x=r.results[i];
    h+='<div class="item"'+(x.ocr?'':' data-go="'+esc(x.session)+'"')+'><span class="tag">'+esc(x.ocr?'screenshot':(x.type||'part'))+'</span><span class="muted">'+esc(x.title||x.session)+'</span> — '+esc(x.snippet||'')+'</div>';}}
  el.innerHTML=h||'<span class="muted">no matches</span>';
}
document.getElementById('q2').addEventListener('keydown',function(ev){if(ev.key==='Enter'){doSearch2();}});
document.getElementById('sres').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
document.getElementById('tfilter').addEventListener('input',function(){TFILTER=this.value;renderTable();});
async function detail(id){
  var card=document.getElementById('detail-card');if(card){card.hidden=false;card.classList.remove('collapsed');}
  var el=document.getElementById('detail');
  el.innerHTML='<span class="muted">loading...</span>';
  var d=await j('/api/session?id='+encodeURIComponent(id)+'&limit=60');
  if(!d||d.error){el.innerHTML='<span class="muted">'+esc((d&&d.error)||'no data')+'</span>';return;}
  var s=d.session;
  var h='<div class="row">'
    +'<div class="stat"><b>$'+(+s.cost).toFixed(4)+'</b><span>cost</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_input)+'</b><span>in</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_output)+'</b><span>out</span></div>'
    +'<div class="stat"><b>'+fmt(s.tokens_reasoning)+'</b><span>reasoning</span></div>'
    +'<div class="stat"><b>'+d.messages+'</b><span>messages</span></div>'
    +'<div class="stat"><b>'+esc(modelId(s.model))+'</b><span>model</span></div>'
    +'</div>';
  h+='<div class="muted" style="font-size:12px;margin:6px 0">'+esc(s.title||'')
    +' · <a href="/?session='+encodeURIComponent(id)+'">full transcript</a>'
    +' · <a href="/api/export/session?id='+encodeURIComponent(id)+'&format=md">download md</a></div>';
  h+='<div style="max-height:340px;overflow:auto">';
  for(var i=0;i<d.parts.length;i++){var x=d.parts[i];
    var body=x.type==='tool'?(esc(x.tool)+' ['+esc(x.status)+'] '+esc(x.cmd||'')):((x.type==='reasoning'||x.type==='text')?esc(String(x.text||'').slice(0,300)):esc(x.files||''));
    h+='<div class="item"><span class="tag">'+esc(x.type)+'</span>'+body+' <span class="muted">'+ts(x.ts)+'</span></div>';}
  h+='</div>';
  el.innerHTML=h;
  var card=document.getElementById('detail');
  if(card&&card.scrollIntoView)card.scrollIntoView({block:'nearest'});
}
async function renderSignals(){
  var el=d3.select('#signals');el.selectAll('*').remove();
  var d=await j('/api/signals');
  if(!d){el.text('(no data)');return;}
  var sig=Object.keys(d.signatures).map(function(k){return esc(k)+'='+d.signatures[k];}).join(', ');
  var rules=Object.keys(d.ruleMentions).map(function(k){return esc(k)+'='+d.ruleMentions[k];}).join(', ');
  var h='<div class="muted" style="font-size:12px">'+d.errorCount+' error tool calls · signatures: '+sig+'</div>';
  h+='<div class="muted" style="font-size:12px">rule mentions: '+rules+'</div>';
  if(d.patches&&d.patches.length){h+='<div class="muted" style="font-size:12px">churn (patch files): '+d.patches.slice(0,6).map(function(p){return esc(String(p.files||'').slice(0,70))+' x'+p.n;}).join(' · ')+'</div>';}
  for(var i=0;i<d.errors.length;i++){var e=d.errors[i];
    h+='<div class="item" data-go="'+esc(e.sid)+'"><span class="tag">error</span>'+esc(e.tool||'')+' '+esc(String(e.detail||'').slice(0,110))+' <span class="muted">'+esc(e.title||'')+'</span></div>';}
  el.html(h);
}
async function renderPatterns(){
  var el=d3.select('#patterns');el.selectAll('*').remove();
  var d=await j('/api/patterns?limit=30');
  setBadge('patterns',d&&d.ngrams?d.ngrams.length:0);
  if(!d||!d.ngrams||!d.ngrams.length){el.text('no tool sequences yet');return;}
  var max=d.ngrams[0].n||1;
  var h='<div class="muted" style="font-size:12px">'+d.distinct+' distinct tools · top tool-sequence bigrams</div>';
  for(var i=0;i<d.ngrams.length;i++){var g=d.ngrams[i];
    var w=Math.max(2,Math.round(100*g.n/max));
    h+='<div style="display:flex;align-items:center;gap:8px;margin:3px 0'+(g.example_sid?';cursor:pointer':'')+'"'+(g.example_sid?' data-go="'+esc(g.example_sid)+'" title="drill into an example session"':'')+'><span style="width:220px;font-size:12px">'+esc(g.gram)+'</span><span style="display:inline-block;height:10px;width:'+w+'%;max-width:420px;background:#2ea043;border-radius:4px"></span><span class="muted">'+g.n+'</span></div>';
  }
  if(d.errorTools&&d.errorTools.length){
    h+='<div class="muted" style="font-size:12px;margin-top:10px">error tool calls</div>';
    for(var k=0;k<d.errorTools.length;k++){var e=d.errorTools[k];
      h+='<div class="item"'+(e.example_sid?' data-go="'+esc(e.example_sid)+'" style="cursor:pointer"':'')+'><span class="tag">error</span>'+esc(e.tool)+' x'+e.n+'</div>';}
  }
  var s=await j('/api/solutions');
  if(s&&s.issues&&s.issues.length){
    h+='<div class="muted" style="font-size:12px;margin-top:10px">known fixes — issue &rarr; next successful action</div>';
    for(var z=0;z<Math.min(5,s.issues.length);z++){var it=s.issues[z];var fx=(it.fixes&&it.fixes[0])||{};
      h+='<div class="item"><span class="tag">fix</span>'+esc(String(it.signature||'').slice(0,60))+' &rarr; '+esc(fx.tool||'?')+' '+esc(String(fx.command||'').slice(0,50))+'</div>';}
  }
  el.html(h);
}
async function renderPivot(){
  var host=document.getElementById('pivot');
  if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  var d=await j('/api/patterns?limit=200');
  if(!d||!d.ngrams||!d.ngrams.length){host.textContent='no tool sequences yet';return;}
  if(d.ngrams[0].from==null){host.textContent='patterns endpoint has no from/to columns';return;}
  var froms=[],tos=[],seenF={},seenT={},i;
  for(i=0;i<d.ngrams.length;i++){var g=d.ngrams[i];
    if(!seenF[g.from]){seenF[g.from]=1;froms.push(g.from);}
    if(!seenT[g.to]){seenT[g.to]=1;tos.push(g.to);}}
  var rows=[];for(i=0;i<d.ngrams.length;i++){rows.push({from:d.ngrams[i].from,to:d.ngrams[i].to,n:Number(d.ngrams[i].n)||0,example_sid:d.ngrams[i].example_sid||null});}
  var span=Math.max(froms.length,tos.length);
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:Math.min(820,140+110*span),
    height:Math.min(600,110+30*span),
    marginLeft:90,marginTop:20,
    color:{scheme:'greens',legend:true,label:'count'},
    x:{label:'to tool',domain:tos,tickRotate:-35},
    y:{label:'from tool',domain:froms},
    marks:[
      Plot.cell(rows,{x:'to',y:'from',fill:'n',href:function(r){return r.example_sid?('/?session='+encodeURIComponent(r.example_sid)):null;},title:function(r){return r.from+' → '+r.to+': '+r.n+(r.example_sid?' (click to drill)':'');}}),
      Plot.text(rows,{x:'to',y:'from',text:function(r){return r.n;},fill:'#0d1117',fontSize:10,fontWeight:600})
    ]
  }));
}
document.getElementById('pivot').addEventListener('click',function(ev){var a=ev.target&&ev.target.closest?ev.target.closest('a[href*="session="]'):null;if(!a)return;var m=/[?&]session=([^&]+)/.exec(a.getAttribute('href')||a.getAttribute('xlink:href')||'');if(m){ev.preventDefault();detail(decodeURIComponent(m[1]));}});
async function renderCode(){
  var el=d3.select('#code');el.selectAll('*').remove();
  var d=await j('/api/code?limit=400');
  setBadge('code',d&&d.files?d.files.length:0);
  if(!d||d.available===false||!d.files||!d.files.length){el.text('no code index yet - run ./scripts/code-index.py');return;}
  var parts=[];for(var i=0;i<d.flags.length;i++){parts.push(esc(d.flags[i].name)+'='+d.flags[i].n);}
  var h='<div class="muted" style="font-size:12px">'+d.files.length+' files · '+parts.join(', ')+'</div>';
  for(var k=0;k<d.files.length;k++){var f=d.files[k];if(!f.flags_n)continue;
    h+='<div class="item"><span class="tag">'+f.flags_n+' flagged</span>'+esc(f.path)+' <span class="muted">'+esc(String(f.symbols||'').slice(0,70))+'</span></div>';}
  el.html(h);
}
async function renderHealth(){
  var el=d3.select('#health');el.selectAll('*').remove();
  var d=await j('/api/health');
  if(!d||d.available===false||!d.findings){el.text('no session-health data');return;}
  var c=d.counts||{};
  var h='<div class="muted" style="font-size:12px">'+esc(String(c.sessions_scanned||0))+' sessions scanned · running '+esc(String(c.running_tools||0))+' · blank '+esc(String(c.blank_tails||0))+(c.dead_tools?' · dead '+esc(String(c.dead_tools)):'')+(c.dead_blanks?' · dead-blank '+esc(String(c.dead_blanks)):'')+'</div>';
  if(d.handoff&&d.handoff.available){h+='<div class="item"><span class="tag'+(d.handoff.level==='ok'?'':' ERR')+'">handoff '+esc(d.handoff.level||'?')+'</span>'+esc(String(d.handoff.in_tok))+'/'+esc(String(d.handoff.budget))+' in ('+esc(String(Math.round((d.handoff.ratio||0)*100)))+'%) — '+esc(d.handoff.action||'')+'</div>';}
  if(d.risks&&d.risks.available){var rk=(d.risks.over||[]).concat(d.risks.denied||[]);for(var ri=0;ri<rk.length&&ri<6;ri++){var rs=rk[ri];h+='<div class="item"'+(rs.session?' data-go="'+esc(rs.session)+'" style="cursor:pointer" title="drill into '+esc(rs.session)+'"':'')+'><span class="tag ERR">risk</span>'+esc(rs.session)+' '+esc(String(rs.in_tok))+' in ('+esc(String(Math.round((rs.ratio||0)*100)))+'%)'+(rs.model_denied?' · model '+esc(rs.model)+' deny-listed':'')+' — '+esc(String(rs.guidance||'').slice(0,140))+'</div>';}}
  if(!d.findings.length){h+='<div class="item">no stalls or blank turns — the web view lagging is a client issue, not an agent stall</div>';}
  for(var i=0;i<d.findings.length;i++){var f=d.findings[i];
    var go=f.session?' data-go="'+esc(f.session)+'" style="cursor:pointer" title="drill into '+esc(f.session)+'"':'';
    if(f.kind==='running_tool'){h+='<div class="item"'+go+'><span class="tag ERR">stall</span>'+esc(f.session)+' '+esc(f.tool)+' [running '+esc(String(f.age_s))+'s] <span class="muted">'+esc(String(f.command||'').slice(0,80))+'</span></div>';}
    else if(f.kind==='dead_tool'){h+='<div class="item"'+go+'><span class="tag">dead</span>'+esc(f.session)+' '+esc(f.tool)+' <span class="muted">dead tool — server idle/absent, running '+esc(String(f.age_s))+'s is archival, not a live stall</span></div>';}
    else if(f.kind==='dead_blank'){h+='<div class="item"'+go+'><span class="tag">dead</span>'+esc(f.session)+' '+esc(f.model)+' <span class="muted">dead blank — server idle/absent, no text '+esc(String(f.age_s))+'s is archival, not a live no-answer</span></div>';}
    else {h+='<div class="item"'+go+'><span class="tag">blank</span>'+esc(f.session)+' '+esc(f.model)+' — no text '+esc(String(f.age_s))+'s after last tool</div>';}
  }
  if(d.by_model){var bm=[];for(var mk in d.by_model){bm.push(esc(mk)+'='+esc(String(d.by_model[mk])));}
    if(bm.length){h+='<div class="muted" style="font-size:11px;margin-top:6px">findings by model: '+bm.join(', ')+'</div>';}}
  if(d.known_issues&&d.known_issues.length){
    h+='<div class="muted" style="font-size:12px;margin-top:8px">known upstream issues correlated with these findings (scripts/known-issues.json)</div>';
    for(var k=0;k<d.known_issues.length;k++){var it=d.known_issues[k];
      h+='<div class="item"><span class="tag">'+esc(it.severity||'?')+'</span><a href="'+esc(it.url||'#')+'" target="_blank" rel="noopener">'+esc(it.id)+'</a> <span class="muted">'+esc(String(it.title||'').slice(0,80))+' (x'+esc(String(it.n||0))+')</span></div>';}}
  if(d.per_model&&d.per_model.length){
    h+='<div class="muted" style="font-size:12px;margin-top:8px">per-model quirks — tool errors + blacklist constructs (recent sessions)</div>';
    for(var q=0;q<d.per_model.length;q++){var pm=d.per_model[q];
      h+='<div class="item"><span class="tag'+(pm.quirk_hits>0?' ERR':'')+'">model</span>'+esc(pm.model)+' — '+esc(String(pm.tool_parts))+' tools, errors '+esc(String(pm.errors))+' ('+esc(String(Math.round((pm.error_rate||0)*1000)/10))+'%) · sed '+esc(String(pm.used_sed||0))+' · 2>/dev/null '+esc(String(pm.used_devnull||0))+'</div>';
      var ad=pm.adaptation;
      if(ad&&ad.verdict&&ad.verdict!=='ok'){h+='<div class="item muted" style="font-size:12px"><span class="tag'+(ad.verdict==='adapt'?' ERR':'')+'">'+esc(ad.verdict)+'</span>'+esc(ad.recs&&ad.recs[0]||'')+'</div>';}}}
  el.html(h);
  setBadge('signals',d.findings.length);
  HEALTH_SUMMARY=c.running_tools+' running · '+c.blank_tails+' blank'+(c.dead_tools?' · '+c.dead_tools+' dead':'');
  renderLanding();
}
async function renderGuard(){
  var el=d3.select('#guard');el.selectAll('*').remove();
  var d=await j('/api/guard?limit=30');
  if(!d||!d.count){el.text('no guard actions yet — restart opencode-web to load the plugin; it logs to data/observability/guard.log');return;}
  var parts=[];for(var k in (d.counts||{})){parts.push(k+'='+d.counts[k]);}
  var h='<div class="muted" style="font-size:12px">'+d.count+' actions · '+parts.join(', ')+'</div>';
  for(var i=0;i<d.actions.length;i++){var a=d.actions[i];
    h+='<div class="item"><span class="tag">'+esc(a.verdict||'?')+'</span>'+esc((a.patterns||[]).join(','))+' <span class="muted">'+esc(String(a.command||'').slice(0,90))+'</span></div>';}
  el.html(h);
}
document.getElementById('brush-reset').addEventListener('click',function(){FILTER=[0,Infinity];setFilterText();renderBurn();renderTreemap();renderScatter();renderSankey();renderGantt();renderLanding();});
// Keyboard: Escape blurs. Never hijacks typing. (Note: '/' is already
// claimed on this page by the Search-everything box #q2 — one shortcut,
// one target; the home page claims '/' for its own #q instead.)
document.addEventListener('keydown',function(ev){
  var t=ev.target&&(ev.target.tagName||'').toLowerCase();
  if(t==='input'||t==='textarea'||t==='select')return;
  if(ev.key==='Escape'&&document.activeElement&&document.activeElement.blur){document.activeElement.blur();}
});
document.getElementById('detail-close').addEventListener('click',function(){document.getElementById('detail').innerHTML='';document.querySelectorAll('#stable tr.selected').forEach(function(r){r.classList.remove('selected');});document.getElementById('detail-card').hidden=true;});
document.getElementById('detail-head').addEventListener('click',function(ev){if(ev.target&&ev.target.id==='detail-close')return;document.getElementById('detail-card').classList.toggle('collapsed');});
document.getElementById('signals').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
document.getElementById('health').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
async function renderOcr(){
  var el=d3.select('#ocr');el.selectAll('*').remove();
  var d=await j('/api/ocr?limit=20');
  setBadge('ocr',d&&d.runs?d.runs.length:0);
  if(!d||!d.runs||!d.runs.length){el.text('no OCR yet — run ./scripts/ocr-image.sh <image> to read a screenshot locally');return;}
  var h='<div class="muted" style="font-size:12px">'+d.count+' OCR runs · also searchable from the search box</div>';
  for(var i=0;i<d.runs.length;i++){var r=d.runs[i];
    h+='<div class="item"><span class="tag">'+esc(r.engine)+'</span>'+esc(r.image)+' <span class="muted">'+esc(r.ts||'')+'</span><div class="muted" style="white-space:pre-wrap;font-size:11px">'+esc(r.snippet)+'</div></div>';}
  el.html(h);
}
async function renderDupes(){
  var el=d3.select('#dupes');el.selectAll('*').remove();
  var d=await j('/api/duplicates');
  setBadge('data',d&&d.length?d.length:0);
  if(!d||!d.length){el.text('no duplicate sessions');return;}
  var h='<div class="muted" style="font-size:12px">'+d.length+' duplicate groups (normalized title)</div>';
  for(var i=0;i<d.length;i++){var g=d[i];h+='<div class="item"'+(g.ids&&g.ids[0]?' data-go="'+esc(g.ids[0])+'" style="cursor:pointer" title="drill into '+esc(g.ids[0])+'"':'')+'><span class="tag">'+g.count+'x</span>'+esc(g.title)+' <span class="muted">$'+(+g.cost).toFixed(4)+'</span></div>';}
  el.html(h);
}
async function renderOps(){
  // Failures, successes, bottlenecks from /api/ops. Error rows carry
  // data-go with an example session and drill via detail() (same
  // delegation contract as the signals pane). Gate strip is display-only.
  var el=d3.select('#ops');el.selectAll('*').remove();
  var d=await j('/api/ops');
  setBadge('ops',d&&d.errors_by_tool?d.errors_by_tool.length:0);
  if(!d){el.text('(ops unavailable)');return;}
  var h='';
  h+='<div class="muted" style="font-size:12px">failures by tool (click a row to drill into an example session)</div>';
  if(d.errors_by_tool&&d.errors_by_tool.length){
    for(var i=0;i<d.errors_by_tool.length;i++){var e=d.errors_by_tool[i];
      h+='<div class="item"'+(e.example_sid?' data-go="'+esc(e.example_sid)+'"':'')+'><span class="tag">error</span>'+esc(e.tool||'?')+' x'+e.n+'</div>';}
  }else{h+='<div class="item">no error tool calls in window</div>';}
  h+='<div class="muted" style="font-size:12px;margin-top:10px">gate history (latest first)</div>';
  if(d.gate_runs&&d.gate_runs.length){
    for(var k=0;k<d.gate_runs.length;k++){var g=d.gate_runs[k];
      h+='<div class="item"><span class="tag">'+esc(g.verdict||'?')+'</span><span class="muted">'+esc(g.ts||'')+'</span> '+esc(g.detail||'')+'</div>';}
  }else{h+='<div class="item">no gate runs recorded</div>';}
  var gb=d.guard_blocks||{n:0,top:[]};
  h+='<div class="muted" style="font-size:12px;margin-top:10px">guard blocks: '+gb.n+'</div>';
  for(var m=0;m<gb.top.length;m++){h+='<div class="item"><span class="tag">block</span>'+esc(String(gb.top[m].pattern||'').slice(0,80))+' x'+gb.top[m].n+'</div>';}
  h+='<div class="muted" style="font-size:12px;margin-top:10px">per-model errors (recent window)</div>';
  if(d.per_model_errors&&d.per_model_errors.length){
    for(var pm=0;pm<d.per_model_errors.length;pm++){var r=d.per_model_errors[pm];
      h+='<div class="item"><span class="tag">'+esc(String(r.errors??'?'))+'</span>'+esc(r.model||'?')+' <span class="muted">'+r.sessions+' sessions · '+(r.tool_parts||0)+' tools · rate '+(r.error_rate==null?'?':r.error_rate)+'</span></div>';}
  }else{h+='<div class="item">no per-model data</div>';}
  h+='<div class="muted" style="font-size:12px;margin-top:10px">slowest recent computations (sync ms; cached hits cost nothing)</div>';
  if(d.slow_endpoints&&d.slow_endpoints.length){
    for(var s=0;s<d.slow_endpoints.length;s++){var se=d.slow_endpoints[s];
      h+='<div class="item"><span class="tag">'+se.ms+'ms</span>'+esc(se.path)+'</div>';}
  }else{h+='<div class="item">no computations recorded yet</div>';}
  el.html(h);
}
document.getElementById('ops').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
document.getElementById('dupes').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
document.getElementById('patterns').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
function activateTab(name,setHash){
  if(!name)return;
  var tabs=document.querySelectorAll('.tab');
  for(var i=0;i<tabs.length;i++){
    if(tabs[i].getAttribute('data-tab')===name){tabs[i].classList.add('active');tabs[i].setAttribute('aria-selected','true');}else{tabs[i].classList.remove('active');tabs[i].setAttribute('aria-selected','false');}
  }
  var panes=document.querySelectorAll('.pane');
  for(var j=0;j<panes.length;j++){panes[j].hidden=(panes[j].getAttribute('data-pane')!==name);}
  if(setHash){try{location.hash=name;}catch(e){}}
  // Self-healing signals: live adjudication (dead_tool/dead_blank) can
  // change between loads, and a load that raced a live-unavailable window
  // paints fail-safe tombstones with no later correction. Re-render the
  // signals pane on activation so the panel converges without a reload.
  // Markers first (renderers clear-then-fetch, which would flash blank).
  if(name==='signals'){
    var ids=['health','signals','guard'];
    for(var k=0;k<ids.length;k++){var c=document.getElementById(ids[k]);if(c)c.innerHTML='<span class="muted" data-loading>loading...</span>';}
    renderHealth();renderSignals();renderGuard();
  }
  // board: lazy load once on first activation (the payload is small, but no
  // reason to pay for it when nobody opens the tab).
  if(name==='board'&&!BOARD_LOADED){BOARD_LOADED=true;renderBoard();}
}
// APG tabs pattern (W3C ARIA Authoring Practices Guide):
// https://www.w3.org/WAI/ARIA/apg/patterns/tabs/ — tablist/tab/tabpanel
// roles, aria-selected synced here, arrow/Home/End keyboard with automatic
// activation. Buttons are natively focusable so Tab/Enter need no extras.
// Keyboard operability follows WCAG 2.1 guideline 2.1:
// https://www.w3.org/TR/WCAG21/
document.getElementById('tabs').addEventListener('click',function(ev){
  var b=ev.target&&ev.target.closest?ev.target.closest('.tab'):null;
  if(b){activateTab(b.getAttribute('data-tab'),true);}
});
// APG tabs keyboard pattern (automatic activation): arrows move between
// tabs in DOM order, Home/End jump. Buttons are natively focusable and
// Enter/Space already activates via click.
document.getElementById('tabs').addEventListener('keydown',function(ev){
  if(ev.key!=='ArrowLeft'&&ev.key!=='ArrowRight'&&ev.key!=='Home'&&ev.key!=='End')return;
  var tabs=document.querySelectorAll('.tab');
  var cur=document.querySelector('.tab.active');
  var curName=cur?cur.getAttribute('data-tab'):null;
  var at=-1,i;
  for(i=0;i<tabs.length;i++){if(tabs[i].getAttribute('data-tab')===curName)at=i;}
  if(at<0)at=0;
  if(ev.key==='Home')at=0;
  else if(ev.key==='End')at=tabs.length-1;
  else at=(at+(ev.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;
  ev.preventDefault();
  if(tabs[at].focus)tabs[at].focus();
  activateTab(tabs[at].getAttribute('data-tab'),true);
});
if(typeof window!=='undefined'&&window.addEventListener){window.addEventListener('hashchange',function(){activateTab((location.hash||'').slice(1),false);});}
activateTab((location.hash||'').slice(1)||'overview',false);
async function load(){
  if(typeof d3==='undefined'){var el=document.getElementById('treemap');if(el){el.textContent='d3 failed to load (/vendor/d3.min.js)';}return;}
  var o=await j('/api/overview?limit=500');
  if(!o||!o.sessions){d3.select('#treemap').text('(no data)');d3.selectAll('[data-loading]').text('(overview unavailable)');return;}
  BUDGET=o.budget;DATA=o.sessions;setFilterText();
  DATA.forEach(function(d){d._span=span(d);});
  MODEL_COLOR=d3.scaleOrdinal(['#79c0ff','#d2a8ff','#7ee787','#ffa657','#ff7b72']);
  COST=d3.scaleLinear().domain([0,d3.max(DATA,function(d){return +d.cost||0;})||1]).range(['#1b3a5c','#79c0ff']);
  renderTable();renderDupes();renderOps();renderSignals();renderGuard();renderHealth();renderPatterns();renderPivot();renderCode();renderOcr();renderIntegrations();renderAb();renderSchema();
  renderTreemap();renderTrends();renderBurn();renderScatter();renderSankey();renderGantt();renderTimeline();renderCloud();
}

async function renderTreemap(){
  var data=DATA.filter(inFilter);
  var el=d3.select('#treemap');el.selectAll('*').remove();
  if(!data.length){el.text('(no sessions in range)');return;}
  var grouped=d3.rollup(data,function(v){return v;},function(d){return modelId(d.model);});
  var groups=Array.from(grouped,function(e){return {model:e[0],children:e[1]};});
  groups.sort(function(a,b){return d3.sum(b.children,function(d){return +d.cost||0;})-d3.sum(a.children,function(d){return +d.cost||0;});});
  var root=d3.hierarchy({children:groups}).sum(function(d){return +d.cost||0;});
  var W=1000,H=Math.max(240,Math.min(560,root.leaves().length*12));
  d3.treemap().size([W,H]).paddingInner(2).paddingTop(18).paddingOuter(2).round(true).tile(d3.treemapResquarify)(root);
  var svg=el.append('svg').attr('width',W).attr('height',H);
  var defs=svg.append('defs');
  root.children.forEach(function(g,i){
    defs.append('clipPath').attr('id','gc'+i).append('rect').attr('x',g.x0).attr('y',g.y0).attr('width',Math.max(0,g.x1-g.x0)).attr('height',16);
  });
  var maxCost=COST.domain()[1]||1;
  var leaf=svg.selectAll('g.leaf').data(root.leaves()).enter().append('g')
    .attr('transform',function(d){return 'translate('+d.x0+','+d.y0+')';});
  leaf.append('rect')
    .attr('width',function(d){return Math.max(0,d.x1-d.x0);})
    .attr('height',function(d){return Math.max(0,d.y1-d.y0);})
    .attr('fill',function(d){return MODEL_COLOR(modelId(d.data.model));})
    .attr('fill-opacity',function(d){return 0.30+0.6*Math.min(1,(+d.data.cost||0)/maxCost);})
    .attr('stroke','#0d1117')
    .attr('tabindex','0')
    .attr('role','link')
    .attr('aria-label',function(d){return d.data.title+' ($'+(+d.data.cost).toFixed(4)+')';})
    .style('cursor','pointer')
    .on('click',function(ev,d){location.href='/?session='+encodeURIComponent(d.data.id);})
    .on('keydown',function(ev,d){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();location.href='/?session='+encodeURIComponent(d.data.id);}})
    .on('focus',function(ev,d){focusTip(ev,esc(d.data.title)+'<br>$'+(+d.data.cost).toFixed(4)+' · in '+fmt(d.data.tokens_input)+' · '+esc(modelId(d.data.model))+'<br>Enter opens the transcript');})
    .on('blur',function(){tip(null);})
    .on('mousemove',function(ev,d){moveTip(ev);tip(esc(d.data.title)+'<br>$'+(+d.data.cost).toFixed(4)+' · in '+fmt(d.data.tokens_input)+' · '+esc(modelId(d.data.model))+'<br>click to open transcript');})
    .on('mouseleave',function(){tip(null);});
  leaf.append('text').attr('x',5).attr('y',14).style('font-size','10px').style('fill','#e6edf3').style('pointer-events','none')
    .text(function(d){return ((d.x1-d.x0)>64&&(d.y1-d.y0)>16)?String(d.data.title||'').slice(0,Math.floor((d.x1-d.x0)/6)):'';});
  svg.selectAll('g.grp').data(root.children).enter().append('g').append('text')
    .attr('x',function(d){return d.x0+2;}).attr('y',function(d){return d.y0+12;})
    .attr('clip-path',function(d,i){return 'url(#gc'+i+')';})
    .style('font-size','11px').style('font-weight','600').style('fill','#8b949e')
    .text(function(d){return d.data.model+' · $'+(+d.value).toFixed(2);});
}

async function renderTrends(){
  var host=document.getElementById('trends');if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  var d=await j('/api/trends');
  if(!d||!d.length){host.textContent='(no history)';return;}
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:1000,height:220,marginLeft:56,marginBottom:34,
    x:{type:'band'},
    y:{grid:true,tickFormat:function(v){return '$'+v;}},
    marks:[
      Plot.barY(d,{x:'day',y:'c',fill:'#1f6feb',title:function(r){return r.day+': '+r.n+' sessions \u00b7 $'+(+r.c).toFixed(4)+' \u00b7 '+r.i+' in';}}),
      Plot.ruleY([0])
    ]
  }));
}
async function renderBurn(){
  // Hybrid Plot spec (G3 migration 4/6, completes chart rendering):
  // Plot renders the step-after area/line + budget rule (same data,
  // BUDGET line, labels, empty text); a d3.brushX overlay keeps the
  // filter linkage bit-for-bit (drag -> FILTER + setFilterText + 4
  // re-renders; clear -> full range). Plot has no brush mark, so the
  // overlay is the honest shape — rendering migrates, interaction
  // stays on the proven d3 brush.
  var host=document.getElementById('burn');
  if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.areaY!=='function'||typeof Plot.line!=='function'||typeof Plot.ruleY!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  if(!DATA.length){host.textContent='(no data)';return;}
  var data=DATA.slice().sort(function(a,b){return a.time_created-b.time_created;});
  setBadge('charts',data.length);
  var cum=0,pts=data.map(function(d){cum+=(+d.cost||0);return {t:new Date(d.time_updated||d.time_created),v:cum};});
  var total=cum;
  var marginTop=12,marginRight=16,marginBottom=26,marginLeft=64;
  var W=1000,H=220,w=W-marginLeft-marginRight,h=H-marginTop-marginBottom;
  var t0=data[0].time_created,t1=Math.max(data[data.length-1].time_updated||data[data.length-1].time_created,t0+1);
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:W,height:H,marginTop:marginTop,marginRight:marginRight,marginBottom:marginBottom,marginLeft:marginLeft,
    x:{type:'time',domain:[new Date(t0),new Date(t1)],ticks:6,tickFormat:function(d){return d3.timeFormat('%b %d %H:%M')(d);}},
    y:{domain:[0,Math.max(BUDGET,total||0)*1.08],nice:true,ticks:5,tickFormat:function(v){return '$'+v;},grid:true},
    marks:[
      Plot.areaY(pts,{x:'t',y:'v',curve:'step-after',fill:'#1f6feb22'}),
      Plot.line(pts,{x:'t',y:'v',curve:'step-after',stroke:'#58a6ff',strokeWidth:1.5}),
      Plot.ruleY([BUDGET],{stroke:'#ff7b72',strokeDasharray:'4 3'}),
      Plot.text([{v:BUDGET,label:'budget $'+BUDGET}],{y:'v',text:'label',textAnchor:'end',dx:w,dy:-4,fill:'#8b949e',fontSize:11})
    ]
  }));
  var svg=host.querySelector('svg');
  // d3-brush overlay (Plot has no brush mark): https://github.com/d3/d3-brush
  if(svg&&typeof d3!=='undefined'&&typeof d3.brushX==='function'&&typeof d3.scaleTime==='function'){
    var x=d3.scaleTime().domain([t0,t1]).range([0,w]);
    var brush=d3.brushX().extent([[0,0],[w,h]]).on('brush end',function(ev){
      if(!ev.selection){FILTER=[0,Infinity];}
      else{FILTER=[+x.invert(ev.selection[0]),+x.invert(ev.selection[1])];}
      setFilterText();renderTreemap();renderScatter();renderSankey();renderGantt();renderLanding();
    });
    d3.select(svg).append('g').attr('transform','translate('+marginLeft+','+marginTop+')').call(brush);
  }
}

async function renderScatter(){
  // Declarative Plot spec (G3 migration 1/6): same filtered data, domains,
  // colors, empty text, drill-down and tooltip strings as the hand-rolled
  // d3 version it replaces. Plot marks/scales reference:
  // https://github.com/observablehq/plot (marks: dot/cell/text/barX/rect;
  // scales: log/sqrt/band; the vendored UMD build is scripts/vendor/). Clicks/tooltips ride ONE delegated listener
  // bound to the container (RULES #61: data-* + delegation, no inline
  // handlers); re-renders only rebuild the row map, never re-bind.
  var host=document.getElementById('scatter');
  if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.dot!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  var data=DATA.filter(inFilter);
  if(!data.length){host.textContent='(no sessions in range)';return;}
  var minS=Infinity,maxS=0,maxC=0,maxTok=0,i,d,sp,cs,tk;
  for(i=0;i<data.length;i++){d=data[i];
    sp=span(d);if(sp<minS)minS=sp;if(sp>maxS)maxS=sp;
    cs=+d.cost||0;if(cs>maxC)maxC=cs;
    tk=(+d.tokens_input||0)+(+d.tokens_output||0);if(tk>maxTok)maxTok=tk;}
  var xmin=Math.max(1000,minS/2),xmax=Math.max(xmin*2,maxS*1.5),ymax=Math.max(0.0002,maxC*1.5);
  if(!(maxTok>0))maxTok=1;
  var xticks=[1000,10000,60000,600000,3600000,86400000].filter(function(v){return v>=xmin&&v<=xmax;});
  var yticks=[0.0001,0.001,0.01,0.1,1,10].filter(function(v){return v>=0.0001&&v<=ymax;});
  var fmtSpan=function(v){var s=v/1000;return s<60?(s+'s'):(s<3600?(Math.round(s/60)+'m'):(Math.round(s/3600)+'h'));};
  var fmtCost=function(v){return '$'+(+v).toPrecision(2);};
  var tipText=function(d){return d.title+' — $'+(+d.cost).toFixed(4)+' · '+(span(d)/1000).toFixed(0)+'s · in '+fmt(d.tokens_input)+' · '+modelId(d.model);};
  var byId={};
  for(i=0;i<data.length;i++){byId[data[i].id]=data[i];}
  host.SCATT_ROWS=byId;
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:1000,height:300,marginTop:12,marginRight:34,marginBottom:34,marginLeft:84,
    x:{type:'log',domain:[xmin,xmax],label:'span (log)',ticks:xticks,tickFormat:fmtSpan,grid:true},
    y:{type:'log',domain:[0.0001,ymax],label:'cost (log)',ticks:yticks,tickFormat:fmtCost,grid:true},
    marks:[
      Plot.dot(data,{
        x:function(d){return Math.max(xmin,span(d));},
        y:function(d){return Math.max(0.0001,+d.cost||0.0001);},
        r:function(d){return (+d.tokens_input||0)+(+d.tokens_output||0);},
        fill:function(d){return MODEL_COLOR(modelId(d.model));},
        fillOpacity:0.45,
        title:tipText
      })
    ],
    r:{type:'sqrt',domain:[0,maxTok],range:[1.5,13]}
  }));
  var dots=host.querySelectorAll('circle');
  if(dots.length===data.length){
    for(i=0;i<dots.length;i++){dots[i].setAttribute('data-id',data[i].id);}
  }
  if(!host.SCATT_WIRED){
    host.SCATT_WIRED=1;
    host.addEventListener('click',function(ev){
      var c=ev.target&&ev.target.closest?ev.target.closest('[data-id]'):null;
      if(c){location.href='/?session='+encodeURIComponent(c.getAttribute('data-id'));}
    });
    host.addEventListener('mousemove',function(ev){
      var c=ev.target&&ev.target.closest?ev.target.closest('[data-id]'):null;
      var r=c&&host.SCATT_ROWS?host.SCATT_ROWS[c.getAttribute('data-id')]:null;
      if(r){moveTip(ev);tip(esc(r.title)+'<br>$'+(+r.cost).toFixed(4)+' · '+(span(r)/1000).toFixed(0)+'s · in '+fmt(r.tokens_input)+' · '+esc(modelId(r.model)));}
      else{tip(null);}
    });
    host.addEventListener('mouseleave',function(){tip(null);});
  }
}

async function renderSankey(){
  var el=d3.select('#sankey');el.selectAll('*').remove();
  if(typeof d3.sankey!=='function'){el.text('(d3-sankey not loaded)');return;}
  var data=DATA.filter(inFilter);
  if(!data.length){el.text('(no sessions in range)');return;}
  var cats=['cache read','reasoning','output'];
  var models=Array.from(new Set(data.map(function(d){return modelId(d.model);})));
  var nodes=models.map(function(m){return {name:m,kind:'model'};}).concat(cats.map(function(c){return {name:c,kind:'cat'};}));
  var idx={};nodes.forEach(function(n,i){idx[n.kind+'|'+n.name]=i;});
  var agg={};
  data.forEach(function(d){
    var m=modelId(d.model);
    agg['cache read|'+m]=(agg['cache read|'+m]||0)+(+d.tokens_cache_read||0);
    agg['reasoning|'+m]=(agg['reasoning|'+m]||0)+(+d.tokens_reasoning||0);
    agg['output|'+m]=(agg['output|'+m]||0)+(+d.tokens_output||0);
  });
  var links=[];
  models.forEach(function(m){cats.forEach(function(c){var v=agg[c+'|'+m]||0;if(v>0)links.push({source:idx['model|'+m],target:idx['cat|'+c],value:v});});});
  if(!links.length){el.text('(no token data)');return;}
  var W=1000,H=Math.max(200,models.length*80);
  // Sankey layout (stays hand-rolled: Plot v0.6 has no sankey mark):
  // https://github.com/d3/d3-sankey
  var layout=d3.sankey().nodeWidth(12).nodePadding(16).nodeAlign(d3.sankeyJustify).extent([[2,14],[W-160,H-14]]);
  var graph=layout({nodes:nodes.map(function(n){return {name:n.name,kind:n.kind};}),links:links.map(function(l){return {source:l.source,target:l.target,value:l.value};})});
  var catColor={'cache read':'#8b949e','reasoning':'#d2a8ff','output':'#7ee787'};
  var svg=el.append('svg').attr('width',W).attr('height',H).append('g');
  var linkTip=function(d){return esc(d.source.name)+' → '+esc(d.target.name)+'<br>'+fmt(d.value)+' tokens';};
  svg.append('g').selectAll('path').data(graph.links).enter().append('path')
    .attr('d',d3.sankeyLinkHorizontal())
    .attr('fill','none')
    .attr('stroke',function(d){return catColor[d.target.name]||'#30363d';})
    .attr('stroke-opacity',0.30)
    .attr('stroke-width',function(d){return Math.max(1,d.width);})
    .attr('tabindex','0')
    .attr('role','img')
    .attr('aria-label',function(d){return d.source.name+' to '+d.target.name+': '+fmt(d.value)+' tokens';})
    .on('mousemove',function(ev,d){moveTip(ev);tip(linkTip(d));})
    .on('mouseleave',function(){tip(null);})
    .on('focus',function(ev,d){focusTip(ev,linkTip(d));})
    .on('blur',function(){tip(null);})
    .on('keydown',function(ev,d){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();focusTip(ev,linkTip(d));}});
  var node=svg.append('g').selectAll('g').data(graph.nodes).enter().append('g');
  var nodeTip=function(d){return esc(d.name)+' — '+fmt(d.value)+' tokens';};
  node.append('rect')
    .attr('x',function(d){return d.x0;}).attr('y',function(d){return d.y0;})
    .attr('width',function(d){return d.x1-d.x0;}).attr('height',function(d){return Math.max(1,d.y1-d.y0);})
    .attr('rx',2)
    .attr('fill',function(d){return d.kind==='model'?MODEL_COLOR(d.name):(catColor[d.name]||'#8b949e');})
    .attr('fill-opacity',0.9)
    .attr('tabindex','0')
    .attr('role','img')
    .attr('aria-label',function(d){return d.name+': '+fmt(d.value)+' tokens';})
    .on('focus',function(ev,d){focusTip(ev,nodeTip(d));})
    .on('blur',function(){tip(null);})
    .on('keydown',function(ev,d){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();focusTip(ev,nodeTip(d));}});
  node.append('text')
    .attr('x',function(d){return d.x0<W/2?d.x1+6:d.x0-6;})
    .attr('y',function(d){return (d.y0+d.y1)/2;})
    .attr('dy','0.35em')
    .attr('text-anchor',function(d){return d.x0<W/2?'start':'end';})
    .attr('class','lbl')
    .text(function(d){return (d.y1-d.y0)>=14?d.name+'  '+fmt(d.value):'';});
  node.append('title')
    .text(function(d){return d.name+' — '+fmt(d.value)+' tokens';});
}

async function renderGantt(){
  // Declarative Plot spec (G3 migration 2/6): same filtered data, time
  // domain, 7px rows / 5px bars, COST colors, empty text, click-to-timeline
  // and tooltip strings as the hand-rolled d3 version. One delegated
  // container listener (RULES #61); re-renders rebuild the row map only.
  var host=document.getElementById('gantt');
  if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.barX!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  var data=DATA.filter(inFilter);
  if(!data.length){host.textContent='(no sessions in range)';return;}
  var minT=Infinity,maxT=0,i,d;
  for(i=0;i<data.length;i++){d=data[i];
    if(d.time_created<minT)minT=d.time_created;
    var te=d.time_updated||d.time_created;if(te>maxT)maxT=te;}
  if(maxT<=minT)maxT=minT+1000;
  var pad=(maxT-minT)/500; // >=2px minimum bar like the legacy version
  var byId={};
  for(i=0;i<data.length;i++){byId[data[i].id]=data[i];}
  host.GANTT_ROWS=byId;
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:1000,height:32+Math.max(160,data.length*7),marginTop:8,marginRight:16,marginBottom:24,marginLeft:8,
    x:{domain:[minT,maxT],ticks:6,tickFormat:timeFmt},
    y:{axis:null,domain:data.map(function(_,j){return j;})},
    marks:[
      Plot.barX(data,{
        x1:function(d){return d.time_created;},
        x2:function(d){return Math.max(d.time_updated||d.time_created,(d.time_created||0)+pad);},
        y:function(d,j){return j;},
        fill:function(d){return COST(+d.cost||0);},
        insetTop:1,insetBottom:1,
        title:function(d){return d.title+' — $'+(+d.cost).toFixed(4)+' · in '+fmt(d.tokens_input)+' / out '+fmt(d.tokens_output)+' / reas '+fmt(d.tokens_reasoning);}
      })
    ]
  }));
  var rects=host.querySelectorAll('rect');
  if(rects.length===data.length){
    for(i=0;i<rects.length;i++){rects[i].setAttribute('data-id',data[i].id);}
  }
  if(!host.GANTT_WIRED){
    host.GANTT_WIRED=1;
    host.addEventListener('click',function(ev){
      var c=ev.target&&ev.target.closest?ev.target.closest('[data-id]'):null;
      if(c){var r=host.GANTT_ROWS?host.GANTT_ROWS[c.getAttribute('data-id')]:null;if(r)renderTimeline(r.id,r.title);}
    });
    host.addEventListener('mousemove',function(ev){
      var c=ev.target&&ev.target.closest?ev.target.closest('[data-id]'):null;
      var r=c&&host.GANTT_ROWS?host.GANTT_ROWS[c.getAttribute('data-id')]:null;
      if(r){moveTip(ev);tip(esc(r.title)+'<br>$'+(+r.cost).toFixed(4)+' · in '+fmt(r.tokens_input)+' / out '+fmt(r.tokens_output)+' / reas '+fmt(r.tokens_reasoning));}
      else{tip(null);}
    });
    host.addEventListener('mouseleave',function(){tip(null);});
  }
}

async function renderTimeline(id,title){
  // Declarative Plot spec (G3 migration 3/6): same parts fetch, time
  // domain, lane geometry, type colors, empty text and tooltip strings as
  // the hand-rolled d3 version. Tooltip rides one delegated listener
  // (RULES #61); re-renders rebuild the row map only.
  var url='/api/parts?limit=600'+(id?'&session='+encodeURIComponent(id):'');
  var data=await j(url);
  var host=document.getElementById('timeline');
  if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.rect!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  document.getElementById('tl-title').textContent=title||'latest session';
  if(!data||!data.length){host.textContent='(no parts)';return;}
  var minT=Infinity,maxT=0,i,d;
  for(i=0;i<data.length;i++){d=data[i];
    if(d.ts<minT)minT=d.ts;if(d.te>maxT)maxT=d.te;}
  if(maxT<=minT)maxT=minT+1000;
  var pad=(maxT-minT)/500; // >=2px minimum bar like the legacy version
  // Degenerate span (single-part session): HH:MM ticks would all read the
  // same; fall back to HH:MM:SS so the axis stays informative.
  var tlTick=function(d){var s=new Date(d).toISOString();return (maxT-minT)<60000?s.slice(11,19):s.slice(11,16);};
  host.TL_ROWS=data;
  host.innerHTML='';
  host.appendChild(Plot.plot({
    width:1000,height:152,marginTop:8,marginRight:16,marginBottom:24,marginLeft:8,
    x:{domain:[minT,maxT],ticks:6,tickFormat:tlTick},
    y:{axis:null,domain:[0,120]},
    marks:[
      Plot.rect(data,{
        x1:function(d){return d.ts;},
        x2:function(d){return Math.max(d.te,(d.ts||0)+pad);},
        y1:30,y2:46,
        fill:function(d){return colors[d.type]||'#8b949e';},
        title:function(d){return d.type+(d.tool?' '+d.tool:'')+(d.status?' ['+d.status+']':'')+' — '+String(d.cmd||d.text||'').slice(0,140);}
      })
    ]
  }));
  var rects=host.querySelectorAll('rect');
  if(rects.length===data.length){
    for(i=0;i<rects.length;i++){rects[i].setAttribute('data-i',i);}
  }
  if(!host.TL_WIRED){
    host.TL_WIRED=1;
    host.addEventListener('mousemove',function(ev){
      var c=ev.target&&ev.target.closest?ev.target.closest('[data-i]'):null;
      var r=c&&host.TL_ROWS?host.TL_ROWS[+c.getAttribute('data-i')]:null;
      if(r){moveTip(ev);tip(r.type+(r.tool?' '+r.tool:'')+(r.status?' ['+r.status+']':'')+'<br>'+String(r.cmd||r.text||'').slice(0,140));}
      else{tip(null);}
    });
    host.addEventListener('mouseleave',function(){tip(null);});
  }
}

function cloud(words,W,H){
  var placed=[],out=[],cx=W/2,cy=H/2,ang=0,rad=0;
  for(var i=0;i<words.length;i++){
    var s=Math.max(10,Math.min(64,words[i].size*2.5));
    var ww=s*0.6*words[i].text.length, hh=s*1.2;
    var x=cx,y=cy,ok=false;
    for(var k=0;k<300;k++){
      var a=ang+k*0.4, r=rad+k*1.6;
      x=cx+Math.cos(a)*r; y=cy+Math.sin(a)*r*0.62;
      ok=true;
      for(var m=0;m<placed.length;m++){var p=placed[m];if(Math.abs(p.x-x)<(p.w+ww)/2&&Math.abs(p.y-y)<(p.h+hh)/2){ok=false;break;}}
      if(ok)break;
    }
    if(!ok){x=cx+rad*Math.cos(ang);y=cy+rad*Math.sin(ang)*0.62;}
    placed.push({x:x,y:y,w:ww,h:hh});
    out.push({text:words[i].text,size:s,x:x,y:y,w:ww,h:hh});
    rad+=s*0.4; ang+=0.8;
  }
  return out;
}

async function renderCloud(){
  var words=await j('/api/words?limit=80');
  var el=d3.select('#cloud');
  if(!words||!words.length){el.text('(no words)');return;}
  var W=1000,H=300;
  var placed=cloud(words,W,H);
  el.selectAll('*').remove();
  // Fit, don't clip: the spiral can outgrow W/H, which cut words off at
  // the container edge. viewBox over the placed bounds keeps every term
  // visible at any container width.
  var x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity,i,q;
  for(i=0;i<placed.length;i++){q=placed[i];
    if(q.x-q.w/2<x0)x0=q.x-q.w/2;if(q.x+q.w/2>x1)x1=q.x+q.w/2;
    if(q.y-q.h/2<y0)y0=q.y-q.h/2;if(q.y+q.h/2>y1)y1=q.y+q.h/2;}
  var vb=(x1>x0&&y1>y0)?(' '+x0+' '+y0+' '+(x1-x0)+' '+(y1-y0)):' 0 0 '+W+' '+H;
  el.append('svg').attr('width','100%').attr('height',H).attr('viewBox',vb.slice(1)).append('g').attr('transform','translate('+W/2+','+H/2+')')
    .selectAll('text').data(placed).enter().append('text')
    .style('font-size',function(d){return d.size+'px';})
    .style('fill',function(d){return d3.interpolateViridis(d.size/64);})
    .style('cursor','pointer')
    .attr('data-word',function(d){return d.text;})
    .attr('text-anchor','middle')
    .attr('transform',function(d){return 'translate('+d.x+','+d.y+')';})
    .text(function(d){return d.text;});
}
document.getElementById('cloud').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-word]'):null;if(!t)return;var w=t.getAttribute('data-word');var q=document.getElementById('q2');if(q)q.value=w;activateTab('overview',true);doSearch2();});

document.getElementById('tl-reset').addEventListener('click',function(){renderTimeline(null,null);});
document.addEventListener('keydown',function(ev){if(ev.key==='/'&&ev.target&&ev.target.tagName!=='INPUT'){var q=document.getElementById('q2');if(q){ev.preventDefault();q.focus();}}});
// Board: Kanban (task state) + Gantt (realized session spans) + accessible
// table twins, from one /api/board payload. Provenance is labelled per source;
// estimates are heuristic and marked. Lazy: rendered on first tab activation.
var BOARD_LOADED=false,BOARD_DATA=null;
async function renderBoard(){
  var kb=document.getElementById('kanban'),bg=document.getElementById('boardgantt'),bt=document.getElementById('board-tables');
  var d=await j('/api/board');
  if(!d||!d.cards){kb.textContent='(board unavailable)';bg.textContent='(board unavailable)';if(bt)bt.textContent='';return;}
  BOARD_DATA=d;
  var cols=d.states||['pending','in_progress','completed'];
  var kh='';
  for(var i=0;i<cols.length;i++){var st=cols[i];
    var items=(d.cards||[]).filter(function(c){return c.state===st;});
    kh+='<div class="kcol"><div class="khead">'+esc(st)+' <span class="muted">'+items.length+'</span></div>';
    for(var k=0;k<items.length&&k<40;k++){var c=items[k];
      kh+='<div class="kcard"><span class="tag">'+esc(c.source)+'</span>'+esc(c.title)+(c.cost?' <span class="muted">$'+(+c.cost).toFixed(4)+'</span>':'')+'</div>';}
    if(items.length>40)kh+='<div class="muted" style="font-size:11px">+ '+(items.length-40)+' more</div>';
    kh+='</div>';
  }
  kb.innerHTML=kh;
  var es=d.estimates||{};
  var esEl=document.getElementById('board-estimates');
  if(esEl)esEl.textContent='estimates (heuristic \u00b7 n='+(es.n||0)+' realized sessions): median duration '+((es.median_duration_ms||0)/1000).toFixed(0)+'s \u00b7 median cost $'+(+es.median_cost_usd||0).toFixed(4)+' — a rough per-work-unit figure, not a per-task promise';
  renderBoardGantt(d);
  renderBoardEstimate(d);
  renderBoardTables(d);
}
function renderBoardGantt(d){
  var host=document.getElementById('boardgantt');if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.barX!=='function'){host.textContent='Plot failed to load (/vendor/plot.umd.min.js)';return;}
  var rows=(d.sessions||[]).filter(function(s){return s.start>0&&(s.end||s.start)>s.start;}).slice(0,150);
  if(!rows.length){host.textContent='(no realized sessions with a span)';return;}
  var minT=Infinity,maxT=0,i;
  for(i=0;i<rows.length;i++){if(rows[i].start<minT)minT=rows[i].start;if(rows[i].end>maxT)maxT=rows[i].end;}
  if(maxT<=minT)maxT=minT+1000;
  var pad=Math.max((maxT-minT)/500,1000);
  host.innerHTML='';
  var chart=Plot.plot({
    width:1000,height:32+Math.max(160,rows.length*7),marginTop:8,marginRight:16,marginBottom:24,marginLeft:8,
    x:{domain:[minT,maxT],ticks:6,tickFormat:function(v){return new Date(+v).toLocaleString(undefined,{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});}},
    y:{axis:null,domain:rows.map(function(_,j){return j;})},
    marks:[Plot.ruleX((d.milestones||[]).map(function(m){return new Date(m.ts).getTime();}).filter(function(t){return t>0;}),{stroke:'#d29922',strokeOpacity:0.35,title:function(v){return 'event '+new Date(+v).toLocaleString();}}),Plot.barX(rows,{
      x1:function(r){return r.start;},
      x2:function(r){return Math.max(r.end,r.start+pad);},
      y:function(r,j){return j;},
      fill:function(r){return r.agent||r.model||'?';},
      insetTop:1,insetBottom:1,
      title:function(r){return r.title+' — '+(r.model||'')+' · $'+(+r.cost).toFixed(4)+' · in '+fmt(r.tokens_in)+' · '+Math.round(r.duration/1000)+'s';}
    })]
  });
  host.appendChild(chart);
  // Clickable bars: a bar drills into its session timeline in-page (detail),
  // the same drill contract as the treemap/table rows. barX renders one <rect>
  // per datum in data order, so index i maps to rows[i].
  var rects=chart.querySelectorAll('rect');
  for(var bi=0;bi<rects.length&&bi<rows.length;bi++){
    (function(el,row){
      el.style.cursor='pointer';
      el.setAttribute('tabindex','0');
      el.setAttribute('role','link');
      el.setAttribute('aria-label','drill into '+(row.title||row.id));
      el.addEventListener('click',function(){detail(row.id);});
      el.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();detail(row.id);}});
    })(rects[bi],rows[bi]);
  }
}
function renderBoardEstimate(d){
  // Gantt-STYLE estimate chart for the OUTSTANDING tasks (pending/in_progress):
  // one bar per task, projected sequentially from now, sized by the median
  // realized session (heuristic, labelled) — for db cards with a real span the
  // bar is the measured span. Answers "what is left, and roughly how big".
  var host=document.getElementById('board-estimategantt');if(!host)return;
  if(typeof Plot==='undefined'||typeof Plot.plot!=='function'||typeof Plot.barX!=='function'){host.textContent='Plot failed to load';return;}
  var lead=(d.estimates&&d.estimates.median_duration_ms)||60000;
  var tasks=(d.cards||[]).filter(function(c){return c.state!=='completed';});
  if(!tasks.length){host.textContent='(no outstanding tasks)';return;}
  var order={'in_progress':0,'pending':1};
  tasks=tasks.slice().sort(function(a,b){return (order[a.state]||2)-(order[b.state]||2);}).slice(0,40);
  var t0=Date.now(),cursor=t0,gap=Math.max(lead*0.15,5000),rows=[];
  for(var i=0;i<tasks.length;i++){var c=tasks[i];
    var dur=(c.source==='db'&&c.end>c.start)?(c.end-c.start):lead;
    rows.push({i:i,title:c.title||c.id,source:c.source||'',session:c.session||'',dur:dur,x1:cursor,x2:cursor+dur});
    cursor+=dur+gap;
  }
  host.innerHTML='';
  var chart=Plot.plot({
    width:1000,height:36+rows.length*20,marginTop:8,marginRight:16,marginBottom:24,marginLeft:8,
    x:{domain:[t0,cursor],ticks:6,tickFormat:function(v){return new Date(+v).toLocaleString(undefined,{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});}},
    y:{axis:null,domain:rows.map(function(r){return r.i;})},
    color:{domain:['db','md'],range:['#1f6feb','#8b949e']},
    marks:[
      Plot.barX(rows,{x1:'x1',x2:'x2',y:'i',fill:'source',insetTop:1,insetBottom:1,title:function(r){return '~'+Math.round(r.dur/1000)+'s estimate \u2014 '+r.title;}}),
      Plot.text(rows,{x:function(){return t0;},y:'i',text:function(r){return (r.i+1)+'. '+String(r.title||'').slice(0,46);},dx:4,textAnchor:'start',fill:'#8b949e',fontSize:10})
    ]
  });
  host.appendChild(chart);
  var rects=chart.querySelectorAll('rect');
  for(var bi=0;bi<rects.length&&bi<rows.length;bi++){(function(el,r){if(r.session){el.style.cursor='pointer';el.setAttribute('tabindex','0');el.setAttribute('role','link');el.setAttribute('aria-label','drill into '+(r.title||r.session));el.addEventListener('click',function(){detail(r.session);});el.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();detail(r.session);}});}})(rects[bi],rows[bi]);}
}
function renderBoardTables(d){
  var bt=document.getElementById('board-tables');if(!bt)return;
  var rows=(d.sessions||[]).slice().sort(function(a,b){return b.duration-a.duration;}).slice(0,20);
  var h='<table><caption class="muted" style="text-align:left">Gantt data — longest realized sessions (accessible twin)</caption><tr><th>session</th><th>model</th><th>agent</th><th class="num">dur s</th><th class="num">cost $</th></tr>';
  for(var i=0;i<rows.length;i++){var r=rows[i];
    h+='<tr><td>'+esc(String(r.title||r.id).slice(0,60))+'</td><td>'+esc(r.model)+'</td><td>'+esc(r.agent)+'</td><td class="num">'+Math.round(r.duration/1000)+'</td><td class="num">'+(+r.cost).toFixed(4)+'</td></tr>';}
  h+='</table>';
  var ms=(d.milestones||[]).slice(0,15);
  h+='<table style="margin-top:10px"><caption class="muted" style="text-align:left">milestones — gate/advisory (observability ledger, newest 15)</caption><tr><th>ts</th><th>type</th><th>verdict</th><th>source</th></tr>';
  for(var k=0;k<ms.length;k++){h+='<tr><td class="muted">'+esc(ms[k].ts)+'</td><td>'+esc(ms[k].type)+'</td><td>'+esc(ms[k].verdict)+'</td><td class="muted">'+esc(ms[k].source)+'</td></tr>';}
  h+='</table>';
  bt.innerHTML=h;
}
load();
</script></body></html>`;

const runbooksHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode runbooks</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 8px}
 a{color:#58a6ff;text-decoration:none;font-size:13px}
 .muted{color:#8b949e}
 .bar{display:flex;align-items:center;gap:10px;margin:10px 0}
 select{background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px}
 .card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:12px;margin:10px 0}
 .rb-head{display:flex;align-items:center;gap:8px;margin-bottom:4px}
 .rb-title{font-weight:600;font-size:14px}
 .badge{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px}
 .badge.HOST{background:#b6232433;color:#ff7b72}
 .badge.CONTAINER{background:#2ea04333;color:#7ee787}
 .rb-purpose{font-size:12px;color:#8b949e;margin-bottom:6px}
 .cmd{display:flex;gap:8px;align-items:flex-start;background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:6px 8px;margin:0 0 6px}
 .cmd code{flex:1;white-space:pre-wrap;word-break:break-word;font-size:12px}
 .badge.MANUAL{background:#9e6a0333;color:#e3b341}
 .count{font-size:11px}
 button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:4px 10px;font-size:12px;cursor:pointer}
 button:hover{background:#2f81f7}
 .rb-note{font-size:11px;color:#8b949e;margin-top:6px}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("runbooks")}
<main id="main" tabindex="-1">
<h1>opencode runbooks</h1>
<div class="muted" style="font-size:12px">Operational scripts surfaced read-only. host = run on the machine with docker; container = safe inside the agent container. Copy, then paste into a terminal.</div>
<div class="bar"><label class="muted" for="f">filter</label><select id="f" aria-label="Filter runbooks by tag"><option value="all">all</option><option value="host">host only</option><option value="container">container only</option><option value="manual">manual only</option></select></div>
<div id="count" class="muted count"></div>
<div id="list" role="list" aria-label="Runbooks"><span class="muted" data-loading>loading...</span></div>
</main>
<script>
var RUNBOOKS=[];
function render(){
  var f=document.getElementById('f').value;
  var el=document.getElementById('list');el.innerHTML='';
  var shown=0;
  for(var i=0;i<RUNBOOKS.length;i++){
    var r=RUNBOOKS[i];
    if(f==='manual'){if(!r.manual)continue;}
    else if(f!=='all'&&r.where!==f)continue;
    shown++;
    var card=document.createElement('div');card.className='card';card.setAttribute('role','listitem');
    var head=document.createElement('div');head.className='rb-head';
    var t=document.createElement('span');t.className='rb-title';t.textContent=r.title;
    var b=document.createElement('span');b.className='badge '+(r.where==='host'?'HOST':'CONTAINER');b.textContent=r.where.toUpperCase();
    head.appendChild(t);head.appendChild(b);
    card.appendChild(head);
    var p=document.createElement('div');p.className='rb-purpose';p.textContent=r.purpose;
    card.appendChild(p);
    if(r.manual){var mb=document.createElement('span');mb.className='badge MANUAL';mb.textContent='MANUAL';head.appendChild(mb);}
    for(var j=0;j<r.commands.length;j++){
      var row=document.createElement('div');row.className='cmd';
      var code=document.createElement('code');code.textContent=r.commands[j];
      var btn=document.createElement('button');btn.textContent='copy';btn.dataset.cmd=r.commands[j];btn.setAttribute('aria-label','copy command');
      btn.addEventListener('click',function(){copy(this.dataset.cmd,this);});
      row.appendChild(code);row.appendChild(btn);
      card.appendChild(row);
    }
    if(r.note){var n=document.createElement('div');n.className='rb-note';n.textContent=r.note;card.appendChild(n);}
    el.appendChild(card);
  }
  document.getElementById('count').textContent=shown+' of '+RUNBOOKS.length+' runbooks';
  if(!shown){el.innerHTML='<div class="muted" data-empty>No runbooks match this filter.</div>';}
}
function copy(text,btn){
  function done(){btn.textContent='copied';setTimeout(function(){btn.textContent='copy';},1200);}
  function fallback(){
    var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();
    try{document.execCommand('copy');}catch(e){}
    document.body.removeChild(ta);done();
  }
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(done,fallback);}
  else{fallback();}
}
document.getElementById('f').addEventListener('change',render);
fetch('/api/runbooks').then(function(r){return r.json();}).then(function(d){RUNBOOKS=d;render();}).catch(function(){document.getElementById('list').innerHTML='<div class="muted" data-error>(runbooks unavailable)</div>';});
</script></body></html>`;

const managedHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode manage</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 a{color:#58a6ff;text-decoration:none;font-size:13px}
 .muted{color:#8b949e}
 .bar{display:flex;align-items:center;gap:10px;margin:10px 0}
 select{background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px}
 .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px;margin:10px 0}
 .rb-head{display:flex;align-items:center;gap:8px;margin-bottom:4px}
 .rb-title{font-weight:600;font-size:14px}
 .badge{display:inline-block;padding:1px 6px;border-radius:999px;font-size:11px}
 .badge.HOST{background:#b6232433;color:#ff7b72}
 .badge.CONTAINER{background:#2ea04333;color:#7ee787}
 .rb-head{cursor:pointer}
 .rb-head::before{content:'▾ ';color:#8b949e}
 .card.collapsed .rb-head::before{content:'▸ '}
 .card.collapsed .cbody{display:none}
 .rb-purpose{font-size:12px;color:#8b949e;margin-bottom:6px}
 .cmd{display:flex;gap:8px;align-items:flex-start;background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:6px 8px;margin:0 0 6px}
 .cmd code{flex:1;white-space:pre-wrap;word-break:break-word;font-size:12px}
 button{background:#1f6feb;color:#fff;border:0;border-radius:999px;padding:4px 10px;font-size:12px;cursor:pointer}
 .count{font-size:11px}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("manage")}
<main id="main" tabindex="-1">
<h1>opencode manage</h1>
<div class="muted" style="font-size:12px">The repo's tools, surfaced read-only. host = run where docker/browser live; container = safe inside the agent container. Copy, then paste into a terminal.</div>
<div id="providers"></div>
<div class="bar"><label class="muted" for="f">filter</label><select id="f"><option value="all">all</option><option value="container">container only</option><option value="host">host only</option></select></div>
<div id="count" class="muted count"></div>
<div id="list"></div>
</main>
<script>
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
var TOOLS=[];
function render(){
  var f=document.getElementById('f').value;
  var el=document.getElementById('list');el.innerHTML='';
  var shown=0;
  for(var i=0;i<TOOLS.length;i++){
    var t=TOOLS[i];
    if(f!=='all'&&t.where!==f)continue;
    shown++;
    var card=document.createElement('div');card.className='card collapsed';
    var head=document.createElement('div');head.className='rb-head';
    head.setAttribute('tabindex','0');head.setAttribute('role','button');head.setAttribute('aria-expanded','false');
    head.addEventListener('click',function(){var c=this.parentElement;var shut=c.classList.toggle('collapsed');this.setAttribute('aria-expanded',shut?'false':'true');});
    head.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();this.click();}});
    var ti=document.createElement('span');ti.className='rb-title';ti.textContent=t.title;
    var b=document.createElement('span');b.className='badge '+(t.where==='host'?'HOST':'CONTAINER');b.textContent=t.where.toUpperCase();
    head.appendChild(ti);head.appendChild(b);card.appendChild(head);
    var cbody=document.createElement('div');cbody.className='cbody';card.appendChild(cbody);
    var p=document.createElement('div');p.className='rb-purpose';p.textContent=t.purpose;cbody.appendChild(p);
    for(var j=0;j<t.commands.length;j++){
      var row=document.createElement('div');row.className='cmd';
      var code=document.createElement('code');code.textContent=t.commands[j];
      var btn=document.createElement('button');btn.textContent='copy';btn.dataset.cmd=t.commands[j];btn.setAttribute('aria-label','copy command');
      btn.addEventListener('click',function(){copy(this.dataset.cmd,this);});
      row.appendChild(code);row.appendChild(btn);cbody.appendChild(row);
    }
    el.appendChild(card);
  }
  document.getElementById('count').textContent=shown+' of '+TOOLS.length+' tools';
}
function copy(text,btn){
  function done(){btn.textContent='copied';setTimeout(function(){btn.textContent='copy';},1200);}
  function fallback(){var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();try{document.execCommand('copy');}catch(e){}document.body.removeChild(ta);done();}
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(done,fallback);}else{fallback();}
}
document.getElementById('f').addEventListener('change',render);
fetch('/api/tools').then(function(r){return r.json();}).then(function(d){TOOLS=d;render();}).catch(function(){document.getElementById('list').innerHTML='<div class="muted">(tools unavailable)</div>';});
fetch('/api/providers').then(function(r){return r.json();}).then(function(d){
  var h='<div class="card"><div class="rb-head"><span class="rb-title">Providers</span></div>';
  h+='<div class="muted" style="font-size:12px">default: '+esc(d.default_model||'?')+' &middot; allow: '+esc((d.allow||[]).join(', '))+' &middot; deny: '+esc((d.deny||[]).join(', '))+'</div>';
  for(var i=0;i<(d.providers||[]).length;i++){var p=d.providers[i];
    h+='<div class="item"><span class="tag">'+esc(p.npm)+'</span><b>'+esc(p.id)+'</b> '+esc(p.name)+' <span class="muted">models: '+esc((p.models||[]).join(', '))+' &middot; env: '+esc((p.env||[]).join(', ')||'-')+'</span></div>';}
  h+='<div class="rb-purpose">Add a provider: create the key, add it to .env.local (mode 0600), add a provider block to opencode.json with provider.env, then restart opencode-web and pick it in /models. This config-defined provider will not appear in /connect. See the connect-gemini runbook.</div></div>';
  document.getElementById('providers').innerHTML=h;
}).catch(function(){});
</script></body></html>`;

const docsHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode docs</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 select{background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px;margin:0 0 10px}
 pre{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:14px;white-space:pre-wrap;word-break:break-word;font-size:12px;line-height:1.5;max-height:75vh;overflow:auto}
 .muted{color:#8b949e;font-size:12px}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("docs")}
<main id="main" tabindex="-1">
<h1>opencode docs</h1>
<div class="muted" style="margin-bottom:8px">The repo's own rules, handoff and docs, rendered in-UI. Read-only; whitelisted files only.</div>
<select id="docsel" aria-label="Select a document to view"></select>
<pre id="docbody">loading...</pre>
</main>
<script>
var DOCS=["HANDOFF.md","RULES.md","README.md","scripts/README.txt","HANDOFF-PROMPT.txt"];
var sel=document.getElementById('docsel');
for(var i=0;i<DOCS.length;i++){var o=document.createElement('option');o.value=DOCS[i];o.textContent=DOCS[i];sel.appendChild(o);}
async function loadDoc(name){
  var body=document.getElementById('docbody');
  body.textContent='loading...';
  try{var r=await fetch('/api/doc?name='+encodeURIComponent(name));body.textContent=r.ok?await r.text():'('+name+' not found)';}
  catch(e){body.textContent='(failed to load '+name+')';}
}
sel.addEventListener('change',function(){loadDoc(sel.value);});
loadDoc(DOCS[0]);
</script></body></html>`;

const modelsHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode models</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d}
 .num{text-align:right;font-variant-numeric:tabular-nums}
 .ok{color:#3fb950}.no{color:#8b949e}
 .muted{color:#8b949e;font-size:12px}
 .banner{padding:10px 14px;border-radius:8px;margin:8px 0;border:1px solid #30363d}
 .banner.ok{border-color:#2ea043}.banner.ask{border-color:#d29922}.banner.block{border-color:#ff7b72}
 #cat{overflow-x:auto}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("models")}
<main id="main" tabindex="-1">
<h1>opencode models</h1>
<div id="banner" class="banner"><span class="muted" data-loading>loading...</span></div>
<div class="muted" id="policy"></div>
<h2>Catalog</h2><div id="cat"><span class="muted" data-loading>loading...</span></div>
 <div class="muted">This is the cost policy, not a guarantee: opencode/* personal-free rows are gateway-metered and can return "Free usage exceeded, subscribe to Go" even when listed ok. Prefer opencode-go/* (Go pool) or direct deepseek/gemini. Switch with /models (TUI) or opencode run -m &lt;id&gt;.</div>
</main>
<script>
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
async function load(){
  var d=null;
  try{var r=await fetch('/api/models');d=r.ok?await r.json():null;}
  catch(e){d=null;}
  var b=document.getElementById('banner');
  if(!d){b.innerHTML='<span class="muted" data-error>(models unavailable)</span>';document.getElementById('cat').innerHTML='';return;}
  if(!d||d.available===false||!d.models||!d.models.length){b.textContent='no catalog yet - run ./scripts/models.sh --write (or ./scripts/harness.sh)';return;}
  var v=d.verdict||'?';
  b.className='banner '+(v==='ALLOW'?'ok':(v==='ASK'?'ask':'block'));
  b.innerHTML='<b>'+esc(v)+'</b> - '+esc(d.reason||'')+'<br>current: <b>'+esc(d.current||'?')+'</b> - recommended: <b>'+esc((d.recommended&&d.recommended.id)||'?')+'</b>';
  document.getElementById('policy').textContent='policy: max_input=$'+(d.policy&&d.policy.max_input_per_m_usd)+'/1M  allow='+JSON.stringify((d.policy&&d.policy.allow)||[])+'  deny='+JSON.stringify((d.policy&&d.policy.deny)||[]);
  var allow={};(d.allowed||[]).forEach(function(x){allow[x]=1;});
  var h='<table><caption>model catalog with cost policy verdicts</caption><tr><th scope="col"></th><th scope="col">model</th><th scope="col" class="num">in $/1M</th><th scope="col" class="num">out</th><th scope="col" class="num">ctx</th><th scope="col">img</th><th scope="col">tool</th></tr>';
  for(var i=0;i<d.models.length;i++){var m=d.models[i];var ok=allow[m.id];
    h+='<tr><td class="'+(ok?'ok':'no')+'">'+(ok?'ok':'no')+'</td><td>'+esc(m.id)+'</td><td class="num">'+m.input+'</td><td class="num">'+m.output+'</td><td class="num">'+m.context+'</td><td>'+(m.attachment?'yes':'')+'</td><td>'+(m.toolcall?'yes':'')+'</td></tr>';}
  document.getElementById('cat').innerHTML=h+'</table>';
}
load();
</script></body></html>`;

function send(res, code, body, type) {
  res.writeHead(code, {
    "Content-Type": type,
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  res.end(body);
}

const SSE_CLIENTS = new Set();
// cost/activity are async (worker-backed); awaiting them is what makes the
// snapshot real. Returning the promises stringified to `{}`, which made the
// client render nothing and left "Live activity"/"Todos" at "loading...".
async function ssePayload() {
  const [cost, activity] = await Promise.all([apiCost(), apiActivity()]);
  return { cost, activity, todos: apiTodos() };
}
const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  const params = qs(req);
  if (url === "/favicon.ico") {
    res.writeHead(204, { "Cache-Control": "max-age=86400" });
    res.end();
  } else if (url === "/api/stream") {
    // snapshot -> deltas (durable-pi pattern): one server-side broadcast loop
    // feeds every client, so clients never poll; a reconnect gets a fresh
    // snapshot. Replaces per-client polling (the single-thread contention).
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Connection": "keep-alive", "X-Accel-Buffering": "no" });
    const client = { write: (ev, data) => { try { res.write("event: " + ev + "\ndata: " + JSON.stringify(data) + "\n\n"); } catch { /* client gone */ } } };
    SSE_CLIENTS.add(client);
    try {
      client.write("snapshot", await ssePayload());
    } catch {
      client.write("snapshot", { cost: null, activity: null, todos: [] });
    }
    req.on("close", () => SSE_CLIENTS.delete(client));
  } else if (url === "/") {
    send(res, 200, html, "text/html; charset=utf-8");
  } else if (url === "/explore") {
    send(res, 200, exploreHtml, "text/html; charset=utf-8");
  } else if (url === "/viz") {
    res.writeHead(302, { "Location": "/explore", "Cache-Control": "no-store" });
    res.end();
  } else if (url.indexOf("/vendor/") === 0) {
    const name = url.slice("/vendor/".length);
    if (name === "d3.min.js" || name === "d3-sankey.min.js" || name === "plot.umd.min.js") {
      try {
        const body = readFileSync(new URL("./vendor/" + name, import.meta.url));
        res.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8", "Cache-Control": "max-age=86400" });
        res.end(body);
      } catch {
        send(res, 404, "not found\n", "text/plain");
      }
    } else {
      send(res, 404, "not found\n", "text/plain");
    }
  } else if (url === "/runbooks") {
    send(res, 200, runbooksHtml, "text/html; charset=utf-8");
  } else if (url === "/manage") {
    send(res, 200, managedHtml, "text/html; charset=utf-8");
  } else if (url === "/docs") {
    send(res, 200, docsHtml, "text/html; charset=utf-8");
  } else if (url === "/models") {
    send(res, 200, modelsHtml, "text/html; charset=utf-8");
  } else if (url === "/api/models") {
    send(res, 200, JSON.stringify(apiModels()), "application/json");
  } else if (url === "/api/solutions") {
    send(res, 200, JSON.stringify(apiSolutions()), "application/json");
  } else if (url === "/api/doc") {
    const body = apiDoc(params.name);
    if (body == null) {
      send(res, 404, "not found\n", "text/plain");
    } else {
      send(res, 200, body, "text/plain; charset=utf-8");
    }
  } else if (url === "/api/runbooks") {
    send(res, 200, JSON.stringify(RUNBOOKS), "application/json");
  } else if (url === "/api/tools") {
    send(res, 200, JSON.stringify(apiTools()), "application/json");
  } else if (url === "/api/rev") {
    send(res, 200, JSON.stringify(apiRev()), "application/json");
  } else if (url === "/api/code") {
    send(res, 200, JSON.stringify(apiCode(Number(params.limit) || 200)), "application/json");
  } else if (url === "/api/providers") {
    send(res, 200, JSON.stringify(apiProviders()), "application/json");
  } else if (url === "/api/overview") {
    send(res, 200, JSON.stringify(apiOverview(Number(params.limit) || 500, Number(params.offset) || 0)), "application/json");
  } else if (url === "/api/schema") {
    send(res, 200, JSON.stringify(apiSchema()), "application/json");
  } else if (url === "/api/integrations") {
    send(res, 200, JSON.stringify(await apiIntegrations()), "application/json");
  } else if (url === "/api/ab") {
    send(res, 200, JSON.stringify(apiAb(Number(params.limit) || 200)), "application/json");
  } else if (url === "/api/ocr") {
    send(res, 200, JSON.stringify(apiOcr(Number(params.limit) || 100)), "application/json");
  } else if (url === "/api/duplicates") {
    send(res, 200, JSON.stringify(apiDuplicates()), "application/json");
  } else if (url === "/api/export/ocr") {
    const rows = ocrRows(2000);
    let body = "id,ts,image,engine,lang,text\n";
    for (const r of rows) {
      body += '"' + r.id + '","' + String(r.ts || "") + '","' + String(r.image || "").replace(/"/g, '""') + '","' + String(r.engine || "") + '","' + String(r.lang || "") + '","' + String(r.text || "").replace(/"/g, '""') + '"\n';
    }
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=opencode-ocr.csv" });
    res.end(body);
  } else if (url === "/api/export/patterns") {
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=opencode-patterns.csv" });
    res.end(await apiExportPatterns());
  } else if (url === "/api/export/guard") {
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=opencode-guard.csv" });
    res.end(apiExportGuard());
  } else if (url === "/api/signals") {
    send(res, 200, JSON.stringify(await apiSignals()), "application/json");
  } else if (url === "/api/guard") {
    send(res, 200, JSON.stringify(apiGuard(Number(params.limit) || 30)), "application/json");
  } else if (url === "/api/health") {
    send(res, 200, JSON.stringify(await apiHealth()), "application/json");
  } else if (url === "/api/ops") {
    send(res, 200, JSON.stringify(await apiOps()), "application/json");
  } else if (url === "/api/patterns") {
    send(res, 200, JSON.stringify(await apiPatterns(Number(params.limit) || 30)), "application/json");
  } else if (url === "/api/trends") {
    send(res, 200, JSON.stringify(await apiTrends()), "application/json");
  } else if (url === "/api/cost") {
    send(res, 200, JSON.stringify(await apiCost()), "application/json");
  } else if (url === "/api/balance") {
    send(res, 200, JSON.stringify(await apiBalance()), "application/json");
  } else if (url === "/api/config") {
    send(res, 200, JSON.stringify(await apiConfig()), "application/json");
  } else if (url === "/api/activity") {
    send(res, 200, JSON.stringify(await apiActivity()), "application/json");
  } else if (url === "/api/todos") {
    send(res, 200, JSON.stringify(apiTodos()), "application/json");
  } else if (url === "/api/sessions") {
    send(res, 200, JSON.stringify(apiSessions(Number(params.limit) || 200, Number(params.offset) || 0)), "application/json");
  } else if (url === "/api/parts") {
    send(res, 200, JSON.stringify(apiParts(params.session || null, Number(params.limit) || 600)), "application/json");
  } else if (url === "/api/session") {
    send(res, 200, JSON.stringify(apiSessionDetail(params.id, Number(params.limit) || 400)), "application/json");
  } else if (url === "/api/search") {
    send(res, 200, JSON.stringify(await apiSearch(params.q, Number(params.limit) || 20)), "application/json");
  } else if (url === "/api/semantic") {
    send(res, 200, JSON.stringify(await apiSemantic(params.q, Number(params.limit) || 20)), "application/json");
  } else if (url === "/api/export/session") {
    const fmt = (params.format || "txt").toLowerCase();
    const body = apiExportSession(params.id, fmt === "md" ? "md" : fmt === "json" ? "json" : "txt");
    if (body == null) {
      send(res, 404, "session not found\n", "text/plain");
    } else {
      const ct = fmt === "json" ? "application/json" : "text/plain; charset=utf-8";
      const ext = fmt === "json" ? "json" : fmt === "md" ? "md" : "txt";
      res.writeHead(200, { "Content-Type": ct, "Content-Disposition": "attachment; filename=session-" + (params.id || "export") + "." + ext });
      res.end(body);
    }
  } else if (url === "/api/words") {
    send(res, 200, JSON.stringify(await apiWords(Number(params.limit) || 80)), "application/json");
  } else if (url === "/api/board") {
    send(res, 200, JSON.stringify(await apiBoard()), "application/json");
  } else if (url === "/api/export") {
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=opencode-sessions.csv" });
    res.end(apiExport());
  } else {
    send(res, 404, "not found\n", "text/plain");
  }
});

server.on("error", (err) => {
  if (err && (err.code === "EADDRINUSE" || err.code === "EACCES")) {
    console.error(
      "error: cannot bind http://" + host + ":" + port + " (" + err.code + "). " +
      "The dashboard is already running (the opencode-web container publishes " +
      "127.0.0.1:5099). Open http://127.0.0.1:5099, or set DASH_PORT to a free port."
    );
  } else {
    console.error("error: " + (err && err.message ? err.message : err));
  }
  process.exit(1);
});

let SSE_REFRESHING = false;
setInterval(async () => {
  if (!SSE_CLIENTS.size || SSE_REFRESHING) return;
  SSE_REFRESHING = true;
  let payload;
  try { payload = await ssePayload(); } catch { SSE_REFRESHING = false; return; }
  SSE_REFRESHING = false;
  for (const c of SSE_CLIENTS) c.write("delta", payload);
}, 5000);
server.listen(port, host, () => {
  console.log("opencode observability: http://" + host + ":" + port + "  (db: " + dbPath + ")");
  // No eager pre-warm. The worker is single-threaded: pre-computing
  // /api/board (~19 s) and /api/health (~10-30 s) at startup starved every
  // other worker-backed API (semantic, trends, cost) for ~30 s. Instead the
  // heavy panels are on-demand and /api/health + /api/signals are seeded from
  // their durable snapshots, so a restart serves them instantly.
});
