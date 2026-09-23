#!/usr/bin/env bash
#
# populate-sidebar.sh
#
# Drives the SPA in a persistent Chromium profile to register /workspace
# as a project. Once registered, the SPA fetches
# /api/session?directory=/workspace and the sidebar renders every
# session that exists on the server.
#
# Also extracts the exact localStorage keys the SPA writes, so the same
# state can be reproduced in any other browser via DevTools console.
#
set -o pipefail
C="opencode-deepseek-web"
URL="http://127.0.0.1:4096"
PROFILE="$HOME/.cache/opencode-sidebar-chromium"
REPO=""; ART=""

resolve_repo() {
  local c="$1"
  while [ "$c" != "/" ]; do
    [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }
    c=$(dirname "$c")
  done
  return 1
}

main() {
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO=$(resolve_repo "$sd"); [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
  [ -z "$REPO" ] && { printf 'GATE FAIL\n'; return 2; }
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  ART="$REPO/logs/artifacts-$ts"; mkdir -p "$ART"

  local pass; pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
  [ -z "$pass" ] && { printf 'GATE FAIL: no password\n'; return 1; }

  if ! python3 -c 'import playwright' >/dev/null 2>&1; then
    printf 'GATE FAIL: playwright not installed (pip install playwright && python3 -m playwright install chromium)\n'
    return 1
  fi

  mkdir -p "$PROFILE"

  python3 - "$URL" "$pass" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

url, password, profile, artdir = sys.argv[1:5]

def snap(page):
    return page.evaluate("""() => {
        const out = {};
        for (let i=0; i<localStorage.length; i++) {
            const k = localStorage.key(i);
            out[k] = localStorage.getItem(k);
        }
        return out;
    }""")

def sidebar_text(page):
    return page.evaluate("""() => {
        const sels = ['aside','nav','[class*=sidebar]','[class*=Sidebar]','[data-testid*=sidebar]'];
        for (const s of sels) {
            for (const el of document.querySelectorAll(s)) {
                const t = el.innerText || '';
                if (t.length > 20 && (t.includes('Session') || t.includes('Project') || t.includes('Nothing'))) return t;
            }
        }
        return document.body.innerText.slice(0, 3000);
    }""")

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=profile,
        headless=False,
        args=["--disable-blink-features=AutomationControlled"],
        http_credentials={"username": "opencode", "password": password},
        viewport={"width": 1280, "height": 900},
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(url, wait_until="networkidle", timeout=30000)
    time.sleep(2)

    before = snap(page)
    print(f"[before] localStorage entries: {len(before)}")
    for k in before: print(f"  {k}")

    text_before = sidebar_text(page)
    already_populated = (
        "Nothing here yet" not in text_before
        and "Create a session" not in text_before
    )
    print(f"[before] sidebar populated: {already_populated}")

    if not already_populated:
        # Try "Add project" first
        clicked = None
        for label in ["Add project", "Create a session to get started", "Create a session"]:
            try:
                loc = page.get_by_text(label, exact=False)
                if loc.count() > 0:
                    loc.first.click(timeout=3000)
                    clicked = label
                    print(f"[click] {label}")
                    break
            except Exception as e:
                print(f"[click skip] {label}: {type(e).__name__}")
        if not clicked:
            page.screenshot(path=os.path.join(artdir, "no-button.png"))
            print("ERROR: no project-registration control found")
            ctx.close()
            sys.exit(2)

        time.sleep(1.5)
        page.screenshot(path=os.path.join(artdir, "after-click.png"))

        # Fill any visible text input with /workspace
        filled = False
        for inp in page.locator("input:visible").all():
            try:
                t = inp.get_attribute("type") or "text"
                ph = inp.get_attribute("placeholder") or ""
                if t in ("text", "search", "") and "search" not in ph.lower():
                    inp.fill("/workspace")
                    filled = True
                    print(f"[fill] /workspace into input placeholder={ph!r}")
                    break
            except Exception:
                pass
        if not filled:
            # Try textarea
            try:
                ta = page.locator("textarea:visible").first
                ta.fill("/workspace")
                filled = True
                print("[fill] /workspace into textarea")
            except Exception:
                pass

        if filled:
            time.sleep(0.5)
            # Submit
            for label in ["Add", "Save", "OK", "Confirm", "Create", "Open"]:
                try:
                    page.get_by_role("button", name=label, exact=True).click(timeout=1500)
                    print(f"[submit] {label}")
                    break
                except Exception:
                    continue
            else:
                # Fallback: Enter key
                try:
                    page.keyboard.press("Enter")
                    print("[submit] Enter")
                except Exception:
                    pass
        else:
            # "Create a session" flow — click opened a chat, send any message
            try:
                box = page.locator("textarea:visible, [contenteditable]:visible").first
                box.fill(".")
                page.keyboard.press("Enter")
                print("[submit] placeholder message sent")
            except Exception as e:
                print(f"[submit skip] {e}")

    # Wait for sidebar to change
    for i in range(20):
        time.sleep(1)
        text = sidebar_text(page)
        if "Nothing here yet" not in text and "Create a session to get started" not in text:
            break

    time.sleep(2)
    page.screenshot(path=os.path.join(artdir, "final.png"))

    after = snap(page)
    with open(os.path.join(artdir, "localStorage.json"), "w") as f:
        json.dump(after, f, indent=2)

    text_after = sidebar_text(page)
    with open(os.path.join(artdir, "sidebar-text.txt"), "w") as f:
        f.write(text_after)

    print("\n=== sidebar text (first 1500 chars) ===")
    print(text_after[:1500])
    print("\n=== localStorage entries after ===")
    for k, v in after.items():
        vs = v if len(v) < 120 else v[:120] + "..."
        print(f"  {k} = {vs}")

    # Print a paste-able snippet for other browsers (Firefox etc.)
    paste_file = os.path.join(artdir, "localStorage-paste.js")
    with open(paste_file, "w") as f:
        f.write("// Paste in any browser's DevTools console on http://localhost:4096\n")
        for k, v in after.items():
            f.write(f"localStorage.setItem({json.dumps(k)}, {json.dumps(v)});\n")
        f.write("location.reload();\n")
    print(f"\n=== paste-able snippet for other browsers: {paste_file} ===")

    ctx.close()
PY

  local rc=$?
  printf '\nrc=%d\nartifacts: %s\nchromium profile: %s\n' "$rc" "$ART" "$PROFILE"
  printf '\nTo open the populated sidebar manually:\n'
  printf '  chromium --user-data-dir=%s %s\n' "$PROFILE" "$URL"
  printf '\nFor Firefox or any other browser: open DevTools (F12) → Console → paste:\n'
  printf '  %s/localStorage-paste.js\n' "$ART"
  return "$rc"
}

main "$@"
