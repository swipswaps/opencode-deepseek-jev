#!/usr/bin/env bash
#
# grafana-up.sh — stand up the Grafana + SQLite ops view (the non-bespoke
# telemetry surface, RULE #67). Host-only: needs docker.
#
# pi-durable: "any number of clients can attach to any conversation" -- Grafana
# is one more client rendering the SAME committed state (the two SQLite stores),
# mounted read-only, so it can never disagree with the source of truth.
#
#   ./scripts/grafana-up.sh            # up -d, then wait until healthy
#   ./scripts/grafana-up.sh --down
#   ./scripts/grafana-up.sh --logs
#   ./scripts/grafana-up.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

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

self_test() {
    local REPO fail=0 C DS PR DB
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    C="$REPO/docker/docker-compose.observability.yml"
    DS="$REPO/docker/grafana/provisioning/datasources/sqlite.yaml"
    PR="$REPO/docker/grafana/provisioning/dashboards/provider.yaml"
    DB="$REPO/docker/grafana/provisioning/dashboards/opencode.json"
    [ -f "$C" ] || { printf 'FAIL: missing compose\n'; fail=1; }
    grep -q 'grafana/grafana' "$C" || { printf 'FAIL: no grafana image\n'; fail=1; }
    grep -q 'GF_INSTALL_PLUGINS: frser-sqlite-datasource' "$C" || { printf 'FAIL: sqlite plugin not installed\n'; fail=1; }
    grep -q 'observability.db:.*:ro' "$C" || { printf 'FAIL: stores not mounted read-only\n'; fail=1; }
    [ -f "$DS" ] && grep -q 'frser-sqlite-datasource' "$DS" || { printf 'FAIL: datasource type\n'; fail=1; }
    [ -f "$PR" ] || { printf 'FAIL: missing dashboard provider\n'; fail=1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("title"), "title"' "$DB" \
        || { printf 'FAIL: dashboard JSON invalid\n'; fail=1; }
    if [ -f "$C" ] && have docker; then
        docker compose -f "$C" config > /dev/null 2>&1 || { printf 'FAIL: compose config invalid\n'; fail=1; }
    fi
    printf 'grafana-up: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local REPO C GF_PORT="${GF_PORT:-3000}" PORT_GIVEN=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    C="$REPO/docker/docker-compose.observability.yml"
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        --port) GF_PORT="${2:-3000}"; PORT_GIVEN=1; shift 2 ;;
        -h | --help) printf 'usage: %s [--port N|--down|--logs|--self-test]\n' "$0"; return 0 ;;
    esac
    have docker || { printf 'GATE FAIL: docker required (host-only)\n'; return 1; }
    case "${1:-}" in
        --down) docker compose -f "$C" down; return $? ;;
        --logs) docker compose -f "$C" logs --tail=40; return $? ;;
        "") : ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    # Never assume the port: discover a free one (deploy.sh does the same).
    if ! bash "$REPO/scripts/free-port.sh" --check "$GF_PORT" > /dev/null; then
        printf 'grafana-up: port %s busy -- holder:\n' "$GF_PORT"
        bash "$REPO/scripts/free-port.sh" --owner "$GF_PORT"
        if [ "$PORT_GIVEN" -eq 1 ]; then
            printf 'FAIL: --port %s is busy; free it or pass another\n' "$GF_PORT"; return 1
        fi
        local np
        np=$(bash "$REPO/scripts/free-port.sh" "$GF_PORT" 50)
        [ -n "$np" ] || { printf 'FAIL: no free port near %s\n' "$GF_PORT"; return 1; }
        printf 'grafana-up: using free port %s instead\n' "$np"
        GF_PORT="$np"
    fi
    export GF_PORT
    docker compose -f "$C" up -d --force-recreate || { printf 'FAIL: compose up\n'; return 1; }
    local pub
    pub=$(docker port opencode-grafana 2>&1 | head -1)
    printf 'grafana-up: container published -> %s (GF_PORT=%s)\n' "$pub" "$GF_PORT"
    local k=0 h=""
    while [ "$k" -lt 40 ]; do
        sleep 3
        h=$(curl -s --max-time 3 "http://127.0.0.1:$GF_PORT/api/health" || true)
        case "$h" in *'"database":"ok"'*) break ;; esac
        k=$((k + 1))
        [ "$k" -eq 10 ] && printf 'grafana-up: still starting (first boot installs the sqlite plugin; allow ~1-2 min)...\n'
    done
    case "$h" in
        *'"database":"ok"'*) printf 'grafana-up: healthy -> http://127.0.0.1:%s (dashboards provisioned)\n' "$GF_PORT"; return 0 ;;
        *) printf 'grafana-up: not healthy after 120s; run --logs\n'; return 1 ;;
    esac
}

main "$@"
