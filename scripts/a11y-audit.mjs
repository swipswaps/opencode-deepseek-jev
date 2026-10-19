// a11y-audit.mjs — offline accessibility/usability audit for served pages.
//
// WHY: the dashboard is a served web app, so WCAG basics are a gate, not a
// taste call. This audits the HTML the server actually emits (the same files
// test-dashboard.sh curls) with no browser and no network: language/title,
// heading order, landmarks, skip-link target, accessible names for controls,
// focus visibility, reduced-motion, and theme colour contrast.
//
// Usage:
//   node scripts/a11y-audit.mjs FILE [FILE...] [--json]
//   node scripts/a11y-audit.mjs --url http://127.0.0.1:5099/ [--url ...]
//   node scripts/a11y-audit.mjs --self-test
//
// Plain ASCII. No dependencies. No network unless --url is passed.

import { readFileSync } from "node:fs";

const norm = (s) => String(s || "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
const decode = (s) => norm(s).replace(/&amp;/g, "&").replace(/&lt;/g, "<")
  .replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");

function axis(name, ok, detail) {
  return { name, ok: !!ok, detail: detail || "" };
}

function cssOf(html) {
  const blocks = [];
  const re = /<style\b[^>]*>([\s\S]*?)<\/style>/gi;
  let m;
  while ((m = re.exec(html))) blocks.push(m[1]);
  return blocks.join("\n");
}

function tokens(css, selector) {
  const out = {};
  const re = new RegExp(selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}", "i");
  const m = css.match(re);
  if (!m) return out;
  const decl = /--([a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,8})/g;
  let d;
  while ((d = decl.exec(m[1]))) out[d[1]] = d[2];
  return out;
}

function lin(c) {
  const v = c / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}
function lum(hex) {
  let h = hex.replace("#", "");
  if (h.length === 3) h = h.split("").map((c) => c + c).join("");
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}
function contrast(a, b) {
  const la = lum(a), lb = lum(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function contrastAxis(css) {
  const dark = tokens(css, ":root");
  const light = tokens(css, "html.light");
  if (!dark.bg || !dark.fg) return axis("contrast", true, "no theme tokens (SKIP)");
  const pairs = [
    ["fg", "bg", 4.5], ["muted", "bg", 4.5], ["fg", "surface", 4.5],
    ["muted", "surface", 4.5], ["accent", "bg", 4.5], ["bg", "accent", 4.5],
    ["danger", "bg", 4.5],
  ];
  const fails = [];
  const note = [];
  for (const [label, set] of [["dark", dark], ["light", Object.keys(light).length ? light : dark]]) {
    for (const [fg, bg, min] of pairs) {
      if (!set[fg] || !set[bg]) continue;
      const r = contrast(set[fg], set[bg]);
      if (r < min) fails.push(`${label} ${fg}/${bg} ${r.toFixed(2)} < ${min}`);
      else note.push(`${label} ${fg}/${bg} ${r.toFixed(1)}`);
    }
  }
  return axis("contrast", fails.length === 0, fails.join("; ") || note.slice(0, 4).join(", "));
}

function headingAxis(html) {
  const tags = [...html.matchAll(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi)]
    .map((m) => ({ level: +m[1], text: decode(m[2]).slice(0, 60) }));
  const h1 = tags.filter((t) => t.level === 1);
  if (h1.length !== 1) return axis("heading tree", false, `expected one h1, found ${h1.length}`);
  for (let i = 1; i < tags.length; i++) {
    if (tags[i].level > tags[i - 1].level + 1) {
      return axis("heading tree", false, `skipped from h${tags[i - 1].level} to h${tags[i].level} at "${tags[i].text}"`);
    }
  }
  return axis("heading tree", true, `${tags.length} headings, one h1`);
}

function controlsAxis(html) {
  const problems = [];
  const labels = new Set();
  for (const m of html.matchAll(/<label\b[^>]*\bfor=["']([^"']+)["']/gi)) labels.add(m[1]);
  const hasName = (attrs, inner) => {
    if (/\baria-label\s*=\s*["'][^"']+["']/i.test(attrs)) return true;
    if (/\baria-labelledby\s*=/i.test(attrs)) return true;
    if (/\btitle\s*=\s*["'][^"']+["']/i.test(attrs)) return true;
    return decode(inner).length > 0;
  };
  for (const m of html.matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button>/gi)) {
    if (!hasName(m[1], m[2])) problems.push("button without accessible name");
  }
  for (const m of html.matchAll(/<(input|select|textarea)\b([^>]*?)\/?>/gi)) {
    const a = m[2];
    const id = (a.match(/\bid=["']([^"']+)["']/i) || [])[1];
    const ok = /\baria-label\s*=\s*["'][^"']+["']/i.test(a) || /\baria-labelledby\s*=/i.test(a) ||
      /\btitle\s*=\s*["'][^"']+["']/i.test(a) || (id && labels.has(id));
    if (!ok) problems.push(`${m[1]} without accessible name${id ? " (#" + id + ")" : ""}`);
  }
  for (const m of html.matchAll(/<[a-z]+\b([^>]*\brole=["'](?:button|link)["'][^>]*)>([\s\S]*?)<\/[a-z]+>/gi)) {
    if (!hasName(m[1], m[2])) problems.push("role=button/link without accessible name");
  }
  if (problems.length) return axis("control names", false, [...new Set(problems)].slice(0, 6).join("; "));
  return axis("control names", true, "buttons, inputs and role controls named");
}

export function audit(html, label = "page") {
  const css = cssOf(html);
  // Structure comes from markup, not from HTML-shaped strings inside scripts.
  const doc = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "");
  const out = [];
  const lang = (html.match(/<html\b[^>]*\blang=["']([^"']+)["']/i) || [])[1];
  out.push(axis("language", !!lang, lang ? `lang="${lang}"` : "missing <html lang>"));
  const title = (html.match(/<title>([\s\S]*?)<\/title>/i) || [])[1];
  out.push(axis("title", !!decode(title), decode(title) ? `"${decode(title)}"` : "missing/empty <title>"));
  out.push(axis("viewport", /<meta\b[^>]*name=["']viewport["']/i.test(html), "responsive meta"));

  const main = doc.match(/<main\b([^>]*)>/i);
  const skip = doc.match(/<a\b[^>]*class=["'][^"']*skip-link[^"']*["'][^>]*href=["']#([^"']+)["']/i) ||
    html.match(/<a\b[^>]*href=["']#([^"']+)["'][^>]*class=["'][^"']*skip-link[^"']*["']/i);
  const skipOk = !!skip && !!main && new RegExp(`id=["']${skip[1]}["']`, "i").test(html) &&
    /\btabindex=["']-1["']/i.test(main[1]);
  out.push(axis("skip link", skipOk, skipOk ? `#${skip[1]} is focusable` : "skip link or tabindex=-1 target missing"));

  const nav = doc.match(/<nav\b([^>]*)>/i);
  const navOk = !nav || /\baria-label\s*=\s*["'][^"']+["']/i.test(nav[1]) || /\baria-labelledby\s*=/i.test(nav[1]);
  out.push(axis("landmark names", navOk, navOk ? "nav is named or absent" : "<nav> has no aria-label"));

  const imgs = [...doc.matchAll(/<img\b([^>]*)>/gi)];
  const badImg = imgs.filter((m) => !/\balt\s*=/i.test(m[1]));
  out.push(axis("image alt", badImg.length === 0, badImg.length ? `${badImg.length} <img> without alt` : `${imgs.length} images checked`));

  out.push(headingAxis(doc));
  out.push(controlsAxis(doc));

  const hasFocus = /:focus-visible\s*\{[^}]*outline\s*:/i.test(css);
  const bareOutline = /(?:^|[,{}])\s*[^{,}]*\{\s*[^}]*outline\s*:\s*none[^}]*\}/i.test(css) &&
    !/:focus(?:-visible)?\s*\{[^}]*outline\s*:\s*(?!none)[^}]*\}/i.test(css);
  out.push(axis("focus visible", hasFocus && !bareOutline,
    !hasFocus ? "no :focus-visible outline" : bareOutline ? "outline:none without a focus override" : "focus outline present"));

  const motion = /(?:^|[;{])\s*(?:transition|animation)\s*:|@keyframes\b/i.test(css);
  const reduce = /@media\s*\([^)]*prefers-reduced-motion\s*:\s*reduce[^)]*\)/i.test(css);
  out.push(axis("reduced motion", !motion || reduce, motion ? (reduce ? "guard present" : "motion without prefers-reduced-motion") : "no motion CSS"));

  out.push(contrastAxis(css));
  const fails = out.filter((a) => !a.ok);
  return { label, checks: out, fails };
}

function report(results, json) {
  let total = 0, failed = 0;
  const rows = [];
  for (const r of results) {
    total += r.checks.length;
    failed += r.fails.length;
    for (const c of r.checks) {
      rows.push({ page: r.label, check: c.name, ok: c.ok, detail: c.detail });
      if (!c.ok) console.log(`FAIL ${r.label} ${c.name}: ${c.detail}`);
    }
  }
  if (json) console.log(JSON.stringify({ total, failed, rows }, null, 1));
  if (failed === 0) console.log(`a11y-audit: PASS (${total} checks, ${results.length} page(s))`);
  else console.log(`a11y-audit: FAIL (${failed} of ${total} checks, ${results.length} page(s))`);
  return failed === 0 ? 0 : 1;
}

const GOOD = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>t</title>
<style>:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--surface:#161b22;--accent:#2ea043;--danger:#ff7b72}
html.light{--bg:#fff;--fg:#1f2328;--muted:#57606a;--surface:#f6f8fa;--accent:#1f883d;--danger:#cf222e}
:focus-visible{outline:2px solid #1f6feb}</style></head><body>
<a class="skip-link" href="#main">Skip</a><nav aria-label="Primary"><a href="/">d</a></nav>
<main id="main" tabindex="-1"><h1>t</h1><h2>s</h2>
<img alt="x"><button>ok</button><input aria-label="q"><div role="button" aria-label="go">go</div>
</main></body></html>`;
const BAD = `<!doctype html><html><head><title></title><style>
:root{--bg:#ffffff;--fg:#dddddd;--muted:#eeeeee;--surface:#ffffff;--accent:#eeeeee;--danger:#eeeeee}
#x{outline:none}.a{transition:all 1s}</style></head><body>
<nav><a href="/">d</a></nav><main id="main"><h1>a</h1><h3>c</h3><img><button></button><input><div role="link">x</div></main></body></html>`;

function selfTest() {
  const good = audit(GOOD, "good");
  const bad = audit(BAD, "bad");
  const badNames = new Set(bad.fails.map((f) => f.name));
  const checks = [
    ["good page passes", good.fails.length === 0],
    ["bad: language", badNames.has("language")],
    ["bad: title", badNames.has("title")],
    ["bad: skip link", badNames.has("skip link")],
    ["bad: landmark names", badNames.has("landmark names")],
    ["bad: image alt", badNames.has("image alt")],
    ["bad: heading tree", badNames.has("heading tree")],
    ["bad: control names", badNames.has("control names")],
    ["bad: focus visible", badNames.has("focus visible")],
    ["bad: reduced motion", badNames.has("reduced motion")],
    ["bad: contrast", badNames.has("contrast")],
  ];
  let fail = 0;
  for (const [name, ok] of checks) {
    if (!ok) { console.log("FAIL self-test: " + name); fail++; }
  }
  console.log(fail === 0 ? "a11y-audit: self-test PASS (11 checks)" : `a11y-audit: self-test FAIL (${fail})`);
  return fail === 0 ? 0 : 1;
}

async function fromUrl(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.text();
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) return selfTest();
  const json = args.includes("--json");
  const files = [];
  const urls = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--json" || a === "--self-test") continue;
    if (a === "--url") { urls.push(args[++i]); continue; }
    if (a.startsWith("--url=")) { urls.push(a.slice(6)); continue; }
    if (!a.startsWith("--")) files.push(a);
  }
  if (files.length === 0 && urls.length === 0) {
    console.log("usage: a11y-audit.mjs FILE... [--json] | --url URL | --self-test");
    return 2;
  }
  const results = [];
  for (const f of files) results.push(audit(readFileSync(f, "utf8"), f));
  for (const u of urls) {
    try { results.push(audit(await fromUrl(u), u)); }
    catch (e) { results.push({ label: u, checks: [axis("fetch", false, String(e.message || e))], fails: [axis("fetch", false, String(e.message || e))] }); }
  }
  return report(results, json);
}

main().then((rc) => { process.exitCode = rc; }).catch((e) => {
  console.log("a11y-audit: ERROR " + (e && e.message ? e.message : e));
  process.exitCode = 2;
});
