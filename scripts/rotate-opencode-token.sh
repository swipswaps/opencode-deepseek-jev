#!/usr/bin/env bash
#
# rotate-opencode-token.sh — rotate the OpenCode console token.
#
# The 2026-11-05 audit leaked OPENCODE_CONSOLE_TOKEN via `opencode debug
# config`. Neither rotate-api-keys.sh nor rotate-provider-keys.sh covers it:
# revocation is console-only, and the token may live in .env.local, auth.json,
# or the global provider config. This script handles the .env.local path:
# revoke in the console, paste the new token hidden, rewrite one line, recreate
# the web container, then prove the OpenCode Go path with the exact smoke.
#
#   ./scripts/rotate-opencode-token.sh
#   ./scripts/rotate-opencode-token.sh --no-recreate
#   ./scripts/rotate-opencode-token.sh --no-smoke
#   ./scripts/rotate-opencode-token.sh --self-test
#
# The old token is NOT revoked by this script (no CLI). Revoke it first at
# https://opencode.ai/console, then run this. Values are never printed.
#
# Exit 0 rotated+verified/skipped, 1 failure, 2 usage/preflight error.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
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

rewrite_env() {
    # rewrite_env FILE NEWTOKEN — replace the ONE line or append it. Atomic,
    # mode 0600, every other line byte-identical. Prints OK/FAIL.
    python3 - "$1" "$2" << 'PYEOF'
import os, sys
path, token = sys.argv[1], sys.argv[2]
key = "OPENCODE_CONSOLE_TOKEN"
with open(path) as fh:
    lines = fh.readlines()
out, seen, hits = [], False, 0
for ln in lines:
    if ln.startswith(key + "="):
        hits += 1
        out.append(key + "=" + token + "\n")
        seen = True
    else:
        out.append(ln)
if hits > 1:
    print("FAIL: expected at most 1 %s assignment, found %d" % (key, hits))
    raise SystemExit(1)
if not seen:
    out.append(key + "=" + token + "\n")
tmp = path + ".tmp.opencode"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.writelines(out)
os.replace(tmp, path)
os.chmod(path, 0o600)
print("OK")
PYEOF
}

smoke() {
    # smoke TOKEN — exact Go output check; never echoes the token.
    local token="$1" log rc
    log=$(mktemp) || return 1
    ( OPENCODE_CONSOLE_TOKEN="$token" timeout "${GO_SMOKE_TIMEOUT:-180}" \
        opencode run -m opencode-go/deepseek-v4.1-flash \
        "Reply with exactly: ROTATED" ) > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '  FAIL Go smoke: rc=%s bound=%ss\n' "$rc" "${GO_SMOKE_TIMEOUT:-180}"
        tail -n 20 "$log"
        rm -f "$log"
        return 1
    fi
    if grep -qx 'ROTATED' "$log" && grep -q 'deepseek-v4.1-flash' "$log"; then
        printf '  PASS Go smoke: exactly ROTATED\n'
        rm -f "$log"
        return 0
    fi
    printf '  FAIL Go smoke: output criterion (expected exactly ROTATED from deepseek-v4.1-flash)\n'
    tail -n 20 "$log"
    rm -f "$log"
    return 1
}

self_test() {
    local work="" fail=0 new="" out=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    {
        printf '%s\n' '# fixture'
        printf '%s\n' 'DEEPSEEK_API_KEY=short'
        printf '%s\n' 'OPENCODE_SERVER_PASSWORD=short'
        printf '%s\n' 'CUSTOM_KEY=keep'
    } > "$work/env.local"
    chmod 600 "$work/env.local"
    new=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))') || { printf 'FAIL token gen\n'; fail=1; }
    out=$(rewrite_env "$work/env.local" "$new" 2>&1)
    [ "$out" = "OK" ] || { printf 'FAIL rewrite: %s\n' "$out"; fail=1; }
    grep -q '^OPENCODE_CONSOLE_TOKEN=' "$work/env.local" || { printf 'FAIL append\n'; fail=1; }
    grep -q '^DEEPSEEK_API_KEY=short$' "$work/env.local" || { printf 'FAIL preserve\n'; fail=1; }
    [ "$(stat -c %a "$work/env.local")" = "600" ] || { printf 'FAIL mode\n'; fail=1; }
    # second write replaces, does not duplicate
    out=$(rewrite_env "$work/env.local" "$new" 2>&1)
    [ "$out" = "OK" ] || { printf 'FAIL rewrite2\n'; fail=1; }
    [ "$(grep -c '^OPENCODE_CONSOLE_TOKEN=' "$work/env.local")" -eq 1 ] || { printf 'FAIL duplicate\n'; fail=1; }
    rm -f "$work/env.local"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'rotate-opencode-token: self-test PASS\n'; else printf 'rotate-opencode-token: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local REPO ENVF MODE="interactive" RECREATE=1 SMOKE=1 KEEP_BACKUP=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi
    ENVF="$REPO/.env.local"
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return "$?" ;;
            --no-recreate) RECREATE=0; shift ;;
            --no-smoke) SMOKE=0; shift ;;
            --keep-backup) KEEP_BACKUP=1; shift ;;
            --env) ENVF="${2:-}"; shift 2 ;;
            -h | --help) printf 'usage: %s [--env FILE] [--no-recreate] [--no-smoke] [--keep-backup] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have python3 || { printf 'FAIL: python3 required\n'; return 2; }
    [ -f "$ENVF" ] || { printf 'FAIL: no env file at %s\n' "$ENVF"; return 2; }
    [ "$SMOKE" -eq 1 ] && ! have opencode && { printf 'FAIL: opencode required for smoke (or --no-smoke)\n'; return 2; }

    section "revoke the OLD token first (browser)"
    printf '  1. Open https://opencode.ai/console\n'
    printf '  2. Revoke the OpenCode console token (the one printed by\n'
    printf '     `opencode debug config`).\n'
    printf '  3. Create a new token and copy it.\n'
    printf '  The old token stops working when you revoke it; that is expected.\n'
    printf '  Type exactly "rotate" to continue, or anything else to abort: '
    if [ "${OCT_CONFIRM:-}" = "rotate" ]; then
        printf '\n'
    else
        local ok=""
        read -r ok
        [ "$ok" = "rotate" ] || { printf 'aborted\n'; return 1; }
    fi

    section "new token"
    local NEW="" NEW2="" ans=""
    printf 'Paste NEW OpenCode console token (hidden), then Enter: '
    read -r -s NEW; printf '\n'
    if [ -z "$NEW" ]; then printf 'FAIL: empty token\n'; return 1; fi
    printf 'Confirm NEW token (hidden): '
    read -r -s NEW2; printf '\n'
    if [ "$NEW" != "$NEW2" ]; then printf 'FAIL: confirmation differs\n'; return 1; fi
    printf '  new token: len=%d (value hidden)\n' "${#NEW}"
    if [ "${OCT_CONFIRM:-}" != "write" ]; then
        printf 'Type "write" to apply: '
        read -r ans
        [ "$ans" = "write" ] || { printf 'aborted\n'; return 1; }
    fi

    section "backup + rewrite"
    local TS BACKUP
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP="$ENVF.bak.opencode.$TS"
    cp "$ENVF" "$BACKUP" && chmod 600 "$BACKUP" || { printf 'FAIL backup\n'; return 1; }
    printf '  backup: %s\n' "$BACKUP"
    [ "$(rewrite_env "$ENVF" "$NEW")" = "OK" ] || { printf 'FAIL rewrite\n'; return 1; }
    printf '  env written (mode 600)\n'

    if [ "$RECREATE" -eq 1 ] && have docker; then
        section "recreate"
        "$REPO/scripts/web-restart.sh" --recreate || printf '  WARN web recreate failed\n'
    else
        section "recreate"
        printf '  skipped (--no-recreate or docker absent)\n'
    fi

    local fail=0
    if [ "$SMOKE" -eq 1 ]; then
        section "verify"
        smoke "$NEW" || fail=1
    else
        section "verify"
        printf '  SKIP Go smoke (--no-smoke)\n'
    fi

    section "summary"
    if [ "$fail" -eq 0 ] && [ "$SMOKE" -eq 1 ] && [ "$KEEP_BACKUP" -eq 0 ]; then
        rm -f "$BACKUP"
        printf '  backup removed after successful verification\n'
    else
        printf '  backup: %s\n' "$BACKUP"
        printf '  rollback: cp %s %s && ./scripts/web-restart.sh --recreate\n' "$BACKUP" "$ENVF"
        printf '  delete the backup after verification: rm -f %s\n' "$BACKUP"
    fi
    if [ "$fail" -eq 0 ]; then
        printf 'PASS: OpenCode console token rotated and Go path verified.\n'
    else
        printf 'FAIL: token written but Go smoke failed; check the console token and recreate.\n'
    fi
    return "$fail"
}

main "$@"
exit $?
