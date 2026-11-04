export const IS_DEMO =
  typeof window !== "undefined" &&
  (window.location.hostname.endsWith(".github.io") ||
    new URLSearchParams(window.location.search).get("demo") === "1");

const TOOLS = ["bash", "read", "grep", "edit", "webfetch", "pytest", "npm"];
const COMMANDS = [
  "npm run build",
  "pytest -q tests/",
  "rg \"TODO|FIXME\" src",
  "git status --short",
  "node scripts/check.mjs",
  "curl -fsS http://127.0.0.1:5099/api/health",
  "find . -name '*.tsx' -maxdepth 3",
];
const TEXT = [
  "Build passes; the Pages workflow is queued.",
  "The health probe recovered after the worker restarted.",
  "Reviewing the mobile layout at 390 px.",
  "Search result ranked the fix above the stale snippet.",
  "Session export is redacted before download.",
  "The access token stays in the server environment; it is never rendered.",
  "Cost trend is grouped by local day.",
];
const TITLES = [
  "Gated recovery diagnose and full apply",
  "Audit notes and repo next steps",
  "PhD-Level Repository Audit",
  "Starting OpenCode Docker on 4096 and 5099",
  "Docs and Pages deployment review",
  "Activity timeline compactness pass",
];

let n = 0;
export function makeDemoEvent(ts = Date.now(), i = 0) {
  const k = (n + i) % 9;
  if (k === 0 || k === 5) {
    return {
      ts,
      te: ts + 1200,
      type: "tool",
      tool: TOOLS[(n + i) % TOOLS.length],
      status: k === 0 ? "completed" : "running",
      cmd: COMMANDS[(n + i) % COMMANDS.length],
    };
  }
  if (k === 1) return { ts, te: ts + 900, type: "reasoning", text: TEXT[(n + i) % TEXT.length] };
  if (k === 2) return { ts, te: ts + 700, type: "text", text: TEXT[(n + i + 2) % TEXT.length] };
  if (k === 3) return { ts, te: ts + 1, type: "step-start" };
  if (k === 4) return { ts, te: ts + 1, type: "step-finish" };
  if (k === 6) return { ts, te: ts + 220, type: "tool", tool: "read", status: "completed", cmd: "src/components/ActivityTimeline.jsx" };
  if (k === 7) return { ts, te: ts + 430, type: "tool", tool: "grep", status: "completed", cmd: "PAGES_BASE" };
  return { ts, te: ts + 1800, type: "tool", tool: "bash", status: "error", cmd: "npm run deploy -- --dry-run" };
}

export const demoActivity = Array.from({ length: 40 }, (_, i) =>
  makeDemoEvent(Date.now() - i * 45000, i),
);

const model = JSON.stringify({ id: "deepseek-v4.1-flash", providerID: "opencode-go", variant: "default" });
const start = Date.now() - 1000 * 60 * 60 * 7;

export const demoSessions = TITLES.map((title, i) => ({
  id: `ses_demo_${i + 1}`,
  title,
  model,
  agent: "build",
  directory: "/home/demo/opencode",
  cost: [1.7, 0.028, 0.2829, 0.0088, 0.0041, 0.019][i],
  tokens_input: [2890000, 73200, 624900, 46800, 88000, 152000][i],
  tokens_output: [287100, 7400, 33500, 1200, 4200, 9100][i],
  tokens_reasoning: [487000, 9300, 28100, 1100, 2200, 5100][i],
  tokens_cache_read: [293000000, 701568, 21400000, 121000, 480000, 900000][i],
  time_created: start + i * 3600000,
  time_updated: start + i * 3600000 + 1800000,
  p_start: start + i * 3600000,
  p_end: start + i * 3600000 + 1800000,
}));

export const demoCost = {
  totals: { n: 123, c: 17.42, i: 158995098, o: 4949436, r: 5741309, cr: 5334090661 },
  sessions: demoSessions,
  latest: demoSessions[0].title,
  active: true,
  cached: false,
};

export const demoTodos = [
  { content: "Verify GitHub Pages deploy and monitor the run", status: "completed", priority: "high", session_id: "ses_demo_1" },
  { content: "Review mobile Activity timeline at 390 px", status: "completed", priority: "medium", session_id: "ses_demo_2" },
  { content: "Add a public demo dataset to the Pages build", status: "in_progress", priority: "high", session_id: "ses_demo_3" },
  { content: "Compare the now/relative-duration axis against the legacy view", status: "pending", priority: "medium", session_id: "ses_demo_4" },
];

export const demoHealth = {
  ts: new Date().toISOString(),
  counts: { sessions_scanned: 40, running_tools: 0, findings: 2, dead_tools: 1, blank_tails: 1 },
  findings: [
    { kind: "dead_tool", tool: "bash", session: "ses_demo_old_1", command: "legacy migration" },
    { kind: "dead_blank", tool: "?", session: "ses_demo_old_2", command: "empty response" },
  ],
  risks: { available: true, over: [], denied: [] },
};

export function demoSnapshot() {
  return { cost: demoCost, activity: demoActivity, todos: demoTodos, shed: false };
}

