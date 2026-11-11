#!/usr/bin/env bash
#
# verify-tier-budget.sh — one paste-safe proof that the tier-1 doc budget and
# its guarding gates are green.
#
# WHY: the 2026-11-11 trim moved old TODO Done + HANDOFF PINs into
# docs/*-archive-2026.md to hold the read-first budget (RULE #77). Proving it
# from a chat message failed when the block carried arrows/prompts; this is the
# scripted form, so the check is one command with a real exit code.
#
#   ./scripts/verify-tier-budget.sh          # budget + lint + hygiene + beacon self-test
#   ./scripts/verify-tier-budget.sh --fast    # skip test-hygiene (slow)
#   ./scripts/verify-tier-budget.sh --help
#
# Exit 0 all steps PASS; 1 any step FAIL; 2 usage / cannot run.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

REPO=""
FAST=0
PASS=0
FAIL=0
SKIP=0

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

usage() {
    printf 'usage: %s [--fast] [--help]\n' "$0"
    printf '  --fast   skip test-hygiene (slow; ~1 min+)\n'
    printf 'exit: 0 all PASS, 1 any FAIL, 2 cannot run\n'
}

row() {
    local name="$1" status="$2" detail="$3"
    case "$status" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        *)    SKIP=$((SKIP + 1)) ;;
    esac
    printf '  %-4s %-16s %s\n' "$status" "$name" "$detail"
}

last_line() {
    awk 'NF { last = $0 } END { print last }'
}

step() {
    local name="$1"
    shift
    local out="" rc=0 detail=""
    out=$("$@" 2>&1)
    rc=$?
    detail=$(printf '%s\n' "$out" | last_line)
    if [ "$rc" -eq 0 ]; then
        row "$name" PASS "$detail"
    else
        row "$name" FAIL "rc=$rc :: $detail"
    fi
    return 0
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fast) FAST=1; shift ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo root\n'
        return 2
    fi
    cd "$REPO" || { printf 'FAIL: cannot cd %s\n' "$REPO"; return 2; }
    if ! command -v git > /dev/null; then
        printf 'FAIL: git required\n'
        return 2
    fi

    printf '=== verify-tier-budget ===\n'
    printf 'repo: %s\n' "$REPO"
    printf 'head: %s\n\n' "$(git log --oneline -1)"

    local budget_out="" budget_rc=0 tier_line=""
    budget_out=$(./scripts/doc-budget.sh --fail 2>&1)
    budget_rc=$?
    tier_line=$(printf '%s\n' "$budget_out" | awk '/^tier 1/{print; exit}')
    if [ "$budget_rc" -eq 0 ]; then
        row doc-budget PASS "${tier_line:-within budget}"
    else
        row doc-budget FAIL "rc=$budget_rc :: ${tier_line:-over budget}"
    fi

    step lint ./scripts/lint.sh
    if [ "$FAST" -eq 1 ]; then
        row hygiene SKIP '--fast'
    else
        step hygiene ./scripts/test-hygiene.sh
    fi
    step beacon-self-test ./scripts/beacon-watch.sh --self-test

    printf '\n=== summary: %d pass, %d fail, %d skip ===\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
