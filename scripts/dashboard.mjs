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
import { execFileSync } from "node:child_process";

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
    "SELECT title, cost, tokens_input, tokens_output, tokens_reasoning, time_created, time_updated FROM session ORDER BY time_created DESC LIMIT 12"
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

function apiSessions(limit) {
  return query(
    "SELECT id, title, cost, tokens_input, tokens_output, tokens_reasoning, time_created, time_updated FROM session ORDER BY time_created DESC LIMIT ?",
    limit
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

const STOP = new Set(("the a an and or but if then else of to in on for with is are was were be been this that these those it its as at by from we you i he she they not no do does did can could will would should may might about into over under out up down so very just than what when where which who how all any more most other some only own same your our").split(" "));

function apiWords(limit) {
  const rows = query(
    "SELECT data FROM part WHERE json_extract(data, '$.type') IN ('reasoning','text') ORDER BY time_created DESC LIMIT 4000"
  );
  const counts = {};
  for (const r of rows) {
    let d;
    try { d = JSON.parse(r.data); } catch { continue; }
    const words = String(d.text || "").toLowerCase().split(/[^a-z0-9_]+/);
    for (const w of words) {
      if (w.length < 3 || STOP.has(w)) continue;
      counts[w] = (counts[w] || 0) + 1;
    }
  }
  const arr = Object.entries(counts).map(([text, size]) => ({ text, size }));
  arr.sort((a, b) => b.size - a.size);
  return arr.slice(0, limit);
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
  return body;
}

let balanceCache = { at: 0, data: { available: false } };
let configCache = { at: 0, data: null };

function apiConfig() {
  const script = process.argv[5];
  if (!script) return { findings: [], summary: { ok: 0, warn: 0, error: 0, fatal: 0, skip: 0 } };
  if (configCache.data && Date.now() - configCache.at < 60000) return configCache.data;
  try {
    const out = execFileSync("bash", [script, "--json"], { timeout: 45000, encoding: "utf8" });
    const j = JSON.parse(out.trim());
    configCache = { at: Date.now(), data: j };
    return j;
  } catch {
    return { error: "config audit failed to run" };
  }
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
<h1>opencode observability <a href="/viz" style="color:#58a6ff;font-size:13px;text-decoration:none">[charts]</a> <a href="/api/export" style="color:#58a6ff;font-size:13px;text-decoration:none">[csv]</a></h1>
<div id="session" class="muted"></div>
<div class="row" id="stats"></div>
<div class="card"><h3>Config audit <span class="muted">(actual vs expected)</span></h3><div id="config"></div></div>
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
function dur(s){var d=Number(s.time_updated||0)-Number(s.time_created||0);return d>0?(d/1000).toFixed(0)+'s':'';}
function sessRow(s){
  var c=+s.cost||0;
  var cls=c>=0.10?' class="num" style="color:#ff7b72"':' class="num"';
  return '<tr><td title="'+esc(s.title||'')+'">'+esc(s.title||'(untitled)')+'</td>'
    +'<td'+cls+'>$'+c.toFixed(4)+'</td>'
    +'<td class="num">'+fmt(s.tokens_input)+'</td>'
    +'<td class="num">'+fmt(s.tokens_output)+'</td>'
    +'<td class="num">'+fmt(s.tokens_reasoning)+'</td>'
    +'<td class="num">'+dur(s)+'</td></tr>';
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
    var sh='<table><tr><th>title</th><th class="num">cost $</th><th class="num">in</th><th class="num">out</th><th class="num">reasoning</th><th class="num">dur</th></tr>';
    for(var i=0;i<c.sessions.length;i++){sh+=sessRow(c.sessions[i]);}
    sh+='</table><div class="muted" style="font-size:11px;margin-top:4px">in = tokens sent as context (the cost driver) · out = tokens generated · reasoning = chain-of-thought. Red = cost &ge; $0.10.</div>';
    document.getElementById('sessions').innerHTML=sh;
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
refreshBalance();
setInterval(refreshCost,2000);
setInterval(refreshActivity,2000);
setInterval(refreshTodos,2000);
setInterval(refreshBalance,30000);
setInterval(refreshConfig,30000);
</script></body></html>`;

const vizHtml = `<!doctype html>
<html><head><meta charset="utf-8"><title>opencode viz</title>
<script src="https://cdn.jsdelivr.net/npm/d3@7"></script>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 4px} h2{font-size:13px;color:#8b949e;margin:16px 0 6px}
 a{color:#58a6ff;text-decoration:none;font-size:13px}
 .chart{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;margin:6px 0;overflow-x:auto}
 .tip{position:absolute;background:#21262d;border:1px solid #30363d;padding:6px 8px;border-radius:4px;font-size:12px;pointer-events:none;opacity:0;max-width:420px}
</style></head>
<body>
<h1>opencode viz &nbsp;<a href="/">[dashboard]</a> <a href="/api/export">[export csv]</a></h1>
<h2>Sessions over time — bar color = cost</h2>
<div class="chart" id="gantt"></div>
<h2>Part timeline — <span id="tl-title">latest session</span> <a href="#" onclick="renderTimeline(null,null);return false;">[reset]</a></h2>
<div class="chart" id="timeline"></div>
<h2>Term frequency — reasoning + answer text</h2>
<div class="chart" id="cloud"></div>
<div class="tip" id="tip"></div>
<script>
function fmt(n){n=Number(n)||0;return n>=1000?(n/1000).toFixed(1)+'k':''+n;}
async function j(u){try{var r=await fetch(u);return r.ok?r.json():null;}catch(e){return null;}}
var colors={tool:'#58a6ff',reasoning:'#d2a8ff',text:'#7ee787','step-start':'#8b949e','step-finish':'#8b949e',patch:'#ff7b72'};
function tip(html){var t=d3.select('#tip');if(html==null){t.style('opacity',0);return;}t.html(html).style('opacity',1);}
function moveTip(ev){d3.select('#tip').style('left',(ev.clientX+14)+'px').style('top',(ev.clientY+14)+'px');}
function timeFmt(d){var x=new Date(d);return x.toISOString().slice(11,16);}

async function renderGantt(){
  var data=await j('/api/sessions?limit=200');
  var el=d3.select('#gantt');
  if(!data||!data.length){el.text('(no sessions)');return;}
  var margin={top:8,right:16,bottom:24,left:8};
  var w=1000-margin.left-margin.right, h=Math.max(220,data.length*7);
  var minT=d3.min(data,function(d){return d.time_created;});
  var maxT=d3.max(data,function(d){return d.time_updated||d.time_created;});
  if(maxT<=minT)maxT=minT+1000;
  var x=d3.scaleLinear().domain([minT,maxT]).range([0,w]);
  var c=d3.scaleSequential(d3.interpolateViridis).domain([0,d3.max(data,function(d){return +d.cost;})||1]);
  el.selectAll('*').remove();
  var svg=el.append('svg').attr('width',1000).attr('height',h+margin.top+margin.bottom).append('g').attr('transform','translate('+margin.left+','+margin.top+')');
  svg.selectAll('rect').data(data).enter().append('rect')
    .attr('x',function(d){return x(d.time_created);})
    .attr('y',function(d,i){return i*7;})
    .attr('width',function(d){return Math.max(2,x(d.time_updated||d.time_created)-x(d.time_created));})
    .attr('height',6)
    .attr('fill',function(d){return c(d.cost);})
    .style('cursor','pointer')
    .on('click',function(ev,d){renderTimeline(d.id,d.title);})
    .on('mousemove',function(ev,d){moveTip(ev);tip(d.title+'<br>$'+(+d.cost).toFixed(4)+' · in '+fmt(d.tokens_input)+' / out '+fmt(d.tokens_output)+' / reas '+fmt(d.tokens_reasoning)+' (click to drill down)');})
    .on('mouseleave',function(){tip(null);});
  svg.append('g').attr('transform','translate(0,'+(data.length*7)+')').call(d3.axisBottom(x).ticks(6).tickFormat(timeFmt));
}

async function renderTimeline(id,title){
  var url='/api/parts?limit=600'+(id?'&session='+encodeURIComponent(id):'');
  var data=await j(url);
  var el=d3.select('#timeline');
  d3.select('#tl-title').text(title||'latest session');
  if(!data||!data.length){el.text('(no parts)');return;}
  var margin={top:8,right:16,bottom:24,left:8};
  var w=1000-margin.left-margin.right, h=120;
  var minT=d3.min(data,function(d){return d.ts;});
  var maxT=d3.max(data,function(d){return d.te;});
  if(maxT<=minT)maxT=minT+1000;
  var x=d3.scaleLinear().domain([minT,maxT]).range([0,w]);
  el.selectAll('*').remove();
  var svg=el.append('svg').attr('width',1000).attr('height',h+margin.top+margin.bottom).append('g').attr('transform','translate('+margin.left+','+margin.top+')');
  svg.selectAll('rect').data(data).enter().append('rect')
    .attr('x',function(d){return x(d.ts);})
    .attr('y',30)
    .attr('width',function(d){return Math.max(2,x(d.te)-x(d.ts));})
    .attr('height',16)
    .attr('rx',2)
    .attr('fill',function(d){return colors[d.type]||'#8b949e';})
    .on('mousemove',function(ev,d){moveTip(ev);tip(d.type+(d.tool?' '+d.tool:'')+(d.status?' ['+d.status+']':'')+'<br>'+String(d.cmd||d.text||'').slice(0,140));})
    .on('mouseleave',function(){tip(null);});
  svg.append('g').attr('transform','translate(0,50)').call(d3.axisBottom(x).ticks(6).tickFormat(timeFmt));
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
    out.push({text:words[i].text,size:s,x:x,y:y});
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
  el.append('svg').attr('width',W).attr('height',H).append('g').attr('transform','translate('+W/2+','+H/2+')')
    .selectAll('text').data(placed).enter().append('text')
    .style('font-size',function(d){return d.size+'px';})
    .style('fill',function(d){return d3.interpolateViridis(d.size/64);})
    .attr('text-anchor','middle')
    .attr('transform',function(d){return 'translate('+d.x+','+d.y+')';})
    .text(function(d){return d.text;});
}

renderGantt();renderTimeline();renderCloud();
</script></body></html>`;

function send(res, code, body, type) {
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  const params = qs(req);
  if (url === "/") {
    send(res, 200, html, "text/html; charset=utf-8");
  } else if (url === "/viz") {
    send(res, 200, vizHtml, "text/html; charset=utf-8");
  } else if (url === "/api/cost") {
    send(res, 200, JSON.stringify(apiCost()), "application/json");
  } else if (url === "/api/balance") {
    send(res, 200, JSON.stringify(await apiBalance()), "application/json");
  } else if (url === "/api/config") {
    send(res, 200, JSON.stringify(apiConfig()), "application/json");
  } else if (url === "/api/activity") {
    send(res, 200, JSON.stringify(apiActivity()), "application/json");
  } else if (url === "/api/todos") {
    send(res, 200, JSON.stringify(apiTodos()), "application/json");
  } else if (url === "/api/sessions") {
    send(res, 200, JSON.stringify(apiSessions(Number(params.limit) || 200)), "application/json");
  } else if (url === "/api/parts") {
    send(res, 200, JSON.stringify(apiParts(params.session || null, Number(params.limit) || 600)), "application/json");
  } else if (url === "/api/words") {
    send(res, 200, JSON.stringify(apiWords(Number(params.limit) || 80)), "application/json");
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

server.listen(port, host, () => {
  console.log("opencode observability: http://" + host + ":" + port + "  (db: " + dbPath + ")");
});
