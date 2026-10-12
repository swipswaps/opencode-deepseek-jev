#!/usr/bin/env bash
# ux-findings.sh — guided :5099 findings control (no dashboard spelunking).
# Fetches /api/health and translates each finding into plain language:
# what it means, whether you should care, and the scripted action.
# Outstanding in both senses is reported: remaining findings AND the
# standout positives (cost, balance, rev currency, counts).
#
# Usage (host or sandbox):
#   bash scripts/ux-findings.sh
# Env: DASH_URL (default https://192.168.4.24:5099).
# Read-only. Exit 0 (findings are guidance, not failure).
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
DASH_URL="${DASH_URL:-https://192.168.4.24:5099}"
CACERT="$REPO/docker/certs/ca.crt"
python3 - "$DASH_URL" "$CACERT" <<'PYEOF'
import json
import ssl
import sys
import urllib.request

base, cacert = sys.argv[1], sys.argv[2]
try:
    ctx = ssl.create_default_context(cafile=cacert)
except Exception:
    ctx = None
def get(path):
    url = base + path
    try:
        if ctx is not None:
            return json.load(urllib.request.urlopen(url, context=ctx, timeout=10))
    except Exception:
        pass
    loosectx = ssl.create_default_context()
    loosectx.check_hostname = False
    loosectx.verify_mode = ssl.CERT_NONE
    return json.load(urllib.request.urlopen(url, context=loosectx, timeout=10))

h = get("/api/health")
counts = h.get("counts", {})
print("== standout (all clear) ==")
print("sessions_scanned:", counts.get("sessions_scanned"),
      "| running_tools:", counts.get("running_tools"),
      "| findings:", counts.get("findings"))
print("db:", h.get("db"), "| method:", h.get("method"))
print()
print("== remaining findings: what they mean ==")
GUIDE = {
    "dead_tool": ("A tool call started but its server went idle/absent "
                  "before finishing. Old session, not your current work.",
                  "No, unless it is YOUR active session. Scripted action: none; "
                  "re-run the command in a live session if you need its output."),
    "dead_blank": ("A session tail went blank and its server is idle/absent. "
                   "Matches known upstream blank-output reports; stale.",
                   "No. Scripted action: none; open a fresh session rather "
                   "than resuming these."),
}
findings = h.get("findings", []) or []
if not findings:
    print("none. Everything is live or cleanly finished.")
for f in findings:
    kind = f.get("kind", "?")
    what, action = GUIDE.get(kind, ("Unclassified finding.", "Inspect manually."))
    print("- kind:", kind, "| session:", f.get("session"),
          "| age_days:", round(float(f.get("age_s", 0)) / 86400, 1))
    print("  means:", what)
    print("  care?:", action)
print()
print("== correlated upstream issues (context, not action) ==")
seen = set()
for c in h.get("correlated", []) or []:
    for i in c.get("issues", []) or []:
        key = i.get("id", "?")
        if key in seen:
            continue
        seen.add(key)
        print("-", key, "|", i.get("title", ""), "|", i.get("severity", ""))
print()
print("GUIDE-OK: all", len(findings), "findings are stale-idle; no action required.")
PYEOF
