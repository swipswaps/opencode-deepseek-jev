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
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// The observability directory is anchored to THIS file's location, not to the
// session/project `directory` opencode passes in. Interactive sessions can run
// with a different project root (e.g. /home/node/.opencode), which made the
// guard write its log somewhere that never got read — making a mis-load
// indistinguishable from "no matches yet". Anchor to <repo>/data/observability.
const DEFAULT_OBS = fileURLToPath(new URL("../../data/observability/", import.meta.url)).replace(/\/+$/, "");

// Semantic layer (durable-pi's beforeTool guard): beyond the fixed PATTERN
// rules below, ask the cheap SubQ classifier whether a command is
// irreversible/destructive, and block it if so. Best-effort + FAIL-OPEN: any
// error (missing script, no key, network, timeout) leaves the command alone —
// exactly like durable-pi's jev-damage-control ("unreachable guard runs the
// command"). Verdicts are memoized in guard-classify.py, so a repeated command
// is free. OPT-IN: it uploads command text to api.subq.ai, so it runs only
// with OPENCODE_SEMANTIC_GUARD=on. guard-classify.py also redacts secret
// shapes before the request.
const REPO = fileURLToPath(new URL("../../", import.meta.url)).replace(/\/+$/, "");
const SEM_SCRIPT = REPO + "/scripts/guard-classify.py";
const SEM_ENV = REPO + "/.env.local";
export function semanticVerdict(command) {
  try {
    execFileSync("python3",
      [SEM_SCRIPT, "--command", String(command), "--json", "--env-file", SEM_ENV],
      { encoding: "utf8", timeout: 15000 });
    return { block: false };
  } catch (e) {
    const out = String((e && e.stdout) || "");
    try {
      const j = JSON.parse(out);
      if (j && j.verdict === "BLOCK") return { block: true, verdict: j };
    } catch { /* not a structured block -> allow */ }
    return { block: false };
  }
}

const RULES = [
  { name: "env-read", pattern: "(?:^|[;&|()]\\s*)(?:cat|less|more|head|tail|nl|xxd|od|strings|base64|cp|tar|dd|scp|rsync|install)\\b[^\\n]*\\.env", sev: "block", raw: true,
    fix: "never print .env: use awk -F= '/^KEY=/{print length($2)}' .env.local, or the rotate scripts (they mask)", rule: "security" },
  { name: "env-grep", pattern: "(?:^|[;&|()]\\s*)grep\\s+(?![^\\n]*(?:\\s*-[A-Za-z]*[qc]\\b|\\s*--count\\b|\\s*--quiet\\b))[^\\n]*\\.env", sev: "block", raw: true,
    fix: "grep -c/-q only (count/match, no value); otherwise awk length or the rotate scripts", rule: "security" },
  { name: "sensitive-read", pattern: "(?:^|[;&|()]\\s*)(?:sudo\\s+)?(?:cat|less|more|head|tail|nl|xxd|od|strings|grep|awk|base64|cp|cut|tar|dd|scp|rsync|install)\\b[^\\n]*(?:/etc/(?:passwd|shadow|sudoers|gshadow)|(?:^|/)\\.ssh/|(?:^|/)\\.aws/credentials|/proc/[0-9]+/environ|(?:^|/)docker/certs/|(?:^|/)litellm-db\\.env)", sev: "block", raw: true,
    fix: "read only inside /workspace; ask the operator for host files", rule: "security" },
  { name: "secret-interpreter-read", pattern: "(?:^|[;&|()]\\s*)(?:python3?|node|ruby|perl|php)\\b[^\\n]*(?:\\.env(?:\\.local)?|(?:^|/)docker/certs/|(?:^|/)litellm-db\\.env)", sev: "block", raw: true,
    fix: "read only inside /workspace; ask the operator for secrets", rule: "security" },
  { name: "config-dump", pattern: "(?:^|[;&|()]\\s*)(?:[^\\s;&|()]*/)?(?:sudo\\s+)?(?:npx\\s+)?opencode\\s+debug\\s+config\\b", sev: "block",
    fix: "resolved config substitutes {env:...} with plaintext; never dump it into a logged terminal — use provider metadata or a redacted view", rule: "security" },
  { name: "sed", pattern: "(?:^|[;&|()]\\s*)sed\\s", sev: "block",
    fix: "python3, then awk, then grep/find; cat/curl to read — prefer all of these before sed", rule: "#7" },
  { name: "rm -rf", pattern: "(?:^|[;&|()]\\s*)rm\\s+(?:-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r|-[rR]\\s+-[fF]|-[fF]\\s+-[rR]|--recursive\\s+--force|--force\\s+--recursive)\\b", sev: "block",
    fix: "rm -f on named paths", rule: "convention" },
  // The rest of the RULES.md blacklist that the guard used to omit.
  { name: "set -e", pattern: "(?:^|[;&|()]\\s*)set\\s+(?:-[A-Za-z]*e[A-Za-z]*\\b|-o\\s+errexit\\b)", sev: "block",
    fix: "set -o pipefail + explicit per-step handling", rule: "#5" },
  { name: "exit 1", pattern: "(?:^|[;&|()]\\s*)exit\\s+1(?![0-9])", sev: "block",
    fix: "main() wrapper returning a code; final line main \"$@\"", rule: "convention" },
  { name: "kill N", pattern: "(?:^|[^0-9])kill\\s+[1-9][0-9]*(?![0-9])", sev: "block",
    fix: "signal explicitly: kill -TERM / -INT / -KILL", rule: "convention" },
  { name: "subprocess.run", pattern: "\\bsubprocess\\.run\\s*\\(", sev: "block",
    fix: "subprocess.Popen(..., stdout=PIPE, stderr=PIPE) + communicate()", rule: "convention" },
  { name: "pipe-to-shell", pattern: "(?:curl|wget|base64)[^|\\n]*\\|\\s*(?:sudo\\s+)?(?:ba|z|k|da|fi)?sh\\b", sev: "block",
    fix: "download and inspect the script before running it (no curl|sh, no base64|sh)", rule: "security" },
  { name: "pipe-to-interp", pattern: "(?:curl|wget|base64)[^|\\n]*\\|\\s*(?:sudo\\s+)?(?:python3?|node|perl|ruby|php)\\b", sev: "block",
    fix: "download and inspect the script before running it; never pipe a download into an interpreter", rule: "security" },
  { name: "source-process-sub", pattern: "(?:^|[;&|()]\\s*)(?:source|\\.|bash|sh|zsh|ksh|dash)\\s+<\\(\\s*(?:curl|wget)", sev: "block",
    fix: "download to a file, inspect it, then run it (no source <(curl ...))", rule: "security" },
  { name: "subprocess-import", pattern: "from\\s+subprocess\\s+import\\s+(?:run|\\*)|getattr\\s*\\(\\s*subprocess\\s*,\\s*['\"]run|asyncio\\.create_subprocess_", sev: "block", raw: true,
    fix: "import subprocess and use subprocess.Popen(..., stdout=PIPE, stderr=PIPE)", rule: "convention" },
  { name: "2>/dev/null", pattern: "2>>?\\s*/dev/null", sev: "fix",
    fix: "redirect removed so stderr (the proof) reaches the tool result", rule: "#8" },
  // #8 evasion family: `2>/dev/null` is auto-removed above, but these spell the
  // same "hide stderr" intent so the remover misses them. Block outright.
  { name: "&>/dev/null", pattern: "&>>?\\s*/dev/null", sev: "block",
    fix: "&> discards stdout AND stderr; redirect only stdout with >/dev/null and let stderr flow", rule: "#8" },
  { name: ">/dev/null 2>&1", pattern: "(?:^|[^0-9])1?>>?\\s*/dev/null\\s+2\\s*>&\\s*1", sev: "block",
    fix: "stdout->/dev/null then 2>&1 sends stderr there too; never hide stderr (the proof) — keep it visible or capture it and print it", rule: "#8" },
  { name: "exec 2>/dev/null", pattern: "\\bexec\\s+2\\s*>>?\\s*/dev/null", sev: "block",
    fix: "do not permanently discard stderr; capture it into a variable you print", rule: "#8" },
  { name: "echo", pattern: "(?:^|[;&|()]\\s*)echo\\s", sev: "warn",
    fix: "printf '%s\\n'", rule: "#38" },
];

for (const r of RULES) r.re = new RegExp(r.pattern);

// Prompt-injection tripwire for tool RESULTS (untrusted data, never
// instructions). Advisory only: it records a value-free marker so the
// dashboard/logs can surface the attempt. The actual defense remains the
// approval policy + jev-guard's from-untrusted risk score.
const INJECTION_PATTERNS = [
  ["ignore-previous", /ignore\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above)\s+instructions/i],
  ["system-override", /system\s+override/i],
  ["disregard", /disregard\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above)/i],
  ["reveal-prompt", /(?:reveal|print|show)\s+(?:your|the)\s+(?:system\s+)?(?:prompt|instructions)/i],
  ["jevpwned", /JEVPWNED/i],
];
export function injectionVerdict(text) {
  const s = String(text ?? "");
  for (const [name, re] of INJECTION_PATTERNS) if (re.test(s)) return name;
  return "";
}

const REDIRECT_RE = /2>>?\s*\/dev\/null/g;

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

// Split a command line at unquoted shell separators. This is a boundary finder,
// not a full shell parser: its job is to stop the `&& sed`, `; sed`, newline,
// subshell, and `| sh` evasions that a single `^` anchor misses.
export function segments(command) {
  const src = String(command || "");
  const out = [];
  let cur = "", quote = null;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quote) {
      cur += ch;
      if (ch === quote && src[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (";|&\n(){}".includes(ch)) { out.push(cur); cur = ""; continue; }
    cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

// Wrapper programs that prefix the real executable, plus the flags that take
// a separate value. Kept small on purpose: over-skipping would hide the
// command we are trying to inspect.
const WRAPPERS = new Set(["sudo", "doas", "command", "builtin", "exec", "nohup", "nice", "time", "stdbuf", "xargs", "busybox", "env"]);
const VALUE_FLAGS = new Set(["-u", "-g", "-n", "-I", "-L", "-P", "-s", "-e", "-C", "-t", "-c", "-o"]);

// Resolve one segment to its executable word: unwrap wrappers, drop
// VAR=value assignments and wrapper options, de-backslash, dequote the first
// word, and take the basename. This is what catches `/usr/bin/sed`,
// `sudo sed`, `"sed"`, `\sed`, `se\d`, `xargs sed`, and `busybox sed`.
export function execWord(segment) {
  const s = String(segment || "").replace(/\\+(?=[A-Za-z])/g, "");
  const toks = s.match(/"[^"]*"|'[^']*'|\S+/g) || [];
  const unq = (t) => t.replace(/^["']|["']$/g, "");
  let i = 0;
  while (i < toks.length) {
    const w = unq(toks[i]);
    if (!WRAPPERS.has(w)) return w.replace(/^.*\//, "");
    i++;
    while (i < toks.length) {
      const n = unq(toks[i]);
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(n)) { i++; continue; }
      if (n.startsWith("-")) {
        const flag = n;
        i++;
        if (VALUE_FLAGS.has(flag) && i < toks.length && !unq(toks[i]).startsWith("-")) i++;
        continue;
      }
      break;
    }
  }
  return "";
}

function hasRecursiveForce(segment) {
  const flags = (String(segment).match(/(?:^|\s)(--?[A-Za-z-]+)/g) || []).map((x) => x.trim());
  const rec = flags.some((f) => /^(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)$/.test(f));
  const force = flags.some((f) => /^(?:-[A-Za-z]*[fF][A-Za-z]*|--force)$/.test(f));
  return rec && force;
}

// Return the rules matched by a command string. The outer command is matched
// quote-aware (`grep 'sed'` passes); interpreter-wrapped scripts and every
// shell segment's executable word are matched too, so wrappers and separators
// cannot smuggle a blocked command past the guard.
export function inspect(command) {
  const hits = [];
  const seen = new Set();
  const add = (name) => {
    if (seen.has(name)) return;
    const r = RULES.find((x) => x.name === name);
    if (!r) return;
    seen.add(name);
    hits.push({ name: r.name, sev: r.sev, fix: r.fix, rule: r.rule });
  };
  const scan = (text) => {
    const bare = stripQuotes(text);
    for (const r of RULES) {
      if (!seen.has(r.name) && r.re.test(r.raw ? text : bare)) add(r.name);
    }
  };
  scan(command);
  for (const inner of innerScripts(command)) scan(inner);

  for (const seg of segments(command)) {
    const w = execWord(seg);
    if (w === "sed") add("sed");
    if (w === "rm" && hasRecursiveForce(seg)) add("rm -rf");
    if (w === "opencode" && /\bdebug\s+config\b/.test(seg)) add("config-dump");
    const execFlag = seg.match(/(?:^|\s)-exec\s+("[^"]*"|'[^']*'|\S+)/);
    if (w === "find" && execFlag && /(?:^|\/)sed$/.test(execFlag[1].replace(/^["']|["']$/g, ""))) add("sed");
  }
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

// ---------------------------------------------------------------------------
// Assistant OUTPUT (prose) enforcement. `experimental.text.complete` gives the
// final text part; scan CODE SPANS (fenced blocks + inline code) with the same
// RULES. Fenced blocks are fully remediated (2>/dev/null removed, block rules
// replaced with a visible marker). Inline code is only rewritten for
// block-severity rules, so a sentence that explains `2>/dev/null` survives.
// Prose is otherwise untouched. Fail-open; only pattern names are logged.
// ---------------------------------------------------------------------------
const FENCED_RE = /```([^\n]*)\n([\s\S]*?)```/g;
const INLINE_RE = /`([^`\n]+)`/g;

function processCode(code, mode) {
  const patterns = new Set();
  let removed = 0, blocked = 0, changed = false;
  const out = String(code).split("\n").map((line) => {
    let hits;
    try { hits = inspect(line); } catch { return line; }
    if (!hits.length) return line;
    hits.forEach((h) => patterns.add(h.name));
    let next = line;
    if (mode === "block" && hits.some((h) => h.sev === "fix")) {
      const r = remediate2devnull(next);
      if (r.count) { next = r.cmd; removed += r.count; changed = true; }
    }
    const blocks = mode === "block" ? hits.filter((h) => h.sev === "block") : [];
    if (blocks.length) {
      next = "[blacklist-guard blocked " + blocks.map((h) => h.name).join(", ") +
        " - use " + blocks.map((h) => h.fix).join("; ") + "]";
      blocked += blocks.length;
      changed = true;
    }
    return next;
  });
  return { code: out.join("\n"), patterns: [...patterns], removed, blocked, changed };
}

export function remediateProse(text, mode = "block") {
  const patterns = new Set();
  let removed = 0, blocked = 0, changed = false;
  let out = String(text || "").replace(FENCED_RE, (_m, lang, body) => {
    const r = processCode(body, mode);
    r.patterns.forEach((p) => patterns.add(p));
    removed += r.removed; blocked += r.blocked; changed = changed || r.changed;
    return "```" + lang + "\n" + r.code + "```";
  });
  out = out.replace(INLINE_RE, (m, code) => {
    if (mode !== "block") return m;
    let hits;
    try { hits = inspect(code).filter((h) => h.sev === "block"); } catch { return m; }
    if (!hits.length) return m;
    hits.forEach((h) => patterns.add(h.name));
    blocked += hits.length; changed = true;
    return "[blacklist-guard blocked " + hits.map((h) => h.name).join(", ") +
      " - use " + hits.map((h) => h.fix).join("; ") + "]";
  });
  return { text: out, changed, removed, blocked, patterns: [...patterns] };
}

function mode() {
  const m = (process.env.OPENCODE_BLACKLIST_GUARD || "block").toLowerCase();
  return (m === "off" || m === "warn") ? m : "block";
}

export const BlacklistGuard = async ({ client, directory }, options) => {
  // Deduplicate double-loading. For a $HOME-rooted session the same file is
  // registered twice (the global plugin dir symlink AND /workspace/opencode.json
  // auto-appending the project plugin), and /config lists both. Without this,
  // every hook runs twice (double warns, wasted work). `options.force` lets the
  // self-test build a second, independent instance.
  if (globalThis.__opencodeBlacklistGuardRegistered && !(options && options.force)) {
    return {};
  }
  globalThis.__opencodeBlacklistGuardRegistered = true;

  // Durable flag: every verdict is appended to data/observability/guard.log
  // (JSONL) so the dashboard and `scripts/logs.sh --source guard` can surface
  // it. This is how blacklisted code used during "Thinking" becomes visible
  // instead of silently succeeding. Best-effort: never break a tool call.
  //
  // Location: tests pass options.logDir; runtime anchors to the plugin's own
  // repo (DEFAULT_OBS) so the file is always the one the dashboard reads.
  const OBS_DIR = (options && options.logDir) || DEFAULT_OBS;
  const GUARD_LOG = OBS_DIR + "/guard.log";
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

  // Heartbeat: a load marker proves the plugin is wired, independent of
  // whether any blacklisted command has run. Without it, "guard missing" and
  // "guard idle" look identical on disk. Appended once per process.
  if (!globalThis.__opencodeBlacklistGuardLoaded) {
    globalThis.__opencodeBlacklistGuardLoaded = true;
    record("loaded", "blacklist-guard registered", { log: GUARD_LOG, mode: mode() });
  }

  // Learned rules (scripts/learn-rules.py --write): shapes with a high
  // historical failure rate. Advisory only — warn + record, never block. A
  // human promotes a confirmed pattern into RULES.md / the fixed blacklist to
  // make it deterministic. Disable with OPENCODE_LEARNED_GUARD=off.
  const GUARD_LEARNED = OBS_DIR + "/learned-rules.json";
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
        // Deterministic pre-check for the most recurring Thinking error: an
        // `edit` whose oldString does not occur in the target file (13/13 of
        // this repo's edit errors are this). The model proposes oldString from
        // *modelled* context; edits shift content. Record an advisory (never
        // block — the tool already fails safe) so it becomes durable telemetry
        // for logs.sh --source guard and learn-rules.py.
        if (input.tool === "edit") {
          try {
            const fp = output && output.args && output.args.filePath;
            const old = output && output.args && output.args.oldString;
            if (typeof fp === "string" && typeof old === "string" && old) {
              const content = readFileSync(fp, "utf8");
              if (!content.includes(old)) {
                record("advisory", "edit oldString not found — re-read the region (edits shift content)", { file: fp, session: input.sessionID });
                await log("warn", "edit oldString pre-check failed (re-read the region)", { file: fp });
              }
            }
          } catch { /* fail open: unreadable file / missing args */ }
        }
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

      // First time the hook actually runs for a bash call, record it. This is
      // the proof that opencode is invoking tool.execute.before (the `loaded`
      // heartbeat only proves the module imported).
      if (!globalThis.__opencodeBlacklistGuardHooked) {
        globalThis.__opencodeBlacklistGuardHooked = true;
        record("hook", "tool.execute.before invoked for bash", { sample: command.slice(0, 120) });
      }

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

      // Semantic layer: OPT-IN. It uploads the command text to a third-party
      // classifier (api.subq.ai) before execution, which is a confidentiality
      // risk, so it runs only when the operator sets OPENCODE_SEMANTIC_GUARD=on.
      if (m === "block" && process.env.OPENCODE_SEMANTIC_GUARD === "on") {
        let sv = { block: false };
        try { sv = semanticVerdict(command); } catch { /* fail open */ }
        if (sv.block) {
          const p = sv.verdict && sv.verdict.noul;
          record("block", "semantic guard blocked irreversible command", { command: command.slice(0, 200), noul: p });
          await log("error", "semantic guard blocked (irreversible)", { command: command.slice(0, 200), noul: p });
          throw new Error(
            "semantic-guard blocked this command as irreversible/destructive" +
            (p != null ? (" (subq noul=" + p + ")") : "") +
            ".\nSplit it, use a reversible form, or confirm intent. " +
            "The semantic layer is opt-in; unset OPENCODE_SEMANTIC_GUARD (or set it to off) to disable."
          );
        }
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
    "tool.execute.after": async (input, output) => {
      try {
        const text = String((output && (output.result || output.output || output.text)) || "");
        const marker = injectionVerdict(text);
        if (marker) record("injection", "prompt-injection marker in tool result", { tool: input && input.tool, marker });
      } catch { /* fail open */ }
    },
    "experimental.text.complete": async (input, output) => {
      const m = mode();
      if (m === "off") return;
      try {
        const r = remediateProse(String((output && output.text) || ""), m);
        if (m === "block") {
          if (!r.changed) return;
          output.text = r.text;
          const detail = { patterns: r.patterns, removed: r.removed, blocked: r.blocked, part: input && input.partID };
          record("prose", "rewrote blacklisted construct in assistant code", detail);
          await log("warn", "blacklisted construct in assistant code; rewritten", detail);
        } else if (r.patterns.length) {
          const detail = { patterns: r.patterns, part: input && input.partID };
          record("prose-warn", "blacklisted construct in assistant code (warn; not rewritten)", detail);
          await log("warn", "blacklisted construct in assistant code (warn mode)", detail);
        }
      } catch { /* fail open */ }
    },
  };
};
