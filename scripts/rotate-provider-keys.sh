#!/usr/bin/env bash
#
# rotate-provider-keys.sh — rotate the remaining exposed credentials:
#   SUBQ_API_KEY        (console: api.subq.ai / subq.ai keys)
#   ANTHROPIC_API_KEY   (console.anthropic.com/settings/keys)
#   LITELLM_MASTER_KEY  (local: generated here; the proxy reads env_file)
#
# DeepSeek and OPENCODE_SERVER_PASSWORD are already rotated by their own
# scripts. Input is hidden; values are never printed (masks/lengths only).
# SUBQ rotation also updates JEV_BASE_API_KEY (the guard's copy).
#
#   ./scripts/rotate-provider-keys.sh                 # interactive
#   ./scripts/rotate-provider-keys.sh --no-recreate   # env only (tests)
#   ./scripts/rotate-provider-keys.sh --self-test     # offline rewrite test
#
# Revoke the OLD keys in each console FIRST; this script only writes the new
# values. Env changes are creation-time: the web and a running litellm proxy
# are recreated. A backup is kept for rollback; delete it after verification.
#
# Exit 0 rotated+verified/skipped, 1 failure, 2 usage/preflight error.
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. printf only.
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

mask() {
    local s="$1"
    if [ "${#s}" -le 8 ]; then printf '***'; return 0; fi
    printf '%s...%s(len %d)' "${s:0:3}" "${s: -2}" "${#s}"
}

gen_litellm() {
    python3 -c 'import secrets; print("sk-" + secrets.token_urlsafe(32))' 2>&1
}

rewrite_env() {
    # rewrite_env ENVFILE SUBQ ANTHROPIC LITELLM — empty means "leave unchanged".
    # JEV_BASE_API_KEY follows SUBQ (the guard's duplicate). Prints OK/FAIL.
    python3 - "$1" "${2:-}" "${3:-}" "${4:-}" <<'PY'
import os, sys
path, subq, anth, lit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
want = {}
if subq:
    want["SUBQ_API_KEY"] = subq
    want["JEV_BASE_API_KEY"] = subq
if anth:
    want["ANTHROPIC_API_KEY"] = anth
if lit:
    want["LITELLM_MASTER_KEY"] = lit
if not want:
    print("OK")
    raise SystemExit(0)
with open(path) as fh:
    lines = fh.readlines()
out, seen = [], set()
for ln in lines:
    k = ln.split("=", 1)[0] if ("=" in ln and not ln.lstrip().startswith("#")) else None
    if k in want:
        out.append(k + "=" + want[k] + "\n"); seen.add(k)
    else:
        out.append(ln)
for k, v in want.items():
    if k not in seen:
        out.append(k + "=" + v + "\n")
tmp = path + ".tmp.providers"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.writelines(out)
os.replace(tmp, path)
os.chmod(path, 0o600)
print("OK")
PY
}

verify_subq() {
    local out
    out=$(env -u SUBQ_API_KEY python3 "$REPO/scripts/subq_snap.py" \
        --state "service ping" --question escalate \
        --instructions "Is this service reachable?" 2>&1)
    case "$out" in
        *"noul="*) printf '  PASS subq (live call)\n'; return 0 ;;
        *) printf '  FAIL subq: %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; return 1 ;;
    esac
}

verify_anthropic() {
    local cfg code
    cfg=$(mktemp)
    ( umask 077; printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$ANTH" > "$cfg" )
    code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -K "$cfg" https://api.anthropic.com/v1/models 2>&1)
    rm -f "$cfg"
    if [ "$code" = "200" ]; then printf '  PASS anthropic (/v1/models 200)\n'; return 0; fi
    printf '  FAIL anthropic: http=%s (new key rejected?)\n' "$code"; return 1
}

verify_litellm() {
    local cfg code i
    cfg=$(mktemp)
    ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$LIT" > "$cfg" )
    code="000"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -K "$cfg" http://127.0.0.1:4000/v1/models 2>&1)
        [ "$code" = "200" ] && break
        sleep 2
    done
    rm -f "$cfg"
    if [ "$code" = "200" ]; then printf '  PASS litellm (/v1/models 200)\n'; return 0; fi
    printf '  WARN litellm: http=%s (proxy down or not recreated)\n' "$code"; return 0
}

self_test() {
    local work fail=0
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    printf '%s\n' \
        '# fixture' \
        'DEEPSEEK_API_KEY=keep-ds' \
        'SUBQ_API_KEY=old-subq' \
        'JEV_BASE_API_KEY=old-subq' \
        'ANTHROPIC_API_KEY=old-ant' \
        'LITELLM_MASTER_KEY=old-litellm' \
        'CUSTOM_KEY=keep' > "$work/env.local"
    chmod 600 "$work/env.local"
    rewrite_env "$work/env.local" "new-subq" "new-ant" "new-litellm" > "$work/o1" 2>&1 || fail=1
    grep -q '^SUBQ_API_KEY=new-subq$' "$work/env.local" || { printf 'FAIL subq\n'; fail=1; }
    grep -q '^JEV_BASE_API_KEY=new-subq$' "$work/env.local" || { printf 'FAIL jev dup\n'; fail=1; }
    grep -q '^ANTHROPIC_API_KEY=new-ant$' "$work/env.local" || { printf 'FAIL anthropic\n'; fail=1; }
    grep -q '^LITELLM_MASTER_KEY=new-litellm$' "$work/env.local" || { printf 'FAIL litellm\n'; fail=1; }
    grep -q '^DEEPSEEK_API_KEY=keep-ds$' "$work/env.local" || { printf 'FAIL preserve\n'; fail=1; }
    grep -q '^CUSTOM_KEY=keep$' "$work/env.local" || { printf 'FAIL custom\n'; fail=1; }
    [ "$(stat -c %a "$work/env.local")" = "600" ] || { printf 'FAIL mode\n'; fail=1; }
    # empty args leave values unchanged (skip semantics)
    rewrite_env "$work/env.local" "" "" "" > "$work/o2" 2>&1 || fail=1
    grep -q '^SUBQ_API_KEY=new-subq$' "$work/env.local" || { printf 'FAIL skip subq\n'; fail=1; }
    rm -r "$work"
    if [ "$fail" -eq 0 ]; then printf 'rotate-provider-keys: self-test PASS\n'; else printf 'rotate-provider-keys: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local REPO ENVF MODE="interactive" RECREATE=1
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi
    ENVF="$REPO/.env.local"
    cd "$REPO" || return 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return "$?" ;;
            --no-recreate) RECREATE=0; shift ;;
            --env) ENVF="${2:-}"; shift 2 ;;
            -h | --help) printf 'usage: %s [--no-recreate] [--env FILE] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have python3 || { printf 'FAIL: python3 required\n'; return 2; }
    have curl || { printf 'FAIL: curl required\n'; return 2; }
    [ -f "$ENVF" ] || { printf 'FAIL: no env file at %s\n' "$ENVF"; return 2; }

    section "revoke the OLD keys first (browser)"
    printf '  SUBQ:      https://api.subq.ai  (or https://subq.ai keys)\n'
    printf '  Anthropic: https://console.anthropic.com/settings/keys\n'
    printf '  LiteLLM:   local master; regenerated here (old proxy key dies on recreate)\n'
    printf '  DeepSeek and the server password are already rotated.\n'

    local NEW_SUBQ="" NEW_ANTH="" NEW_LIT="" yn=""
    printf '\nNew SUBQ key (hidden; empty = leave unchanged): '
    read -r -s NEW_SUBQ; printf '\n'
    printf 'New Anthropic key (hidden; empty = leave unchanged): '
    read -r -s NEW_ANTH; printf '\n'
    printf 'Generate a new local LiteLLM master key? [Y/n]: '
    read -r yn
    case "$yn" in
        n | N)
            printf 'New LiteLLM key (hidden; empty = leave unchanged): '
            read -r -s NEW_LIT; printf '\n'
            ;;
        *)
            NEW_LIT=$(gen_litellm)
            printf 'generated LiteLLM key: %s\n' "$(mask "$NEW_LIT")"
            ;;
    esac

    if [ -z "$NEW_SUBQ" ] && [ -z "$NEW_ANTH" ] && [ -z "$NEW_LIT" ]; then
        printf 'nothing to change\n'; return 1
    fi
    printf '\n  new SUBQ:      %s\n' "$( [ -n "$NEW_SUBQ" ] && mask "$NEW_SUBQ" || printf '(unchanged)')"
    printf '  new Anthropic: %s\n' "$( [ -n "$NEW_ANTH" ] && mask "$NEW_ANTH" || printf '(unchanged)')"
    printf '  new LiteLLM:   %s\n' "$( [ -n "$NEW_LIT" ] && mask "$NEW_LIT" || printf '(unchanged)')"
    if [ "${PROVIDER_CONFIRM:-}" != "write" ]; then
        printf 'Type "write" to apply: '
        read -r ans
        if [ "$ans" != "write" ]; then printf 'aborted\n'; return 1; fi
    fi

    local TS BACKUP
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP="$ENVF.bak.providers.$TS"
    cp "$ENVF" "$BACKUP" && chmod 600 "$BACKUP" || { printf 'FAIL backup\n'; return 1; }
    printf 'backup: %s\n' "$BACKUP"
    [ "$(rewrite_env "$ENVF" "$NEW_SUBQ" "$NEW_ANTH" "$NEW_LIT")" = "OK" ] || { printf 'FAIL rewrite\n'; return 1; }
    printf 'env written (mode 600)\n'

    if [ "$RECREATE" -eq 1 ] && have docker; then
        section "recreate"
        "$REPO/scripts/web-restart.sh" --recreate || printf 'WARN web recreate failed\n'
        if docker ps --format '{{.Names}}' 2>&1 | grep -qx litellm; then
            ( cd "$REPO/docker" && docker compose -f docker-compose.litellm.yml up -d --force-recreate litellm ) \
                || printf 'WARN litellm recreate failed\n'
        else
            printf 'litellm not running; proxy recreate skipped\n'
        fi
    else
        printf 'recreate skipped (--no-recreate or docker absent)\n'
    fi

    section "verify"
    local fail=0 ANTH="$NEW_ANTH" LIT="$NEW_LIT"
    [ -n "$NEW_SUBQ" ] && { verify_subq || fail=1; }
    [ -n "$NEW_ANTH" ] && { verify_anthropic || fail=1; }
    [ -n "$NEW_LIT" ] && { verify_litellm || fail=1; }
    if [ -x "$REPO/scripts/guard-verify.sh" ] && have docker; then
        "$REPO/scripts/guard-verify.sh" >/tmp/guard-verify-providers.txt 2>&1 && printf '  PASS guard (jev-guard via new SUBQ)\n' \
            || { printf '  WARN guard: see /tmp/guard-verify-providers.txt\n'; }
    fi

    section "summary"
    printf '  backup: %s\n' "$BACKUP"
    printf '  old keys: revoke them in the consoles (already requested above)\n'
    printf '  delete the backup after verification: rm -f %s\n' "$BACKUP"
    if [ "$fail" -eq 0 ]; then
        printf '  PASS: provider keys rotated\n'
        return 0
    fi
    printf '  FAIL: one or more verifications failed (see above)\n'
    return 1
}

main "$@"
