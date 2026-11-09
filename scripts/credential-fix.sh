#!/usr/bin/env bash
#
# credential-fix.sh - turn "AI_APICallError: Invalid credential" into numbered,
# actionable fixes, informed by the opencode log and auth store.
#
#   ./scripts/credential-fix.sh                 # diagnose + print the menu
#   ./scripts/credential-fix.sh --apply 2       # switch model to an authed provider
#   ./scripts/credential-fix.sh --apply 3       # print the stale-Anthropic logout
#   ./scripts/credential-fix.sh --self-test     # offline fixtures
#
# Why: the error names the failing provider (e.g. opencode-go) and model, but
# the UI only says "Invalid credential". This reads the last real log line,
# lists what is authenticated, and offers the safe fixes:
#
#   1) authenticate the failing provider        (opencode auth login)
#   2) switch the project model to DeepSeek     (deepseek/deepseek-flash)
#   3) remove the stale Anthropic credential    (Claude cancelled)
#   4) reload the client                        (web container / CLI restart)
#
# The web UI denies the native question tool (session permission), so this
# prints the same choices as text; reply with a number.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

LOG="${OPENCODE_LOG:-$HOME/.local/share/opencode/log/opencode.log}"
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
CONF="${CRED_CONF:-$SELF_DIR/../opencode.json}"
BACKUP_TS="$(date -u +%Y%m%dT%H%M%SZ)"

have() { command -v "$1" >/dev/null; }

last_error_line() {
    [ -f "$LOG" ] || return 1
    grep 'error.error="AI_APICallError: Invalid credential"' "$LOG" 2>&1 | tail -1
}

field() {
    # field VALUE KEY -> value after "KEY="
    printf '%s' "$1" | awk -v k="$2" '{for (i=1;i<=NF;i++) if (index($i,k"=")==1) {sub(k"=","",$i); print $i; exit}}'
}

auth_providers() {
    if have opencode; then
        opencode auth list 2>&1 | awk '/●/ {print "  - " $2}'
    else
        printf '  (opencode not on PATH)\n'
    fi
}

current_model() {
    [ -f "$CONF" ] || { printf '<none>'; return; }
    awk -F'"' '/"model"[[:space:]]*:/ {print $4; exit}' "$CONF"
}

diagnose() {
    local line="" provider="" model=""
    line="$(last_error_line)"
    if [ -n "$line" ]; then
        provider="$(field "$line" providerID)"
        model="$(field "$line" modelID)"
    fi
    printf '=== credential-fix ===\n'
    printf 'failing provider : %s\n' "${provider:-<none in log>}"
    printf 'failing model    : %s\n' "${model:-<none in log>}"
    printf 'project model    : %s\n' "$(current_model)"
    printf 'authenticated    :\n'
    auth_providers

    if [ -z "$provider" ]; then
        printf '\nNo "Invalid credential" line found in the recent log.\n'
        printf 'The last errors were resolved, or the log rotated.\n'
    else
        printf '\nThe error is from provider "%s", not Anthropic (unless Anthropic\n' "$provider"
        printf 'is listed above and is the failing one). "opencode-go" is the\n'
        printf 'opencode gateway and needs its own login.\n'
    fi

    printf '\nChoose a fix (reply with the number):\n'
    printf '  1  authenticate the failing provider   -> opencode auth login   [interactive]\n'
    printf '  2  switch the project model            -> deepseek/deepseek-flash\n'
    printf '  3  remove the stale Anthropic auth     -> opencode auth logout anthropic\n'
    printf '  4  reload the client                   -> web: docker restart opencode-deepseek-web\n'
    printf '                                            CLI: quit and relaunch opencode\n'
    printf '\nRun: %s --apply N\n' "$0"
}

apply_model_switch() {
    local target="deepseek/deepseek-flash"
    [ -f "$CONF" ] || { printf 'FAIL: no config at %s\n' "$CONF"; return 2; }
    if ! have python3; then printf 'FAIL: python3 required\n'; return 2; fi
    cp "$CONF" "$CONF.bak.$BACKUP_TS" 2>&1 || { printf 'FAIL: backup failed\n'; return 2; }
    python3 - "$CONF" "$target" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["model"] = target
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
print("model -> " + target)
PY
    printf 'backup: %s.bak.%s\n' "$CONF" "$BACKUP_TS"
    printf 'restart the client (choice 4), then retry.\n'
}

apply_choice() {
    case "$1" in
        1)
            printf 'Run interactively:\n  opencode auth login\n'
            printf 'Pick the failing provider (e.g. opencode / opencode-go) or DeepSeek.\n'
            ;;
        2) apply_model_switch ;;
        3)
            printf 'Run (Claude was cancelled):\n  opencode auth logout anthropic\n'
            ;;
        4)
            printf 'Reload:\n'
            printf '  web: docker restart opencode-deepseek-web\n'
            printf '  CLI: quit and relaunch opencode (config/auth load at start)\n'
            ;;
        *) printf 'FAIL: choose 1..4\n'; return 2 ;;
    esac
}

self_test() {
    local fail=0 w="" c="" out=""
    w="$(mktemp)"
    c="$(mktemp)"
    printf '%s\n' 'timestamp=2026-11-09T19:43:53.657Z level=ERROR message="stream error" providerID=opencode-go modelID=deepseek-v4.1-flash session.id=x error.error="AI_APICallError: Invalid credential"' > "$w"
    printf '{\n  "model": "opencode-go/deepseek-v4.1-flash"\n}\n' > "$c"
    out="$(CRED_LOG="$w" CRED_CONF="$c" bash "$0" 2>&1)"
    printf '%s' "$out" | grep -q 'failing provider : opencode-go' || { printf 'FAIL provider parse\n'; fail=1; }
    printf '%s' "$out" | grep -q 'switch the project model' || { printf 'FAIL menu\n'; fail=1; }
    CRED_LOG="$w" CRED_CONF="$c" bash "$0" --apply 2 > /dev/null 2>&1
    grep -q '"model": "deepseek/deepseek-flash"' "$c" || { printf 'FAIL model switch\n'; fail=1; }
    grep -q 'opencode-go/deepseek' "$c.bak."* 2>&1 || { printf 'FAIL backup\n'; fail=1; }
    rm -f "$w" "$c" "$c.bak."*
    if [ "$fail" -eq 0 ]; then printf 'credential-fix: self-test PASS (parse + menu + model switch)\n'; else printf 'credential-fix: self-test FAIL\n'; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--diagnose|--apply N|--self-test]\n' "$0"
    printf '  N: 1 auth login, 2 model->deepseek, 3 logout anthropic, 4 reload\n'
}

main() {
    case "${1:-}" in
        --diagnose | '') diagnose; return 0 ;;
        --apply) apply_choice "${2:-}" ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
    esac
}

main "$@"
