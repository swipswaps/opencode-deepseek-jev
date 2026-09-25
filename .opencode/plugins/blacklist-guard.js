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
const RULES = [
  { name: "sed", pattern: "(?:^|[;&|()]\\s*)sed\\s", sev: "block",
    fix: "awk / grep / python3", rule: "#7" },
  { name: "rm -rf", pattern: "(?:^|[;&|()]\\s*)rm\\s+-rf\\b", sev: "block",
    fix: "rm -f on named paths", rule: "convention" },
  { name: "subprocess.run", pattern: "\\bsubprocess\\.run\\s*\\(", sev: "block",
    fix: "subprocess.Popen(..., stdout=PIPE, stderr=PIPE) + communicate()", rule: "convention" },
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

// Return the rules matched by a command string (quote-aware).
export function inspect(command) {
  const bare = stripQuotes(command);
  const hits = [];
  for (const r of RULES) if (r.re.test(bare)) hits.push({ name: r.name, sev: r.sev, fix: r.fix, rule: r.rule });
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

export const BlacklistGuard = async ({ client }) => {
  async function log(level, message, extra) {
    try {
      await client.app.log({ body: { service: "blacklist-guard", level, message, extra } });
    } catch {
      // logging must never break a tool call
    }
  }

  return {
    "tool.execute.before": async (input, output) => {
      const m = mode();
      if (m === "off") return;

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
        await log("error", "blacklist blocked", {
          patterns: blockers.map((h) => h.name),
          command: command.slice(0, 200),
        });
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
          await log("warn", "removed 2>/dev/null so stderr (the proof) is visible", {
            removed: r.count,
            command: r.cmd.slice(0, 200),
          });
        }
      }

      if (warners.length) {
        await log("warn", "blacklist warning (not blocked)", {
          patterns: warners.map((h) => h.name),
          command: command.slice(0, 200),
        });
      }
    },
  };
};
