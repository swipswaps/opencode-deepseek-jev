#!/usr/bin/env node
// quirks.mjs — correlate a symptom (e.g. a session-health finding) with KNOWN
// upstream issues, and fuzzily search the local corpora (chat DB, repo code,
// docs) for where that quirk already appears.
//
// WHY (epistemic order: model -> criticize -> design)
// ---------------------------------------------------
// session-health.mjs answers "is the agent stalled?" (state). This answers the
// next question: "is this a known upstream defect, and has it bitten us
// before?" — so a finding carries an explanation, not just an alarm. The map is
// VENDORED (scripts/known-issues.json): read offline, deterministic, and
// reviewed — never a runtime GitHub call (that would fail offline, rate-limit,
// and inject untrusted text).
//
// FUZZY, NOT EXACT
// ----------------
// A symptom is free text; the map's `match` are regexes and its `keywords` are
// tokens. We score both, and add token-level fuzzy so a typo ("blnak") still
// lands on "blank" (Levenshtein <= 1 for tokens of length >= 4). This is the
// "fuzzy found in the chat log(s), repo code and documentation" requirement:
//   - matchIssues()  : text -> issues            (pure, cheap; used by :5099)
//   - corpusHits()   : keywords -> DB + code + docs (IO; CLI only, because a
//     LIKE scan over the whole `part` table is not page-load cheap)
//
// No model calls, no network. Read-only over opencode.db.
//
// CLI: node --experimental-sqlite quirks.mjs --self-test
//      node --experimental-sqlite quirks.mjs --query "blank output"
//      node --experimental-sqlite quirks.mjs --report [db]

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

const HERE = new URL(".", import.meta.url);
const KNOWN_ISSUES = fileURLToPath(new URL("./known-issues.json", import.meta.url));
const REPO = fileURLToPath(new URL("..", import.meta.url));

export function loadIssues(path = KNOWN_ISSUES) {
  const j = JSON.parse(readFileSync(path, "utf8"));
  const issues = Array.isArray(j) ? j : j.issues;
  for (const it of issues) it.re = (it.match || []).map((p) => new RegExp(p, "i"));
  return issues;
}

// --- fuzzy text primitives -------------------------------------------------
function tokens(s) {
  return String(s || "").toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 1);
}
function jaccard(a, b) {
  const A = new Set(a), B = new Set(b);
  let inter = 0;
  for (const x of B) if (A.has(x)) inter++;
  const un = A.size + B.size - inter;
  return un ? inter / un : 0;
}
export function levenshtein(a, b) {
  a = String(a); b = String(b);
  const m = a.length, n = b.length;
  if (!m) return n;
  if (!n) return m;
  let prev = Array.from({ length: n + 1 }, (_, i) => i);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[n];
}
function closeToken(t, list) {
  for (const x of list) if (x.length >= 4 && t.length >= 4 && levenshtein(t, x) <= 1) return true;
  return false;
}
// Token-level typo similarity in [0,1]: 1 if any symptom token is within
// edit distance 1 of a keyword token. Independent of Jaccard so a shared
// stopword ("no") cannot mask a real near-match.
function typoSim(toks, kw) {
  let best = 0;
  for (const t of toks) {
    for (const x of kw) {
      if (t.length < 4 || x.length < 4) continue;
      const d = levenshtein(t, x);
      if (d === 1) best = Math.max(best, 1);
      else if (d === 2 && t.length >= 6) best = Math.max(best, 0.5);
    }
  }
  return best;
}

// text -> scored issues. score = regex hits (strong) + token Jaccard + typo.
export function matchIssues(text, issues = loadIssues(), threshold = 0.15) {
  const toks = tokens(text);
  const scored = [];
  for (const it of issues) {
    let reHits = 0;
    for (const re of it.re) if (re.test(text)) reHits++;
    const kw = tokens((it.keywords || []).join(" "));
    const jac = jaccard(toks, kw);
    const typo = typoSim(toks, kw);
    const score = reHits * 1.0 + jac + 0.3 * typo;
    if (score >= threshold) scored.push({ id: it.id, title: it.title, url: it.url, severity: it.severity, score: Number(score.toFixed(2)), reHits });
  }
  return scored.sort((a, b) => b.score - a.score);
}

// The synthetic symptom text a health finding implies.
function symptomText(f) {
  if (f.kind === "running_tool") return `a tool (${f.tool || "?"}) stuck running; shell not returning; agent stall`;
  return "blank output; no text part after the last tool; no answer printed";
}

// CHEAP annotation for the dashboard: attach matched issues + per-model counts.
// Pure (a few regexes); safe on every /api/health page load.
export function annotateReport(report, issues = loadIssues()) {
  const findings = report.findings || [];
  const correlated = findings.map((f) => ({ kind: f.kind, session: f.session, model: f.model || null, issues: matchIssues(symptomText(f), issues).slice(0, 3) }));
  const seen = {};
  for (const c of correlated) for (const m of c.issues) seen[m.id] = seen[m.id] || { ...m, n: 0 };
  for (const c of correlated) for (const m of c.issues) seen[m.id].n++;
  const known_issues = Object.values(seen).sort((a, b) => b.n - a.n);
  const by_model = {};
  for (const f of findings) {
    const m = f.model || "(unattributed)";
    by_model[m] = (by_model[m] || 0) + 1;
  }
  return { correlated, known_issues, by_model };
}

// PER-MODEL QUIRK LEDGER (P4): join each model to its tool-error rate and its
// blacklist-construct usage, so "which model keeps emitting sed/2>/dev/null or
// fails most" is a measured property, not a hunch. Bounded to the most recent
// sessions so it stays cheap enough for a page load. Read-only.
export function modelLedger(dbPath, opts = {}) {
  const recent = opts.recentSessions ?? 40;
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const rows = db
    .prepare(
      `SELECT
         CASE WHEN s.model IS NULL THEN '(unattributed)'
              ELSE COALESCE(json_extract(s.model,'$.id'), json_extract(s.model,'$'), s.model) END AS model,
         COUNT(DISTINCT s.id) AS sessions,
         SUM(CASE WHEN json_extract(p.data,'$.type')='tool' THEN 1 ELSE 0 END) AS tool_parts,
         SUM(CASE WHEN json_extract(p.data,'$.type')='tool'
                   AND json_extract(p.data,'$.state.status')='error' THEN 1 ELSE 0 END) AS errors,
         SUM(CASE WHEN json_extract(p.data,'$.state.input.command') LIKE '% sed %'
                    OR json_extract(p.data,'$.state.input.command') LIKE '%|sed %'
                    THEN 1 ELSE 0 END) AS used_sed,
         SUM(CASE WHEN json_extract(p.data,'$.state.input.command') LIKE '%/dev/null%'
                    THEN 1 ELSE 0 END) AS used_devnull,
         SUM(CASE WHEN json_extract(p.data,'$.state.input.command') LIKE '%subprocess.run%'
                    THEN 1 ELSE 0 END) AS used_subprocess
       FROM part p JOIN session s ON s.id = p.session_id
      WHERE p.session_id IN (SELECT id FROM session ORDER BY time_created DESC LIMIT ?)
      GROUP BY 1
      ORDER BY tool_parts DESC`,
    )
    .all(recent);
  for (const r of rows) {
    r.error_rate = r.tool_parts ? Number((r.errors / r.tool_parts).toFixed(3)) : 0;
    r.quirk_hits = (r.used_sed || 0) + (r.used_devnull || 0) + (r.used_subprocess || 0);
  }
  return rows;
}

// --- corpus scan (CLI): where does this quirk already appear? --------------
function countIn(text, kw) {
  let n = 0, i = 0;
  const hay = text.toLowerCase(), needle = kw.toLowerCase();
  while ((i = hay.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
  return n;
}
function docHits(keywords, docs) {
  const out = {};
  for (const p of docs) {
    try {
      const text = readFileSync(p, "utf8");
      let n = 0;
      for (const k of keywords) n += countIn(text, k);
      if (n) out[p.replace(REPO, "")] = n;
    } catch { /* absent doc */ }
  }
  return out;
}
function codeHits(keywords, dir) {
  const out = {};
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => /\.(mjs|js|sh|py)$/.test(f));
  } catch { return out; }
  for (const f of files.slice(0, 300)) {
    try {
      const text = readFileSync(dir + "/" + f, "utf8");
      let n = 0;
      for (const k of keywords) n += countIn(text, k);
      if (n) out[f] = n;
    } catch { /* skip */ }
  }
  return out;
}
function dbHits(keywords, dbPath) {
  try {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const where = keywords.map(() => "data LIKE ?").join(" OR ");
    const args = keywords.map((k) => "%" + k + "%");
    const row = db.prepare(`SELECT COUNT(*) AS c FROM part WHERE ${where}`).get(...args);
    return row.c;
  } catch (e) {
    return -1;
  }
}
export function corpusHits(keywords, { dbPath, docs } = {}) {
  const docList = docs || ["HANDOFF.md", "README.txt", "RULES.md", "TODO.md", "scripts/README.txt"].map((p) => REPO + "/" + p);
  return { db_parts: dbHits(keywords, dbPath || REPO + "/data/opencode/opencode.db"), docs: docHits(keywords, docList), code: codeHits(keywords, REPO + "/scripts") };
}

// ---------------------------------------------------------------------------
// Self-test: offline, deterministic. Pure matcher + corpus counters on temp
// fixtures. No live DB, no network.
// ---------------------------------------------------------------------------
async function selfTest() {
  const { mkdtempSync, rmSync, writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "quirks-"));
  const doc = join(dir, "doc.txt");
  writeFileSync(doc, "the blank pane and the black screen and base64 image\nblank again\n");
  const dbfile = join(dir, "t.db");
  const db = new DatabaseSync(dbfile);
  db.exec("CREATE TABLE part(data TEXT)");
  db.prepare("INSERT INTO part(data) VALUES(?)").run('{"type":"text","text":"blank output"}');
  db.prepare("INSERT INTO part(data) VALUES(?)").run('{"type":"text","text":"ok"}');
  db.close();

  // Second fixture: sessions + parts for the per-model ledger.
  const mdb = join(dir, "m.db");
  const m = new DatabaseSync(mdb);
  m.exec("CREATE TABLE session(id TEXT, model TEXT, time_created INTEGER); CREATE TABLE part(session_id TEXT, data TEXT);");
  m.prepare("INSERT INTO session VALUES(?,?,?)").run("s1", '{"id":"deepseek-flash"}', 2000);
  m.prepare("INSERT INTO session VALUES(?,?,?)").run("s2", '{"id":"free-model"}', 1000);
  m.prepare("INSERT INTO part VALUES(?,?)").run("s1", JSON.stringify({ type: "tool", tool: "bash", state: { status: "error", input: { command: "ls /x 2>/dev/null" } } }));
  m.prepare("INSERT INTO part VALUES(?,?)").run("s1", JSON.stringify({ type: "tool", tool: "bash", state: { status: "completed", input: { command: "grep x f" } } }));
  m.prepare("INSERT INTO part VALUES(?,?)").run("s2", JSON.stringify({ type: "tool", tool: "read", state: { status: "completed", input: { filePath: "/x" } } }));
  m.close();

  const issues = loadIssues();
  const has = (arr, id) => arr.some((x) => x.id === id);
  const checks = [
    ["known-issues.json is a curated map (>=5, all fields)", issues.length >= 5 && issues.every((i) => i.id && i.title && i.url && i.match && i.keywords)],
    ["blank symptom -> #48623", has(matchIssues("blank output, no text part after the tool", issues), "anomalyco/opencode#48623")],
    ["image symptom -> #46419", has(matchIssues("huge base64 image attachment payload", issues), "anomalyco/opencode#46419")],
    ["typo 'blnak outpt' still -> #48623", has(matchIssues("blnak outpt no answr", issues), "anomalyco/opencode#48623")],
    ["decoy 'the cat sat on the mat' matches nothing high", matchIssues("the cat sat on the mat", issues).every((x) => x.score < 0.6)],
    ["docHits counts occurrences", (docHits(["blank", "black screen"], [doc]))[doc] === 3],
    ["dbHits counts matching rows", dbHits(["blank"], dbfile) === 1],
    ["modelLedger returns one row per model", modelLedger(mdb).length === 2],
    ["modelLedger: deepseek-flash error=1, devnull=1, quirk_hits>=1", (() => {
      const d = modelLedger(mdb).find((x) => x.model === "deepseek-flash");
      return !!d && d.errors === 1 && d.used_devnull === 1 && d.quirk_hits >= 1;
    })()],
    ["modelLedger: free-model has 0 errors + 0 quirk hits", (() => {
      const f = modelLedger(mdb).find((x) => x.model === "free-model");
      return !!f && f.errors === 0 && f.quirk_hits === 0;
    })()],
  ];
  rmSync(dir, { recursive: true, force: true });
  let fail = 0;
  console.log("=== quirks.mjs --self-test ===");
  for (const [name, ok] of checks) { if (!ok) fail++; console.log((ok ? "  PASS " : "  FAIL ") + name); }
  console.log("result: " + (fail ? "FAIL" : "PASS"));
  return fail ? 1 : 0;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--self-test")) return selfTest();
  const issues = loadIssues();
  if (argv.includes("--query")) {
    const q = argv[argv.indexOf("--query") + 1] || "";
    const matched = matchIssues(q, issues);
    const keywords = matched.length ? issues.find((i) => i.id === matched[0].id).keywords : tokens(q);
    const dbPath = argv.find((a) => a.endsWith(".db")) || REPO + "/data/opencode/opencode.db";
    console.log(JSON.stringify({ query: q, matched, corpus: corpusHits(keywords, { dbPath }) }, null, 2));
    return 0;
  }
  if (argv.includes("--report")) {
    const dbPath = argv.find((a) => a.endsWith(".db")) || REPO + "/data/opencode/opencode.db";
    const { healthReport } = await import("./session-health.mjs");
    const report = healthReport(dbPath);
    const annot = annotateReport(report, issues);
    const corpus = {};
    for (const it of annot.known_issues.slice(0, 3)) corpus[it.id] = corpusHits(it.keywords, { dbPath });
    console.log(JSON.stringify({ counts: report.counts, known_issues: annot.known_issues, by_model: annot.by_model, corpus }, null, 2));
    return 0;
  }
  console.log("usage: quirks.mjs --self-test | --query TEXT | --report [db]");
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(await main());
}
