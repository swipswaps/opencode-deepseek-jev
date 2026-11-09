// permission-memory-self-test.mjs — prove the repeat-memory rules without the
// plugin loader: same command+session is allowed after execution, deny is
// preserved, different command/session stays ask, and the telemetry line lands.
import { PermissionMemory } from "../.opencode/plugins/permission-memory.js";
import { normalizeCommand, memoryKey } from "./permission-memory-lib.mjs";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let fail = 0;
const check = (name, ok) => {
    if (!ok) fail++;
    console.log((ok ? "  PASS " : "  FAIL ") + name);
};

check("normalize collapses whitespace", normalizeCommand("  a   b\t c ") === "a b c");
check("key needs a command", memoryKey("s", "bash", {}) === null);
check("key is session+type+command", memoryKey("s", "bash", { command: "x  y" }) === "s|bash|x y");

const dir = mkdtempSync(join(tmpdir(), "pm-"));
const logFile = join(dir, "guard.log");
process.env.PERMISSION_MEMORY_LOG = logFile;
writeFileSync(logFile, "");

const hooks = await PermissionMemory();
const S = "s_pm_1";
const cmd = "sudo systemctl restart nebula";

const first = { status: "ask" };
await hooks["permission.ask"]({ type: "bash", sessionID: S, metadata: { command: cmd }, pattern: "*ssh *" }, first);
check("first ask is not auto-allowed", first.status === "ask");

await hooks["tool.execute.after"]({ tool: "bash", sessionID: S, args: { command: cmd } }, {});
const repeat = { status: "ask" };
await hooks["permission.ask"]({ type: "bash", sessionID: S, metadata: { command: cmd }, pattern: "*ssh *" }, repeat);
check("repeat ask becomes allow", repeat.status === "allow");

const denied = { status: "deny" };
await hooks["permission.ask"]({ type: "bash", sessionID: S, metadata: { command: cmd } }, denied);
check("deny is preserved", denied.status === "deny");

const otherCmd = { status: "ask" };
await hooks["permission.ask"]({ type: "bash", sessionID: S, metadata: { command: "ls -la" } }, otherCmd);
check("different command stays ask", otherCmd.status === "ask");

const otherSession = { status: "ask" };
await hooks["permission.ask"]({ type: "bash", sessionID: "s_pm_2", metadata: { command: cmd } }, otherSession);
check("different session stays ask", otherSession.status === "ask");

let logged = "";
try {
    logged = readFileSync(logFile, "utf8");
} catch {}
check("repeat-allow is logged", logged.includes('"action":"allow-repeat"'));

rmSync(dir, { recursive: true, force: true });
console.log("result: " + (fail ? "FAIL" : "PASS"));
process.exit(fail ? 1 : 0);
