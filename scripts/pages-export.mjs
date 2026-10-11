#!/usr/bin/env node
// pages-export.mjs — build a redacted static snapshot for GitHub Pages.
//
// Reads opencode.db READ-ONLY plus the models catalog, strips secrets via
// redact.mjs, applies the publish allowlist (aggregates + session rows
// WITHOUT part/message text), and writes out/data.json + out/index.html.
// Detection gates fail closed: zero sessions or zero models => exit 2.
// Never prints secrets; never writes the DB.
//
// Usage:
//   node --experimental-sqlite scripts/pages-export.mjs \
//     --db data/opencode/opencode.db --out site \
//     --consent '{"scope":"once","policyHash":"abc","ts":"..."}' \
//     [--commit site-data/panel.json] [--rev HEAD] [--limit 500]
//   node scripts/pages-export.mjs --shell-only --commit site-data/panel.json \
//     --out site   (no DB: assemble shell around committed redacted data;
//     for CI, which never sees the database)
//
//
// Exit 0 wrote site, 2 gate failed (nothing written).

import { DatabaseSync } from "node:sqlite";
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { redact } from "./redact.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function arg(name, def) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : def;
}

function has(name) {
  return process.argv.includes("--" + name);
}

function shortDir(d) {
  const s = String(d || "");
  return s.length > 56 ? "…" + s.slice(-55) : s;
}

function modelId(m) {
  if (!m) return "(none)";
  try {
    const o = JSON.parse(m);
    return o.id ? (o.providerID ? o.providerID + "/" + o.id : o.id) : String(m);
  } catch {
    return String(m);
  }
}

function shellOnly(out) {
  const commit = arg("commit", join(ROOT, "site-data", "panel.json"));
  let data;
  try {
    data = JSON.parse(readFileSync(commit, "utf8"));
  } catch {
    console.error("FAIL: no committed panel data (export locally and push it first)");
    process.exit(2);
  }
  if (!data.sessions || !data.sessions.length) {
    console.error("FAIL: committed panel is empty (refusing)");
    process.exit(2);
  }
  const chk = JSON.stringify(data);
  if (/sk-[A-Za-z0-9]{20,}/.test(chk) || /apikey_[A-Za-z0-9_]{16,}/.test(chk)) {
    console.error("FAIL: secret shape in committed panel (refusing)");
    process.exit(2);
  }
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "data.json"), chk + "\n");
  writeShell(out, data, data.sessions, data.rev || "unknown", {
    n: data.totals.sessions, c: data.totals.cost,
  });
  console.log("SHELL " + out + " sessions=" + data.sessions.length);
}

function main() {
  const dbPath = arg("db", null);
  const out = arg("out", join(ROOT, "site"));
  const consent = JSON.parse(arg("consent", "{}"));
  const rev = arg("rev", "unknown");
  const limit = Number(arg("limit", "500")) || 500;
  if (has("shell-only")) {
    return shellOnly(out);
  }
  if (!dbPath) {
    console.error("FAIL: --db required");
    process.exit(2);
  }
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const q = (sql, ...a) => db.prepare(sql).all(...a);

  const totals = q(
    "SELECT COUNT(*) n, COALESCE(SUM(cost),0) c, COALESCE(SUM(tokens_input),0) i, " +
    "COALESCE(SUM(tokens_output),0) o, COALESCE(SUM(tokens_reasoning),0) r FROM session"
  )[0];
  if (!totals || totals.n === 0) {
    console.error("FAIL: zero sessions (refusing to publish an empty panel)");
    process.exit(2);
  }
  const models = q(
    "SELECT model, COUNT(*) sessions, COALESCE(SUM(cost),0) cost, " +
    "COALESCE(SUM(tokens_input),0) tin, COALESCE(SUM(tokens_output),0) tout " +
    "FROM session GROUP BY model ORDER BY cost DESC LIMIT 40"
  );
  if (!models.length) {
    console.error("FAIL: zero models (refusing to publish an empty panel)");
    process.exit(2);
  }
  const sessions = q(
    "SELECT s.id, s.title, s.model, s.agent, s.directory, p.worktree AS project, " +
    "s.cost, s.tokens_input, s.tokens_output, s.time_created, s.time_updated " +
    "FROM session s LEFT JOIN project p ON p.id=s.project_id " +
    "ORDER BY s.time_updated DESC LIMIT ?",
    limit
  ).map((s) => ({
    id: s.id,
    title: redact(s.title || "(untitled)").slice(0, 120),
    model: modelId(s.model),
    agent: s.agent || null,
    directory: shortDir(s.directory),
    project: shortDir(s.project),
    cost: s.cost || 0,
    tin: s.tokens_input || 0,
    tout: s.tokens_output || 0,
    created: s.time_created,
    updated: s.time_updated,
  }));

  let policy = {};
  try {
    policy = JSON.parse(readFileSync(join(ROOT, "models.policy.json"), "utf8"));
  } catch {
    policy = { error: "models.policy.json unreadable" };
  }
  const data = {
    generated_at: new Date().toISOString(),
    rev,
    consent: {
      scope: consent.scope || "unknown",
      policyHash: consent.policyHash || null,
      ts: consent.ts || null,
    },
    policy: { allow: policy.allow || [], deny: policy.deny || [] },
    totals: { sessions: totals.n, cost: totals.c, tin: totals.i, tout: totals.o, treason: totals.r },
    models: models.map((m) => ({ id: modelId(m.model), sessions: m.sessions, cost: m.cost, tin: m.tin, tout: m.tout })),
    sessions,
  };
  const body = JSON.stringify(data);
  if (/sk-[A-Za-z0-9]{20,}/.test(body) || /apikey_[A-Za-z0-9_]{16,}/.test(body)) {
    console.error("FAIL: secret shape survived redaction (refusing to write)");
    process.exit(2);
  }
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "data.json"), body + "\n");
  writeShell(out, data, sessions, rev, totals);
  const commit = arg("commit", null);
  if (commit) {
    mkdirSync(dirname(join(ROOT, commit)), { recursive: true });
    writeFileSync(join(ROOT, commit), body + "\n");
    console.log("COMMITTABLE " + commit + " (review the diff before pushing)");
  }
  db.close();
  console.log("WROTE " + out + " sessions=" + sessions.length + " models=" + models.length);
}

function writeShell(out, data, sessions, rev, totals) {
  mkdirSync(out, { recursive: true });
  mkdirSync(join(out, "vendor"), { recursive: true });
  for (const v of ["d3.min.js"]) {
    try {
      copyFileSync(join(ROOT, "scripts", "vendor", v), join(out, "vendor", v));
    } catch {}
  }
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const rows = sessions.map((s) => {
    const dt = s.updated ? new Date(Number(s.updated)).toISOString().slice(0, 19).replace("T", " ") : "";
    return "<tr><td>" + esc(s.title) + "</td><td>" + esc(s.model) + "</td><td>" + esc(s.project || s.directory) + "</td><td class=num>" + dt + "</td><td class=num>$" + Number(s.cost).toFixed(4) + "</td></tr>";
  }).join("");
  const html = "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>" +
    "<title>sessions panel</title><style>" +
    "body{font-family:system-ui,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px}" +
    "table{border-collapse:collapse;width:100%;font-size:12px}" +
    "th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d}.num{text-align:right}" +
    ".muted{color:#8b949e;font-size:12px}.badge{border:1px solid #30363d;border-radius:8px;padding:8px 12px;margin:8px 0;font-size:12px}" +
    "</style></head><body>" +
    "<h1>sessions panel</h1>" +
    "<div class=badge>generated " + esc(data.generated_at) + " · rev " + esc(rev) + " · consent " + esc(data.consent.scope) +
    " · policy " + esc(data.consent.policyHash || "?") + " · redacted aggregates only (no message text)</div>" +
    "<div class=muted>" + totals.n + " sessions · $" + Number(totals.c).toFixed(2) + " total</div>" +
    "<h2>models</h2><div id=bars></div>" +
    "<h2>sessions</h2><div style=overflow-x:auto><table><tr><th>title</th><th>model</th><th>project</th><th class=num>updated</th><th class=num>cost</th></tr>" +
    rows + "</table></div>" +
    "<script src=vendor/d3.min.js></script><script>" +
    "fetch('data.json').then(function(r){return r.json();}).then(function(d){" +
    "var m=d.models.slice(0,12),W=640,bh=22;" +
    "var max=Math.max.apply(null,m.map(function(x){return x.cost;}))||1;" +
    "var svg=d3.select('#bars').append('svg').attr('width',W).attr('height',m.length*(bh+4));" +
    "var g=svg.selectAll('g').data(m).enter().append('g').attr('transform',function(d,i){return 'translate(0,'+(i*(bh+4))+')';});" +
    "g.append('rect').attr('width',function(d){return Math.max(2,d.cost/max*(W-320));}).attr('height',bh).attr('fill','#2ea043');" +
    "g.append('text').attr('x',function(d){return Math.max(2,d.cost/max*(W-320))+6;}).attr('y',bh-6).attr('fill','#e6edf3').attr('font-size',11).text(function(d){return d.id+' $'+d.cost.toFixed(3);});" +
    "}).catch(function(){document.getElementById('bars').textContent='(data unavailable)';});" +
    "</script></body></html>";
  writeFileSync(join(out, "index.html"), html + "\n");
  writeFileSync(join(out, ".nojekyll"), "");
}

main();
