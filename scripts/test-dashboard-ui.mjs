// test-dashboard-ui.mjs — headless execution test for the dashboard's
// inline browser script. Fetches the served "/" page, runs its <script> in
// a minimal DOM shim against the live server, fires the interval refreshers
// once, and asserts the panes actually populate. This catches runtime
// client bugs (and template-literal escape errors) that a syntax-only check
// and a substring grep both miss. No browser required.
//
// Usage: node scripts/test-dashboard-ui.mjs <base-url>   (default :5099)

import vm from "node:vm";

const BASE = process.argv[2] || "http://127.0.0.1:5099";

class El {
  constructor(tag) {
    this.tag = tag; this.children = []; this._html = ""; this._text = "";
    this.style = {}; this.dataset = {}; this.attrs = {}; this.listeners = {};
  }
  set innerHTML(v) { this._html = String(v); this.children = []; }
  get innerHTML() { return this._html; }
  set textContent(v) { this._text = String(v); }
  get textContent() { return this._text; }
  appendChild(c) { this.children.push(c); return c; }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k]; }
  querySelector() { return null; }
  closest() { return null; }
  select() {}
}

const reg = {};
const getEl = (id) => (reg[id] = reg[id] || new El("div"));
const timers = [];
const noop = () => {};

const document = {
  getElementById: getEl,
  createElement: (t) => new El(t),
  body: new El("body"),
  querySelector: () => null,
  execCommand: () => true,
};

function fail(msg) { console.log("FAIL: " + msg); process.exit(1); }

async function main() {
  let html;
  try {
    html = await (await fetch(BASE + "/")).text();
  } catch (e) {
    fail("cannot reach " + BASE + " (" + e.message + ")");
  }
  const m = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!m) fail("no inline <script> in /");

  const sandbox = {
    document,
    fetch: (u, o) => fetch(new URL(u, BASE), o),
    console, navigator: {},
    setTimeout, clearTimeout,
    setInterval: (fn) => { timers.push(fn); return timers.length; },
    clearInterval: noop,
    Date, JSON, Math, Number, String, Boolean, Object, Array, Promise, RegExp,
    encodeURIComponent, decodeURIComponent,
  };
  try {
    vm.createContext(sandbox);
    vm.runInContext(m[1], sandbox, { filename: "inline.js" });
  } catch (e) {
    fail("inline script threw at load: " + e.message);
  }

  await new Promise((r) => setTimeout(r, 300));
  for (const fn of timers) {
    try { fn(); } catch (e) { fail("interval refresher threw: " + e.message); }
  }

  const panes = ["session", "stats", "sessions", "activity", "config"];
  let ok = true;
  for (const id of panes) {
    const el = getEl(id);
    const t0 = Date.now();
    while ((el._html || el._text || "").length === 0 && Date.now() - t0 < 20000) {
      await new Promise((r) => setTimeout(r, 250));
    }
    const n = (el._html || el._text || "").length;
    console.log((n > 0 ? "PASS " : "FAIL ") + "pane #" + id + " populated (" + n + " bytes, " + (Date.now() - t0) + "ms)");
    if (n <= 0) ok = false;
  }
  process.exit(ok ? 0 : 1);
}

main();
