#!/usr/bin/env node
// capabilities.mjs — read-only capability registry checker.
//
// WHY: a capability can be DECLARED and even CONFIGURED yet never actually
// execute. This repo lived that: `blacklist-guard.js` was listed in `/config`
// but wrote no `guard.log` heartbeat (silently inert). LifeOS reports the same
// class (issue #1770: version advanced, runtime machinery stale). The fix is a
// registry that checks the four links separately:
//   IMPLEMENTATION (file exists) -> REGISTRATION (wired in) -> TEST -> EVIDENCE
// and reports GREEN only when impl+registration+test hold, DEGRADED when impl
// exists but wiring/tests are missing, MISSING when there is no impl.
// Evidence levels follow RULES.md "Evidence levels" (E0..E5); nothing is
// "confirmed" below E3. Offline, no network, no model call.
//
// Usage: node scripts/capabilities.mjs [--json] [--self-test]

import { readFileSync, existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("..", import.meta.url)).replace(/\/+$/, "");
const CAPS = fileURLToPath(new URL("./capabilities.json", import.meta.url));

const expand = (p) => (p && p.startsWith("~") ? homedir() + p.slice(1) : p);
const abs = (root, p) => (p && p.startsWith("/") ? p : root + "/" + p);
const readIf = (p) => { try { return readFileSync(p, "utf8"); } catch { return null; } };

function checkCapability(root, cap) {
  const implOk = existsSync(abs(root, cap.impl));
  let regOk = false;
  const reg = cap.registration || {};
  if (reg.kind === "exists") {
    regOk = existsSync(abs(root, expand(reg.path)));
  } else if (reg.kind === "symlink") {
    const link = abs(root, expand(reg.path));
    try { regOk = existsSync(link) && realpathSync(link) === realpathSync(abs(root, reg.target)); } catch { regOk = false; }
  } else if (reg.kind === "contains") {
    const t = readIf(abs(root, reg.path));
    regOk = t !== null && t.includes(reg.marker);
  }
  const testOk = existsSync(abs(root, cap.test));
  let evidenceOk = false;
  if (cap.evidence) {
    const t = readIf(abs(root, cap.evidence.path));
    evidenceOk = t !== null && t.includes(cap.evidence.marker);
  }
  const status = !implOk ? "MISSING" : (!regOk || !testOk ? "DEGRADED" : "GREEN");
  const evidence_level = !implOk ? "E0" : (testOk && evidenceOk ? "E5" : (testOk || evidenceOk ? "E3" : "E2"));
  return {
    id: cap.id,
    purpose: cap.purpose,
    status,
    evidence_level,
    checks: { impl: implOk, registration: regOk, test: testOk, evidence: evidenceOk },
  };
}

export function evaluate(root = REPO, capsPath = CAPS) {
  const caps = JSON.parse(readFileSync(capsPath, "utf8")).capabilities || [];
  const capabilities = caps.map((c) => checkCapability(root, c));
  const counts = { GREEN: 0, DEGRADED: 0, MISSING: 0 };
  for (const c of capabilities) counts[c.status]++;
  return { ts: new Date().toISOString(), repo: root, counts, capabilities };
}

async function selfTest() {
  const { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const root = mkdtempSync(join(tmpdir(), "caps-"));
  mkdirSync(join(root, "scripts"), { recursive: true });
  mkdirSync(join(root, "plugins"), { recursive: true });
  writeFileSync(join(root, "plugins", "a.js"), "// impl a\n");
  writeFileSync(join(root, "scripts", "wired.mjs"), "// imports ./a-import\n");
  writeFileSync(join(root, "scripts", "test-a.mjs"), "// test\n");
  writeFileSync(join(root, "evidence.log"), "verdict loaded\n");
  symlinkSync(join(root, "plugins", "a.js"), join(root, "plugins", "link.js"));
  const caps = {
    capabilities: [
      { id: "a-green", impl: "plugins/a.js", registration: { kind: "contains", path: "scripts/wired.mjs", marker: "./a-import" }, test: "scripts/test-a.mjs", evidence: { path: "evidence.log", marker: "loaded" } },
      { id: "b-degraded", impl: "plugins/a.js", registration: { kind: "contains", path: "scripts/wired.mjs", marker: "NOPE" }, test: "scripts/test-a.mjs" },
      { id: "c-missing", impl: "plugins/nope.js", registration: { kind: "exists", path: "plugins/a.js" }, test: "scripts/test-a.mjs" },
      { id: "d-symlink-green", impl: "plugins/a.js", registration: { kind: "symlink", path: "plugins/link.js", target: "plugins/a.js" }, test: "scripts/test-a.mjs", evidence: { path: "evidence.log", marker: "loaded" } },
    ],
  };
  const capsPath = join(root, "caps.json");
  writeFileSync(capsPath, JSON.stringify(caps));
  const r = evaluate(root, capsPath);
  const by = Object.fromEntries(r.capabilities.map((c) => [c.id, c]));
  const checks = [
    ["impl+registration+test+evidence -> GREEN / E5", by["a-green"].status === "GREEN" && by["a-green"].evidence_level === "E5"],
    ["impl without registration -> DEGRADED", by["b-degraded"].status === "DEGRADED"],
    ["missing impl -> MISSING / E0", by["c-missing"].status === "MISSING" && by["c-missing"].evidence_level === "E0"],
    ["registration by symlink resolves -> GREEN", by["d-symlink-green"].status === "GREEN"],
    ["counts add up", r.counts.GREEN === 2 && r.counts.DEGRADED === 1 && r.counts.MISSING === 1],
  ];
  rmSync(root, { recursive: true, force: true });
  let fail = 0;
  console.log("=== capabilities.mjs --self-test ===");
  for (const [name, ok] of checks) { if (!ok) fail++; console.log((ok ? "  PASS " : "  FAIL ") + name); }
  console.log("result: " + (fail ? "FAIL" : "PASS"));
  return fail ? 1 : 0;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--self-test")) return selfTest();
  const r = evaluate();
  if (argv.includes("--json")) console.log(JSON.stringify(r, null, 2));
  else {
    console.log("=== capabilities ===");
    for (const c of r.capabilities) console.log("  " + c.status.padEnd(8) + " " + c.evidence_level + "  " + c.id);
    console.log("  " + JSON.stringify(r.counts));
  }
  return r.counts.MISSING ? 1 : 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(await main());
}
