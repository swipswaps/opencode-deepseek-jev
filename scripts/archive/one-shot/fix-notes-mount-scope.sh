#!/usr/bin/env bash
#
# fix-notes-mount-scope.sh
#
# v1/v2 added the /notes mount but the anchor matched a service other
# than opencode-web. Result: compose config shows the mount, docker
# inspect on opencode-deepseek-web does not.
#
# This script:
#   1. Prints every service header and every volumes: block in the
#      compose file so we can see where the mount landed.
#   2. Removes every /notes line regardless of service.
#   3. Adds /notes under opencode-web specifically, after its existing
#      data/opencode bind.
#   4. Verifies with docker compose config, scoped to opencode-web only.
#   5. Recreates, verifies with docker inspect, and checks inside the
#      container.
#   6. Aborts before any agent invocation unless all three pass.
#
set -o pipefail

C="opencode-deepseek-web"
NOTES_HOST_REL="../notes"
NOTES_CONT="/notes"
HTTP_URL="http://127.0.0.1:4096"

REPO=""; LOG=""; ARTIFACT_DIR=""

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

log() {
    local level="$1" phase="$2" stage="$3" status="$4" msg="$5"
    shift 5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv="" p; for p in "$@"; do kv="$kv $p"; done
    local rec="ts=$ts level=$level phase=$phase stage=$stage status=$status msg=\"$msg\"$kv"
    [ -n "$LOG" ] && printf '%s\n' "$rec" >> "$LOG"
    printf '%s\n' "$rec"
}

show_structure() {
    local f="$1"
    printf '\n===== compose structure =====\n'
    grep -nE '^[[:space:]]*[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$|^[[:space:]]*volumes:|^[[:space:]]*services:' "$f" \
        | while IFS= read -r line; do printf '    %s\n' "$line"; done
    printf '\n===== every /notes line and its service context =====\n'
    awk '
        /^  [a-zA-Z]/ { svc = $1 }
        /notes/ { printf "    %-8s  line %d: %s\n", svc, NR, $0 }
    ' "$f"
}

scoped_config_has_mount() {
    # Extract only the opencode-web block from docker compose config.
    local repo="$1"
    ( cd "$repo/docker" && docker compose config 2>&1 ) \
        | awk '
            /^  opencode-web:/ { s=1 }
            s && /^  [a-zA-Z]/ && !/^  opencode-web:/ { exit }
            s
          ' \
        | grep -F "$NOTES_CONT" >/dev/null
}

inspect_has_mount() {
    docker inspect "$C" --format '{{json .Mounts}}' 2>&1 \
        | grep -F "\"Destination\":\"$NOTES_CONT\"" >/dev/null
}

container_has_dir() {
    docker exec "$C" sh -c "[ -d $NOTES_CONT ]" 2>&1
}

wait_http() {
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1)); sleep 2
    done
    printf '%s' "$code"
}

main() {
    local script_dir repo compose ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"; compose="$repo/docker/docker-compose.yml"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "fix-notes-mount-scope" "repo=$repo"

    # ---- 1. Show structure ----
    show_structure "$compose"

    # ---- 2. Fix scope ----
    cp "$compose" "$compose.bak.${ts}"
    log INFO edit START "rewriting" "backup=$compose.bak.$ts"

    python3 - "$compose" "$NOTES_HOST_REL" "$NOTES_CONT" <<'PY'
import re, sys
path, hostrel, cont = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    text = fh.read()

# Step A: remove every /notes mount line, any service.
patterns = [
    re.compile(r'^[ \t]*- [^\n]*' + re.escape(cont) + r'[^\n]*\n', re.MULTILINE),
]
removed = 0
for p in patterns:
    text, n = p.subn('', text)
    removed += n

# Step B: locate the opencode-web service block.
m = re.search(r'^  opencode-web:\n((?:[ \t].*\n|\n)*?)(?=^  [a-zA-Z]|\Z)',
              text, re.MULTILINE)
if not m:
    print("NO_OPENCODE_WEB_SECTION", file=sys.stderr)
    sys.exit(3)

block = m.group(1)

# Step C: find the data/opencode mount line inside that block.
anchor = None
for line in block.splitlines(True):
    if '- ../data/opencode:/home/node/.local/share/opencode' in line:
        anchor = line
        break
if anchor is None:
    print("NO_DATA_ANCHOR_IN_OPENCODE_WEB", file=sys.stderr)
    sys.exit(3)

# Step D: insert /notes line right after the anchor, same indent.
indent = anchor[:len(anchor) - len(anchor.lstrip())]
new_line = f"{indent}- {hostrel}:{cont}:ro\n"
new_block = block.replace(anchor, anchor + new_line, 1)

text = text[:m.start(1)] + new_block + text[m.end(1):]
with open(path, "w") as fh:
    fh.write(text)

print(f"REMOVED={removed}")
print(f"ADDED={new_line.strip()}")
print(f"SERVICE=opencode-web")
PY
    local prc=$?
    if [ "$prc" -ne 0 ]; then
        log ERROR edit FAIL "python3 edit failed" "rc=$prc"
        return 1
    fi

    # ---- 3. Show structure after edit ----
    show_structure "$compose"

    # ---- 4. Scoped config check ----
    if ! scoped_config_has_mount "$repo"; then
        log ERROR gate config FAIL "opencode-web block lacks $NOTES_CONT"
        ( cd "$repo/docker" && docker compose config 2>&1 ) \
            | awk '/^  opencode-web:/{s=1} s{print} s && /^  [a-zA-Z]/ && !/^  opencode-web:/{exit}'
        return 1
    fi
    log INFO gate config PASS "opencode-web block has mount"

    # ---- 5. Recreate ----
    log INFO recreate START "recreating"
    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
    if [ $? -ne 0 ]; then
        log ERROR recreate FAIL "compose up"
        return 1
    fi
    local http; http=$(wait_http)
    log INFO recreate PASS "up" "http=$http"

    # ---- 6. Inspect ----
    if ! inspect_has_mount; then
        log ERROR gate inspect FAIL "inspect lacks $NOTES_CONT"
        docker inspect "$C" --format '{{json .Mounts}}' 2>&1 | python3 -m json.tool
        return 1
    fi
    log INFO gate inspect PASS "inspect shows $NOTES_CONT"

    # ---- 7. Container ----
    if ! container_has_dir; then
        log ERROR gate container FAIL "no dir at $NOTES_CONT"
        docker exec "$C" ls -la / 2>&1 | head -20
        return 1
    fi
    log INFO gate container PASS "$NOTES_CONT visible"

    # ---- 8. Show what the agent will see ----
    printf '\n===== inside container =====\n'
    printf '    /notes listing:\n'
    docker exec "$C" ls -la /notes 2>&1 | head -15 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    printf '\n    /workspace/logs listing:\n'
    docker exec "$C" ls -la /workspace/logs 2>&1 | head -10 | while IFS= read -r l; do printf '      %s\n' "$l"; done

    log INFO session end END "mount-verified" "http=$http"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
