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
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const dbPath = process.argv[2];
const port = Number(process.argv[3] || 5099);
const host = process.argv[4] || "127.0.0.1";

const RUNBOOKS = JSON.parse(
  readFileSync(new URL("./runbooks.json", import.meta.url), "utf8")
);

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
    "SELECT s.id, s.title, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning, s.tokens_cache_read, s.time_created, s.time_updated, " +
    "(SELECT MIN(p.time_created) FROM part p WHERE p.session_id=s.id) p_start, " +
    "(SELECT MAX(p.time_updated) FROM part p WHERE p.session_id=s.id) p_end " +
    "FROM session s ORDER BY s.time_created DESC LIMIT 12"
  );
  const latest = query("SELECT title FROM session ORDER BY time_created DESC LIMIT 1")[0];
  const lastPart = query("SELECT MAX(time_created) m FROM part")[0];
  const active = !!(lastPart && lastPart.m && Date.now() - Number(lastPart.m) < 30000);
  return { totals, sessions, latest: latest ? latest.title : null, active };
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

function apiOverview(limit) {
  return { budget: budgetUsd(), sessions: apiSessions(limit) };
}

function apiSchema() {
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

function apiIntegrations() {
  const tools = query(
    "SELECT json_extract(data,'$.tool') tool, COUNT(*) n FROM part WHERE json_extract(data,'$.type')='tool' GROUP BY tool ORDER BY n DESC"
  );
  const sum = (re) => tools.filter((t) => re.test(t.tool || '')).reduce((a, t) => a + t.n, 0);
  return { jev: sum(/jev/i), laya: sum(/laya/i), tools };
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

function apiSignals() {
  const errors = query(
    "SELECT s.id sid, s.title title, p.time_created ts, json_extract(p.data,'$.tool') tool, " +
    "COALESCE(json_extract(p.data,'$.state.input.command'), json_extract(p.data,'$.state.input.filePath'), json_extract(p.data,'$.tool'), '') detail " +
    "FROM part p JOIN session s ON s.id=p.session_id " +
    "WHERE json_extract(p.data,'$.type')='tool' AND json_extract(p.data,'$.state.status')='error' " +
    "ORDER BY p.time_created DESC LIMIT 40"
  );
  const signatures = {};
  for (const sig of ["SyntaxError", "Unexpected token", "EADDRINUSE", "FAIL:", "ReferenceError", "Traceback"]) {
    signatures[sig] = query(
      "SELECT COUNT(*) c FROM part WHERE json_extract(data,'$.text') LIKE ? OR json_extract(data,'$.state.input.command') LIKE ?",
      "%" + sig + "%", "%" + sig + "%"
    )[0].c;
  }
  const ruleMentions = {};
  for (const r of ["sed ", "2>/dev/null", "echo ", "rm -rf"]) {
    ruleMentions[r] = query(
      "SELECT COUNT(*) c FROM part WHERE json_extract(data,'$.state.input.command') LIKE ? OR json_extract(data,'$.text') LIKE ?",
      "%" + r + "%", "%" + r + "%"
    )[0].c;
  }
  const patches = query(
    "SELECT json_extract(data,'$.files') files, COUNT(*) n FROM part WHERE json_extract(data,'$.type')='patch' GROUP BY files ORDER BY n DESC LIMIT 20"
  );
  return { errorCount: errors.length, errors, signatures, ruleMentions, patches };
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
    "SELECT s.id, s.title, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning, s.tokens_cache_read, s.model, s.time_created, s.time_updated, " +
    "(SELECT MIN(p.time_created) FROM part p WHERE p.session_id=s.id) p_start, " +
    "(SELECT MAX(p.time_updated) FROM part p WHERE p.session_id=s.id) p_end " +
    "FROM session s ORDER BY s.time_created DESC LIMIT ?",
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

function sessionRow(id) {
  return query(
    "SELECT id, title, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, time_created, time_updated, model, agent FROM session WHERE id = ?",
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
  if (format === "json") return JSON.stringify({ session: s, turns }, null, 2);
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
  if (format === "md") return head + body;
  return head + body.replace(/^### /gm, "").replace(/^_\(reasoning\)_\n/gm, "[reasoning] ").replace(/^_\[/gm, "[");
}

function apiSearch(q, limit) {
  const needle = String(q || "").replace(/[%_\\]/g, "");
  const like = "%" + needle + "%";
  if (!needle) return { q, sessions: [], hits: [] };
  const sessions = query(
    "SELECT id, title, cost, tokens_input, time_created FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT ?",
    like, limit
  );
  const rows = query(
    "SELECT p.session_id sid, s.title title, p.time_created ts, json_extract(p.data,'$.type') type, " +
    "COALESCE(json_extract(p.data,'$.text'), json_extract(p.data,'$.state.input.command'), json_extract(p.data,'$.tool'), '') snippet " +
    "FROM part p JOIN session s ON s.id = p.session_id " +
    "WHERE json_extract(p.data,'$.text') LIKE ? OR json_extract(p.data,'$.state.input.command') LIKE ? " +
    "ORDER BY p.time_created DESC LIMIT ?",
    like, like, limit
  );
  const hits = rows.map((h) => ({ session: h.sid, title: h.title, ts: h.ts, type: h.type, snippet: String(h.snippet || "").slice(0, 200) }));
  return { q: needle, sessions, hits };
}

let fts = { db: null, at: 0, count: -1, sourceMax: -1 };

function sanitizeFts(q) {
  const words = String(q || "").toLowerCase().match(/[a-z0-9_]+/g) || [];
  return words.map((w) => '"' + w + '"').join(" ");
}

function ftsSource() {
  return query(
    "SELECT COUNT(*) n, COALESCE(MAX(time_created),0) m FROM part " +
    "WHERE json_extract(data,'$.text') IS NOT NULL OR json_extract(data,'$.state.input.command') IS NOT NULL"
  )[0];
}

function ensureFts() {
  const src = ftsSource();
  const n = Number(src.n), m = Number(src.m);
  if (fts.db && fts.count === n && fts.sourceMax === m && Date.now() - fts.at < 60000) return fts.db;
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE VIRTUAL TABLE parts_fts USING fts5(part_id UNINDEXED, session_id UNINDEXED, type UNINDEXED, text)");
  const rows = query(
    "SELECT id, session_id, json_extract(data,'$.type') type, " +
    "COALESCE(json_extract(data,'$.text'), json_extract(data,'$.state.input.command'), '') text " +
    "FROM part WHERE json_extract(data,'$.text') IS NOT NULL OR json_extract(data,'$.state.input.command') IS NOT NULL"
  );
  const ins = db.prepare("INSERT INTO parts_fts(part_id, session_id, type, text) VALUES (?,?,?,?)");
  db.exec("BEGIN");
  for (const r of rows) ins.run(r.id, r.session_id, r.type || "", String(r.text || ""));
  for (const o of ocrRows(2000)) ins.run("ocr" + o.id, "OCR", "ocr", String(o.text || ""));
  db.exec("COMMIT");
  fts = { db, at: Date.now(), count: n, sourceMax: m };
  return db;
}

function apiSemantic(q, limit) {
  const raw = String(q || "");
  const needle = sanitizeFts(raw);
  const sessions = query(
    "SELECT id, title, cost, tokens_input, time_created FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT ?",
    "%" + raw.replace(/[%_\\]/g, "") + "%", limit
  );
  if (!needle) return { q: raw, mode: "fts", indexed: fts.count, sessions, results: [] };
  let db;
  try { db = ensureFts(); } catch (e) {
    return { q: needle, mode: "error", error: String((e && e.message) || e), sessions, results: [] };
  }
  let rows;
  try {
    rows = db.prepare(
      "SELECT part_id, session_id, type, snippet(parts_fts, 3, '[', ']', '...', 14) snip, bm25(parts_fts) score " +
      "FROM parts_fts WHERE parts_fts MATCH ? ORDER BY score LIMIT ?"
    ).all(needle, limit);
  } catch (e) {
    return { q: needle, mode: "error", error: String((e && e.message) || e), sessions, results: [] };
  }
  const ids = [...new Set(rows.map((r) => r.session_id))];
  const titles = {};
  if (ids.length) {
    const ph = ids.map(() => "?").join(",");
    for (const t of query("SELECT id, title FROM session WHERE id IN (" + ph + ")", ...ids)) titles[t.id] = t.title;
  }
  const ocrTitles = {};
  for (const o of ocrRows(2000)) ocrTitles[o.id] = o.image;
  return {
    q: needle, mode: "fts", indexed: fts.count, sessions,
    results: rows.map((r) => {
      const isOcr = r.session_id === "OCR";
      return {
        session: isOcr ? "" : r.session_id,
        title: isOcr ? (ocrTitles[Number(String(r.part_id).slice(3))] || "(screenshot)") : (titles[r.session_id] || ""),
        type: r.type, snippet: r.snip, score: r.score, part: r.part_id, ocr: isOcr,
      };
    })
  };
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
 .srow{cursor:pointer}
 .srow:hover{background:#1f6feb22}
 input#q{width:100%;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:13px;box-sizing:border-box}
 .card a{font-size:12px;margin-right:6px}
 .live{color:#3fb950}.idle{color:#8b949e}
 #session{font-size:13px;margin-bottom:4px}
</style></head>
<body>
<h1>opencode observability <a href="/explore" style="color:#58a6ff;font-size:13px;text-decoration:none">[explore]</a> <a href="/api/export" style="color:#58a6ff;font-size:13px;text-decoration:none">[csv]</a> <a href="/runbooks" style="color:#58a6ff;font-size:13px;text-decoration:none">[runbooks]</a></h1>
<div id="session" class="muted"></div>
<div class="row" id="stats"></div>
<div class="card"><h3>Search <span class="muted">(ranked FTS: title · text · commands)</span></h3><input id="q" placeholder="search across sessions..."><div id="searchres"></div></div>
<div class="card"><h3>Config audit <span class="muted">(actual vs expected)</span></h3><div id="config"></div></div>
<div class="card"><h3>Sessions <span class="muted">(click a row to drill down)</span></h3><div id="sessions"></div></div>
<div class="card"><h3>Session detail <span class="muted" id="drill-id"></span></h3><div id="drill"><span class="muted">click a session row to drill down</span></div></div>
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
function dur(s){
  var a=Number(s.p_start||0), b=Number(s.p_end||0);
  if(b>a){return ((b-a)/1000).toFixed(0)+'s';}
  var d=Number(s.time_updated||0)-Number(s.time_created||0);
  return d>0?(d/1000).toFixed(0)+'s':'';
}
function sessRow(s){
  var c=+s.cost||0;
  var cls=c>=0.10?' class="num" style="color:#ff7b72"':' class="num"';
  return '<tr class="srow" data-id="'+esc(s.id||'')+'" title="click to drill down">'
    +'<td>'+esc(s.title||'(untitled)')+'</td>'
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
    sh+='</table><div class="muted" style="font-size:11px;margin-top:4px">in = tokens sent as context (the cost driver) · out = tokens generated · reasoning = chain-of-thought. Red = cost &ge; $0.10. click a row to drill down.</div>';
    var sel=document.getElementById('sessions');
    sel.innerHTML=sh;
    if(drillId){var row=sel.querySelector('tr[data-id="'+drillId+'"]');if(row){row.style.background='#1f6feb33';}}
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
var drillId=null;
function drillItem(x){
  var cls=String(x.type||'').toUpperCase();
  var tag=(x.type==='step-start'||x.type==='step-finish')?'STEP':cls;
  var body='';
  if(x.type==='tool'){body=esc(x.tool)+' ['+esc(x.status)+'] '+esc(x.cmd||'');}
  else if(x.type==='reasoning'||x.type==='text'){body=esc(String(x.text||'').slice(0,600));}
  else if(x.type==='patch'){body=esc(x.files||'');}
  return '<div class="item"><span class="tag '+tag+'">'+esc(x.type)+'</span>'+body+' <span class="muted">'+ts(x.ts)+'</span></div>';
}
async function drill(id){
  drillId=id;
  var d=await j('/api/session?id='+encodeURIComponent(id));
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
  for(var i=0;i<d.parts.length;i++){h+=drillItem(d.parts[i]);}
  el.innerHTML=h;
}
async function doSearch(){
  var q=document.getElementById('q').value.trim();
  var el=document.getElementById('searchres');
  if(!q){el.innerHTML='';return;}
  var h='';
  var r=await j('/api/semantic?q='+encodeURIComponent(q)+'&limit=20');
  if(r&&r.mode==='fts'){
    if(r.sessions&&r.sessions.length){h+='<div class="muted" style="font-size:11px">sessions</div>';
      for(var i=0;i<r.sessions.length;i++){var s=r.sessions[i];
        h+='<div class="item" data-go="'+esc(s.id)+'" style="cursor:pointer"><span class="tag STEP">session</span>'+esc(s.title)+' <span class="muted">$'+(+s.cost).toFixed(4)+'</span></div>';}}
    if(r.results&&r.results.length){h+='<div class="muted" style="font-size:11px">ranked matches</div>';
      for(var k=0;k<r.results.length;k++){var x=r.results[k];
        h+='<div class="item"'+(x.ocr?'':' data-go="'+esc(x.session)+'" style="cursor:pointer"')+'><span class="tag STEP">'+esc(x.ocr?'screenshot':(x.type||'part'))+'</span><span class="muted">'+esc(x.title||x.session)+'</span> — '+esc(x.snippet||'')+'</div>';}}
  } else {
    var f=await j('/api/search?q='+encodeURIComponent(q)+'&limit=20');
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
  var tr=ev.target&&ev.target.closest?ev.target.closest('tr.srow'):null;
  if(tr){drill(tr.getAttribute('data-id'));}
});
var want=new URLSearchParams(location.search).get('session');
if(want){drill(want);}
refreshBalance();
setInterval(refreshCost,2000);
setInterval(refreshActivity,2000);
setInterval(refreshTodos,2000);
setInterval(refreshBalance,30000);
setInterval(refreshConfig,30000);
</script></body></html>`;

const exploreHtml = `<!doctype html>
<html><head><meta charset="utf-8"><title>opencode explore</title>
<script src="/vendor/d3.min.js"></script>
<script src="/vendor/d3-sankey.min.js"></script>
<style>
 body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}
 h1{font-size:18px;margin:0 0 4px} h2{font-size:13px;color:#8b949e;margin:16px 0 6px}
 a{color:#58a6ff;text-decoration:none;font-size:13px}
 .chart{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;margin:6px 0;overflow-x:auto}
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
 .item{padding:4px 0;border-bottom:1px solid #21262d;font-size:12px;cursor:pointer}
 .item:hover{background:#1f6feb22}
 .tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;margin-right:6px;background:#30363d;color:#8b949e}
 .tabs{display:flex;gap:6px;margin:10px 0}
 .tab{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:5px 14px;font-size:12px;color:#8b949e;cursor:pointer}
 .tab.active{background:#1f6feb;color:#fff;border-color:#1f6feb}
 .row{display:flex;flex-wrap:wrap;gap:10px;margin:6px 0}
 .stat{flex:1;min-width:90px;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:8px}
 .stat b{display:block;font-size:16px}
 .stat span{color:#8b949e;font-size:11px}
</style></head>
<body>
<h1>opencode explore &nbsp;<a href="/">[dashboard]</a> <a href="/runbooks">[runbooks]</a> <a href="/api/export">[csv]</a></h1>
<div class="muted" id="filter">filter: all time</div> <button id="brush-reset">reset filter</button>
<div class="tabs">
  <button class="tab active" data-tab="overview">overview</button>
  <button class="tab" data-tab="charts">charts</button>
  <button class="tab" data-tab="signals">signals</button>
  <button class="tab" data-tab="ocr">ocr</button>
</div>
<div class="card" style="border-color:#d29922"><h2 style="margin-top:0">Session detail <button id="detail-close">close</button></h2><div id="detail"><span class="muted">click a treemap tile, scatter point, table row, or signal to drill in — without leaving this page</span></div></div>
<div class="pane" data-pane="overview">
<div class="card"><h2 style="margin-top:0">Search everything</h2><input id="q2" placeholder="search titles, message text, and tool commands (ranked)"><div id="sres"></div></div>
<h2>Sessions — sortable, filterable, click to open</h2>
<div class="chart"><input id="tfilter" placeholder="filter sessions by title or model..." style="max-width:360px"> <span id="tcount" class="muted"></span><div id="stable"></div></div>
<h2>Duplicates — near-identical sessions</h2>
<div class="chart" id="dupes"></div>
<h2>Integrations — Jev (hosted) vs Laya (self-hosted)</h2>
<div class="chart" id="integrations"></div>
<h2>Jev vs Laya — A/B runs (persisted)</h2>
<div class="chart" id="ab"></div>
<h2>Database map — tables sized by rows, edges = foreign keys</h2>
<div class="chart" id="dmap"></div>
</div>
<div class="pane" data-pane="charts" style="display:none">
<h2>Where the money goes — sessions sized by cost, grouped by model</h2>
<div class="chart" id="treemap"></div>
<h2>Cumulative spend vs budget — drag to filter the views below</h2>
<div class="chart" id="burn"></div>
<h2>Latency x cost — radius = tokens, colour = model (outliers are bottlenecks)</h2>
<div class="chart" id="scatter"></div>
<h2>Token flow — where the tokens go, by model</h2>
<div class="chart" id="sankey"></div>
<h2>Sessions over time — bar colour = cost (click to load the part timeline)</h2>
<div class="chart" id="gantt"></div>
<h2>Part timeline — <span id="tl-title">latest session</span> <button id="tl-reset">reset</button></h2>
<div class="chart" id="timeline"></div>
</div>
<div class="pane" data-pane="signals" style="display:none">
<h2>Signals — mistakes, rule mentions, churn</h2>
<div class="chart" id="signals"></div>
</div>
<div class="pane" data-pane="ocr" style="display:none">
<h2>OCR — screenshot text (searchable)</h2>
<div class="chart" id="ocr"></div>
</div>
<div class="tip" id="tip"></div>
<script>
function fmt(n){n=Number(n)||0;return n>=1000?(n/1000).toFixed(1)+'k':''+n;}
async function j(u){try{var r=await fetch(u);return r.ok?r.json():null;}catch(e){return null;}}
var colors={tool:'#58a6ff',reasoning:'#d2a8ff',text:'#7ee787','step-start':'#8b949e','step-finish':'#8b949e',patch:'#ff7b72'};
function tip(html){var t=d3.select('#tip');if(html==null){t.style('opacity',0);return;}t.html(html).style('opacity',1);}
function moveTip(ev){d3.select('#tip').style('left',(ev.clientX+14)+'px').style('top',(ev.clientY+14)+'px');}
function timeFmt(d){var x=new Date(d);return x.toISOString().slice(11,16);}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function modelId(m){if(!m)return '(none)';try{var o=JSON.parse(m);return o.id||o.modelID||m;}catch(e){return String(m);}}
function span(d){var a=Number(d.p_start||0),b=Number(d.p_end||0);if(b>a)return b-a;return Math.max(0,Number(d.time_updated||0)-Number(d.time_created||0));}
var MODEL_COLOR=null,COST=null;
var DATA=[],BUDGET=0,FILTER=[0,Infinity];
function inFilter(d){var t=d.time_created;return t>=FILTER[0]&&t<=FILTER[1];}
function setFilterText(){
  var el=document.getElementById('filter');
  if(!el)return;
  el.textContent=(FILTER[1]===Infinity)?'filter: all time':('filter: '+new Date(FILTER[0]).toISOString().slice(0,16)+' to '+new Date(FILTER[1]).toISOString().slice(0,16));
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
  if(TFILTER){var q=TFILTER.toLowerCase();rows=rows.filter(function(d){return String(d.title||'').toLowerCase().indexOf(q)>=0||modelId(d.model).toLowerCase().indexOf(q)>=0;});}
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
  var cols=[['title','title'],['model','model'],['cost','cost $'],['tokens_input','in'],['tokens_output','out'],['tokens_reasoning','reason'],['tokens_cache_read','cache'],['_span','span']];
  var table=el.append('table');
  table.append('tr').selectAll('th').data(cols).enter().append('th')
    .text(function(d){return (d[0]===SORT.col?'▾ ':'')+d[1];})
    .style('text-decoration',function(d){return d[0]===SORT.col?'underline':'none';})
    .on('click',function(ev,d){if(SORT.col===d[0])SORT.dir=-SORT.dir;else{SORT.col=d[0];SORT.dir=-1;}renderTable();});
  var tr=table.selectAll('tr.row').data(rows).enter().append('tr').attr('class','row')
    .on('click',function(ev,d){detail(d.id);});
  tr.append('td').text(function(d){return d.title||'(untitled)';});
  tr.append('td').text(function(d){return modelId(d.model);});
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
  var el=document.getElementById('detail');
  el.innerHTML='<span class="muted">loading...</span>';
  var d=await j('/api/session?id='+encodeURIComponent(id)+'&limit=300');
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
document.getElementById('brush-reset').addEventListener('click',function(){FILTER=[0,Infinity];setFilterText();renderBurn();renderTreemap();renderScatter();renderSankey();renderGantt();});
document.getElementById('detail-close').addEventListener('click',function(){document.getElementById('detail').innerHTML='<span class="muted">click a treemap tile, scatter point, table row, or signal to drill in — without leaving this page</span>';});
document.getElementById('signals').addEventListener('click',function(ev){var t=ev.target&&ev.target.closest?ev.target.closest('[data-go]'):null;if(t){detail(t.getAttribute('data-go'));}});
async function renderOcr(){
  var el=d3.select('#ocr');el.selectAll('*').remove();
  var d=await j('/api/ocr?limit=20');
  if(!d||!d.runs||!d.runs.length){el.text('no OCR yet — run ./scripts/ocr-image.sh <image> to read a screenshot locally');return;}
  var h='<div class="muted" style="font-size:12px">'+d.count+' OCR runs · also searchable from the search box</div>';
  for(var i=0;i<d.runs.length;i++){var r=d.runs[i];
    h+='<div class="item"><span class="tag">'+esc(r.engine)+'</span>'+esc(r.image)+' <span class="muted">'+esc(r.ts||'')+'</span><div class="muted" style="white-space:pre-wrap;font-size:11px">'+esc(r.snippet)+'</div></div>';}
  el.html(h);
}
async function renderDupes(){
  var el=d3.select('#dupes');el.selectAll('*').remove();
  var d=await j('/api/duplicates');
  if(!d||!d.length){el.text('no duplicate sessions');return;}
  var h='<div class="muted" style="font-size:12px">'+d.length+' duplicate groups (normalized title)</div>';
  for(var i=0;i<d.length;i++){var g=d[i];h+='<div class="item"><span class="tag">'+g.count+'x</span>'+esc(g.title)+' <span class="muted">$'+(+g.cost).toFixed(4)+'</span></div>';}
  el.html(h);
}
document.getElementById('tabs').addEventListener('click',function(ev){
  var b=ev.target&&ev.target.closest?ev.target.closest('.tab'):null;
  if(!b)return;
  var name=b.getAttribute('data-tab');
  var tabs=document.querySelectorAll('#tabs .tab');
  for(var i=0;i<tabs.length;i++){tabs[i].classList.remove('active');}
  b.classList.add('active');
  var panes=document.querySelectorAll('.pane');
  for(var j=0;j<panes.length;j++){panes[j].style.display=(panes[j].getAttribute('data-pane')===name)?'block':'none';}
});
async function load(){
  if(typeof d3==='undefined'){var el=document.getElementById('treemap');if(el){el.textContent='d3 failed to load (/vendor/d3.min.js)';}return;}
  var o=await j('/api/overview?limit=500');
  if(!o||!o.sessions){d3.select('#treemap').text('(no data)');return;}
  BUDGET=o.budget;DATA=o.sessions;setFilterText();
  DATA.forEach(function(d){d._span=span(d);});
  MODEL_COLOR=d3.scaleOrdinal(['#79c0ff','#d2a8ff','#7ee787','#ffa657','#ff7b72']);
  COST=d3.scaleLinear().domain([0,d3.max(DATA,function(d){return +d.cost||0;})||1]).range(['#1b3a5c','#79c0ff']);
  renderTable();renderDupes();renderSignals();renderOcr();renderIntegrations();renderAb();renderSchema();
  renderTreemap();renderBurn();renderScatter();renderSankey();renderGantt();renderTimeline();
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
  d3.treemapResquarify().size([W,H]).paddingInner(2).paddingTop(18).paddingOuter(2).round(true)(root);
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
    .style('cursor','pointer')
    .on('click',function(ev,d){location.href='/?session='+encodeURIComponent(d.data.id);})
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

async function renderBurn(){
  var el=d3.select('#burn');el.selectAll('*').remove();
  if(!DATA.length){el.text('(no data)');return;}
  var data=DATA.slice().sort(function(a,b){return a.time_created-b.time_created;});
  var cum=0,pts=data.map(function(d){cum+=(+d.cost||0);return {t:d.time_updated||d.time_created,v:cum};});
  var total=cum;
  var margin={top:12,right:16,bottom:26,left:64};
  var W=1000,H=220,w=W-margin.left-margin.right,h=H-margin.top-margin.bottom;
  var t0=data[0].time_created,t1=Math.max(data[data.length-1].time_updated||data[data.length-1].time_created,t0+1);
  var x=d3.scaleTime().domain([t0,t1]).range([0,w]);
  var y=d3.scaleLinear().domain([0,Math.max(BUDGET,total||0)*1.08]).nice().range([h,0]);
  var svg=el.append('svg').attr('width',W).attr('height',H).append('g').attr('transform','translate('+margin.left+','+margin.top+')');
  svg.append('g').attr('class','grid').call(d3.axisLeft(y).ticks(5).tickSize(-w).tickFormat(''));
  var area=d3.area().x(function(d){return x(d.t);}).y0(h).y1(function(d){return y(d.v);}).curve(d3.curveStepAfter);
  var line=d3.line().x(function(d){return x(d.t);}).y(function(d){return y(d.v);}).curve(d3.curveStepAfter);
  svg.append('path').datum(pts).attr('fill','#1f6feb22').attr('d',area);
  svg.append('path').datum(pts).attr('fill','none').attr('stroke','#58a6ff').attr('stroke-width',1.5).attr('d',line);
  svg.append('line').attr('x1',0).attr('x2',w).attr('y1',y(BUDGET)).attr('y2',y(BUDGET)).attr('stroke','#ff7b72').attr('stroke-dasharray','4 3');
  svg.append('text').attr('x',w).attr('y',y(BUDGET)-4).attr('text-anchor','end').attr('class','lbl').text('budget $'+BUDGET);
  svg.append('g').attr('class','axis').attr('transform','translate(0,'+h+')').call(d3.axisBottom(x).ticks(6).tickFormat(d3.timeFormat('%b %d %H:%M')));
  svg.append('g').attr('class','axis').call(d3.axisLeft(y).ticks(5).tickFormat(function(v){return '$'+v;}));
  var brush=d3.brushX().extent([[0,0],[w,h]]).on('brush end',function(ev){
    if(!ev.selection){FILTER=[0,Infinity];}
    else{FILTER=[+x.invert(ev.selection[0]),+x.invert(ev.selection[1])];}
    setFilterText();renderTreemap();renderScatter();renderSankey();renderGantt();
  });
  svg.append('g').call(brush);
}

async function renderScatter(){
  var data=DATA.filter(inFilter);
  var el=d3.select('#scatter');el.selectAll('*').remove();
  if(!data.length){el.text('(no sessions in range)');return;}
  var margin={top:12,right:18,bottom:34,left:70};
  var W=1000,H=300,w=W-margin.left-margin.right,h=H-margin.top-margin.bottom;
  var xmin=Math.max(1000,d3.min(data,function(d){return span(d);})/2);
  var xmax=Math.max(xmin*2,d3.max(data,function(d){return span(d);})*1.5);
  var ymax=Math.max(0.0002,d3.max(data,function(d){return +d.cost||0;})*1.5);
  var x=d3.scaleLog().domain([xmin,xmax]).range([0,w]);
  var y=d3.scaleLog().domain([0.0001,ymax]).range([h,0]);
  var r=d3.scaleSqrt().domain([0,d3.max(data,function(d){return (+d.tokens_input||0)+(+d.tokens_output||0);})||1]).range([1.5,13]);
  var svg=el.append('svg').attr('width',W).attr('height',H).append('g').attr('transform','translate('+margin.left+','+margin.top+')');
  var xticks=[1000,10000,60000,600000,3600000,86400000].filter(function(v){return v>=x.domain()[0]&&v<=x.domain()[1];});
  var yticks=[0.0001,0.001,0.01,0.1,1,10].filter(function(v){return v>=y.domain()[0]&&v<=y.domain()[1];});
  var fmtSpan=function(v){var s=v/1000;return s<60?(s+'s'):(s<3600?(Math.round(s/60)+'m'):(Math.round(s/3600)+'h'));};
  svg.append('g').attr('class','grid').call(d3.axisLeft(y).tickValues(yticks).tickSize(-w).tickFormat(''));
  svg.append('g').attr('class','axis').attr('transform','translate(0,'+h+')').call(d3.axisBottom(x).tickValues(xticks).tickFormat(fmtSpan));
  svg.append('g').attr('class','axis').call(d3.axisLeft(y).tickValues(yticks).tickFormat(function(v){return '$'+(+v).toPrecision(2);}));
  svg.append('text').attr('class','lbl').attr('x',w).attr('y',h+30).attr('text-anchor','end').text('span (log)');
  svg.append('text').attr('class','lbl').attr('transform','rotate(-90)').attr('x',-h).attr('y',-54).attr('text-anchor','end').text('cost (log)');
  svg.selectAll('circle').data(data).enter().append('circle')
    .attr('cx',function(d){return x(Math.max(xmin,span(d)));})
    .attr('cy',function(d){return y(Math.max(0.0001,+d.cost||0.0001));})
    .attr('r',function(d){return r((+d.tokens_input||0)+(+d.tokens_output||0));})
    .attr('fill',function(d){return MODEL_COLOR(modelId(d.model));})
    .attr('fill-opacity',0.45)
    .style('cursor','pointer')
    .on('click',function(ev,d){location.href='/?session='+encodeURIComponent(d.id);})
    .on('mousemove',function(ev,d){moveTip(ev);tip(esc(d.title)+'<br>$'+(+d.cost).toFixed(4)+' · '+(span(d)/1000).toFixed(0)+'s · in '+fmt(d.tokens_input)+' · '+esc(modelId(d.model)));})
    .on('mouseleave',function(){tip(null);});
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
  var layout=d3.sankey().nodeWidth(12).nodePadding(16).nodeAlign(d3.sankeyJustify).extent([[2,14],[W-160,H-14]]);
  var graph=layout({nodes:nodes.map(function(n){return {name:n.name,kind:n.kind};}),links:links.map(function(l){return {source:l.source,target:l.target,value:l.value};})});
  var catColor={'cache read':'#8b949e','reasoning':'#d2a8ff','output':'#7ee787'};
  var svg=el.append('svg').attr('width',W).attr('height',H).append('g');
  svg.append('g').selectAll('path').data(graph.links).enter().append('path')
    .attr('d',d3.sankeyLinkHorizontal())
    .attr('fill','none')
    .attr('stroke',function(d){return catColor[d.target.name]||'#30363d';})
    .attr('stroke-opacity',0.30)
    .attr('stroke-width',function(d){return Math.max(1,d.width);})
    .on('mousemove',function(ev,d){moveTip(ev);tip(esc(d.source.name)+' → '+esc(d.target.name)+'<br>'+fmt(d.value)+' tokens');})
    .on('mouseleave',function(){tip(null);});
  var node=svg.append('g').selectAll('g').data(graph.nodes).enter().append('g');
  node.append('rect')
    .attr('x',function(d){return d.x0;}).attr('y',function(d){return d.y0;})
    .attr('width',function(d){return d.x1-d.x0;}).attr('height',function(d){return Math.max(1,d.y1-d.y0);})
    .attr('rx',2)
    .attr('fill',function(d){return d.kind==='model'?MODEL_COLOR(d.name):(catColor[d.name]||'#8b949e');})
    .attr('fill-opacity',0.9);
  node.append('text')
    .attr('x',function(d){return d.x0<W/2?d.x1+6:d.x0-6;})
    .attr('y',function(d){return (d.y0+d.y1)/2;})
    .attr('dy','0.35em')
    .attr('text-anchor',function(d){return d.x0<W/2?'start':'end';})
    .attr('class','lbl')
    .text(function(d){return d.name+'  '+fmt(d.value);});
}

async function renderGantt(){
  var data=DATA.filter(inFilter);
  var el=d3.select('#gantt');el.selectAll('*').remove();
  if(!data.length){el.text('(no sessions in range)');return;}
  var margin={top:8,right:16,bottom:24,left:8};
  var W=1000,w=W-margin.left-margin.right,h=Math.max(160,data.length*7);
  var minT=d3.min(data,function(d){return d.time_created;});
  var maxT=d3.max(data,function(d){return d.time_updated||d.time_created;});
  if(maxT<=minT)maxT=minT+1000;
  var x=d3.scaleLinear().domain([minT,maxT]).range([0,w]);
  var svg=el.append('svg').attr('width',W).attr('height',h+margin.top+margin.bottom).append('g').attr('transform','translate('+margin.left+','+margin.top+')');
  svg.selectAll('rect').data(data).enter().append('rect')
    .attr('x',function(d){return x(d.time_created);})
    .attr('y',function(d,i){return i*7;})
    .attr('width',function(d){return Math.max(2,x(d.time_updated||d.time_created)-x(d.time_created));})
    .attr('height',5).attr('rx',1)
    .attr('fill',function(d){return COST(+d.cost||0);})
    .style('cursor','pointer')
    .on('click',function(ev,d){renderTimeline(d.id,d.title);})
    .on('mousemove',function(ev,d){moveTip(ev);tip(esc(d.title)+'<br>$'+(+d.cost).toFixed(4)+' · in '+fmt(d.tokens_input)+' / out '+fmt(d.tokens_output)+' / reas '+fmt(d.tokens_reasoning));})
    .on('mouseleave',function(){tip(null);});
  svg.append('g').attr('class','axis').attr('transform','translate(0,'+h+')').call(d3.axisBottom(x).ticks(6).tickFormat(timeFmt));
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

document.getElementById('tl-reset').addEventListener('click',function(){renderTimeline(null,null);});
load();
</script></body></html>`;

const runbooksHtml = `<!doctype html>
<html><head><meta charset="utf-8"><title>opencode runbooks</title>
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
</style></head>
<body>
<h1>opencode runbooks <a href="/">[dashboard]</a> <a href="/explore">[explore]</a> <a href="/api/export">[csv]</a></h1>
<div class="muted" style="font-size:12px">Operational scripts surfaced read-only. host = run on the machine with docker; container = safe inside the agent container. Copy, then paste into a terminal.</div>
<div class="bar"><label class="muted" for="f">filter</label><select id="f"><option value="all">all</option><option value="host">host only</option><option value="container">container only</option></select></div>
<div id="count" class="muted count"></div>
<div id="list"></div>
<script>
var RUNBOOKS=[];
function render(){
  var f=document.getElementById('f').value;
  var el=document.getElementById('list');el.innerHTML='';
  var shown=0;
  for(var i=0;i<RUNBOOKS.length;i++){
    var r=RUNBOOKS[i];
    if(f!=='all'&&r.where!==f)continue;
    shown++;
    var card=document.createElement('div');card.className='card';
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
fetch('/api/runbooks').then(function(r){return r.json();}).then(function(d){RUNBOOKS=d;render();}).catch(function(){document.getElementById('list').innerHTML='<div class="muted">(runbooks unavailable)</div>';});
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
  } else if (url === "/explore") {
    send(res, 200, exploreHtml, "text/html; charset=utf-8");
  } else if (url === "/viz") {
    res.writeHead(302, { "Location": "/explore", "Cache-Control": "no-store" });
    res.end();
  } else if (url.indexOf("/vendor/") === 0) {
    const name = url.slice("/vendor/".length);
    if (name === "d3.min.js" || name === "d3-sankey.min.js") {
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
  } else if (url === "/api/runbooks") {
    send(res, 200, JSON.stringify(RUNBOOKS), "application/json");
  } else if (url === "/api/overview") {
    send(res, 200, JSON.stringify(apiOverview(Number(params.limit) || 500)), "application/json");
  } else if (url === "/api/schema") {
    send(res, 200, JSON.stringify(apiSchema()), "application/json");
  } else if (url === "/api/integrations") {
    send(res, 200, JSON.stringify(apiIntegrations()), "application/json");
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
  } else if (url === "/api/signals") {
    send(res, 200, JSON.stringify(apiSignals()), "application/json");
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
  } else if (url === "/api/session") {
    send(res, 200, JSON.stringify(apiSessionDetail(params.id, Number(params.limit) || 400)), "application/json");
  } else if (url === "/api/search") {
    send(res, 200, JSON.stringify(apiSearch(params.q, Number(params.limit) || 20)), "application/json");
  } else if (url === "/api/semantic") {
    send(res, 200, JSON.stringify(apiSemantic(params.q, Number(params.limit) || 20)), "application/json");
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
