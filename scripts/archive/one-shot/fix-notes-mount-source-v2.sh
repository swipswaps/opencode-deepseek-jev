#!/usr/bin/env bash
#
# fix-notes-mount-source-v2.sh
#
# v1 bugs:
#   - Python subn result was never written back to the compose file.
#     REPLACED=1 printed, file unchanged.
#   - The mount source ../notes resolves from docker/ to repo/notes,
#     an empty directory created by Docker on a prior failed bind.
#     Real notes live one level above the repo.
#
# v2:
#   - Writes the file back. Verifies by re-reading and grepping.
#   - Uses an absolute source path so compose has no ambiguity.
#   - Removes the stale empty repo/notes directory afterward.
#   - Verifies /notes has real files inside the container before
#     declaring success.
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

    log INFO session start START "fix-notes-mount-source-v2" "repo=$repo"

    if [ ! -d "$parent/notes" ]; then
        log ERROR preflight FAIL "no source dir" "path=$parent/notes"
        printf 'GATE FAIL: %s does not exist\n' "$parent/notes"
        return 1
    fi
    abs_notes="$parent/notes"

    local n_files
    n_files=$(ls -1 "$abs_notes" 2>&1 | wc -l | tr -d ' ')
    log INFO preflight PASS "source has files" \
        "abs=$abs_notes" "entries=$n_files"

    if [ "$n_files" -lt 1 ]; then
        log ERROR preflight FAIL "source is empty" "abs=$abs_notes"
        return 1
    fi

    printf '\n===== R1. before =====\n'
    grep -nF "$NOTES_CONT" "$compose" | while IFS= read -r l; do
        printf '    %s\n' "$l"
    done

    printf '\n===== R2. patch and WRITE =====\n'
    cp "$compose" "$compose.bak.${ts}"
    log INFO edit START "rewriting + writing back" "backup=$compose.bak.$ts"

    python3 - "$compose" "$abs_notes" "$NOTES_CONT" <<'PY'
import re, sys
path, abs_src, cont = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    src = fh.read()

pat = re.compile(
    r'^([ \t]*- )[^\n]*' + re.escape(cont) + r'[^\n]*\n',
    re.MULTILINE,
)
new_line = f"\\1{abs_src}:{cont}:ro\n"

new_src, n = pat.subn(new_line, src)
if n == 0:
    print("NO_NOTES_MOUNT_FOUND", file=sys.stderr)
    sys.exit(3)

with open(path, "w") as fh:
    fh.write(new_src)

# Verify the write took by reading back.
with open(path) as fh:
    after = fh.read()
if abs_src not in after:
    print("WRITE_DID_NOT_TAKE", file=sys.stderr)
    sys.exit(4)

print(f"REPLACED={n}")
print(f"WROTE_BYTES={len(new_src)}")
PY
    local prc=$?
    if [ "$prc" -ne 0 ]; then
        log ERROR edit FAIL "patch failed" "rc=$prc"
        return 1
    fi

    printf '\n    after (re-read from disk):\n'
    grep -nF "$NOTES_CONT" "$compose" | while IFS= read -r l; do
        printf '      %s\n' "$l"
    done

    if ! grep -qF "$abs_notes" "$compose"; then
        log ERROR verify FAIL "absolute source not in file after write"
        return 1
    fi
    log INFO edit PASS "file rewritten with absolute source"

    printf '\n===== R3. remove stale empty dir =====\n'
    if [ -d "$repo/notes" ]; then
        local stale_count
        stale_count=$(ls -1 "$repo/notes" 2>&1 | wc -l | tr -d ' ')
        if [ "$stale_count" -eq 0 ]; then
            rmdir "$repo/notes" 2>&1 && printf '    removed %s\n' "$repo/notes" || \
                printf '    could not remove %s\n' "$repo/notes"
            log INFO stale PASS "empty repo/notes removed" "path=$repo/notes"
        else
            log WARN stale SKIP "repo/notes not empty" "entries=$stale_count"
        fi
    else
        printf '    no stale repo/notes\n'
    fi

    printf '\n===== R4. recreate =====\n'
    ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 )
    if [ $? -ne 0 ]; then
        log ERROR config FAIL "rejected"
        ( cd "$repo/docker" && docker compose config 2>&1 | head -30 )
        return 1
    fi

    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
    if [ $? -ne 0 ]; then
        log ERROR recreate FAIL "compose up"
        return 1
    fi
    local http; http=$(wait_http)
    log INFO recreate PASS "up" "http=$http"

    printf '\n===== R5. verify =====\n'
    docker inspect "$C" --format '{{json .Mounts}}' 2>&1 \
        | python3 -m json.tool | grep -A4 "$NOTES_CONT" | while IFS= read -r l; do
        printf '    %s\n' "$l"
    done

    local inside_count
    inside_count=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT 2>&1 | wc -l" 2>&1 | tr -d ' ')
    printf '\n    entries inside %s: %s\n' "$NOTES_CONT" "$inside_count"

    docker exec "$C" sh -c "ls -la $NOTES_CONT" 2>&1 | head -10 | while IFS= read -r l; do
        printf '      %s\n' "$l"
    done

    if [ "$inside_count" -lt 1 ]; then
        log ERROR gate content FAIL "still empty" "entries=$inside_count"
        return 1
    fi
    log INFO gate content PASS "container sees notes" "entries=$inside_count"

    log INFO session end END "success" "http=$http" "entries=$inside_count"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
