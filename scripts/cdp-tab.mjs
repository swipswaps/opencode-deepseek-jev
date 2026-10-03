#!/usr/bin/env node
// cdp-tab.mjs — zero-dependency Chrome DevTools Protocol client.
//
// WHY: the repo already proves pages two ways — headless DOM-shim
// (test-dashboard-ui.mjs, no browser) and Playwright (ux-test.py, needs a
// bundled chromium). Both miss the case the operator actually hits: a real
// browser is open (browser-use / Chrome for Testing with
// --remote-debugging-port) and the question is "what does the LIVE page
// show right now". This file attaches to that browser over CDP and reads
// rendered state, so :4096 (opencode server, source of truth) and :5099
// (dashboard, visualization) can be compared end to end.
//
// No npm packages: global fetch + global WebSocket (Node 22). Port
// discovery needs no child_process: it scans /proc cmdlines for
// --remote-debugging-port=, honouring CDP_PORT first, then 9222.
//
// Usage:
//   node scripts/cdp-tab.mjs --self-test            # offline, no browser
//   node scripts/cdp-tab.mjs tabs                   # list open tabs
//   node scripts/cdp-tab.mjs open <url>             # open url in a tab
//   node scripts/cdp-tab.mjs text <match>           # rendered innerText
//   node scripts/cdp-tab.mjs eval <match> <js>      # evaluate, print JSON
//   node scripts/cdp-tab.mjs shot <match> <png>     # screenshot to file
//   node scripts/cdp-tab.mjs probe                  # :4096 vs :5099 E2E
//
// probe contract: :5099 /api/health + /api/sessions ids (dashboard source),
// :4096 GET /session ids via Basic opencode:PASSWORD (source of truth;
// password from env only, never logged), rendered row ids from the live
// :5099 tab. PASS iff both endpoints live, rows render, markers settle, and
// rendered ids are a subset of the dashboard api. Dashboard-vs-opencode id
// drift is a NOTE (different database files), not a FAIL.
// Evidence: logs/cdp/probe-<ts>.json + logs/cdp/probe-latest.json
// (marker "verdict"), screenshots beside them (logs/ is gitignored).
// Exit 0 PASS, 2 FAIL, 0 with status=SKIP when no browser is reachable
// (SKIP is not PASS — RULES #37).

import { readdirSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("..", import.meta.url)).replace(/\/+$/, "");
const DASH = process.env.DASH_URL || "http://127.0.0.1:5099";
const API = process.env.OPENCODE_API_URL || "http://127.0.0.1:4096";

// ---- pure helpers (unit-tested by --self-test, no I/O) -----------------

export function portFromCmdline(cmd) {
  const m = /--remote-debugging-port=(\d+)/.exec(cmd || "");
  return m ? Number(m[1]) : 0;
}

export function matchTab(tabs, match) {
  const q = String(match || "").toLowerCase();
  const pages = (tabs || []).filter((t) => t && t.type === "page");
  const hit = pages.filter((t) =>
    String(t.url || "").toLowerCase().includes(q) ||
    String(t.title || "").toLowerCase().includes(q));
  if (hit.length === 0) return { ok: false, why: "no tab matches " + match };
  const real = hit.filter((t) => !String(t.url || "").startsWith("chrome://"));
  return { ok: true, tab: real[0] || hit[0], alternates: hit.length - 1 };
}

export function basicHeader(user, pw) {
  return "Basic " + Buffer.from(String(user) + ":" + String(pw), "utf8").toString("base64");
}

export function decideProbe(dashIds, apiIds, rendered) {
  // rendered: { rows, loading, ids[] }. Verdict semantics:
  // FAIL = an endpoint is down, nothing rendered, markers stuck, or the
  // visualization is unfaithful to its own source (rendered !<= dashboard).
  // Dashboard-vs-opencode drift is a NOTE (data currency), not a FAIL:
  // the two read different database files.
  const reasons = [];
  const notes = [];
  const dash = new Set(dashIds || []);
  if ((dashIds || []).length === 0) reasons.push("dashboard api returned no sessions");
  if ((apiIds || []).length === 0) reasons.push("opencode api unreachable (no password in env?)");
  const stray = (rendered.ids || []).filter((id) => !dash.has(id));
  if (!(rendered.rows > 0)) reasons.push("no rendered session rows on :5099");
  else if (stray.length > 0) reasons.push("rendered ids missing from dashboard api: " + stray.slice(0, 3).join(","));
  if (rendered.loading !== 0) reasons.push("loading markers left: " + rendered.loading);
  const api = new Set(apiIds || []);
  const drift = (dashIds || []).filter((id) => !api.has(id));
  if (drift.length > 0) notes.push("drift: " + drift.length + " dashboard sessions absent from :4096");
  return { verdict: reasons.length === 0 ? "PASS" : "FAIL", reasons, notes, drift: drift.slice(0, 10) };
}

// ---- CDP transport ------------------------------------------------------

export async function findDebugPort() {
  if (process.env.CDP_PORT) {
    const p = Number(process.env.CDP_PORT);
    if (p > 0) return { port: p, via: "env" };
  }
  try {
    for (const pid of readdirSync("/proc")) {
      if (!/^\d+$/.test(pid)) continue;
      let cmd = "";
      try { cmd = readFileSync("/proc/" + pid + "/cmdline", "utf8"); } catch { continue; }
      if (!cmd.includes("chrome") && !cmd.includes("chromium")) continue;
      const p = portFromCmdline(cmd.replace(/\0/g, " "));
      if (p > 0) return { port: p, via: "proc" };
    }
  } catch { /* non-Linux: fall through to default */ }
  return { port: 9222, via: "default" };
}

async function cdpGet(port, path) {
  const r = await fetch("http://127.0.0.1:" + port + path,
    { signal: AbortSignal.timeout(5000) });
  if (!r.ok) throw new Error("cdp http " + r.status + " on " + path);
  return r.json();
}

export async function listTabs(port) {
  return cdpGet(port, "/json/list");
}

export async function openUrl(port, url, tolerant) {
  const r = await fetch("http://127.0.0.1:" + port + "/json/new?url=" + encodeURIComponent(url),
    { method: "PUT", signal: AbortSignal.timeout(8000) });
  if (!r.ok) throw new Error("open failed: http " + r.status);
  const t = await r.json();
  // /json/new creates the target but does not reliably commit navigation
  // (observed: about:blank stuck). Drive it explicitly, then wait.
  await navigateTab(t.webSocketDebuggerUrl, url, tolerant);
  return t;
}

export async function navigateTab(wsUrl, url, tolerant) {
  const ws = await connect(wsUrl);
  try {
    const id = 7;
    ws.send(JSON.stringify({ id, method: "Page.navigate", params: { url } }));
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("navigate ack timeout")), 10000);
      ws.addEventListener("message", (ev) => {
        let m = null;
        try { m = JSON.parse(String(ev.data)); } catch { return; }
        if (m && m.id === id) { clearTimeout(t); resolve(m); }
      });
    });
  } finally {
    try { ws.close(); } catch { /* already closed */ }
  }
  const t0 = Date.now();
  let href = "";
  for (;;) {
    href = String(await evaluate(wsUrl, "location.href"));
    if (href.startsWith(url)) return href;
    // A 401-with-empty-body endpoint lands on chrome-error:// — that IS the
    // expected evidence for an auth-gated API, not a navigation failure.
    if (tolerant) return href;
    if (Date.now() - t0 > 25000) throw new Error("navigation never committed: " + href);
    await new Promise((r) => setTimeout(r, 500));
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener("open", () => resolve(ws), { once: true });
    ws.addEventListener("error", () => reject(new Error("ws connect failed")), { once: true });
    setTimeout(() => reject(new Error("ws connect timeout")), 8000);
  });
}

export async function evaluate(wsUrl, expression) {
  const ws = await connect(wsUrl);
  try {
    const id = 1;
    ws.send(JSON.stringify({ id, method: "Runtime.evaluate",
      params: { expression, returnByValue: true, awaitPromise: true } }));
    const raw = await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("evaluate timeout")), 15000);
      ws.addEventListener("message", (ev) => {
        let m = null;
        try { m = JSON.parse(String(ev.data)); } catch { return; }
        if (m && m.id === id) { clearTimeout(t); resolve(m); }
      });
    });
    if (raw.error) throw new Error("evaluate: " + raw.error.message);
    const res = raw.result && raw.result.result ? raw.result.result : {};
    if (res.subtype === "error" || res.type === "undefined") {
      throw new Error("evaluate threw: " + (res.description || "undefined"));
    }
    return ("value" in res) ? res.value : res.description;
  } finally {
    try { ws.close(); } catch { /* already closed */ }
  }
}

export async function screenshot(wsUrl, path) {
  const ws = await connect(wsUrl);
  try {
    const id = 2;
    ws.send(JSON.stringify({ id, method: "Page.captureScreenshot",
      params: { format: "png" } }));
    const raw = await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("screenshot timeout")), 20000);
      ws.addEventListener("message", (ev) => {
        let m = null;
        try { m = JSON.parse(String(ev.data)); } catch { return; }
        if (m && m.id === id) { clearTimeout(t); resolve(m); }
      });
    });
    const data = raw.result && raw.result.data ? raw.result.data : null;
    if (!data) throw new Error("empty screenshot");
    writeFileSync(path, Buffer.from(data, "base64"));
    return path;
  } finally {
    try { ws.close(); } catch { /* already closed */ }
  }
}

// Probe js: single expression, no backslash escapes (RULES #61).
const RENDERED_JS = "({loading: document.querySelectorAll('[data-loading]').length, rows: document.querySelectorAll('#sessions tr[data-id]').length, ids: Array.prototype.slice.call(document.querySelectorAll('#sessions tr[data-id]'), 0, 20).map(function(r){return r.getAttribute('data-id');})})";

async function ensureTab(port, url, match, tolerant) {
  const tabs = await listTabs(port);
  const found = matchTab(tabs, match);
  if (found.ok) return found.tab;
  return openUrl(port, url, tolerant);
}

export async function runProbe(outdir) {
  const started = new Date().toISOString();
  const steps = [];
  const step = (name, ok, detail) => {
    steps.push({ name, ok: !!ok, detail: String(detail || "") });
    return !!ok;
  };
  // 1. dashboard api counts (no auth on :5099).
  let dashIds = [];
  try {
    const h = await (await fetch(DASH + "/api/health",
      { signal: AbortSignal.timeout(10000) })).json();
    const s = await (await fetch(DASH + "/api/sessions?limit=500",
      { signal: AbortSignal.timeout(10000) })).json();
    dashIds = Array.isArray(s) ? s.map((x) => x.id) : [];
    step("dash api", dashIds.length > 0, "health findings=" +
      ((h.counts && h.counts.findings) || "?") + " sessions=" + dashIds.length);
  } catch (e) { step("dash api", false, String(e.message || e).slice(0, 120)); }
  // 2. opencode api ids (Basic opencode:PASSWORD, env only, never logged).
  let apiIds = [];
  let authed = false;
  try {
    const pw = process.env.OPENCODE_SERVER_PASSWORD || "";
    const headers = pw ? { Authorization: basicHeader("opencode", pw) } : {};
    const r = await fetch(API + "/session",
      { headers, signal: AbortSignal.timeout(10000) });
    if (r.status === 200) {
      const arr = await r.json();
      apiIds = Array.isArray(arr) ? arr.map((x) => x.id) : [];
      authed = true;
      step("opencode api", apiIds.length > 0, "sessions=" + apiIds.length);
    } else {
      step("opencode api", false, "http " + r.status + " (auth gate intact)");
    }
  } catch (e) { step("opencode api", false, String(e.message || e).slice(0, 120)); }
  // 3. rendered state via CDP.
  let c = { rows: 0, loading: -1, ids: [] };
  let shot5099 = "";
  let shot4096 = "";
  try {
    const found = await findDebugPort();
    const tab = await ensureTab(found.port, DASH + "/", "127.0.0.1:5099");
    // Settle: poll the loading marker the way ux-test.py does.
    for (let i = 0; i < 30; i++) {
      const cur = await evaluate(tab.webSocketDebuggerUrl,
        "document.querySelectorAll('[data-loading]').length");
      if (cur === 0) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    c = await evaluate(tab.webSocketDebuggerUrl, RENDERED_JS);
    step("rendered :5099", true, "rows=" + c.rows + " loading=" + c.loading);
    mkdirSync(outdir, { recursive: true });
    shot5099 = outdir + "/probe-5099.png";
    await screenshot(tab.webSocketDebuggerUrl, shot5099);
    const tab2 = await ensureTab(found.port, API + "/", "127.0.0.1:4096", true);
    const gate = String(await evaluate(tab2.webSocketDebuggerUrl,
      "document.title + ' :: ' + document.body.innerText.slice(0,80)")).replace(/\s+/g, " ");
    step("auth gate :4096", true, gate.slice(0, 100));
    shot4096 = outdir + "/probe-4096.png";
    await screenshot(tab2.webSocketDebuggerUrl, shot4096);
    step("screenshots", true, "2 png");
  } catch (e) {
    step("rendered :5099", false, String(e.message || e).slice(0, 120));
  }
  const d = decideProbe(dashIds, apiIds, c);
  const report = {
    ts: started, dash: DASH, api: API, authed,
    counts: { dashboard_api: dashIds.length, opencode_api: apiIds.length, rendered_rows: c.rows, rendered_loading: c.loading },
    drift_sample: d.drift,
    shots: [shot5099, shot4096].filter(Boolean),
    steps, verdict: d.verdict, reasons: d.reasons, notes: d.notes,
  };
  mkdirSync(outdir, { recursive: true });
  const stamp = started.replace(/[:.]/g, "").slice(0, 15);
  writeFileSync(outdir + "/probe-" + stamp + ".json", JSON.stringify(report, null, 1) + "\n");
  writeFileSync(outdir + "/probe-latest.json", JSON.stringify(report, null, 1) + "\n");
  return report;
}

// ---- CLI ---------------------------------------------------------------

function usage() {
  const lines = [
    "usage: node scripts/cdp-tab.mjs [--self-test|tabs|open <url>|text <match>|eval <match> <js>|shot <match> <png>|probe]",
    "  env: CDP_PORT (override), DASH_URL (default " + DASH + "), OPENCODE_API_URL (default " + API + ")",
    "  OPENCODE_SERVER_PASSWORD only enables the :4096 count in probe; it is never printed.",
  ];
  process.stdout.write(lines.join("\n") + "\n");
}

function selfTest() {
  let pass = 0;
  let fail = 0;
  const ok = (n, c) => { if (c) { pass++; } else { fail++; process.stdout.write("FAIL " + n + "\n"); } };
  ok("port parse", portFromCmdline("--remote-debugging-port=43171 --window-size=1") === 43171);
  ok("port absent", portFromCmdline("--no-first-run") === 0);
  const tabs = [
    { type: "page", title: "opencode sessions", url: "http://127.0.0.1:5099/" },
    { type: "page", title: "x", url: "chrome://settings/help" },
  ];
  const m = matchTab(tabs, "5099");
  ok("match tab", m.ok && m.tab.title === "opencode sessions");
  ok("no match", !matchTab(tabs, "nope").ok);
  const h = basicHeader("opencode", "s3cret!");
  ok("basic shape", /^Basic [A-Za-z0-9+/=]+$/.test(h));
  ok("basic decodes", Buffer.from(h.slice(6), "base64").toString().includes(":"));
  const d1 = decideProbe(["a", "b"], ["a", "b"], { rows: 2, loading: 0, ids: ["a"] });
  ok("decide pass", d1.verdict === "PASS");
  const d2 = decideProbe(["a", "b"], ["a"], { rows: 1, loading: 0, ids: ["a"] });
  ok("decide drift-is-note", d2.verdict === "PASS" && d2.notes.length === 1 && d2.drift.join() === "b");
  const d2b = decideProbe(["a"], ["a"], { rows: 1, loading: 0, ids: ["zzz"] });
  ok("decide stray-rendered", d2b.verdict === "FAIL");
  const d3 = decideProbe([], [], { rows: 0, loading: 2, ids: [] });
  ok("decide down", d3.verdict === "FAIL" && d3.reasons.length === 4);
  process.stdout.write("self-test: " + pass + " pass, " + fail + " fail\n");
  return fail === 0 ? 0 : 2;
}

async function cli(argv) {
  const cmd = argv[0];
  if (!cmd || cmd === "--help") { usage(); return 0; }
  if (cmd === "--self-test") return selfTest();
  let found = null;
  try {
    found = await findDebugPort();
    await cdpGet(found.port, "/json/version");
  } catch {
    process.stdout.write("status=SKIP no browser with remote debugging reachable (start one or set CDP_PORT; SKIP is not PASS)\n");
    return 0;
  }
  if (cmd === "tabs") {
    const tabs = await listTabs(found.port);
    for (const t of tabs) {
      if (t.type !== "page") continue;
      process.stdout.write(t.title + " | " + t.url + "\n");
    }
    return 0;
  }
  if (cmd === "open") {
    if (!argv[1]) { usage(); return 2; }
    const t = await openUrl(found.port, argv[1]);
    process.stdout.write("opened: " + (t.url || argv[1]) + "\n");
    return 0;
  }
  const need = matchTab(await listTabs(found.port), argv[1]);
  if (!need.ok) { process.stdout.write("FAIL " + need.why + "\n"); return 2; }
  const ws = need.tab.webSocketDebuggerUrl;
  if (cmd === "text") {
    process.stdout.write(String(await evaluate(ws, "document.body.innerText")) + "\n");
    return 0;
  }
  if (cmd === "eval") {
    if (!argv[2]) { usage(); return 2; }
    process.stdout.write(JSON.stringify(await evaluate(ws, argv[2])) + "\n");
    return 0;
  }
  if (cmd === "shot") {
    if (!argv[2]) { usage(); return 2; }
    await screenshot(ws, argv[2]);
    process.stdout.write("saved: " + argv[2] + "\n");
    return 0;
  }
  if (cmd === "probe") {
    const rep = await runProbe(REPO + "/logs/cdp");
    for (const s of rep.steps) {
      process.stdout.write((s.ok ? "ok   " : "NOT-OK ") + s.name + " :: " + s.detail + "\n");
    }
    process.stdout.write("counts: dashboard_api=" + rep.counts.dashboard_api +
      " opencode_api=" + rep.counts.opencode_api +
      " rendered_rows=" + rep.counts.rendered_rows + "\n");
    if (rep.reasons.length > 0) {
      for (const r of rep.reasons) process.stdout.write("reason: " + r + "\n");
    }
    if (rep.notes.length > 0) {
      for (const n of rep.notes) process.stdout.write("note: " + n + "\n");
    }
    process.stdout.write("probe: " + rep.verdict + "\n");
    return rep.verdict === "PASS" ? 0 : 2;
  }
  usage();
  return 2;
}

const rc = await cli(process.argv.slice(2)).catch((e) => {
  process.stderr.write("FAIL " + String((e && e.message) || e).slice(0, 200) + "\n");
  return 2;
});
process.exit(rc);
