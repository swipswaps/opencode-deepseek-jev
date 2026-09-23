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
    if [ -z "$pass" ]; then
        printf 'GATE FAIL: no password\n' >&2
        return 1
    fi

    python3 -c 'import playwright' >/dev/null 2>&1 || {
        printf 'playwright missing\n' >&2
        return 1
    }

    mkdir -p "$PROFILE"

    python3 - "$URL" "$pass" "$PROFILE" "$ART" <<'PY'
import json, os, sys, time
from playwright.sync_api import sync_playwright

url, password, profile, artdir = sys.argv[1:5]
requests = []

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        user_data_dir=profile,
        headless=False,
        args=["--disable-blink-features=AutomationControlled"],
        http_credentials={"username": "opencode", "password": password},
        viewport={"width": 1400, "height": 900},
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    def on_request(req):
        if req.resource_type in ("document", "stylesheet", "script", "image", "font"):
            return
        entry = {
            "method": req.method,
            "url": req.url,
            "resource_type": req.resource_type,
            "post_data": req.post_data,
            "headers": {k: v for k, v in req.headers.items() if k.lower() not in ("authorization", "cookie")},
        }
        requests.append(entry)

    def on_response(resp):
        try:
            if resp.request.resource_type in ("document", "stylesheet", "script", "image", "font"):
                return
            if not resp.url.startswith(url):
                return
            if resp.request.method == "GET" and "event" in resp.url:
                return
            ct = resp.headers.get("content-type", "")
            if "json" not in ct and "text" not in ct:
                return
            body = resp.text()[:500]
            for e in requests:
                if e["url"] == resp.url and e["method"] == resp.request.method:
                    e["response_status"] = resp.status
                    e["response_body"] = body
                    break
        except Exception:
            pass

    page.on("request", on_request)
    page.on("response", on_response)

    page.goto(url, wait_until="networkidle", timeout=30000)
    time.sleep(2)
    page.screenshot(path=os.path.join(artdir, "00-initial.png"))

    print("[action] clicking Add project")
    clicked = False
    for sel in [
        "text=Add project",
        "button:has-text('Add project')",
        "[aria-label*='project' i]",
    ]:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=3000)
                clicked = True
                print(f"[action] clicked: {sel}")
                break
        except Exception:
            pass

    if not clicked:
        page.screenshot(path=os.path.join(artdir, "no-add-button.png"))
        print("ERROR: Add project control not found")
        ctx.close(); sys.exit(2)

    time.sleep(1.5)
    page.screenshot(path=os.path.join(artdir, "01-picker.png"))

    print("[action] selecting first folder in picker")
    picked = False
    for sel in [
        "text=~/ .cache/", "text=~/.cache/", "text=.cache",
        "[role=option]:first-child",
        "li:first-child",
        "button:has-text('.cache')",
    ]:
        try:
            loc = page.locator(sel)
            if loc.count() > 0:
                loc.first.click(timeout=2000)
                picked = True
                print(f"[action] picked: {sel}")
                break
        except Exception:
            pass

    if not picked:
        page.screenshot(path=os.path.join(artdir, "02-no-folder.png"))
        print("WARN: no folder entry picked; capture may be incomplete")

    time.sleep(3)
    page.screenshot(path=os.path.join(artdir, "03-after-pick.png"))

    # Also dump IndexedDB databases and their object stores
    idb_info = page.evaluate("""async () => {
        const out = {dbs: []};
        if (!indexedDB.databases) return out;
        const dbs = await indexedDB.databases();
        for (const d of dbs) {
            out.dbs.push(d.name);
        }
        return out;
    }""")
    print(f"\n[indexeddb] databases: {idb_info}")

    # Dump each db's stores
    idb_dump = page.evaluate("""async () => {
        const out = {};
        const dbs = await indexedDB.databases();
        for (const d of dbs) {
            const db = await new Promise((res, rej) => {
                const r = indexedDB.open(d.name);
                r.onsuccess = () => res(r.result);
                r.onerror = () => rej(r.error);
            });
            const stores = Array.from(db.objectStoreNames);
            out[d.name] = {};
            for (const s of stores) {
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
        }
        return out;
    }""")

    with open(os.path.join(artdir, "indexeddb-dump.json"), "w") as f:
        json.dump(idb_dump, f, indent=2)

    print("\n=== network requests (non-static) ===")
    for r in requests:
        print(f"{r['method']:6} {r['url']}")
        if r.get("post_data"):
            print(f"       body: {r['post_data'][:400]}")
        if r.get("response_status"):
            print(f"       status: {r['response_status']}")
        if r.get("response_body"):
            print(f"       resp: {r['response_body'][:300]}")

    with open(os.path.join(artdir, "requests.json"), "w") as f:
        json.dump(requests, f, indent=2)

    print("\n=== localStorage ===")
    ls = page.evaluate("""() => {
        const o = {};
        for (let i=0;i<localStorage.length;i++){const k=localStorage.key(i);o[k]=localStorage.getItem(k);}
        return o;
    }""")
    for k, v in ls.items():
        print(f"  {k} = {v[:200]}")

    print("\n=== IndexedDB databases and stores ===")
    for dbname, stores in idb_dump.items():
        print(f"  db: {dbname}")
        for sname, values in stores.items():
            print(f"    store: {sname}  ({len(values)} entries)")
            for v in values[:5]:
                print(f"      {json.dumps(v)[:300]}")

    ctx.close()
PY

    local rc=$?
    printf '\nrc=%d\nartifacts: %s\n' "$rc" "$ART"
    return "$rc"
}

main "$@"
