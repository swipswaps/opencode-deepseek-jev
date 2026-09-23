#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
PROFILE="$HOME/.cache/oc-register"
TS=$(date -u +%Y%m%dT%H%M%SZ)
ART="$REPO/logs/artifacts-$TS"; mkdir -p "$ART"

PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
[ -z "$PASS" ] && { printf 'GATE FAIL: no password\n' >&2; return 1; }

rm -rf "$PROFILE"; mkdir -p "$PROFILE"

python3 - "$PASS" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright

pw, prof, art = sys.argv[1:4]

INJECT = {
    "opencode.global.dat:server": json.dumps({
        "list": [],
        "projects": {"local": [{"worktree": "/workspace", "expanded": True}]},
        "lastProject": {"local": "/workspace"},
        "recentlyClosed": {}
    }),
    "opencode.global.dat:layout": json.dumps({
        "sidebar": {"opened": True, "width": 344, "workspaces": {}, "workspacesDefault": False},
        "terminal": {"height": 280, "opened": False},
        "review": {"diffStyle": "split", "panelOpened": False},
        "fileTree": {"opened": False, "width": 200, "tab": "changes"},
        "session": {"width": 600},
        "mobileSidebar": {"opened": False},
        "sessionTabs": {}, "sessionView": {}, "handoff": {},
        "home": {"selection": {"server": "http://127.0.0.1:4096", "directory": "/workspace"}}
    })
}

def sidebar(page):
    return page.evaluate("""() => {
        for (const sel of ['aside','nav','[class*=sidebar]','[class*=Sidebar]']) {
            for (const el of document.querySelectorAll(sel)) {
                const t = (el.innerText||'').trim();
                if (t.length > 10) return t;
            }
        }
        return document.body.innerText.slice(0, 2000);
    }""")

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=prof, headless=False,
        http_credentials={"username":"opencode","password":pw},
        viewport={"width":1400,"height":900})
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto("http://127.0.0.1:4096/", wait_until="networkidle", timeout=30000)
    time.sleep(3)

    print("=== BEFORE ===")
    print(sidebar(page)[:400] or "(empty)")
    page.screenshot(path=f"{art}/01-before.png")

    for k, v in INJECT.items():
        page.evaluate("([k,v]) => localStorage.setItem(k,v)", [k, v])
        print(f"\n[inject] {k}")

    page.reload(wait_until="networkidle", timeout=30000)
    time.sleep(6)

    page.screenshot(path=f"{art}/02-after.png")
    body = sidebar(page)
    print("\n=== AFTER ===")
    print(body[:800] or "(empty)")

    final_ls = page.evaluate("""() => {
        const o={};for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);o[k]=localStorage.getItem(k);}return o;
    }""")
    with open(f"{art}/ls-final.json","w") as f:
        json.dump(final_ls, f, indent=2)

    # Emit a paste-able snippet for Firefox
    paste = os.path.join(art, "firefox-paste.js")
    with open(paste, "w") as f:
        f.write("// Paste in Firefox DevTools Console at http://localhost:4096, then reload\n")
        for k, v in INJECT.items():
            f.write(f"localStorage.setItem({json.dumps(k)}, {json.dumps(v)});\n")
        f.write("location.reload();\n")
    print(f"\n[paste for Firefox] {paste}")

    populated = "Nothing here yet" not in body and "Create a session" not in body
    print(f"\n=== VERDICT ===\n  sidebar populated: {populated}")

    ctx.close()
PY

cd "$REPO"
for f in logs/agent-*.log; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
n=re.sub(r'apikey_[A-Za-z0-9_]{20,}','apikey_REDACTED',s)
n=re.sub(r'sk-[A-Za-z0-9]{20,}','sk-REDACTED',n)
n=re.sub(r'OPENCODE_SERVER_PASSWORD=[A-Za-z0-9+/=]{20,}','OPENCODE_SERVER_PASSWORD=REDACTED',n)
if n!=s: open(p,'w').write(n); print(f"redacted {p}")
PY
done
./scripts/archive/one-shot/push-telemetry.sh
