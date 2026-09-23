#!/usr/bin/env bash
#
# cost.sh — DeepSeek cost accounting for this repository's opencode usage.
#
# Two sections:
#   T1  local accounting — totals from the opencode SQLite database:
#       sessions, USD cost, input/output/reasoning/cache tokens.
#   T2  provider balance — DeepSeek GET /user/balance via curl.
#
# Reads DEEPSEEK_API_KEY from .env.local (mode 0600). The key is never
# printed. Works on the host and inside the container (the database is
# mounted at data/opencode/opencode.db from either side).
#
# Usage:
#   ./scripts/cost.sh
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
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

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n=== %s ===\n' "$1"; }

load_key() {
    ENV_FILE="$REPO/.env.local"
    if [ ! -f "$ENV_FILE" ]; then
        printf 'WARN: %s missing; provider balance skipped\n' "$ENV_FILE"
        return 1
    fi
    DEEPSEEK_API_KEY=""
    while IFS='=' read -r k v; do
        [ "$k" = "DEEPSEEK_API_KEY" ] && DEEPSEEK_API_KEY="$v"
    done < "$ENV_FILE"
    export DEEPSEEK_API_KEY
    [ -n "$DEEPSEEK_API_KEY" ]
}

t1_accounting() {
    section "T1  local accounting (opencode.db)"
    local db="$REPO/data/opencode/opencode.db"
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi

    if have node; then
        node --no-warnings --experimental-sqlite -e '
            const { DatabaseSync } = require("node:sqlite");
            const db = new DatabaseSync(process.argv[1], { readOnly: true });
            const s = db.prepare("SELECT COUNT(*) n, COALESCE(SUM(cost),0) c, COALESCE(SUM(tokens_input),0) i, COALESCE(SUM(tokens_output),0) o, COALESCE(SUM(tokens_reasoning),0) r, COALESCE(SUM(tokens_cache_read),0) cr, COALESCE(SUM(tokens_cache_write),0) cw FROM session").get();
            const f = (x) => Number(x || 0).toFixed(6);
            console.log("sessions          = " + s.n);
            console.log("total_cost_usd    = " + f(s.c));
            console.log("tokens_input      = " + s.i);
            console.log("tokens_output     = " + s.o);
            console.log("tokens_reasoning  = " + s.r);
            console.log("tokens_cache_read = " + s.cr);
            console.log("tokens_cache_write= " + s.cw);
        ' "$db"
    elif have sqlite3; then
        sqlite3 "$db" "SELECT 'sessions='||COUNT(*), 'total_cost_usd='||COALESCE(SUM(cost),0), 'in='||COALESCE(SUM(tokens_input),0), 'out='||COALESCE(SUM(tokens_output),0), 'reasoning='||COALESCE(SUM(tokens_reasoning),0) FROM session;"
    else
        printf 'FAIL: need node or sqlite3 to read the database\n'
        return 1
    fi
    return 0
}

t2_balance() {
    section "T2  provider balance (DeepSeek)"
    if ! load_key; then
        return 1
    fi

    local tmp http body
    tmp=$(mktemp)
    http=$(curl -s -o "$tmp" -w '%{http_code}' -m 20 \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        https://api.deepseek.com/user/balance)
    body=$(cat "$tmp")
    rm -f "$tmp"

    printf 'HTTP %s\n' "$http"
    printf '%s\n' "$body"
    return 0
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    printf '=== cost.sh ===\n'
    printf 'Repo: %s\n' "$REPO"

    t1_accounting
    t2_balance
    return 0
}

main "$@"
