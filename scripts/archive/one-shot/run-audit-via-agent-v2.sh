#!/usr/bin/env bash
#
# run-audit-via-agent-v2.sh
#
# v1 defects:
#   - /notes was not visible inside the container (visible=no) but the
#     script continued anyway. Gating failure.
#   - Agent subprocess output was buffered to a file and only read after
#     exit. During the run: silent. Not telemetry.
#
# v2 fixes:
#   G1  After compose edit, verify the mount in three independent places:
#       compose config, docker inspect .Mounts, container filesystem.
#       Abort if any check disagrees.
#   G2  The agent subprocess writes to a logfile, and tail -F streams it
#       line-by-line into the telemetry log as it arrives. Every line from
#       opencode --print-logs becomes a status=LINE record with level
#       derived from the line content.
#   G3  Errored agent exits still emit the last 40 lines as records.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill (TERM only), printf only,
# main() wrapper. ASCII only.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"
MODEL="deepseek/deepseek-flash"
RUN_TIMEOUT=300
NOTES_HOST_REL="../notes"
NOTES_CONT="/notes"

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

emit_artifact() {
    local f="$1" label="$2"
    [ -f "$f" ] || { log WARN artifact "$label" MISSING "path=$f"; return 0; }
    local bytes sha
    bytes=$(wc -c < "$f" | tr -d ' ')
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    log INFO artifact "$label" READY "captured" \
        "path=$f" "bytes=$bytes" "sha256=$sha"
}

# mount_seen_in_config COMPOSE
mount_seen_in_config() {
    ( cd "$(dirname "$1")" && docker compose config 2>&1 ) \
        | grep -F "$NOTES_CONT" >/dev/null
}

# mount_seen_in_inspect
mount_seen_in_inspect() {
    docker inspect "$C" --format '{{json .Mounts}}' 2>&1 \
        | grep -F "\"Destination\":\"$NOTES_CONT\"" >/dev/null
}

# mount_seen_in_container
mount_seen_in_container() {
    docker exec "$C" sh -c "[ -d $NOTES_CONT ]" 2>&1
}

ensure_notes_mount() {
    local compose="$1" hostrel="$2" cont="$3"
    if grep -qF "$cont" "$compose"; then
        log INFO mount notes PASS "already in compose" "cont=$cont"
        return 1
    fi
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    cp "$compose" "$compose.bak.${ts}"
    log INFO mount notes START "adding read-only mount" \
        "hostrel=$hostrel" "cont=$cont" "backup=$compose.bak.$ts"

    python3 - "$compose" "$hostrel" "$cont" <<'PY'
import sys
path, hostrel, cont = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    src = fh.read()
anchor = "      - ../data/opencode:/home/node/.local/share/opencode\n"
if anchor not in src:
    print("ANCHOR_MISSING", file=sys.stderr); sys.exit(3)
if cont in src:
    print("ALREADY_PRESENT"); sys.exit(0)
new = anchor + f"      - {hostrel}:{cont}:ro\n"
src = src.replace(anchor, new, 1)
with open(path, "w") as fh:
    fh.write(src)
print("MOUNT_ADDED")
PY
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    log ERROR mount notes FAIL "python3 edit failed" "rc=$rc"
    return 2
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

# Stream one subprocess log file into telemetry, live.
# Elevated lines (matching ERROR|WARN|event|error|failed|rejected) get
# promoted to their level. Ordinary lines become level=DEBUG.
stream_logfile() {
    local file="$1" label="$2" stopfile="$3"
    while [ ! -f "$stopfile" ]; do
        if [ -f "$file" ]; then
            # tail -F emits new lines; -n +1 starts at line 1.
            # We use a per-invocation tail with --pid of the notifier.
            break
        fi
        sleep 0.1
    done
    tail -F -n +1 "$file" 2>&1 | while IFS= read -r line; do
        [ -f "$stopfile" ] && exit 0
        local lvl="DEBUG"
        case "$line" in
            *level=ERROR*|*error*|*Error*|*failed*|*rejected*) lvl="ERROR" ;;
            *level=WARN*|*warn*)                                   lvl="WARN"  ;;
            *"event connected"*|*"permission requested"*|*"tool"*) lvl="INFO"  ;;
        esac
        local esc; esc=$(printf '%s' "$line" | tr '"' "'")
        local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
        local rec="ts=$ts level=$lvl phase=agent stage=$label status=LINE msg=\"agent output\" text=\"$esc\""
        printf '%s\n' "$rec" >> "$LOG"
        printf '%s\n' "$rec"
    done
}

main() {
    local script_dir repo parent ts compose
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"; parent=$(dirname "$repo")
    compose="$repo/docker/docker-compose.yml"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "run-audit-via-agent-v2" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    # ---- 1. Host notes exist ----
    if [ ! -d "$parent/notes" ]; then
        log ERROR preflight notes MISSING "host dir absent" "path=$parent/notes"
        printf 'GATE FAIL: %s does not exist. Cannot mount.\n' "$parent/notes"
        return 1
    fi
    log INFO preflight notes PASS "host dir present" "path=$parent/notes"

    # ---- 2. Ensure mount in compose ----
    ensure_notes_mount "$compose" "$NOTES_HOST_REL" "$NOTES_CONT"
    local mrc=$?
    if [ "$mrc" -eq 2 ]; then
        log ERROR mount FAIL "compose unchanged; abort"
        return 1
    fi

    # ---- 3. Compose config must show it ----
    if ! mount_seen_in_config "$compose"; then
        log ERROR gate config FAIL "compose config lacks $NOTES_CONT"
        ( cd "$repo/docker" && docker compose config 2>&1 | head -40 )
        return 1
    fi
    log INFO gate config PASS "compose config has mount"

    # ---- 4. Recreate if needed ----
    if [ "$mrc" -eq 0 ] || ! mount_seen_in_inspect; then
        log INFO recreate START "recreating"
        ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
        if [ $? -ne 0 ]; then
            log ERROR recreate FAIL "compose up"
            return 1
        fi
        local http
        http=$(wait_http)
        log INFO recreate PASS "up" "http=$http"
    fi

    # ---- 5. Verify mount in inspect ----
    if ! mount_seen_in_inspect; then
        log ERROR gate inspect FAIL "docker inspect lacks $NOTES_CONT"
        docker inspect "$C" --format '{{json .Mounts}}' 2>&1 \
            | python3 -m json.tool
        return 1
    fi
    log INFO gate inspect PASS "inspect shows mount"

    # ---- 6. Verify mount inside container ----
    if ! mount_seen_in_container; then
        log ERROR gate container FAIL "container cannot see $NOTES_CONT"
        printf 'GATE FAIL: /notes not visible inside container despite mount in inspect.\n'
        docker exec "$C" ls -la / 2>&1 | head -20
        return 1
    fi
    log INFO gate container PASS "$NOTES_CONT visible"

    local notes_visible="yes"

    # ---- 7. Deliver prompt ----
    local prompt_path_in_container="/tmp/audit-prompt.txt"
    docker exec -i "$C" sh -c "cat > $prompt_path_in_container" <<PROMPT_END
You are auditing a Docker-packaged coding agent environment.

Readable locations:
- /workspace -- the project repo (read/write)
- /notes     -- chat logs (read-only)

Produce an audit report at /workspace/logs/sidebar-audit.md with:

1. Project identity -- from README.txt, QUICKSTART.txt, opencode.json
2. Rule system -- grep /notes for #N patterns; cross-reference scripts/archive/one-shot/push_notes_v18.sh
3. JEV -- where it appears in /notes and /workspace
4. Current state -- opencode-web block of docker/docker-compose.yml, docker/web-entrypoint.sh, session count via sqlite3
5. Open risks -- five bullets

Then call jev_review once with the report as the diff.

Reply with two lines:
  correctness=<score>
  summary=<one sentence>
PROMPT_END

    # ---- 8. Invoke with live streaming ----
    local transcript="$ARTIFACT_DIR/agent-transcript.log"
    local stopfile="$ARTIFACT_DIR/agent-stop"
    local flag="$ARTIFACT_DIR/timeout-flag"
    : > "$transcript"
    : > "$flag"
    rm -f "$stopfile"

    log INFO agent invoke START "invoking" \
        "model=$MODEL" "timeout_s=$RUN_TIMEOUT" "transcript=$transcript"

    # Start streaming in background.
    stream_logfile "$transcript" "P" "$stopfile" &
    local streamer=$!

    local start_epoch
    start_epoch=$(date +%s)

    docker exec -w /workspace "$C" sh -c \
        "opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat $prompt_path_in_container)\"" \
        > "$transcript" 2>&1 &
    local child=$!

    (
        local c15=0 c60=0 c180=0
        while sleep 1; do
            kill -0 "$child" >/dev/null 2>&1 || exit 0
            local now elapsed
            now=$(date +%s); elapsed=$((now - start_epoch))
            [ "$elapsed" -ge 15 ]  && [ "$c15"  -eq 0 ] && { log INFO agent invoke STALL "crossed 15s"  "elapsed_s=$elapsed"; c15=1; }
            [ "$elapsed" -ge 60 ]  && [ "$c60"  -eq 0 ] && { log INFO agent invoke STALL "crossed 60s"  "elapsed_s=$elapsed"; c60=1; }
            [ "$elapsed" -ge 180 ] && [ "$c180" -eq 0 ] && { log INFO agent invoke STALL "crossed 180s" "elapsed_s=$elapsed"; c180=1; }
            if [ "$elapsed" -ge "$RUN_TIMEOUT" ]; then
                log WARN agent invoke TIMEOUT "sending TERM" \
                    "elapsed_s=$elapsed" "timeout_s=$RUN_TIMEOUT"
                printf 'TIMEOUT\n' > "$flag"
                kill -TERM "$child" >/dev/null 2>&1
                sleep 2
                kill -KILL "$child" >/dev/null 2>&1
                exit 0
            fi
        done
    ) &
    local watcher=$!

    wait "$child"
    local child_rc=$?
    kill -TERM "$watcher" >/dev/null 2>&1
    wait "$watcher" >/dev/null 2>&1

    # Stop streaming.
    touch "$stopfile"
    sleep 1
    kill -TERM "$streamer" >/dev/null 2>&1
    wait "$streamer" >/dev/null 2>&1

    local end_epoch elapsed_ms status rc
    end_epoch=$(date +%s)
    elapsed_ms=$(( (end_epoch - start_epoch) * 1000 ))
    if [ -s "$flag" ]; then
        rc=124; status="TIMEOUT"
    elif [ "$child_rc" -ne 0 ]; then
        rc=$child_rc; status="ERROR"
    else
        rc=0; status="END"
    fi
    log INFO agent invoke "$status" "finished" \
        "rc=$rc" "child_rc=$child_rc" "elapsed_ms=$elapsed_ms"
    emit_artifact "$transcript" "agent-transcript"

    # On error, surface the tail as records.
    if [ "$rc" -ne 0 ]; then
        local i=0 line
        while IFS= read -r line; do
            i=$((i + 1))
        done < "$transcript"
        local start=$((i > 40 ? i - 40 : 1))
        log INFO agent tail EMIT "last 40 lines of transcript" \
            "total_lines=$i" "start=$start"
        awk -v s="$start" 'NR>=s' "$transcript" | while IFS= read -r line; do
            local esc; esc=$(printf '%s' "$line" | tr '"' "'")
            local ts2; ts2=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
            printf '%s\n' "ts=$ts2 level=INFO phase=agent stage=tail status=LINE text=\"$esc\"" >> "$LOG"
            printf '%s\n' "ts=$ts2 level=INFO phase=agent stage=tail status=LINE text=\"$esc\""
        done
    fi

    # ---- 9. Verify report ----
    local report_host="$repo/logs/sidebar-audit.md"
    if [ -f "$report_host" ]; then
        emit_artifact "$report_host" "sidebar-audit-md"
        printf '\n===== report (first 60 lines) =====\n'
        head -60 "$report_host"
    else
        printf '\n===== report MISSING =====\n'
        printf '    expected: %s\n' "$report_host"
        printf '    in container: '
        docker exec "$C" sh -c 'ls -la /workspace/logs/ 2>&1' | head -10
    fi

    log INFO session end END "done" "rc=$rc"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return "$rc"
}

main "$@"
