// test-dashboard-ui.mjs — headless execution test for the dashboard's
// inline browser scripts. Fetches a served page, runs its <script> in a
// minimal DOM shim against the live server, and asserts behaviour. This
// catches runtime client bugs and template-literal escape errors that a
// syntax-only check and a substring grep both miss. No browser required.
//
// Usage:
//   node scripts/test-dashboard-ui.mjs <base-url>            # home page: panes populate
//   node scripts/test-dashboard-ui.mjs <base-url> explore    # explore page: script executes (d3 stubbed)

import vm from "node:vm";

const BASE = process.argv[2] || "http://127.0.0.1:5099";
const MODE = process.argv[3] || "home";
const PATH = MODE === "explore" ? "/explore" : "/";

class El {
  constructor(tag) {
    this.tag = tag; this.children = []; this._html = ""; this._text = "";
    this.style = {}; this.dataset = {}; this.attrs = {}; this.listeners = {};
    this._classes = new Set();
    this.classList = {
      add: (c) => this._classes.add(c),
      remove: (c) => this._classes.delete(c),
      contains: (c) => this._classes.has(c),
      toggle: (c) => (this._classes.has(c) ? (this._classes.delete(c), false) : (this._classes.add(c), true)),
    };
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
  querySelectorAll() { return []; }
  closest() { return null; }
  select() {}
}

const reg = {};
// Strict ids: an id that is not present in the served HTML is null, exactly as
// a browser behaves. This is what catches `getElementById('tabs')` on a div
// that only had class="tabs" — the stub-permissive shim used to hide it.
let validIds = null;
const getEl = (id) => {
  if (validIds && !validIds.has(id)) return null;
  return (reg[id] = reg[id] || new El("div"));
};
const timers = [];
const noop = () => {};

const document = {
  getElementById: getEl,
  createElement: (t) => new El(t),
  body: new El("body"),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: () => {},
  execCommand: () => true,
};

function fail(msg) { console.log("FAIL: " + msg); process.exit(1); }

function makeStub() {
  const handler = {
    get(t, p) {
      if (p === "then") return undefined;
      if (p === Symbol.toPrimitive) return () => "";
      if (p === "toString") return () => "";
      if (p === "valueOf") return () => 0;
      return stub;
    },
    apply() { return stub; },
    construct() { return stub; },
  };
  const stub = new Proxy(function () {}, handler);
  return stub;
}

process.on("unhandledRejection", (e) => fail("unhandled rejection: " + (e && e.message ? e.message : e)));

async function main() {
  let html;
  try {
    html = await (await fetch(BASE + PATH)).text();
  } catch (e) {
    fail("cannot reach " + BASE + PATH + " (" + e.message + ")");
  }
  const m = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!m) fail("no inline <script> in " + PATH);
  validIds = new Set([...html.matchAll(/id="([^"]+)"/g)].map((x) => x[1]));

  const sandbox = {
    document,
    fetch: (u, o) => fetch(new URL(u, BASE), o),
    console, navigator: {},
    setTimeout, clearTimeout,
    setInterval: (fn) => { timers.push(fn); return timers.length; },
    clearInterval: noop,
    Date, JSON, Math, Number, String, Boolean, Object, Array, Promise, RegExp,
    encodeURIComponent, decodeURIComponent, URLSearchParams,
    location: { search: "", hash: "", href: BASE + PATH },
    window: { addEventListener: () => {} },
  };
  if (MODE === "explore") sandbox.d3 = makeStub();

  try {
    vm.createContext(sandbox);
    vm.runInContext(m[1], sandbox, { filename: "inline.js" });
  } catch (e) {
    fail(PATH + " inline script threw at load: " + e.message);
  }

  await new Promise((r) => setTimeout(r, 400));
  for (const fn of timers) {
    try { fn(); } catch (e) { fail(PATH + " interval refresher threw: " + e.message); }
  }

  if (MODE === "explore") {
    await new Promise((r) => setTimeout(r, 500));
    const tabs = getEl("tabs");
    if (!tabs || !tabs.listeners.click || !tabs.listeners.click.length) {
      fail("explore: #tabs click handler not wired (id present?)");
    }
    console.log("PASS explore: inline script executes and #tabs is wired (d3 stubbed)");
    process.exit(0);
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
