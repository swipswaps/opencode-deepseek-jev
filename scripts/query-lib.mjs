#!/usr/bin/env node
// query-lib.mjs — pure read-only aggregations shared by the dashboard server
// and query-worker.mjs. Single source of truth: dashboard.mjs wrappers call
// these (never duplicate the SQL), and the worker imports them directly so
// heavy scans run off the event loop without a second implementation to
// drift. Every function is (dbPath, ...) -> plain JSON; each opens its own
// read-only handle per call (node:sqlite handles cannot cross threads).
// Behavior changes here must keep test-dashboard.sh endpoint shapes green.
import { DatabaseSync } from "node:sqlite";
import { readFileSync, writeFileSync, renameSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function queryDb(dbPath, sql, ...args) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return db.prepare(sql).all(...args);
  } finally {
    db.close();
  }
}

// Durable derived-cache helpers (pi-durable #74): a slow panel's last good
// value is persisted atomically and re-served at startup as stale, so a cold
// process never makes the user wait for the rebuild. Values are plain JSON.
export function loadJsonCache(path) {
  try {
    const j = JSON.parse(readFileSync(path, "utf8"));
    if (j && j.value !== undefined) return j;
  } catch { /* absent or torn: cold start is the fallback */ }
  return null;
}

export function saveJsonCache(path, value) {
  try {
    const tmp = path + ".tmp." + process.pid;
    writeFileSync(tmp, JSON.stringify({ at: Date.now(), value }));
    renameSync(tmp, path);   // atomic on the same filesystem
    return true;
  } catch { return false; }
}

// /api/trends payload (sessions + cost per day). Moved here so the worker can
// run it off the dashboard event loop; the dashboard keeps this exact body as
// the inline fallback (same shape the page already renders).
export function apiTrendsFresh(dbPath) {
  return queryDb(
    dbPath,
    "SELECT date(time_created/1000,'unixepoch') day, COUNT(*) n, COALESCE(SUM(cost),0) c, " +
      "COALESCE(SUM(tokens_input),0) i FROM session GROUP BY day ORDER BY day"
  );
}

// /api/search legacy substring search. The LIKE + json_extract scan measured
// 6.8 s on the live 59k-part store, so it runs in the worker (off-loop) and is
// cached by query; /api/semantic remains the fast FTS5 path.
export function apiSearchFresh(dbPath, q, limit) {
  const needle = String(q || "").replace(/[%_\\]/g, "");
  const like = "%" + needle + "%";
  if (!needle) return { q, sessions: [], hits: [] };
  const sessions = queryDb(
    dbPath,
    "SELECT id, title, cost, tokens_input, time_created FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT ?",
    like, limit
  );
  const rows = queryDb(
    dbPath,
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

// /api/integrations: json_extract GROUP BY over every part (8.6 s measured).
// Static enough for a 60 s cache; runs in the worker.
export function apiIntegrationsFresh(dbPath) {
  const tools = queryDb(
    dbPath,
    "SELECT json_extract(data,'$.tool') tool, COUNT(*) n FROM part WHERE json_extract(data,'$.type')='tool' GROUP BY tool ORDER BY n DESC"
  );
  const sum = (re) => tools.filter((t) => re.test(t.tool || "")).reduce((a, t) => a + t.n, 0);
  return { jev: sum(/jev/i), laya: sum(/laya/i), tools };
}

// /api/cost: polling endpoint (home every 2 s). Cold compute includes 12
// correlated part lookups; run it in the worker so a TTL expiry cannot block
// the loop. Same payload the home page already renders.
export function apiCostFresh(dbPath) {
  const totals = queryDb(
    dbPath,
    "SELECT COUNT(*) n, COALESCE(SUM(cost),0) c, COALESCE(SUM(tokens_input),0) i, COALESCE(SUM(tokens_output),0) o, COALESCE(SUM(tokens_reasoning),0) r, COALESCE(SUM(tokens_cache_read),0) cr FROM session"
  )[0];
  const sessions = queryDb(
    dbPath,
    "SELECT s.id, s.title, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning, s.tokens_cache_read, s.model, s.agent, s.directory, s.time_created, s.time_updated, " +
      "(SELECT MIN(p.time_created) FROM part p WHERE p.session_id=s.id) p_start, " +
      "(SELECT MAX(p.time_updated) FROM part p WHERE p.session_id=s.id) p_end " +
      "FROM session s ORDER BY s.time_created DESC LIMIT 12"
  );
  const latest = queryDb(dbPath, "SELECT title FROM session ORDER BY time_created DESC LIMIT 1")[0];
  const lastPart = queryDb(dbPath, "SELECT MAX(time_created) m FROM part")[0];
  const active = !!(lastPart && lastPart.m && Date.now() - Number(lastPart.m) < 30000);
  return { totals, sessions, latest: latest ? latest.title : null, active };
}

// /api/activity: bounded to the 12 most recently updated sessions (the scoped
// query measured ~0.3 s; the unscoped sort was 3.1 s+). Still off-loop.
export function apiActivityFresh(dbPath) {
  const rows = queryDb(
    dbPath,
    "SELECT time_created, data FROM part WHERE session_id IN (SELECT id FROM session ORDER BY time_updated DESC LIMIT 12) ORDER BY time_created DESC LIMIT 80"
  );
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

// Board payload (Kanban + Gantt + milestones) for /api/board. Lives here so the
// ~19s cold compute runs in query-worker (off the dashboard event loop); the
// dashboard keeps an inline fallback with identical output (healthSync pattern).
export function apiBoardFresh(dbPath, todoPath, obsDbPath) {
  let cards = [];
  try {
    const rows = queryDb(
      dbPath,
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
  try { md = readFileSync(todoPath, "utf8"); } catch { md = ""; }
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
    const db = new DatabaseSync(obsDbPath, { readOnly: true });
    milestones = db.prepare("SELECT ts, type, verdict, source FROM ledger ORDER BY id DESC LIMIT 200").all()
      .map((r) => ({ ts: r.ts, type: r.type, verdict: r.verdict || "", source: r.source || "" }));
    db.close();
  } catch { milestones = []; }
  let sessions = [];
  try {
    sessions = queryDb(
      dbPath,
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

const STOP = new Set(("the a an and or but if then else of to in on for with is are was were be been this that these those it its as at by from we you i he she they not no do does did can could will would should may might about into over under out up down so very just than what when where which who how all any more most other some only own same your our").split(" "));

export function apiSignalsFresh(dbPath) {
  const errors = queryDb(dbPath,
    "SELECT s.id sid, s.title title, p.time_created ts, json_extract(p.data,'$.tool') tool, " +
    "COALESCE(json_extract(p.data,'$.state.input.command'), json_extract(p.data,'$.state.input.filePath'), json_extract(p.data,'$.tool'), '') detail " +
    "FROM part p JOIN session s ON s.id=p.session_id " +
    "WHERE json_extract(p.data,'$.type')='tool' AND json_extract(p.data,'$.state.status')='error' " +
    "ORDER BY p.time_created DESC LIMIT 40"
  );
  // ONE full scan for all 10 terms (was 10 scans): COUNT(*) under a WHERE
  // condition equals SUM(CASE WHEN condition) over the same rows, and OR is
  // commutative, so per-term counts are identical to the old loop. NULL text
  // matches nothing in both forms.
  const terms = ["SyntaxError", "Unexpected token", "EADDRINUSE", "FAIL:", "ReferenceError", "Traceback",
    "sed ", "2>/dev/null", "echo ", "rm -rf"];
  const sums = terms.map((_, i) => "SUM(CASE WHEN t LIKE ? OR c LIKE ? THEN 1 ELSE 0 END) AS n" + i).join(", ");
  const likeArgs = [];
  for (const t of terms) likeArgs.push("%" + t + "%", "%" + t + "%");
  const counts = queryDb(dbPath,
    "SELECT " + sums + " FROM (SELECT json_extract(data,'$.text') t, json_extract(data,'$.state.input.command') c FROM part)",
    ...likeArgs
  )[0];
  const signatures = {};
  terms.slice(0, 6).forEach((s, i) => { signatures[s] = counts["n" + i]; });
  const ruleMentions = {};
  terms.slice(6).forEach((r, i) => { ruleMentions[r] = counts["n" + (6 + i)]; });
  const patches = queryDb(dbPath,
    "SELECT json_extract(data,'$.files') files, COUNT(*) n FROM part WHERE json_extract(data,'$.type')='patch' GROUP BY files ORDER BY n DESC LIMIT 20"
  );
  return { errorCount: errors.length, errors, signatures, ruleMentions, patches };
}

export function apiPatternsFresh(dbPath, limit) {
  // Recent-40 session window (same as health/ledger/activity): the full-log
  // window function + two full scans cost ~5s sync on the single-threaded
  // loop per TTL expiry. SQLite window functions:
  // https://www.sqlite.org/windowfunctions.html (lead() partitions tool
  // calls per session in one pass instead of N correlated subqueries). Values are now recent-windowed like every other
  // panel (shape unchanged; counts reflect current behavior, not history).
  const recent = 40;
  const win = "session_id IN (SELECT id FROM session ORDER BY time_created DESC LIMIT ?)";
  const ngrams = queryDb(dbPath,
    "SELECT tool || '->' || next_tool AS gram, tool AS \"from\", next_tool AS \"to\", COUNT(*) n, MAX(session_id) example_sid FROM (" +
    "SELECT session_id, json_extract(data,'$.tool') tool, time_created, " +
    "lead(json_extract(data,'$.tool')) OVER (PARTITION BY session_id ORDER BY time_created) next_tool " +
    "FROM part WHERE json_extract(data,'$.type')='tool' AND " + win + ") " +
    "WHERE next_tool IS NOT NULL GROUP BY tool, next_tool ORDER BY n DESC LIMIT ?", recent, limit);
  const errorTools = queryDb(dbPath,
    "SELECT json_extract(data,'$.tool') tool, COUNT(*) n, MAX(session_id) example_sid FROM part " +
    "WHERE json_extract(data,'$.type')='tool' AND json_extract(data,'$.state.status')='error' " +
    "AND " + win + " " +
    "GROUP BY tool ORDER BY n DESC LIMIT 10", recent);
  const d = queryDb(dbPath, "SELECT COUNT(DISTINCT json_extract(data,'$.tool')) n FROM part WHERE json_extract(data,'$.type')='tool' AND " + win, recent)[0];
  return { ngrams, errorTools, distinct: d ? d.n : 0 };
}

export function apiWordsFresh(dbPath, limit) {
  const rows = queryDb(dbPath,
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

// --- semantic (FTS5 / bm25 over parts + OCR) ----------------------------
// Building the in-memory index is a multi-second synchronous scan. It lives
// here (not in dashboard.mjs) so the identical body runs in query-worker.mjs,
// off the dashboard's single-threaded event loop; dashboard.mjs imports it
// only for the rare inline fallback when the worker is unavailable. The index
// is reused for minRebuildMs so a continuously-written DB does not rebuild on
// every search (bounded staleness instead of a per-query stall).
// Rebuild the in-memory index at most once per window. The build is a
// multi-second (measured ~19 s on a 19582-part DB) synchronous scan, so a
// short window would rebuild almost continuously under write load and starve
// the single query worker; 2 min bounds that while keeping search fresh enough.
export const FTS_MIN_REBUILD_MS = Number(process.env.FTS_MIN_REBUILD_MS || 120000);
let FTS = { db: null, at: 0, count: -1, sourceMax: -1, ocrMax: 0, mode: "" };

// On-disk FTS index (built by semantic-search.sh with an atomic swap) is the
// BASE. New parts since its watermark live in a small in-memory OVERLAY, so a
// request queries both (fast) and never pays a full scan or a 24k-row copy.
// The disk index is refreshed out-of-band (host/timer), never on this path.
const SEMANTIC_IDX = process.env.SEMANTIC_IDX || fileURLToPath(new URL("../data/search/opencode-index.db", import.meta.url));
const FTS_OVERLAY_REBUILD_MS = Number(process.env.FTS_OVERLAY_REBUILD_MS || 30000);
let DISK = { db: null, mtime: 0, sourceMax: 0 };
let OVL = { db: null, baseMax: -1, max: -1, at: 0 };

function diskBase(dbPath) {
  try {
    const st = statSync(SEMANTIC_IDX);
    if (DISK.db && DISK.mtime === st.mtimeMs) return DISK;
    if (DISK.db) { try { DISK.db.close(); } catch { /* reopen */ } }
    const db = new DatabaseSync(SEMANTIC_IDX, { readOnly: true });
    let m = 0;
    try { m = Number(db.prepare("SELECT m FROM meta").get().m) || 0; } catch { /* old meta(n) */ }
    if (!m) m = Number(queryDb(dbPath, "SELECT COALESCE(MAX(time_created),0) m FROM part")[0].m) || 0;
    DISK = { db, mtime: st.mtimeMs, sourceMax: m };
    return DISK;
  } catch {
    if (DISK.db) { try { DISK.db.close(); } catch { /* ignore */ } }
    DISK = { db: null, mtime: 0, sourceMax: 0 };
    return null;
  }
}

function overlayFts(dbPath, baseMax) {
  const pick = (since) => queryDb(dbPath,
    "SELECT id, session_id, time_created, json_extract(data,'$.type') type, " +
    "COALESCE(json_extract(data,'$.text'), json_extract(data,'$.state.input.command'), '') text " +
    "FROM part WHERE time_created > ? AND (json_extract(data,'$.text') IS NOT NULL OR json_extract(data,'$.state.input.command') IS NOT NULL)",
    since
  );
  if (!OVL.db || OVL.baseMax !== baseMax) {
    const db = new DatabaseSync(":memory:");
    db.exec("CREATE VIRTUAL TABLE parts_fts USING fts5(part_id UNINDEXED, session_id UNINDEXED, type UNINDEXED, text)");
    const rows = pick(baseMax);
    const ins = db.prepare("INSERT INTO parts_fts(part_id, session_id, type, text) VALUES (?,?,?,?)");
    db.exec("BEGIN");
    for (const r of rows) ins.run(r.id, r.session_id, r.type || "", String(r.text || ""));
    db.exec("COMMIT");
    const max = rows.reduce((a, r) => Math.max(a, Number(r.time_created) || 0), baseMax);
    OVL = { db, baseMax, max, at: Date.now() };
    return db;
  }
  if (Date.now() - OVL.at < FTS_OVERLAY_REBUILD_MS) return OVL.db;
  const rows = pick(OVL.max);
  if (rows.length) {
    const ins = OVL.db.prepare("INSERT INTO parts_fts(part_id, session_id, type, text) VALUES (?,?,?,?)");
    OVL.db.exec("BEGIN");
    for (const r of rows) ins.run(r.id, r.session_id, r.type || "", String(r.text || ""));
    OVL.db.exec("COMMIT");
    OVL.max = rows.reduce((a, r) => Math.max(a, Number(r.time_created) || 0), OVL.max);
  }
  OVL.at = Date.now();
  return OVL.db;
}

function sanitizeFts(q) {
  const words = String(q || "").toLowerCase().match(/[a-z0-9_]+/g) || [];
  return words.map((w) => '"' + w + '"').join(" ");
}

// Append-only store: count + max(time_created) is a cheap change watermark
// (no json_extract scan). A changed watermark means new parts, not a rebuild.
function ftsSource(dbPath) {
  return queryDb(dbPath, "SELECT COUNT(*) n, COALESCE(MAX(time_created),0) m FROM part")[0];
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

function ocrRowsSince(minId) {
  try {
    const db = new DatabaseSync(fileURLToPath(new URL("../data/observability/observability.db", import.meta.url)), { readOnly: true });
    const rows = db.prepare("SELECT id, ts, image, engine, lang, text FROM ocr_run WHERE id > ? ORDER BY id").all(Number(minId) || 0);
    db.close();
    return rows;
  } catch {
    return [];
  }
}

function ensureFts(dbPath, minRebuildMs) {
  const src = ftsSource(dbPath);
  const n = Number(src.n), m = Number(src.m);
  if (FTS.db && Date.now() - FTS.at < minRebuildMs) return FTS.db;
  if (FTS.db && FTS.sourceMax === m) { FTS.at = Date.now(); FTS.mode = "hit"; return FTS.db; }
  if (!FTS.db) {
    const db = new DatabaseSync(":memory:");
    db.exec("CREATE VIRTUAL TABLE parts_fts USING fts5(part_id UNINDEXED, session_id UNINDEXED, type UNINDEXED, text)");
    const rows = queryDb(dbPath,
      "SELECT id, session_id, json_extract(data,'$.type') type, " +
      "COALESCE(json_extract(data,'$.text'), json_extract(data,'$.state.input.command'), '') text " +
      "FROM part WHERE json_extract(data,'$.text') IS NOT NULL OR json_extract(data,'$.state.input.command') IS NOT NULL"
    );
    const ins = db.prepare("INSERT INTO parts_fts(part_id, session_id, type, text) VALUES (?,?,?,?)");
    db.exec("BEGIN");
    for (const r of rows) ins.run(r.id, r.session_id, r.type || "", String(r.text || ""));
    const ocr = ocrRows(2000);
    for (const o of ocr) ins.run("ocr" + o.id, "OCR", "ocr", String(o.text || ""));
    db.exec("COMMIT");
    const ocrMax = ocr.reduce((a, o) => Math.max(a, Number(o.id) || 0), 0);
    FTS = { db, at: Date.now(), count: n, sourceMax: m, ocrMax, mode: "full", source: "memory" };
    return db;
  }
  // New parts only: append by time-created watermark (the store is append-only;
  // an in-place update of an already-indexed part keeps its old text, which is
  // bounded staleness, not a full 28 s rebuild every 2 min).
  const db = FTS.db;
  const rows = queryDb(dbPath,
    "SELECT id, session_id, json_extract(data,'$.type') type, " +
    "COALESCE(json_extract(data,'$.text'), json_extract(data,'$.state.input.command'), '') text " +
    "FROM part WHERE time_created > ? AND (json_extract(data,'$.text') IS NOT NULL OR json_extract(data,'$.state.input.command') IS NOT NULL)",
    FTS.sourceMax
  );
  const ins = db.prepare("INSERT INTO parts_fts(part_id, session_id, type, text) VALUES (?,?,?,?)");
  db.exec("BEGIN");
  for (const r of rows) ins.run(r.id, r.session_id, r.type || "", String(r.text || ""));
  let ocrMax = FTS.ocrMax || 0;
  for (const o of ocrRowsSince(ocrMax)) {
    ins.run("ocr" + o.id, "OCR", "ocr", String(o.text || ""));
    ocrMax = Math.max(ocrMax, Number(o.id) || 0);
  }
  db.exec("COMMIT");
  FTS = { db, at: Date.now(), count: n, sourceMax: m, ocrMax, mode: "incremental", source: FTS.source || "memory" };
  return db;
}

export function apiSemanticFresh(dbPath, q, limit, minRebuildMs = FTS_MIN_REBUILD_MS) {
  const raw = String(q || "");
  const needle = sanitizeFts(raw);
  const sessions = queryDb(dbPath,
    "SELECT id, title, cost, tokens_input, time_created FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT ?",
    "%" + raw.replace(/[%_\\]/g, "") + "%", limit
  );
  if (!needle) return { q: raw, mode: "fts", indexed: FTS.count, sessions, results: [] };
  const ftsQuery = (handle) => handle.prepare(
    "SELECT part_id, session_id, type, snippet(parts_fts, 3, '[', ']', '...', 14) snip, bm25(parts_fts) score " +
    "FROM parts_fts WHERE parts_fts MATCH ? ORDER BY score LIMIT ?"
  ).all(needle, limit);
  let base = diskBase(dbPath);
  let rows = [], source = "memory";
  if (base) {
    try {
      rows = ftsQuery(base.db);
      rows = rows.concat(ftsQuery(overlayFts(dbPath, base.sourceMax)));
      rows.sort((a, b) => a.score - b.score);
      rows = rows.slice(0, limit);
      source = "disk";
      // OCR rows are not in the disk index; query the small table directly.
      const rawLower = raw.toLowerCase();
      const ocrHits = ocrRows(2000)
        .filter((o) => String(o.text || "").toLowerCase().includes(rawLower))
        .slice(0, limit)
        .map((o) => ({ part_id: "ocr" + o.id, session_id: "OCR", type: "ocr",
                       snip: String(o.text || "").slice(0, 200), score: 0 }));
      if (ocrHits.length) rows = rows.concat(ocrHits).sort((a, b) => a.score - b.score).slice(0, limit);
    } catch {
      base = null;
      rows = [];
    }
  }
  if (!base) {
    let db;
    try { db = ensureFts(dbPath, minRebuildMs); } catch (e) {
      return { q: needle, mode: "error", error: String((e && e.message) || e), sessions, results: [] };
    }
    try {
      rows = ftsQuery(db);
    } catch (e) {
      return { q: needle, mode: "error", error: String((e && e.message) || e), sessions, results: [] };
    }
    source = "memory";
  }
  const ids = [...new Set(rows.map((r) => r.session_id))];
  const titles = {};
  if (ids.length) {
    const ph = ids.map(() => "?").join(",");
    for (const t of queryDb(dbPath, "SELECT id, title FROM session WHERE id IN (" + ph + ")", ...ids)) titles[t.id] = t.title;
  }
  const ocrTitles = {};
  for (const o of ocrRows(2000)) ocrTitles[o.id] = o.image;
  return {
    q: needle, mode: "fts", indexed: base ? null : FTS.count,
    index_mode: base ? "disk+overlay" : FTS.mode, index_source: source, sessions,
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
