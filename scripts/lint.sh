#!/usr/bin/env bash
#
# lint.sh — static checks for repo scripts + generated code, encoding the
# rule set and the recurring failure classes from the session log.
#
#   bash -n         shell syntax (scripts/*.sh, docker/*.sh, one-shots)
#   SC (shellcheck) shell static analysis (if installed)
#   node --check    JS syntax (dashboard.mjs, helpers, page scripts)
#   RULES grep      no `sed`, no `2>/dev/null` in operating scripts (non-comment)
#
# Exit 0 only if every available check passes. shellcheck is optional; its
# absence is reported as SKIP (SKIP is not PASS — see RULES #37).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); printf 'ts=%s level=INFO  status=PASS %s\n' "$(date -u +%H:%M:%S)" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'ts=%s level=ERROR status=FAIL %s\n' "$(date -u +%H:%M:%S)" "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'ts=%s level=WARN  status=SKIP %s\n' "$(date -u +%H:%M:%S)" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

main() {
    local REPO
    REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    printf '=== lint.sh ===\n'
    printf 'repo: %s\n' "$REPO"

    local f err
    for f in "$REPO"/scripts/*.sh "$REPO"/docker/*.sh; do
        [ -f "$f" ] || continue
        err=$(bash -n "$f" 2>&1) && ok "bash -n $(basename "$f")" || { bad "bash -n $(basename "$f")"; printf '%s\n' "$err" | head -4; }
    done

    if have shellcheck; then
        for f in "$REPO"/scripts/*.sh; do
            [ -f "$f" ] || continue
            if shellcheck -S error "$f" >/dev/null; then
                ok "shellcheck $(basename "$f")"
            else
                bad "shellcheck $(basename "$f")"
                shellcheck -S error "$f" | head -6
            fi
        done
    else
        skip 'shellcheck not installed (apt-get install -y shellcheck)'
    fi

    for f in "$REPO"/scripts/*.mjs; do
        [ -f "$f" ] || continue
        if node --check "$f" >/dev/null 2>&1; then
            ok "node --check $(basename "$f")"
        else
            bad "node --check $(basename "$f")"
        fi
    done

    for f in "$REPO"/.opencode/plugins/*.js; do
        [ -f "$f" ] || continue
        if node --check "$f" >/dev/null 2>&1; then
            ok "node --check .opencode/plugins/$(basename "$f")"
        else
            bad "node --check .opencode/plugins/$(basename "$f")"
        fi
    done

    if have python3; then
        for f in "$REPO"/scripts/*.py; do
            [ -f "$f" ] || continue
            if python3 -m py_compile "$f" >/dev/null 2>&1; then
                ok "py_compile $(basename "$f")"
            else
                bad "py_compile $(basename "$f")"
                python3 -m py_compile "$f" 2>&1 | head -4
            fi
        done
    else
        skip 'python3 not installed'
    fi

    local pyv=""
    pyv=$(grep -rnE 'subprocess\.run\s*\(' "$REPO"/scripts/*.py || true)
    if [ -n "$pyv" ]; then
        bad "RULES: subprocess.run in scripts/*.py (use subprocess.Popen)"
        printf '%s\n' "$pyv" | head -5
    else
        ok 'RULES: no subprocess.run in scripts/*.py'
    fi

    if [ -f "$REPO/scripts/scan-constraints.py" ] && have python3; then
        if python3 "$REPO/scripts/scan-constraints.py" "$REPO/scripts" \
                --exclude-dir archive --include '*.sh' --quiet >/dev/null; then
            ok 'scan-constraints: no code-level blacklist hits (scripts/*.sh)'
        else
            bad 'scan-constraints: code-level blacklist hits (scripts/*.sh)'
            python3 "$REPO/scripts/scan-constraints.py" "$REPO/scripts" \
                --exclude-dir archive --include '*.sh' | head -12
        fi
    else
        skip 'scan-constraints.py not available'
    fi

    local v=""
    for f in "$REPO"/scripts/*.sh; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "lint.sh" ] && continue
        v="$v$(grep -nE '2>/dev/null|(^|[^[:alnum:]_])sed([^[:alnum:]_]|$)' "$f" | grep -vE ':[[:space:]]*#' || true)"
    done
    if [ -n "$v" ]; then
        bad "RULES: sed/2>/dev/null in operating scripts"
        printf '%s\n' "$v" | head -5
    else
        ok 'RULES: no sed / 2>/dev/null in scripts/*.sh'
    fi

    printf '\n=== lint result: %d pass, %d fail, %d skip ===\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}

main "$@"
