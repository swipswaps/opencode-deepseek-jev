// blacklist-guard.js — execution-time enforcement of RULES.md "Substitutions
// for the blacklist", aimed at the agent's OWN tool calls during "Thinking".
//
// Detection is not prevention: `lint.sh`/`scan-constraints.py` police the
// files and `scripts/audit-tool-calls.py` reports what the agent already ran.
// This plugin is the missing third layer — it runs inside opencode and acts on
// a blacklisted command BEFORE it executes.
//
// Three verdicts, because the failure modes differ:
//   block  destructive/opaque (`sed`, `rm -rf`, `subprocess.run`): throw and
//          hand the model the substitute so it retries correctly.
//   fix    `2>/dev/null`: *remove the redirect* so stderr — the proof of what
//          went wrong — flows into the tool result. Failing silently is the
//          bug; hiding the failure is what blocks access to the solution.
//   warn   `echo`: log only (RULES #38 is a script rule; ad-hoc echoes are
//          benign).
//
// Registered automatically: any *.js in .opencode/plugins/ is loaded at
// startup. No opencode.json entry needed (adding one would double-load).
// opencode-web runs with working_dir /workspace, so the repo's .opencode/ is
// discovered. Config is read once — restart the container to reload.
//
// Policy (mode = process.env.OPENCODE_BLACKLIST_GUARD):
//   unset | "block"  block destructive, fix `2>/dev/null`, warn echo
//   "warn"           never block or rewrite; log every match
//   "off"            disabled
//
// Matching is quote-aware: `grep 'sed'` is not `sed`. inspect() and
// remediate2devnull() are exported so scripts/blacklist-guard-self-test.mjs
// can assert the discrimination without opencode. Fail-open: a bug in the
// guard must never block a tool call.

// name -> { pattern, sev, fix, rule }. Patterns are strings compiled to RegExp
// so the file keeps no escaped regex literals.
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";

const RULES = [
  { name: "sed", pattern: "(?:^|[;&|()]\\s*)sed\\s", sev: "block",
    fix: "awk / grep / python3", rule: "#7" },
  { name: "rm -rf", pattern: "(?:^|[;&|()]\\s*)rm\\s+-rf\\b", sev: "block",
    fix: "rm -f on named paths", rule: "convention" },
  { name: "subprocess.run", pattern: "\\bsubprocess\\.run\\s*\\(", sev: "block",
    fix: "subprocess.Popen(..., stdout=PIPE, stderr=PIPE) + communicate()", rule: "convention" },
  { name: "pipe-to-shell", pattern: "(?:curl|wget|base64)[^|\\n]*\\|\\s*(?:ba|z|k|da)?sh\\b", sev: "block",
    fix: "download and inspect the script before running it (no curl|sh, no base64|sh)", rule: "security" },
  { name: "2>/dev/null", pattern: "2>\\s*/dev/null", sev: "fix",
    fix: "redirect removed so stderr (the proof) reaches the tool result", rule: "#8" },
  { name: "echo", pattern: "(?:^|[;&|()]\\s*)echo\\s", sev: "warn",
    fix: "printf '%s\\n'", rule: "#38" },
];

for (const r of RULES) r.re = new RegExp(r.pattern);

const REDIRECT_RE = /2>\s*\/dev\/null/g;

// Blank single/double-quoted regions so `grep 'sed'` is not treated as `sed`.
// Preserves string length, so match indices map back onto the original.
export function stripQuotes(cmd) {
  let out = "", quote = null;
  for (const ch of String(cmd || "")) {
    if (quote) {
      if (ch === quote) quote = null;
      out += " ";
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      out += " ";
    } else {
      out += ch;
    }
  }
  return out;
}

// Extract the script text from an interpreter wrapper (`bash -c '…'`,
// `sh -lc "…"`, `python3 -c '…'`, `eval '…'`) so a blacklisted command hidden
// INSIDE the quoted script is still inspected. Quote-stripping alone misses it:
// `bash -c 'sed -i x'` would otherwise pass because `sed` sits inside quotes.
const WRAP_RE = /\b(?:bash|sh|zsh|ksh|dash|python3?)\b\s+(?:-[A-Za-z]+\s+)*?-?[A-Za-z]*c\s+("[^"]*"|'[^']*')|\beval\s+("[^"]*"|'[^']*')/g;
export function innerScripts(command) {
  const out = [];
  const src = String(command || "");
  const bare = stripQuotes(src);
  WRAP_RE.lastIndex = 0;
  let m;
  while ((m = WRAP_RE.exec(src)) !== null) {
    // Skip a wrapper that is itself inside quotes (e.g. echo "bash -c '…'").
    if (bare[m.index] === " ") continue;
    const arg = m[1] || m[2];
    if (arg) out.push(arg.slice(1, -1));
  }
  return out;
}

// Return the rules matched by a command string. The outer command is matched
// quote-aware (`grep 'sed'` passes); any interpreter-wrapped script is matched
// too, so the wrapper cannot smuggle a blocked command past the guard.
export function inspect(command) {
  const hits = [];
  const seen = new Set();
  const scan = (text) => {
    const bare = stripQuotes(text);
    for (const r of RULES) {
      if (!seen.has(r.name) && r.re.test(bare)) {
        seen.add(r.name);
        hits.push({ name: r.name, sev: r.sev, fix: r.fix, rule: r.rule });
      }
    }
  };
  scan(command);
  for (const inner of innerScripts(command)) scan(inner);
  return hits;
}

// Remove unquoted `2>/dev/null` redirects so stderr is no longer suppressed.
// Returns { cmd, count }. Quoted occurrences are left intact.
export function remediate2devnull(command) {
  const src = String(command || "");
  const bare = stripQuotes(src);
  const spans = [];
  let m;
  REDIRECT_RE.lastIndex = 0;
  while ((m = REDIRECT_RE.exec(bare)) !== null) spans.push([m.index, m.index + m[0].length]);
  if (!spans.length) return { cmd: src, count: 0 };
  let last = 0;
  const parts = [];
  for (const [s, e] of spans) {
    parts.push(src.slice(last, s));
    last = e;
  }
  parts.push(src.slice(last));
  return { cmd: parts.join(" "), count: spans.length };
}

function mode() {
  const m = (process.env.OPENCODE_BLACKLIST_GUARD || "block").toLowerCase();
  return (m === "off" || m === "warn") ? m : "block";
}

export const BlacklistGuard = async ({ client, directory }) => {
  // Durable flag: every verdict is appended to data/observability/guard.log
  // (JSONL) so the dashboard and `scripts/logs.sh --source guard` can surface
  // it. This is how blacklisted code used during "Thinking" becomes visible
  // instead of silently succeeding. Best-effort: never break a tool call.
  const GUARD_LOG = (directory ? String(directory).replace(/\/+$/, "") : ".") + "/data/observability/guard.log";
  function record(verdict, message, extra) {
    try {
      mkdirSync(GUARD_LOG.replace(/\/guard\.log$/, ""), { recursive: true });
      appendFileSync(GUARD_LOG, JSON.stringify(Object.assign({ ts: new Date().toISOString(), verdict, message }, extra)) + "\n");
    } catch {
      // logging must never break a tool call
    }
  }
  async function log(level, message, extra) {
    try {
      await client.app.log({ body: { service: "blacklist-guard", level, message, extra } });
    } catch {
      // logging must never break a tool call
    }
  }

  // Learned rules (scripts/learn-rules.py --write): shapes with a high
  // historical failure rate. Advisory only — warn + record, never block. A
  // human promotes a confirmed pattern into RULES.md / the fixed blacklist to
  // make it deterministic. Disable with OPENCODE_LEARNED_GUARD=off.
  const GUARD_LEARNED = (directory ? String(directory).replace(/\/+$/, "") : ".") + "/data/observability/learned-rules.json";
  let learnedCache = { at: 0, set: new Set() };
  function avoidShapes() {
    if (Date.now() - learnedCache.at < 30000) return learnedCache.set;
    const set = new Set();
    try {
      const j = JSON.parse(readFileSync(GUARD_LEARNED, "utf8"));
      for (const x of (j.avoid || [])) if (x && x.shape) set.add(x.shape);
    } catch {
      // no rules yet / unreadable — no advisory
    }
    learnedCache = { at: Date.now(), set };
    return set;
  }
  function commandShape(tool, command) {
    if (tool === "bash" && command) {
      for (const tok of String(command).trim().split(/\s+/)) {
        if (tok.includes("=") && !tok.startsWith("-")) continue;
        return tok;
      }
      return "bash";
    }
    return tool || "?";
  }
  async function learnedAdvisory(input, output) {
    if (process.env.OPENCODE_LEARNED_GUARD === "off") return;
    const set = avoidShapes();
    if (!set.size) return;
    const sh = commandShape(input.tool, output && output.args && output.args.command);
    if (!set.has(sh)) return;
    await log("warn", "learned-avoid shape (advisory)", { shape: sh });
    record("learned", "advisory: shape has a high historical failure rate", { shape: sh });
  }

  return {
    "tool.execute.before": async (input, output) => {
      const m = mode();
      if (m === "off") return;

      try { await learnedAdvisory(input, output); } catch { /* advisory only */ }

      if (input.tool === "write" || input.tool === "edit") {
        // subprocess.run is Python source, so in bash it is always inside a
        // quoted heredoc/`-c` and invisible to quote-stripping. Catch it where
        // it is actually written. Warn only — a file may legitimately mention
        // it in prose (this guard's own RULES.md does).
        const text = String((output && output.args && (output.args.content || output.args.newString)) || "");
        if (/\bsubprocess\.run\s*\(/.test(text)) {
          await log("warn", "subprocess.run written in file content (prefer subprocess.Popen)", { tool: input.tool });
        }
        return;
      }

      if (input.tool !== "bash") return;
      const command = output && output.args && output.args.command;
      if (typeof command !== "string" || !command) return;

      let hits;
      try {
        hits = inspect(command);
      } catch {
        return; // fail open
      }
      if (!hits.length) return;

      const blockers = m === "block" ? hits.filter((h) => h.sev === "block") : [];
      const warners = hits.filter((h) => h.sev === "warn");

      if (blockers.length) {
        const names = blockers.map((h) => h.name);
        await log("error", "blacklist blocked", { patterns: names, command: command.slice(0, 200) });
        record("block", "blocked blacklisted command", { patterns: names, command: command.slice(0, 200) });
        const detail = blockers.map((h) => "- " + h.name + " (rule " + h.rule + "): use " + h.fix).join("\n");
        throw new Error(
          "blacklist-guard blocked this command:\n" + detail +
          "\nThese constructs fail opaquely and hide the evidence needed to fix them. " +
          "See RULES.md \"Substitutions for the blacklist\". " +
          "Set OPENCODE_BLACKLIST_GUARD=warn to downgrade, or =off to disable."
        );
      }

      if (m === "block" && hits.some((h) => h.sev === "fix")) {
        const r = remediate2devnull(output.args.command);
        if (r.count) {
          output.args.command = r.cmd;
          await log("warn", "removed 2>/dev/null so stderr (the proof) is visible", { removed: r.count, command: r.cmd.slice(0, 200) });
          record("fix", "removed 2>/dev/null (stderr restored)", { removed: r.count, command: r.cmd.slice(0, 200) });
        }
      }

      if (warners.length) {
        const names = warners.map((h) => h.name);
        await log("warn", "blacklist warning (not blocked)", { patterns: names, command: command.slice(0, 200) });
        record("warn", "blacklist warning (not blocked)", { patterns: names, command: command.slice(0, 200) });
      }
    },
  };
};
