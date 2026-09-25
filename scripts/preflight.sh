#!/usr/bin/env bash
#
# preflight.sh — fail-closed readiness + spend gate. Run it BEFORE any paid
# session; if it says STOP, do not spend until the cause is resolved.
#
# Best practice for "avoid API spend until a failing gate is resolved" is to
# gate on a CHEAP LOCAL check, not on a budget alert you see after the fact:
# fail closed, check the cheapest signal first, and never retry blind. This is
# that check. It is local except for one free balance GET.
#
# Critical (STOP, exit 1):
#   - repo/database missing
#   - .env.local missing any of DEEPSEEK_API_KEY / JEV_API_KEY / OPENCODE_SERVER_PASSWORD
#   - the last `harness.sh` run recorded a failed gate (data/observability/last-gate.json)
#   - no recorded gate run yet
#   - DeepSeek balance below MIN_BALANCE (default 1.00 USD)
#   - the configured model is not deepseek-flash (unless --allow-pro)
#   - the most recent session ran a non-flash model (unless --allow-pro)
# Warns (does not stop): guard off, no guard.log yet.
#
#   ./scripts/preflight.sh            # human output
#   ./scripts/preflight.sh --json     # machine output (for a wrapper/plugin)
#   ./scripts/preflight.sh --allow-pro
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

CRIT=0
WARN=0
JSON=0
ALLOW_PRO=0
MIN_BALANCE="${MIN_BALANCE:-1.00}"

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

crit() { CRIT=$((CRIT+1)); [ "$JSON" -eq 1 ] || printf '  [STOP] %s\n' "$1"; }
warn() { WARN=$((WARN+1)); [ "$JSON" -eq 1 ] || printf '  [warn] %s\n' "$1"; }
good() { [ "$JSON" -eq 1 ] || printf '  [ ok ] %s\n' "$1"; }

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --allow-pro) ALLOW_PRO=1; shift ;;
            -h|--help) printf 'usage: %s [--json] [--allow-pro]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--json] [--allow-pro]\n' "$0"; return 2 ;;
        esac
    done

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'STOP: cannot resolve repo root\n'
        return 2
    fi

    local db="$REPO/data/opencode/opencode.db"
    local envf="$REPO/.env.local"
    local marker="$REPO/data/observability/last-gate.json"

    [ "$JSON" -eq 1 ] || printf '=== preflight.sh ===\n'

    [ -f "$db" ] && good "database present" || crit "no database at $db"

    if [ -f "$envf" ]; then
        local k
        for k in DEEPSEEK_API_KEY JEV_API_KEY OPENCODE_SERVER_PASSWORD; do
            if grep -q "^$k=" "$envf"; then good "$k set (name only)"; else crit "$k missing from .env.local"; fi
        done
    else
        crit "no .env.local at $envf"
    fi

    if [ -f "$marker" ]; then
        local failed
        failed=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("failed",0))' "$marker" 2>&1)
        if [ "$failed" = "0" ]; then
            good "last gate run passed"
        else
            crit "last gate run recorded $failed failing gate(s) — resolve before spending"
        fi
    else
        crit "no recorded gate run — run ./scripts/harness.sh once"
    fi

    if [ -f "$envf" ] && have curl; then
        local key usd
        key=$(grep '^DEEPSEEK_API_KEY=' "$envf" | head -1)
        key=${key#DEEPSEEK_API_KEY=}
        if [ -n "$key" ]; then
            usd=$(curl -s -m 15 -H "Authorization: Bearer $key" https://api.deepseek.com/user/balance \
                | python3 -c 'import json,sys;
try:
    d=json.load(sys.stdin); i=[b for b in d.get("balance_infos",[]) if b.get("currency")=="USD"]; print(i[0]["total_balance"] if i else "?")
except Exception:
    print("?")' 2>&1)
            if [ "$usd" = "?" ]; then
                warn "could not read DeepSeek balance"
            else
                local low
                low=$(python3 -c 'import sys;print(1 if float(sys.argv[1]) < float(sys.argv[2]) else 0)' "$usd" "$MIN_BALANCE" 2>&1)
                if [ "$low" = "1" ]; then
                    crit "balance \$$usd < \$$MIN_BALANCE — top up before spending"
                else
                    good "balance \$$usd >= \$$MIN_BALANCE"
                fi
            fi
        fi
    fi

    if [ "$ALLOW_PRO" -eq 0 ]; then
        local cfgmodel
        cfgmodel=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("model",""))' "$REPO/opencode.json" 2>&1)
        case "$cfgmodel" in
            *flash*) good "deterministic for non-flash leak: opencode.json model=$cfgmodel" ;;
            *) crit "opencode.json model=$cfgmodel is not deepseek-flash (cost leak)" ;;
        esac
        if [ -f "$db" ]; then
            local lastmodel
            lastmodel=$(sqlite3 "$db" "SELECT COALESCE(json_extract(model,'\$.id'),'') FROM session ORDER BY time_created DESC LIMIT 1;" 2>&1)
            case "$lastmodel" in
                *flash*|"") [ -z "$lastmodel" ] && warn "no last-session model" || good "last session model=$lastmodel" ;;
                *) crit "last session ran model=$lastmodel (non-flash; 2.9x) — pin deepseek-flash" ;;
            esac
        fi
    else
        warn "--allow-pro: skipping model checks"
    fi

    if [ "${OPENCODE_BLACKLIST_GUARD:-block}" = "off" ]; then
        warn "blacklist guard is off"
    fi
    [ -f "$REPO/data/observability/guard.log" ] || warn "no guard.log yet (plugin loads on restart)"

    local ready=1
    [ "$CRIT" -gt 0 ] && ready=0

    if [ "$JSON" -eq 1 ]; then
        printf '{"ready":%d,"critical":%d,"warn":%d,"min_balance":"%s"}\n' "$ready" "$CRIT" "$WARN" "$MIN_BALANCE"
    else
        printf '\n'
        if [ "$ready" -eq 1 ]; then
            printf 'READY: %d warning(s). Safe to start a paid session.\n' "$WARN"
        else
            printf 'STOP: %d critical issue(s). Do NOT spend until resolved.\n' "$CRIT"
            printf 'cheapest path: fix the critical item(s) above, then re-run.\n'
        fi
    fi

    [ "$ready" -eq 1 ] && return 0 || return 1
}

main "$@"
