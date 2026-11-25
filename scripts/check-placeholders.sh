#!/usr/bin/env bash
#
# check-placeholders.sh — gate for rule #99 (no unresolved placeholders in
# copy-paste commands).
#
#   python3 check-placeholders.py --self-test   detector discriminates
#   python3 check-placeholders.py --db ...      no NEW assistant shell fence
#                                                carries <token>/YOUR_TOKEN
#
# The DB scan is cursor-based (logs/placeholder-cursor). Accepted historical
# findings are listed explicitly in scripts/placeholder-baseline.json; the
# cursor is NOT advanced by this wrapper, so new messages keep being scanned
# and only unlisted violations fail. Advancing the cursor is a separate,
# human-reviewed action (PLACEHOLDER_ADVANCE=1) after reviewing the findings.
# This enforces rule #99 for future turns without rewriting the past.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
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

main() {
    local repo tool rc cursor baseline
    repo=$(resolve_repo "$(pwd)")
    [ -n "$repo" ] || repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    tool="$repo/scripts/check-placeholders.py"
    cursor="$repo/logs/placeholder-cursor"

    printf '=== check-placeholders.sh ===\n'
    printf 'repo: %s\n' "$repo"

    if [ ! -f "$tool" ]; then
        printf 'status=FAIL missing %s\n' "$tool"
        printf '=== result: FAIL check-placeholders (tool missing)\n'
        return 1
    fi

    python3 "$tool" --self-test
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '=== result: FAIL check-placeholders (self-test)\n'
        return 1
    fi

    mkdir -p "$repo/logs"
    baseline="$repo/scripts/placeholder-baseline.json"
    if [ "${PLACEHOLDER_ADVANCE:-0}" = "1" ]; then
        python3 "$tool" --db --cursor "$cursor" --baseline "$baseline" --advance
    else
        python3 "$tool" --db --cursor "$cursor" --baseline "$baseline"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'fix: replace the token with a resolved value, or print the lookup command first\n'
        printf '=== result: FAIL check-placeholders (db scan)\n'
        return 1
    fi

    printf '=== result: PASS check-placeholders\n'
    return 0
}

main "$@"
