#!/usr/bin/env bash
#
# diagnose-sidebar-v3.sh
#
# v2.1 established: SPA is SSE-driven, /api/event only emits
# server.connected, bundle references /api/session/active and
# /api/project/current. v3 probes both.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"

REPO=""; LOG=""; ARTIFACT_DIR=""; PASS=""

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

log() {
    local level="$1" phase="$2" stage="$3" status="$4" msg="$5"
    shift 5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv="" p
    for p in "$@"; do kv="$kv $p"; done
    local record="ts=$ts level=$level phase=$phase stage=$stage status=$status msg=\"$msg\"$kv"
    if [ -n "$LOG" ]; then printf '%s\n' "$record" >> "$LOG"; fi
    printf '%s\n' "$record"
}

emit_artifact() {
    local file="$1" purpose="$2"
    [ -f "$file" ] || { log WARN artifact "$purpose" MISSING "path=$file"; return 0; }
    local bytes sha
    bytes=$(wc -c < "$file" | tr -d ' ')
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    log INFO artifact "$purpose" READY "content preserved" \
        "path=$file" "bytes=$bytes" "sha256=$sha"
}

# probe_probe LABEL PATH OUTFILE
probe() {
    local label="$1" path="$2" outfile="$3"
    local http
    http=$(curl -s -u "opencode:$PASS" -m 10 -o "$outfile" \
        -w '%{http_code}' "$HTTP_URL$path" 2>&1)
    local bytes=0 ctype=""
    [ -f "$outfile" ] && bytes=$(wc -c < "$outfile" | tr -d ' ')
    [ -f "$outfile" ] && ctype=$(file -b "$outfile" 2>&1 | head -c 30)
    log INFO probe "$label" READY "probed" \
        "path=$path" "http=$http" "bytes=$bytes" "type=\"$ctype\""
    printf '    %-34s  http=%s  bytes=%-7s  %s\n' "$path" "$http" "$bytes" "$ctype"
}

main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"; ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "diagnose-sidebar-v3" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    have curl    || { log ERROR preflight curl MISSING; return 1; }
    have python3 || { log ERROR preflight python3 MISSING; return 1; }

    PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$PASS" ] && { log ERROR preflight password MISSING; return 1; }

    printf '\n=== the endpoints the SPA actually references ===\n'
    probe "project-current"   "/api/project/current"    "$ARTIFACT_DIR/project-current.json"
    probe "project-root"      "/api/project"            "$ARTIFACT_DIR/project-root.out"
    probe "session-active"    "/api/session/active"     "$ARTIFACT_DIR/session-active.json"
    probe "session-plain"     "/api/session"            "$ARTIFACT_DIR/session-plain.json"
    probe "session-dir"       "/api/session?directory=/workspace" "$ARTIFACT_DIR/session-dir.json"

    # What /api/project/current returns
    printf '\n=== /api/project/current body ===\n'
    if [ -s "$ARTIFACT_DIR/project-current.json" ]; then
        if grep -q '<!doctype html' "$ARTIFACT_DIR/project-current.json" 2>&1; then
            printf '    (HTML — SPA fallback, endpoint does not exist under this name)\n'
        else
            head -c 600 "$ARTIFACT_DIR/project-current.json" | while IFS= read -r l; do printf '    %s\n' "$l"; done
            printf '\n'
        fi
    fi

    # What /api/session/active returns
    printf '\n=== /api/session/active body ===\n'
    if [ -s "$ARTIFACT_DIR/session-active.json" ]; then
        if grep -q '<!doctype html' "$ARTIFACT_DIR/session-active.json" 2>&1; then
            printf '    (HTML — SPA fallback, endpoint does not exist under this name)\n'
        else
            head -c 600 "$ARTIFACT_DIR/session-active.json" | while IFS= read -r l; do printf '    %s\n' "$l"; done
            printf '\n'
        fi
    fi

    # Parse the JSON files with python3.
    printf '\n=== structured parse ===\n'
    python3 - "$ARTIFACT_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]

def load(name):
    p = os.path.join(d, name)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None
    try:
        with open(p) as f:
            head = f.read(15)
            f.seek(0)
            if head.lstrip().startswith("<"):
                return "HTML"
            return json.load(f)
    except Exception as e:
        return f"ERR: {e}"

pc = load("project-current.json")
sa = load("session-active.json")
sp = load("session-plain.json")
sd = load("session-dir.json")

def count(x):
    if x is None: return "absent"
    if x == "HTML": return "HTML-fallback"
    if isinstance(x, dict):
        if isinstance(x.get("data"), list):
            return len(x["data"])
        return f"dict keys={sorted(x.keys())[:6]}"
    if isinstance(x, list):
        return len(x)
    return type(x).__name__

print(f"    /api/project/current   : {count(pc)}")
print(f"    /api/session/active    : {count(sa)}")
print(f"    /api/session           : {count(sp)}")
print(f"    /api/session?directory : {count(sd)}")

# If session-active is a list, dump the ids.
if isinstance(sa, dict) and isinstance(sa.get("data"), list):
    ids = [s.get("id","")[:24] for s in sa["data"][:10]]
    print(f"    active session ids     : {ids}")
if isinstance(sa, list):
    ids = [s.get("id","")[:24] for s in sa[:10]]
    print(f"    active session ids     : {ids}")
PY

    # Verdict
    printf '\n=== verdict ===\n'
    local sa_size
    sa_size=$(wc -c < "$ARTIFACT_DIR/session-active.json" 2>&1)
    if grep -q '<!doctype html' "$ARTIFACT_DIR/session-active.json" 2>&1; then
        printf '    /api/session/active does not exist as an endpoint.\n'
        printf '    SPA must use /api/session + SSE.\n'
        printf '    Sidebar emptiness = SSE is not emitting session events.\n'
        printf '    The server needs to announce pre-existing sessions, or the\n'
        printf '    SPA needs to hydrate from /api/session before subscribing.\n'
    else
        printf '    /api/session/active exists. Compare its count to /api/session:\n'
        printf '      - equal: sidebar emptiness is elsewhere (project scope, filter).\n'
        printf '      - active < plain: SPA shows only active; historical runs are\n'
        printf '        intentionally excluded. Fix is a UI setting, not data.\n'
    fi

    log INFO session end END "done"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
