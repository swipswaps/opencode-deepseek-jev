#!/usr/bin/env bash
#
# fix-notes-mount-source.sh
#
# v1/v2 used ../notes as the mount source. From docker/docker-compose.yml
# that resolves to repo/notes, which does not exist. Docker created an
# empty directory and mounted it, so the container saw an empty /notes
# while every gate passed. The actual notes dir is one level above the
# repo, at ../notes relative to the repo root.
#
# This script:
#   R1  Prints the current source path of the /notes mount.
#   R2  Shows what is at each candidate path on the host.
#   R3  Rewrites the mount source to the absolute path.
#   R4  Recreates, then verifies /notes has real files inside.
#   R5  Aborts before any further step if /notes is still empty.
#
set -o pipefail

C="opencode-deepseek-web"
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
    local script_dir repo parent compose ts abs_notes
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"
    parent=$(dirname "$repo")
    compose="$repo/docker/docker-compose.yml"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "fix-notes-mount-source" "repo=$repo"

    # ------------------------------------------------------------------
    printf '\n===== R1. current mount line in compose =====\n'
    grep -nF "$NOTES_CONT" "$compose" | while IFS= read -r l; do
        printf '    %s\n' "$l"
    done

    printf '\n===== R2. candidate host paths =====\n'
    local cand
    for cand in "$repo/notes" "$parent/notes"; do
        if [ -d "$cand" ]; then
            local n
            n=$(ls -1 "$cand" 2>&1 | wc -l | tr -d ' ')
            printf '    EXISTS  %-70s  entries=%s\n' "$cand" "$n"
            if [ "$n" -gt 0 ]; then
                ls -1 "$cand" 2>&1 | head -10 | while IFS= read -r f; do
                    printf '              %s\n' "$f"
                done
            fi
        else
            printf '    ABSENT  %s\n' "$cand"
        fi
    done

    if [ ! -d "$parent/notes" ]; then
        log ERROR preflight FAIL "parent/notes does not exist" "path=$parent/notes"
        printf '\nGATE FAIL: %s does not exist. Nothing to mount.\n' "$parent/notes"
        return 1
    fi
    abs_notes="$parent/notes"
    log INFO preflight PASS "notes dir" "abs=$abs_notes"

    # ------------------------------------------------------------------
    printf '\n===== R3. rewrite mount source =====\n'
    cp "$compose" "$compose.bak.${ts}"
    log INFO edit START "rewriting" "backup=$compose.bak.$ts"

    python3 - "$compose" "$abs_notes" "$NOTES_CONT" <<'PY'
import re, sys
path, abs_src, cont = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    src = fh.read()

# Match any line with the container target of /notes and capture indentation.
pat = re.compile(
    r'^([ \t]*- )[^:\n]+(:' + re.escape(cont) + r'(:ro)?)[ \t]*\n',
    re.MULTILINE,
)
new_line = f"\\1{abs_src}\\2\\n"

src, n = pat.subn(new_line, src)
if n == 0:
    print("NO_NOTES_MOUNT_FOUND", file=sys.stderr)
    sys.exit(3)
print(f"REPLACED={n}")
PY
    local prc=$?
    if [ "$prc" -ne 0 ]; then
        log ERROR edit FAIL "rewrite failed" "rc=$prc"
        return 1
    fi

    printf '\n    after edit:\n'
    grep -nF "$NOTES_CONT" "$compose" | while IFS= read -r l; do
        printf '      %s\n' "$l"
    done

    # ------------------------------------------------------------------
    printf '\n===== R4. recreate =====\n'
    ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 )
    if [ $? -ne 0 ]; then
        log ERROR config FAIL "compose config rejected"
        return 1
    fi
    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
    if [ $? -ne 0 ]; then
        log ERROR recreate FAIL "compose up"
        return 1
    fi
    local http; http=$(wait_http)
    log INFO recreate PASS "up" "http=$http"

    # ------------------------------------------------------------------
    printf '\n===== R5. verify /notes has real files =====\n'
    local inside_count
    inside_count=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT 2>&1 | wc -l" 2>&1 | tr -d ' ')
    printf '    entries inside %s: %s\n' "$NOTES_CONT" "$inside_count"
    docker exec "$C" sh -c "ls -la $NOTES_CONT" 2>&1 | head -15 | while IFS= read -r l; do
        printf '      %s\n' "$l"
    done

    if [ "$inside_count" -lt 1 ]; then
        log ERROR gate content FAIL "container /notes is empty" "entries=$inside_count"
        printf '\nGATE FAIL: /notes still empty. Inspect:\n'
        docker inspect "$C" --format '{{json .Mounts}}' 2>&1 | python3 -m json.tool
        return 1
    fi
    log INFO gate content PASS "/notes has entries" "entries=$inside_count"

    log INFO session end END "mount-source-fixed" "http=$http" "entries=$inside_count"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
