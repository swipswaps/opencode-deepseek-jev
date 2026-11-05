#!/usr/bin/env bash
#
# scan-chat-secrets.sh — value-free scan of the OpenCode chat DB.
#
# The 2026-11-05 leak was pasted into the terminal and the chat store, not
# only into logs/. secret-scan.sh deliberately skips *.db, so the chat DB was
# the one store the at-rest scan could not see. This closes that gap.
#
# It reads the DB read-only, walks the text/reasoning/tool strings in
# part.data, and reports session:part [kind] only. It never prints a value.
#
#   ./scripts/scan-chat-secrets.sh
#   ./scripts/scan-chat-secrets.sh --limit 2000
#   ./scripts/scan-chat-secrets.sh --all
#   ./scripts/scan-chat-secrets.sh --db ~/.local/share/opencode/opencode.db
#   ./scripts/scan-chat-secrets.sh --json
#   ./scripts/scan-chat-secrets.sh --self-test
#
# Defaults: the newest 5000 part rows; --all scans every row (slow on a large
# DB). Exit 0 clean, 1 findings, 2 usage/DB error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

find_db() {
    local c
    for c in \
        "${CHAT_DB:-}" \
        "$HOME/.local/share/opencode/opencode.db" \
        "$REPO/data/opencode/opencode.db" \
        "/home/owner/.local/share/opencode/opencode.db" \
        "/home/node/.local/share/opencode/opencode.db"; do
        [ -n "$c" ] || continue
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

scan_py() {
    # scan_py DB LIMIT ALL CERT_DIR TLS_CHECK — LIMIT 0 means all rows.
    # Prints value-free JSON; TLS_CHECK compares PEM blocks to live *.key
    # files and reports only the filename/session/part on a match.
    python3 - "$@" << 'PYEOF'
import json, os, re, sqlite3, sys

db, limit_s, all_s, cert_dir, tls_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
limit = 0 if all_s == "1" else max(1, int(limit_s))
tls_check = tls_s == "1"
PATTERNS = [
    ("deepseek_key", re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9]{20,}")),
    ("jev_key", re.compile(r"apikey_[A-Za-z0-9_]{16,}")),
    ("bearer_token", re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{16,}")),
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("env_assignment", re.compile(
        r"(?:^|[^A-Za-z0-9])[A-Z][A-Z0-9_]*(?:API_KEY|PASSWORD|SECRET|TOKEN|MASTER_KEY)\s*=\s*\S{8,}")),
    ("server_password", re.compile(r"(?i)OPENCODE_SERVER_PASSWORD\s*=\s*\S{8,}")),
]
SKIP_KEYS = {"id", "session_id", "message_id", "time_created", "time_updated"}
PEM_RE = re.compile("-----BEGIN " + r"([A-Z ]*)PRIVATE KEY-----.*?-----END \1PRIVATE KEY-----", re.S)
LIVE_KEYS = {}
if tls_check and cert_dir and os.path.isdir(cert_dir):
    for name in sorted(os.listdir(cert_dir)):
        if not name.endswith(".key"):
            continue
        try:
            with open(os.path.join(cert_dir, name), encoding="utf-8", errors="replace") as fh:
                LIVE_KEYS[name] = fh.read().strip().replace("\r\n", "\n")
        except OSError:
            continue

def strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            if k in SKIP_KEYS:
                continue
            yield from strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings(v)

try:
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
except Exception as e:
    print(json.dumps({"error": "open: %s" % e}))
    raise SystemExit(2)
q = "SELECT session_id, id, data FROM part ORDER BY time_created DESC"
if limit:
    q += " LIMIT %d" % limit
try:
    rows = con.execute(q).fetchall()
except Exception as e:
    print(json.dumps({"error": "query: %s" % e}))
    raise SystemExit(2)
finally:
    con.close()

findings = []
tls_matches = []
scanned = 0
for sid, pid, data in rows:
    try:
        obj = json.loads(data)
    except Exception:
        continue
    scanned += 1
    seen = set()
    ctx = {"type": str(obj.get("type", "")) if isinstance(obj, dict) else "",
           "tool": str(obj.get("tool", "")) if isinstance(obj, dict) else ""}
    for text in strings(obj):
        if not text:
            continue
        for kind, rx in PATTERNS:
            if kind in seen:
                continue
            if rx.search(text):
                seen.add(kind)
                findings.append({"session": sid, "part": pid, "kind": kind,
                                 "type": ctx["type"], "tool": ctx["tool"]})
        if tls_check and LIVE_KEYS:
            for m in PEM_RE.finditer(text):
                block = m.group(0).strip().replace("\r\n", "\n")
                for name, live_text in LIVE_KEYS.items():
                    if block == live_text and not any(
                            x["file"] == name and x["session"] == sid and x["part"] == pid
                            for x in tls_matches):
                        tls_matches.append({"file": name, "session": sid,
                                            "part": pid, "type": ctx["type"],
                                            "tool": ctx["tool"]})
print(json.dumps({"scanned": scanned, "count": len(findings), "findings": findings,
                  "tls_checked": tls_check, "tls_matches": tls_matches}))
PYEOF
}

report() {
    printf '%s' "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("=== chat-secret-scan: %d finding(s) in %d part(s) ===" % (d.get("count",0), d.get("scanned",0)))
for f in d.get("findings", []):
    extra = " ".join(x for x in ("type=" + f.get("type",""), "tool=" + f.get("tool","")) if not x.endswith("="))
    print("  %s:%s  [%s%s]" % (f["session"], f["part"], f["kind"], (" " + extra) if extra else ""))
for m in d.get("tls_matches", []):
    print("  LIVE TLS KEY %s  %s:%s" % (m["file"], m["session"], m["part"]))'
}

self_test() {
    local work="" out="" fail=0
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    mkdir -p "$work/certs"
    python3 - "$work/fixture.db" "$work/certs" << 'PYEOF'
import json, os, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
certdir = sys.argv[2]
con.execute("CREATE TABLE part (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
dirty = "sk-" + "a" * 30
clean = "all good, no keys here"
begin = "-----BEGIN " + "RSA PRIVATE KEY" + "-----"
end = "-----END " + "RSA PRIVATE KEY" + "-----"
pem = begin + "\nFAKEKEYMATERIAL\n" + end + "\n"
with open(os.path.join(certdir, "fake.key"), "w") as fh:
    fh.write(pem)
con.execute("INSERT INTO part VALUES (?,?,?,?)",
            ("p_dirty", "s1", 1, json.dumps({"type": "text", "text": "OPENCODE_SERVER_PASSWORD=" + "x" * 24})))
con.execute("INSERT INTO part VALUES (?,?,?,?)",
            ("p_key", "s1", 2, json.dumps({"type": "text", "text": dirty})))
con.execute("INSERT INTO part VALUES (?,?,?,?)",
            ("p_clean", "s2", 3, json.dumps({"type": "text", "text": clean})))
con.execute("INSERT INTO part VALUES (?,?,?,?)",
            ("p_pem", "s3", 4, json.dumps({"type": "text", "text": pem})))
con.commit()
con.close()
PYEOF
    out=$(bash "${BASH_SOURCE[0]}" --db "$work/fixture.db" --all --json 2>&1)
    printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] >= 2, "count"; assert all(set(("session","part","kind")) <= set(f) for f in d["findings"]), "shape"' \
        || { printf 'FAIL json contract\n'; fail=1; }
    printf '%s' "$out" | grep -q "aaaaaaaaaaaaaaaaaaaa" && { printf 'FAIL report leaked value\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" --db "$work/fixture.db" --all --cert-dir "$work/certs" --tls-check --json 2>&1)
    printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d.get("tls_matches", [])) == 1, "tls match"; assert d["tls_matches"][0]["file"] == "fake.key", "file"' \
        || { printf 'FAIL tls match\n'; fail=1; }
    printf '%s' "$out" | grep -q "FAKEKEYMATERIAL" && { printf 'FAIL tls value leaked\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --db "$work/fixture.db" --all > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL dirty exits 1\n'; fail=1; }
    rm -f "$work/fixture.db" "$work/certs/fake.key"
    rmdir "$work/certs" "$work"
    if [ "$fail" -eq 0 ]; then printf 'scan-chat-secrets: self-test PASS\n'; else printf 'scan-chat-secrets: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local DB="" LIMIT=5000 ALL=0 JSON=0 QUIET=0 SELFTEST=0 TLS=0 CERTDIR=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            --limit) LIMIT="${2:-5000}"; shift 2 ;;
            --limit=*) LIMIT="${1#--limit=}"; shift ;;
            --all) ALL=1; shift ;;
            --tls-check) TLS=1; shift ;;
            --cert-dir) CERTDIR="${2:-}"; shift 2 ;;
            --cert-dir=*) CERTDIR="${1#--cert-dir=}"; shift ;;
            --json) JSON=1; shift ;;
            --quiet) QUIET=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help)
                printf 'usage: %s [--db PATH] [--limit N] [--all] [--tls-check] [--cert-dir DIR] [--json] [--quiet] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'GATE FAIL: cannot resolve repo root\n'; return 2; fi
    [ -z "$CERTDIR" ] && CERTDIR="$REPO/docker/certs"
    if [ -z "$DB" ]; then
        DB=$(find_db) || { printf 'GATE FAIL: no chat DB found (use --db PATH)\n'; return 2; }
    fi
    [ -f "$DB" ] || { printf 'GATE FAIL: no DB at %s\n' "$DB"; return 2; }
    local out count tls_count
    out=$(scan_py "$DB" "$LIMIT" "$ALL" "$CERTDIR" "$TLS" 2>&1)
    case "$out" in
        *'"error"'*) printf 'GATE FAIL: %s\n' "$out"; return 2 ;;
    esac
    count=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' 2>&1)
    case "${count:-x}" in
        ''|*[!0-9]*) printf 'GATE FAIL: scan error\n'; return 2 ;;
    esac
    tls_count=$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tls_matches", [])))' 2>&1)
    case "${tls_count:-x}" in
        ''|*[!0-9]*) tls_count=0 ;;
    esac
    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' "$out"
    elif [ "$QUIET" -eq 0 ]; then
        report "$out"
        if [ "$count" -gt 0 ]; then
            printf '\nCHAT SECRETS: rotate the credential, then do not re-paste it.\n'
            printf '  This DB is read-only; rotation is the fix (rotate-api-keys.sh,\n'
            printf '  rotate-provider-keys.sh, rotate-server-password.sh, or the console).\n'
        fi
        if [ "$tls_count" -gt 0 ]; then
            printf '\nLIVE TLS KEY FOUND IN CHAT DB: rotate the cert pair now.\n'
            printf '  ./scripts/rotate-tls.sh --apply --yes\n'
        fi
    fi
    [ "$count" -gt 0 ] && return 1
    [ "$tls_count" -gt 0 ] && return 1
    [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ] && printf 'chat-secret-scan: clean\n'
    return 0
}

main "$@"
exit $?
