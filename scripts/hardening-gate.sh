#!/usr/bin/env bash
#
# hardening-gate.sh — P0 gate: independent review + evidence + handoff + guard.
#
# Explainer-driven safety tranche:
#   review-gate --gate   independent redacted-diff review (LOW may skip; MED/HIGH require PASS)
#   evidence-gate --check  runtime evidence claims (all claims by default; HARDENING_EVIDENCE narrows)
#   handoff-validate --check  schema + SHA-256 for the newest docs/HANDOFF-*.md
#   guard-health --check      guard present/current (strict + irreversible + output hook)
#
#   ./scripts/hardening-gate.sh
#   HARDENING_EVIDENCE=gates,a11y ./scripts/hardening-gate.sh
#   ./scripts/hardening-gate.sh --self-test
#
# Exit 0 PASS, 2 FAIL, 4 usage.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
# Leaf gate: runs review/evidence/handoff/guard only. It never calls
# closeout-gate.py (the closeout calls this gate; no recursion).
set -o pipefail

REPO=""
FAIL=0
STATE=""

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

step() {
    local name="$1"; shift
    if "$@" > "$STATE/hardening-$name" 2>&1; then
        printf '  PASS %-18s %s\n' "$name" "$(tail -1 "$STATE/hardening-$name")"
    else
        local rc=$?
        printf '  FAIL %-18s rc=%s %s\n' "$name" "$rc" "$(tail -1 "$STATE/hardening-$name")"
        FAIL=$((FAIL + 1))
    fi
}

self_test() {
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    STATE="$here/../logs"; mkdir -p "$STATE"
    if python3 "$here/review-gate.py" --self-test > $STATE/hardening-review-st 2>&1 \
       && python3 "$here/evidence-gate.py" --self-test > $STATE/hardening-evidence-st 2>&1 \
       && python3 "$here/handoff-validate.py" --self-test > $STATE/hardening-handoff-st 2>&1 \
       && bash "$here/guard-health.sh" --self-test > $STATE/hardening-guard-st 2>&1; then
        printf 'hardening-gate: self-test PASS\n'
        return 0
    fi
    printf 'hardening-gate: self-test FAIL\n'
    for f in $STATE/hardening-review-st $STATE/hardening-evidence-st $STATE/hardening-handoff-st $STATE/hardening-guard-st; do
        printf '%s\n' "--- $f"
        tail -n 3 "$f" 2>&1
    done
    return 2
}

main() {
    [ "${1:-}" = "--self-test" ] && { self_test; return "$?"; }
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo\n'; return 2; fi
    cd "$REPO" || { printf 'FAIL: cannot cd %s\n' "$REPO"; return 2; }
    STATE="$REPO/logs"; mkdir -p "$STATE"
    printf '=== hardening-gate ===\n'
    step review python3 scripts/review-gate.py --gate
    if [ -n "${HARDENING_EVIDENCE:-}" ]; then
        step evidence python3 scripts/evidence-gate.py --check --require "$HARDENING_EVIDENCE"
    else
        step evidence python3 scripts/evidence-gate.py --check
    fi
    step handoff python3 scripts/handoff-validate.py --check
    step guard ./scripts/guard-health.sh --check
    printf 'hardening-gate: %s\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf 'FAIL (%s)' "$FAIL")"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

main "$@"
