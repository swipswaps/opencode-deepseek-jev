#!/bin/sh
#
# patch-global-config.sh — JEV-OFF applied to the GLOBAL opencode config.
#
# The image installs jev-guard with `opencode plugin ... --global` (Dockerfile),
# so removing it from /workspace/opencode.json is not enough: the global config
# still lists it and the plugin still runs (its Jev login fails). This patch:
#   - removes jev-guard* from the global plugin list
#   - removes the jev-review MCP server and /opt/jev-review skills
#   - replaces a literal LiteLLM apiKey with {env:LITELLM_MASTER_KEY}
#
# Idempotent. A JSONC file that is not plain JSON is left untouched (a warning
# is printed and the container still starts). Never prints a key.
#
set -u

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
CFG=""
if [ -f "$CFG_DIR/opencode.jsonc" ]; then
    CFG="$CFG_DIR/opencode.jsonc"
elif [ -f "$CFG_DIR/opencode.json" ]; then
    CFG="$CFG_DIR/opencode.json"
fi

if [ -z "$CFG" ]; then
    printf '[patch-global-config] no global config; nothing to patch\n' >&2
    exit 0
fi

node -e '
    const fs = require("fs");
    const f = process.argv[1];
    let d;
    try { d = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) {
        console.error("[patch-global-config] not plain JSON; JEV patch skipped: " + e.message);
        process.exit(0);
    }
    let changed = false;
    // JEV_BASE_URL is the switch: set it (Laya/Kev) to keep jev-guard active
    // against that server; leave it unset to disable the guard entirely.
    const base = String(process.env.JEV_BASE_URL || "").trim();
    if (!Array.isArray(d.plugin) && base) { d.plugin = []; changed = true; }
    if (Array.isArray(d.plugin)) {
        const has = d.plugin.some((p) => /^jev-guard(@|$)/.test(String(p)));
        if (base) {
            if (!has) { d.plugin.push("jev-guard@0.3.1"); changed = true; }
        } else {
            const kept = d.plugin.filter((p) => !/^jev-guard(@|$)/.test(String(p)));
            if (kept.length !== d.plugin.length) { d.plugin = kept; changed = true; }
        }
    }
    if (d.mcp && d.mcp.servers && d.mcp.servers["jev-review"]) {
        delete d.mcp.servers["jev-review"]; changed = true;
    }
    if (Array.isArray(d.skills)) {
        const kept = d.skills.filter((s) => !String(s).includes("/opt/jev-review"));
        if (kept.length !== d.skills.length) { d.skills = kept; changed = true; }
    }
    const lp = d.provider && d.provider.litellm;
    if (lp && lp.options && typeof lp.options.apiKey === "string" && /^sk-/.test(lp.options.apiKey)) {
        lp.options.apiKey = "{env:LITELLM_MASTER_KEY}"; changed = true;
    }
    if (changed) {
        fs.writeFileSync(f, JSON.stringify(d, null, 2) + "\n");
        console.error("[patch-global-config] patched: " + (base ? "jev-guard ON via JEV_BASE_URL" : "JEV disabled") + ", literal LiteLLM key -> env ref");
    }
' "$CFG"
exit 0
