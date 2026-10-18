#!/usr/bin/env node
// session-health.mjs — READ-ONLY, browser-independent detection of stalled and
// blank assistant turns in opencode's session store.
//
// Query substrate: SQLite JSON1 (json_extract over the part.data JSON blob:
// https://www.sqlite.org/json1.html) plus GROUP BY aggregation. All scans
// are bounded to recent sessions — the part log grows without bound while
// recent sessions hold nearly all of it.
//
// WHY (the "screen-blindness" problem)
// ------------------------------------
// The opencode server is the single writer of `opencode.db`; every tool call,
// reasoning block and text part is a `part` row. The web client at :4096 is a
// projection of that store over Server-Sent Events (`GET /event`), so when the
// view freezes ("Shell stuck", "black page", "did not print until refresh") the
// STORE is still complete. This tool reads the store, so it sees the truth even
// when the browser does not. (opencode.ai/docs/server -> Events.)
//
// TWO LOW-FALSE-POSITIVE SIGNALS (a third was FALSIFIED)
// ------------------------------------------------------
//  S0 running_tool : a tool part still `state.status="running"` long after it
//                    started — the sharpest agent-stall fingerprint. Excludes
//                    interactive tools (a pending `question` blocks on the
//                    OPERATOR by design: the 2026-10-17 stall flags were all
//                    `question`, age ~2h — a false positive).
//  S1 blank_tail   : a recent session whose LAST part is a tool and no `text`
//                    part followed within the deadline — the "no answer printed"
//                    fingerprint. Sessions already flagged by S0 are excluded.
//  S2 long_gap     : a large inter-part silence. We deliberately DO NOT emit it:
//                    measured on this repo, 20/20 such gaps were overnight
//                    user-idle (≈100% false positives). It is available behind
//                    `--include-gaps` for analysis only, never as a finding.
//                    (Cry-wolf failure: Observability Engineering, ISBN
//                    9781492076445; change-point theory: NIST pmc323 / Page 1954.)
//
// CONTRACT
//   export healthReport(dbPath, opts) -> { ts, counts, findings, ... }
//   export handoffAdvice(dbPath, opts) -> { level ok|warn|over, action }
//   export modelDenied(model, deny?) -> bool (deny-listed gateway free tier)
//   export budgetRisks(dbPath, opts) -> { budget, scanned, over[], warn[], denied[] }
//   CLI:  node --experimental-sqlite session-health.mjs [db] [--json]
//         [--include-gaps] [--self-test] [--live]
//   Read-only. No model calls. No network unless --live (then only :4096).
//
// COST NOTE: this file never spends. It is the diagnostic half of the
// session-health work; the cost/handoff watchers (preflight.sh, harness.sh,
// cost-bottlenecks.sh) are untouched and still authoritative before any spend.

import { DatabaseSync } from "node:sqlite"; // Node >= 22 built-in; no npm dep
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const POLICY_PATH = fileURLToPath(new URL("../models.policy.json", import.meta.url));
function loadDeny() {
  try {
    const p = JSON.parse(readFileSync(POLICY_PATH, "utf8"));
    return Array.isArray(p.deny) ? p.deny : [];
  } catch {
    return [];
  }
}

// MODEL-DENIED — is this a deny-listed gateway-metered free tier? Exact deny
// match on the full or short id, plus the opencode/*-free shape the policy
// $comment names. Such a model answers AI_APICallError "backend temporarily
// unavailable" instead of text, so flag it even when the session is small.
export function modelDenied(model, deny = loadDeny()) {
  const raw = typeof model === "string" ? model : JSON.stringify(model);
  const id = modelId(raw);
  const short = String(id).split("/").pop();
  if (deny.includes(id) || deny.includes(short)) return true;
  return /^opencode\/.*-free$/.test(String(id));
}

// BUDGET RISKS — handoffAdvice() sees only the LATEST session, so an old
// bloated session kept alive by retries stays invisible. This scans the
// recent window for EVERY over/warn session plus every session on a
// deny-listed model, each carrying its own guidance. One grouped pass so it
// stays cheap enough for /api/health. Read-only.
export function budgetRisks(dbPath, opts = {}) {
  const budget = Number(opts.budgetTokens ?? process.env.CONTEXT_BUDGET ?? 200000);
  const recent = opts.recentSessions ?? 40;
  const deny = opts.deny ?? loadDeny();
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const rows = db
    .prepare(
      `SELECT s.id, s.title, s.model, COALESCE(s.tokens_input,0) AS in_tok,
              COALESCE(s.cost,0) AS cost, s.time_updated,
              (SELECT COUNT(*) FROM part p WHERE p.session_id = s.id) AS parts
         FROM session s ORDER BY s.time_created DESC LIMIT ?`,
    )
    .all(recent);
  const over = [], warn = [], denied = [];
  for (const r of rows) {
    const ratio = budget > 0 ? r.in_tok / budget : 0;
    const lvl = r.in_tok > budget ? "over" : ratio >= 0.8 ? "warn" : "ok";
    const mid = modelId(r.model);
    // The session model JSON carries providerID apart from id; the policy
    // deny list names provider/id pairs, so rejoin before the verdict.
    let prov = "";
    try {
      const o = JSON.parse(r.model);
      prov = (o && typeof o === "object" && o.providerID) || "";
    } catch {
      prov = "";
    }
    const full = prov ? prov + "/" + mid : mid;
    const isDenied = modelDenied(full, deny);
    const item = {
      session: r.id, title: r.title, model: mid, model_denied: isDenied,
      in_tok: r.in_tok, ratio: Number(ratio.toFixed(2)), level: lvl,
      cost: r.cost, parts: r.parts, updated_at: iso(r.time_updated),
    };
    if (lvl === "over") {
      item.guidance =
        "stop prompting " + r.id + ": every turn re-sends " + r.in_tok +
        " tokens; open a fresh session and carry a brief (./scripts/handoff-brief.sh " +
        r.id + "), never --fork/--continue";
      over.push(item);
    } else if (lvl === "warn") {
      warn.push(item);
    }
    if (isDenied) {
      item.guidance =
        (item.guidance ? item.guidance + " " : "") +
        "model " + mid + " is deny-listed (gateway-metered free tier): " +
        "switch to opencode-go/* or direct deepseek/flash";
      denied.push(item);
    }
  }
  return { available: true, budget, scanned: rows.length, over, warn, denied };
}

export const DEFAULTS = {
  runMs: 120_000, // a tool "running" longer than this is a stall
  recentSessions: 40, // only the most recent N sessions are online-interesting
};

// Tools that legitimately stay `state.status="running"` while awaiting OPERATOR
// input: a pending prompt is not a stalled agent. The 2026-10-17 [HIGH] stall
// flags were all `question` tools (age ~2h) — a false positive. Excluded from S0.
export const INTERACTIVE_TOOLS = ["question"];

// The session row stores `model` as a JSON string; it may be an object
// ({"id":"deepseek-flash",...}) or a bare JSON string ("deepseek-flash").
function modelId(m) {
  try {
    const o = JSON.parse(m);
    return typeof o === "string" ? o : (o && (o.id || o.modelID)) || m || "(none)";
  } catch {
    return m || "(none)";
  }
}
function iso(ms) {
  return ms ? new Date(ms).toISOString() : null;
}

export function healthReport(dbPath, opts = {}) {
  const now = opts.now ?? Date.now(); // injectable for deterministic tests
  const runMs = opts.runMs ?? DEFAULTS.runMs;
  const recent = opts.recentSessions ?? DEFAULTS.recentSessions;
  const db = new DatabaseSync(dbPath, { readOnly: true });

  // S0 — tools stuck in `running` (join session for per-model attribution).
  // Interactive tools (a pending `question`) are excluded: they block on the
  // OPERATOR, not on the server, so they are not a stall.
  const excl = INTERACTIVE_TOOLS.map((t) => `'${t}'`).join(",");
  const running = db
    .prepare(
      `SELECT p.session_id                           AS session_id,
              p.time_created                          AS time_created,
              json_extract(p.data,'$.tool')           AS tool,
              json_extract(p.data,'$.state.input.command') AS cmd,
              s.model                                 AS model
         FROM part p LEFT JOIN session s ON s.id = p.session_id
        WHERE json_extract(p.data,'$.type') = 'tool'
          AND json_extract(p.data,'$.state.status') = 'running'
          AND json_extract(p.data,'$.tool') NOT IN (${excl})
          AND p.time_created < ?
          AND p.session_id IN (SELECT id FROM session ORDER BY time_created DESC LIMIT ?)
        ORDER BY p.time_created DESC
        LIMIT 20`,
    )
    .all(now - runMs, recent);

  // S1 — blank tails among recent sessions. The extra `< now - runMs` bound
  // removes the transient "a tool is legitimately in progress right now" case
  // that would otherwise look blank on every active session.
  // Single grouped pass (was 2 correlated full-table scans per session):
  // MAX over the same per-session sets, so results are identical. The part
  // table grows without bound while recent sessions hold most of it; 80
  // correlated scans turned this into the dashboard's slowest sync query
  // (~5 s, blocking the single-threaded server on every /api/health miss).
  const blank = db
    .prepare(
      `SELECT s.id    AS id,
              s.title AS title,
              s.model AS model,
              MAX(CASE WHEN json_extract(p.data,'$.type') = 'text'
                       THEN p.time_created END) AS last_text,
              MAX(CASE WHEN json_extract(p.data,'$.type') = 'tool'
                        AND json_extract(p.data,'$.tool') NOT IN (${excl})
                       THEN p.time_created END) AS last_tool
         FROM session s LEFT JOIN part p ON p.session_id = s.id
        WHERE s.id IN (SELECT id FROM session
                        ORDER BY time_created DESC LIMIT ?)
        GROUP BY s.id
       HAVING last_tool IS NOT NULL
          AND last_tool < ?
          AND (last_text IS NULL OR last_text < last_tool)`,
    )
    .all(recent, now - runMs);

  const scanned = db
    .prepare(
      `SELECT COUNT(*) AS c FROM (
         SELECT id FROM session ORDER BY time_created DESC LIMIT ?)`,
    )
    .get(recent).c;

  // Exclude a session already reported by S0 from S1 (avoid double-counting a
  // single incident as two findings).
  const stallSessions = new Set(running.map((r) => r.session_id));

  const findings = [];
  for (const r of running) {
    findings.push({
      kind: "running_tool",
      session: r.session_id,
      model: modelId(r.model),
      tool: r.tool || "?",
      started_at: iso(r.time_created),
      age_s: Math.round((now - r.time_created) / 1000),
      command: String(r.cmd || "").slice(0, 90),
    });
  }
  for (const r of blank) {
    if (stallSessions.has(r.id)) continue;
    findings.push({
      kind: "blank_tail",
      session: r.id,
      model: modelId(r.model),
      last_tool_at: iso(r.last_tool),
      last_text_at: iso(r.last_text),
      age_s: Math.round((now - r.last_tool) / 1000),
    });
  }

  const report = {
    ts: new Date(now).toISOString(),
    db: dbPath,
    method: "db-readonly",
    thresholds: { run_ms: runMs, recent_sessions: recent },
    counts: {
      sessions_scanned: scanned,
      running_tools: running.length,
      blank_tails: findings.filter((f) => f.kind === "blank_tail").length,
      findings: findings.length,
    },
    findings,
  };

  // S2 (analysis only; never a finding) — kept behind a flag with the why.
  if (opts.includeGaps) {
    report.gaps = db
      .prepare(
        `SELECT session_id, time_created, gaptime, type, tool, status FROM (
           SELECT session_id, time_created,
                  json_extract(data,'$.type')         AS type,
                  json_extract(data,'$.tool')         AS tool,
                  json_extract(data,'$.state.status') AS status,
                  time_created - lag(time_created) OVER (
                    PARTITION BY session_id ORDER BY time_created) AS gaptime
             FROM part
            WHERE session_id IN (SELECT id FROM session
                                  ORDER BY time_created DESC LIMIT ?)
         )
         WHERE gaptime IS NOT NULL AND gaptime > ?
         ORDER BY gaptime DESC LIMIT 10`,
      )
      .all(recent, 5 * 60_000)
      .map((r) => ({
        session: r.session_id,
        gap_s: Math.round(r.gaptime / 1000),
        preceded_by: r.type === "tool" ? `${r.tool}[${r.status}]` : r.type,
        NOTE: "user-idle vs stall is indistinguishable offline; not a finding",
      }));
  }

  return report;
}

// HANDOFF ADVISOR — mirror cost-bottlenecks.sh's "context budget (latest
// session)" (CONTEXT_BUDGET, default 200k input tokens) so the operator is
// told *in the UI* when a fresh session would protect cost and quality. The
// number already existed; this surfaces it. Read-only.
export function handoffAdvice(dbPath, opts = {}) {
  const budget = Number(opts.budgetTokens ?? process.env.CONTEXT_BUDGET ?? 200000);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const s = db
    .prepare(
      "SELECT id, title, tokens_input, tokens_output, tokens_reasoning, time_created " +
        "FROM session ORDER BY time_created DESC LIMIT 1",
    )
    .get();
  if (!s) return { available: false };
  const inTok = Number(s.tokens_input) || 0;
  const ratio = budget > 0 ? inTok / budget : 0;
  const level = inTok > budget ? "over" : ratio >= 0.8 ? "warn" : "ok";
  return {
    available: true,
    session: s.id,
    title: s.title,
    in_tok: inTok,
    budget,
    ratio: Number(ratio.toFixed(2)),
    level,
    action:
      level === "over"
        ? "start a fresh session (read HANDOFF first)"
        : level === "warn"
          ? "plan to hand off soon"
          : "within budget",
  };
}

// LIVE enrichment: ask the server which sessions are busy. This is the one
// place the detector may touch the network, and only :4096 with basic auth.
// Offline callers (the gate) never hit this; `--live` is explicit.
function loadServerPassword() {
  try {
    const envPath = fileURLToPath(new URL("../.env.local", import.meta.url));
    for (const line of readFileSync(envPath, "utf8").split("\n")) {
      if (line.startsWith("OPENCODE_SERVER_PASSWORD=")) {
        return line.slice("OPENCODE_SERVER_PASSWORD=".length).trim();
      }
    }
  } catch {
    // no .env.local / unreadable — live mode simply stays unavailable
  }
  return "";
}

export async function liveStatus(opts = {}) {
  const base = opts.serverUrl || "http://127.0.0.1:4096";
  const pass = opts.password || loadServerPassword();
  if (!pass) return { available: false, reason: "no OPENCODE_SERVER_PASSWORD" };
  try {
    const res = await fetch(base + "/session/status", {
      headers: {
        Authorization: "Basic " + Buffer.from("opencode:" + pass).toString("base64"),
      },
      signal: AbortSignal.timeout(opts.timeoutMs ?? 6000),
    });
    if (!res.ok) return { available: false, reason: "http " + res.status };
    return { available: true, statuses: await res.json() };
  } catch (e) {
    return { available: false, reason: String(e && e.message ? e.message : e) };
  }
}

// ---------------------------------------------------------------------------
// Self-test: build a synthetic DB with four fixtures and assert the detector
// returns EXACTLY the expected findings. Offline, deterministic, no network.
// ---------------------------------------------------------------------------
async function selfTest() {
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "sess-health-"));
  const dbFile = join(dir, "fixture.db");

  const db = new DatabaseSync(dbFile); // writable synthetic store
  db.exec(
    "CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, model TEXT, time_created INTEGER);" +
      "CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);",
  );
  const NOW = 2_000_000_000_000; // fixed clock -> deterministic
  const insS = db.prepare("INSERT INTO session(id,title,model,time_created) VALUES(?,?,?,?)");
  const insP = db.prepare("INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)");
  const tool = (tool, status, cmd) =>
    JSON.stringify({ type: "tool", tool, state: { status, input: { command: cmd } } });
  const text = (t) => JSON.stringify({ type: "text", text: t });

  insS.run("s_stall", "stall", '{"id":"deepseek-flash"}', NOW - 9_000_000);
  insP.run("p1", "m", "s_stall", NOW - 600_000, NOW - 600_000, tool("bash", "running", "sleep 999"));

  insS.run("s_blank", "blank", '{"id":"deepseek-flash"}', NOW - 9_000_000);
  insP.run("p2", "m", "s_blank", NOW - 700_000, NOW - 700_000, JSON.stringify({ type: "reasoning", text: "..." }));
  insP.run("p3", "m", "s_blank", NOW - 500_000, NOW - 500_000, tool("bash", "completed", "ls"));

  insS.run("s_ok", "ok", '{"id":"deepseek-flash"}', NOW - 9_000_000);
  insP.run("p4", "m", "s_ok", NOW - 600_000, NOW - 600_000, tool("bash", "completed", "ls"));
  insP.run("p5", "m", "s_ok", NOW - 500_000, NOW - 500_000, text("done"));

  insS.run("s_idle", "idle", '{"id":"deepseek-flash"}', NOW - 9_000_000);
  insP.run("p6", "m", "s_idle", NOW - 7_200_000, NOW - 7_200_000, text("bye"));
  insP.run("p7", "m", "s_idle", NOW - 3_600_000, NOW - 3_600_000, text("back"));

  // A pending interactive `question` also sits in `running` for hours, but it
  // blocks on the OPERATOR, not the server — it must NOT be a stall (S0).
  insS.run("s_q", "asking", '{"id":"deepseek-flash"}', NOW - 9_000_000);
  insP.run("p8", "m", "s_q", NOW - 7_200_000, NOW - 7_200_000,
    JSON.stringify({ type: "tool", tool: "question", state: { status: "running", input: {} } }));
  db.close();

  const r = healthReport(dbFile, { now: NOW });
  const kinds = r.findings.map((f) => f.kind).sort().join(",");
  const checks = [
    ["one running_tool finding", r.counts.running_tools === 1],
    ["one blank_tail finding", r.counts.blank_tails === 1],
    ["exactly two findings", r.findings.length === 2],
    ["kinds are blank_tail + running_tool", kinds === "blank_tail,running_tool"],
    ["idle session is NOT flagged", !r.findings.some((f) => f.session === "s_idle")],
    ["healthy session is NOT flagged", !r.findings.some((f) => f.session === "s_ok")],
    ["pending question is NOT a stall", !r.findings.some((f) => f.session === "s_q")],
    ["long gap is not a finding by default", !("gaps" in r)],
  ];
  rmSync(dir, { recursive: true, force: true });

  // --live path: stand up a stub /session/status and prove liveStatus() parses
  // it. Offline (loopback only), so the gate never needs the real server.
  const { createServer } = await import("node:http");
  const srv = createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end('{"ses_1":{"type":"busy"},"ses_2":{"type":"idle"}}');
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const port = srv.address().port;
  const live = await liveStatus({ serverUrl: "http://127.0.0.1:" + port, password: "stub" });
  srv.close();
  checks.push(["liveStatus parses /session/status", live.available === true && !!live.statuses && live.statuses.ses_1 && live.statuses.ses_1.type === "busy"]);

  // handoff advisor: latest session input vs budget -> over / warn / ok.
  // Separate fixture (token columns), same fixed clock domain idea.
  const hoDir = mkdtempSync(join(tmpdir(), "sess-ho-"));
  const hoFile = join(hoDir, "ho.db");
  const hoDb = new DatabaseSync(hoFile);
  hoDb.exec(
    "CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, time_created INTEGER);",
  );
  const hoIns = hoDb.prepare("INSERT INTO session VALUES(?,?,?,?,?,?)");
  hoIns.run("s_over", "over", 1200, 0, 0, NOW);
  hoDb.close();
  const hoOver = handoffAdvice(hoFile, { budgetTokens: 1000 });
  const hoDb2 = new DatabaseSync(hoFile, { readOnly: false });
  hoDb2.exec("UPDATE session SET tokens_input=850 WHERE id='s_over'");
  hoDb2.close();
  const hoWarn = handoffAdvice(hoFile, { budgetTokens: 1000 });
  const hoDb3 = new DatabaseSync(hoFile, { readOnly: false });
  hoDb3.exec("UPDATE session SET tokens_input=100 WHERE id='s_over'");
  hoDb3.close();
  const hoOk = handoffAdvice(hoFile, { budgetTokens: 1000 });
  rmSync(hoDir, { recursive: true, force: true });
  checks.push(["handoff over budget", hoOver.level === "over" && hoOver.ratio === 1.2]);
  checks.push(["handoff warn band", hoWarn.level === "warn"]);
  checks.push(["handoff within budget", hoOk.level === "ok" && hoOk.ratio === 0.1]);
  checks.push(["handoff over action names a fresh session", typeof hoOver.action === "string" && hoOver.action.includes("fresh session")]);

  // budgetRisks: old bloated sessions must surface, not just the latest; a
  // deny-listed free-tier model must flag even when the session is small.
  const rkDir = mkdtempSync(join(tmpdir(), "sess-rk-"));
  const rkFile = join(rkDir, "rk.db");
  const rkDb = new DatabaseSync(rkFile);
  rkDb.exec(
    "CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, model TEXT, tokens_input INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER);" +
      "CREATE TABLE part(id TEXT, session_id TEXT);",
  );
  const rkIns = rkDb.prepare("INSERT INTO session VALUES(?,?,?,?,?,?,?)");
  rkIns.run("s_risk", "risk", '{"id":"opencode/muse-spark-1.3-contributor-free"}', 5000, 0, NOW - 9000, NOW - 1000);
  rkIns.run("s_warned", "warned", '{"id":"deepseek-flash"}', 850, 0.01, NOW - 8000, NOW - 2000);
  rkIns.run("s_fine", "fine", '{"id":"deepseek-flash"}', 100, 0, NOW - 7000, NOW - 3000);
  rkDb.prepare("INSERT INTO part VALUES(?,?)").run("p1", "s_risk");
  rkDb.close();
  const rk = budgetRisks(rkFile, { budgetTokens: 1000, deny: ["opencode/muse-spark-1.3-contributor-free"] });
  rmSync(rkDir, { recursive: true, force: true });
  checks.push(["risks: old over-budget session surfaces", rk.over.length === 1 && rk.over[0].session === "s_risk"]);
  checks.push(["risks: over guidance names fresh session + no fork", typeof rk.over[0].guidance === "string" && rk.over[0].guidance.includes("fresh session") && rk.over[0].guidance.includes("--fork")]);
  checks.push(["risks: warn band listed separately", rk.warn.length === 1 && rk.warn[0].session === "s_warned"]);
  checks.push(["risks: deny-listed free tier flagged with guidance", rk.denied.length === 1 && rk.denied[0].model_denied === true && rk.denied[0].guidance.includes("deny-listed")]);
  checks.push(["risks: healthy session in neither list", !rk.over.concat(rk.warn, rk.denied).some((x) => x.session === "s_fine")]);
  checks.push(["modelDenied matches deny list + free shape", modelDenied('{"id":"opencode/muse-spark-1.3-contributor-free"}', ["opencode/muse-spark-1.3-contributor-free"]) === true && modelDenied('{"id":"deepseek-flash"}', ["opencode/muse-spark-1.3-contributor-free"]) === false]);

  // dead-tool adjudication: same old running tool under three live states.
  // No network — live payloads are passed directly (fail-safe default needs
  // no server at all).
  const deadReport = () => ({
    counts: { running_tools: 1 },
    findings: [{ kind: "running_tool", session: "s_old", tool: "bash", age_s: 439103, command: "sleep 999" }],
  });
  const dIdle = applyLiveAdjudication(deadReport(), { available: true, statuses: { s_old: { type: "idle" } } });
  checks.push(["dead: old running + idle server -> dead_tool, out of running_tools",
    dIdle.findings[0].kind === "dead_tool" && dIdle.counts.running_tools === 0 && dIdle.counts.dead_tools === 1]);
  const dBusy = applyLiveAdjudication(deadReport(), { available: true, statuses: { s_old: { type: "busy" } } });
  checks.push(["dead: old running + busy server -> stays stall",
    dBusy.findings[0].kind === "running_tool" && dBusy.counts.running_tools === 1]);
  const dOff = applyLiveAdjudication(deadReport(), { available: false, reason: "http 000" });
  checks.push(["dead: no live data -> stays stall (fail-safe)",
    dOff.findings[0].kind === "running_tool"]);

  // Same adjudication for blank tails (a stale blank whose session is idle is
  // an archival tombstone, not a live "no answer").
  const blankReport = () => ({
    counts: { blank_tails: 1 },
    findings: [{ kind: "blank_tail", session: "s_old", model: "x", age_s: 439103 }],
  });
  const bIdle = applyLiveAdjudication(blankReport(), { available: true, statuses: { s_old: { type: "idle" } } });
  checks.push(["dead: old blank + idle server -> dead_blank, out of blank_tails",
    bIdle.findings[0].kind === "dead_blank" && bIdle.counts.blank_tails === 0 && bIdle.counts.dead_blanks === 1]);
  const bBusy = applyLiveAdjudication(blankReport(), { available: true, statuses: { s_old: { type: "busy" } } });
  checks.push(["dead: old blank + busy server -> stays blank_tail",
    bBusy.findings[0].kind === "blank_tail" && bBusy.counts.blank_tails === 1]);
  const bOff = applyLiveAdjudication(blankReport(), { available: false });
  checks.push(["dead: no live data -> blank stays (fail-safe)",
    bOff.findings[0].kind === "blank_tail" && bOff.counts.blank_tails === 1]);

  // LOCUS (client-vs-agent): a RECENT running tool (below DEAD_AFTER_S) with an
  // idle server is still a live stall, but now names the side — the agent side
  // is not progressing ("idle"); a busy server says the agent side is active.
  // Offline assigns no locus (never guess the side).
  const recentReport = () => ({
    counts: { running_tools: 1 },
    findings: [{ kind: "running_tool", session: "s_new", tool: "bash", age_s: 300, command: "npm i" }],
  });
  const rIdle = applyLiveAdjudication(recentReport(), { available: true, statuses: { s_new: { type: "idle" } } });
  checks.push(["locus: recent idle running tool stays stall + locus idle",
    rIdle.findings[0].kind === "running_tool" && rIdle.findings[0].locus === "idle"]);
  const rBusy = applyLiveAdjudication(recentReport(), { available: true, statuses: { s_new: { type: "busy" } } });
  checks.push(["locus: busy server marks the finding locus agent",
    rBusy.findings[0].kind === "running_tool" && rBusy.findings[0].locus === "agent"]);
  checks.push(["locus: offline assigns no locus (never guess the side)",
    typeof applyLiveAdjudication(recentReport(), { available: false }).findings[0].locus === "undefined"]);

  let fail = 0;
  console.log("=== session-health.mjs --self-test ===");
  for (const [name, ok] of checks) {
    if (!ok) fail++;
    console.log((ok ? "  PASS " : "  FAIL ") + name);
  }
  console.log("result: " + (fail ? "FAIL" : "PASS"));
  return fail ? 1 : 0;
}

// CLIENT-VS-AGENT LOCUS — the store proves the AGENT side; /session/status says
// whether the session is actively BUSY. Each finding gets a `locus`:
//   "agent" — the server reports the session busy: the agent side is working
//             (a long tool run may be legitimate, not a wedge);
//   "idle"  — the server reports idle/absent while the store claims a tool is
//             still running or a turn went blank: the agent side is NOT
//             progressing. A client-side freeze is invisible from the store
//             (which is exactly why this tool reads the store, not the view),
//             so "idle" is the honest, offline-safe locus. Without live data
//             no locus is assigned (fail-safe: never guess the side).
//
// DEAD-TOOL ADJUDICATION — reclassify `running_tool` findings the server has
// demonstrably outlived: older than DEAD_AFTER_S *and* the session idle/absent
// in live /session/status. Without live data the verdict stays `stall`
// (fail-safe: never auto-exonerate offline). Mutates the report only; the DB
// is never touched — cleanup happens at report time, not in storage.
export const DEAD_AFTER_S = 21600; // 6h: past any legitimate tool run
export function applyLiveAdjudication(report, live, opts = {}) {
  const deadAfterS = opts.deadAfterS ?? DEAD_AFTER_S;
  if (!live || live.available !== true || !live.statuses) return report;
  for (const f of report.findings || []) {
    const st = live.statuses[f.session];
    const busy = !!(st && st.type === "busy");
    f.locus = busy ? "agent" : "idle";
    if (!(f.age_s > deadAfterS)) continue;
    if (busy) continue;
    // A tool still `running` long past its stride, server idle/absent -> dead.
    if (f.kind === "running_tool") {
      f.kind = "dead_tool";
      f.verdict = "dead (server idle/absent)";
    } else if (f.kind === "blank_tail") {
      // A blank tail that is merely old and whose session is idle is the same
      // archival tombstone: not a live "no answer" event. Keep it visible but
      // out of the blank count so the panel does not desensitize.
      f.kind = "dead_blank";
      f.verdict = "dead (server idle/absent)";
    }
  }
  const kinds = (k) => (report.findings || []).filter((f) => f.kind === k).length;
  report.counts.running_tools = kinds("running_tool");
  report.counts.dead_tools = kinds("dead_tool");
  report.counts.blank_tails = kinds("blank_tail");
  report.counts.dead_blanks = kinds("dead_blank");
  return report;
}

// --- CLI ------------------------------------------------------------------
async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--self-test")) return selfTest();
  const dbPath =
    argv.find((a) => !a.startsWith("--")) || "/workspace/data/opencode/opencode.db";
  const report = healthReport(dbPath, { includeGaps: argv.includes("--include-gaps") });
  if (argv.includes("--live")) report.live = await liveStatus();
  if (argv.includes("--live")) applyLiveAdjudication(report, report.live);
  try {
    report.handoff = handoffAdvice(dbPath);
  } catch {
    report.handoff = { available: false };
  }
  try {
    report.risks = budgetRisks(dbPath);
  } catch {
    report.risks = { available: false };
  }
  if (argv.includes("--json")) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(
      `session-health: ${report.counts.sessions_scanned} scanned · ` +
        `${report.counts.running_tools} running · ${report.counts.blank_tails} blank`,
    );
    if (report.risks && report.risks.available) {
      console.log(
        `risks: ${report.risks.over.length} over, ${report.risks.warn.length} warn, ${report.risks.denied.length} denied-model`,
      );
      if (report.risks.over.length) {
        console.log(`  worst: ${report.risks.over[0].session} ${report.risks.over[0].in_tok} in — ${report.risks.over[0].guidance}`);
      }
    }
    if (report.handoff && report.handoff.available) {
      console.log(
        `handoff: ${report.handoff.level} (${report.handoff.in_tok}/${report.handoff.budget} in) — ${report.handoff.action}`,
      );
    }
    for (const f of report.findings) {
      const locus = f.locus ? ` locus=${f.locus}` : "";
      if (f.kind === "running_tool")
        console.log(`  [stall] ${f.session} ${f.tool} running ${f.age_s}s${locus} :: ${f.command}`);
      else if (f.kind === "dead_tool")
        console.log(`  [dead] ${f.session} ${f.tool} ran ${f.age_s}s, server idle/absent :: archival, not a live stall`);
      else if (f.kind === "dead_blank")
        console.log(`  [dead] ${f.session} ${f.model} blank ${f.age_s}s, server idle/absent :: archival, not a live no-answer`);
      else console.log(`  [blank] ${f.session} ${f.model} no text ${f.age_s}s after tool${locus}`);
    }
  }
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(await main());
}
