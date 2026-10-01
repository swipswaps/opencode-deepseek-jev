#!/usr/bin/env node
// query-lib.mjs — pure read-only aggregations shared by the dashboard server
// and query-worker.mjs. Single source of truth: dashboard.mjs wrappers call
// these (never duplicate the SQL), and the worker imports them directly so
// heavy scans run off the event loop without a second implementation to
// drift. Every function is (dbPath, ...) -> plain JSON; each opens its own
// read-only handle per call (node:sqlite handles cannot cross threads).
// Behavior changes here must keep test-dashboard.sh endpoint shapes green.
import { DatabaseSync } from "node:sqlite";

export function queryDb(dbPath, sql, ...args) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return db.prepare(sql).all(...args);
  } finally {
    db.close();
  }
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
    "SELECT tool || '->' || next_tool AS gram, tool AS \"from\", next_tool AS \"to\", COUNT(*) n FROM (" +
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
