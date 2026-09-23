#!/usr/bin/env bash
#
# run-audit-via-agent.sh
#
# Performs the audit BY THE AGENT, not by this script. This wrapper:
#   1. Ensures /notes is visible inside the container (read-only bind mount).
#   2. Invokes `opencode run` with a task that reads /workspace and /notes,
#      writes a report to /workspace/logs/sidebar-audit.md, and calls
#      jev_review for a correctness score.
#   3. Captures the agent transcript as an artifact.
#   4. Verifies the report file exists and prints its path.
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
    if [ ! -f "$f" ]; then
        log WARN artifact "$label" MISSING "no file" "path=$f"
        return 0
    fi
    local bytes sha
    bytes=$(wc -c < "$f" | tr -d ' ')
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    log INFO artifact "$label" READY "captured" \
        "path=$f" "bytes=$bytes" "sha256=$sha"
}

# ensure_notes_mount COMPOSE_FILE NOTES_HOST NOTES_CONT
#   Idempotent. Backs up before editing. Returns 0 if a recreate is needed.
ensure_notes_mount() {
    local compose="$1" hostrel="$2" cont="$3"
    if grep -qF "$cont" "$compose"; then
        log INFO mount notes PASS "already present" "cont=$cont"
        return 1   # no recreate needed
    fi
    local ts
    ts=$(date -u +%Y%m%dT%H%M%SZ)
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
    print("ANCHOR_MISSING", file=sys.stderr)
    sys.exit(3)
if cont in src:
    print("ALREADY_PRESENT")
    sys.exit(0)

new_line = anchor + f"      - {hostrel}:{cont}:ro\n"
src = src.replace(anchor, new_line, 1)
with open(path, "w") as fh:
    fh.write(src)
print("MOUNT_ADDED")
PY
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        log ERROR mount notes FAIL "python3 edit failed" "rc=$rc"
        return 2
    fi
    return 0
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

    log INFO session start START "run-audit-via-agent" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    # Host-side checks
    if [ ! -d "$parent/notes" ]; then
        log WARN preflight notes MISSING "notes dir not on host" \
            "path=$parent/notes"
        printf '\n  notes/ does not exist at %s\n' "$parent/notes"
        printf '  The agent will audit /workspace only.\n\n'
    else
        log INFO preflight notes PASS "host notes present" \
            "path=$parent/notes"
    fi

    # Ensure mount
    if [ -d "$parent/notes" ]; then
        ensure_notes_mount "$compose" "$NOTES_HOST_REL" "$NOTES_CONT"
        local mrc=$?
        if [ "$mrc" -eq 0 ]; then
            log INFO recreate START "recreating for new mount"
            ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
            if [ $? -ne 0 ]; then
                log ERROR recreate FAIL "compose up failed"
                return 1
            fi
            local tries=0 code=""
            while [ "$tries" -lt 60 ]; do
                code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
                [ -n "$code" ] && [ "$code" != "000" ] && break
                tries=$((tries + 1)); sleep 2
            done
            log INFO recreate PASS "container up" "http=$code"
        elif [ "$mrc" -eq 1 ]; then
            log INFO mount notes SKIP "no recreate needed"
        else
            log ERROR mount notes FAIL "compose not modified"
            return 1
        fi
    fi

    # Confirm container sees /notes
    local notes_visible
    if docker exec "$C" sh -c "[ -d $NOTES_CONT ]" 2>&1; then
        notes_visible="yes"
    else
        notes_visible="no"
    fi
    log INFO verify notes READY "visibility check" "cont=$NOTES_CONT visible=$notes_visible"

    # ------------------------------------------------------------------
    # Build the prompt and deliver via stdin to avoid host-side quoting.
    # ------------------------------------------------------------------
    local prompt_file_in_container="/tmp/audit-prompt.txt"
    printf '    delivering prompt to %s\n' "$prompt_file_in_container"

    docker exec -i "$C" sh -c "cat > $prompt_file_in_container" <<PROMPT_END
You are auditing a Docker-packaged coding agent environment.

Readable locations:
- /workspace -- the project repo (read/write)
- /notes     -- chat logs (read-only), visible=$notes_visible

Produce an audit report at /workspace/logs/sidebar-audit.md with these sections:

1. Project identity -- read README.txt, QUICKSTART.txt, opencode.json. One paragraph: what is this project?

2. Rule system -- if /notes is visible, grep it for patterns like #7, #8, #37, #38, #41, #53, #54, #55, #57. List which rule numbers appear. Cross-reference with scripts/archive/one-shot/push_notes_v18.sh which cites a specific set. Report any cited-but-undefined or defined-but-uncited rules.

3. JEV -- grep /notes (case-insensitive) and /workspace for "jev". Note where it appears.

4. Current state -- paste the opencode-web service block from docker/docker-compose.yml. Read docker/web-entrypoint.sh. Query session count:  sqlite3 /workspace/data/opencode/opencode.db "select count(*) from session;"

5. Open risks -- five bullets a new operator should know before touching this repo.

Then call the jev_review tool once with:
  task:     "Produce a project audit report at logs/sidebar-audit.md"
  diff:     "New file: logs/sidebar-audit.md"
  files:    [{"path": "logs/sidebar-audit.md", "content": "<the report you wrote>"}]
  repositoryContext: "opencode-deepseek-jev container; /workspace is the repo, /notes is read-only chat history"

Reply with two lines only:
  correctness=<score from jev_review>
  summary=<one sentence about the audit>
PROMPT_END

    # ------------------------------------------------------------------
    # Invoke the agent.
    # ------------------------------------------------------------------
    local transcript="$ARTIFACT_DIR/agent-transcript.log"
    local flag="$ARTIFACT_DIR/timeout-flag"
    : > "$flag"
    : > "$transcript"

    log INFO agent invoke START "starting agent" \
        "model=$MODEL" "timeout_s=$RUN_TIMEOUT" \
        "transcript=$transcript"

    local start_epoch
    start_epoch=$(date +%s)

    docker exec -w /workspace "$C" sh -c \
        "opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat $prompt_file_in_container)\"" \
        > "$transcript" 2>&1 &
    local child=$!

    (
        local c15=0 c60=0 c180=0
        while sleep 1; do
            kill -0 "$child" >/dev/null 2>&1 || exit 0
            local now elapsed
            now=$(date +%s); elapsed=$((now - start_epoch))
            if [ "$elapsed" -ge 15 ] && [ "$c15" -eq 0 ]; then
                log INFO agent invoke STALL "crossed 15s" "elapsed_s=$elapsed"
                c15=1
            fi
            if [ "$elapsed" -ge 60 ] && [ "$c60" -eq 0 ]; then
                log INFO agent invoke STALL "crossed 60s" "elapsed_s=$elapsed"
                c60=1
            fi
            if [ "$elapsed" -ge 180 ] && [ "$c180" -eq 0 ]; then
                log INFO agent invoke STALL "crossed 180s" "elapsed_s=$elapsed"
                c180=1
            fi
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

    log INFO agent invoke "$status" "agent finished" \
        "rc=$rc" "child_rc=$child_rc" "elapsed_ms=$elapsed_ms" \
        "transcript=$transcript"
    emit_artifact "$transcript" "agent-transcript"

    # ------------------------------------------------------------------
    # Verify the report landed.
    # ------------------------------------------------------------------
    local report_host="$repo/logs/sidebar-audit.md"
    local report_ok=0
    if [ -f "$report_host" ]; then
        report_ok=1
        emit_artifact "$report_host" "sidebar-audit-md"
    else
        # Try to copy from container in case it wrote to an unexpected path
        local alt
        alt=$(docker exec "$C" sh -c 'ls -la /workspace/logs/sidebar-audit.md' 2>&1)
        log WARN report missing MISSING "report not at expected path" \
            "expected=$report_host" "container_check=\"$alt\""
    fi

    # ------------------------------------------------------------------
    # Print agent output tail and where things landed.
    # ------------------------------------------------------------------
    printf '\n===== agent stdout tail =====\n'
    tail -60 "$transcript" | while IFS= read -r line; do printf '    %s\n' "$line"; done

    printf '\n===== report =====\n'
    if [ "$report_ok" -eq 1 ]; then
        printf '    path: %s\n' "$report_host"
        printf '    bytes: %s\n' "$(wc -c < "$report_host" | tr -d ' ')"
        printf '\n    first 80 lines:\n'
        head -80 "$report_host" | while IFS= read -r line; do printf '      %s\n' "$line"; done
    else
        printf '    not found at %s\n' "$report_host"
    fi

    log INFO session end END "done" "rc=$rc" "report_ok=$report_ok"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return "$rc"
}

main "$@"
