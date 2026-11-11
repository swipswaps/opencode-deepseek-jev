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
import { randomBytes, timingSafeEqual } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, existsSync, writeFileSync, renameSync, mkdirSync } from "node:fs";
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
const SEGMENTS = (process.env.DASH_SEGMENTS || "cost,activity,todos")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const SSE_MS = Math.max(1000, Number(process.env.DASH_SSE_MS) || 5000);
const AUTO_SHED = process.env.DASH_AUTO_SHED === "1";

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

const PWA_MANIFEST = {
  id: "/",
  name: "opencode observability",
  short_name: "observability",
  description: "Local OpenCode/DeepSeek cost, activity, sessions, and guard telemetry.",
  start_url: "/?source=pwa",
  scope: "/",
  display: "standalone",
  background_color: "#0d1117",
  theme_color: "#0d1117",
  lang: "en",
  dir: "ltr",
  orientation: "any",
  categories: ["developer", "productivity"],
  icons: [
    { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" }
  ]
};
const APP_MANIFEST = {
  id: "/app/",
  name: "opencode observability (MUI)",
  short_name: "observability",
  description: "Material UI observability app for the local OpenCode/DeepSeek store.",
  start_url: "/app/",
  scope: "/app/",
  display: "standalone",
  background_color: "#0d1117",
  theme_color: "#0d1117",
  lang: "en",
  dir: "ltr",
  orientation: "any",
  categories: ["developer", "productivity"],
  icons: PWA_MANIFEST.icons
};
const SW_JS = `const CACHE="ocdash-v3";
const SHELL=["/","/graph","/app/","/vendor/d3.min.js","/vendor/plot.umd.min.js","/icon-192.png","/icon-512.png"];
self.addEventListener("install",(e)=>{self.skipWaiting();e.waitUntil(caches.open(CACHE).then((c)=>Promise.all(SHELL.map((u)=>c.add(u).catch(()=>{})))));});
self.addEventListener("activate",(e)=>{e.waitUntil(caches.keys().then((ks)=>Promise.all(ks.filter((k)=>k!==CACHE).map((k)=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener("fetch",(e)=>{const r=e.request;if(r.method!=="GET")return;const u=new URL(r.url);if(u.origin!==self.location.origin||u.pathname.startsWith("/api/"))return;
if(u.pathname.startsWith("/vendor/")||u.pathname.startsWith("/icon-")||u.pathname.startsWith("/app/assets/")){e.respondWith(caches.match(r).then((c)=>c||fetch(r).then((n)=>{const cp=n.clone();caches.open(CACHE).then((x)=>x.put(r,cp));return n;})));return;}
if(r.mode==="navigate"){e.respondWith(fetch(r).then((n)=>{const cp=n.clone();caches.open(CACHE).then((x)=>x.put(r,cp));return n;}).catch(()=>caches.match(r).then((c)=>c||caches.match("/"))));}
});`;

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
  ".nav a.active{background:#1f6feb;border-color:#1f6feb;color:#fff}" +
  "@media(max-width:720px){.nav{flex-wrap:nowrap;overflow-x:auto;gap:4px;padding:8px 0;margin:-10px 0 10px;scrollbar-width:none}.nav::-webkit-scrollbar{display:none}.nav .brand{display:none}.nav a{flex:0 0 auto;padding:10px 12px;min-height:44px;box-sizing:border-box}.nav #res,.nav #rev{display:none}.nav #theme{flex:0 0 auto;margin-left:0!important;min-height:44px}}";
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
const NAV_ITEMS = [["/", "dashboard"], ["/recovery", "recovery"], ["/usability", "usability"], ["/graph", "graph"], ["/explore", "explore"], ["/app/", "app"], ["/models", "models"],
                   ["/settings", "settings"], ["/runbooks", "runbooks"], ["/manage", "manage"], ["/docs", "docs"],
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
  ".skip-link:focus{left:8px}" +
  ":focus-visible{outline:2px solid var(--accent);outline-offset:2px}" +
  "pre{overflow-x:auto}";

function nav(active) {
  let h = "<style>" + NAV_CSS + THEME_CSS + CMDK_CSS + "</style><a class=\"skip-link\" href=\"#main\">Skip to main content</a><nav class=\"nav\" aria-label=\"Primary\"><span class=\"brand\">opencode observability</span>";
  for (const it of NAV_ITEMS) {
    h += "<a href=\"" + it[0] + "\"" + (it[1] === active ? " class=\"active\" aria-current=\"page\"" : "") + ">" + it[1] + "</a>";
  }
  h += "<span id=\"res\" class=\"muted\" style=\"font-size:11px;margin-right:8px\" title=\"container resources\"></span>";
  h += "<button id=\"theme\" class=\"tab\" title=\"toggle light/dark\" aria-label=\"toggle light or dark theme\" style=\"margin-left:auto\">&#9680; theme</button><span id=\"rev\" class=\"muted\" style=\"font-size:11px\"></span>";
  h += "</nav><script>fetch('/api/rev').then(function(r){return r.json();}).then(function(d){var e=document.getElementById('rev');if(!e)return;e.textContent=d.stale?('STALE served '+(d.served||'?')+' vs HEAD '+(d.head||'?')):('rev '+(d.served||'?'));if(d.stale)e.style.color='#ff7b72';}).catch(function(){});</script>";
  h += "<script>setInterval(function(){fetch('/api/resources').then(function(r){return r.json();}).then(function(d){var e=document.getElementById('res');if(!e)return;var c=(d.psi&&d.psi.cpu&&d.psi.cpu.some)?d.psi.cpu.some[0]:0;e.textContent='cpu '+c+'% rss '+d.node_rss_mb+'MB live '+d.sse_clients;}).catch(function(){});},10000);</script>";
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
  h += "{label:'settings',hint:'providers · pause/resume',href:'/settings'},";
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
const DOC_FILES = ["HANDOFF.md", "RULES.md", "README.md", "scripts/README.txt", "HANDOFF-PROMPT.txt", "docs/USABILITY-TESTING.md", "docs/STATUS-AUTOMATION.md"];
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

// ---------------------------------------------------------------------------
// Settings: one redacted provider matrix + a safe pause/resume control.
// The browser never sees or sends a secret. Pause writes DESIRED state; the
// host-side scripts/settings-apply.sh performs the env-key part (the container
// has .env.local masked) and recreates the container.
// ---------------------------------------------------------------------------
const SETTINGS_STATE_PATH = fileURLToPath(new URL("../data/observability/settings-state.json", import.meta.url));
const KNOWN_PROVIDER_ENV = {
  anthropic: "ANTHROPIC_API_KEY", deepseek: "DEEPSEEK_API_KEY", gemini: "GEMINI_API_KEY",
  subq: "SUBQ_API_KEY", jev: "JEV_API_KEY", litellm: "LITELLM_MASTER_KEY",
  "opencode-go": "OPENCODE_CONSOLE_TOKEN", opencode: "OPENCODE_CONSOLE_TOKEN",
};

function readJsonAbsSafe(path, fallback) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return fallback; }
}

function writeJsonAtomicAbs(path, obj, mode = 0o644) {
  try { mkdirSync(path.slice(0, path.lastIndexOf("/")) || ".", { recursive: true }); } catch {}
  const tmp = path + ".tmp." + process.pid;
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n", { mode });
  renameSync(tmp, path);
}

function authProviderNames() {
  try {
    const home = process.env.HOME || "/home/node";
    const auth = JSON.parse(readFileSync(home + "/.local/share/opencode/auth.json", "utf8"));
    return Object.keys(auth || {});
  } catch {
    return [];
  }
}

function settingsState() {
  const s = readJsonAbsSafe(SETTINGS_STATE_PATH, {});
  return { updated: s.updated || "", providers: s.providers || {} };
}

function apiSettings() {
  const cfg = readJsonAbsSafe(fileURLToPath(new URL("../opencode.json", import.meta.url)), {});
  const policy = readJsonAbsSafe(fileURLToPath(new URL("../models.policy.json", import.meta.url)), {});
  const dp = readJsonAbsSafe(fileURLToPath(new URL("../scripts/decision_providers.json", import.meta.url)), { providers: [] });
  const state = settingsState();
  const keyReq = readJsonAbsSafe(SETTINGS_KEY_REQUEST, null);
  const authKeys = authProviderNames();
  const ids = new Set();
  for (const id of Object.keys(cfg.provider || {})) ids.add(id);
  for (const p of dp.providers || []) ids.add(p.id);
  for (const m of (policy.allow || []).concat(policy.deny || [])) {
    const s = String(m);
    if (s.indexOf("/") > 0) ids.add(s.split("/")[0]);
  }
  for (const k of authKeys) ids.add(k);
  for (const [id, env] of Object.entries(KNOWN_PROVIDER_ENV)) if (process.env[env]) ids.add(id);
  for (const id of Object.keys(state.providers || {})) ids.add(id);
  const decision = new Map((dp.providers || []).map((p) => [p.id, p]));
  const providers = [...ids].sort().map((id) => {
    const inConfig = !!(cfg.provider && cfg.provider[id]);
    const envVar = KNOWN_PROVIDER_ENV[id] || "";
    const envKey = !!(envVar && process.env[envVar]);
    const authEntry = authKeys.includes(id);
    const pol = (policy.allow || []).some((x) => x === id || String(x).startsWith(id + "/")) ? "allow"
      : (policy.deny || []).some((x) => x === id || String(x).startsWith(id + "/")) ? "deny" : "unlisted";
    const d = decision.get(id);
    const entry = state.providers[id] || null;
    const paused = !!(entry && entry.paused);
    const pendingApply = paused && entry && entry.applied !== true;
    const active = !paused && (inConfig || envKey || authEntry || (d && d.enabled));
    return {
      id,
      name: (cfg.provider && cfg.provider[id] && cfg.provider[id].name) || (d && d.name) || id,
      inConfig, envVar, envKey, authEntry, policy: pol,
      decision: d ? { enabled: d.enabled !== false } : null,
      paused, pausedSince: paused ? entry.since || "" : "", pendingApply,
      keyQueued: !!(keyReq && keyReq.provider === id),
      state: paused ? (pendingApply ? "paused (pending host apply)" : "paused") : active ? "active" : "unconfigured",
      hostActionRequired: pendingApply && envKey,
      hostCommand: pendingApply ? "./scripts/settings-apply.sh --apply --yes" : "",
    };
  });
  return {
    updated: state.updated || "",
    default_model: cfg.model || null,
    pausedCount: providers.filter((p) => p.paused).length,
    providers,
    note: "Redacted view of opencode.json, env presence, auth.json, models.policy.json and decision_providers.json. Pause writes desired state; the host applier removes the effective env key.",
  };
}

function apiSettingsAction(doc) {
  const id = String((doc && doc.id) || "").trim();
  const action = String((doc && doc.action) || "").trim();
  const confirm = String((doc && doc.confirm) || "").trim();
  if (!id) return { ok: false, error: "id required" };
  if (action !== "pause" && action !== "resume") return { ok: false, error: "action must be pause or resume" };
  const view = apiSettings();
  const provider = view.providers.find((p) => p.id === id);
  if (!provider) return { ok: false, error: "unknown provider: " + id };
  if (confirm !== id) return { ok: false, error: "typed confirmation must match: " + id };
  const state = settingsState();
  const now = new Date().toISOString();
  const entry = state.providers[id] || { envVar: provider.envVar || "", since: now };
  entry.envVar = entry.envVar || provider.envVar || "";
  if (action === "pause") {
    if (entry.paused) return { ok: true, skipped: "already paused", settings: view };
    entry.paused = true;
    entry.since = now;
    entry.applied = false;
    entry.reason = String((doc && doc.reason) || "").slice(0, 200);
  } else {
    if (!entry.paused) return { ok: true, skipped: "not paused", settings: view };
    entry.paused = false;
    entry.applied = false;
  }
  state.providers[id] = entry;
  state.updated = now;
  writeJsonAtomicAbs(SETTINGS_STATE_PATH, state);
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)));
    try { db.exec("PRAGMA busy_timeout = 500"); } catch {}
    db.exec("CREATE TABLE IF NOT EXISTS ledger(id INTEGER PRIMARY KEY, ts TEXT NOT NULL, type TEXT NOT NULL, actor TEXT DEFAULT '', tool TEXT DEFAULT '', resource TEXT DEFAULT '', verdict TEXT DEFAULT '', detail TEXT DEFAULT '', rev TEXT DEFAULT '', source TEXT DEFAULT '', source_key TEXT UNIQUE)");
    db.prepare("INSERT OR IGNORE INTO ledger(ts,type,actor,tool,resource,verdict,detail,rev,source,source_key) VALUES(?,?,?,?,?,?,?,?,?,?)")
      .run(now, "SETTINGS", "dashboard", "settings", "provider/" + id,
           action === "pause" ? "PAUSE" : "RESUME",
           "desired state " + action + " via /settings", "",
           "settings-state", "settings-" + id + "-" + action + "-" + now);
    db.close();
  } catch {}
  const after = apiSettings();
  const ap = after.providers.find((p) => p.id === id);
  return {
    ok: true, id, action, settings: after,
    hostActionRequired: !!(ap && ap.hostActionRequired),
    hostCommand: ap ? ap.hostCommand : "",
  };
}

const SETTINGS_KEY_REQUEST = fileURLToPath(new URL("../data/observability/key-request.json", import.meta.url));
const KEY_PREFIX = {
  anthropic: "sk-ant-", deepseek: "sk-", subq: "sk-", jev: "apikey_",
  gemini: "AIza", litellm: "sk-", opencode: "sk-", "opencode-go": "sk-",
};

// Queue a key entered in /app/#settings. The dashboard cannot write the
// host's .env.local (it is masked in the container), so it writes a mode-0600
// request in the shared data dir; the host path unit runs
// `rotate-guided.py --action apply-request`, which writes .env.local and
// deletes the request. The key is never returned or logged.
function apiSettingsKey(doc) {
  const id = String((doc && doc.id) || "").trim();
  const key = String((doc && doc.key) || "").trim();
  const confirm = String((doc && doc.confirm) || "").trim();
  if (!id) return { ok: false, error: "id required" };
  if (!key) return { ok: false, error: "key required" };
  if (confirm !== id) return { ok: false, error: "typed confirmation must match: " + id };
  const view = apiSettings();
  const p = view.providers.find((x) => x.id === id);
  if (!p || !p.envVar) return { ok: false, error: "provider has no env key: " + id };
  const prefix = KEY_PREFIX[id] || "";
  if (prefix && !key.startsWith(prefix)) return { ok: false, error: "key does not start with " + prefix };
  if (key.length < 12) return { ok: false, error: "key is too short" };
  const now = new Date().toISOString();
  const req = { ts: now, provider: id, env: p.envVar, key, source: "dashboard" };
  writeJsonAtomicAbs(SETTINGS_KEY_REQUEST, req, 0o600);
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)));
    try { db.exec("PRAGMA busy_timeout = 500"); } catch {}
    db.exec("CREATE TABLE IF NOT EXISTS ledger(id INTEGER PRIMARY KEY, ts TEXT NOT NULL, type TEXT NOT NULL, actor TEXT DEFAULT '', tool TEXT DEFAULT '', resource TEXT DEFAULT '', verdict TEXT DEFAULT '', detail TEXT DEFAULT '', rev TEXT DEFAULT '', source TEXT DEFAULT '', source_key TEXT UNIQUE)");
    db.prepare("INSERT OR IGNORE INTO ledger(ts,type,actor,tool,resource,verdict,detail,rev,source,source_key) VALUES(?,?,?,?,?,?,?,?,?,?)")
      .run(now, "SETTINGS", "dashboard", "settings", "provider/" + id, "KEY_QUEUE",
           "queued " + p.envVar + " (len " + key.length + ")", "", "dashboard-key-queue",
           "key-queue-" + id + "-" + now);
    db.close();
  } catch {}
  return { ok: true, queued: true, provider: id, env: p.envVar, len: key.length,
           note: "queued for the host applier; it writes .env.local and restarts the web container" };
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

// ---------------------------------------------------------------------------
// Project graph: real, selectable and editable. Nodes come from the repo's own
// catalogs and stores (tools/runbooks JSON, code.db, observability tables,
// benchmark/choices/pulse snapshots) - never synthetic data. Edits (position,
// label, note, hide, add/remove edge) persist in observability.db.graph_edit.
// ---------------------------------------------------------------------------
function readJsonRel(rel) {
  try {
    return JSON.parse(readFileSync(new URL(rel, import.meta.url), "utf8"));
  } catch {
    return null;
  }
}

function graphEditRows() {
  let db;
  try {
    db = new DatabaseSync(OBS_DB_PATH, { readOnly: true });
    const has = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='graph_edit'").get();
    if (!has) { db.close(); return []; }
    const rows = db.prepare("SELECT id, ts, action, node, source, target, payload FROM graph_edit ORDER BY id").all();
    db.close();
    return rows;
  } catch {
    try { if (db) db.close(); } catch { /* ignore */ }
    return [];
  }
}

function applyGraphEdits(nodes, links) {
  const seen = new Set(links.map((l) => l.source + "|" + l.target + "|" + l.kind));
  let applied = 0;
  for (const row of graphEditRows()) {
    let payload = {};
    try { payload = JSON.parse(row.payload || "{}"); } catch { payload = {}; }
    const a = String(row.action || "");
    if (a === "pos") {
      const n = nodes.get(row.node);
      if (n) {
        n.x = Number(payload.x); n.y = Number(payload.y); n.z = Number(payload.z);
        n.pinned = true; n.user = true; applied++;
      }
    } else if (a === "label") {
      const n = nodes.get(row.node);
      if (n && payload.label) { n.label = String(payload.label).slice(0, 120); n.user = true; applied++; }
    } else if (a === "note") {
      const n = nodes.get(row.node);
      if (n) { n.note = String(payload.note || "").slice(0, 2000); n.user = true; applied++; }
    } else if (a === "hidden") {
      const n = nodes.get(row.node);
      if (n) { n.hidden = !!payload.hidden; n.user = true; applied++; }
    } else if (a === "edge_add") {
      const s = nodes.get(row.source), t = nodes.get(row.target);
      const k = row.source + "|" + row.target + "|user";
      if (s && t && !seen.has(k)) { links.push({ source: row.source, target: row.target, kind: "user", w: 2 }); seen.add(k); applied++; }
    } else if (a === "edge_del") {
      for (let i = links.length - 1; i >= 0; i--) {
        if (links[i].source === row.source && links[i].target === row.target) { links.splice(i, 1); applied++; }
      }
    }
  }
  return applied;
}

const GRAPH_AREAS = ["security", "stalls", "tunnel", "usability", "automation", "observability", "code"];
const API_ROUTES = [
  "/api/cost", "/api/balance", "/api/activity", "/api/todos", "/api/sessions", "/api/session",
  "/api/parts", "/api/search", "/api/semantic", "/api/overview", "/api/trends", "/api/schema",
  "/api/integrations", "/api/ab", "/api/ocr", "/api/duplicates", "/api/signals", "/api/guard",
  "/api/health", "/api/ops", "/api/patterns", "/api/solutions", "/api/code", "/api/board",
  "/api/models", "/api/tools", "/api/runbooks", "/api/providers", "/api/benchmark",
  "/api/choices", "/api/pulse", "/api/recovery", "/api/graph",
];
const API_TABLE = {
  "/api/sessions": "session", "/api/session": "session", "/api/cost": "session", "/api/overview": "session",
  "/api/trends": "session", "/api/todos": "todo", "/api/board": "todo", "/api/health": "part",
  "/api/signals": "part", "/api/patterns": "part", "/api/activity": "part", "/api/parts": "part",
  "/api/search": "part", "/api/semantic": "part", "/api/integrations": "part", "/api/duplicates": "session",
  "/api/benchmark": "issue_bench", "/api/graph": "graph_edit",
};

function apiGraph() {
  const nodes = new Map();
  const links = [];
  const seen = new Set();
  const add = (id, label, type, group, extra = {}) => {
    if (!id || nodes.has(id)) return nodes.get(id);
    const n = { id, label: String(label || id), type, group, ...extra };
    nodes.set(id, n);
    return n;
  };
  const link = (s, t, kind = "ref", w = 1) => {
    if (!s || !t || s === t) return;
    const k = s + "|" + t + "|" + kind;
    if (seen.has(k)) return;
    seen.add(k);
    links.push({ source: s, target: t, kind, w });
  };

  for (const a of GRAPH_AREAS) add("area:" + a, a, "area", "control");

  const b = readJsonRel("../data/observability/benchmark.json") || {};
  for (const m of b.metrics || []) {
    const area = String(m.area || "observability");
    if (!GRAPH_AREAS.includes(area)) add("area:" + area, area, "area", "control");
    const id = "metric:" + area + "/" + m.metric;
    add(id, m.metric, "metric", "control", {
      area, value: m.value, unit: m.unit, verdict: m.verdict, note: m.detail, scored: m.scored !== false,
    });
    link(id, "area:" + area, "measures");
  }

  const choicesCfg = readJsonRel("../scripts/choices.json");
  const choicesState = readJsonRel("../data/observability/choices.json") || {};
  const decided = choicesState.choices || {};
  for (const c of (choicesCfg && choicesCfg.choices) || []) {
    const id = "choice:" + c.id;
    const area = /tunnel/.test(c.id) ? "tunnel" : "security";
    const st = decided[c.id] || {};
    add(id, c.id, "choice", "control", {
      question: c.question, recommended: c.recommended, selected: st.selected || null,
      status: st.status || "pending", note: c.why,
    });
    link(id, "area:" + area, "decides");
  }

  const usability = readJsonRel("../data/observability/usability.json") || {};
  if (usability && usability.axes) {
    const uid = "usability:last";
    add(uid, "usability run", "metric", "control", {
      verdict: usability.verdict || "SKIP", mode: usability.mode || "?",
      value: usability.fail_count, unit: "failures", note: usability.caveat || "",
    });
    link(uid, "area:usability", "measures");
    for (const axis of Object.keys(usability.axes)) {
      const d = usability.axes[axis] || {};
      const id = "usability:" + axis;
      add(id, axis, "metric", "control", {
        verdict: (d.fail ? "FAIL" : (d.pass ? "PASS" : "SKIP")),
        value: d.score, unit: "score", note: "pass=" + d.pass + " fail=" + d.fail + " skip=" + d.skip,
      });
      link(id, "area:usability", "measures");
    }
  }

  const pulse = readJsonRel("../data/observability/pulse.json") || {};
  for (const e of pulse.external || []) {
    const id = "issue:" + e.resource;
    add(id, e.resource, "issue", "external", { state: e.state, note: "observed " + (e.ts || "") });
    link(id, "area:tunnel", "watches");
  }

  for (const [list, kind] of [[RUNBOOKS, "runbook"], [TOOLS, "tool"]]) {
    for (const r of list || []) {
      if (!r || !r.id) continue;
      const id = kind + ":" + r.id;
      add(id, r.id, kind, "procedure", { where: r.where || "", note: r.purpose || "" });
      link(id, kind === "tool" ? "area:automation" : "area:observability", "belongs");
      const cmds = r.commands || [];
      for (const cmd of cmds) {
        const re = /scripts\/[A-Za-z0-9_./-]+\.(?:sh|py|mjs)/g;
        let m;
        while ((m = re.exec(String(cmd))) !== null) {
          const p = m[0];
          if (!existsSync(REPO_ROOT + p)) continue;
          add("file:" + p, p.split("/").pop(), "file", "code", { path: p });
          link(id, "file:" + p, "runs");
        }
      }
    }
  }

  try {
    const db = new DatabaseSync(CODE_DB_PATH, { readOnly: true });
    const files = db.prepare("SELECT path, ext, bytes, lines, flags_n FROM code ORDER BY flags_n DESC, bytes DESC LIMIT 140").all();
    const flags = db.prepare("SELECT name, COUNT(*) n FROM code_flag GROUP BY name ORDER BY n DESC").all();
    db.close();
    for (const f of files) {
      const id = "file:" + f.path;
      add(id, String(f.path).split("/").pop(), "file", "code", {
        path: f.path, ext: f.ext, bytes: f.bytes, lines: f.lines, flags_n: f.flags_n,
      });
      if (Number(f.flags_n) > 0) link(id, "area:code", "flagged", 1);
    }
    for (const fl of flags) {
      const id = "flag:" + fl.name;
      add(id, fl.name, "flag", "code", { count: fl.n });
    }
    try {
      const db2 = new DatabaseSync(CODE_DB_PATH, { readOnly: true });
      const refs = db2.prepare("SELECT path, name FROM code_flag LIMIT 400").all();
      db2.close();
      for (const r of refs) {
        if (nodes.has("file:" + r.path) && nodes.has("flag:" + r.name)) link("file:" + r.path, "flag:" + r.name, "contains");
      }
    } catch { /* flags are optional detail */ }
  } catch {
    add("store:code.db", "code.db", "store", "data", { note: "code index unavailable" });
  }

  for (const route of API_ROUTES) {
    const id = "api:" + route;
    add(id, route.replace("/api/", ""), "api", "surface", { route });
    link(id, "area:observability", "serves");
    const table = API_TABLE[route];
    if (table) link(id, "store:observability." + table, "reads");
  }

  try {
    const db = new DatabaseSync(OBS_DB_PATH, { readOnly: true });
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
    const small = new Set(["ledger", "ab_run", "ocr_run", "decision_route", "issue_bench", "graph_edit"]);
    for (const t of tables) {
      let rows = null;
      if (small.has(t.name)) {
        try { rows = db.prepare('SELECT COUNT(*) c FROM "' + t.name + '"').get().c; } catch { rows = null; }
      }
      const id = "store:observability." + t.name;
      add(id, t.name, "store", "data", { rows, db: "observability.db", table: t.name });
      link(id, "area:observability", "stored");
    }
    try {
      const ev = db.prepare(
        "SELECT type, COUNT(*) n FROM ledger WHERE ts >= datetime('now','-7 day') GROUP BY type ORDER BY n DESC LIMIT 14"
      ).all();
      for (const e of ev) {
        const id = "event:" + e.type;
        add(id, e.type, "event", "telemetry", { count: e.n });
        link(id, "store:observability.ledger", "recorded");
      }
    } catch { /* ledger optional */ }
    db.close();
  } catch {
    add("store:observability.db", "observability.db", "store", "data", { note: "unavailable" });
  }

  try {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    add("store:opencode.db", "opencode.db", "store", "data", { db: "opencode.db", note: "session store (read-only)" });
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
    for (const t of tables) {
      const id = "store:opencode." + t.name;
      add(id, t.name, "store", "data", { db: "opencode.db", table: t.name });
      link(id, "store:opencode.db", "part-of");
    }
    db.close();
  } catch { /* the store may be absent in a fixture */ }

  if (existsSync(UX_DB_PATH)) {
    add("store:ux.db", "ux.db", "store", "data", { db: "ux.db", note: "UX trace corpus" });
    link("store:ux.db", "area:observability", "stored");
  }

  const finalLinks = links.filter((l) => nodes.has(l.source) && nodes.has(l.target));
  const applied = applyGraphEdits(nodes, finalLinks);
  return {
    ts: new Date().toISOString(),
    rev: SERVED_REV,
    nodes: [...nodes.values()],
    links: finalLinks,
    areas: GRAPH_AREAS,
    edits_applied: applied,
    sources: ["scripts/tools.json", "scripts/runbooks.json", "scripts/choices.json",
              "data/observability/{benchmark,choices,pulse}.json", "code.db", "observability.db", "opencode.db"],
    editable: ["pos", "label", "note", "hidden", "edge_add", "edge_del", "reset"],
  };
}

function graphIdOk(v) {
  return typeof v === "string" && v.length > 0 && v.length <= 200 && /^[A-Za-z0-9_./:#-]+$/.test(v);
}

function apiGraphEdit(doc) {
  const action = String((doc && doc.action) || "");
  const allowed = new Set(["pos", "label", "note", "hidden", "edge_add", "edge_del", "reset"]);
  if (!allowed.has(action)) return { ok: false, error: "unknown action" };
  const node = String((doc && doc.node) || "");
  const source = String((doc && doc.source) || "");
  const target = String((doc && doc.target) || "");
  if (action === "pos" || action === "label" || action === "note" || action === "hidden") {
    if (!graphIdOk(node)) return { ok: false, error: "invalid node id" };
  }
  if (action === "edge_add" || action === "edge_del") {
    if (!graphIdOk(source) || !graphIdOk(target)) return { ok: false, error: "invalid edge ids" };
  }
  let payload = {};
  if (action === "pos") {
    const clamp = (v) => Math.max(-10000, Math.min(10000, Number(v) || 0));
    payload = { x: clamp(doc.x), y: clamp(doc.y), z: clamp(doc.z) };
  } else if (action === "label") {
    payload = { label: String(doc.label || "").slice(0, 120) };
  } else if (action === "note") {
    payload = { note: String(doc.note || "").slice(0, 2000) };
  } else if (action === "hidden") {
    payload = { hidden: !!doc.hidden };
  }
  let db;
  try {
    db = new DatabaseSync(OBS_DB_PATH);
    db.exec("PRAGMA busy_timeout=3000");
    db.exec("CREATE TABLE IF NOT EXISTS graph_edit(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, action TEXT, node TEXT, source TEXT, target TEXT, payload TEXT)");
    if (action === "reset") {
      db.exec("DELETE FROM graph_edit");
    } else {
      db.prepare("INSERT INTO graph_edit(ts,action,node,source,target,payload) VALUES(?,?,?,?,?,?)")
        .run(new Date().toISOString(), action, node, source, target, JSON.stringify(payload));
    }
    db.close();
    return { ok: true, action, node: node || null, edits_applied: graphEditRows().length };
  } catch (e) {
    try { if (db) db.close(); } catch { /* ignore */ }
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

// --- guided usability sessions (human data; never fabricated) --------------
function apiUsabilityTasks() {
  return readJsonRel("../scripts/usability-tasks.json") || { version: 0, tasks: [], sus_items: [] };
}

function susScore(answers) {
  if (!Array.isArray(answers) || answers.length !== 10) return null;
  let total = 0;
  for (let i = 0; i < answers.length; i++) {
    const v = Number(answers[i]);
    if (!Number.isInteger(v) || v < 1 || v > 5) return null;
    total += i % 2 === 0 ? v - 1 : 5 - v;
  }
  return Math.round(total * 2.5 * 10) / 10;
}

function guidedRows(limit = 20) {
  let db;
  try {
    db = new DatabaseSync(OBS_DB_PATH, { readOnly: true });
    const has = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='usability_guided'").get();
    if (!has) { db.close(); return []; }
    const rows = db.prepare(
      "SELECT id,ts,rev,participant,mode,effectiveness,efficiency_s,satisfaction_sus,completed,total,notes,payload " +
      "FROM usability_guided ORDER BY id DESC LIMIT ?").all(limit);
    db.close();
    return rows.map((r) => {
      let payload = {};
      try { payload = JSON.parse(r.payload || "{}"); } catch { payload = {}; }
      return { ...r, tasks: payload.tasks || [], sus: payload.sus || null };
    });
  } catch {
    try { if (db) db.close(); } catch { /* ignore */ }
    return [];
  }
}

function apiUsabilityGuidedSave(doc) {
  const spec = apiUsabilityTasks();
  const ids = new Set((spec.tasks || []).map((t) => t.id));
  const input = (doc && doc.tasks) || [];
  if (!Array.isArray(input) || !input.length) return { ok: false, error: "tasks[] required" };
  const seen = new Set();
  const tasks = [];
  for (const r of input) {
    if (!r || !ids.has(r.id)) return { ok: false, error: "unknown task id: " + (r && r.id) };
    if (seen.has(r.id)) return { ok: false, error: "duplicate task id: " + r.id };
    seen.add(r.id);
    if (!(r.success === true || r.success === false || r.success === null || r.success === undefined)) {
      return { ok: false, error: "success must be boolean or null" };
    }
    let dur = r.duration_s;
    if (dur != null) {
      dur = Number(dur);
      if (!isFinite(dur) || dur < 0) return { ok: false, error: "duration_s invalid" };
    } else dur = null;
    let diff = r.difficulty == null ? null : Number(r.difficulty);
    if (diff != null && (!Number.isInteger(diff) || diff < 1 || diff > 5)) {
      return { ok: false, error: "difficulty must be 1..5" };
    }
    tasks.push({ id: r.id, success: r.success === undefined ? null : r.success,
                 duration_s: dur, difficulty: diff, note: String(r.note || "").slice(0, 500) });
  }
  const sus = doc && doc.sus != null ? doc.sus : null;
  if (sus != null && susScore(sus) == null) return { ok: false, error: "sus must be 10 integers 1..5" };
  const done = tasks.filter((t) => t.success === true);
  const times = done.map((t) => t.duration_s).filter((v) => typeof v === "number").sort((a, b) => a - b);
  const median = times.length ? (times.length % 2 ? times[(times.length - 1) / 2]
    : (times[times.length / 2 - 1] + times[times.length / 2]) / 2) : null;
  const session = {
    ts: new Date().toISOString(), rev: SERVED_REV,
    participant: String((doc && doc.participant) || "anonymous").slice(0, 60),
    mode: "human-guided", notes: String((doc && doc.notes) || "").slice(0, 1000),
    completed: done.length, failed: tasks.filter((t) => t.success === false).length,
    total: tasks.length,
    effectiveness: Math.round((done.length / tasks.length) * 1000) / 1000,
    efficiency_s: median == null ? null : Math.round(median * 1000) / 1000,
    satisfaction_sus: sus == null ? null : susScore(sus), sus,
    sus_threshold: 68, tasks,
  };
  if (doc && doc.dry_run) return { ok: true, dry_run: true, session };
  let db;
  try {
    db = new DatabaseSync(OBS_DB_PATH);
    db.exec("PRAGMA busy_timeout=3000");
    db.exec("CREATE TABLE IF NOT EXISTS usability_guided(" +
      "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, rev TEXT, participant TEXT, mode TEXT, " +
      "effectiveness REAL, efficiency_s REAL, satisfaction_sus REAL, completed INTEGER, total INTEGER, " +
      "notes TEXT, payload TEXT)");
    const cur = db.prepare(
      "INSERT INTO usability_guided(ts,rev,participant,mode,effectiveness,efficiency_s,satisfaction_sus," +
      "completed,total,notes,payload) VALUES(?,?,?,?,?,?,?,?,?,?,?)").run(
      session.ts, session.rev, session.participant, session.mode, session.effectiveness,
      session.efficiency_s, session.satisfaction_sus, session.completed, session.total,
      session.notes, JSON.stringify({ tasks, sus, participant: session.participant, notes: session.notes }));
    session.id = Number(cur.lastInsertRowid);
    db.close();
    return { ok: true, session };
  } catch (e) {
    try { if (db) db.close(); } catch { /* ignore */ }
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

function readBody(req, limit = 65536) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(new Error("body too large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
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
  return { budget: budgetUsd(), limit: Number(limit) || 500, offset: Number(offset) || 0,
           sessions: apiSessions(limit, offset) };
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

async function apiSearch(q, limit, full) {
  // Legacy substring search (measured 6.8 s). Cache by query and run in the
  // worker; /api/semantic is the fast FTS5 path for interactive search.
  // full=1 returns up to 20k chars per hit for the Activity timeline; the
  // search card keeps the 200-char teaser.
  const needle = String(q || "").replace(/[%_\\]/g, "");
  const lim = Number(limit) || 20;
  const wantFull = !!full;
  return asyncCached("search:" + needle + ":" + lim + ":" + (wantFull ? 1 : 0), CACHE_TTL_MS, "search",
    [needle, lim, wantFull], () => searchFresh(dbPath, needle, lim, wantFull));
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
const CODE_DB_PATH = fileURLToPath(new URL("../data/observability/code.db", import.meta.url));
const UX_DB_PATH = fileURLToPath(new URL("../data/observability/ux.db", import.meta.url));
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
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="theme-color" content="#0d1117"><link rel="manifest" href="/manifest.webmanifest"><link rel="apple-touch-icon" href="/icon-192.png"><title>opencode observability</title>
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
 body{font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;font-size:14px;line-height:1.5;user-select:text}
 .muted{color:#b1bac4}
 .card h2{font-size:14px;color:#c9d1d9}
 .item{font-size:13.5px;line-height:1.55;user-select:text}
 table{font-size:13px}
 th{color:#b1bac4}
 .srow .exp{user-select:none}
 .copy{background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;font-size:11px;padding:1px 5px;margin-left:6px;cursor:pointer;user-select:none;font-family:inherit}
 .copy:hover{color:#fff;border-color:#58a6ff}
 .item .copy{float:right;margin-left:8px}
 #timeline{max-height:520px;overflow:auto;border-top:1px solid #21262d;color:#c9d1d9;user-select:text}
 .tl-row{display:grid;grid-template-columns:74px 120px 96px 64px 58px minmax(200px,1fr) 92px;gap:6px;align-items:start;padding:3px 0;border-bottom:1px solid #21262d;font-size:12.5px;user-select:text}
 .tl-head{position:sticky;top:0;background:#161b22;color:#b1bac4;font-size:11px;z-index:2}
 .tl-lane{position:relative;height:18px;background:#0d1117;border:1px solid #21262d;border-radius:3px;overflow:hidden}
 .tl-lane i{position:absolute;top:3px;height:10px;border-radius:2px;opacity:.9}
 .tl-lane .tl-now{top:0;bottom:0;height:auto;width:0;border-left:1px dashed #f85149;background:none;opacity:1}
 .tl-lane .tl-dot{top:6px;width:6px;height:6px;border-radius:50%;opacity:1;transform:translateX(-50%)}
 .tl-axis{overflow:visible}
 .tl-tick,.tl-nowlabel{position:absolute;top:1px;font-size:8.5px;transform:translateX(-50%);pointer-events:none;white-space:nowrap}
 .tl-tick{color:#8b949e}.tl-nowlabel{color:#f85149}
 .tl-time,.tl-dur{font-variant-numeric:tabular-nums;color:#b1bac4}
 .tl-text{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.4;min-width:0;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}
 .tl-row .copy{justify-self:start}
 .tl-actions{display:flex;gap:4px;flex-wrap:wrap;justify-self:start}
 .tl-actions .copy{margin-left:0}
 .light .muted{color:#57606a}
 .light .card h2{color:#24292f}
 .light .item{color:#24292f}
 .light .copy{background:#f6f8fa;color:#24292f;border-color:#d0d7de}
 .light .tl-row{border-color:#d0d7de}
 .light .tl-head{background:#f6f8fa;color:#57606a}
 .light .tl-lane{background:#f6f8fa;border-color:#d0d7de}
 .light .tl-tick{color:#57606a}
 .light .tl-time,.light .tl-dur{color:#57606a}
 .light .tl-text{color:#24292f}
 .light #timeline{color:#57606a}
 .light #timeline text{fill:#24292f}
 .light #timeline svg{color:#57606a}
 .tl-controls{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 8px}
 .chip{background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:999px;font-size:12px;padding:3px 10px;min-height:28px;cursor:pointer;font-family:inherit}
 .chip:hover{color:#fff;border-color:#58a6ff}
 .chip.active{background:#1f6feb;border-color:#1f6feb;color:#fff}
 .tl-text.open{display:block;-webkit-line-clamp:unset;overflow:visible}
 .light .chip{background:#fff;color:#24292f;border-color:#d0d7de}
 .light .chip.active{background:#1f6feb;border-color:#1f6feb;color:#fff}
 @media(max-width:720px){
   body{padding:12px;padding-top:max(12px,env(safe-area-inset-top));padding-bottom:max(12px,env(safe-area-inset-bottom));padding-left:max(12px,env(safe-area-inset-left));padding-right:max(12px,env(safe-area-inset-right))}
   h1{font-size:20px}
   .card{padding:10px;margin:8px 0}
   #timeline{max-height:70vh;border-top:0;overflow:auto}
   .tl-head{display:none}
   .tl-row{grid-template-columns:1fr auto;grid-template-areas:"time copy" "type type" "text text" "dur dur";gap:2px 8px;padding:10px 0}
   .tl-time{grid-area:time;font-size:12px}
   .tl-type{grid-area:type}
   .tl-dur{grid-area:dur;font-size:11px}
   .tl-text{grid-area:text;-webkit-line-clamp:3}
   .tl-row>.tl-lane{display:none}
   .tl-row .tl-actions{grid-area:copy;justify-self:end}
   .tl-row .copy{min-height:44px;min-width:48px}
   .tl-row .tl-more{min-height:44px;min-width:44px}
   .tl-controls{gap:6px}
   .chip{min-height:44px;min-width:44px;padding:4px 12px}
   .copy{min-height:44px;min-width:44px}
   input#q{min-height:44px}
   .srow .exp{width:44px;height:44px;line-height:44px}
   .stat{min-width:calc(50% - 10px)}
   input#q{font-size:16px}
 }
</style></head>
<body>
${nav("dashboard")}
<main id="main" tabindex="-1">
<h1>opencode observability</h1>
<div id="session" class="muted" aria-live="polite"><span class="muted" data-loading>loading...</span></div>
<div class="row" id="stats" aria-live="polite"><span class="muted" data-loading>loading...</span></div>
<div class="card" id="pulse-card"><h2>Project pulse <span class="muted">(what is true · what needs you · next automatic)</span> <a href="/graph">open graph &gt;</a></h2><div id="pulse" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card" id="activity-card"><h2>Activity timeline <span class="muted">(newest first · filter · expand · live)</span> <span class="muted" id="act-count"></span> <button class="copy" type="button" data-copy-target="timeline-data">copy JSON</button></h2>
<div class="tl-controls" role="toolbar" aria-label="Activity filters">
 <button class="chip active" type="button" data-filter="all">All</button>
 <button class="chip" type="button" data-filter="tools">Tools</button>
 <button class="chip" type="button" data-filter="text">Text</button>
 <button class="chip" type="button" data-filter="reasoning">Reasoning</button>
 <button class="chip" type="button" data-filter="errors">Errors</button>
 <button class="chip" type="button" data-filter="steps">Steps</button>
 <button class="chip" type="button" data-limit="all" id="tl-limit">show all</button>
</div>
<div id="activity" aria-live="polite"><div id="timeline" aria-label="Activity timeline"><span class="muted" data-loading>loading...</span></div></div>
<textarea id="timeline-data" hidden aria-hidden="true" aria-label="Activity timeline data"></textarea></div>

<div class="card" id="flags-card" style="border-color:#d29922"><h2>Flags <span class="muted">(bottlenecks · cost · slowdowns · stalls — click an example)</span></h2><div id="flags" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Search <span class="muted">(ranked FTS: title · text · commands)</span></h2><input id="q" placeholder="search across sessions..." aria-label="Search sessions" aria-keyshortcuts="/"><div id="searchres" aria-live="polite"></div></div>
<div class="card"><h2>Config audit <span class="muted">(actual vs expected)</span></h2><div id="config" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Sessions <span class="muted">(▸ expands inline · title opens the session in a new tab)</span> <span class="muted" data-tz></span></h2><div id="sessions" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
<div class="card"><h2>Session detail <span class="muted" id="drill-id"></span></h2><div id="drill"><span class="muted">click a session row to drill down</span></div></div>
<div class="card"><h2>Todos</h2><div id="todos" aria-live="polite"><span class="muted" data-loading>loading...</span></div></div>
</main>
<script src="/vendor/d3.min.js"></script>
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
var lastActivity=null;
var tlDomain=null;
var actFilter='all', actLimit=30;
function copyText(t,btn){
  t=String(t==null?'':t);
  function done(){if(btn){var o=btn.textContent;btn.textContent='copied';setTimeout(function(){btn.textContent=o;},1200);}}
  function fallback(){try{var ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();document.execCommand('copy');document.body.removeChild(ta);done();}catch(e){}}
  try{if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,fallback);return;}}catch(e){}
  fallback();
}
document.addEventListener('click',function(ev){
  var b=ev.target&&ev.target.closest?ev.target.closest('[data-copy],[data-copy-target]'):null;
  if(!b)return;
  ev.preventDefault();ev.stopPropagation();
  var t=b.getAttribute('data-copy');
  if(t==null){var id=b.getAttribute('data-copy-target');var el=id&&document.getElementById(id);t=el?(el.value!=null?el.value:el.textContent):'';}
  copyText(t,b);
},true);
document.addEventListener('click',function(ev){
  var b=ev.target&&ev.target.closest?ev.target.closest('[data-tog]'):null;
  if(!b)return;
  ev.preventDefault();ev.stopPropagation();
  tog(b.getAttribute('data-tog'));
},true);
document.addEventListener('click',function(ev){
  var b=ev.target&&ev.target.closest?ev.target.closest('[data-filter],[data-limit]'):null;
  if(!b)return;
  ev.preventDefault();ev.stopPropagation();
  var f=b.getAttribute('data-filter');
  if(f){
    actFilter=f;
    var bs=document.querySelectorAll('#activity-card [data-filter]');
    for(var i=0;i<bs.length;i++){bs[i].classList.toggle('active',bs[i].getAttribute('data-filter')===actFilter);}
  }
  if(b.getAttribute('data-limit')!=null){actLimit=actLimit?0:30;b.textContent=actLimit?'show all':'show 30';}
  renderDiagTimeline(lastActivity);
},true);
function tog(ts){var el=document.getElementById('timeline');var top=el?el.scrollTop:0;expanded[ts]=expanded[ts]?0:1;renderDiagTimeline(lastActivity);if(el)el.scrollTop=top;}
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
    +'<td><a class="sopen" href="'+href+'" target="_blank" rel="noopener" title="open session in new tab">'+esc(s.title||'(untitled)')+'</a> <button class="copy" type="button" data-copy="'+id+'" title="copy session id">copy id</button></td>'
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
function renderPulse(p){
  var el=document.getElementById('pulse');if(!el)return;
  if(!p||!p.headline){failIfPristine('pulse','(pulse unavailable - run ./scripts/pulse.py)');return;}
  var sc=p.scores||{},h='';
  h+='<div style="font-size:14px;margin:2px 0 8px">'+esc(p.headline)+'</div>';
  h+='<div class="row">';
  var areas=['security','stalls','tunnel'];
  for(var i=0;i<areas.length;i++){var a=areas[i],v=sc[a];var cls=v==null?'':(v>=90?'ok':v>=60?'warn':'ERR');
    h+='<div class="stat"><b class="'+cls+'">'+(v==null?'n/a':v)+'</b><span>'+a+' score</span></div>';}
  h+='<div class="stat"><b>'+(p.pending_choices||0)+'</b><span>decisions</span></div>';
  var us=p.usability||{}; var uc=us.verdict==='PASS'?'ok':us.verdict==='FAIL'?'ERR':'';
  h+='<div class="stat"><b class="'+uc+'">'+esc(us.verdict||'n/a')+'</b><span>usability</span></div>';
  h+='</div>';
  if(us.ts){h+='<div class="muted" style="margin-top:4px">usability '+esc(us.mode||'')+' · effectiveness '+esc(us.effectiveness==null?'n/a':us.effectiveness)+' · failures '+esc(us.fail_count||0)+' · <a href="/usability">guided test + method</a></div>';}
  var gd=p.guided||{}; if(gd.id){h+='<div class="muted">guided session '+esc(gd.id)+' · effectiveness '+esc(gd.effectiveness==null?'n/a':gd.effectiveness)+' · SUS '+esc(gd.satisfaction_sus==null?'n/a':gd.satisfaction_sus)+'</div>';}
  var att=(p.attention||[]).slice(0,4);
  if(att.length){h+='<div style="margin-top:8px">';
    for(var j=0;j<att.length;j++){var x=att[j];
      if(x.kind==='choice'){h+='<div class="item">DECIDE <b>'+esc(x.id)+'</b> — '+esc(x.question||'');
        h+=' <span class="muted">recommended '+esc(x.recommended||'')+'</span> <button class="copy" type="button" data-copy="'+esc(x.apply||'')+'">copy command</button></div>';}
      else{h+='<div class="item"><span class="'+(x.level==='FAIL'?'ERR':'warn')+'">'+esc(x.level)+'</span> '+esc(x.id)+' = '+esc(x.value)+' <span class="muted">'+esc((x.detail||'').slice(0,120))+'</span></div>';}
    }
    h+='</div>';}
  if(p.next){h+='<div class="muted" style="margin-top:8px">next unit: '+esc(p.next.slice(0,200))+'</div>';}
  el.innerHTML=h;
}
async function refreshPulse(){ try{renderPulse(await j('/api/pulse'));}catch(e){failIfPristine('pulse','(pulse unavailable)');} }
function renderDiagTimeline(a,shed){
  if(a)lastActivity=a;
  var el=document.getElementById('timeline');if(!el)return;
  var all=lastActivity||[];
  var match=function(x){
    if(actFilter==='tools')return x.type==='tool';
    if(actFilter==='text')return x.type==='text';
    if(actFilter==='reasoning')return x.type==='reasoning';
    if(actFilter==='errors')return x.status==='error';
    if(actFilter==='steps')return String(x.type||'').indexOf('step')===0;
    return true;
  };
  var filtered=all.filter(match);
  var raw=actLimit?filtered.slice(0,actLimit):filtered;
  var dataEl=document.getElementById('timeline-data');if(dataEl)dataEl.value=JSON.stringify(raw);
  var cnt=document.getElementById('act-count');if(cnt)cnt.textContent=raw.length+' / '+all.length;
  if(!raw.length){el.innerHTML='<span class="muted">'+(shed?'(activity paused)':'(no activity for this filter)')+'</span>';tlDomain=null;return;}
  var keep=el.scrollTop||0;
  var now=Date.now();
  var rows=raw.map(function(x){var s=Number(x.ts)||now;var e=Number(x.te)||0;var running=x.status==='running'||x.status==='pending'||!e;if(running||!e||e<s)e=now;if(e-s<150)e=s+150;return {x:x,s:s,e:e,running:running};});
  var t0=rows[0].s,t1=rows[0].e;
  rows.forEach(function(r){if(r.s<t0)t0=r.s;if(r.e>t1)t1=r.e;});
  t1=Math.max(t1,now)+60000;
  tlDomain={t0:t0,t1:t1};
  var pct=function(t){return Math.max(0,Math.min(100,((t-t0)/(t1-t0))*100));};
  var nowPct=pct(now);
  var fmt=(typeof d3!=='undefined'&&d3.timeFormat)?d3.timeFormat('%H:%M:%S'):function(d){return d.toLocaleTimeString(undefined,{hour12:false});};
  var maxDur=150;rows.forEach(function(r){var d=r.e-r.s;if(d>maxDur)maxDur=d;});
  var h='<div class="tl-row tl-head"><span>time <span style="color:#f85149">· now</span></span><div class="tl-lane tl-axis" id="tl-axis">';
  for(var i=0;i<3;i++){var p=i/2;var st=i===0?'left:0;transform:none;text-align:left':i===2?'left:100%;transform:translateX(-100%);text-align:right':'left:50%';h+='<span class="tl-tick" style="'+st+'">'+esc(fmt(new Date(t0+p*(t1-t0))))+'</span>';}
  h+='<i class="tl-now" style="left:'+nowPct+'%"></i></div><span>rel. dur</span><span>type</span><span>dur</span><span>detail</span><span></span></div>';
  rows.forEach(function(r){
    var x=r.x,type=String(x.type||'').toUpperCase();
    var tag=(x.type==='step-start'||x.type==='step-finish')?'STEP':type;
    if(x.type==='tool'&&x.status==='error')tag=tag+' ERR';else if(x.type==='tool'&&x.status==='running')tag=tag+' RUN';
    var fill=(x.status==='error')?'#f85149':(type==='TOOL'?'#58a6ff':type==='TEXT'?'#3fb950':type==='REASONING'?'#d2a8ff':type==='STEP'?'#8b949e':'#f85149');
    var label=x.type==='tool'?(x.tool||'tool'):(x.type||'?');
    var detail=x.cmd||x.text||x.files||'';
    var open=!!expanded[x.ts];
    var canMore=detail.length>140||detail.indexOf(String.fromCharCode(10))>=0;
    var more=canMore?'<button class="copy tl-more" type="button" data-tog="'+x.ts+'">'+(open?'less':'more')+'</button>':'';
    var durStr=r.running?'running':((r.e-r.s)/1000).toFixed(1)+'s';
    var w=Math.max(2,Math.sqrt((r.e-r.s)/maxDur)*100);
    h+='<div class="tl-row">'
      +'<span class="tl-time">'+esc(ts(x.ts))+'</span>'
      +'<div class="tl-lane tl-when"><i class="tl-dot" style="left:'+pct(r.s)+'%;background:'+fill+'"></i><i class="tl-now" style="left:'+nowPct+'%"></i></div>'
      +'<div class="tl-lane"><i style="left:0;width:'+w+'%;background:'+fill+'"></i></div>'
      +'<span class="tl-type"><span class="tag '+tag+'">'+esc(label)+'</span></span>'
      +'<span class="tl-dur">'+esc(durStr)+'</span>'
      +'<span class="tl-text'+(open?' open':'')+'" title="'+esc(detail)+'">'+esc(detail)+'</span>'
      +'<span class="tl-actions">'+more+'<button class="copy" type="button" data-copy="'+esc(detail)+'">copy</button></span>'
      +'</div>';
  });
  el.innerHTML=h;
  if(keep)el.scrollTop=keep;
  tickTimeline();
}
function tickTimeline(){
  if(!tlDomain)return;
  var p=((Date.now()-tlDomain.t0)/(tlDomain.t1-tlDomain.t0))*100;
  p=Math.max(0,Math.min(100,p));
  var nodes=document.querySelectorAll('#timeline .tl-now');
  for(var i=0;i<nodes.length;i++)nodes[i].style.left=p+'%';
}
setInterval(tickTimeline,1000);
if('serviceWorker' in navigator){navigator.serviceWorker.register('/sw.js').catch(function(){});}
function renderActivity(a,shed){
  if(a)lastActivity=a;
  renderDiagTimeline(lastActivity,shed);
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
// F3: a deadline must be longer than the observed tail, and a timeout must be
// VISIBLE. j() returns null for both "empty" and "aborted", so a saturated
// server used to render "no matches" (or silently fall through to a second slow
// request). jr() keeps the failure kind so the pane can say "degraded".
var SEARCH_DEADLINE_MS=20000;
async function jr(u,ms){
  try{
    var o=(ms&&typeof AbortSignal!=='undefined')?{signal:AbortSignal.timeout(ms)}:undefined;
    var r=await fetch(u,o);
    return r.ok?{ok:true,data:await r.json()}:{ok:false,status:r.status};
  }catch(e){return {ok:false,err:String((e&&e.name)||'network')};}
}
async function doSearch(){
  var q=document.getElementById('q').value.trim();
  var el=document.getElementById('searchres');
  if(!q){el.innerHTML='';return;}
  el.innerHTML='<span class="muted" data-loading>searching…</span>';
  var h='',why='';
  var r=await jr('/api/semantic?q='+encodeURIComponent(q)+'&limit=20',SEARCH_DEADLINE_MS);
  if(r.ok&&r.data&&r.data.mode==='fts'){
    var d=r.data;
    if(d.sessions&&d.sessions.length){h+='<div class="muted" style="font-size:11px">sessions</div>';
      for(var i=0;i<d.sessions.length;i++){var s=d.sessions[i];
        h+='<div class="item" data-go="'+esc(s.id)+'" style="cursor:pointer"><span class="tag STEP">session</span>'+esc(s.title)+' <span class="muted">$'+(+s.cost).toFixed(4)+'</span></div>';}}
    if(d.results&&d.results.length){h+='<div class="muted" style="font-size:11px">ranked matches</div>';
      for(var k=0;k<d.results.length;k++){var x=d.results[k];
        h+='<div class="item"'+(x.ocr?'':' data-go="'+esc(x.session)+'" style="cursor:pointer"')+'><span class="tag STEP">'+esc(x.ocr?'screenshot':(x.type||'part'))+'</span><span class="muted">'+esc(x.title||x.session)+'</span> — '+esc(x.snippet||'')+'</div>';}}
  } else {
    if(!r.ok){why=r.err||('http '+(r.status||'?'));}
    var f=await jr('/api/search?q='+encodeURIComponent(q)+'&limit=20',SEARCH_DEADLINE_MS);
    if(f.ok&&f.data){
      var fd=f.data;
      if(fd.sessions){for(var a=0;a<fd.sessions.length;a++){var ss=fd.sessions[a];
        h+='<div class="item" data-go="'+esc(ss.id)+'" style="cursor:pointer"><span class="tag STEP">session</span>'+esc(ss.title)+'</div>';}}
      if(fd.hits){for(var b=0;b<fd.hits.length;b++){var y=fd.hits[b];
        h+='<div class="item" data-go="'+esc(y.session)+'" style="cursor:pointer"><span class="tag STEP">'+esc(y.type)+'</span>'+esc(y.snippet)+'</div>';}}
    } else if(!f.ok){why=why||f.err||('http '+(f.status||'?'));}
  }
  if(h){el.innerHTML=h;}
  else if(why){el.innerHTML='<span class="muted" data-error>search degraded ('+esc(why)+') — server busy, retry in a moment</span>';}
  else {el.innerHTML='<span class="muted">no matches</span>';}
}
document.getElementById('q').addEventListener('keydown',function(ev){if(ev.key==='Enter'){doSearch();}});
document.getElementById('searchres').addEventListener('click',function(ev){
  var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;
  if(t){drill(t.getAttribute('data-go'));}
});
document.getElementById('sessions').addEventListener('click',function(ev){
  if(ev.target&&ev.target.closest&&ev.target.closest('[data-copy],[data-tog]'))return;
  var a=ev.target&&ev.target.closest?ev.target.closest('a.sopen'):null;
  if(a){return;}
  var ex=ev.target&&ev.target.closest?ev.target.closest('[data-exp]'):null;
  if(ex){toggleSessRow(ex.getAttribute('data-exp'));return;}
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
    try{renderActivity(p.activity,p.shed);}catch(e){}
    try{renderTodos(p.todos);}catch(e){}
  };
  _es.addEventListener('snapshot',_onflow);
  _es.addEventListener('delta',_onflow);
}else{
  poll(refreshCost,8000);
  poll(refreshActivity,8000);
  poll(refreshTodos,15000);
  poll(refreshPulse,15000);
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
  var r=await jr('/api/semantic?q='+encodeURIComponent(q)+'&limit=15',SEARCH_DEADLINE_MS);
  var h='';
  if(r.ok&&r.data&&r.data.results){for(var i=0;i<r.data.results.length;i++){var x=r.data.results[i];
    h+='<div class="item"'+(x.ocr?'':' data-go="'+esc(x.session)+'"')+'><span class="tag">'+esc(x.ocr?'screenshot':(x.type||'part'))+'</span><span class="muted">'+esc(x.title||x.session)+'</span> — '+esc(x.snippet||'')+'</div>';}}
  if(h){el.innerHTML=h;}
  else if(!r.ok){el.innerHTML='<span class="muted" data-error>search degraded ('+esc(r.err||('http '+(r.status||'?')))+') — server busy, retry in a moment</span>';}
  else {el.innerHTML='<span class="muted">no matches</span>';}
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

const graphHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode graph</title>
<style>
 body{margin:0;padding:14px;background:#070b10;color:#e6edf3;font-family:system-ui,monospace}
 h1{font-size:17px;margin:0 0 2px}.muted{color:#8b949e;font-size:12px}
 .bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
 .bar input{background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:7px;padding:7px 9px;font-size:13px;min-width:220px}
 .bar button{background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:7px;padding:6px 10px;font-size:12px;cursor:pointer}
 .bar button:hover{border-color:#58a6ff;color:#58a6ff}
 .bar button.on{background:#1f6feb;border-color:#1f6feb;color:#fff}
 .wrap{display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:10px;height:calc(100vh - 150px);min-height:420px}
 #panel{position:relative;background:radial-gradient(1200px 700px at 50% 35%,#0d1a2b 0%,#070b10 68%);border:1px solid #1f2a37;border-radius:10px;overflow:hidden}
 #cv{display:block;width:100%;height:100%;cursor:grab}
 #cv.grabbing{cursor:grabbing}
 #side{background:#0d1117;border:1px solid #1f2a37;border-radius:10px;padding:10px;overflow:auto;font-size:12px}
 #side h2{font-size:12px;color:#8b949e;margin:0 0 6px}
 #side label{display:block;color:#8b949e;margin:8px 0 3px;font-size:11px}
 #side input,#side textarea{width:100%;box-sizing:border-box;background:#070b10;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px;font-size:12px}
 #side textarea{min-height:64px;resize:vertical}
 #side .row{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}
 #side button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:6px 9px;font-size:11px;cursor:pointer}
 #side button.ghost{background:#161b22;border:1px solid #30363d;color:#e6edf3}
 #tip{position:fixed;pointer-events:none;background:#0d1117ee;border:1px solid #30363d;border-radius:7px;padding:7px 9px;font-size:11px;max-width:320px;opacity:0;z-index:40}
 .key{display:flex;gap:10px;flex-wrap:wrap;font-size:11px;color:#8b949e;margin-top:6px}
 .key i{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px;vertical-align:middle}
 .pill{display:inline-block;padding:1px 7px;border-radius:999px;font-size:10px;background:#21262d;color:#8b949e;margin-right:4px}
 .ok{color:#7ee787}.warn{color:#d29922}.bad{color:#ff7b72}
 #status{position:absolute;right:10px;bottom:8px;font-size:11px;color:#8b949e;background:#0d1117cc;padding:3px 8px;border-radius:6px}
 @media(max-width:780px){.wrap{grid-template-columns:1fr;height:auto}#panel{height:62vh}#side{max-height:none}}
 :focus-visible{outline:2px solid #58a6ff;outline-offset:2px}
</style></head>
<body>
${nav("graph")}
<main id="main" tabindex="-1">
<h1>Project graph <span class="muted">(real repo data · drag to orbit · click to select · double-click to connect)</span></h1>
<div class="bar" role="toolbar" aria-label="Graph controls">
 <input id="q" placeholder="search nodes..." aria-label="Search nodes">
 <button id="fit" type="button">fit</button>
 <button id="reheat" type="button">reheat</button>
 <button id="export" type="button">export JSON</button>
 <button id="reset" type="button">reset layout</button>
 <span id="count" class="muted"></span>
</div>
<div class="wrap">
 <div id="panel"><canvas id="cv" tabindex="0" role="img" aria-label="Editable 3D project graph. Use arrow keys to rotate, plus/minus to zoom, n/p to select a node, Enter to inspect it.">Graph visualization. Use the side panel and search box; arrow keys rotate, plus/minus zoom, n/p select nodes.</canvas><div id="status">loading graph...</div></div>
 <aside id="side" aria-live="polite">
   <h2 id="side-title">Select a node</h2>
   <div id="side-body" class="muted">Click a node to inspect it. Your edits persist to observability.db.</div>
 </aside>
</div>
<div class="key" id="legend"></div>
<div id="tip" role="tooltip"></div>
</main>
<script>
(function(){
  var cv=document.getElementById('cv'), panel=document.getElementById('panel'), tip=document.getElementById('tip');
  var statusEl=document.getElementById('status'), countEl=document.getElementById('count');
  var q=document.getElementById('q');
  var DATA=null, nodes=[], links=[], byId={}, sel=null, hover=null, dirty=true;
  var rotY=0.45, rotX=-0.12, zoom=1, panX=0, panY=0;
  var dragNode=null, orbit=null, moved=false;
  var COLORS={area:'#f0f6fc',metric:'#79c0ff',choice:'#d2a8ff',tool:'#7ee787',runbook:'#56d364',
    file:'#8b949e',flag:'#f0883e',api:'#58a6ff',store:'#ffa657',event:'#a5d6ff',issue:'#ff7b72'};
  var TYPE_LABEL={area:'area',metric:'metric',choice:'decision',tool:'tool',runbook:'runbook',file:'file',
    flag:'flag',api:'api',store:'store',event:'event',issue:'issue'};
  var visible={area:1,metric:1,choice:1,tool:1,runbook:1,file:1,flag:1,api:1,store:1,event:1,issue:1};

  function post(doc){return fetch('/api/graph/edit',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(doc)}).then(function(r){return r.json();});}
  function layer(group){return {control:0,procedure:-1,surface:1,data:2,code:3,telemetry:-2,external:-3}[group]||0;}
  function seed(){
    for(var i=0;i<nodes.length;i++){
      var n=nodes[i];
      if(typeof n.x!=='number'||isNaN(n.x)){
        var a=i*2.399963, r=70+Math.sqrt(i)*34;
        n.x=Math.cos(a)*r; n.y=Math.sin(a)*r*0.72; n.z=layer(n.group)*110+((i%9)-4)*7;
      }
      n.vx=0;n.vy=0;n.vz=0;
    }
    for(var k=0;k<160;k++) tick(true);
    dirty=true;
  }
  function tick(force){
    var n=nodes.length,i,j,a,b,dx,dy,dz,d2,f;
    for(i=0;i<n;i++){a=nodes[i];if(a.pinned)continue;
      for(j=i+1;j<n;j++){b=nodes[j];dx=a.x-b.x;dy=a.y-b.y;dz=a.z-b.z;d2=dx*dx+dy*dy+dz*dz;
        if(d2<1)d2=1; if(d2<42000){f=2600/d2; a.vx+=dx*f;a.vy+=dy*f;a.vz+=dz*0.6*f; b.vx-=dx*f;b.vy-=dy*f;b.vz-=dz*0.6*f;}}
    }
    for(i=0;i<links.length;i++){var l=links[i],s=byId[l.source],t=byId[l.target];if(!s||!t)continue;
      dx=t.x-s.x;dy=t.y-s.y;dz=t.z-s.z;var d=Math.sqrt(dx*dx+dy*dy+dz*dz)||1;
      var want=l.kind==='user'?70:95; f=(d-want)*0.0022;
      if(!s.pinned){s.vx+=dx*f;s.vy+=dy*f;s.vz+=dz*0.4*f;}
      if(!t.pinned){t.vx-=dx*f;t.vy-=dy*f;t.vz-=dz*0.4*f;}
    }
    for(i=0;i<n;i++){a=nodes[i];if(a.pinned)continue;
      var lz=layer(a.group)*110;
      a.vx-=a.x*0.0009; a.vy-=a.y*0.0009; a.vz+=(lz-a.z)*0.005;
      a.vx*=0.86;a.vy*=0.86;a.vz*=0.86;
      a.x+=a.vx;a.y+=a.vy;a.z+=a.vz;
    }
  }
  function resize(){
    var r=panel.getBoundingClientRect(), dpr=window.devicePixelRatio||1;
    cv.width=Math.max(320,Math.round(r.width*dpr)); cv.height=Math.max(280,Math.round(r.height*dpr));
    cv.__dpr=dpr; dirty=true;
  }
  function project(p){
    var x=p.x*zoom+panX, y=p.y*zoom+panY, z=p.z*zoom;
    var cy=Math.cos(rotY),sy=Math.sin(rotY),cx=Math.cos(rotX),sx=Math.sin(rotX);
    var x1=x*cy-z*sy, z1=x*sy+z*cy;
    var y1=y*cx-z1*sx, z2=y*sx+z1*cx;
    var depth=z2+1500;
    if(depth<80)depth=80;
    var sc=900/depth;
    return {x:cv.width/2+x1*sc, y:cv.height/2+y1*sc, z:depth, s:sc};
  }
  function radius(n){var deg=0;for(var i=0;i<links.length;i++){if(links[i].source===n.id||links[i].target===n.id)deg++;}
    return (n.type==='area'?9:n.type==='metric'||n.type==='choice'?6:4)+Math.min(7,deg*0.35);}
  function draw(){
    var ctx=cv.getContext('2d'), W=cv.width, H=cv.height, dpr=cv.__dpr||1;
    ctx.setTransform(1,0,0,1,0,0); ctx.clearRect(0,0,W,H);
    ctx.fillStyle='#070b10'; ctx.fillRect(0,0,W,H);
    var focus=sel||hover, near={};
    if(focus){near[focus]=1;for(var i=0;i<links.length;i++){if(links[i].source===focus)near[links[i].target]=1;if(links[i].target===focus)near[links[i].source]=1;}}
    var proj={}; for(var k=0;k<nodes.length;k++){var nd=nodes[k];if(!visible[nd.type]||nd.hidden)continue;proj[nd.id]=project(nd);}
    ctx.lineWidth=Math.max(0.5,0.7*dpr);
    for(var j=0;j<links.length;j++){
      var l=links[j], ps=proj[l.source], pt=proj[l.target]; if(!ps||!pt)continue;
      var act=focus&&(l.source===focus||l.target===focus);
      if(focus&&!act&&!near[l.source]&&!near[l.target])continue;
      ctx.strokeStyle=act?'#58a6ff':(l.kind==='user'?'#d2a8ff':l.kind==='measures'?'#79c0ff':l.kind==='runs'?'#7ee787':'#30363d');
      ctx.globalAlpha=act?0.85:focus?0.22:0.34;
      ctx.beginPath();ctx.moveTo(ps.x,ps.y);ctx.lineTo(pt.x,pt.y);ctx.stroke();
    }
    ctx.globalAlpha=1;
    var order=[]; for(var id in proj) order.push(id); order.sort(function(a,b){return proj[b].z-proj[a].z;});
    for(var o=0;o<order.length;o++){
      var nid=order[o], n2=byId[nid], p=proj[nid];
      var isSel=sel===nid, isHov=hover===nid, dim=focus&&!isSel&&!isHov&&!near[nid];
      var rr=radius(n2)*p.s*1.15; if(rr<1.4)rr=1.4;
      var col=COLORS[n2.type]||'#8b949e';
      if(isSel||isHov){ctx.shadowColor=col;ctx.shadowBlur=18*dpr;}else{ctx.shadowBlur=0;}
      ctx.globalAlpha=dim?0.18:1;
      ctx.fillStyle=col;ctx.beginPath();ctx.arc(p.x,p.y,rr,0,6.2832);ctx.fill();
      if(n2.type==='area'){ctx.strokeStyle='#fff';ctx.lineWidth=1.5*dpr;ctx.stroke();}
      ctx.shadowBlur=0;
      if((isSel||isHov)||(n2.type==='area'&&p.s>0.55)){
        ctx.fillStyle='#e6edf3';ctx.font=(10*dpr)+'px system-ui,monospace';
        ctx.fillText(n2.label,p.x+rr+4,p.y+3);
      }
    }
    ctx.globalAlpha=1;
    var qv=(q.value||'').toLowerCase();
    if(qv){ctx.fillStyle='#8b949e';ctx.font=(12*dpr)+'px system-ui,monospace';ctx.fillText('search: '+qv,12*dpr,18*dpr);}
  }
  function loop(){ if(dirty){draw();dirty=false;} requestAnimationFrame(loop); }
  function findNear(mx,my){
    var best=null,bd=1e9;
    for(var i=0;i<nodes.length;i++){var n=nodes[i];if(n.hidden||!visible[n.type])continue;var p=project(n);
      var rr=radius(n)*p.s*1.15+6;var dx=mx-p.x,dy=my-p.y,d=Math.sqrt(dx*dx+dy*dy);
      if(d<rr&&d<bd){bd=d;best=n;}}
    return best;
  }
  function evPos(ev){var r=cv.getBoundingClientRect(),dpr=cv.__dpr||1;return {x:(ev.clientX-r.left)*dpr,y:(ev.clientY-r.top)*dpr};}
  cv.addEventListener('pointerdown',function(ev){cv.setPointerCapture(ev.pointerId);var p=evPos(ev);var n=findNear(p.x,p.y);moved=false;
    if(n){dragNode=n;}else{orbit={x:ev.clientX,y:ev.clientY,ry:rotY,rx:rotX};cv.classList.add('grabbing');}});
  cv.addEventListener('pointermove',function(ev){var p=evPos(ev);
    if(dragNode){moved=true;var pr=project(dragNode);dragNode.x+=(p.x-pr.x)/(pr.s*Math.max(0.2,zoom));dragNode.y+=(p.y-pr.y)/(pr.s*Math.max(0.2,zoom));dirty=true;}
    else if(orbit){moved=true;rotY=orbit.ry+(ev.clientX-orbit.x)*0.008;rotX=Math.max(-1.3,Math.min(1.3,orbit.rx+(ev.clientY-orbit.y)*0.006));dirty=true;}
    else{var h=findNear(p.x,p.y);if((h&&h.id)!==(hover&&hover.id)){hover=h;dirty=true;
      if(h){tip.innerHTML='<b>'+esc(h.label)+'</b><br>'+TYPE_LABEL[h.type]+(h.verdict?' · '+h.verdict:'')+(h.value!==undefined?' · '+h.value+(h.unit||''):'');tip.style.opacity=1;tip.style.left=(ev.clientX+14)+'px';tip.style.top=(ev.clientY+14)+'px';}else{tip.style.opacity=0;}}}
  });
  cv.addEventListener('pointerup',function(ev){cv.classList.remove('grabbing');
    if(dragNode&&moved){post({action:'pos',node:dragNode.id,x:dragNode.x,y:dragNode.y,z:dragNode.z}).then(function(){dragNode.pinned=true;statusEl.textContent='position saved';});}
    else if(dragNode&&!moved){select(dragNode);}
    dragNode=null;orbit=null;
  });
  cv.addEventListener('wheel',function(ev){ev.preventDefault();zoom*=Math.exp(-ev.deltaY*0.0012);zoom=Math.max(0.25,Math.min(4,zoom));dirty=true;},{passive:false});
  cv.addEventListener('keydown',function(ev){
    var order=Object.keys(byId);
    if(ev.key==='ArrowLeft'){rotY-=0.12;dirty=true;ev.preventDefault();}
    else if(ev.key==='ArrowRight'){rotY+=0.12;dirty=true;ev.preventDefault();}
    else if(ev.key==='ArrowUp'){rotX=Math.max(-1.3,rotX-0.08);dirty=true;ev.preventDefault();}
    else if(ev.key==='ArrowDown'){rotX=Math.min(1.3,rotX+0.08);dirty=true;ev.preventDefault();}
    else if(ev.key==='+'||ev.key==='='){zoom=Math.min(4,zoom*1.1);dirty=true;ev.preventDefault();}
    else if(ev.key==='-'){zoom=Math.max(0.25,zoom/1.1);dirty=true;ev.preventDefault();}
    else if(ev.key==='n'||ev.key==='p'||ev.key==='Enter'){
      if(!order.length)return;
      var cur=sel?order.indexOf(sel):-1;
      var next=ev.key==='p'?(cur<=0?order.length-1:cur-1):((cur+1)%order.length);
      if(ev.key==='Enter'&&sel){renderSide();ev.preventDefault();return;}
      select(byId[order[next]]);dirty=true;ev.preventDefault();
    }
  });
  cv.addEventListener('dblclick',function(ev){var p=evPos(ev),n=findNear(p.x,p.y);if(n&&sel&&n.id!==sel){post({action:'edge_add',source:sel,target:n.id}).then(function(r){if(r.ok){statusEl.textContent='edge added';reload();}});}else if(n){select(n);}});
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c];});}
  function select(n){sel=n?n.id:null;dirty=true;renderSide();}
  function kv(k,v){if(v===undefined||v===null||v==='')return '';return '<div><span class="muted">'+esc(k)+':</span> '+esc(v)+'</div>';}
  function renderSide(){
    var t=document.getElementById('side-title'), b=document.getElementById('side-body');
    if(!sel){t.textContent='Select a node';b.innerHTML='<span class="muted">Click a node to inspect it. Double-click a second node to connect them. Edits persist to observability.db.</span>';return;}
    var n=byId[sel];t.textContent=n.label;
    var h='<div><span class="pill">'+TYPE_LABEL[n.type]+'</span>'+(n.group?'<span class="pill">'+esc(n.group)+'</span>':'')+(n.user?'<span class="pill">edited</span>':'')+'</div>';
    h+=kv('id',n.id)+kv('verdict',n.verdict)+kv('value',n.value+(n.unit||''))+kv('rows',n.rows)+kv('status',n.status)+kv('recommended',n.recommended)+kv('path',n.path)+kv('route',n.route)+kv('state',n.state);
    h+='<label for="ed-label">label</label><input id="ed-label" value="'+esc(n.label).replace(/"/g,'&quot;')+'">';
    h+='<label for="ed-note">note</label><textarea id="ed-note">'+esc(n.note||'')+'</textarea>';
    h+='<div class="row"><button id="ed-save" type="button">save</button><button id="ed-hide" class="ghost" type="button">'+(n.hidden?'unhide':'hide')+'</button></div>';
    h+='<label for="ed-target">connect to node id</label><input id="ed-target" placeholder="file:scripts/pulse.py">';
    h+='<div class="row"><button id="ed-link" class="ghost" type="button">add edge</button><button id="ed-unlink" class="ghost" type="button">remove edges</button></div>';
    b.innerHTML=h;
    document.getElementById('ed-save').onclick=function(){
      var label=document.getElementById('ed-label').value, note=document.getElementById('ed-note').value;
      post({action:'label',node:n.id,label:label}).then(function(){return post({action:'note',node:n.id,note:note});}).then(function(){n.label=label;n.note=note;n.user=true;statusEl.textContent='saved';dirty=true;renderSide();});
    };
    document.getElementById('ed-hide').onclick=function(){post({action:'hidden',node:n.id,hidden:!n.hidden}).then(function(){n.hidden=!n.hidden;statusEl.textContent='hidden: '+n.hidden;dirty=true;select(null);});};
    document.getElementById('ed-link').onclick=function(){var tgt=document.getElementById('ed-target').value.trim();if(!tgt)return;post({action:'edge_add',source:n.id,target:tgt}).then(function(r){statusEl.textContent=r.ok?'edge added':'edge failed: '+r.error;if(r.ok)reload();});};
    document.getElementById('ed-unlink').onclick=function(){post({action:'edge_del',source:n.id,target:n.id}).then(function(){statusEl.textContent='matching edges removed';reload();});};
  }
  function reload(){fetch('/api/graph').then(function(r){return r.json();}).then(load).catch(function(e){statusEl.textContent='graph unavailable: '+e;});}
  function load(d){
    DATA=d||{}; nodes=DATA.nodes||[]; links=DATA.links||[]; byId={};
    for(var i=0;i<nodes.length;i++)byId[nodes[i].id]=nodes[i];
    seed(); renderLegend(); renderSide(); resize(); dirty=true;
    statusEl.textContent=nodes.length+' nodes · '+links.length+' links · '+(DATA.edits_applied||0)+' edits';
    countEl.textContent=nodes.length+' / '+links.length;
  }
  function renderLegend(){
    var el=document.getElementById('legend');var h='';
    for(var t in TYPE_LABEL){if(!visible[t])continue;h+='<span><i style="background:'+COLORS[t]+'"></i>'+TYPE_LABEL[t]+'</span>';}
    el.innerHTML=h;
  }
  q.addEventListener('input',function(){dirty=true;});
  document.getElementById('fit').onclick=function(){zoom=1;panX=0;panY=0;rotY=0.45;rotX=-0.12;dirty=true;};
  document.getElementById('reheat').onclick=function(){for(var i=0;i<nodes.length;i++){nodes[i].pinned=false;nodes[i].x=undefined;}seed();};
  document.getElementById('export').onclick=function(){var blob=new Blob([JSON.stringify(DATA,null,1)],{type:'application/json'});var a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='project-graph.json';a.click();};
  document.getElementById('reset').onclick=function(){if(!confirm('Clear all saved graph edits?'))return;post({action:'reset'}).then(function(){statusEl.textContent='edits cleared';reload();});};
  window.addEventListener('resize',resize);
  // Test seam for scripts/usability-suite.py: read-only ids + select by id.
  // It never writes; edits still go through POST /api/graph/edit.
  window.__projectGraph={ids:function(){return Object.keys(byId);},count:function(){return nodes.length;},
    select:function(id){if(!byId[id])return false;select(byId[id]);return true;}};
  resize(); fetch('/api/graph').then(function(r){return r.json();}).then(load).catch(function(e){statusEl.textContent='graph unavailable: '+e;});
  setInterval(function(){if(!dragNode&&!orbit){tick();dirty=true;}},80);
  requestAnimationFrame(loop);
})();
</script></body></html>`;

const usabilityHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode usability</title>
<style>
 body{margin:0;padding:16px;background:#0d1117;color:#e6edf3;font-family:system-ui,monospace}
 h1{font-size:18px;margin:0 0 2px}.muted{color:#8b949e;font-size:12px}
 .grid{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(320px,.85fr);gap:12px;margin-top:10px}
 .card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:12px;margin:8px 0}
 h2{font-size:13px;color:#8b949e;margin:0 0 8px}h3{font-size:14px;margin:8px 0 4px}
 .stat{display:inline-block;min-width:86px;background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:8px;margin:4px 6px 4px 0}
 .stat b{display:block;font-size:17px}.stat span{color:#8b949e;font-size:11px}
 table{border-collapse:collapse;width:100%;font-size:12px}th,td{text-align:left;padding:4px 7px;border-bottom:1px solid #21262d}
 th{color:#8b949e;font-weight:600}.num{text-align:right;font-variant-numeric:tabular-nums}
 button{background:#1f6feb;color:#fff;border:0;border-radius:7px;padding:7px 11px;font-size:12px;cursor:pointer;min-height:34px}
 button.ghost{background:#161b22;border:1px solid #30363d;color:#e6edf3}button:disabled{opacity:.5;cursor:not-allowed}
 input,select,textarea{background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:7px;padding:6px;font-size:12px}
 input[type=text],textarea{width:100%;box-sizing:border-box}textarea{min-height:54px}
 .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
 .ok{color:#7ee787}.warn{color:#d29922}.bad{color:#ff7b72}
 .item{padding:5px 0;border-bottom:1px solid #21262d;font-size:12px}
 .pill{display:inline-block;padding:1px 7px;border-radius:999px;background:#21262d;color:#8b949e;font-size:10px;margin-right:5px}
 #u-timer{font-size:24px;font-variant-numeric:tabular-nums;margin:8px 0}
 #u-sus label{display:block;margin:6px 0;color:#c9d1d9;font-size:12px}
 #u-sus select{min-width:60px}
 .skip-link{position:absolute;left:-9999px;top:8px;background:#2ea043;color:#0d1117;padding:8px;border-radius:6px;z-index:99}
 .skip-link:focus{left:8px}
 :focus-visible{outline:2px solid #58a6ff;outline-offset:2px}
 @media(max-width:780px){.grid{grid-template-columns:1fr}}
</style></head>
<body>
${nav("usability")}
<a class="skip-link" href="#main">Skip to main content</a>
<main id="main" tabindex="-1">
<h1>Usability <span class="muted">guided human test + cited automated screen</span></h1>
<div class="muted" id="u-status" aria-live="polite">loading evidence...</div>
<div class="grid">
 <section class="card" id="auto-card">
  <h2>Automated evidence <a href="/docs" class="muted">method</a></h2>
  <div id="auto-body" aria-live="polite"><span class="muted">loading...</span></div>
 </section>
 <section class="card" id="guided-card">
  <h2>Guided test <span class="muted">(one goal at a time; a human uses the app)</span></h2>
  <div class="muted">The automated suite screens the build. This records a real session against the same task script.</div>
  <div class="row" style="margin-top:8px">
   <label class="muted" for="u-participant">participant</label>
   <input id="u-participant" type="text" value="anonymous" aria-label="Participant label" style="max-width:180px">
   <button id="u-start" type="button">Start guided test</button>
  </div>
  <div id="u-flow" hidden>
   <div class="muted" id="u-progress"></div>
   <h3 id="u-title"></h3>
   <div id="u-goal"></div>
   <div class="muted" id="u-success"></div>
   <div class="row" style="margin-top:6px"><a id="u-link" href="/" target="_blank" rel="noopener">open the page</a><span class="muted" id="u-path"></span></div>
   <div id="u-timer">0.0s</div>
   <label class="muted" for="u-diff">difficulty</label>
   <select id="u-diff"><option value="">n/a</option><option>1</option><option>2</option><option>3</option><option>4</option><option>5</option></select>
   <label class="muted" for="u-note" style="margin-left:8px">note</label>
   <input id="u-note" type="text" placeholder="what happened?" style="max-width:260px">
   <div class="row" style="margin-top:8px">
    <button id="u-done" type="button">Done</button>
    <button id="u-fail" class="ghost" type="button">Failed</button>
    <button id="u-skip" class="ghost" type="button">Skip</button>
    <button id="u-next" class="ghost" type="button" hidden>Next</button>
   </div>
  </div>
  <div id="u-sus" hidden>
   <h3>SUS questionnaire <span class="muted">1 = strongly disagree, 5 = strongly agree</span></h3>
   <div id="u-sus-items"></div>
   <label class="muted" for="u-notes">session notes</label>
   <textarea id="u-notes" placeholder="anything the numbers miss"></textarea>
   <div class="row" style="margin-top:8px"><button id="u-submit" type="button">Submit session</button><span class="muted" id="u-save"></span></div>
  </div>
 </section>
</div>
<section class="card" id="history-card"><h2>Recent guided sessions</h2><div id="u-history" aria-live="polite"><span class="muted">loading...</span></div></section>
</main>
<script>
(function(){
 var SPEC={tasks:[],sus_items:[]}, AUTO=null, IDX=-1, RESULTS=[], T0=0, TIMER=null, BUSY=false;
 var $=function(id){return document.getElementById(id);};
 function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c];});}
 function fmt(n){return n==null?'n/a':String(n);}
 function renderAuto(d){
  var el=$('auto-body'); if(!d||!d.verdict){el.innerHTML='<span class="muted">No automated run yet. Run ./scripts/usability-suite.py --static-only.</span>';return;}
  var h='<div class="row"><div class="stat"><b class="'+(d.verdict==='PASS'?'ok':'bad')+'">'+esc(d.verdict)+'</b><span>verdict</span></div>';
  h+='<div class="stat"><b>'+esc(fmt(d.effectiveness))+'</b><span>effectiveness</span></div>';
  h+='<div class="stat"><b>'+esc(fmt(d.efficiency_s))+'</b><span>efficiency s</span></div>';
  h+='<div class="stat"><b>'+esc(fmt(d.satisfaction_sus))+'</b><span>SUS</span></div>';
  h+='<div class="stat"><b>'+esc(d.fail_count||0)+'</b><span>failures</span></div></div>';
  var axes=d.axes||{}; h+='<table><tr><th>axis</th><th class="num">pass</th><th class="num">fail</th><th class="num">skip</th><th class="num">score</th></tr>';
  for(var k in axes){var a=axes[k];h+='<tr><td>'+esc(k)+'</td><td class="num">'+esc(a.pass)+'</td><td class="num '+((a.fail?'bad':''))+'">'+esc(a.fail)+'</td><td class="num">'+esc(a.skip)+'</td><td class="num">'+esc(fmt(a.score))+'</td></tr>';}
  h+='</table><div class="muted" style="margin-top:6px">mode '+esc(d.mode||'?')+' · '+esc(d.ts||'')+' · '+(d.caveat?esc(d.caveat):'')+'</div>';
  var fs=(d.failures||[]); if(fs.length){h+='<div style="margin-top:8px">';for(var i=0;i<fs.length;i++){h+='<div class="item bad">FAIL '+esc(fs[i].axis)+'/'+esc(fs[i].metric)+' '+esc(fs[i].detail||'')+'</div>';}h+='</div>';}
  el.innerHTML=h;
 }
 function renderHistory(rows){
  var el=$('u-history');rows=rows||[];
  if(!rows.length){el.innerHTML='<span class="muted">No human-guided sessions yet. Start one above.</span>';return;}
  var h='<table><tr><th>when</th><th>participant</th><th class="num">eff</th><th class="num">time</th><th class="num">SUS</th><th class="num">tasks</th><th>mode</th></tr>';
  for(var i=0;i<rows.length;i++){var r=rows[i];h+='<tr><td>'+esc(r.ts)+'</td><td>'+esc(r.participant)+'</td><td class="num">'+esc(fmt(r.effectiveness))+'</td><td class="num">'+esc(fmt(r.efficiency_s))+'</td><td class="num">'+esc(fmt(r.satisfaction_sus))+'</td><td class="num">'+esc(r.completed)+'/'+esc(r.total)+'</td><td>'+esc(r.mode)+'</td></tr>';}
  el.innerHTML=h+'</table>';
 }
 function load(){
  fetch('/api/usability').then(function(r){return r.json();}).then(function(d){AUTO=d;renderAuto(d);}).catch(function(){renderAuto(null);});
  fetch('/api/usability/tasks').then(function(r){return r.json();}).then(function(d){SPEC=d||{};$('u-status').textContent=(SPEC.tasks||[]).length+' guided task(s) ready';}).catch(function(){$('u-status').textContent='task script unavailable';});
  fetch('/api/usability/guided?limit=20').then(function(r){return r.json();}).then(function(d){renderHistory((d&&d.sessions)||[]);}).catch(function(){renderHistory([]);});
 }
 function showTask(){
  var t=(SPEC.tasks||[])[IDX]; if(!t){showSus();return;}
  $('u-flow').hidden=false; $('u-sus').hidden=true; $('u-next').hidden=true;
  $('u-title').textContent=t.title; $('u-goal').textContent=t.instruction; $('u-success').textContent='Success: '+t.success;
  $('u-link').href=t.path; $('u-path').textContent=t.path; $('u-progress').textContent='Task '+(IDX+1)+' of '+SPEC.tasks.length;
  $('u-diff').value=''; $('u-note').value=''; $('u-done').disabled=false; $('u-fail').disabled=false; $('u-skip').disabled=false;
  T0=Date.now(); $('u-timer').textContent='0.0s';
  if(TIMER)clearInterval(TIMER);
  TIMER=setInterval(function(){if(!BUSY)$('u-timer').textContent=((Date.now()-T0)/1000).toFixed(1)+'s';},200);
  if(window.scrollTo)window.scrollTo(0,0);
 }
 function finishTask(success){
  if(BUSY)return; BUSY=true;
  var t=SPEC.tasks[IDX], dur=Math.round(((Date.now()-T0)/1000)*100)/100;
  if(TIMER){clearInterval(TIMER);TIMER=null;}
  var diff=$('u-diff').value; RESULTS.push({id:t.id,success:success,duration_s:dur,difficulty:diff?Number(diff):null,note:$('u-note').value||''});
  $('u-done').disabled=true; $('u-fail').disabled=true; $('u-skip').disabled=true; $('u-next').hidden=false;
  $('u-timer').textContent=dur.toFixed(1)+'s '+(success===true?'done':success===false?'failed':'skipped');
  BUSY=false;
 }
 function showSus(){
  $('u-flow').hidden=true; $('u-sus').hidden=false; $('u-save').textContent='';
  var host=$('u-sus-items'); if(host.innerHTML)return;
  var h='';
  for(var i=0;i<(SPEC.sus_items||[]).length;i++){
    h+='<label>'+esc(SPEC.sus_items[i])+' <select data-sus="'+i+'" aria-label="SUS item '+(i+1)+'">';
    for(var v=1;v<=5;v++)h+='<option value="'+v+'">'+v+'</option>';
    h+='</select></label>';
  }
  host.innerHTML=h;
  $('u-status').textContent='All tasks recorded. Complete SUS and submit.';
 }
 function submit(){
  var sus=[], sels=document.querySelectorAll('#u-sus-items select');
  for(var i=0;i<sels.length;i++)sus.push(Number(sels[i].value));
  if(sus.length!==10){$('u-save').textContent='SUS needs 10 answers';return;}
  $('u-submit').disabled=true; $('u-save').textContent='saving...';
  fetch('/api/usability/guided',{method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({participant:$('u-participant').value||'anonymous',notes:$('u-notes').value||'',tasks:RESULTS,sus:sus})})
   .then(function(r){return r.json();}).then(function(d){
     $('u-submit').disabled=false;
     if(!d.ok){$('u-save').textContent='failed: '+(d.error||'unknown');return;}
     var s=d.session; $('u-save').textContent='saved #'+s.id+' · effectiveness '+s.effectiveness+' · SUS '+fmt(s.satisfaction_sus);
     $('u-sus').hidden=true; $('u-flow').hidden=true; $('u-status').textContent='Guided session saved.';
     fetch('/api/usability/guided?limit=20').then(function(r){return r.json();}).then(function(x){renderHistory((x&&x.sessions)||[]);});
   }).catch(function(e){$('u-submit').disabled=false;$('u-save').textContent='failed: '+e;});
 }
 $('u-start').onclick=function(){IDX=0;RESULTS=[];$('u-start').disabled=true;$('u-flow').hidden=false;showTask();};
 $('u-done').onclick=function(){finishTask(true);};
 $('u-fail').onclick=function(){finishTask(false);};
 $('u-skip').onclick=function(){finishTask(null);};
 $('u-next').onclick=function(){IDX++;showTask();};
 $('u-submit').onclick=submit;
 load();
})();
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
var DOCS=["HANDOFF.md","RULES.md","README.md","scripts/README.txt","HANDOFF-PROMPT.txt","docs/USABILITY-TESTING.md","docs/STATUS-AUTOMATION.md"];
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

const settingsHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>opencode settings</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d}
 .ok{color:#3fb950}.warn{color:#d29922}.muted{color:#8b949e;font-size:12px}
 button{background:#1f6feb;color:#fff;border:0;border-radius:7px;padding:6px 10px;font-size:12px;cursor:pointer;min-height:32px}
 button:hover{filter:brightness(1.1)}
 input{background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:7px;padding:6px 8px;font-size:12px}
 #prov{overflow-x:auto}
 .bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:8px 0}
 :focus-visible{outline:2px solid #1f6feb;outline-offset:1px}
</style></head>
<body>
${nav("settings")}
<main id="main" tabindex="-1">
<h1>opencode settings</h1>
<div class="muted">Provider controls. Secrets are never shown or sent here; pause writes desired state and the host applier removes the effective env key.</div>
<div class="bar"><label for="confirm" class="muted">type the provider id to confirm:</label><input id="confirm" aria-label="typed confirmation" autocomplete="off"><span id="status" role="status" class="muted"></span></div>
<div id="note" class="muted"></div>
<h2>Providers</h2><div id="prov"><span class="muted" data-loading>loading...</span></div>
</main>
<script>
(function(){
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  function render(d){
    var box=document.getElementById('prov'); if(!box) return;
    if(!d||!d.providers){box.textContent='(settings unavailable)';return;}
    var h='<table><caption>providers: config, env presence, auth, policy, state</caption><tr><th scope="col">provider</th><th scope="col">state</th><th scope="col">config</th><th scope="col">key</th><th scope="col">auth</th><th scope="col">policy</th><th scope="col">action</th></tr>';
    for(var i=0;i<d.providers.length;i++){
      var p=d.providers[i];
      var act=p.paused?'resume':'pause';
      h+='<tr><td><b>'+esc(p.id)+'</b>'+(p.inConfig?'':' <span class="muted">(env-only)</span>')+'</td>'
        +'<td class="'+(p.paused?'warn':'ok')+'">'+esc(p.state)+'</td>'
        +'<td>'+(p.inConfig?'yes':'no')+'</td>'
        +'<td>'+(p.envKey?'present':'absent')+'</td>'
        +'<td>'+(p.authEntry?'yes':'no')+'</td>'
        +'<td>'+esc(p.policy)+'</td>'
        +'<td><button data-act="'+act+'" data-id="'+esc(p.id)+'">'+act+'</button></td></tr>';
    }
    box.innerHTML=h+'</table>';
    var n=document.getElementById('note'); if(n) n.textContent=d.note||'';
  }
  function load(){
    fetch('/api/settings').then(function(r){return r.json();}).then(render).catch(function(e){var b=document.getElementById('prov');if(b)b.textContent='(settings unavailable: '+e+')';});
  }
  var box=document.getElementById('prov');
  if(box&&box.addEventListener){
    box.addEventListener('click',function(ev){
      var t=ev&&ev.target; var b=t&&t.closest?t.closest('[data-act]'):null;
      if(!b) return;
      var id=b.getAttribute('data-id'), act=b.getAttribute('data-act');
      var c=document.getElementById('confirm'); var v=c?String(c.value||'').trim():'';
      var s=document.getElementById('status');
      if(v!==id){if(s)s.textContent='type "'+id+'" in the box to confirm '+act;return;}
      if(s)s.textContent=act+' '+id+' ...';
      fetch('/api/settings/provider',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id:id,action:act,confirm:v})})
        .then(function(r){return r.json();})
        .then(function(d){
          if(s)s.textContent=d.ok?(act+' '+id+' recorded'+(d.hostActionRequired?' — run '+d.hostCommand:'')):('error: '+(d.error||'?'));
          if(d.ok) render(d.settings||{});
        })
        .catch(function(e){if(s)s.textContent='error: '+e;});
    });
  }
  load();
})();
</script></body></html>`;

// Authentication: the dashboard exposes full session transcripts and exports,
// so it is NOT a public surface. When OPENCODE_SERVER_PASSWORD is set (the same
// password opencode-web uses), every route requires HTTP Basic auth. A test or
// an explicitly local-only deployment can set DASH_AUTH=off. CORS is opt-in via
// DASH_ALLOW_ORIGIN; the previous hardcoded GitHub Pages grant let a public site
// read the private store from a visitor's browser.
const DASH_PASSWORD = process.env.OPENCODE_SERVER_PASSWORD || "";
const DASH_AUTH = (process.env.DASH_AUTH || "on").toLowerCase();
const DASH_ALLOW_ORIGIN = process.env.DASH_ALLOW_ORIGIN || "";

function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

function authOk(req) {
  if (DASH_AUTH === "off" || !DASH_PASSWORD) return true;
  const m = /^Basic\s+(.+)$/i.exec(req.headers.authorization || "");
  if (!m) return false;
  let decoded = "";
  try { decoded = Buffer.from(m[1], "base64").toString("utf8"); } catch { return false; }
  const i = decoded.indexOf(":");
  if (i < 0) return false;
  return safeEqual(decoded.slice(i + 1), DASH_PASSWORD);
}

const CORS_HEADERS = DASH_ALLOW_ORIGIN
  ? {
      "Access-Control-Allow-Origin": DASH_ALLOW_ORIGIN,
      "Access-Control-Allow-Private-Network": "true",
      "Vary": "Origin",
    }
  : {};

// Mutations must be same-origin (and authenticated above). A public site must
// never be able to POST into the private store.
function sameOriginMutation(req) {
  const origin = req.headers.origin;
  if (!origin) return true; // non-browser client (curl/CLI) on the private net
  try {
    const u = new URL(origin);
    return u.host === (req.headers.host || "");
  } catch {
    return false;
  }
}

function send(res, code, body, type) {
  const isHtml = String(type || "").startsWith("text/html");
  // Per-response nonce: the dashboard is built from inline <script> blocks, so
  // `script-src 'self'` alone would break it. A nonce lets us drop
  // 'unsafe-inline' without restructuring every page. Non-HTML responses get
  // the strictest policy because they never need scripts.
  const nonce = isHtml ? randomBytes(16).toString("base64") : "";
  const payload = isHtml
    ? String(body).replace(/<script\b/g, `<script nonce="${nonce}"`)
    : body;
  res.writeHead(code, {
    ...CORS_HEADERS,
    "Content-Type": type,
    "Cache-Control": "no-store",
    "Content-Security-Policy": isHtml
      ? `default-src 'self'; script-src 'self' 'nonce-${nonce}'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'`
      : "default-src 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  res.end(payload);
}

const SSE_CLIENTS = new Set();

function readProc(path) {
  try {
    return readFileSync(path, "utf8").trim();
  } catch {
    return "";
  }
}

function psiCpu10() {
  const match = readProc("/proc/pressure/cpu").match(/some avg10=([\d.]+)/);
  return match ? Number(match[1]) : 0;
}

function apiResources() {
  const psi = {};
  for (const key of ["cpu", "memory", "io"]) {
    const text = readProc(`/proc/pressure/${key}`);
    const some = text.match(/some avg10=([\d.]+) avg60=([\d.]+) avg300=([\d.]+)/);
    const full = text.match(/full avg10=([\d.]+) avg60=([\d.]+) avg300=([\d.]+)/);
    psi[key] = {
      some: some ? [Number(some[1]), Number(some[2]), Number(some[3])] : null,
      full: full ? [Number(full[1]), Number(full[2]), Number(full[3])] : null,
    };
  }
  const load = readProc("/proc/loadavg").split(/\s+/).slice(0, 3).map(Number);
  const mem = process.memoryUsage();
  const cpu = process.cpuUsage();
  return {
    ts: Date.now(),
    pid: process.pid,
    uptime_s: Math.round(process.uptime()),
    node_rss_mb: Math.round(mem.rss / 1048576),
    node_cpu_s: Math.round(((cpu.user + cpu.system) / 1e6) * 10) / 10,
    sse_clients: SSE_CLIENTS.size,
    segments: SEGMENTS,
    sse_ms: SSE_MS,
    auto_shed: AUTO_SHED,
    cpu_psi_10: psiCpu10(),
    load,
    psi,
    cgroup: {
      cpu_max: readProc("/sys/fs/cgroup/cpu.max"),
      cpu_stat: readProc("/sys/fs/cgroup/cpu.stat"),
      memory_current_mb: Math.round((Number(readProc("/sys/fs/cgroup/memory.current")) || 0) / 1048576),
      memory_max: readProc("/sys/fs/cgroup/memory.max"),
    },
  };
}

// cost/activity are async (worker-backed); awaiting them is what makes the
// snapshot real. Returning the promises stringified to `{}`, which made the
// client render nothing and left "Live activity"/"Todos" at "loading...".
async function ssePayload(segments = SEGMENTS) {
  const shed = AUTO_SHED && psiCpu10() > 30;
  let active = segments;
  if (shed) {
    active = active.filter((name) => name === "cost" || name === "todos");
  }
  const want = (name) => active.includes(name);
  const [cost, activity] = await Promise.all([
    want("cost") ? apiCost() : Promise.resolve(null),
    want("activity") ? apiActivity() : Promise.resolve(null),
  ]);
  return { cost, activity, todos: want("todos") ? apiTodos() : [], shed };
}
function recoveryPage() {
  const e = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const d = readJsonRel("../data/observability/recovery.json");
  let body = "";
  if (!d || !d.subsystems) {
    body = "<h1>Recovery</h1><p class=\"muted\">No recovery snapshot yet. On the host run:</p><pre>./scripts/recovery-status.sh --write</pre>";
  } else {
    body = "<h1>Recovery</h1><p class=\"muted\">overall <b>" + e(d.overall || "unknown") + "</b> &middot; " + e(d.ts || "?") + "</p>";
    body += "<table><thead><tr><th>subsystem</th><th>state</th><th>detail</th></tr></thead><tbody>";
    for (const s of (d.subsystems || [])) {
      body += "<tr><td>" + e(s.name) + "</td><td>" + e(s.state) + "</td><td>" + e(s.detail) + "</td></tr>";
    }
    body += "</tbody></table>";
    const acts = d.actions || [];
    if (acts.length) {
      body += "<h2>Next</h2><ul>";
      for (const a of acts) body += "<li><code>" + e(a) + "</code></li>";
      body += "</ul>";
    }
  }
  const css = "<style>body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}" +
    "main{max-width:1100px}table{border-collapse:collapse;width:100%;font-size:12px}" +
    "th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d}th{color:#8b949e}" +
    "pre{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;overflow-x:auto}" +
    ":focus-visible{outline:2px solid #1f6feb;outline-offset:1px}</style>";
  return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>recovery</title>" + css + "</head><body>" + nav("recovery") + "<main id=\"main\" tabindex=\"-1\">" + body + "</main></body></html>";
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  const params = qs(req);
  // Auth gate for every route (including SSE and exports). SET
  // OPENCODE_SERVER_PASSWORD to require Basic auth; DASH_AUTH=off is the
  // explicit local/test escape hatch.
  if (!authOk(req)) {
    res.writeHead(401, {
      "WWW-Authenticate": 'Basic realm="opencode dashboard", charset="UTF-8"',
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end("authentication required\n");
    return;
  }
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      ...CORS_HEADERS,
      "Access-Control-Allow-Methods": "GET,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Max-Age": "600",
    });
    res.end();
    return;
  }
  if (req.method === "POST" && url === "/api/graph/edit") {
    if (!sameOriginMutation(req)) {
      send(res, 403, JSON.stringify({ ok: false, error: "cross-origin mutation blocked" }), "application/json");
      return;
    }
    try {
      const raw = await readBody(req);
      const doc = JSON.parse(raw || "{}");
      const result = apiGraphEdit(doc);
      send(res, result.ok ? 200 : 400, JSON.stringify(result), "application/json");
    } catch (e) {
      send(res, 400, JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) }), "application/json");
    }
  } else if (req.method === "POST" && url === "/api/usability/guided") {
    if (!sameOriginMutation(req)) {
      send(res, 403, JSON.stringify({ ok: false, error: "cross-origin mutation blocked" }), "application/json");
      return;
    }
    try {
      const raw = await readBody(req);
      const doc = JSON.parse(raw || "{}");
      const result = apiUsabilityGuidedSave(doc);
      send(res, result.ok ? 200 : 400, JSON.stringify(result), "application/json");
    } catch (e) {
      send(res, 400, JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) }), "application/json");
    }
  } else if (req.method === "POST" && url === "/api/settings/provider") {
    if (!sameOriginMutation(req)) {
      send(res, 403, JSON.stringify({ ok: false, error: "cross-origin mutation blocked" }), "application/json");
      return;
    }
    try {
      const raw = await readBody(req);
      const doc = JSON.parse(raw || "{}");
      const result = apiSettingsAction(doc);
      send(res, result.ok ? 200 : 400, JSON.stringify(result), "application/json");
    } catch (e) {
      send(res, 400, JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) }), "application/json");
    }
  } else if (req.method === "POST" && url === "/api/settings/key") {
    if (!sameOriginMutation(req)) {
      send(res, 403, JSON.stringify({ ok: false, error: "cross-origin mutation blocked" }), "application/json");
      return;
    }
    try {
      const raw = await readBody(req);
      const doc = JSON.parse(raw || "{}");
      const result = apiSettingsKey(doc);
      send(res, result.ok ? 200 : 400, JSON.stringify(result), "application/json");
    } catch (e) {
      send(res, 400, JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) }), "application/json");
    }
  } else if (url === "/favicon.ico") {
    res.writeHead(204, { "Cache-Control": "max-age=86400" });
    res.end();
  } else if (url === "/manifest.webmanifest") {
    res.writeHead(200, { "Content-Type": "application/manifest+json", "Cache-Control": "no-cache" });
    res.end(JSON.stringify(PWA_MANIFEST));
  } else if (url === "/app-manifest.webmanifest") {
    res.writeHead(200, { "Content-Type": "application/manifest+json", "Cache-Control": "no-cache" });
    res.end(JSON.stringify(APP_MANIFEST));
  } else if (url === "/app") {
    res.writeHead(302, { "Location": "/app/", "Cache-Control": "no-store" });
    res.end();
  } else if (url === "/app/") {
    try {
      const body = readFileSync(new URL("../web/dist/index.html", import.meta.url));
      send(res, 200, body, "text/html; charset=utf-8");
    } catch {
      send(res, 503, "MUI app not built. Run: cd web && npm ci && npm run build\n", "text/plain");
    }
  } else if (url.startsWith("/app/assets/")) {
    const name = url.slice("/app/assets/".length);
    if (/^[A-Za-z0-9._-]+$/.test(name)) {
      try {
        const body = readFileSync(new URL("../web/dist/assets/" + name, import.meta.url));
        const type = name.endsWith(".js") ? "application/javascript; charset=utf-8"
          : name.endsWith(".css") ? "text/css; charset=utf-8"
          : name.endsWith(".woff2") ? "font/woff2"
          : "application/octet-stream";
        res.writeHead(200, { "Content-Type": type, "Cache-Control": "public, max-age=31536000, immutable", "X-Content-Type-Options": "nosniff" });
        res.end(body);
      } catch {
        send(res, 404, "not found\n", "text/plain");
      }
    } else {
      send(res, 404, "not found\n", "text/plain");
    }
  } else if (url.startsWith("/app/") && !url.startsWith("/app/assets/")) {
    // The MUI shell is a single hash-routed page. A legacy path typed under
    // /app/ (e.g. /app/explore) used to 404; send it to the real page instead.
    const rest = url.slice("/app".length) || "/";
    res.writeHead(302, { "Location": rest, "Cache-Control": "no-store" });
    res.end();
  } else if (url === "/sw.js") {
    res.writeHead(200, {
      "Content-Type": "application/javascript; charset=utf-8",
      "Cache-Control": "no-cache",
      "Service-Worker-Allowed": "/",
      "X-Content-Type-Options": "nosniff",
    });
    res.end(SW_JS);
  } else if (url === "/icon-192.png" || url === "/icon-512.png") {
    try {
      const body = readFileSync(new URL("./pwa/" + url.slice(1), import.meta.url));
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "max-age=86400" });
      res.end(body);
    } catch {
      send(res, 404, "not found\n", "text/plain");
    }
  } else if (url === "/api/stream") {
    // snapshot -> deltas (durable-pi pattern): one server-side broadcast loop
    // feeds every client, so clients never poll; a reconnect gets a fresh
    // snapshot. Replaces per-client polling (the single-thread contention).
    res.writeHead(200, { ...CORS_HEADERS, "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Connection": "keep-alive", "X-Accel-Buffering": "no" });
    const client = { write: (ev, data) => { try { res.write("event: " + ev + "\ndata: " + JSON.stringify(data) + "\n\n"); } catch { /* client gone */ } } };
    SSE_CLIENTS.add(client);
    try {
      const segs = params.segments
        ? String(params.segments).split(",").map((s) => s.trim()).filter(Boolean)
        : SEGMENTS;
      client.write("snapshot", await ssePayload(segs));
    } catch {
      client.write("snapshot", { cost: null, activity: null, todos: [] });
    }
    req.on("close", () => SSE_CLIENTS.delete(client));
  } else if (url === "/") {
    send(res, 200, html, "text/html; charset=utf-8");
  } else if (url === "/explore") {
    send(res, 200, exploreHtml, "text/html; charset=utf-8");
  } else if (url === "/graph") {
    send(res, 200, graphHtml, "text/html; charset=utf-8");
  } else if (url === "/recovery") {
    send(res, 200, recoveryPage(), "text/html; charset=utf-8");
  } else if (url === "/usability") {
    send(res, 200, usabilityHtml, "text/html; charset=utf-8");
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
  } else if (url === "/settings") {
    send(res, 200, settingsHtml, "text/html; charset=utf-8");
  } else if (url === "/api/models") {
    send(res, 200, JSON.stringify(apiModels()), "application/json");
  } else if (url === "/api/settings") {
    send(res, 200, JSON.stringify(apiSettings()), "application/json");
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
    send(res, 200, JSON.stringify(await apiSearch(params.q, Number(params.limit) || 20, params.full === "1")), "application/json");
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
  } else if (url === "/api/graph") {
    send(res, 200, JSON.stringify(apiGraph()), "application/json");
  } else if (url === "/api/benchmark") {
    send(res, 200, JSON.stringify(readJsonRel("../data/observability/benchmark.json") || { available: false, metrics: [] }), "application/json");
  } else if (url === "/api/usability") {
    send(res, 200, JSON.stringify(readJsonRel("../data/observability/usability.json") || { available: false }), "application/json");
  } else if (url === "/api/usability/tasks") {
    send(res, 200, JSON.stringify(apiUsabilityTasks()), "application/json");
  } else if (url === "/api/usability/guided") {
    send(res, 200, JSON.stringify({ sessions: guidedRows(Number(params.limit) || 20) }), "application/json");
  } else if (url === "/api/pulse") {
    send(res, 200, JSON.stringify(readJsonRel("../data/observability/pulse.json") || { available: false }), "application/json");
  } else if (url === "/api/recovery") {
    send(res, 200, JSON.stringify(readJsonRel("../data/observability/recovery.json") || { available: false }), "application/json");
  } else if (url === "/api/choices") {
    const cfg = readJsonRel("../scripts/choices.json") || { choices: [] };
    const st = readJsonRel("../data/observability/choices.json") || { choices: {} };
    const done = st.choices || {};
    const choices = (cfg.choices || []).map((c) => ({
      id: c.id, question: c.question, why: c.why, recommended: c.recommended,
      options: c.options || [], selected: (done[c.id] || {}).selected || null,
      status: (done[c.id] || {}).status || "pending", at: (done[c.id] || {}).at || null,
    }));
    send(res, 200, JSON.stringify({ updated: st.updated || null, choices }), "application/json");
  } else if (url === "/api/export") {
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=opencode-sessions.csv" });
    res.end(apiExport());
  } else if (url === "/api/resources") {
    send(res, 200, JSON.stringify(apiResources()), "application/json");
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
}, SSE_MS);
server.listen(port, host, () => {
  console.log("opencode observability: http://" + host + ":" + port + "  (db: " + dbPath + ")");
  // No eager pre-warm. The worker is single-threaded: pre-computing
  // /api/board (~19 s) and /api/health (~10-30 s) at startup starved every
  // other worker-backed API (semantic, trends, cost) for ~30 s. Instead the
  // heavy panels are on-demand and /api/health + /api/signals are seeded from
  // their durable snapshots, so a restart serves them instantly.
});
