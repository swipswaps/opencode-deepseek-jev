#!/usr/bin/env bash
#
# secret-scan.sh — find secrets AT REST in artifacts and guide rotation.
#
# The transcript/log problem: a pasted `env` block or a shell echo can land a
# live key in logs/ (transcripts, guard.log, dashboard dumps). Those files are
# copied, pasted, and read back by models — so a leak at rest outlives the
# session. The redaction in handoff-brief.sh protects the EXPORT path; this
# protects the STORE and tells the operator which rotation tool to run.
#
# It never prints the secret value: findings are `file:line:kind` only, so the
# scan report is itself safe to paste or keep.
#
#   ./scripts/secret-scan.sh [--paths "logs data/observability"] [--quiet]
#   ./scripts/secret-scan.sh --json
#   ./scripts/secret-scan.sh --self-test      # offline fixture
#
# Exit 0 = clean, 1 = findings (rotate), 2 = usage/resolve error.
# Defaults scan the sibling notes/ dir plus logs/ and data/observability/.
# .env.local is deliberately EXCLUDED: it is the 0600 home of the real keys,
# not an artifact. Rotate with ./scripts/rotate-api-keys.sh.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

scan_py() {
    # scan_py ROOT1 [ROOT2 ...] — walk text artifacts, print redacted findings
    # as JSON. The value is never emitted; only path, line, and a kind label.
    python3 - "$@" << 'PYEOF'
import json, os, re, sys

PATTERNS = [
    ("deepseek_key", re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9]{20,}")),
    ("jev_key", re.compile(r"apikey_[A-Za-z0-9_]{16,}")),
    ("bearer_token", re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{16,}")),
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("env_assignment", re.compile(
        r"(?i)\b(?:API_KEY|PASSWORD|SECRET|TOKEN|MASTER_KEY|SERVER_PASSWORD)\s*[:=]\s*[\"']?[A-Za-z0-9_./+\-]{8,}")),
]
SKIP_NAMES = {".env.local", ".env", ".git"}
SKIP_EXT = {".db", ".db-wal", ".db-shm", ".png", ".jpg", ".jpeg", ".gif", ".webp",
            ".pdf", ".zip", ".gz", ".bz2", ".xz", ".so", ".node", ".bin", ".woff",
            ".woff2", ".ico", ".mp4", ".webm", ".wasm", ".lock"}
MAX_BYTES = 4 * 1024 * 1024
findings = []
scanned = 0


def files_of(root):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_NAMES]
        for name in filenames:
            yield os.path.join(dirpath, name)


for root in sys.argv[1:]:
    if not os.path.exists(root):
        continue
    for path in files_of(root):
        name = os.path.basename(path)
        if name in SKIP_NAMES or name.startswith(".env"):
            continue
        if os.path.splitext(name)[1].lower() in SKIP_EXT:
            continue
        try:
            if os.path.getsize(path) > MAX_BYTES:
                continue
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if b"\x00" in raw:          # binary
            continue
        scanned += 1
        text = raw.decode("utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for kind, rx in PATTERNS:
                if rx.search(line):
                    findings.append({"file": path, "line": lineno, "kind": kind})
print(json.dumps({"scanned": scanned, "count": len(findings), "findings": findings}))
PYEOF
}

report() {
    # report JSON — human lines + guidance. Values are never printed.
    printf '%s' "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("=== secret-scan: %d finding(s) in %d file(s) ===" % (d["count"], d["scanned"]))
for f in d["findings"]:
    print("  %s:%s  [%s]" % (f["file"], f["line"], f["kind"]))'
}

guidance() {
    printf '\nSECRETS AT REST: rotate now, then scrub the artifacts.\n'
    printf '  1. ./scripts/rotate-api-keys.sh   (guided: browser revoke -> new key -> .env.local -> verify)\n'
    printf '  2. DeepSeek revoke: https://platform.deepseek.com/api_keys\n'
    printf '  3. JEV revoke:      https://console.typesafe.ai/keys\n'
    printf '  4. Re-run ./scripts/secret-scan.sh until clean.\n'
    printf '  note: the scan report is value-free; the artifact file still holds the raw key.\n'
}

self_test() {
    local fail=0 work="" out=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    python3 - "$work" << 'PYEOF'
import sys
d = sys.argv[1]
open(d + "/dirty.log", "w").write(
    "env dump\nDEEPSEEK_API_KEY=sk-" + "a" * 30 + "\nJEV_API_KEY=apikey_" + "b" * 24 + "\n")
open(d + "/clean.log", "w").write("all good, no keys here\n")
PYEOF
    out=$(bash "${BASH_SOURCE[0]}" --paths "$work" --json 2>&1)
    printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] >= 2, "count"; assert all(set(("file","line","kind")) == set(f) for f in d["findings"]), "shape"' \
        || { printf 'FAIL json contract\n'; fail=1; }
    # The report must never contain the raw secret bytes.
    printf '%s' "$out" | grep -q "aaaaaaaaaaaaaaaaaaaa" && { printf 'FAIL report leaked value\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --paths "$work" > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL dirty exits 1\n'; fail=1; }
    python3 -c 'import sys; open(sys.argv[1], "w").write("")' "$work/dirty.log"
    bash "${BASH_SOURCE[0]}" --paths "$work" > /dev/null 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL clean exits 0\n'; fail=1; }
    rm -f "$work/dirty.log" "$work/clean.log"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'secret-scan: self-test PASS\n'; else printf 'secret-scan: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local JSON=0 SELFTEST=0 QUIET=0 PATHS=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --quiet) QUIET=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            --paths) PATHS="${2:-}"; shift 2 ;;
            --paths=*) PATHS="${1#--paths=}"; shift ;;
            -h | --help)
                printf 'usage: %s [--paths "DIR ..."] [--json] [--quiet] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local roots=""
    if [ -n "$PATHS" ]; then
        roots="$PATHS"
    else
        [ -d "$REPO/logs" ] && roots="$roots $REPO/logs"
        [ -d "$REPO/data/observability" ] && roots="$roots $REPO/data/observability"
        [ -d "$REPO/../notes" ] && roots="$roots $REPO/../notes"
    fi
    if [ -z "${roots// /}" ]; then
        printf 'secret-scan: no artifact dirs present (logs/, data/observability/, ../notes)\n'
        return 0
    fi
    local out="" count=""
    out=$(scan_py $roots)
    count=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' 2>&1)
    case "${count:-x}" in
        ''|*[!0-9]*) printf 'FAIL: scan error\n'; return 2 ;;
    esac
    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' "$out"
    elif [ "$QUIET" -eq 0 ]; then
        report "$out"
        [ "$count" -gt 0 ] && guidance
    fi
    if [ "$count" -gt 0 ]; then return 1; fi
    [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ] && printf 'secret-scan: clean\n'
    return 0
}

main "$@"
