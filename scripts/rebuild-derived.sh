#!/usr/bin/env bash
#
# rebuild-derived.sh — rebuild every DERIVED artifact from the durable source.
#
# pi-durable: storage is the source of truth and every projection is rebuildable
# ("older messages always stay in storage"). This proves it by regenerating our
# projections from storage ALONE -- the alert brief from the ledger, and the
# latest-session digest from the opencode store. Nothing here reads a cached
# client; delete the outputs and re-run and they come back.
#
#   ./scripts/rebuild-derived.sh [--ledger DB] [--db OPENCODE_DB] [--out DIR]
#   ./scripts/rebuild-derived.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

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

latest_session() {
    python3 - "$1" << 'PYEOF'
import sqlite3, sys
try:
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    r = con.execute("SELECT id FROM session ORDER BY time_updated DESC LIMIT 1").fetchone()
    con.close()
    print(r[0] if r else "")
except sqlite3.Error:
    print("")
PYEOF
}

self_test() {
    local work fail=0
    work=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    python3 - "$work/o.db" << 'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, resource TEXT, detail TEXT, type TEXT, verdict TEXT)")
c.execute("INSERT INTO ledger(ts,resource,detail,type,verdict) VALUES('t','caddy access log','slow fetches x1, slowest 12.0s (GET /provider)','ADVISORY','FAIL')")
c.commit(); c.close()
PYEOF
    local rep="$work/triage.md"
    python3 "$(dirname "${BASH_SOURCE[0]}")/triage-alerts.py" --ledger "$work/o.db" --out "$rep" >/dev/null 2>&1
    [ -s "$rep" ] || { printf 'FAIL: triage projection not rebuilt\n'; fail=1; }
    grep -q 'ALERT TRIAGE' "$rep" || { printf 'FAIL: rebuilt report malformed\n'; fail=1; }
    grep -q 'session-digest.sh' "${BASH_SOURCE[0]}" || { printf 'FAIL: digest projection missing\n'; fail=1; }
    printf 'rebuild-derived: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local REPO OUT LED OPEN_DB DATE SID fail=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        -h | --help) printf 'usage: %s [--ledger DB] [--db OPENCODE_DB] [--out DIR] [--self-test]\n' "$0"; return 0 ;;
    esac
    OUT="$REPO/data/observability"; LED="$OUT/observability.db"; OPEN_DB="$REPO/data/opencode/opencode.db"
    while [ $# -gt 0 ]; do
        case "$1" in
            --ledger) LED="${2:-}"; shift 2 ;;
            --db) OPEN_DB="${2:-}"; shift 2 ;;
            --out) OUT="${2:-}"; shift 2 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    mkdir -p "$OUT/digests" || { printf 'FAIL: cannot create %s\n' "$OUT"; return 1; }
    DATE=$(date -u +%Y%m%d)
    printf 'rebuild-derived: storage=%s  store=%s  out=%s\n' "$LED" "$OPEN_DB" "$OUT"
    # projection 1: the alert brief <- the durable ledger
    if [ -f "$LED" ]; then
        python3 "$REPO/scripts/triage-alerts.py" --ledger "$LED" --out "$OUT/triage-$DATE.md" || fail=1
    else
        printf '  skip triage: no ledger at %s\n' "$LED"; fail=1
    fi
    # projection 2: latest-session digest <- the opencode store
    if [ -f "$OPEN_DB" ]; then
        SID=$(latest_session "$OPEN_DB")
        if [ -n "$SID" ]; then
            if bash "$REPO/scripts/session-digest.sh" "$SID" --db "$OPEN_DB" > "$OUT/digests/$SID.md"; then
                printf '  rebuilt digests/%s.md (%s bytes)\n' "$SID" "$(wc -c < "$OUT/digests/$SID.md")"
            else
                printf '  FAIL digest for %s\n' "$SID"; fail=1
            fi
        else
            printf '  skip digest: no sessions in store\n'
        fi
    else
        printf '  skip digest: no store at %s\n' "$OPEN_DB"; fail=1
    fi
    if [ "$fail" -eq 0 ]; then printf 'rebuild-derived: OK (all projections rebuilt from storage)\n'; fi
    return "$fail"
}

main "$@"
