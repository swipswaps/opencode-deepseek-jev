#!/usr/bin/env node
// notify-sink.mjs — self-hosted webhook sink for sentinel alerts (no third
// party). Replaces the "give me a Slack/Discord URL" requirement: the sink is
// local, so NOTIFY_WEBHOOK can point at http://127.0.0.1:PORT/hook.
//
//   node scripts/notify-sink.mjs [--self-test]
//   env: PORT (8788), HOST (127.0.0.1), SINK_FILE (data/observability/notify-sink.jsonl)
//
//   POST /hook  -> append the JSON body as one JSONL line; 200 {"ok":true}
//   GET  /      -> "notify-sink: N lines" + the last 20 lines
//   GET  /health-> "ok"
// Read the captured alerts at:  ./scripts/notify-sink.mjs (GET) or tail the file.
import { createServer } from "node:http";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url)).replace(/\/+$/, "");
const PORT = Number(process.env.PORT || 8788);
const HOST = process.env.HOST || "127.0.0.1";
const FILE = process.env.SINK_FILE || REPO + "/data/observability/notify-sink.jsonl";

function ensureDir() { try { mkdirSync(dirname(FILE), { recursive: true }); } catch { /* ignore */ } }
function lineFor(body) {
  try { return JSON.stringify({ ts: new Date().toISOString(), body: JSON.parse(body || "{}") }); }
  catch { return JSON.stringify({ ts: new Date().toISOString(), raw: String(body || "").slice(0, 2000) }); }
}

function selfTest() {
  const l = lineFor('{"source":"sentinel","count":2}');
  const ok = l.includes('"count":2') && JSON.parse(l).ts;
  process.stdout.write(ok ? "notify-sink: self-test PASS\n" : "notify-sink: self-test FAIL " + l + "\n");
  process.exit(ok ? 0 : 1);
}
if (process.argv.includes("--self-test")) selfTest();

const server = createServer((req, res) => {
  const url = (req.url || "/").split("?")[0];
  if (req.method === "POST" && url === "/hook") {
    let b = "";
    req.on("data", (c) => { b += c; if (b.length > 1_000_000) req.destroy(); });
    req.on("end", () => {
      ensureDir();
      try { appendFileSync(FILE, lineFor(b) + "\n"); } catch { /* ignore */ }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end('{"ok":true}\n');
    });
    return;
  }
  if (url === "/health") { res.writeHead(200, { "Content-Type": "text/plain" }); res.end("ok\n"); return; }
  if (url === "/") {
    let n = 0, tail = [];
    try { const L = readFileSync(FILE, "utf8").trim().split("\n").filter(Boolean); n = L.length; tail = L.slice(-20); } catch { /* empty */ }
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("notify-sink: " + n + " line(s) -> " + FILE + "\n" + tail.join("\n") + "\n");
    return;
  }
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found\n");
});
server.listen(PORT, HOST, () => console.log("notify-sink listening on http://" + HOST + ":" + PORT + "/hook -> " + FILE));
