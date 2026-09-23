#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
URL="http://127.0.0.1:4096"
PROFILE="$HOME/.cache/opencode-register-chromium"
REPO=""; ART=""

resolve_repo() { local c="$1"; while [ "$c" != "/" ]; do [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }; c=$(dirname "$c"); done; return 1; }

main() {
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO=$(resolve_repo "$sd"); [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
  [ -z "$REPO" ] && { printf 'GATE FAIL\n'; return 2; }
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  ART="$REPO/logs/artifacts-$ts"; mkdir -p "$ART"

  local pass; pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
  [ -z "$pass" ] && { printf 'GATE FAIL: no password\n'; return 1; }

  python3 -c 'import playwright' >/dev/null 2>&1 || {
    printf 'playwright missing: pip install playwright && python3 -m playwright install chromium\n'; return 1; }

  mkdir -p "$PROFILE"

  python3 - "$URL" "$pass" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright

url, password, profile, artdir = sys.argv[1:5]

def snap(page):
    return page.evaluate("""() => {
        const o = {};
        for (let i=0;i<localStorage.length;i++){const k=localStorage.key(i);o[k]=localStorage.getItem(k);}
        return o;
    }""")

def body(page):
    return page.evaluate("() => document.body.innerText")

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=profile,
        headless=False,
        args=["--disable-blink-features=AutomationControlled"],
        http_credentials={"username": "opencode", "password": password},
        viewport={"width": 1400, "height": 900},
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(url, wait_until="networkidle", timeout=30000)
    time.sleep(2)

    before = snap(page)
    print(f"[before] localStorage keys: {list(before.keys())}")

    # Find the "Add project" button. It is a small square-with-plus icon
    # at the top-right of the Projects section, no text label.
    clicked = False
    strategies = [
        ("aria-label", "button[aria-label*='project' i]"),
        ("title",      "button[title*='project' i]"),
        ("testid",     "[data-testid*='add-project' i], [data-testid*='new-project' i]"),
    ]
    for name, sel in strategies:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2000)
                print(f"[click] {name}: {sel}")
                clicked = True; break
        except Exception:
            pass

    if not clicked:
        # Sibling-of-heading fallback
        try:
            h = page.get_by_text("Projects", exact=True).first
            parent = h.locator("xpath=ancestor::*[1]")
            btns = parent.locator("button")
            if btns.count() > 0:
                btns.first.click(timeout=2000)
                print(f"[click] sibling of Projects heading ({btns.count()} buttons)")
                clicked = True
        except Exception as e:
            print(f"[skip] heading: {type(e).__name__}")

    if not clicked:
        # Small icon buttons in top-left quadrant
        try:
            for btn in page.locator("button").all():
                box = btn.bounding_box()
                if box and box["x"] < 500 and box["y"] < 200 and 15 < box["width"] < 60:
                    btn.click(timeout=2000)
                    print(f"[click] position ({int(box['x'])},{int(box['y'])})")
                    clicked = True; break
        except Exception as e:
            print(f"[skip] position: {type(e).__name__}")

    if not clicked:
        page.screenshot(path=os.path.join(artdir, "no-button.png"))
        print("ERROR: no project-add control found")
        ctx.close(); sys.exit(2)

    time.sleep(1)
    page.screenshot(path=os.path.join(artdir, "01-dialog.png"))

    # Fill folder search
    filled = False
    for inp in page.locator("input:visible").all():
        try:
            ph = inp.get_attribute("placeholder") or ""
            if "folder" in ph.lower() or "search" in ph.lower() or ph == "":
                inp.fill("workspace")
                filled = True
                print(f"[fill] 'workspace' (placeholder={ph!r})")
                break
        except Exception:
            pass

    if not filled:
        try:
            page.locator("input:visible").first.fill("workspace")
            print("[fill] 'workspace' (first input)")
        except Exception:
            pass

    time.sleep(1.5)
    page.screenshot(path=os.path.join(artdir, "02-filtered.png"))

    # Click workspace entry
    clicked_ws = False
    for sel in [
        "text=~/workspace",
        "text=workspace",
        "li:has-text('workspace')",
        "[role=option]:has-text('workspace')",
        "button:has-text('workspace')",
    ]:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2000)
                print(f"[click ws] {sel}")
                clicked_ws = True; break
        except Exception:
            pass

    if not clicked_ws:
        page.screenshot(path=os.path.join(artdir, "03-no-workspace.png"))
        print("ERROR: workspace entry not found in picker")

    time.sleep(3)

    # Wait for sidebar to update
    for i in range(20):
        t = body(page)
        if "Nothing here yet" not in t and "Create a session" not in t:
            print(f"[wait] sidebar populated after {i+1}s")
            break
        time.sleep(1)

    time.sleep(2)
    page.screenshot(path=os.path.join(artdir, "04-final.png"))

    after = snap(page)
    with open(os.path.join(artdir, "localStorage.json"), "w") as f:
        json.dump(after, f, indent=2)

    print("\n=== localStorage keys ===")
    for k, v in after.items():
        vs = v if len(v) < 200 else v[:200] + "..."
        print(f"  {k}\n    = {vs}")

    paste = os.path.join(artdir, "localStorage-paste.js")
    with open(paste, "w") as f:
        f.write("// Paste in Firefox DevTools Console on http://localhost:4096, then reload\n")
        for k, v in after.items():
            f.write(f"localStorage.setItem({json.dumps(k)}, {json.dumps(v)});\n")
        f.write("location.reload();\n")
    print(f"\n[paste for Firefox] {paste}")

    ctx.close()
PY

  local rc=$?
  printf '\nrc=%d\nartifacts: %s\n' "$rc" "$ART"
  printf '\nFor Firefox:\n'
  printf '  1. open http://localhost:4096\n'
  printf '  2. F12 -> Console\n'
  printf '  3. paste contents of %s/localStorage-paste.js\n' "$ART"
  printf '  4. reload\n'
  return "$rc"
}
main "$@"
