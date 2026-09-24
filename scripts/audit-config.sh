#!/usr/bin/env bash
#
# audit-config.sh — compare "actual" deployment settings against an
# "expected" spec and surface every drift with a remediation hint.
#
# Read-only. Emits a human table by default, or a single JSON document
# with --json (for the observability dashboard at :5099).
#
# Expected spec (the "ought be"):
#   .env.local present, mode 0600
#   DEEPSEEK_API_KEY (sk-*) and JEV_API_KEY (apikey_*) set
#   OPENCODE_SERVER_PASSWORD set, length >= 12
#   opencode.json parses; model == deepseek/deepseek-flash;
#     mcp.servers includes jev-review; plugin includes jev-guard
#   docker-compose.yml opencode-web: no-new-privileges, cap_drop ALL,
#     publishes 127.0.0.1:5099 (and 4096)
#   .gitignore ignores .env.local and *.bak.*
#   no .env.local.bak.* present
#   opencode.db present
#   (docker) container running; container password == .env.local
#   (network) DeepSeek balance above threshold
#
# Usage:
#   ./scripts/audit-config.sh            human table
#   ./scripts/audit-config.sh --json     single JSON document
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

REPO=""
JSON=0
BALANCE_THRESHOLD="${BALANCE_THRESHOLD:-1.00}"

# Severity ordering used by the summary.
FATAL=0
ERROR=0
WARN=0
OK=0
SKIP=0

FINDINGS=""

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

emit() {
    local key="$1" sev="$2" status="$3" expected="$4" actual="$5" fix="$6"
    FINDINGS="${FINDINGS}${key}|${sev}|${status}|${expected}|${actual}|${fix}"$'\n'
    case "$sev" in
        FATAL) FATAL=$((FATAL + 1)) ;;
        ERROR) ERROR=$((ERROR + 1)) ;;
        WARN)  WARN=$((WARN + 1)) ;;
        OK)    OK=$((OK + 1)) ;;
        SKIP)  SKIP=$((SKIP + 1)) ;;
    esac
    if [ "$JSON" = "0" ]; then
        printf '  [%-5s] %-30s %s\n' "$status" "$key" "$actual"
        if [ "$status" != "OK" ] && [ "$status" != "SKIP" ]; then
            printf '            expected: %s\n' "$expected"
            [ -n "$fix" ] && printf '            fix:      %s\n' "$fix"
        fi
    fi
}

json_esc() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

emit_json() {
    local first=1
    printf '{"repo":'
    printf '"%s"' "$(json_esc "$REPO")"
    printf ',"findings":['
    while IFS='|' read -r key sev status expected actual fix; do
        [ -n "$key" ] || continue
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"key":"%s","severity":"%s","status":"%s","expected":"%s","actual":"%s","fix":"%s"}' \
            "$(json_esc "$key")" "$(json_esc "$sev")" "$(json_esc "$status")" \
            "$(json_esc "$expected")" "$(json_esc "$actual")" "$(json_esc "$fix")"
    done <<< "$FINDINGS"
    printf '],"summary":{"fatal":%d,"error":%d,"warn":%d,"ok":%d,"skip":%d}}\n' \
        "$FATAL" "$ERROR" "$WARN" "$OK" "$SKIP"
}

main() {
    case "${1:-}" in
        --json) JSON=1 ;;
        "") ;;
        *) printf 'usage: %s [--json]\n' "$0"; return 2 ;;
    esac

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi

    local ENV="$REPO/.env.local"
    local OC="$REPO/opencode.json"
    local COMPOSE="$REPO/docker/docker-compose.yml"
    local GI="$REPO/.gitignore"
    local DB="$REPO/data/opencode/opencode.db"

    [ "$JSON" = "0" ] && printf '=== audit-config.sh ===\nrepo: %s\n\n' "$REPO"

    # ---- .env.local -------------------------------------------------------
    if [ -f "$ENV" ]; then
        local mode
        mode=$(stat -c '%a' "$ENV" 2>&1)
        if [ "$mode" = "600" ]; then
            emit env-mode OK OK "0600" "$mode" ""
        else
            emit env-mode ERROR DRIFT "0600" "$mode" "chmod 600 .env.local"
        fi
    else
        emit env-file FATAL MISSING "present" "missing" "create .env.local (see README)"
    fi

    # ---- keys + password from .env.local --------------------------------
    local DS="" JV="" PW=""
    if [ -f "$ENV" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                DEEPSEEK_API_KEY) DS="$v" ;;
                JEV_API_KEY)      JV="$v" ;;
                OPENCODE_SERVER_PASSWORD) PW="$v" ;;
            esac
        done < "$ENV"
    fi

    if [ -n "$DS" ]; then
        case "$DS" in
            sk-*) emit deepseek-key OK OK "sk-*" "set" "" ;;
            *)    emit deepseek-key WARN DRIFT "sk-*" "unexpected prefix" "issue a new key" ;;
        esac
    else
        emit deepseek-key FATAL MISSING "set" "empty" "add DEEPSEEK_API_KEY to .env.local"
    fi

    if [ -n "$JV" ]; then
        case "$JV" in
            apikey_*|sk-*|ts_*|jev-*) emit jev-key OK OK "apikey_*" "set" "" ;;
            *) emit jev-key WARN DRIFT "apikey_*" "unexpected prefix" "issue a new key" ;;
        esac
    else
        emit jev-key FATAL MISSING "set" "empty" "add JEV_API_KEY to .env.local"
    fi

    if [ -n "$PW" ]; then
        if [ "${#PW}" -ge 12 ]; then
            emit web-password OK OK "len >= 12" "len ${#PW}" ""
        else
            emit web-password WARN DRIFT "len >= 12" "len ${#PW}" "use a longer password"
        fi
    else
        emit web-password FATAL MISSING "set" "empty" "add OPENCODE_SERVER_PASSWORD to .env.local"
    fi

    # ---- opencode.json ----------------------------------------------------
    if [ -f "$OC" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OC" 2>&1; then
        emit opencode-json OK OK "valid JSON" "parses" ""
        local model mcp plugin
        model=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "$OC" 2>&1)
        mcp=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("mcp",{}).get("servers",{}).keys()))' "$OC" 2>&1)
        plugin=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("plugin",[]) or []))' "$OC" 2>&1)
        if [ "$model" = "deepseek/deepseek-flash" ]; then
            emit opencode-model OK OK "deepseek/deepseek-flash" "$model" ""
        else
            emit opencode-model ERROR DRIFT "deepseek/deepseek-flash" "$model" "set \"model\" in opencode.json"
        fi
        case ",$mcp," in
            *,jev-review,*) emit jev-mcp OK OK "jev-review" "$mcp" "" ;;
            *) emit jev-mcp ERROR DRIFT "jev-review" "$mcp" "add jev-review to mcp.servers" ;;
        esac
        case ",$plugin," in
            *,jev-guard,*) emit jev-plugin OK OK "jev-guard" "$plugin" "" ;;
            *) emit jev-plugin ERROR DRIFT "jev-guard" "$plugin" "add jev-guard to plugin" ;;
        esac
    else
        emit opencode-json FATAL MISSING "valid JSON" "missing or invalid" "fix opencode.json"
    fi

    # ---- docker-compose.yml ----------------------------------------------
    if [ -f "$COMPOSE" ]; then
        grep -q 'no-new-privileges:true' "$COMPOSE" \
            && emit compose-nonpriv OK OK "no-new-privileges:true" "present" "" \
            || emit compose-nonpriv ERROR DRIFT "no-new-privileges:true" "absent" "add security_opt"
        grep -q 'cap_drop:' "$COMPOSE" && grep -q '  - ALL' "$COMPOSE" \
            && emit compose-capdrop OK OK "cap_drop: ALL" "present" "" \
            || emit compose-capdrop ERROR DRIFT "cap_drop: ALL" "absent" "add cap_drop"
        grep -q '127.0.0.1:5099' "$COMPOSE" \
            && emit compose-dashport OK OK "127.0.0.1:5099" "present" "" \
            || emit compose-dashport WARN DRIFT "127.0.0.1:5099" "absent" "publish dashboard on localhost only"
    else
        emit compose-file FATAL MISSING "present" "missing" "restore docker/docker-compose.yml"
    fi

    # ---- .gitignore -------------------------------------------------------
    if [ -f "$GI" ]; then
        grep -q '^\.env\.local$' "$GI" \
            && emit gitignore-env OK OK ".env.local" "ignored" "" \
            || emit gitignore-env ERROR DRIFT ".env.local" "not ignored" "add .env.local to .gitignore"
        grep -q '^\*\.bak\.\*$' "$GI" \
            && emit gitignore-bak OK OK "*.bak.*" "ignored" "" \
            || emit gitignore-bak WARN DRIFT "*.bak.*" "not ignored" "add *.bak.* to .gitignore"
    else
        emit gitignore FATAL MISSING "present" "missing" "restore .gitignore"
    fi

    # ---- stale key backups ------------------------------------------------
    local baks
    baks=$(find "$REPO" -type f -name '.env.local.bak.*' 2>&1 | wc -l | tr -d ' ')
    if [ "${baks:-0}" = "0" ]; then
        emit stale-baks OK OK "0" "$baks" ""
    else
        emit stale-baks WARN DRIFT "0" "$baks" "./scripts/cleanup-baks.sh --apply"
    fi

    # ---- database ---------------------------------------------------------
    if [ -f "$DB" ]; then
        emit database OK OK "present" "present" ""
    else
        emit database ERROR DRIFT "present" "missing" "start the agent once to create it"
    fi

    # ---- container (optional, needs docker) ------------------------------
    if have docker; then
        local c="opencode-deepseek-web"
        local st
        st=$(docker inspect -f '{{.State.Status}}' "$c" 2>&1)
        if [ "$st" = "running" ]; then
            emit container OK OK "running" "running" ""
            if [ -n "$PW" ]; then
                local cpass
                cpass=$(docker exec "$c" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
                if [ "$cpass" = "$PW" ]; then
                    emit container-password OK OK "matches .env.local" "matches" ""
                else
                    emit container-password ERROR DRIFT "matches .env.local" "differs" "recreate container: docker compose up -d opencode-web"
                fi
            fi
        else
            emit container WARN DRIFT "running" "$st" "docker compose up -d opencode-web"
        fi
    else
        emit container SKIP SKIP "docker" "not available" ""
    fi

    # ---- DeepSeek balance (optional, needs key + curl) -------------------
    if [ -n "$DS" ] && have curl; then
        local http bal
        http=$(curl -s -o /tmp/audit-balance.$$ -w '%{http_code}' -m 15 \
            -H "Authorization: Bearer $DS" https://api.deepseek.com/user/balance)
        if [ "$http" = "200" ]; then
            bal=$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); b=[x for x in j.get("balance_infos",[]) if x.get("currency")=="USD"]; print(b[0]["total_balance"] if b else "0")' /tmp/audit-balance.$$ 2>&1)
            local ge
            ge=$(awk -v a="$bal" -v b="$BALANCE_THRESHOLD" 'BEGIN{print (a+0 >= b+0)?"1":"0"}')
            if [ "$ge" = "1" ]; then
                emit balance OK OK ">= \$$BALANCE_THRESHOLD" "\$$bal" ""
            else
                emit balance WARN DRIFT ">= \$$BALANCE_THRESHOLD" "\$$bal" "top up at platform.deepseek.com/top_up"
            fi
        else
            emit balance SKIP SKIP "HTTP 200" "HTTP $http" ""
        fi
        rm -f /tmp/audit-balance.$$
    else
        emit balance SKIP SKIP "key + curl" "not available" ""
    fi

    # ---- summary ----------------------------------------------------------
    if [ "$JSON" = "1" ]; then
        emit_json
    else
        printf '\n=== summary ===\n'
        printf '  ok=%d warn=%d error=%d fatal=%d skip=%d\n' "$OK" "$WARN" "$ERROR" "$FATAL" "$SKIP"
        printf '  balance threshold: $%s\n' "$BALANCE_THRESHOLD"
        if [ "$FATAL" -gt 0 ] || [ "$ERROR" -gt 0 ]; then
            printf '  result: FAIL\n'
            return 1
        fi
        printf '  result: OK (or warnings only)\n'
    fi

    if [ "$FATAL" -gt 0 ] || [ "$ERROR" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
