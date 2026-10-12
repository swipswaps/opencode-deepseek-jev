#!/usr/bin/env node
// repo-mcp.mjs — minimal MCP (stdio) wrapper over the repo's read-only tools.
// rea-style pattern: one MCP server so any agent (opencode, Claude, Codex)
// calls probe/recall/findings/cost as tools instead of pasted shell.
// Tools are read-only: probe_status, recall_sessions, findings, cost.
// No dependencies (Node 22): JSON-RPC over stdio, newline-delimited.
// Usage: node scripts/repo-mcp.mjs  (add to opencode.json mcp.servers)
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("..", import.meta.url)).replace(/\/+$/, "");
const TOOLS = {
  probe_status: { cmd: ["bash", ["scripts/probe-diagnose.sh"]], what: "Full PASS check with telemetry (may take ~1 min)." },
  recall_sessions: { cmd: ["python3", ["scripts/recall-sessions.py"]], what: "Keyword recall over sessions. args: {keyword}." },
  findings: { cmd: ["bash", ["scripts/ux-findings.sh"]], what: "Guided :5099 findings in plain language." },
  cost: { cmd: ["bash", ["scripts/cost.sh"]], what: "Cost accounting headline." },
};

function run(cmd, args) {
  return new Promise((resolve) => {
    execFile(cmd, args, { cwd: REPO, timeout: 120000, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => resolve(String(stdout || "") + (err ? "\n[exit " + (err.code || "?") + "] " + String(stderr || "").slice(0, 300) : "")));
  });
}

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk;
  const lines = buf.split("\n");
  buf = lines.pop();
  for (const line of lines) {
    if (!line.trim()) continue;
    let msg = null;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.method === "initialize") {
      reply(msg.id, { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "repo-tools", version: "1" } });
    } else if (msg.method === "tools/list") {
      reply(msg.id, { tools: Object.entries(TOOLS).map(([name, t]) => ({ name, description: t.what, inputSchema: { type: "object", properties: { keyword: { type: "string" } } } })) });
    } else if (msg.method === "tools/call") {
      const name = msg.params && msg.params.name;
      const t = TOOLS[name];
      if (!t) { reply(msg.id, { content: [{ type: "text", text: "unknown tool: " + name }], isError: true }); continue; }
      const args = name === "recall_sessions"
        ? [...t.cmd[1].slice(0, 1), String((msg.params.arguments && msg.params.arguments.keyword) || "mesh"), "--limit", "5"]
        : t.cmd[1];
      const text = await run(t.cmd[0], args);
      reply(msg.id, { content: [{ type: "text", text: text.slice(0, 8000) }] });
    } else if (String(msg.method || "").startsWith("notifications/")) {
      continue;
    } else if (msg.id !== undefined) {
      reply(msg.id, {});
    }
  }
});
