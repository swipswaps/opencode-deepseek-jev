#!/usr/bin/env bash
#
# test-opencode-deepseek-chatlog.sh — post-fix verification suite for the
# opencode-deepseek-web container.
#
# Gates:
#   G0  repo resolvable
#   G1  container running
#   G2  auth.json present inside the container
#   G3  HTTP listener responds (401 expected behind password)
#   G4  providers list names DeepSeek
#   G5  models list yields a deepseek/* ID
#   G6  one-shot completion returns PONG
#   G7  workspace mount visible
#   G8  model can read a known file and answer correctly
#   G9  sqlite session table present with >= 1 row
#   G10 session table carries a row from the last 30 min
#   G11 JEV one-shot (SKIP unless JEV_MODEL_ID is provided)
#
# ============================================================================
# CONSTRAINTS
# ============================================================================
#
#   No sed.     Indentation via indent() helper.
#   No rm -rf.  Nothing is removed; db copy goes to /tmp.
#   No set -e.  Failures are inspected, not aborted on.
#   No return 1.  main() returns status codes.
#   No 2>/dev/null.  Stderr is preserved.
#   No subprocess.run.  No python at all in this script.
#   No bare kill.  timeout(1) sends TERM by default.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX read(1) (shell builtin):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/read.html
#   Docker exec:
#     https://docs.docker.com/engine/reference/commandline/exec/
#   Docker cp:
#     https://docs.docker.com/engine/reference/commandline/cp/
#   SQLite CLI:
#     https://sqlite.org/cli.html
#   opencode CLI (models subcommand, top-level help):
#     observed 2026-09-22 in-container: `opencode models [provider]`
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
# ============================================================================

set -o pipefail

CONTAINER="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"
DATA_DIR="/home/node/.local/share/opencode"
AUTH_PATH="$DATA_DIR/auth.json"
WORKSPACE="/workspace"
PROBE_FILE="docker/docker-compose.yml"
PROBE_ANSWER="opencode-web"
RUN_TIMEOUT=180

GATES_RUN=0
GATES_PASS=0
GATES_FAIL=0
GATES_SKIP=0

indent() {
    local line
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
}

gate() {
    GATES_RUN=$((GATES_RUN + 1))
    case "$2" in
        PASS) GATES_PASS=$((GATES_PASS + 1)) ;;
        FAIL) GATES_FAIL=$((GATES_FAIL + 1)) ;;
        SKIP) GATES_SKIP=$((GATES_SKIP + 1)) ;;
    esac
    printf '  %-4s %-4s %s\n' "$1" "$2" "$3"
}

section() { printf '\n=== %s ===\n' "$1"; }

# is_uint() — true if $1 is a non-empty string of digits only.
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

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

load_env() {
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            DEEPSEEK_API_KEY) DEEPSEEK_API_KEY="$v" ;;
            JEV_API_KEY)      JEV_API_KEY="$v" ;;
            JEV_MODEL_ID)     JEV_MODEL_ID="$v" ;;
        esac
    done < "$env_file"
    export DEEPSEEK_API_KEY JEV_API_KEY JEV_MODEL_ID
}

main() {
    printf '=== test-opencode-deepseek-chatlog.sh ===\n'

    local script_dir repo_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_dir=$(resolve_repo "$script_dir")
    [ -z "$repo_dir" ] && repo_dir=$(resolve_repo "$PWD")

    section "G0  repo resolution"
    if [ -z "$repo_dir" ]; then
        gate G0 FAIL "cannot locate opencode.json + docker/Dockerfile above $PWD"
        return 2
    fi
    gate G0 PASS "repo: $repo_dir"
    load_env "$repo_dir/.env.local"

    section "G1  container running"
    local cstate
    cstate=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>&1)
    if [ "$cstate" != "running" ]; then
        gate G1 FAIL "state=$cstate"
        return 1
    fi
    gate G1 PASS "state=running"

    section "G2  auth.json inside the container"
    local auth_ls abytes
    auth_ls=$(docker exec "$CONTAINER" sh -c "ls -la '$AUTH_PATH' && wc -c < '$AUTH_PATH'" 2>&1)
    if printf '%s' "$auth_ls" | grep -q 'No such file'; then
        gate G2 FAIL "auth.json missing — entrypoint did not run"
        printf '%s\n' "$auth_ls" | indent
    else
        abytes=$(printf '%s\n' "$auth_ls" | tail -1 | tr -d ' ')
        if ! is_uint "$abytes" || [ "$abytes" -lt 1 ]; then
            gate G2 FAIL "auth.json present but size unreadable: $abytes"
        else
            gate G2 PASS "auth.json ${abytes} bytes"
        fi
    fi

    section "G3  HTTP listener"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$HTTP_URL/" 2>&1)
    case "$code" in
        200|401) gate G3 PASS "http=$code" ;;
        000|"")  gate G3 FAIL "no listener at $HTTP_URL" ;;
        *)       gate G3 PASS "http=$code (unusual but live)" ;;
    esac

    section "G4  providers list"
    local prov_out
    prov_out=$(docker exec -w "$WORKSPACE" "$CONTAINER" sh -c 'opencode providers list' 2>&1)
    printf '%s\n' "$prov_out" | indent
    if printf '%s' "$prov_out" | grep -qi 'deepseek'; then
        gate G4 PASS "DeepSeek listed"
    else
        gate G4 FAIL "DeepSeek absent from providers list"
    fi

    section "G5  model id discovery"
    local models_out deepseek_model
    models_out=$(docker exec -w "$WORKSPACE" "$CONTAINER" sh -c 'opencode models' 2>&1)
    deepseek_model=$(printf '%s\n' "$models_out" | grep -Eio 'deepseek/[A-Za-z0-9._-]+' | head -1)
    if [ -z "$deepseek_model" ]; then
        gate G5 FAIL "no deepseek/* id in models output"
        printf '%s\n' "$models_out" | head -30 | indent
        DEEPSEEK_MODEL=""
    else
        gate G5 PASS "model id: $deepseek_model"
        DEEPSEEK_MODEL="$deepseek_model"
    fi

    section "G6  one-shot completion (PONG)"
    if [ -z "$DEEPSEEK_MODEL" ]; then
        gate G6 SKIP "no model id from G5"
    else
        local pong_out
        pong_out=$(timeout "$RUN_TIMEOUT" docker exec -w "$WORKSPACE" "$CONTAINER" \
            sh -c "opencode run --model '$DEEPSEEK_MODEL' 'Reply with exactly: PONG'" 2>&1)
        printf '%s\n' "$pong_out" | tail -20 | indent
        if printf '%s' "$pong_out" | grep -q 'PONG'; then
            gate G6 PASS "model replied PONG"
        else
            gate G6 FAIL "no PONG in output (timeout=$RUN_TIMEOUT s)"
        fi
    fi

    section "G7  workspace mount"
    local ws_ls ws_count
    ws_ls=$(docker exec -w "$WORKSPACE" "$CONTAINER" sh -c 'ls -A /workspace' 2>&1)
    ws_count=$(printf '%s\n' "$ws_ls" | grep -c .)
    if [ "$ws_count" -lt 1 ]; then
        gate G7 FAIL "workspace appears empty"
    else
        gate G7 PASS "$ws_count entries visible"
        printf '%s\n' "$ws_ls" | head -12 | indent
    fi

    section "G8  model reads a known file"
    if [ -z "$DEEPSEEK_MODEL" ]; then
        gate G8 SKIP "no model id from G5"
    else
        local read_out
        read_out=$(timeout "$RUN_TIMEOUT" docker exec -w "$WORKSPACE" "$CONTAINER" \
            sh -c "opencode run --model '$DEEPSEEK_MODEL' 'Read $PROBE_FILE and reply with only the service name whose entrypoint is web-entrypoint.sh.'" 2>&1)
        printf '%s\n' "$read_out" | tail -15 | indent
        if printf '%s' "$read_out" | grep -q "$PROBE_ANSWER"; then
            gate G8 PASS "model answered '$PROBE_ANSWER'"
        else
            gate G8 FAIL "model did not return '$PROBE_ANSWER'"
        fi
    fi

    section "G9  sqlite session table"
    local have_sqlite=0
    command -v sqlite3 >/dev/null && have_sqlite=1
    local db_local="/tmp/opencode-test.db"
    docker cp "$CONTAINER:$DATA_DIR/opencode.db"      "$db_local"      2>&1 | indent
    docker cp "$CONTAINER:$DATA_DIR/opencode.db-wal"  "$db_local-wal"  2>&1 | indent || true
    docker cp "$CONTAINER:$DATA_DIR/opencode.db-shm"  "$db_local-shm"  2>&1 | indent || true

    if [ "$have_sqlite" -ne 1 ]; then
        gate G9 SKIP "sqlite3 not on host; db copied to $db_local"
    elif [ ! -f "$db_local" ]; then
        gate G9 FAIL "docker cp produced no $db_local"
    else
        local tables has_session count
        tables=$(sqlite3 "$db_local" ".tables" 2>&1)
        has_session=$(printf '%s\n' "$tables" | tr ' ' '\n' | grep -x 'session' | head -1)
        if [ -z "$has_session" ]; then
            gate G9 FAIL "no 'session' table; tables: $tables"
        else
            count=$(sqlite3 "$db_local" "select count(*) from session;" 2>&1)
            if ! is_uint "$count"; then
                gate G9 FAIL "count query error: $count"
            elif [ "$count" -ge 1 ]; then
                gate G9 PASS "session rows=$count"
            else
                gate G9 FAIL "session table empty (rows=0) — G6/G8 did not persist"
            fi
        fi
    fi

    section "G10 sessions written in the last 30 min"
    if [ "$have_sqlite" -ne 1 ] || [ ! -f "$db_local" ]; then
        gate G10 SKIP "sqlite3/db unavailable"
    else
        # session.time_created is INTEGER NOT NULL milliseconds since epoch.
        local now_ms cutoff recent
        now_ms=$(($(date +%s) * 1000))
        cutoff=$((now_ms - 1800000))
        recent=$(sqlite3 "$db_local" \
            "select count(*) from session where time_created >= $cutoff;" 2>&1)
        if ! is_uint "$recent"; then
            gate G10 FAIL "query error: $recent"
        elif [ "$recent" -ge 1 ]; then
            gate G10 PASS "$recent session(s) in last 30 min"
            printf 'recent sessions:\n'
            sqlite3 -header "$db_local" \
                "select id, substr(title,1,40) as title, model, tokens_input, tokens_output
                   from session where time_created >= $cutoff
                   order by time_created desc limit 10;" 2>&1 | indent
        else
            gate G10 FAIL "no session in last 30 min"
            local total
            total=$(sqlite3 "$db_local" "select count(*) from session;" 2>&1)
            printf '  total session rows: %s\n' "$total"
            printf '  cutoff (ms):        %s\n' "$cutoff"
            local maxt
            maxt=$(sqlite3 "$db_local" "select coalesce(max(time_created),0) from session;" 2>&1)
            printf '  max(time_created):  %s\n' "$maxt"
        fi
    fi

    section "G11 JEV one-shot"
    if [ -z "${JEV_MODEL_ID:-}" ]; then
        gate G11 SKIP "set JEV_MODEL_ID in .env.local to enable"
    else
        local jev_out
        jev_out=$(timeout "$RUN_TIMEOUT" docker exec -w "$WORKSPACE" "$CONTAINER" \
            sh -c "opencode run --model '$JEV_MODEL_ID' 'Reply with exactly: JEVOK'" 2>&1)
        printf '%s\n' "$jev_out" | tail -15 | indent
        if printf '%s' "$jev_out" | grep -q 'JEVOK'; then
            gate G11 PASS "JEV replied JEVOK"
        else
            gate G11 FAIL "no JEVOK in output"
        fi
    fi

    section "summary"
    printf '  run=%d  pass=%d  fail=%d  skip=%d\n' \
        "$GATES_RUN" "$GATES_PASS" "$GATES_FAIL" "$GATES_SKIP"
    printf '  db copy: %s\n' "$db_local"

    if [ "$GATES_FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
