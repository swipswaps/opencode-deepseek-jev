// blacklist-guard.js — execution-time enforcement of RULES.md "Substitutions
// for the blacklist".
//
// Detection is not prevention: `lint.sh`/`scan-constraints.py` police the
// files and `scripts/audit-tool-calls.py` reports what the agent already ran.
// This plugin is the missing third layer — it runs inside opencode and blocks
// a blacklisted command BEFORE it executes, returning the sanctioned
// substitute to the model so it can retry correctly.
//
// Registered automatically: any *.js in .opencode/plugins/ is loaded at
// startup. No opencode.json entry needed (and adding one would double-load).
//
// Policy (mode = process.env.OPENCODE_BLACKLIST_GUARD):
//   unset | "block"  block sed / 2>/dev/null / subprocess.run / rm -rf; warn echo
//   "warn"           never block; log every match
//   "off"            disabled
//
// Matching is quote-aware: a pattern that is merely *named* (grep 'sed') is
// not a violation; only command-position uses and redirects count. The
// inspect() function is exported so scripts/blacklist-guard-self-test.mjs can
// assert the discrimination without opencode.
//
// Constraints mirror the repo: no dependencies, fail-open (a bug in the
// guard must never block a tool call).

// name -> { pattern, sev, fix, rule }. Patterns are strings compiled to RegExp
// so the file keeps no escaped regex literals.
const RULES = [
  { name: "sed", pattern: "(?:^|[;&|()]\\s*)sed\\s", sev: "block",
    fix: "awk / grep / python3", rule: "#7" },
  { name: "rm -rf", pattern: "(?:^|[;&|()]\\s*)rm\\s+-rf\\b", sev: "block",
    fix: "rm -f on named paths", rule: "convention" },
  { name: "subprocess.run", pattern: "\\bsubprocess\\.run\\s*\\(", sev: "block",
    fix: "subprocess.Popen(..., stdout=PIPE, stderr=PIPE) + communicate()", rule: "convention" },
  { name: "2>/dev/null", pattern: "2>/dev/null", sev: "block",
    fix: "let stderr flow and branch on the failure", rule: "#8" },
  { name: "echo", pattern: "(?:^|[;&|()]\\s*)echo\\s", sev: "warn",
    fix: "printf '%s\\n'", rule: "#38" },
];

for (const r of RULES) r.re = new RegExp(r.pattern);

// Blank single/double-quoted regions so `grep 'sed'` is not treated as `sed`.
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

// Return the rules matched by a command string.
export function inspect(command) {
  const bare = stripQuotes(command);
  const hits = [];
  for (const r of RULES) if (r.re.test(bare)) hits.push({ name: r.name, sev: r.sev, fix: r.fix, rule: r.rule });
  return hits;
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

      const warners = hits.filter((h) => h.sev === "warn");
      const blockers = m === "block" ? hits.filter((h) => h.sev === "block") : [];

      if (warners.length) {
        await log("warn", "blacklist warning (not blocked)", {
          patterns: warners.map((h) => h.name),
          command: command.slice(0, 200),
        });
      }

      if (blockers.length) {
        await log("error", "blacklist blocked", {
          patterns: blockers.map((h) => h.name),
          command: command.slice(0, 200),
        });
        const detail = blockers.map((h) => "- " + h.name + " (rule " + h.rule + "): use " + h.fix).join("\n");
        throw new Error(
          "blacklist-guard blocked this command:\n" + detail +
          "\nSee RULES.md \"Substitutions for the blacklist\". " +
          "Set OPENCODE_BLACKLIST_GUARD=warn to downgrade, or =off to disable."
        );
      }
    },
  };
};
