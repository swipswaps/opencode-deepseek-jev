#!/usr/bin/env bash
#
# verify-rotation-go.sh — one host-side gate for the 2026-11-05 rotation.
#
# The rotation touched four credentials and two security invariants, so the
# proof should be one command, not a paste of eight. This script runs the
# existing gates in order and adds the two checks they do not cover:
#   - no .env.local.bak.* files remain (old keys at rest)
#   - the OpenCode Go path answers "Reply with exactly: ROTATED"
#
# It never prints a secret value. It never rotates or recreates anything. It
# does make one small paid model call unless --no-smoke is passed.
#
#   ./scripts/verify-rotation-go.sh
#   ./scripts/verify-rotation-go.sh --no-smoke
#   ./scripts/verify-rotation-go.sh --no-preflight
#   ./scripts/verify-rotation-go.sh --json
#   ./scripts/verify-rotation-go.sh --help
#
# Exit 0 all checks pass (SKIP and MANUAL do not fail); 1 a check failed;
# 2 usage / missing repo.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

SCRIPT_NAME="verify-rotation-go.sh"
SMOKE=1
PREFLIGHT=1
JSON=0
PASS=0
FAIL=0
SKIP=0
MANUAL=0
CHECKS=""

section() { [ "$JSON" -eq 1 ] || printf '\n=== %s ===\n' "$1"; }
info() { [ "$JSON" -eq 1 ] || printf '  info  %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); add_check "$1" PASS; [ "$JSON" -eq 1 ] || printf '  PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); add_check "$1" FAIL; [ "$JSON" -eq 1 ] || printf '  FAIL  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); add_check "$1" SKIP; [ "$JSON" -eq 1 ] || printf '  SKIP  %s\n' "$*"; }
manual() { MANUAL=$((MANUAL + 1)); add_check "$1" MANUAL; [ "$JSON" -eq 1 ] || printf '  MANUAL %s\n' "$*"; }

add_check() {
    local name="$1" verdict="$2" sep=""
    [ -n "$CHECKS" ] && sep=","
    CHECKS="$CHECKS$sep{\"name\":\"$name\",\"verdict\":\"$verdict\"}"
}

have() { command -v "$1" >/dev/null 2>&1; }

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

ms_now() { date +%s%3N 2>&1; }

run_logged() {
    # run_logged NAME BOUND_REASON -- CMD...
    local name="$1" reason="$2"; shift 2
    [ "${1:-}" = "--" ] && shift
    local log="$WORK/$name.log" start end rc
    start=$(ms_now)
    timeout "${CHECK_TIMEOUT:-180}" "$@" > "$log" 2>&1
    rc=$?
    end=$(ms_now)
    if [ "$rc" -eq 0 ]; then
        pass "$name (ms=$((end - start)))"
    else
        fail "$name (ms=$((end - start)) rc=$rc) $reason"
        if [ -f "$log" ]; then
            tail -n 20 "$log" | while IFS= read -r line; do
                [ "$JSON" -eq 1 ] || printf '        %s\n' "$line"
            done
        fi
    fi
    return "$rc"
}

check_preflight() {
    section "preflight (fail-closed spend/budget/model gate)"
    local log="$WORK/preflight.log" out rc
    out=$(timeout 45 "$REPO/scripts/preflight.sh" --json 2>&1)
    rc=$?
    printf '%s\n' "$out" > "$log"
    if [ "$rc" -eq 0 ]; then
        pass "preflight ready"
    else
        fail "preflight STOP (rc=$rc)"
        [ "$JSON" -eq 1 ] || printf '%s\n' "$out" | tail -n 12 | while IFS= read -r line; do printf '        %s\n' "$line"; done
    fi
}

check_env_mode() {
    section "secret-file modes"
    local envf="$REPO/.env.local" mode
    if [ ! -f "$envf" ]; then
        fail ".env.local present"
        return
    fi
    mode=$(stat -c %a "$envf" 2>&1)
    if [ "$mode" = "600" ]; then pass ".env.local mode 600"; else fail ".env.local mode 600 (got $mode)"; fi
    if [ -f "$REPO/docker/litellm-db.env" ]; then
        mode=$(stat -c %a "$REPO/docker/litellm-db.env" 2>&1)
        if [ "$mode" = "600" ]; then pass "litellm-db.env mode 600"; else fail "litellm-db.env mode 600 (got $mode)"; fi
    else
        skip "litellm-db.env present"
    fi
}

check_console_token() {
    section "OpenCode console token"
    if [ -f "$REPO/.env.local" ] && grep -q '^OPENCODE_CONSOLE_TOKEN=' "$REPO/.env.local"; then
        manual "OPENCODE_CONSOLE_TOKEN present in .env.local — confirm the old token was revoked and this is the new one"
    else
        manual "no OPENCODE_CONSOLE_TOKEN in .env.local — confirm any OpenCode console token (auth.json or console session) was revoked"
    fi
}

check_backups() {
    section "old key backups"
    local found
    found=$(find "$REPO" -maxdepth 1 -type f -name '.env.local.bak.*' -printf '%f\n' 2>&1)
    if [ -z "$found" ]; then
        pass "no .env.local.bak.* files"
    else
        fail "old key backup(s) remain: $found — run ./scripts/scrub-secrets.sh --apply --yes --purge-env-backups"
    fi
}

check_cert_ignore() {
    section "cert ignore"
    if [ ! -f "$REPO/docker/certs/.gitignore" ]; then
        fail "docker/certs/.gitignore present — run git checkout -- docker/certs/.gitignore on the host"
        return
    fi
    if git -C "$REPO" check-ignore -q docker/certs/opencode.key; then
        pass "docker/certs/*.key ignored"
    else
        fail "docker/certs/opencode.key is NOT ignored"
    fi
}

check_git_status() {
    section "git status"
    local out bad=0
    out=$(git -C "$REPO" status --short 2>&1)
    [ -n "$out" ] && info "uncommitted changes:" && printf '%s\n' "$out" | while IFS= read -r line; do [ "$JSON" -eq 1 ] || printf '        %s\n' "$line"; done
    case "$out" in
        *"D docker/certs/.gitignore"*) bad=1 ;;
    esac
    if [ "$bad" -eq 0 ]; then pass "no docker/certs/.gitignore deletion on the host"; else fail "docker/certs/.gitignore deleted — run git checkout -- docker/certs/.gitignore"; fi
}

check_smoke() {
    section "OpenCode Go smoke"
    if [ "$SMOKE" -eq 0 ]; then
        skip "opencode-go/deepseek-v4.1-flash smoke (--no-smoke)"
        return
    fi
    if ! have opencode; then
        fail "opencode binary present"
        return
    fi
    local log="$WORK/go-smoke.log" start end rc
    start=$(ms_now)
    timeout "${SMOKE_TIMEOUT:-180}" opencode run -m opencode-go/deepseek-v4.1-flash \
        "Reply with exactly: ROTATED" > "$log" 2>&1
    rc=$?
    end=$(ms_now)
    if [ "$rc" -ne 0 ]; then
        fail "Go smoke completed (ms=$((end - start)) rc=$rc) — bound=${SMOKE_TIMEOUT:-180}s; normal run observed <15s"
        tail -n 20 "$log" | while IFS= read -r line; do [ "$JSON" -eq 1 ] || printf '        %s\n' "$line"; done
        return
    fi
    if grep -qx 'ROTATED' "$log" && grep -q 'deepseek-v4.1-flash' "$log"; then
        pass "Go smoke returned exactly ROTATED (ms=$((end - start)))"
    else
        fail "Go smoke output criterion failed (ms=$((end - start))) — expected exactly ROTATED from deepseek-v4.1-flash"
        tail -n 20 "$log" | while IFS= read -r line; do [ "$JSON" -eq 1 ] || printf '        %s\n' "$line"; done
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-smoke) SMOKE=0; shift ;;
            --no-preflight) PREFLIGHT=0; shift ;;
            --json) JSON=1; shift ;;
            -h | --help)
                printf 'usage: %s [--no-smoke] [--no-preflight] [--json]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'ERROR: cannot resolve repo root\n' >&2
        return 2
    fi
    WORK=$(mktemp -d)
    local TS REV
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')

    if [ "$JSON" -eq 0 ]; then
        printf '=== %s ===\n' "$SCRIPT_NAME"
        printf 'repo: %s\n' "$REPO"
        printf 'rev:  %s\n' "$REV"
        printf 'utc:  %s\n' "$TS"
    fi

    [ -x "$REPO/scripts/preflight.sh" ] || { printf 'ERROR: preflight.sh missing\n' >&2; return 2; }
    [ -x "$REPO/scripts/security-posture.sh" ] || { printf 'ERROR: security-posture.sh missing\n' >&2; return 2; }

    [ "$PREFLIGHT" -eq 1 ] && check_preflight || skip "preflight (--no-preflight)"
    check_env_mode
    check_console_token
    check_backups
    check_cert_ignore

    section "at-rest secrets"
    run_logged "secret-scan" "rotate/scrub before continuing" -- "$REPO/scripts/secret-scan.sh"
    run_logged "secret-leak-response --audit" "contain the finding, then rotate" -- "$REPO/scripts/secret-leak-response.sh" --audit

    section "security gates"
    run_logged "security-posture" "expect pass=19 fail=0" -- "$REPO/scripts/security-posture.sh"
    run_logged "https-selfheal --check" "expect exit 0" -- "$REPO/scripts/https-selfheal.sh" --check
    run_logged "red-team" "expect all layers pass" -- "$REPO/scripts/red-team.sh"

    check_smoke
    check_git_status

    local total
    total=$((PASS + FAIL + SKIP + MANUAL))
    if [ "$JSON" -eq 1 ]; then
        printf '{"ts":"%s","rev":"%s","pass":%d,"fail":%d,"skip":%d,"manual":%d,"checks":[%s]}\n' \
            "$TS" "$REV" "$PASS" "$FAIL" "$SKIP" "$MANUAL" "$CHECKS"
    else
        section "summary"
        printf 'pass=%d fail=%d skip=%d manual=%d total=%d\n' "$PASS" "$FAIL" "$SKIP" "$MANUAL" "$total"
        if [ "$FAIL" -eq 0 ]; then
            printf 'VERDICT: PASS — rotation and Go path verified; manual items still need a human.\n'
        else
            printf 'VERDICT: FAIL — fix the named checks before trusting the rotation.\n'
        fi
        printf '@@END %s pass=%d fail=%d skip=%d manual=%d ts=%s\n' "$SCRIPT_NAME" "$PASS" "$FAIL" "$SKIP" "$MANUAL" "$TS"
    fi

    rm -f "$WORK"/*.log
    rmdir "$WORK"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
exit $?
