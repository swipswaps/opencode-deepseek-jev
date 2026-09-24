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

const dbPath = process.argv[2];
const port = Number(process.argv[3] || 5099);
const host = process.argv[4] || "127.0.0.1";

if (!dbPath) {
  console.error("usage: node dashboard.mjs <db-path> [port] [host]");
  process.exit(2);
}

function query(sql, ...args) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return db.prepare(sql).all(...args);
  } finally {
    db.close();
  }
}

function apiCost() {
  const totals = query(
    "SELECT COUNT(*) n, COALESCE(SUM(cost),0) c, COALESCE(SUM(tokens_input),0) i, COALESCE(SUM(tokens_output),0) o, COALESCE(SUM(tokens_reasoning),0) r, COALESCE(SUM(tokens_cache_read),0) cr FROM session"
  )[0];
  const sessions = query(
    "SELECT title, cost, tokens_input, tokens_output, tokens_reasoning, time_created FROM session ORDER BY time_created DESC LIMIT 12"
  );
  const latest = query("SELECT title FROM session ORDER BY time_created DESC LIMIT 1")[0];
  const lastPart = query("SELECT MAX(time_created) m FROM part")[0];
  const active = !!(lastPart && lastPart.m && Date.now() - Number(lastPart.m) < 30000);
  return { totals, sessions, latest: latest ? latest.title : null, active };
}

function apiActivity() {
  const rows = query("SELECT time_created, data FROM part ORDER BY time_created DESC LIMIT 80");
  const items = [];
  for (const row of rows) {
    let d;
    try { d = JSON.parse(row.data); } catch { continue; }
    const it = { ts: row.time_created, type: d.type };
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

function apiTodos() {
  const latest = query("SELECT id FROM session ORDER BY time_created DESC LIMIT 1")[0];
  if (!latest) return [];
  return query(
    "SELECT content, status, priority, position FROM todo WHERE session_id = ? ORDER BY position ASC",
    latest.id
  );
}

let balanceCache = { at: 0, data: { available: false } };
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
<html><head><meta charset="utf-8"><title>opencode observability</title>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 8px}
 .row{display:flex;flex-wrap:wrap;gap:10px}
 .card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:12px;margin:10px 0}
 .card h3{margin:0 0 8px;font-size:13px;color:#8b949e;font-weight:600}
 .stat{flex:1;min-width:120px;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:10px}
 .stat b{display:block;font-size:20px;font-weight:600}
 .stat span{color:#8b949e;font-size:12px}
 .item{padding:4px 0;border-bottom:1px solid #21262d;font-size:13px;word-break:break-word;cursor:default}
 .tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;margin-right:6px;vertical-align:top}
 .TOOL{background:#1f6feb33;color:#58a6ff}.REASON{background:#8957e533;color:#d2a8ff}
 .TEXT{background:#2ea04333;color:#7ee787}.STEP{background:#30363d;color:#8b949e}
 .PATCH{background:#b6232433;color:#ff7b72}
 .muted{color:#8b949e}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:3px 8px;border-bottom:1px solid #21262d}
 th{color:#8b949e;font-weight:600}
 .num{text-align:right;font-variant-numeric:tabular-nums}
 .live{color:#3fb950}.idle{color:#8b949e}
 #session{font-size:13px;margin-bottom:4px}
</style></head>
<body>
<h1>opencode observability</h1>
<div id="session" class="muted"></div>
<div class="row" id="stats"></div>
<div class="card"><h3>Sessions</h3><div id="sessions"></div></div>
<div class="card"><h3>Live activity <span class="muted">(click to expand)</span></h3><div id="activity"></div></div>
<div class="card"><h3>Todos</h3><div id="todos"></div></div>
<script>
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function fmt(n){n=Number(n)||0;return n>=1000?(n/1000).toFixed(1)+'k':''+n;}
function ts(t){return new Date(t).toISOString().slice(11,23);}
async function j(u){try{var r=await fetch(u);return r.ok?r.json():null;}catch(e){return null;}}
var expanded={};
function item(x){
  var cls=String(x.type||'').toUpperCase();
  var tag=(x.type==='step-start'||x.type==='step-finish')?'STEP':cls;
  var short='',full='';
  if(x.type==='tool'){short=esc(x.tool)+' ['+esc(x.status)+'] '+esc((x.cmd||'').slice(0,90));full=esc(x.tool)+' ['+esc(x.status)+'] '+esc(x.cmd||'');}
  else if(x.type==='reasoning'||x.type==='text'){short=esc((x.text||'').slice(0,140));full=esc(x.text||'');}
  else if(x.type==='patch'){short=esc(x.files||'');full=short;}
  var click=(full&&full!==short)?' style="cursor:pointer" onclick="tog('+x.ts+')" title="'+(expanded[x.ts]?'click to collapse':'click to expand')+'"':'';
  var body=expanded[x.ts]?full:short;
  return '<div class="item"'+click+'><span class="tag '+tag+'">'+esc(x.type)+'</span>'+body+' <span class="muted">'+ts(x.ts)+'</span></div>';
}
function tog(ts){expanded[ts]=expanded[ts]?0:1;refreshActivity();}
function sessRow(s){
  return '<tr><td>'+esc(s.title||'(untitled)')+'</td><td class="num">$'+(+s.cost).toFixed(4)+'</td><td class="num">'+fmt(s.tokens_input)+'</td><td class="num">'+fmt(s.tokens_output)+'</td><td class="num">'+fmt(s.tokens_reasoning)+'</td></tr>';
}
var bal=null;
async function refreshCost(){
  var c=await j('/api/cost');
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
    var sh='<table><tr><th>title</th><th class="num">cost</th><th class="num">in</th><th class="num">out</th><th class="num">reas</th></tr>';
    for(var i=0;i<c.sessions.length;i++){sh+=sessRow(c.sessions[i]);}
    document.getElementById('sessions').innerHTML=sh+'</table>';
  }
}
async function refreshActivity(){
  var a=await j('/api/activity');
  if(a){var h='';for(var i=0;i<a.length;i++){h+=item(a[i]);}
    document.getElementById('activity').innerHTML=h||'<div class="item">(no activity)</div>';}
}
async function refreshTodos(){
  var td=await j('/api/todos');
  if(td){var h2='';for(var k=0;k<td.length;k++){h2+='<div class="item"><span class="tag">'+esc(td[k].status)+'</span>'+esc(td[k].content)+'</div>';}
    document.getElementById('todos').innerHTML=h2||'<div class="item">(no todos)</div>';}
}
async function refreshBalance(){
  bal=await j('/api/balance');
  await refreshCost();
}
refreshBalance();
setInterval(refreshCost,2000);
setInterval(refreshActivity,2000);
setInterval(refreshTodos,2000);
setInterval(refreshBalance,30000);
</script></body></html>`;

function send(res, code, body, type) {
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  if (url === "/") {
    send(res, 200, html, "text/html; charset=utf-8");
  } else if (url === "/api/cost") {
    send(res, 200, JSON.stringify(apiCost()), "application/json");
  } else if (url === "/api/balance") {
    send(res, 200, JSON.stringify(await apiBalance()), "application/json");
  } else if (url === "/api/activity") {
    send(res, 200, JSON.stringify(apiActivity()), "application/json");
  } else if (url === "/api/todos") {
    send(res, 200, JSON.stringify(apiTodos()), "application/json");
  } else {
    send(res, 404, "not found\n", "text/plain");
  }
});

server.listen(port, host, () => {
  console.log("opencode observability: http://" + host + ":" + port + "  (db: " + dbPath + ")");
});
