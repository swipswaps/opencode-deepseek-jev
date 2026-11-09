// permission-memory.js — session-scoped repeat memory for approved bash commands.
//
// Goal: after the user approves an operation once (e.g. a script --apply that
// sets off jev-guard's prompt), do not prompt for the exact same normalized
// command again in the same session.
//
// Safety rules:
//   - Only bash.
//   - Only downgrades the current status from "ask" to "allow"; never touches
//     "deny" (jev-guard's deny stays deny).
//   - Only commands that actually executed (tool.execute.after) are remembered,
//     so a blocked/denied command is never cached.
//   - Keyed by sessionID + type + the exact normalized command; a broad
//     permission pattern is never used as the key.
//   - Session-scoped in memory; cleared on process restart.
//   - Disable with PERMISSION_MEMORY=off.
//
// Telemetry: one JSON line per repeat-allow to data/observability/guard.log
// (override with PERMISSION_MEMORY_LOG).
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OFF = String(process.env.PERMISSION_MEMORY ?? "").toLowerCase() === "off";
const seen = new Map();

export function normalizeCommand(cmd) {
    return String(cmd ?? "").replace(/\s+/g, " ").trim();
}

export function memoryKey(sessionID, type, metadata) {
    const cmd = normalizeCommand(metadata?.command ?? "");
    if (!cmd) return null;
    return [sessionID ?? "-", String(type ?? "-").toLowerCase(), cmd].join("|");
}

function log(rec) {
    try {
        const override = process.env.PERMISSION_MEMORY_LOG;
        let file = override;
        if (!file) {
            const here = dirname(fileURLToPath(import.meta.url));
            file = join(here, "..", "..", "data", "observability", "guard.log");
        }
        mkdirSync(dirname(file), { recursive: true });
        appendFileSync(file, JSON.stringify({ ts: new Date().toISOString(), verdict: "permission-memory", ...rec }) + "\n");
    } catch {
        // telemetry must never break the tool call
    }
}

export const PermissionMemory = async () => {
    if (OFF) return {};
    return {
        "tool.execute.after": async (input, output) => {
            if (String(input?.tool ?? "").toLowerCase() !== "bash") return;
            const key = memoryKey(input.sessionID, "bash", input.args);
            if (key) seen.set(key, true);
            void output;
        },
        "permission.ask": async (input, output) => {
            if (String(input?.type ?? "").toLowerCase() !== "bash") return;
            if (!output || output.status === "deny") return;
            const key = memoryKey(input.sessionID, "bash", input.metadata);
            if (!key || !seen.has(key)) return;
            output.status = "allow";
            log({ action: "allow-repeat", key, pattern: input.pattern });
        },
    };
};
