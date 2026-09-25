#!/usr/bin/env bash
#
# logs.sh — aggregate actionable telemetry, local and read-only.
#
# Per-check `ms=` says a step is slow; it does not say WHY. This pulls the
# real evidence from every layer:
#
#   guard   data/observability/guard.log — every blacklist block/fix/warn the
#           agent's own "Thinking" triggered (JSONL)
#   error   opencode.db part rows with state.status=error — the tool failure
#           text / stack trace, with the session and command
#   event   opencode.db event table — the event bus (message.part.updated, …)
#   app     ~/.local/share/opencode/log/opencode.log — the application log
#   system  docker logs of the opencode-web container (host only; no docker
#           inside the container)
#   packet  the exact tcpdump command to capture provider traffic (not run)
#
# Usage:
#   ./scripts/logs.sh                      # guard + error (the signal)
#   ./scripts/logs.sh --source all
#   ./scripts/logs.sh --source error --since 30 --tail 40
#   ./scripts/logs.sh --source app --grep ERROR
#   ./scripts/logs.sh --source packet
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

SOURCE="signal"
SINCE=""
TAIL=40
GREP=""

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

usage() {
    printf 'usage: %s [--source guard|error|event|app|system|packet|all|signal] [--since MIN] [--tail N] [--grep RE]\n' "$0"
}

section() { printf '\n=== %s ===\n' "$1"; }

# ---- sources -------------------------------------------------------------

show_guard() {
    local f="$REPO/data/observability/guard.log"
    section "guard actions ($f)"
    if [ ! -f "$f" ]; then
        printf 'no guard actions recorded yet (the plugin writes here once opencode-web restarts)\n'
        return 0
    fi
    tail -n "$TAIL" "$f"
}

show_error() {
    local db="$REPO/data/opencode/opencode.db"
    section "tool errors (opencode.db part.status=error)"
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi
    if ! have sqlite3; then
        printf 'FAIL: sqlite3 required\n'
        return 1
    fi
    local where=""
    if [ -n "$SINCE" ]; then
        local cutoff
        cutoff=$(date -u -d "-${SINCE} minutes" +%s%3N)
        where=" AND p.time_created > $cutoff"
    fi
    sqlite3 -separator ' | ' "$db" \
        "SELECT s.title, json_extract(p.data,'\$.tool'), json_extract(p.data,'\$.state.error') \
         FROM part p JOIN session s ON s.id=p.session_id \
         WHERE json_extract(p.data,'\$.type')='tool' AND json_extract(p.data,'\$.state.status')='error'$where \
         ORDER BY p.time_created DESC LIMIT $TAIL;"
}

show_event() {
    local db="$REPO/data/opencode/opencode.db"
    section "recent events (opencode.db event)"
    if [ ! -f "$db" ] || ! have sqlite3; then
        printf 'FAIL: need sqlite3 + database\n'
        return 1
    fi
    sqlite3 -separator ' | ' "$db" \
        "SELECT type, aggregate_id, substr(data,1,120) FROM event ORDER BY rowid DESC LIMIT $TAIL;"
}

show_app() {
    local f="$HOME/.local/share/opencode/log/opencode.log"
    section "application log ($f)"
    if [ ! -f "$f" ]; then
        section_placeholder_missing "$f"
        return 0
    fi
    if [ -n "$GREP" ]; then
        grep -E "$GREP" "$f" | tail -n "$TAIL"
    else
        tail -n "$TAIL" "$f"
    fi
}

section_placeholder_missing() { printf 'no log at %s\n' "$1"; }

show_system() {
    section "system / container logs"
    if have docker; then
        docker logs --tail "$TAIL" opencode-deepseek-web
    else
        printf 'no docker here (this is the agent container). On the host: docker logs --tail %s opencode-deepseek-web\n' "$TAIL"
    fi
}

show_packet() {
    section "packet capture (manual)"
    printf 'Provider traffic is HTTPS; capture names only, never bodies:\n\n'
    printf '  sudo tcpdump -i any -nn -s0 -c 200 "tcp port 443 and host api.deepseek.com"\n'
    printf '  sudo tcpdump -i any -nn -s0 -c 200 "tcp port 443 and host console.typesafe.ai"\n\n'
    printf 'For DNS + TLS SNI only: sudo tcpdump -i any -nn "port 53 or (tcp[tcpflags] & tcp-syn != 0)"\n'
    printf 'Prefer a packet socket via ss/curl timing if full capture is overkill:\n'
    printf '  curl -w "%%{time_namelookup} %%{time_connect} %%{time_appconnect} %%{time_total}\\n" -o /dev/null -s https://api.deepseek.com/user/balance\n'
}

show_signal() {
    show_guard
    show_error
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) SOURCE="${2:-}"; shift 2 ;;
            --since)  SINCE="${2:-}"; shift 2 ;;
            --tail)   TAIL="${2:-40}"; shift 2 ;;
            --grep)   GREP="${2:-}"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) usage; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    printf '=== logs.sh (source=%s)\n' "$SOURCE"
    case "$SOURCE" in
        guard)  show_guard ;;
        error)  show_error ;;
        event)  show_event ;;
        app)    show_app ;;
        system) show_system ;;
        packet) show_packet ;;
        signal) show_signal ;;
        all)    show_guard; show_error; show_event; show_app; show_system ;;
        *) usage; return 2 ;;
    esac
    return 0
}

main "$@"
