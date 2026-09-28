#!/usr/bin/env node
// redact.mjs — strip secrets from text before it leaves the system.
//
// WHY: this repo prints nothing secret, but a leaked value can still be *in the
// transcript* (a tool output, e.g. a stray `/proc/1/environ`). Anything that
// serialises that transcript — `/api/export/session`, the sessions CSV, the
// guard/patterns CSVs — is an exfiltration vector. Rotation is deferred
// (loopback-only, gitignored), so the honest mitigation is a redaction pass at
// the egress points. This is RULES "minimise before egress": better than
// nothing, and it also covers values we never knew leaked.
//
// It is deliberately conservative: it only matches *key shapes* and
// `NAME=value` assignments, so ordinary prose ("risk-management", "disk-usage")
// is untouched. Unit-tested by `--self-test` (offline) and wired into
// test-hygiene.sh.
//
// CLI: `node scripts/redact.mjs` filters stdin→stdout; `--self-test` asserts.

import { fileURLToPath } from "node:url";

export const REDACTION = "[REDACTED]";

// Each rule: [regex, replacement]. Lookbehind/ahead keep boundaries tight so
// substrings inside words are not matched.
const RULES = [
  // DeepSeek-style API keys: sk- followed by a long token, not preceded by an
  // alphanumeric (so "risk-" / "disk-" are safe).
  [/(?<![A-Za-z0-9])sk-[A-Za-z0-9]{20,}/g, REDACTION],
  // Jev-style keys.
  [/apikey_[A-Za-z0-9_]{16,}/g, REDACTION],
  // JWT / Bearer tokens.
  [/\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/g, REDACTION],
  [/(\bBearer\s+)[A-Za-z0-9._~+/=-]{16,}/gi, "$1" + REDACTION],
  // Any SECRET/API_KEY/PASSWORD/TOKEN assignment: keep the name, drop the value.
  [/([A-Za-z0-9_]*(?:API_KEY|PASSWORD|SECRET|TOKEN)\s*[:=]\s*)\S+/gi, "$1" + REDACTION],
];

export function redact(text) {
  let out = String(text ?? "");
  for (const [re, repl] of RULES) out = out.replace(re, repl);
  return out;
}

async function selfTest() {
  const cases = [
    ["sk-" + "a".repeat(30), true],
    ["apikey_" + "b".repeat(30), true],
    ["OPENCODE_SERVER_PASSWORD=629cb8685bc1a6ac3e8759a1ea38218e4c2325d6491c9ccd", true],
    ["JEV_API_KEY=apikey_deadbeefdeadbeefdeadbeef", true],
    ["Authorization: Bearer " + "c".repeat(40), true],
    ["eyJhbGciOiJIUzI1NiJ9." + "d".repeat(20) + ".sig" + "e".repeat(12), true],
    // benign text that must survive
    ["risk-management and disk-usage are normal words", false],
    ["the task is to sketch a disk", false],
    ["export title: Explore tabs, duplicates grouping", false],
  ];
  let fail = 0;
  console.log("=== redact.mjs --self-test ===");
  for (const [s, mustRedact] of cases) {
    const out = redact(s);
    const redacted = out.includes(REDACTION);
    const ok = redacted === mustRedact && (mustRedact ? !out.includes(s.split(/[=:]/).pop().trim()) : out === s);
    if (!ok) fail++;
    console.log((ok ? "  PASS " : "  FAIL ") + JSON.stringify(s.slice(0, 40)) + (mustRedact ? " -> redacted" : " -> unchanged") + (ok ? "" : "  got=" + JSON.stringify(out)));
  }
  console.log("result: " + (fail ? "FAIL" : "PASS"));
  return fail ? 1 : 0;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--self-test")) return selfTest();
  // stdin -> stdout filter
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  process.stdout.write(redact(Buffer.concat(chunks).toString("utf8")));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(await main());
}
