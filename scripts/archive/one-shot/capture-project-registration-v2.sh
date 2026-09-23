#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
URL="http://127.0.0.1:4096"
PROFILE="$HOME/.cache/opencode-capture-chromium"
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
    [ -z "$REPO" ] && { printf 'GATE FAIL\n' >&2; return 2; }
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    ART="$REPO/logs/artifacts-$ts"; mkdir -p "$ART"

    local pass
    pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$pass" ] && { printf 'GATE FAIL: no password\n' >&2; return 1; }

    python3 -c 'import playwright' >/dev/null 2>&1 || {
        printf 'playwright missing\n' >&2
        return 1
    }

    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"

    python3 - "$URL" "$pass" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright

url, password, profile, artdir = sys.argv[1:5]
requests = []
console = []

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=profile,
        headless=False,
        args=["--disable-blink-features=AutomationControlled"],
        http_credentials={"username": "opencode", "password": password},
        viewport={"width": 1400, "height": 900},
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    page.on("console", lambda m: console.append({"type": m.type, "text": m.text}))

    def on_request(req):
        if req.resource_type in ("document","stylesheet","script","image","font","media"):
            return
        requests.append({
            "method": req.method,
            "url": req.url,
            "resource_type": req.resource_type,
            "post_data": req.post_data,
        })
    def on_response(resp):
        try:
            if resp.request.resource_type in ("document","stylesheet","script","image","font","media"):
                return
            if not resp.url.startswith(url):
                return
            ct = resp.headers.get("content-type", "")
            if "json" not in ct and "text" not in ct:
                return
            body = resp.text()[:2000]
            for e in requests:
                if e["url"] == resp.url and e["method"] == resp.request.method and "response_body" not in e:
                    e["status"] = resp.status
                    e["response_body"] = body
                    break
        except Exception:
            pass

    page.on("request", on_request)
    page.on("response", on_response)

    page.goto(url, wait_until="networkidle", timeout=30000)
    time.sleep(3)
    page.screenshot(path=os.path.join(artdir, "00-loaded.png"))

    # Find any button or clickable element whose bounding box is roughly
    # where the Add-project button sits: near the "Projects" heading text.
    print("[find] searching for Add project control")
    clicked = False

    # 1. Text-based
    for sel in [
        "text=Add project",
        "text=Open project",
        "[role=button][aria-label*='project' i]",
        "button[aria-label*='project' i]",
    ]:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2500)
                print(f"[click] text/aria: {sel}")
                clicked = True
                break
        except Exception as e:
            pass

    # 2. Anchor to "Projects" heading: any clickable in the same row
    if not clicked:
        try:
            h = page.get_by_text("Projects", exact=True).first
            box = h.bounding_box()
            if box:
                # Look for buttons in the row to the right of the heading
                for btn in page.locator("button, [role=button], a[href]").all():
                    try:
                        b = btn.bounding_box()
                        if not b: continue
                        if abs(b["y"] - box["y"]) < 40 and b["x"] > box["x"] + box["width"]:
                            btn.click(timeout=2500)
                            print(f"[click] row-right of Projects heading at ({int(b['x'])},{int(b['y'])})")
                            clicked = True
                            break
                    except Exception:
                        pass
        except Exception as e:
            print(f"[skip] heading anchor: {type(e).__name__}")

    # 3. Anything clickable in the top-left 600x300
    if not clicked:
        try:
            for btn in page.locator("button, [role=button], [class*=icon], svg").all():
                try:
                    b = btn.bounding_box()
                    if not b: continue
                    if b["x"] < 600 and b["y"] < 300 and 8 < b["width"] < 80 and 8 < b["height"] < 80:
                        btn.click(timeout=2000)
                        print(f"[click] top-left icon at ({int(b['x'])},{int(b['y'])}) size {int(b['width'])}x{int(b['height'])}")
                        clicked = True
                        break
                except Exception:
                    pass
        except Exception as e:
            print(f"[skip] top-left scan: {type(e).__name__}")

    if not clicked:
        page.screenshot(path=os.path.join(artdir, "01-no-button.png"))
        print("ERROR: no control found")
    else:
        time.sleep(3)
        page.screenshot(path=os.path.join(artdir, "02-picker.png"))

        # If a picker dialog is up, try typing /workspace
        try:
            for inp in page.locator("input:visible").all():
                try:
                    inp.fill("/workspace")
                    print("[fill] typed /workspace into input")
                    time.sleep(1.5)
                    page.screenshot(path=os.path.join(artdir, "03-typed.png"))
                    break
                except Exception:
                    pass
        except Exception:
            pass

        # Click any element that appears to be a folder entry
        try:
            for sel in ["text=workspace", "li:has-text('workspace')", "[role=option]:has-text('workspace')"]:
                loc = page.locator(sel)
                if loc.count() > 0:
                    loc.first.click(timeout=2000)
                    print(f"[click] folder: {sel}")
                    break
        except Exception:
            pass
        time.sleep(3)
        page.screenshot(path=os.path.join(artdir, "04-after.png"))

    # Dump everything regardless
    ls = page.evaluate("""() => {
        const o = {};
        for (let i=0;i<localStorage.length;i++){const k=localStorage.key(i);o[k]=localStorage.getItem(k);}
        return o;
    }""")
    with open(os.path.join(artdir, "localStorage.json"), "w") as f:
        json.dump(ls, f, indent=2)
    print(f"\n[localStorage] {len(ls)} keys")

    idb = page.evaluate("""async () => {
        const out = {};
        if (!indexedDB.databases) return out;
        const dbs = await indexedDB.databases();
        for (const d of dbs) {
            try {
                const db = await new Promise((res, rej) => {
                    const r = indexedDB.open(d.name);
                    r.onsuccess = () => res(r.result);
                    r.onerror = () => rej(r.error);
                });
                out[d.name] = {};
                for (const s of db.objectStoreNames) {
                    const tx = db.transaction(s, "readonly");
                    const st = tx.objectStore(s);
                    const all = await new Promise((res, rej) => {
                        const r = st.getAll();
                        r.onsuccess = () => res(r.result);
                        r.onerror = () => rej(r.error);
                    });
                    out[d.name][s] = all.map(v => {
                        try { return JSON.parse(JSON.stringify(v)); } catch (e) { return String(v); }
                    });
                }
                db.close();
            } catch (e) {
                out[d.name] = {"_error": String(e)};
            }
        }
        return out;
    }""")
    with open(os.path.join(artdir, "indexeddb.json"), "w") as f:
        json.dump(idb, f, indent=2)
    print(f"[indexeddb] {len(idb)} databases: {list(idb.keys())}")
    for dbname, stores in idb.items():
        for sname, vals in stores.items():
            print(f"  {dbname}.{sname}: {len(vals)} entries")
            for v in vals[:5]:
                print(f"    {json.dumps(v)[:300]}")

    with open(os.path.join(artdir, "requests.json"), "w") as f:
        json.dump(requests, f, indent=2)
    print(f"\n[network] {len(requests)} requests")
    for r in requests:
        if r.get("post_data") or "/api/" in r["url"]:
            print(f"  {r['method']:6} {r['url']}")
            if r.get("post_data"):
                print(f"         body: {r['post_data'][:300]}")
            if r.get("response_body"):
                print(f"         resp: {r['response_body'][:300]}")

    with open(os.path.join(artdir, "console.json"), "w") as f:
        json.dump(console, f, indent=2)

    ctx.close()
PY

    local rc=$?
    printf '\ncapture rc=%d\nartifacts=%s\n\n' "$rc" "$ART"

    # Push and print URLs regardless of capture rc
    if [ -x "$REPO/scripts/archive/one-shot/push-telemetry.sh" ]; then
        "$REPO/scripts/archive/one-shot/push-telemetry.sh"
    fi

    return "$rc"
}

main "$@"
