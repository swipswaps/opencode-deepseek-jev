#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
PROFILE="$HOME/.cache/oc-streaming-v2"
TS=$(date -u +%Y%m%dT%H%M%SZ)
ART="$REPO/logs/artifacts-$TS"; mkdir -p "$ART"

PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"')
[ -z "$PASS" ] && { printf 'GATE FAIL\n' >&2; return 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -u "opencode:$PASS" http://127.0.0.1:4096/api/health)
[ "$code" != "200" ] && { printf 'GATE FAIL: no auth\n' >&2; return 1; }
printf 'auth: %s, password: %d chars\n' "$code" "${#PASS}"

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
        "sidebar": {"opened": True, "width": 400, "workspaces": {}, "workspacesDefault": False},
        "terminal": {"height": 280, "opened": False},
        "review": {"diffStyle": "split", "panelOpened": False},
        "fileTree": {"opened": False, "width": 200, "tab": "changes"},
        "session": {"width": 600},
        "mobileSidebar": {"opened": False},
        "sessionTabs": {}, "sessionView": {}, "handoff": {},
        "home": {"selection": {"server": "http://127.0.0.1:4096", "directory": "/workspace"}}
    })
}

PERMISSION_LABELS = ["Allow", "Allow once", "Always allow", "Approve",
                     "Accept", "Confirm", "Yes", "Yes, allow", "Continue"]

def click_permission(page):
    """Click the first visible Allow/Approve button. Returns label or None."""
    for label in PERMISSION_LABELS:
        try:
            btns = page.get_by_role("button", name=label, exact=False)
            n = btns.count()
            for i in range(n):
                b = btns.nth(i)
                if b.is_visible():
                    b.click(timeout=800)
                    return label
        except Exception:
            pass
    return None

def api_sessions(page):
    try:
        return page.evaluate("""async () => {
            const r = await fetch('/api/session?directory=/workspace&limit=5&order=desc',{credentials:'include'});
            const j = await r.json();
            return (j.data||[]).map(s => ({id: s.id, title: s.title}));
        }""")
    except Exception:
        return []

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=prof, headless=False,
        http_credentials={"username":"opencode","password":pw},
        viewport={"width":1600,"height":1000})
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    page.goto("http://127.0.0.1:4096/", wait_until="domcontentloaded", timeout=30000)
    for k, v in INJECT.items():
        page.evaluate("([k,v]) => localStorage.setItem(k,v)", [k, v])
    page.reload(wait_until="networkidle", timeout=30000)
    time.sleep(6)

    page.screenshot(path=f"{art}/01-home.png", full_page=True)

    before = api_sessions(page)
    print(f"=== baseline: {len(before)} sessions; newest = {before[0]['id'] if before else 'none'} ===")
    if before:
        print(f"    newest title: {before[0]['title']!r}")

    # Create a new session
    print("\n[action] New session")
    clicked = False
    for sel in ["text=New session", "button:has-text('New session')", "text=Create a session"]:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2500)
                print(f"[click] {sel}")
                clicked = True
                break
        except Exception:
            pass
    if not clicked:
        print("[fallback] no New session control; checking if input already present")

    time.sleep(2)
    page.screenshot(path=f"{art}/02-after-new.png", full_page=True)

    # Type and send
    send_time = None
    try:
        box = page.locator("textarea:visible, [contenteditable=true]:visible").first
        box.fill("Reply with exactly: STREAMTEST")
        print("[fill] typed")
        time.sleep(0.5)
        send_time = time.time()
        page.keyboard.press("Enter")
        print(f"[send] Enter at t=0")
    except Exception as e:
        print(f"[fail] no input: {type(e).__name__}")
        ctx.close()
        sys.exit(0)

    # Poll: session creation via API, reply via DOM, auto-approve permissions
    appeared_session = None
    appeared_reply = None
    permissions_clicked = []

    for i in range(240):  # 120s at 0.5s
        time.sleep(0.5)

        # Auto-approve any dialog
        lbl = click_permission(page)
        if lbl:
            permissions_clicked.append((round(time.time()-send_time, 2), lbl))
            print(f"[allow] {lbl} at t={round(time.time()-send_time,2)}s")

        # New session in API?
        if appeared_session is None:
            now = api_sessions(page)
            if now and before and now[0]["id"] != before[0]["id"]:
                appeared_session = time.time() - send_time
                print(f"[session] new id {now[0]['id']} at t={appeared_session:.2f}s")
                print(f"          title: {now[0]['title']!r}")

        # Reply in DOM? Look for STREAMTEST outside of the user's own message
        try:
            txt = page.evaluate("() => document.body.innerText")
            # reply is a standalone STREAMTEST not preceded by "Reply with exactly:"
            lines = [l.strip() for l in txt.splitlines() if l.strip()]
            for idx, l in enumerate(lines):
                if l == "STREAMTEST":
                    # if the line before does not contain "Reply with exactly"
                    prev = lines[idx-1] if idx > 0 else ""
                    if "Reply with exactly" not in prev and "STREAMTEST" != prev:
                        appeared_reply = time.time() - send_time
                        break
            if appeared_reply is not None:
                break
        except Exception:
            pass

    page.screenshot(path=f"{art}/03-final.png", full_page=True)

    print("\n=== permissions clicked ===")
    for t, lbl in permissions_clicked:
        print(f"  t={t}s  {lbl}")
    if not permissions_clicked:
        print("  (none needed)")

    print("\n=== timing ===")
    print(f"  session appeared:  {appeared_session and f'{appeared_session:.2f}s' or 'never'}")
    print(f"  reply appeared:    {appeared_reply and f'{appeared_reply:.2f}s' or 'never'}")

    print("\n=== VERDICT ===")
    if appeared_session is None:
        print("  INCONCLUSIVE: no new session created")
    elif appeared_reply is None:
        print("  PARTIAL: session seen, reply never matched")
    elif appeared_session < appeared_reply:
        print("  YES: session visible in UI BEFORE reply completes")
        print(f"       session at {appeared_session:.2f}s, reply at {appeared_reply:.2f}s")
        print(f"       delta: {appeared_reply - appeared_session:.2f}s of streaming")
    elif appeared_session == appeared_reply:
        print("  AMBIGUOUS: session and reply appeared in same poll tick")
    else:
        print("  NO: session only visible after reply")
        print(f"      session at {appeared_session:.2f}s, reply at {appeared_reply:.2f}s")

    txt = page.evaluate("() => document.body.innerText")
    with open(f"{art}/body-final.txt","w") as f: f.write(txt)

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
