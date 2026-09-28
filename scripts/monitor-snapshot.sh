#!/usr/bin/env bash
#
# monitor-snapshot.sh — one-shot repo health snapshot from the databases/logs.
#
# Reads (never writes): data/opencode/opencode.db (read-only URI),
# data/observability/observability.db, data/observability/guard.log,
# data/opencode/log/opencode.log tail, docker ps, :4096/:5099 probes,
# key NAMES from .env.local. Prints names/codes/counts only — secret values
# never appear (safe to paste or store under notes/).
#
#   ./scripts/monitor-snapshot.sh [--json] [--no-docker] [--db PATH]
#   ./scripts/monitor-snapshot.sh --self-test   # offline fixture, no docker
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
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

q() {
    # q <db> <sql> — read-only query, empty string on failure (never fatal).
    sqlite3 "file:$1?mode=ro" "$2" 2>&1 || true
}

self_test() {
    local fail=0
    command -v sqlite3 > /dev/null || { printf 'FAIL sqlite3 missing\n'; return 1; }
    command -v python3 > /dev/null || { printf 'FAIL python3 missing\n'; return 1; }
    local work=""
    work=$(mktemp -d)
    sqlite3 "$work/fix.db" "CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, tokens_input INTEGER, time_created INTEGER); CREATE TABLE part(id TEXT, session_id TEXT, data TEXT);" > /dev/null
    sqlite3 "$work/fix.db" "INSERT INTO session VALUES('s1','t',100,1),('s2','u',200,2); INSERT INTO part VALUES('p1','s1','{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"running\"}}'),('p2','s2','{\"type\":\"text\"}');" > /dev/null
    local n=""
    n=$(q "$work/fix.db" "SELECT COUNT(*) FROM session;")
    [ "$n" = "2" ] || { printf 'FAIL sessions got=%s\n' "$n"; fail=1; }
    n=$(q "$work/fix.db" "SELECT COUNT(*) FROM part WHERE json_extract(data,'\$.state.status')='running';")
    [ "$n" = "1" ] || { printf 'FAIL running got=%s\n' "$n"; fail=1; }
    local j=""
    j=$("$REPO_BIN/monitor-snapshot.sh" --json --no-docker --db "$work/fix.db")
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("sessions")==2 and d.get("running_tools")==1 else 1)' <<< "$j" || { printf 'FAIL json shape\n'; fail=1; }
    rm -f "$work/fix.db"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'monitor-snapshot: self-test PASS\n'; else printf 'monitor-snapshot: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local repo=""
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -n "$repo" ] || repo=$(resolve_repo "$PWD")
    [ -n "$repo" ] || { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    REPO_BIN="$repo/scripts"
    local json=0 nodocker=0 selftest=0 db="$repo/data/opencode/opencode.db"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            --no-docker) nodocker=1; shift ;;
            --self-test) selftest=1; shift ;;
            --db=*) db="${1#--db=}"; shift ;;
            --db) db="${2:-}"; shift 2 ;;
            -h|--help) printf 'usage: %s [--json] [--no-docker] [--db PATH] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    if [ "$selftest" -eq 1 ]; then self_test; return "$?"; fi
    command -v sqlite3 > /dev/null || { printf 'GATE FAIL: sqlite3 missing\n'; return 1; }
    command -v python3 > /dev/null || { printf 'GATE FAIL: python3 missing\n'; return 1; }

    local sessions parts dbbytes running latest_in latest_title blanks
    sessions=$(q "$db" "SELECT COUNT(*) FROM session;")
    parts=$(q "$db" "SELECT COUNT(*) FROM part;")
    dbbytes=$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$db")
    running=$(q "$db" "SELECT COUNT(*) FROM part WHERE json_extract(data,'\$.type')='tool' AND json_extract(data,'\$.state.status')='running';")
    latest_in=$(q "$db" "SELECT COALESCE(tokens_input,0) FROM session ORDER BY time_created DESC LIMIT 1;")
    latest_title=$(q "$db" "SELECT substr(COALESCE(title,'(none)'),1,60) FROM session ORDER BY time_created DESC LIMIT 1;")
    blanks=$(q "$db" "SELECT COUNT(*) FROM (SELECT s.id FROM session s WHERE s.id IN (SELECT id FROM session ORDER BY time_created DESC LIMIT 40) AND EXISTS (SELECT 1 FROM part p WHERE p.session_id=s.id AND json_extract(p.data,'\$.type')='tool')) ;")

    local guard_blocks guard_warn guard_adv
    guard_blocks=$(grep -c '"verdict":"block"' "$repo/data/observability/guard.log" 2>&1 || true)
    guard_warn=$(grep -c '"verdict":"warn"' "$repo/data/observability/guard.log" 2>&1 || true)
    guard_adv=$(grep -c '"verdict":"advisory"' "$repo/data/observability/guard.log" 2>&1 || true)

    local keys=""
    for k in DEEPSEEK_API_KEY JEV_API_KEY GEMINI_API_KEY OPENCODE_SERVER_PASSWORD; do
        if grep -q "^$k=" "$repo/.env.local" 2>&1; then keys="$keys$k=1 "; else keys="$keys$k=0 "; fi
    done

    local web_status="skip" web_restarts="skip" code4096="skip" health="skip" latency="skip"
    if [ "$nodocker" -eq 0 ] && command -v docker > /dev/null; then
        web_status=$(docker inspect opencode-deepseek-web --format '{{.State.Status}}' 2>&1 || printf 'unknown')
        web_restarts=$(docker inspect opencode-deepseek-web --format '{{.RestartCount}}' 2>&1 || printf '?')
        if command -v curl > /dev/null; then
            code4096=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:4096/ 2>&1 || printf '000')
            local hj=""
            hj=$(curl -s --max-time 12 http://127.0.0.1:5099/api/health 2>&1 || true)
            latency=$(curl -s -o /dev/null -w '%{time_total}' --max-time 15 http://127.0.0.1:5099/api/health 2>&1 || printf '?')
            health=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("handoff") or {}).get("level","?"))' <<< "$hj" 2>&1 || printf '?')
        fi
    fi

    if [ "$json" -eq 1 ]; then
        python3 -c 'import json; print(json.dumps({
          "sessions": int("'"$sessions"'" or 0), "parts": int("'"$parts"'" or 0),
          "db_bytes": int("'"$dbbytes"'" or 0), "running_tools": int("'"$running"'" or 0),
          "latest_input": int("'"$latest_in"'" or 0),
          "guard": {"block": int("'"$guard_blocks"'" or 0), "warn": int("'"$guard_warn"'" or 0), "advisory": int("'"$guard_adv"'" or 0)},
          "web": {"status": "'"$web_status"'", "restarts": "'"$web_restarts"'", "p4096": "'"$code4096"'", "health": "'"$health"'", "latency_s": "'"$latency"'"} }))'
    else
        printf '=== monitor-snapshot ===\n'
        printf 'db: sessions=%s parts=%s bytes=%s running_tools=%s\n' "$sessions" "$parts" "$dbbytes" "$running"
        printf 'latest: input=%s title=%s\n' "$latest_in" "$latest_title"
        printf 'guard: block=%s warn=%s advisory=%s\n' "$guard_blocks" "$guard_warn" "$guard_adv"
        printf 'keys: %s\n' "$keys"
        printf 'web: status=%s restarts=%s p4096=%s health=%s latency_s=%s\n' "$web_status" "$web_restarts" "$code4096" "$health" "$latency"
    fi
    return 0
}

main "$@"
