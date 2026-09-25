// blacklist-guard-self-test.mjs — assert the guard's matcher discriminates.
//
// Imported by test-hygiene.sh. Kept as .mjs (not .sh) so the literal patterns
// under test do not trip lint.sh's RULES grep over scripts/*.sh. The plugin
// file is ESM (see .opencode/package.json {"type":"module"}).
import { inspect, stripQuotes } from "../.opencode/plugins/blacklist-guard.js";

const has = (cmd, name) => inspect(cmd).some((h) => h.name === name);

const cases = [
  ["sed -n '1,3p' file", "sed", true],
  ["grep 'sed' file", "sed", false],
  ["echo x | sed 's/x/y/'", "sed", true],
  ["ls -la 2>/dev/null", "2>/dev/null", true],
  ["ls -la 2>&1", "2>/dev/null", false],
  ["rm -rf /tmp/x", "rm -rf", true],
  ["rm -f /tmp/x", "rm -rf", false],
  ["echo hello", "echo", true],
  ["printf '%s\\n' hello", "echo", false],
  ["grep 'rm -rf' .", "rm -rf", false],
];

let fail = 0;
console.log("=== blacklist-guard-self-test.mjs ===");
for (const [cmd, name, want] of cases) {
  const got = has(cmd, name);
  const ok = got === want;
  if (!ok) fail++;
  console.log((ok ? "  PASS " : "  FAIL ") + JSON.stringify(cmd) + " -> " + name + "=" + got + " (want " + want + ")");
}

const stripped = stripQuotes("grep 'sed' x");
if (stripped.includes("sed")) {
  fail++;
  console.log("  FAIL stripQuotes left a quoted pattern: " + JSON.stringify(stripped));
} else {
  console.log("  PASS stripQuotes blanks quoted regions");
}

console.log("result: " + (fail ? "FAIL" : "PASS"));
process.exit(fail ? 1 : 0);
