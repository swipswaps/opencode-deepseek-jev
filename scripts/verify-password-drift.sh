#!/usr/bin/env bash
#
# verify-password-drift.sh — 4-gate verification that OPENCODE_SERVER_PASSWORD
# handling is consistent across web.sh, .env.local, and the running container.
#
# Gates:
#   G1  web.sh warns when shell value differs from .env.local
#   G2  web.sh does NOT warn when shell value is absent
#   G3  doctor.sh Tier 2 reports PASS for OPENCODE_SERVER_PASSWORD
#   G4  Auth enforced end-to-end (401 without credentials)
#
# No sed. No 2>/dev/null. No set -e. No top-level exit. No rm -rf.
# No subprocess.run. No bare kill. printf only. main() wrapper.
#
set -o pipefail

REPO=""
LOG=""
ART=""
GATES_RUN=0
GATES_PASS=0
GATES_FAIL=0

# The drift warning pattern web.sh is expected to emit. Kept as a variable
# so a future wording change is a one-line edit, not a grep hunt.
DRIFT_RE='WARN.*(differs|drift|mismatch|override.*env\.local)'

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

log() {
    local level="$1" phase="$2" status="$3" msg="$4"
    shift 4
    local ts kv p
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    kv=""
    for p in "$@"; do kv="$kv $p"; done
    [ -n "$LOG" ] && printf 'ts=%s level=%s phase=%s status=%s msg="%s"%s\n' \
        "$ts" "$level" "$phase" "$status" "$msg" "$kv" >> "$LOG"
}

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
}

record() {
    local name="$1" status="$2" detail="$3"
    GATES_RUN=$((GATES_RUN + 1))
    case "$status" in
        PASS) GATES_PASS=$((GATES_PASS + 1)) ;;
        FAIL) GATES_FAIL=$((GATES_FAIL + 1)) ;;
    esac
    printf '  %-4s %-4s %s\n' "$name" "$status" "$detail"
    log INFO check "$status" "$name" "detail=$detail"
}

# Extract a section from doctor.sh output delimited by two headers.
extract_section() {
    local file="$1" start="$2" stop="$3"
    awk -v s="$start" -v e="$stop" '
        $0 ~ e { exit }
        $0 ~ s { flag = 1 }
        flag
    ' "$file"
}

main() {
    local sd repo ts
    sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$sd")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    REPO="$repo"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ART="$repo/logs/artifacts-$ts"
    mkdir -p "$ART"

    printf '=== verify-password-drift.sh ===\n'
    printf 'repo:    %s\n' "$REPO"
    printf 'art:     %s\n' "$ART"
    printf 'drift:   %s\n' "$DRIFT_RE"

    cd "$REPO" || return 1

    # ---------------------------------------------------------------------
    section "G1  drift warning fires when shell value differs from .env.local"
    local g1_log="$ART/g1-web-dirty.log"
    (
        export OPENCODE_SERVER_PASSWORD=wrong-stale-value
        timeout 90 ./scripts/web.sh
    ) > "$g1_log" 2>&1
    local g1_rc=$?
    printf '  web.sh exit=%s  log=%s\n' "$g1_rc" "$g1_log"
    printf '  WARN lines in output:\n'
    grep -iE 'WARN' "$g1_log" | head -5 | indent
    if grep -qE "$DRIFT_RE" "$g1_log"; then
        record G1 PASS "drift warning present"
    else
        record G1 FAIL "no drift warning (pattern: $DRIFT_RE)"
    fi

    # ---------------------------------------------------------------------
    section "G2  no drift warning when shell value is absent"
    local g2_log="$ART/g2-web-clean.log"
    (
        unset OPENCODE_SERVER_PASSWORD
        timeout 90 ./scripts/web.sh
    ) > "$g2_log" 2>&1
    local g2_rc=$?
    printf '  web.sh exit=%s  log=%s\n' "$g2_rc" "$g2_log"
    if grep -qE "$DRIFT_RE" "$g2_log"; then
        printf '  spurious warning:\n'
        grep -E "$DRIFT_RE" "$g2_log" | head -3 | indent
        record G2 FAIL "spurious drift warning with clean shell"
    else
        record G2 PASS "no drift warning with clean shell"
    fi

    # ---------------------------------------------------------------------
    section "G3  doctor.sh Tier 2 reports OPENCODE_SERVER_PASSWORD"
    local g3_log="$ART/g3-doctor.log"
    timeout 90 ./scripts/doctor.sh > "$g3_log" 2>&1
    local g3_rc=$?
    printf '  doctor.sh exit=%s  log=%s\n' "$g3_rc" "$g3_log"
    local tier2
    tier2=$(extract_section "$g3_log" 'Tier 2' 'Tier 3')
    if [ -n "$tier2" ]; then
        printf '  Tier 2 block:\n'
        printf '%s\n' "$tier2" | head -40 | indent
        if printf '%s' "$tier2" | grep -qiE 'pass.*OPENCODE_SERVER_PASSWORD'; then
            record G3 PASS "Tier 2 PASS for OPENCODE_SERVER_PASSWORD"
        else
            record G3 FAIL "Tier 2 did not PASS the password check"
        fi
    else
        printf '  no Tier 2 / Tier 3 headers found in doctor output\n'
        printf '  full doctor tail:\n'
        tail -30 "$g3_log" | indent
        record G3 FAIL "doctor.sh has no Tier 2 section"
    fi

    # ---------------------------------------------------------------------
    section "G4  auth enforced end-to-end"
    local g4_code
    g4_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:4096/)
    printf '  unauthenticated GET /  ->  http=%s\n' "$g4_code"
    case "$g4_code" in
        401) record G4 PASS "auth enforced (401)" ;;
        200) record G4 FAIL "server answered 200 without credentials" ;;
        *)   record G4 FAIL "unexpected response: $g4_code" ;;
    esac

    # ---------------------------------------------------------------------
    section "summary"
    printf '  run=%d pass=%d fail=%d\n' "$GATES_RUN" "$GATES_PASS" "$GATES_FAIL"
    printf '  drift pattern: %s\n' "$DRIFT_RE"
    printf '  artifacts:     %s\n' "$ART"
    log INFO session END "done" "run=$GATES_RUN" "pass=$GATES_PASS" "fail=$GATES_FAIL"

    if [ "$GATES_FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
