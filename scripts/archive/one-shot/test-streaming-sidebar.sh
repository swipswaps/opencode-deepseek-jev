#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
PROFILE="$HOME/.cache/oc-streaming"
TS=$(date -u +%Y%m%dT%H%M%SZ)
ART="$REPO/logs/artifacts-$TS"; mkdir -p "$ART"

# Password from container only. Do not trust the shell.
PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"')
[ -z "$PASS" ] && { printf 'GATE FAIL: container has no password\n' >&2; return 1; }
printf 'container password: %d chars\n' "${#PASS}"

# Confirm it authenticates
code=$(curl -s -o /dev/null -w '%{http_code}' -u "opencode:$PASS" http://127.0.0.1:4096/api/health)
printf 'curl /api/health: %s\n' "$code"
[ "$code" != "200" ] && { printf 'GATE FAIL: password does not authenticate\n' >&2; return 1; }

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

def main_text(page):
    return page.evaluate("""() => {
        // Largest visible text block excluding <aside>
        let best = {len: 0, text: ''};
        for (const el of document.querySelectorAll('main, [role=main], [class*=content], [class*=Content], [class*=session], [class*=Session]')) {
            if (el.tagName === 'ASIDE') continue;
            if (el.closest('aside')) continue;
            const t = (el.innerText || '').trim();
            if (t.length > best.len) best = {len: t.length, text: t};
        }
        return best.text || document.body.innerText;
    }""")

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=prof, headless=False,
        http_credentials={"username":"opencode","password":pw},
        viewport={"width":1600,"height":1000})
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    # Seed project state, then load
    page.goto("http://127.0.0.1:4096/", wait_until="domcontentloaded", timeout=30000)
    for k, v in INJECT.items():
        page.evaluate("([k,v]) => localStorage.setItem(k,v)", [k, v])
    page.reload(wait_until="networkidle", timeout=30000)
    time.sleep(6)

    page.screenshot(path=f"{art}/01-home.png", full_page=True)
    home = main_text(page)
    print(f"=== home main content: {len(home)} chars ===")
    print(home[:600])

    # Count existing sessions visible
    titles = [
        "OpenCode DeepSeek JEV container audit",
        "Sidebar audit and JEV review of notes",
        "Docker coding agent sidebar audit",
        "Docker coding agent environment audit report",
    ]
    pre_hits = sum(home.count(t) for t in titles)
    print(f"\n[pre] session-title hits in main: {pre_hits}")

    # New session: click the button or navigate directly
    print("\n[action] creating new session")
    new_sid = None
    try:
        for sel in ["text=New session", "button:has-text('New session')", "text=Create a session"]:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2500)
                print(f"[click] {sel}")
                break
    except Exception as e:
        print(f"[click-fallback] {type(e).__name__}")

    time.sleep(2)
    # The URL should now be /session/<id> or the page has an input
    url_now = page.url
    print(f"[url] {url_now}")
    if "/session/" in url_now:
        new_sid = url_now.rstrip("/").split("/")[-1]
        print(f"[sid] new session id: {new_sid}")

    # Type and send
    try:
        box = page.locator("textarea:visible, [contenteditable=true]:visible").first
        box.fill("Reply with exactly: STREAMTEST")
        print("[fill] message typed")
        time.sleep(0.5)
        page.keyboard.press("Enter")
        print("[send] Enter")
    except Exception as e:
        print(f"[fill/send fail] {type(e).__name__}")
        page.screenshot(path=f"{art}/02-no-input.png", full_page=True)
        ctx.close()
        sys.exit(0)

    t0 = time.time()

    # Poll main content every 0.5s up to 60s. Detect the message reply.
    appeared_session = None
    appeared_reply = None
    for i in range(120):
        time.sleep(0.5)
        t = main_text(page)
        if new_sid and appeared_session is None and new_sid in t:
            appeared_session = time.time() - t0
        if appeared_reply is None and "STREAMTEST" in t and "Reply with exactly" not in t:
            appeared_reply = time.time() - t0
        if appeared_reply is not None and appeared_session is not None:
            break

    page.screenshot(path=f"{art}/03-final.png", full_page=True)
    final = main_text(page)
    print("\n=== timing ===")
    print(f"  new session visible in main:    {appeared_session and f'{appeared_session:.2f}s' or 'never'}")
    print(f"  assistant reply text visible:   {appeared_reply and f'{appeared_reply:.2f}s' or 'never'}")

    print("\n=== final main content (first 800) ===")
    print(final[:800])

    with open(f"{art}/main-after.txt","w") as f: f.write(final)

    # Check: is the new session in /api/session?
    api = page.evaluate("""async () => {
        const r = await fetch('/api/session?directory=/workspace&limit=5000&order=desc',{credentials:'include'});
        const j = await r.json();
        return {count: (j.data||[]).length, first: (j.data||[])[0]};
    }""")
    print(f"\n=== /api/session count: {api['count']}")
    print(f"=== newest session: {json.dumps(api['first'])[:300]}")

    # Verdict
    print("\n=== VERDICT ===")
    if appeared_session is not None and appeared_reply is not None:
        if appeared_session <= appeared_reply:
            print("  PASS: session appears in main content BEFORE reply completes")
            print(f"        session at {appeared_session:.2f}s, reply at {appeared_reply:.2f}s")
        else:
            print("  FAIL: session appears only after reply")
    elif appeared_session is None:
        print("  INCONCLUSIVE: new session id not detected in main content")
    else:
        print("  PARTIAL: session seen, reply not detected")

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
