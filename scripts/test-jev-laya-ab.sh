#!/usr/bin/env bash
#
# test-jev-laya-ab.sh — A/B the same typed-decision payload through TypeSafe
# Jev and a self-hosted Laya server, then diff the answers and report latency.
#
# Laya ships `laya-serve`, a Jev-API-compatible server (POST /v1/systemone),
# so the same payload is valid against both. If Laya is not reachable the
# script prints the exact commands to start it and skips the diff.
#
# Usage:
#   ./scripts/test-jev-laya-ab.sh
#   LAYA_URL=http://host:8000/v1/systemone ./scripts/test-jev-laya-ab.sh
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

JEV_URL="https://api.typesafe.ai/v1/systemone"
LAYA_URL="${LAYA_URL:-http://127.0.0.1:8000/v1/systemone}"
OBS_DB=""

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

section() { printf '\n=== %s ===\n' "$1"; }

persist_ab() {
    local ts="$1" model="$2" jcode="$3" jlat="$4" jok="$5" lcode="$6" llat="$7" lok="$8" same="$9" jf="${10}" lf="${11}"
    mkdir -p "$(dirname "$OBS_DB")"
    python3 - "$OBS_DB" "$ts" "$model" "$jcode" "$jlat" "$jok" "$lcode" "$llat" "$lok" "$same" "$jf" "$lf" <<'PY'
import sqlite3, sys, json
(db, ts, model, jcode, jlat, jok, lcode, llat, lok, same, jf, lf) = sys.argv[1:13]

def scores(path):
    try:
        with open(path) as f:
            d = json.load(f)
        a = d.get("answers", {}) or {}
        c = a.get("correctness", {}) or {}
        s = a.get("safe_to_merge", {}) or {}
        return (c.get("score"), c.get("confidence"), s.get("noul"), d.get("model"))
    except Exception:
        return (None, None, None, None)

jc, jconf, jsafe, jmodel = scores(jf)
lc, lconf, lsafe, lmodel = scores(lf)

con = sqlite3.connect(db)
con.execute(
    "CREATE TABLE IF NOT EXISTS ab_run("
    "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, model TEXT, "
    "jev_status TEXT, jev_latency REAL, jev_ok INTEGER, "
    "laya_status TEXT, laya_latency REAL, laya_ok INTEGER, same INTEGER, "
    "jev_correctness REAL, jev_safe REAL, jev_confidence REAL, "
    "laya_correctness REAL, laya_safe REAL, laya_confidence REAL, "
    "jev_model TEXT, laya_model TEXT)"
)
for col in (
    "jev_correctness REAL", "jev_safe REAL", "jev_confidence REAL",
    "laya_correctness REAL", "laya_safe REAL", "laya_confidence REAL",
    "jev_model TEXT", "laya_model TEXT",
):
    try:
        con.execute("ALTER TABLE ab_run ADD COLUMN " + col)
    except sqlite3.OperationalError:
        pass
con.execute(
    "INSERT INTO ab_run(ts,model,jev_status,jev_latency,jev_ok,laya_status,laya_latency,laya_ok,same,"
    "jev_correctness,jev_safe,jev_confidence,laya_correctness,laya_safe,laya_confidence,jev_model,laya_model) "
    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (ts, model, jcode, float(jlat or 0), int(jok or 0), lcode, float(llat or 0), int(lok or 0),
     None if same == "" else int(same), jc, jsafe, jconf, lc, lsafe, lconf, jmodel, lmodel),
)
con.commit()
con.close()
PY
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi

    OBS_DB="$REPO/data/observability/observability.db"
    local ENV="$REPO/.env.local" jk="" lk=""
    if [ -f "$ENV" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                JEV_API_KEY) jk="$v" ;;
                LAYA_API_KEY) lk="$v" ;;
            esac
        done < "$ENV"
    fi
    [ -n "$jk" ] || jk="${JEV_API_KEY:-}"
    [ -n "$lk" ] || lk="${LAYA_API_KEY:-}"

    local ts work
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    work="/tmp/jev-laya-ab-$ts"
    mkdir -p "$work"

    cat > "$work/payload.json" <<'PAYLOAD_EOF'
{"state":{"document":"def add(a, b):\n    return a + b\n"},"model":"jev-latest","questions":{"correctness":{"type":"score","instructions":"Is this change correct?","criteria":["incorrect","partially correct","correct"]},"safe_to_merge":{"type":"noul","instructions":"Is this change safe to merge?"}}}
PAYLOAD_EOF

    printf '=== test-jev-laya-ab.sh ===\n'
    printf 'payload: %s\n' "$work/payload.json"
    printf 'jev:     %s\n' "$JEV_URL"
    printf 'laya:    %s\n' "$LAYA_URL"

    # ---- TypeSafe Jev -----------------------------------------------------
    section "Jev (TypeSafe)"
    local jcode="000" jlat="0" jok=0
    if [ -z "$jk" ]; then
        printf 'SKIP: JEV_API_KEY not set\n'
    else
        local jres
        jres=$(curl -s -o "$work/jev.json" -w '%{http_code} %{time_total}' -m 60 \
            -X POST "$JEV_URL" \
            -H "Authorization: Bearer $jk" \
            -H "Content-Type: application/json" \
            --data-binary @"$work/payload.json")
        printf '  %s\n' "$jres"
        case "$jres" in
            *" "*) jcode="${jres%% *}"; jlat="${jres##* }" ;;
            *)     jcode="$jres" ;;
        esac
        case "$jcode" in 2*) jok=1 ;; esac
        [ -f "$work/jev.json" ] && python3 -m json.tool "$work/jev.json" 2>&1 | head -40
    fi

    # ---- Laya (self-hosted) ----------------------------------------------
    section "Laya (self-hosted)"
    local lcode="000" llat="0" lok=0
    local lres
    if [ -n "$lk" ]; then
        lres=$(curl -s -o "$work/laya.json" -w '%{http_code} %{time_total}' -m 60 \
            -X POST "$LAYA_URL" \
            -H "Authorization: Bearer $lk" \
            -H "Content-Type: application/json" \
            --data-binary @"$work/payload.json")
    else
        lres=$(curl -s -o "$work/laya.json" -w '%{http_code} %{time_total}' -m 60 \
            -X POST "$LAYA_URL" \
            -H "Content-Type: application/json" \
            --data-binary @"$work/payload.json")
    fi
    printf '  %s\n' "$lres"
    case "$lres" in
        *" "*) lcode="${lres%% *}"; llat="${lres##* }" ;;
        *)     lcode="$lres" ;;
    esac
    if [ -f "$work/laya.json" ] && grep -qE '^\{' "$work/laya.json"; then
        case "$lcode" in 2*) lok=1 ;; esac
        python3 -m json.tool "$work/laya.json" 2>&1 | head -40
    else
        printf '  Laya not reachable. Start it with:\n'
        printf '    pip install "laya[serve]"\n'
        printf '    laya-serve    # serves POST /v1/systemone on http://127.0.0.1:8000\n'
    fi

    # ---- diff -------------------------------------------------------------
    section "diff"
    local same=""
    if [ -f "$work/jev.json" ] && [ -f "$work/laya.json" ] && grep -qE '^\{' "$work/laya.json"; then
        if diff -u "$work/jev.json" "$work/laya.json" > "$work/diff.txt"; then
            printf '  IDENTICAL responses\n'
            same="1"
        else
            printf '  responses differ (artifacts: %s):\n' "$work/diff.txt"
            same="0"
            diff -u "$work/jev.json" "$work/laya.json" | head -40
        fi
    else
        printf '  SKIP: Laya response unavailable\n'
    fi

    persist_ab "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "jev-latest" "$jcode" "$jlat" "$jok" "$lcode" "$llat" "$lok" "$same" "$work/jev.json" "$work/laya.json"
    printf '\npersisted: %s\n' "$OBS_DB"
    printf 'artifacts: %s\n' "$work"
    return 0
}

main "$@"
