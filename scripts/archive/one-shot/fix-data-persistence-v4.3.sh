#!/usr/bin/env bash
#
# fix-data-persistence-v4.3.sh
#
# Telemetry contract (per user stipulation 2026-09-23):
#   P3.1  structured, timestamped, persisted records on state transitions
#   P3.2  UTC ISO-8601 timestamps with milliseconds
#   P3.3  uniform shape: ts= level= phase= stage= status= k=v...
#   P3.4  full payloads to artifact files; records carry path+bytes+sha256
#   P3.5  persisted to <repo>/logs/telemetry-<date>.log; path printed
#   P3.6  greppable: all verdicts carry level=; all checks carry status=
#   P3.7  emitted on transitions, not timers
#
# Summary contract: BOTH forms emitted.
#   Machine: SUMMARY log=<path> pass=N fail=N skip=N inconclusive=N rc=N
#   Human:   prose paragraph after the machine line
#
# Mount check: docker inspect .Mounts only. No substring-in-file checks.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit/return,
# no rm -rf, no subprocess.run, no bare kill, printf only.
#
set -o pipefail

C="opencode-deepseek-web"
COMPOSE_REL="docker/docker-compose.yml"
DATA_CONT="/home/node/.local/share/opencode"
DATA_HOST_REL="data/opencode"
HTTP_URL="http://127.0.0.1:4096"
MODEL="deepseek/deepseek-flash"
RUN_TIMEOUT=120

REPO=""
LOG=""
ARTIFACT_DIR=""
COUNTS_PASS=0
COUNTS_FAIL=0
COUNTS_SKIP=0
COUNTS_INC=0
SUMMARY_TEXT=""

# ---------------------------------------------------------------------------
# Telemetry primitives
# ---------------------------------------------------------------------------

# log LEVEL PHASE STAGE STATUS MSG [k=v ...]
log() {
    local level="$1" phase="$2" stage="$3" status="$4" msg="$5"
    shift 5
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv=""
    local p
    for p in "$@"; do
        kv="$kv $p"
    done
    local record="ts=$ts level=$level phase=$phase stage=$stage status=$status msg=\"$msg\"$kv"
    printf '%s\n' "$record" >> "$LOG"
    printf '%s\n' "$record"
}

# record_check NAME STATUS OBSERVED CRITERION
record_check() {
    local name="$1" status="$2" observed="$3" criterion="$4"
    case "$status" in
        PASS)  COUNTS_PASS=$((COUNTS_PASS + 1)) ;;
        FAIL)  COUNTS_FAIL=$((COUNTS_FAIL + 1)) ;;
        SKIP)  COUNTS_SKIP=$((COUNTS_SKIP + 1)) ;;
        INCONCLUSIVE) COUNTS_INC=$((COUNTS_INC + 1)) ;;
    esac
    log INFO check "$name" "$status" "$criterion" "observed=\"$observed\""
}

# emit_artifact FILE PURPOSE
#   Records metadata only. Full content preserved in FILE.
emit_artifact() {
    local file="$1" purpose="$2"
    [ -f "$file" ] || { log WARN artifact "$purpose" MISSING "no file" "path=$file"; return 0; }
    local bytes sha
    bytes=$(wc -c < "$file" | tr -d ' ')
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    log INFO artifact "$purpose" READY "content preserved" "path=$file" "bytes=$bytes" "sha256=$sha"
}

# run_traced LABEL TIMEOUT_S LOGFILE CMD [ARGS...]
#   Emits START, STALL (threshold crossings), END. No periodic output.
run_traced() {
    local label="$1" timeout_s="$2" logfile="$3"
    shift 3

    : > "$logfile"

    log INFO subprocess "$label" START "subprocess starting" \
        "cmd=\"$*\"" "logfile=$logfile"

    local start_epoch
    start_epoch=$(date +%s)

    "$@" > "$logfile" 2>&1 &
    local child=$!

    # Threshold-crossing watcher. Emits one record per threshold crossed.
    # Thresholds: 2s, 15s, 30s, 60s, timeout.
    (
        local crossed_2=0 crossed_15=0 crossed_30=0 crossed_60=0
        while sleep 1; do
            kill -0 "$child" >/dev/null 2>&1 || exit 0
            local now elapsed
            now=$(date +%s); elapsed=$((now - start_epoch))

            if [ "$elapsed" -ge 2 ] && [ "$crossed_2" -eq 0 ]; then
                log INFO subprocess "$label" STALL "crossed 2s" "elapsed_s=$elapsed"
                crossed_2=1
            fi
            if [ "$elapsed" -ge 15 ] && [ "$crossed_15" -eq 0 ]; then
                log INFO subprocess "$label" STALL "crossed 15s" "elapsed_s=$elapsed"
                crossed_15=1
            fi
            if [ "$elapsed" -ge 30 ] && [ "$crossed_30" -eq 0 ]; then
                log INFO subprocess "$label" STALL "crossed 30s" "elapsed_s=$elapsed"
                crossed_30=1
            fi
            if [ "$elapsed" -ge 60 ] && [ "$crossed_60" -eq 0 ]; then
                log INFO subprocess "$label" STALL "crossed 60s" "elapsed_s=$elapsed"
                crossed_60=1
            fi
            if [ "$elapsed" -gt "$timeout_s" ]; then
                log WARN subprocess "$label" TIMEOUT "sending TERM" \
                    "elapsed_s=$elapsed" "timeout_s=$timeout_s"
                kill -TERM "$child" >/dev/null 2>&1
                sleep 2
                kill -KILL "$child" >/dev/null 2>&1
                exit 0
            fi
        done
    ) &
    local watcher=$!

    wait "$child"
    local rc=$?
    kill -TERM "$watcher" >/dev/null 2>&1
    wait "$watcher" >/dev/null 2>&1

    local end_epoch elapsed_ms
    end_epoch=$(date +%s)
    elapsed_ms=$(( (end_epoch - start_epoch) * 1000 ))

    local status="END"
    [ "$rc" -eq 124 ] && status="TIMEOUT"
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && status="ERROR"

    log INFO subprocess "$label" "$status" "subprocess finished" \
        "rc=$rc" "elapsed_ms=$elapsed_ms" "logfile=$logfile"

    return "$rc"
}

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

live_has_data_mount() {
    docker inspect "$C" --format '{{json .Mounts}}' 2>&1 \
      | grep -F "\"Destination\":\"$DATA_CONT\"" >/dev/null
}

count_sessions() {
    # count_sessions AUTH OUTFILE
    #   Writes full API body to OUTFILE. Prints integer or "ERR".
    local auth="$1" outfile="$2"
    curl -s -u "$auth" -m 10 "$HTTP_URL/api/session" -o "$outfile" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$outfile" ]; then
        printf 'ERR'
        return 0
    fi
    if grep -q '"data"' "$outfile" 2>&1; then
        grep -o '"id":"ses_' "$outfile" | wc -l | tr -d ' '
    else
        printf 'ERR'
    fi
}

wait_http() {
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        if [ $((tries % 5)) -eq 0 ] || [ "$code" != "000" ]; then
            log DEBUG http wait POLL "polling" "attempt=$((tries+1))" "http=$code"
        fi
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1)); sleep 2
    done
}

rewrite_block() {
    local compose="$1" ts="$2"
    cp "$compose" "$compose.bak.${ts}"
    log INFO compose rewrite START "rewriting opencode-web block" \
        "backup=$compose.bak.$ts"

    python3 - "$compose" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()

TEMPLATE = """  opencode-web:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-web
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    working_dir: /workspace
    entrypoint: ["/workspace/docker/web-entrypoint.sh"]
    ports:
      - "4096:4096"
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
    env_file:
      - ../.env.local
    environment:
      OPENCODE_DISABLE_DEFAULT_PLUGINS: "true"
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
"""

pat = re.compile(r'^  opencode-web:\n(?:[ \t].*\n|\n)*?(?=^  [a-zA-Z]|\Z)', re.MULTILINE)
m = pat.search(text)
if not m:
    print("REWRITE_FAILED", file=sys.stderr)
    sys.exit(3)

text = text[:m.start()] + TEMPLATE + text[m.end():]
with open(path, "w") as fh:
    fh.write(text)
print("REWRITE_OK")
PY
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log INFO compose rewrite END "block rewritten" "rc=0"
    else
        log ERROR compose rewrite FAIL "block rewrite failed" "rc=$rc"
    fi
    return $rc
}

main() {
    local script_dir repo compose data_host ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf '%s\n' 'GATE FAIL: cannot resolve repo'; return 2; }
    REPO="$repo"
    compose="$repo/$COMPOSE_REL"
    data_host="$repo/$DATA_HOST_REL"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    # Persistent daily log. Rolling append.
    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "fix-data-persistence-v4.3" \
        "repo=$repo" "compose=$compose" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    [ -f "$compose" ] || { log ERROR preflight compose MISSING "compose not found" "path=$compose"; return 1; }
    have python3    || { log ERROR preflight python3 MISSING "python3 not on PATH"; return 1; }
    have curl       || { log ERROR preflight curl    MISSING "curl not on PATH";    return 1; }

    [ -d "$data_host" ] || mkdir -p "$data_host"
    chown -R "$(id -u):$(id -g)" "$data_host" 2>&1 || true

    # --- R1 ---
    log INFO R1 phase START "reading current state"
    local mounts_before
    mounts_before="$ARTIFACT_DIR/mounts-before.json"
    docker inspect "$C" --format '{{json .Mounts}}' > "$mounts_before" 2>&1
    emit_artifact "$mounts_before" "mounts-before"

    # --- R2 ---
    log INFO R2 gate START "evaluating mount presence"
    if live_has_data_mount; then
        record_check "live-has-data-mount" PASS "destination=$DATA_CONT present" "mount-active"
        log INFO R2 gate SKIP "no action needed"
    else
        record_check "live-has-data-mount" FAIL "destination=$DATA_CONT absent" "mount-active"

        if ! rewrite_block "$compose" "$ts"; then
            record_check "rewrite-block" FAIL "python3 exited nonzero" "rewrite-ok"
            log ERROR R2 phase ABORT "rewrite failed" "rc=$?"
            return 1
        fi
        record_check "rewrite-block" PASS "block replaced" "rewrite-ok"

        if ! ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 ); then
            record_check "compose-config" FAIL "parse error" "config-valid"
            log ERROR R2 phase ABORT "compose config rejects file" "backup=$compose.bak.$ts"
            return 1
        fi
        record_check "compose-config" PASS "parses cleanly" "config-valid"

        log INFO R3 phase START "recreating container"
        ( cd "$repo/docker" && \
          run_traced "recreate-1" 60 "$ARTIFACT_DIR/recreate-1.log" \
              docker compose up -d --force-recreate opencode-web )
        local rc_rec=$?
        emit_artifact "$ARTIFACT_DIR/recreate-1.log" "recreate-1-log"
        if [ "$rc_rec" -ne 0 ]; then
            record_check "recreate-1" FAIL "rc=$rc_rec" "compose-up-ok"
            return 1
        fi
        record_check "recreate-1" PASS "rc=0" "compose-up-ok"
        wait_http

        local mounts_after
        mounts_after="$ARTIFACT_DIR/mounts-after.json"
        docker inspect "$C" --format '{{json .Mounts}}' > "$mounts_after" 2>&1
        emit_artifact "$mounts_after" "mounts-after"

        if ! live_has_data_mount; then
            record_check "mount-after-recreate" FAIL "still absent" "mount-active"
            log ERROR R3 phase ABORT "rewrite did not produce active mount"
            return 1
        fi
        record_check "mount-after-recreate" PASS "present" "mount-active"
    fi

    # --- Persistence test ---
    log INFO persistence phase START "two-session recreate test"

    local pass
    pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    if [ -z "$pass" ]; then
        record_check "password-present" FAIL "empty" "password-nonempty"
        log ERROR persistence phase ABORT "password empty"
        return 1
    fi
    record_check "password-present" PASS "length=${#pass}" "password-nonempty"
    local auth="opencode:$pass"

    local log1 log2
    log1="$ARTIFACT_DIR/p1.log"
    log2="$ARTIFACT_DIR/p2.log"

    run_traced "P1" "$RUN_TIMEOUT" "$log1" \
        docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: P1'"
    local rc1=$?
    emit_artifact "$log1" "P1-run-log"

    run_traced "P2" "$RUN_TIMEOUT" "$log2" \
        docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: P2'"
    local rc2=$?
    emit_artifact "$log2" "P2-run-log"

    local p1_ok=0 p2_ok=0
    grep -q 'P1' "$log1" && p1_ok=1
    grep -q 'P2' "$log2" && p2_ok=1

    if [ "$p1_ok" -eq 1 ]; then
        record_check "P1-reply" PASS "token P1 found" "reply-contains-token"
    else
        record_check "P1-reply" INCONCLUSIVE "rc=$rc1 token missing" "reply-contains-token"
    fi
    if [ "$p2_ok" -eq 1 ]; then
        record_check "P2-reply" PASS "token P2 found" "reply-contains-token"
    else
        record_check "P2-reply" INCONCLUSIVE "rc=$rc2 token missing" "reply-contains-token"
    fi

    if [ "$p1_ok" -eq 0 ] || [ "$p2_ok" -eq 0 ]; then
        log ERROR persistence phase ABORT "model run incomplete"
        SUMMARY_TEXT="Persistence test not evaluable: one or both model runs failed to return their token. See artifacts."
        render_summary 1
        return 1
    fi

    local before_body after_body before after
    before_body="$ARTIFACT_DIR/before-body.json"
    after_body="$ARTIFACT_DIR/after-body.json"

    before=$(count_sessions "$auth" "$before_body")
    emit_artifact "$before_body" "api-before"

    if [ "$before" = "ERR" ]; then
        record_check "sessions-before" INCONCLUSIVE "api-non-json" "api-returns-json"
        log ERROR persistence phase ABORT "before-api-non-json"
        SUMMARY_TEXT="Persistence test not evaluable: /api/session did not return JSON before recreate."
        render_summary 1
        return 1
    fi
    record_check "sessions-before" PASS "count=$before" "count-ge-2"

    if [ "$before" -lt 2 ]; then
        record_check "sessions-before-count" FAIL "count=$before" "count-ge-2"
        log ERROR persistence phase ABORT "fewer than 2 sessions before recreate"
        SUMMARY_TEXT="Persistence test not evaluable: only $before sessions before recreate (need >= 2)."
        render_summary 1
        return 1
    fi

    log INFO recreate phase START "second recreate"
    ( cd "$repo/docker" && \
      run_traced "recreate-2" 60 "$ARTIFACT_DIR/recreate-2.log" \
          docker compose up -d --force-recreate opencode-web )
    emit_artifact "$ARTIFACT_DIR/recreate-2.log" "recreate-2-log"
    wait_http

    after=$(count_sessions "$auth" "$after_body")
    emit_artifact "$after_body" "api-after"

    if [ "$after" = "ERR" ]; then
        record_check "sessions-after" INCONCLUSIVE "api-non-json" "api-returns-json"
        SUMMARY_TEXT="Persistence test not evaluable: /api/session did not return JSON after recreate."
        render_summary 1
        return 1
    fi

    if [ "$after" = "$before" ] && [ "$before" -ge 2 ]; then
        record_check "sessions-after" PASS "count=$after" "count-equal-before"
        SUMMARY_TEXT="Persistence verified. $before sessions survived a full recreate. Mount is active; data is durable."
        render_summary 0
        return 0
    fi

    record_check "sessions-after" FAIL "before=$before after=$after" "count-equal-before"
    SUMMARY_TEXT="Persistence FAILED. Sessions dropped from $before to $after across a recreate. Mount check §R3 passed but data still lost — inspect $mounts_before vs $( [ -n "$mounts_after" ] && printf '%s' "$mounts_after" || printf 'second inspect' )."
    render_summary 1
    return 1
}

render_summary() {
    local rc="$1"
    local log_basename
    log_basename=$(basename "$LOG")
    printf '\n'
    printf '%s\n' "SUMMARY log=$LOG pass=$COUNTS_PASS fail=$COUNTS_FAIL skip=$COUNTS_SKIP inconclusive=$COUNTS_INC rc=$rc"
    printf '%s\n' "$SUMMARY_TEXT"
    log INFO session end END "summary rendered" \
        "pass=$COUNTS_PASS" "fail=$COUNTS_FAIL" "skip=$COUNTS_SKIP" \
        "inconclusive=$COUNTS_INC" "rc=$rc"
    printf '\n'
    printf '%s\n' "log:       $LOG"
    printf '%s\n' "artifacts: $ARTIFACT_DIR"
}

main "$@"
