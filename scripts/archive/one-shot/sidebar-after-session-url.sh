#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
SID="ses_f307d80a3ffeAPOSI6z4jRpwxj"
PROFILE="$HOME/.cache/opencode-sessurl-chromium"
TS=$(date -u +%Y%m%dT%H%M%SZ)
ART="$REPO/logs/artifacts-$TS"
mkdir -p "$ART"

PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
[ -z "$PASS" ] && { printf 'GATE FAIL: no password\n' >&2; return 1; }

rm -rf "$PROFILE"; mkdir -p "$PROFILE"

python3 - "$SID" "$PASS" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright

sid, pw, prof, art = sys.argv[1:5]

def sidebar_text(page):
    return page.evaluate("""() => {
        for (const sel of ['aside','nav','[class*=sidebar]','[class*=Sidebar]']) {
            for (const el of document.querySelectorAll(sel)) {
                const t = (el.innerText||'').trim();
                if (t.length > 20) return t;
            }
        }
        return '';
    }""")

def snap_ls(page):
    return page.evaluate("""() => {
        const o = {};
        for (let i=0;i<localStorage.length;i++){const k=localStorage.key(i);o[k]=localStorage.getItem(k);}
        return o;
    }""")

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=prof, headless=False,
        http_credentials={"username":"opencode","password":pw},
        viewport={"width":1400,"height":900})
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    # 1. Root
    page.goto("http://127.0.0.1:4096/", wait_until="networkidle", timeout=30000)
    time.sleep(3)
    page.screenshot(path=f"{art}/01-root.png")
    sb1 = sidebar_text(page)
    ls1 = snap_ls(page)
    print("=== root sidebar ===")
    print(sb1[:800] or "(empty)")
    print(f"\n=== root localStorage: {sorted(ls1.keys())} ===")

    # 2. Session URL
    page.goto(f"http://127.0.0.1:4096/session/{sid}", wait_until="networkidle", timeout=30000)
    time.sleep(6)
    page.screenshot(path=f"{art}/02-session.png")
    sb2 = sidebar_text(page)
    ls2 = snap_ls(page)
    print("\n=== session sidebar ===")
    print(sb2[:800] or "(empty)")

    print("\n=== new localStorage keys after session URL ===")
    new_keys = sorted(set(ls2) - set(ls1))
    for k in new_keys:
        print(f"  +{k} = {ls2[k][:300]}")
    if not new_keys:
        print("  (none)")

    print("\n=== changed localStorage values ===")
    for k in sorted(set(ls1) & set(ls2)):
        if ls1[k] != ls2[k]:
            print(f"  ~{k}: {ls1[k][:150]}  ->  {ls2[k][:300]}")

    # 3. Back to root
    page.goto("http://127.0.0.1:4096/", wait_until="networkidle", timeout=30000)
    time.sleep(3)
    page.screenshot(path=f"{art}/03-root-after.png")
    sb3 = sidebar_text(page)
    print("\n=== root again sidebar ===")
    print(sb3[:800] or "(empty)")

    with open(f"{art}/localStorage.json","w") as f:
        json.dump(ls2, f, indent=2)

    ctx.close()
PY
