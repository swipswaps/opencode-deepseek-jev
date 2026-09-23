#!/usr/bin/env bash
#
# show-ui-sessions.sh
#
# Read-only. Fetches /api/session with basic auth, pretty-prints the
# sessions the browser will display, and cross-checks against the sqlite
# database on the host-side bind mount.
#
# Answers: "the CLI writes sessions, and the API returns them, so what
# exactly should the browser at :4096 show?"
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"
DATA_HOST_REL="data/opencode"
DATA_CONT="/home/node/.local/share/opencode"

REPO=""
LOG=""
ARTIFACT_DIR=""

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
    if [ ! -f "$file" ]; then
        log WARN artifact "$purpose" MISSING "no file" "path=$file"
        return 0
    fi
    local bytes sha
    bytes=$(wc -c < "$file" | tr -d ' ')
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    log INFO artifact "$purpose" READY "content preserved" \
        "path=$file" "bytes=$bytes" "sha256=$sha"
}

main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf '%s\n' 'GATE FAIL: cannot resolve repo'; return 2; }
    REPO="$repo"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "show-ui-sessions" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    have curl || { log ERROR preflight curl MISSING "curl not on PATH"; return 1; }

    # Container running?
    local cstate
    cstate=$(docker inspect -f '{{.State.Status}}' "$C" 2>&1)
    if [ "$cstate" != "running" ]; then
        log ERROR preflight container ERROR "container not running" "state=$cstate"
        return 1
    fi
    log INFO preflight container PASS "container running" "state=running"

    # Password from container env
    local pass
    pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    if [ -z "$pass" ]; then
        log ERROR preflight password MISSING "password empty in container"
        return 1
    fi
    log INFO preflight password PASS "password present" "length=${#pass}"

    # Fetch /api/session
    local body_file
    body_file="$ARTIFACT_DIR/api-session.json"
    local http_code
    http_code=$(curl -s -u "opencode:$pass" -m 10 -o "$body_file" \
        -w '%{http_code}' "$HTTP_URL/api/session" 2>&1)
    log INFO fetch api-session READY "fetched" \
        "http=$http_code" "path=$body_file"
    emit_artifact "$body_file" "api-session-json"

    if [ "$http_code" != "200" ]; then
        log ERROR fetch api-session ERROR "non-200" "http=$http_code"
        return 1
    fi

    # Count and list sessions from the API
    if ! have python3; then
        log WARN parse api-session SKIP "python3 absent; showing raw"
        head -c 2000 "$body_file"
        return 0
    fi

    local api_count
    api_count=$(python3 - "$body_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
data = doc.get("data", [])
print(len(data))
PY
)
    log INFO parse api-session PASS "counted" "api_count=$api_count"

    printf '\n=== sessions visible to the UI (via /api/session) ===\n'
    printf '%4s  %-30s  %-30s  %s\n' "n" "id" "title" "model"
    printf '    ----  ------------------------------  ------------------------------  ----------------\n'
    python3 - "$body_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
data = doc.get("data", [])
for i, s in enumerate(data, 1):
    sid = s.get("id", "")[:28]
    title = (s.get("title") or "")[:28]
    model = s.get("model") or ""
    if isinstance(model, dict):
        m = f"{model.get('providerID','?')}/{model.get('id','?')}"
    else:
        m = str(model)
    print(f"    {i:>3}  {sid:<30}  {title:<30}  {m}")
PY

    # Cross-check against the sqlite database on the host bind mount
    local db_host="$repo/$DATA_HOST_REL/opencode.db"
    local db_count="?"
    if have sqlite3 && [ -f "$db_host" ]; then
        db_count=$(sqlite3 "$db_host" "select count(*) from session;" 2>&1)
    fi
    log INFO parse sqlite PASS "counted" \
        "db_path=$db_host" "db_count=$db_count" "api_count=$api_count"

    printf '\n=== cross-check ===\n'
    printf '  api_count:  %s\n' "$api_count"
    printf '  db_count:   %s  (%s)\n' "$db_count" "$db_host"

    printf '\n=== browser ===\n'
    printf '  URL:      %s\n' "$HTTP_URL"
    printf '  user:     opencode\n'
    printf '  password: %s\n' "$pass"
    printf '\n  Refresh the browser. The sessions above are what the sidebar should show.\n'
    printf '  If the sidebar is empty while api_count > 0, the browser is serving\n'
    printf '  cached HTML or an old JS bundle; hard-reload (Ctrl-Shift-R) or use a\n'
    printf '  private window.\n'

    log INFO session end END "done" "api_count=$api_count" "db_count=$db_count"
    printf '\nlog:       %s\n' "$LOG"
    printf 'artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
