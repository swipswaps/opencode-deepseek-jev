#!/usr/bin/env python3
"""
rotate-guided.py — Playwright-guided provider key rotation that learns.

The problem this removes: every vendor console is a different UI, and after a
leak the operator has to remember where "revoke" and "create key" live. This
tool opens the console in a persistent Chromium profile (log in ONCE), then
finds, clicks and remembers the right controls in a durable SQLite memory. On
the next rotation the remembered locator is tried first; if the vendor changes
the page, the tool falls back to heuristics and asks the operator to point at
the right control once, then remembers that.

  ./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action rotate
  ./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action login --browser chrome-cdp
  ./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action revoke --browser chrome-cdp
  ./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action open
  ./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action capture

Google/LinkedIn SSO can reject Playwright's bundled Chromium with "This browser
or app may not be secure". Use --browser chrome-cdp: it launches a REAL Chrome
with a dedicated persistent profile (no automation flags) and attaches over CDP.
Log in there once; the Chrome profile persists. --browser auto prefers an
existing CDP endpoint, then real Chrome, then bundled Chromium.
  ./scripts/browser-python.sh scripts/rotate-guided.py --plan --provider deepseek
  ./scripts/browser-python.sh scripts/rotate-guided.py --report
  ./scripts/browser-python.sh scripts/rotate-guided.py --self-test
  ./scripts/browser-python.sh scripts/rotate-guided.py --reset-login

Memory lives in data/observability/observability.db:
  rotation_memory(provider, action, locator, successes, failures, last_ok, ...)
  rotation_run(ts, provider, action, step, ok, url, detail, screenshot)

Secrets: the new key is read from the page (or the clipboard after a prompt),
written atomically to .env.local (0600) with a backup, and NEVER printed or
logged. No screenshot is taken after a key is revealed. The script prints only
the variable name and key length.

Exit 0 success, 1 failure, 2 usage / Playwright missing / login required.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
REDACT = re.compile(r"(sk-[A-Za-z0-9_\-]{8,}|apikey_[A-Za-z0-9_]{8,}|AIza[A-Za-z0-9_\-]{8,})")
CANDIDATES_JS = r"""() => {
  const vis = el => {
    if (!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)) return false;
    if (el.getAttribute('aria-hidden') === 'true') return false;
    const s = getComputedStyle(el);
    return s.opacity !== '0' && s.pointerEvents !== 'none';
  };
  const css = el => {
    const parts = [];
    while (el && el.nodeType === 1 && parts.length < 6) {
      let s = el.tagName.toLowerCase();
      if (el.id) { s += '#' + el.id; parts.unshift(s); break; }
      const p = el.parentElement;
      if (p) { const same = [...p.children].filter(x => x.tagName === el.tagName);
               if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')'; }
      parts.unshift(s); el = p;
    }
    return parts.join(' > ');
  };
  const role = el => el.getAttribute('role') ||
    (el.tagName === 'A' ? 'link' : el.tagName === 'INPUT' ? 'button' : 'button');
  const name = el => (el.getAttribute('aria-label') || el.innerText || el.value ||
    el.getAttribute('title') || '').replace(/\s+/g, ' ').trim();
  const context = el => {
    const row = el.closest('tr,li,[role="row"],[data-testid*="key"]');
    return row ? (row.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 160) : '';
  };
  return [...document.querySelectorAll('button,a,[role="button"],input[type="submit"],input[type="button"],[role="menuitem"]')]
    .filter(vis)
    .slice(0, 100)
    .map((el, i) => ({ i, tag: el.tagName.toLowerCase(), role: role(el), name: name(el).slice(0, 100),
                       context: context(el), disabled: !!el.disabled, css: css(el),
                       href: (el.getAttribute('href') || '').slice(0, 200) }));
}"""
EXTRACT_JS = r"""() => {
  const out = [];
  document.querySelectorAll('input,textarea').forEach(el => { if (el.value) out.push(String(el.value)); });
  document.querySelectorAll('code,pre,[data-testid*="key"],.font-mono').forEach(el => {
    const t = (el.innerText || '').trim(); if (t) out.push(t);
  });
  return { values: out, body: ((document.body && document.body.innerText) || '').slice(0, 300000) };
}"""


def repo_root() -> Path:
    c = HERE
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return HERE.parent


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text: str) -> str:
    return REDACT.sub("[REDACTED]", str(text or ""))


def db_path() -> Path:
    return Path(os.environ.get("ROTATION_DB") or (repo_root() / "data" / "observability" / "observability.db"))


def env_path() -> Path:
    return Path(os.environ.get("ROTATION_ENV") or (repo_root() / ".env.local"))


def chrome_profile_dir() -> Path:
    p = Path(os.environ.get("ROTATION_CHROME_PROFILE") or
             (Path.home() / ".local" / "state" / "opencode-rotation" / "chrome-profile"))
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def find_chrome() -> str:
    for name in ("google-chrome-stable", "google-chrome", "chromium-browser", "chromium"):
        exe = shutil.which(name)
        if exe:
            return exe
    return ""


def cdp_reachable(url: str) -> bool:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/json/version", timeout=3) as r:
            return b"Browser" in r.read(200)
    except Exception:  # noqa: BLE001
        return False


def _cdp_port(url: str, default: int) -> int:
    try:
        return urlsplit(url).port or default
    except Exception:  # noqa: BLE001
        return default


def chrome_hint(args) -> str:
    return ("%s --remote-debugging-port=%d --remote-allow-origins=* --user-data-dir=%s "
            "--no-first-run --no-default-browser-check about:blank"
            % (find_chrome() or "google-chrome-stable", _cdp_port(args.cdp, args.cdp_port), chrome_profile_dir()))


def launch_chrome(args) -> bool:
    exe = find_chrome()
    if not exe:
        print("FAIL: no Chrome/Chromium binary found (google-chrome-stable, google-chrome, chromium)", file=sys.stderr)
        return False
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        print("FAIL: chrome-cdp needs a desktop session (DISPLAY/WAYLAND_DISPLAY unset)", file=sys.stderr)
        print("  run this from the desktop terminal, or start Chrome yourself with --remote-debugging-port", file=sys.stderr)
        return False
    cmd = [exe, "--remote-debugging-port=%d" % _cdp_port(args.cdp, args.cdp_port),
           "--remote-allow-origins=*", "--user-data-dir=%s" % chrome_profile_dir(),
           "--no-first-run", "--no-default-browser-check"]
    if args.headless:
        cmd.append("--headless=new")
    cmd.append("about:blank")
    print("launching real Chrome (no automation flags): %s" % " ".join(cmd))
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(30):
        if cdp_reachable(args.cdp):
            return True
        time.sleep(1)
    print("FAIL: Chrome CDP not reachable at %s after 30s" % args.cdp, file=sys.stderr)
    return False


def choose_browser_mode(args) -> str:
    if args.browser != "auto":
        return args.browser
    if cdp_reachable(args.cdp):
        return "cdp"
    if find_chrome():
        return "chrome-cdp"
    return "chromium"


def profile_dir() -> Path:
    p = Path(os.environ.get("ROTATION_PROFILE") or (Path.home() / ".local" / "state" / "opencode-rotation" / "profile"))
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


SCHEMA = """
CREATE TABLE IF NOT EXISTS rotation_memory(
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL,
  action TEXT NOT NULL,
  locator TEXT NOT NULL,
  successes INTEGER DEFAULT 0,
  failures INTEGER DEFAULT 0,
  last_ok TEXT,
  last_fail TEXT,
  note TEXT,
  url TEXT,
  UNIQUE(provider, action, locator));
CREATE TABLE IF NOT EXISTS rotation_run(
  id INTEGER PRIMARY KEY,
  ts TEXT, provider TEXT, action TEXT, step TEXT, ok INTEGER,
  url TEXT, detail TEXT, screenshot TEXT);
"""


def connect() -> sqlite3.Connection:
    db_path().parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(db_path()))
    con.executescript(SCHEMA)
    return con


def recall(provider: str, action: str):
    con = connect()
    row = con.execute(
        "SELECT locator, successes, failures FROM rotation_memory "
        "WHERE provider=? AND action=? ORDER BY (successes - failures) DESC, successes DESC, last_ok DESC LIMIT 1",
        (provider, action)).fetchone()
    con.close()
    return json.loads(row[0]) if row else None


def _origin(u: str) -> str:
    try:
        parts = urlsplit(u)
        return "%s://%s" % (parts.scheme, parts.netloc)
    except Exception:  # noqa: BLE001
        return ""


def recall_url(provider: str, action: str, console: str) -> str:
    """Return the remembered page where this control lived, same-origin only."""
    con = connect()
    row = con.execute(
        "SELECT url FROM rotation_memory WHERE provider=? AND action=? AND url IS NOT NULL AND url != '' "
        "ORDER BY (successes - failures) DESC, successes DESC, last_ok DESC LIMIT 1",
        (provider, action)).fetchone()
    con.close()
    if row and row[0] and _origin(row[0]) == _origin(console) and _origin(row[0]):
        return row[0]
    return ""


def remember(provider: str, action: str, locator, ok: bool, url: str, note: str = ""):
    loc = json.dumps(locator, sort_keys=True)
    ts = utcnow()
    con = connect()
    con.execute(
        "INSERT INTO rotation_memory(provider,action,locator,successes,failures,last_ok,last_fail,note,url) "
        "VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,action,locator) DO UPDATE SET "
        "successes=successes+excluded.successes, failures=failures+excluded.failures, "
        "last_ok=COALESCE(excluded.last_ok,last_ok), last_fail=COALESCE(excluded.last_fail,last_fail), "
        "note=excluded.note, url=excluded.url",
        (provider, action, loc, 1 if ok else 0, 0 if ok else 1,
         ts if ok else None, None if ok else ts, redact(note)[:300], url[:300]))
    con.commit()
    con.close()


def log_run(provider: str, action: str, step: str, ok: bool, url: str, detail: str = "", shot: str = ""):
    con = connect()
    con.execute("INSERT INTO rotation_run(ts,provider,action,step,ok,url,detail,screenshot) VALUES(?,?,?,?,?,?,?,?)",
                (utcnow(), provider, action, step, 1 if ok else 0, url[:300], redact(detail)[:500], shot[:300]))
    con.commit()
    con.close()


def load_providers() -> dict:
    with open(HERE / "rotation-providers.json", encoding="utf-8") as fh:
        return json.load(fh)["providers"]


def derive_locator(c: dict) -> dict:
    if c.get("name") and c.get("role"):
        return {"kind": "role", "role": c["role"], "name": c["name"]}
    return {"kind": "css", "selector": c.get("css") or ""}


def locator_for(page, d: dict):
    if d.get("kind") == "role":
        return page.get_by_role(d["role"], name=d["name"], exact=False)
    return page.locator(d.get("selector") or "")


def visible_first(loc):
    try:
        n = loc.count()
    except Exception:  # noqa: BLE001
        return None
    for i in range(min(n, 8)):
        try:
            if loc.nth(i).is_visible():
                return loc.nth(i)
        except Exception:  # noqa: BLE001
            continue
    return None


def candidates(page) -> list:
    return page.evaluate(CANDIDATES_JS)


def matches(cands: list, words: list) -> list:
    out = []
    for c in cands:
        hay = (c.get("name", "") + " " + c.get("context", "")).lower()
        if any(w.lower() in hay for w in words):
            out.append(c)
    return out


NAV_NOISE = ("continue with", "terms", "privacy", "contact", "cookbook", "quickstart",
              "api reference", "developer docs", "documentation", "twitter", "linkedin",
              "youtube", "instagram", "threads", "sign in", "log in")


def ask_pick(cands: list, action: str, patterns: list, yes: bool) -> dict | None:
    hit = matches(cands, patterns)
    if not hit:
        cands = [c for c in cands if not any(x in (c.get("name", "") + " " + c.get("context", "")).lower() for x in NAV_NOISE)] or cands
    pool = hit or cands
    if not pool:
        return None
    if len(pool) == 1 and hit:
        return pool[0]
    if yes:
        return pool[0]
    if not sys.stdin.isatty():
        print("no unique %s control; rerun interactively to pick one" % action, file=sys.stderr)
        return None
    print("\nCandidate %s controls:" % action)
    for n, c in enumerate(pool[:40], 1):
        ctx = ("  | " + c["context"][:80]) if c.get("context") else ""
        print("  %2d. %-6s %-18s %s%s" % (n, c.get("tag"), c.get("role"), c.get("name", "")[:60], ctx))
    try:
        choice = input("choose 1-%d (0 abort): " % min(len(pool), 40)).strip()
    except EOFError:
        return None
    if not choice.isdigit() or not (1 <= int(choice) <= min(len(pool), 40)):
        return None
    return pool[int(choice) - 1]


def confirm(prompt: str, yes: bool) -> bool:
    if yes:
        return True
    if not sys.stdin.isatty():
        return False
    try:
        return input(prompt + " [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def fill_name(page, patterns: list, value: str) -> bool:
    try:
        inputs = page.locator('input[type="text"], input:not([type]), input[type="search"]')
        for i in range(min(inputs.count(), 10)):
            el = inputs.nth(i)
            if not el.is_visible():
                continue
            meta = " ".join([
                el.get_attribute("placeholder") or "",
                el.get_attribute("aria-label") or "",
                el.get_attribute("name") or "",
                el.get_attribute("id") or "",
            ]).lower()
            if any(w.lower() in meta for w in patterns):
                el.fill(value)
                return True
        return False
    except Exception:  # noqa: BLE001
        return False


def dialog_confirm(page, patterns: list, yes: bool) -> bool:
    try:
        dlg = page.locator('[role="dialog"], [aria-modal="true"]')
        if dlg.count() == 0:
            return False
        cands = page.evaluate(CANDIDATES_JS)
        hit = matches(cands, patterns)
        if not hit:
            return False
        target = hit[0]
        loc = locator_for(page, derive_locator(target))
        el = visible_first(loc)
        if el:
            el.click()
            return True
    except Exception:  # noqa: BLE001
        return False
    return False


def extract_key(page, prefix: str) -> str:
    pat = re.compile(r"(?<![A-Za-z0-9_])(" + re.escape(prefix) + r"[A-Za-z0-9_\-]{8,})(?![A-Za-z0-9_])")
    try:
        data = page.evaluate(EXTRACT_JS)
    except Exception:  # noqa: BLE001
        data = {"values": [], "body": ""}
    found = []
    for text in (data.get("values") or []) + [data.get("body") or ""]:
        found.extend(pat.findall(str(text)))
    if found:
        return max(found, key=len)
    return ""


def _popen(cmd, stdin_data: bytes | None = None, timeout: int = 5):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.PIPE if stdin_data is not None else None)
    out, err = p.communicate(stdin_data, timeout=timeout)
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def read_clipboard() -> str:
    if os.environ.get("WAYLAND_DISPLAY"):
        rc, out, _ = _popen(["wl-paste", "--no-newline"])
        if rc == 0:
            return out.strip()
    rc, out, _ = _popen(["xclip", "-selection", "clipboard", "-o"])
    return out.strip() if rc == 0 else ""


def clear_clipboard() -> None:
    try:
        if os.environ.get("WAYLAND_DISPLAY"):
            _popen(["wl-copy", "--clear"])
        else:
            _popen(["xclip", "-selection", "clipboard"], stdin_data=b"")
    except Exception:  # noqa: BLE001
        pass


def write_env(path: Path, var: str, key: str, ts: str) -> Path:
    path = Path(path)
    backup = path.with_name(path.name + ".bak.guided." + ts)
    shutil.copy2(path, backup)
    os.chmod(backup, 0o600)
    line = var + "=" + key + "\n"
    out, seen = [], False
    pat = re.compile(r"^(?:(?:# PAUSED \S+ )?)" + re.escape(var) + r"=")
    for ln in path.read_text(encoding="utf-8").splitlines(keepends=True):
        if pat.match(ln):
            out.append(line)
            seen = True
        else:
            out.append(ln)
    if not seen:
        out.append(line)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".env.guided.")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("".join(out))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return backup


def remember_or_ask(page, provider, action, cfg, yes, no_learn) -> bool:
    url = page.url
    loc = recall(provider, action)
    if loc:
        el = visible_first(locator_for(page, loc))
        if el is not None:
            print("  remembered %s locator: %s" % (action, json.dumps(loc, sort_keys=True)))
            if confirm("  click this %s control?" % action, yes):
                el.click()
                if not no_learn:
                    remember(provider, action, loc, True, url, "remembered")
                log_run(provider, action, "click", True, url, "remembered")
                return True
        else:
            if not no_learn:
                remember(provider, action, loc, False, url, "remembered locator not visible (page drift)")
            log_run(provider, action, "recall", False, url, "remembered locator not visible")
    cands = candidates(page)
    chosen = ask_pick(cands, action, cfg.get("patterns", {}).get(action, []), yes)
    if not chosen:
        log_run(provider, action, "find", False, url, "no control chosen")
        return False
    loc = derive_locator(chosen)
    print("  target: %s %r  %s" % (chosen.get("role"), chosen.get("name"), ("| " + chosen.get("context", "")) if chosen.get("context") else ""))
    if not confirm("  click this %s control?" % action, yes):
        return False
    el = visible_first(locator_for(page, loc))
    if el is None:
        log_run(provider, action, "click", False, page.url, "locator not visible")
        return False
    el.click()
    if not no_learn:
        remember(provider, action, loc, True, url, "operator-picked")
    log_run(provider, action, "click", True, page.url, "operator-picked")
    return True


LOGIN_URL_HINTS = ("login", "signin", "sign-in", "oauth", "auth")
REJECT_HINTS = ("signin/rejected", "access blocked", "couldn't sign you in",
                "couldn’t sign you in", "could not sign you in", "sign-in was rejected")
LOGIN_BODY_HINTS = ("continue with google", "continue with email", "continue with sso",
                    "sign in to", "log in to")
KEYS_BODY_HINTS = ("api key", "api keys", "create key", "new key", "revoke", "delete key")


def login_state(page, cfg) -> str:
    """Return ok | login | rejected | unknown for the current page."""
    try:
        url = page.url.lower()
    except Exception:  # noqa: BLE001
        url = ""
    try:
        body = (page.locator("body").inner_text() or "").lower()[:12000]
    except Exception:  # noqa: BLE001
        body = ""
    if any(k in url or k in body for k in REJECT_HINTS):
        return "rejected"
    try:
        pw = page.locator('input[type="password"]').count()
    except Exception:  # noqa: BLE001
        pw = 0
    if pw or any(k in body for k in LOGIN_BODY_HINTS) or any(k in url for k in LOGIN_URL_HINTS):
        return "login"
    if any(k in body for k in KEYS_BODY_HINTS):
        return "ok"
    return "unknown"


def wait_login(page, args, cfg) -> bool:
    """Verify authentication; never assume the operator logged in."""
    for attempt in range(6):
        page.wait_for_timeout(1200)
        st = login_state(page, cfg)
        if st == "ok":
            print("  logged in: %s" % page.url)
            return True
        if st == "rejected":
            print("FAIL: the vendor rejected the sign-in (page: %s)" % page.url, file=sys.stderr)
            print("  Google returned signin/rejected. Use 'Continue with email' or 'Continue with SSO'", file=sys.stderr)
            print("  with an account that has access, then re-run --action login.", file=sys.stderr)
            log_run(args.provider, args.action, "login", False, page.url, "vendor rejected sign-in")
            return False
        if st == "login":
            if not sys.stdin.isatty():
                print("login required; rerun interactively (or --action login) first", file=sys.stderr)
                return False
            print("\nNot logged in (%s). Log in in the opened browser window; the profile persists." % cfg.get("console"))
            print("If a popup was rejected, close it and use 'Continue with email' or 'Continue with SSO'.")
            print("Press Enter here only after you can see the API keys page...")
            try:
                input()
            except EOFError:
                return False
            continue
        # unknown: a dashboard or an unexpected page; let the operator reach the keys page
        if not sys.stdin.isatty():
            print("FAIL: not on an API keys page (%s)" % page.url, file=sys.stderr)
            return False
        print("\nWaiting for the API keys page (%s)." % page.url)
        print("Navigate to the keys page in the browser, then press Enter here (Ctrl-C aborts)...")
        try:
            input()
        except EOFError:
            return False
    print("FAIL: still not logged in after retries (%s)" % page.url, file=sys.stderr)
    log_run(args.provider, args.action, "login", False, page.url, "not logged in after retries")
    return False


def request_path() -> Path:
    return Path(os.environ.get("ROTATION_REQUEST") or
                (repo_root() / "data" / "observability" / "key-request.json"))


def apply_request(args) -> int:
    """Host side: apply a key queued from /app/#settings and remove the request.

    The request is written by the dashboard (mode 0600) in the shared data dir.
    This runs as the host user (systemd user path unit or manually), writes
    .env.local atomically with a backup, and deletes the request. The key is
    validated by prefix/length and never printed.
    """
    p = request_path()
    if not p.is_file():
        print("no pending key request at %s" % p)
        return 0
    try:
        req = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        print("FAIL: cannot read key request (%s)" % e, file=sys.stderr)
        return 1
    provider = str(req.get("provider") or "").strip()
    key = str(req.get("key") or "").strip()
    env = str(req.get("env") or "").strip()
    cfg = load_providers().get(provider)
    if not cfg:
        print("FAIL: unknown provider in request: %r" % provider, file=sys.stderr)
        return 1
    if env and env != cfg["env"]:
        print("FAIL: env mismatch in request (%s != %s)" % (env, cfg["env"]), file=sys.stderr)
        return 1
    need = max(12, len(cfg["prefix"]) + 8)
    if not (key.startswith(cfg["prefix"]) and len(key) >= need):
        print("FAIL: request key does not look like a %s key (len %d)" % (cfg["prefix"], len(key)), file=sys.stderr)
        return 1
    envf = Path(args.env_file)
    if not envf.is_file():
        print("FAIL: env file missing: %s" % envf, file=sys.stderr)
        return 1
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = write_env(envf, cfg["env"], key, ts)
    try:
        p.unlink()
    except OSError as e:  # noqa: BLE001
        print("WARN: request not removed (%s)" % e, file=sys.stderr)
    print("applied %s (len %d, value not printed)" % (cfg["env"], len(key)))
    print("backup: %s (contains the old key; purge with ./scripts/scrub-secrets.sh --apply --yes --purge-env-backups)" % backup)
    if getattr(args, "restart", False):
        print("restarting the web container to load the new key...")
        rc, _out, _err = _popen([str(repo_root() / "scripts" / "web-restart.sh")], timeout=240)
        print("restart: rc=%s" % rc)
        if rc != 0:
            print("WARN: restart failed; run ./scripts/web-restart.sh", file=sys.stderr)
    else:
        print("next: ./scripts/web-restart.sh")
    log_run(provider, "apply-request", "write", True, "", "host")
    return 0


def capture_key(args, cfg) -> int:
    """Read the key the operator copied in the vendor page and write .env.local.

    No browser and no vendor clicks: the operator does the revoke/create in the
    already-open Chrome, clicks Copy, and this atomically writes the variable.
    The key is never printed; the value is validated by prefix and length.
    """
    got = read_clipboard()
    need = max(12, len(cfg["prefix"]) + 8)
    if not (got.startswith(cfg["prefix"]) and len(got) >= need):
        print("clipboard does not hold a %s key" % cfg["prefix"], file=sys.stderr)
        if not sys.stdin.isatty():
            return 1
        import getpass
        got = getpass.getpass("paste the new %s key (hidden), or Enter to abort: " % cfg["env"]).strip()
    if not got:
        return 1
    if not (got.startswith(cfg["prefix"]) and len(got) >= need):
        print("FAIL: value does not look like a %s key (len %d)" % (cfg["prefix"], len(got)), file=sys.stderr)
        return 1
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = write_env(Path(args.env_file), cfg["env"], got, ts)
    clear_clipboard()
    print("updated %s in %s (mode 600, %d chars)" % (cfg["env"], args.env_file, len(got)))
    print("backup: %s (contains the old key; purge with ./scripts/scrub-secrets.sh --apply --yes --purge-env-backups)" % backup)
    print("next: ./scripts/web-restart.sh")
    print("note: if this provider is paused in /settings, resume/clear it before settings-apply, or the new key will be commented")
    log_run(args.provider, "capture", "write", True, "", "clipboard")
    return 0


def goto_retry(page, url: str, timeout: int) -> bool:
    """Navigate with a generous bound + one retry (console pages redirect and are heavy)."""
    last = None
    for _ in range(2):
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=max(timeout, 60000))
            return True
        except Exception as e:  # noqa: BLE001
            last = e
            try:
                page.wait_for_timeout(1500)
            except Exception:  # noqa: BLE001
                pass
    print("FAIL: navigation failed: %s (%s)" % (url, last), file=sys.stderr)
    return False


def run_browser(args, cfg) -> int:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # noqa: BLE001
        print("FAIL: Playwright missing (%s)" % e, file=sys.stderr)
        print("  run: ./scripts/browser-python.sh scripts/rotate-guided.py ...", file=sys.stderr)
        return 2
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    shots = repo_root() / "logs" / ("rotation-" + ts)
    shots.mkdir(parents=True, exist_ok=True)
    provider = args.provider
    action = args.action
    key = ""
    mode = choose_browser_mode(args)
    print("browser mode: %s" % mode)
    with sync_playwright() as p:
        owned = None
        browser = None
        if mode in ("cdp", "chrome-cdp"):
            if mode == "chrome-cdp" and not cdp_reachable(args.cdp):
                if not launch_chrome(args):
                    return 2
            try:
                browser = p.chromium.connect_over_cdp(args.cdp)
            except Exception as e:  # noqa: BLE001
                print("FAIL: cannot connect to Chrome CDP at %s (%s)" % (args.cdp, e), file=sys.stderr)
                print("  start: %s" % chrome_hint(args), file=sys.stderr)
                return 2
            context = browser.contexts[0] if browser.contexts else browser.new_context()
        else:
            kwargs = {"headless": args.headless, "ignore_https_errors": True,
                      "viewport": {"width": 1280, "height": 900}}
            if mode == "chrome":
                kwargs.update(channel="chrome", ignore_default_args=["--enable-automation"],
                              args=["--disable-blink-features=AutomationControlled"])
            context = p.chromium.launch_persistent_context(str(profile_dir()), **kwargs)
            owned = context
        try:
            page = context.new_page()
            page.set_default_timeout(args.timeout)
            page.set_default_navigation_timeout(max(args.timeout, 60000))
            page.on("dialog", lambda d: d.accept())
            if not goto_retry(page, cfg["console"], args.timeout):
                return 1
            if not wait_login(page, args, cfg):
                return 2
            target = cfg["console"] if action == "login" else (recall_url(provider, action, cfg["console"]) or cfg["console"])
            if not goto_retry(page, target, args.timeout):
                return 1
            page.wait_for_timeout(1000)
            if target != cfg["console"]:
                print("  navigating to remembered page: %s" % target)
            if not wait_login(page, args, cfg):
                return 2
            if action == "login":
                where = args.cdp if mode in ("cdp", "chrome-cdp") else str(profile_dir())
                print("login profile verified (%s)" % where)
                return 0
            if action == "open":
                print("keys page open: %s" % page.url)
                print("Do the revoke/create in this browser, click Copy on the new key,")
                print("then run: ./scripts/browser-python.sh scripts/rotate-guided.py --provider %s --action capture" % provider)
                return 0
            if action in ("revoke", "rotate"):
                if not remember_or_ask(page, provider, "revoke", cfg, args.yes, args.no_learn):
                    page.screenshot(path=str(shots / "revoke-not-found.png"))
                    print("FAIL: could not find a revoke control", file=sys.stderr)
                    return 1
                page.wait_for_timeout(1000)
                dialog_confirm(page, cfg.get("patterns", {}).get("confirm", []), args.yes)
                page.wait_for_timeout(1200)
                print("  revoked (confirm dialog handled if present)")
            if action in ("create", "rotate"):
                if not remember_or_ask(page, provider, "create", cfg, args.yes, args.no_learn):
                    page.screenshot(path=str(shots / "create-not-found.png"))
                    print("FAIL: could not find a create control", file=sys.stderr)
                    return 1
                page.wait_for_timeout(1200)
                fill_name(page, cfg.get("patterns", {}).get("name", []), args.key_name or ("opencode-" + ts[:8]))
                page.wait_for_timeout(300)
                # Only click a dialog submit that actually matches a create keyword.
                subs = matches(candidates(page), ["create", "generate", "save", "done", "confirm"])
                if subs:
                    sub = subs[0] if args.yes else ask_pick(subs, "create-submit", [], args.yes)
                    if sub:
                        el = visible_first(locator_for(page, derive_locator(sub)))
                        if el:
                            el.click()
                elif not args.yes:
                    print("  no create-submit found; click Create in the browser, then press Enter here...")
                    try:
                        input()
                    except EOFError:
                        pass
                page.wait_for_timeout(1600)
                key = extract_key(page, cfg["prefix"])
                if not key and args.clipboard:
                    print("\nKey not found in the DOM. Click Copy in the browser, then press Enter here (clipboard is read once and cleared)...")
                    try:
                        input()
                    except EOFError:
                        pass
                    got = read_clipboard()
                    if got.startswith(cfg["prefix"]) and len(got) >= 12:
                        key = got
                    clear_clipboard()
                if not key:
                    print("FAIL: could not read the new key (no screenshot taken after reveal)", file=sys.stderr)
                    log_run(provider, action, "reveal", False, page.url, "key not found")
                    return 1
                print("  new key read: %s (%d chars, value not printed)" % (cfg["env"], len(key)))
                log_run(provider, action, "reveal", True, page.url, "key read")
                if not args.no_write:
                    backup = write_env(Path(args.env_file), cfg["env"], key, ts)
                    print("  updated %s in %s (mode 600)" % (cfg["env"], args.env_file))
                    print("  backup: %s (contains the old key; purge with ./scripts/scrub-secrets.sh --apply --yes --purge-env-backups)" % backup)
                    if args.recreate:
                        rc, out, err = _popen([str(repo_root() / "scripts" / "web-restart.sh")], timeout=180)
                        print("  recreate: rc=%s" % rc)
                    else:
                        print("  next: ./scripts/web-restart.sh  (or docker compose ... up -d --force-recreate opencode-web)")
                print("  rotate complete for %s" % provider)
        finally:
            if owned is not None:
                try:
                    owned.close()
                except Exception:  # noqa: BLE001
                    pass
            elif browser is not None:
                # Connected over CDP: do NOT close the real Chrome. The profile
                # (and the login) must survive for the next rotation; closing the
                # browser here was why the next run relaunched Chrome.
                print("  leaving real Chrome open for the next rotation (CDP %s)" % args.cdp)
    return 0


def self_test() -> int:
    work = Path(tempfile.mkdtemp())
    db = work / "obs.db"
    env = work / "env.local"
    os.environ["ROTATION_DB"] = str(db)
    env.write_text("DEEPSEEK_API_KEY=old\nOTHER=keep\n", encoding="utf-8")
    os.chmod(env, 0o600)
    loc = {"kind": "role", "role": "button", "name": "Revoke"}
    remember("deepseek", "revoke", loc, True, "https://example.test/keys", "self-test")
    remember("deepseek", "revoke", loc, True, "https://example.test/keys", "self-test")
    got = recall("deepseek", "revoke")
    assert got == loc, got
    con = connect()
    row = con.execute("SELECT successes, failures FROM rotation_memory WHERE provider='deepseek'").fetchone()
    con.close()
    assert row == (2, 0), row
    assert redact("x sk-abcdefgh12345678 y") == "x [REDACTED] y"
    key = "sk-" + "z" * 24
    backup = write_env(env, "DEEPSEEK_API_KEY", key, "20260101T000000Z")
    text = env.read_text(encoding="utf-8")
    assert "DEEPSEEK_API_KEY=" + key in text, "env not written"
    assert "OTHER=keep" in text, "unrelated env line lost"
    assert oct(env.stat().st_mode & 0o777) == "0o600", "mode not 600"
    assert backup.exists(), "backup missing"
    # paused line is replaced, not duplicated
    env.write_text("# PAUSED 20260101T000000Z DEEPSEEK_API_KEY=old\n", encoding="utf-8")
    write_env(env, "DEEPSEEK_API_KEY", key, "20260101T000001Z")
    assert env.read_text(encoding="utf-8").count("DEEPSEEK_API_KEY=") == 1, "paused line duplicated"
    # apply-request: queued key -> env write -> request removed
    env2 = work / "env2.local"
    env2.write_text("DEEPSEEK_API_KEY=old\n", encoding="utf-8")
    os.chmod(env2, 0o600)
    req = work / "key-request.json"
    req.write_text(json.dumps({"provider": "deepseek", "env": "DEEPSEEK_API_KEY",
                               "key": "sk-" + "q" * 24}), encoding="utf-8")
    prev = os.environ.get("ROTATION_REQUEST")
    os.environ["ROTATION_REQUEST"] = str(req)
    rc = apply_request(argparse.Namespace(env_file=str(env2), restart=False))
    if prev is None:
        os.environ.pop("ROTATION_REQUEST", None)
    else:
        os.environ["ROTATION_REQUEST"] = prev
    assert rc == 0, "apply-request rc=%s" % rc
    assert not req.exists(), "request not removed"
    assert ("DEEPSEEK_API_KEY=sk-" + "q" * 24) in env2.read_text(encoding="utf-8"), "env not applied"
    shutil.rmtree(work, ignore_errors=True)
    print("rotate-guided: self-test PASS (memory recall/upsert + redaction + env write + paused line + apply-request)")
    return 0


def cdp_self_test(args) -> int:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # noqa: BLE001
        print("FAIL: Playwright missing (%s)" % e, file=sys.stderr)
        return 2
    if not cdp_reachable(args.cdp):
        print("SKIP: no CDP endpoint at %s (start Chrome with --remote-debugging-port)" % args.cdp, file=sys.stderr)
        return 2
    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(args.cdp)
        try:
            context = browser.contexts[0] if browser.contexts else browser.new_context()
            page = context.new_page()
            page.set_content('<html><body><h1>API keys</h1><button>Create key</button></body></html>')
            names = [c.get("name") for c in candidates(page)]
            assert "Create key" in names, names
            assert login_state(page, {}) == "ok", "keys page not detected over CDP"
        finally:
            try:
                browser.close()
            except Exception:  # noqa: BLE001
                pass
    print("rotate-guided: CDP self-test PASS (attach + candidates + login state)")
    return 0


def browser_self_test() -> int:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # noqa: BLE001
        print("FAIL: Playwright missing (%s); run with ./scripts/browser-python.sh" % e, file=sys.stderr)
        return 2
    html = ('<html><body><table><tr><td>Key A</td>'
            '<td><button aria-label="Revoke">Revoke</button></td></tr></table>'
            '<button>Create key</button></body></html>')
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.set_content(html)
            cs = candidates(page)
            names = [c.get("name") for c in cs]
            assert "Revoke" in names, names
            revoke = next(c for c in cs if c.get("name") == "Revoke")
            loc = derive_locator(revoke)
            assert loc.get("kind") == "role" and loc.get("name") == "Revoke", loc
            assert visible_first(locator_for(page, loc)) is not None, "locator did not resolve"
            assert "Create key" in names, names
            login_page = browser.new_page()
            login_page.set_content('<html><body><button>Continue with Google</button></body></html>')
            assert login_state(login_page, {}) == "login", "login page not detected"
            keys_page = browser.new_page()
            keys_page.set_content('<html><body><h1>API keys</h1><button>Create key</button></body></html>')
            assert login_state(keys_page, {}) == "ok", "keys page not detected"
            reject_page = browser.new_page()
            reject_page.set_content("<html><body><h1>Couldn't sign you in</h1></body></html>")
            assert login_state(reject_page, {}) == "rejected", "rejection not detected"
        finally:
            browser.close()
    print("rotate-guided: browser self-test PASS (candidates + locator + login/reject detection)")
    return 0


def report() -> int:
    con = connect()
    mem = con.execute("SELECT provider,action,locator,successes,failures,last_ok,last_fail FROM rotation_memory ORDER BY provider,action").fetchall()
    runs = con.execute("SELECT ts,provider,action,step,ok,url FROM rotation_run ORDER BY id DESC LIMIT 15").fetchall()
    con.close()
    print("=== rotation memory ===")
    if not mem:
        print("  (empty; first rotation will learn)")
    for r in mem:
        print("  %-10s %-7s ok=%-3s fail=%-3s %s" % (r[0], r[1], r[3], r[4], r[2]))
    print("=== recent runs ===")
    for r in runs:
        print("  %s %-10s %-7s %-8s ok=%s %s" % (r[0], r[1], r[2], r[3], r[4], r[5]))
    return 0


def plan(args) -> int:
    provs = load_providers()
    for pid, cfg in provs.items():
        if args.provider and pid != args.provider:
            continue
        loc = recall(pid, "revoke")
        cloc = recall(pid, "create")
        print("%-10s console=%s" % (pid, cfg["console"]))
        print("           env=%s prefix=%s%s" % (cfg["env"], cfg["prefix"], " (local)" if cfg.get("local") else ""))
        print("           revoke=%s" % (json.dumps(loc, sort_keys=True) if loc else "learn on first run"))
        print("           create=%s" % (json.dumps(cloc, sort_keys=True) if cloc else "learn on first run"))
    return 0


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Playwright-guided, learning key rotation")
    ap.add_argument("--provider", default="", help="deepseek|anthropic|subq|jev|gemini|litellm")
    ap.add_argument("--action", default="rotate", choices=["login", "open", "revoke", "create", "rotate", "capture", "apply-request"])
    ap.add_argument("--env-file", default=str(env_path()))
    ap.add_argument("--key-name", default="")
    ap.add_argument("--browser", default="auto", choices=["auto", "chrome-cdp", "cdp", "chrome", "chromium"])
    ap.add_argument("--cdp", default=os.environ.get("ROTATION_CDP", "http://127.0.0.1:9222"))
    ap.add_argument("--cdp-port", type=int, default=9222)
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--no-learn", action="store_true")
    ap.add_argument("--no-write", action="store_true")
    ap.add_argument("--clipboard", action="store_true", default=True)
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--restart", action="store_true", help="apply-request: restart opencode-web to load the key")
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--reset-login", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--list-providers", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--browser-self-test", action="store_true")
    ap.add_argument("--cdp-self-test", action="store_true")
    ap.add_argument("--timeout", type=int, default=20000)
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    if args.reset_login:
        shutil.rmtree(profile_dir(), ignore_errors=True)
        shutil.rmtree(chrome_profile_dir(), ignore_errors=True)
        profile_dir()
        chrome_profile_dir()
        print("cleared login profiles: %s ; %s" % (profile_dir(), chrome_profile_dir()))
        return 0
    if args.self_test:
        return self_test()
    if args.browser_self_test:
        return browser_self_test()
    if args.cdp_self_test:
        return cdp_self_test(args)
    if args.report:
        return report()
    if args.list_providers:
        print(" ".join(sorted(load_providers())))
        return 0
    if args.plan:
        return plan(args)
    provs = load_providers()
    if args.action == "apply-request":
        return apply_request(args)
    if not args.provider:
        print("--provider required (one of: %s)" % ", ".join(sorted(provs)), file=sys.stderr)
        return 2
    cfg = provs.get(args.provider)
    if not cfg:
        print("unknown provider %r (one of: %s)" % (args.provider, ", ".join(sorted(provs))), file=sys.stderr)
        return 2
    if args.reset:
        con = connect()
        con.execute("DELETE FROM rotation_memory WHERE provider=?", (args.provider,))
        con.commit()
        con.close()
        print("forgot learned locators for %s" % args.provider)
        return 0
    if cfg.get("local"):
        print("%s is generated locally; use ./scripts/rotate-provider-keys.sh" % args.provider)
        return 2
    if not Path(args.env_file).is_file():
        print("env file missing: %s (run this on the host)" % args.env_file, file=sys.stderr)
        return 2
    if args.action == "capture":
        return capture_key(args, cfg)
    return run_browser(args, cfg)


if __name__ == "__main__":
    sys.exit(main())
