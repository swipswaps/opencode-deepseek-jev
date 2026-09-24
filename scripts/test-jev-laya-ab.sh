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

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi

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
        [ -f "$work/jev.json" ] && python3 -m json.tool "$work/jev.json" 2>&1 | head -40
    fi

    # ---- Laya (self-hosted) ----------------------------------------------
    section "Laya (self-hosted)"
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
    if [ -f "$work/laya.json" ] && grep -qE '^\{' "$work/laya.json"; then
        python3 -m json.tool "$work/laya.json" 2>&1 | head -40
    else
        printf '  Laya not reachable. Start it with:\n'
        printf '    pip install "laya[serve]"\n'
        printf '    laya-serve    # serves POST /v1/systemone on http://127.0.0.1:8000\n'
    fi

    # ---- diff -------------------------------------------------------------
    section "diff"
    if [ -f "$work/jev.json" ] && [ -f "$work/laya.json" ] && grep -qE '^\{' "$work/laya.json"; then
        if diff -u "$work/jev.json" "$work/laya.json" > "$work/diff.txt"; then
            printf '  IDENTICAL responses\n'
        else
            printf '  responses differ (artifacts: %s):\n' "$work/diff.txt"
            diff -u "$work/jev.json" "$work/laya.json" | head -40
        fi
    else
        printf '  SKIP: Laya response unavailable\n'
    fi

    printf '\nartifacts: %s\n' "$work"
    return 0
}

main "$@"
