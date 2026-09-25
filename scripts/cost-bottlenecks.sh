#!/usr/bin/env bash
#
# cost-bottlenecks.sh — rank where API cost actually goes.
#
# Reads the opencode database read-only and reports the cost drivers:
#   totals + effective $/1k-input, top sessions by cost, top by input
#   tokens (context is the cost driver), worst effective $/1k-input, the
#   fixed overhead of tiny sessions, and a per-model breakdown.
#
# Usage:
#   ./scripts/cost-bottlenecks.sh [--top N]
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

DB=""
TOP=10

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

q() { sqlite3 -header -column "$DB" "$1"; }

usage() { printf 'usage: %s [--top N]\n' "$0"; }

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    DB="$REPO/data/opencode/opencode.db"
    if [ ! -f "$DB" ]; then
        printf 'FAIL: no database at %s\n' "$DB"
        return 1
    fi
    if ! have sqlite3; then
        printf 'FAIL: sqlite3 required\n'
        return 1
    fi

    case "${1:-}" in
        "") ;;
        --top)
            case "${2:-}" in
                ''|*[!0-9]*) usage; return 2 ;;
                *) TOP="$2" ;;
            esac
            ;;
        *) usage; return 2 ;;
    esac

    printf '=== cost-bottlenecks.sh ===\n'
    printf 'db:  %s\n' "$DB"
    printf 'top: %s\n' "$TOP"

    section "totals"
    q "SELECT COUNT(*) sessions,
              printf('\$%.4f', COALESCE(SUM(cost),0)) cost,
              COALESCE(SUM(tokens_input),0) in_tok,
              COALESCE(SUM(tokens_output),0) out_tok,
              COALESCE(SUM(tokens_reasoning),0) reasoning,
              printf('\$%.4f', COALESCE(SUM(cost),0)*1000.0/MAX(1,SUM(tokens_input))) per_1k_in
         FROM session;"

    section "top by cost"
    q "SELECT substr(title,1,44) title,
              printf('\$%.4f', cost) cost,
              tokens_input in_tok,
              printf('\$%.4f', cost*1000.0/MAX(1,tokens_input)) per_1k_in
         FROM session ORDER BY cost DESC LIMIT $TOP;"

    section "top by input tokens (context = the cost driver)"
    q "SELECT substr(title,1,44) title,
              tokens_input in_tok,
              printf('\$%.4f', cost) cost
         FROM session ORDER BY tokens_input DESC LIMIT $TOP;"

    section "worst effective \$/1k input (>=1000 in)"
    q "SELECT substr(title,1,44) title,
              tokens_input in_tok,
              printf('\$%.4f', cost) cost,
              printf('\$%.4f', cost*1000.0/MAX(1,tokens_input)) per_1k_in
         FROM session WHERE tokens_input >= 1000
         ORDER BY cost*1.0/MAX(1,tokens_input) DESC LIMIT $TOP;"

    section "tiny-session overhead (cost < \$0.001)"
    q "SELECT COUNT(*) tiny_sessions,
              printf('\$%.4f', COALESCE(SUM(cost),0)) tiny_cost,
              COALESCE(SUM(tokens_input),0) tiny_in_tok
         FROM session WHERE cost < 0.001;"

    section "per model (cost share)"
    q "SELECT COALESCE(json_extract(model,'\$.id'),'(none)') model,
              COUNT(*) n,
              printf('\$%.4f', COALESCE(SUM(cost),0)) cost,
              printf('%.1f%%', 100.0*SUM(cost)/MAX(1,(SELECT SUM(cost) FROM session))) share
         FROM session GROUP BY COALESCE(json_extract(model,'\$.id'),'(none)') ORDER BY SUM(cost) DESC;"

    section "model mix check (default = deepseek-flash)"
    q "SELECT printf('\$%.4f', COALESCE(SUM(cost),0)) nonflash_cost,
              printf('%.1f%%', 100.0*SUM(cost)/MAX(1,(SELECT SUM(cost) FROM session))) nonflash_share
         FROM session WHERE COALESCE(json_extract(model,'\$.id'),'') <> 'deepseek-flash';"

    printf '\nread: per_1k_in is the effective price of context. A high\n'
    printf 'per_1k_in with high in_tok is the bottleneck to cut first\n'
    printf '(trim context, summarize, or cache). tiny_sessions are the\n'
    printf 'fixed per-call overhead.\n'
    printf 'If nonflash_share is high, switch the model back to\n'
    printf 'deepseek-flash (the opencode.json default): a non-flash\n'
    printf 'reasoning model re-prices the whole context every turn.\n'
    return 0
}

main "$@"
