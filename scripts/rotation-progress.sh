#!/usr/bin/env bash
#
# rotation-progress.sh — read-only progress/status for the open rotation
# terminal plus the background workers that touch the :4096 store.
#
# What it reads (never writes):
#   - process table + /proc: the rotate-server-password.sh tree, its tty,
#     state, wchan and stdin target
#   - data/observability/jobs/rotate-server-password.jsonl (durable-run)
#   - .env.local and .env.local.bak.rotate: mode/size and cmp only, never values
#   - /tmp/rotate-smoke-*.log: last line of the newest smoke log
#   - docker state/top for opencode-deepseek-web
#   - systemd --user state for sentinel/proactive/progress-review/fts-refresh
#   - https://HOST:4096/session/status and :5099/api/health (codes only)
#   - data/opencode/opencode.db via file:...?mode=ro (counts, stale tools)
#
#   ./scripts/rotation-progress.sh
#   ./scripts/rotation-progress.sh --watch 5
#   ./scripts/rotation-progress.sh --json
#   ./scripts/rotation-progress.sh --host 10.100.0.24 --no-net
#
# Exit 0 on a completed read, 2 on usage/resolve error. Ctrl-C stops a watch
# view; it never signals the rotation or the server.
#
# Constraints: no set -e, no top-level exit, printf only, main() wrapper,
#   read-only sqlite URI, no raw .env values printed.
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

have() { command -v "$1" >/dev/null 2>&1; }

q() {
    sqlite3 -separator '|' "file:$1?mode=ro" "$2" 2>&1 || true
}

fmt_age() {
    local s="${1:-0}"
    case "$s" in ''|*[!0-9]*) printf '?'; return ;; esac
    if [ "$s" -ge 86400 ]; then
        printf '%dd%dh' "$((s / 86400))" "$((s % 86400 / 3600))"
    elif [ "$s" -ge 3600 ]; then
        printf '%dh%dm' "$((s / 3600))" "$((s % 3600 / 60))"
    elif [ "$s" -ge 60 ]; then
        printf '%dm%ds' "$((s / 60))" "$((s % 60))"
    else
        printf '%ds' "$s"
    fi
}

latest_file() {
    local dir="$1" pat="$2"
    find "$dir" -maxdepth 1 -type f -name "$pat" -printf '%T@\t%p\n' 2>&1 \
        | sort -nr | head -n 1 | cut -f2-
}

checkpoint_state() {
    local f="$1"
    if [ ! -f "$f" ]; then
        printf 'missing'
        return
    fi
    python3 - "$f" <<'PY'
import json
import sys
import time

rows = []
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            ts = d.get("ts")
            when = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts)) if isinstance(ts, (int, float)) else "?"
            rows.append("%s=%s@%s" % (d.get("step", "?"), "ok" if d.get("ok") else "FAIL", when))
except OSError as exc:
    print("unreadable: %s" % exc)
    raise SystemExit(0)
print("; ".join(rows) if rows else "empty")
PY
}

usage() {
    printf 'usage: %s [--watch SEC] [--json] [--no-net] [--host H] [--db PATH] [--env PATH]\n' "$0"
}

run_once() {
    local ts db envf bak jobs smoke_log smoke_state checkpoint
    local rotate_ps rpid rtty rstat retime rwchan rstdin
    local rewritten env_mode env_size rotated proof
    local web_status web_restarts web_started web_procs
    local p4096 p5099 busy_sessions timers timer_line u
    local sessions parts tools states stale pending stale_list stale_top latest
    local latest_id latest_title latest_created dbbytes dbmtime
    local active active_id active_title active_updated lastpart walbytes walmtime
    local sep="----------------------------------------"

    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    db="$DB"
    envf="$ENVF"
    bak="$ENVF.bak.rotate"
    jobs="$REPO/data/observability/jobs/rotate-server-password.jsonl"
    smoke_log=$(latest_file /tmp 'rotate-smoke-*.log')

    rotate_ps=""
    if have pgrep; then
        rotate_ps=$(pgrep -af 'rotate-server-password\.sh' 2>&1 || true)
    fi
    rpid=$(printf '%s\n' "$rotate_ps" | awk 'NF{last=$1} END{print last}')
    if [ -n "$rpid" ] && [ -d "/proc/$rpid" ]; then
        rtty=$(ps -o tty= -p "$rpid" 2>&1 | awk 'NF{print $1; exit}')
        rstat=$(ps -o stat= -p "$rpid" 2>&1 | awk 'NF{print $1; exit}')
        retime=$(ps -o etime= -p "$rpid" 2>&1 | awk 'NF{print $1; exit}')
        rwchan=$(cat "/proc/$rpid/wchan" 2>&1 || printf '?')
        rstdin=$(readlink "/proc/$rpid/fd/0" 2>&1 || printf '?')
    else
        rtty=""; rstat=""; retime=""; rwchan=""; rstdin=""
    fi

    rewritten="unknown"
    if [ -f "$envf" ] && [ -f "$bak" ]; then
        if cmp -s "$envf" "$bak"; then rewritten="no"; else rewritten="yes"; fi
    fi
    env_mode=$(stat -c '%a' "$envf" 2>&1 || printf '?')
    env_size=$(stat -c '%s' "$envf" 2>&1 || printf '?')

    checkpoint=$(checkpoint_state "$jobs")

    smoke_state="none"
    if [ -n "$smoke_log" ] && [ -f "$smoke_log" ]; then
        smoke_state=$(tail -n 1 "$smoke_log" 2>&1 | awk '{sub(/^[[:space:]]*smoke:[[:space:]]*/,""); print}')
    fi

    rotated=$(q "$db" "SELECT p.session_id || '|' || datetime(p.time_created/1000,'unixepoch','localtime') FROM part p WHERE json_extract(p.data,'\$.type')='text' AND json_extract(p.data,'\$.text')='ROTATED' ORDER BY p.time_created DESC LIMIT 1;")
    proof="none"
    if [ -n "$rotated" ]; then
        proof=$(printf '%s' "$rotated" | awk -F'|' '{printf "%s @ %s", $1, $2}')
    fi

    web_status="skip"; web_restarts="skip"; web_started="skip"; web_procs="skip"
    if have docker; then
        web_status=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>&1 || printf 'unknown')
        web_restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}' 2>&1 || printf '?')
        web_started=$(docker inspect "$CONTAINER" --format '{{.State.StartedAt}}' 2>&1 || printf '?')
        web_procs=$(docker top "$CONTAINER" -eo pid,args 2>&1 | awk '
            /opencode web/ { w=1 }
            /dashboard\.mjs/ { d=1 }
            END {
                if (w && d) printf "opencode-web,dashboard.mjs";
                else if (w) printf "opencode-web";
                else if (d) printf "dashboard.mjs";
                else printf "?";
            }')
    fi

    p4096="skip"; p5099="skip"; busy_sessions="skip"
    if [ "$NET" -eq 1 ] && have curl; then
        p4096=$(probe_https "$HOST" 4096 "/")
        p5099=$(probe_https "$HOST" 5099 "/api/health")
        busy_sessions=$(probe_busy "$HOST")
    fi

    timers=""
    if have systemctl; then
        for u in opencode-sentinel.service opencode-proactive.service opencode-progress-review.service opencode-fts-refresh.service; do
            timer_line=$(systemctl --user show "$u" -p ActiveState -p Result -p ExecMainStatus --value 2>&1 | paste -sd'|' -)
            timers="$timers$u=$timer_line; "
        done
    else
        timers="systemctl unavailable"
    fi

    sessions=$(q "$db" "SELECT COUNT(*) FROM session;")
    parts=$(q "$db" "SELECT COUNT(*) FROM part;")
    tools=$(q "$db" "SELECT COUNT(*) FROM part WHERE json_extract(data,'\$.type')='tool';")
    states=$(q "$db" "SELECT COALESCE(json_extract(data,'\$.state.status'),'?'), COUNT(*) FROM part WHERE json_extract(data,'\$.type')='tool' GROUP BY 1 ORDER BY 2 DESC;" | awk -F'|' '{printf "%s%s=%s", (n++?" ":""), $1, $2}')
    stale=$(q "$db" "SELECT COUNT(*) FROM part WHERE json_extract(data,'\$.type')='tool' AND json_extract(data,'\$.state.status') IN ('running','pending') AND time_created < (strftime('%s','now','-120 seconds')*1000);")
    pending=$(q "$db" "SELECT COUNT(*) FROM part WHERE json_extract(data,'\$.type')='tool' AND json_extract(data,'\$.state.status')='pending';")
    stale_list=$(q "$db" "SELECT p.session_id, COALESCE(json_extract(p.data,'\$.tool'),'?'), (strftime('%s','now') - p.time_created/1000), substr(replace(COALESCE(json_extract(p.data,'\$.state.input.command'),''),char(10),' '),1,70) FROM part p WHERE json_extract(p.data,'\$.type')='tool' AND json_extract(p.data,'\$.state.status') IN ('running','pending') AND p.time_created < (strftime('%s','now','-120 seconds')*1000) ORDER BY p.time_created DESC LIMIT 6;")
    stale_top=$(printf '%s\n' "$stale_list" | awk 'NF{printf "%s%s", (n++?"; ":""), $0}')
    [ -n "$stale_top" ] || stale_top="none"
    latest=$(q "$db" "SELECT id || '|' || substr(COALESCE(title,'(none)'),1,60) || '|' || datetime(time_created/1000,'unixepoch','localtime') FROM session ORDER BY time_created DESC LIMIT 1;")
    latest_id=$(printf '%s' "$latest" | awk -F'|' '{print $1}')
    latest_title=$(printf '%s' "$latest" | awk -F'|' '{print $2}')
    latest_created=$(printf '%s' "$latest" | awk -F'|' '{print $3}')
    # Liveness is NOT the main file's mtime (SQLite WAL) and NOT the newest
    # CREATED session (a long-running session stays active). Report both
    # explicit signals: the last part's time, the WAL, and the session with
    # the newest time_updated.
    active=$(q "$db" "SELECT id || '|' || substr(COALESCE(title,'(none)'),1,60) || '|' || datetime(time_updated/1000,'unixepoch','localtime') FROM session ORDER BY time_updated DESC LIMIT 1;")
    active_id=$(printf '%s' "$active" | awk -F'|' '{print $1}')
    active_title=$(printf '%s' "$active" | awk -F'|' '{print $2}')
    active_updated=$(printf '%s' "$active" | awk -F'|' '{print $3}')
    lastpart=$(q "$db" "SELECT COALESCE(datetime(MAX(time_created)/1000,'unixepoch','localtime'),'?') FROM part;")
    walbytes=$(stat -Lc '%s' "$db-wal" 2>&1 || printf '0')
    walmtime=$(stat -Lc '%y' "$db-wal" 2>&1 | cut -d. -f1)
    dbbytes=$(stat -Lc '%s' "$db" 2>&1 || printf '?')
    dbmtime=$(stat -Lc '%y' "$db" 2>&1 | cut -d. -f1)

    if [ "$JSON" -eq 1 ]; then
        json_out \
            ts "$ts" repo "$REPO" \
            rotate_pids "$(printf '%s\n' "$rotate_ps" | awk 'NF{printf "%s%s", (n++?",":""), $1}')" \
            rotate_tty "$rtty" rotate_state "$rstat" rotate_elapsed "$retime" \
            rotate_wchan "$rwchan" rotate_stdin "$rstdin" \
            checkpoint "$checkpoint" rewrite_applied "$rewritten" \
            env_mode "$env_mode" env_size "$env_size" \
            smoke_log "$smoke_log" smoke_state "$smoke_state" \
            rotated_proof "$proof" \
            web_status "$web_status" web_restarts "$web_restarts" web_started "$web_started" web_procs "$web_procs" \
            p4096 "$p4096" p5099 "$p5099" busy_sessions "$busy_sessions" \
            timers "$timers" \
            db "$db" db_bytes "$dbbytes" db_mtime "$dbmtime" \
            db_wal_bytes "$walbytes" db_wal_mtime "$walmtime" last_part "$lastpart" \
            active_session "$active_id" active_title "$active_title" active_updated "$active_updated" \
            sessions "$sessions" parts "$parts" tools "$tools" db_states "$states" \
            db_stale_running "$stale" db_pending "$pending" \
            db_stale_top "$stale_top" \
            latest_session "$latest_id" latest_title "$latest_title" latest_created "$latest_created"
        return 0
    fi

    printf '=== rotation-progress (read-only) ===\n'
    printf 'ts:   %s\n' "$ts"
    printf 'repo: %s\n' "$REPO"
    printf '%s\n' "$sep"
    printf 'open terminal / rotation\n'
    if [ -z "$rpid" ]; then
        printf '  process: none (rotation finished or was aborted)\n'
    else
        printf '  pids:    %s\n' "$(printf '%s\n' "$rotate_ps" | awk 'NF{printf "%s%s", (n++?",":""), $1}')"
        printf '  tty:     %s  state=%s  elapsed=%s  wchan=%s\n' "${rtty:-?}" "${rstat:-?}" "${retime:-?}" "${rwchan:-?}"
        printf '  stdin:   %s  <- the prompt is blocked here\n' "${rstdin:-?}"
    fi
    printf '  steps:   %s\n' "$checkpoint"
    printf '  env:     rewritten=%s mode=%s size=%s\n' "$rewritten" "$env_mode" "$env_size"
    if [ -n "$rpid" ] && [ "$rewritten" = "no" ]; then
        printf '  next:    type "write" in %s to rewrite + recreate; anything else aborts\n' "${rtty:-the tty}"
    elif [ -n "$rpid" ]; then
        printf '  next:    rewrite already applied; recreate/verify is in progress\n'
    fi
    printf '  smoke:   %s\n' "$smoke_state"
    if [ -n "$smoke_log" ]; then
        printf '  log:     %s\n' "$smoke_log"
    fi
    printf '  proof:   %s\n' "$proof"
    printf '%s\n' "$sep"
    printf 'background workers (:4096 store)\n'
    printf '  container: status=%s restarts=%s started=%s\n' "$web_status" "$web_restarts" "$web_started"
    printf '  procs:     %s\n' "$web_procs"
    printf '  https :%s: p4096=%s p5099=%s busy_sessions=%s\n' "$HOST" "$p4096" "$p5099" "$busy_sessions"
    printf '  timers:    %s\n' "$timers"
    printf '%s\n' "$sep"
    printf 'chat-log db\n'
    printf '  db:       %s bytes=%s main_mtime=%s wal_bytes=%s wal_mtime=%s\n' "$db" "$dbbytes" "$dbmtime" "$walbytes" "$walmtime"
    printf '  last part: %s\n' "$lastpart"
    printf '  counts:   sessions=%s parts=%s tools=%s\n' "$sessions" "$parts" "$tools"
    printf '  tools:    %s\n' "$states"
    printf '  stale:    running/pending>120s=%s pending=%s\n' "$stale" "$pending"
    if [ -n "$stale_list" ]; then
        printf '%s\n' "$stale_list" | while IFS='|' read -r sid tool age cmd; do
            [ -n "$sid" ] || continue
            printf '    %s %s age=%s %s\n' "${sid:0:28}" "$tool" "$(fmt_age "$age")" "$cmd"
        done
    fi
    printf '  active:   %s "%s" @ %s (time_updated)\n' "$active_id" "$active_title" "$active_updated"
    printf '  latest created: %s "%s" @ %s\n' "$latest_id" "$latest_title" "$latest_created"
    return 0
}

probe_https() {
    local host="$1" port="$2" path="$3" pw code
    pw=$(env_password)
    if [ -n "$pw" ]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 \
            -K <(printf 'user = "opencode:%s"\n' "$pw") \
            "https://$host:$port$path" 2>&1 || true)
    else
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 \
            "https://$host:$port$path" 2>&1 || true)
    fi
    printf '%s' "${code:-000}"
}

probe_busy() {
    local host="$1" pw body
    pw=$(env_password)
    if [ -n "$pw" ]; then
        body=$(curl -sk --max-time 6 -K <(printf 'user = "opencode:%s"\n' "$pw") \
            "https://$host:4096/session/status" 2>&1 || true)
    else
        body=$(curl -sk --max-time 6 "https://$host:4096/session/status" 2>&1 || true)
    fi
    printf '%s' "$body" | python3 -c '
import json
import sys
try:
    d = json.load(sys.stdin)
    print(sum(1 for v in d.values() if isinstance(v, dict) and v.get("type") == "busy"))
except Exception:
    print("?")
' 2>&1
}

env_password() {
    if [ ! -f "$ENVF" ]; then
        return
    fi
    awk -F= '/^OPENCODE_SERVER_PASSWORD=/{sub(/^[^=]*=/,""); print; exit}' "$ENVF"
}

json_out() {
    python3 - "$@" <<'PY'
import json
import sys

kv = sys.argv[1:]
out = {}
for i in range(0, len(kv) - 1, 2):
    out[kv[i]] = kv[i + 1]
print(json.dumps(out, indent=2, sort_keys=True))
PY
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    if [ -z "$REPO" ]; then
        REPO=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n' >&2
        return 2
    fi

    DB="$REPO/data/opencode/opencode.db"
    ENVF="$REPO/.env.local"
    HOST="10.100.0.24"
    CONTAINER="opencode-deepseek-web"
    WATCH=0
    JSON=0
    NET=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --watch|--loop) WATCH="${2:-0}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --no-net) NET=0; shift ;;
            --host) HOST="${2:-}"; shift 2 ;;
            --db) DB="${2:-}"; shift 2 ;;
            --env) ENVF="${2:-}"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1" >&2; return 2 ;;
        esac
    done

    case "$WATCH" in ''|*[!0-9]*) WATCH=0 ;; esac
    if [ "$WATCH" -gt 0 ]; then
        while :; do
            run_once
            sleep "$WATCH"
        done
    fi
    run_once
    return 0
}

main "$@"
