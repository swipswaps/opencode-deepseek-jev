#!/usr/bin/env bash
#
# check-placeholders.sh — gate for rule #99 (no unresolved placeholders in
# copy-paste commands).
#
#   python3 check-placeholders.py --self-test   detector discriminates
#   python3 check-placeholders.py --db ...      no NEW assistant shell fence
#                                                carries <token>/YOUR_TOKEN
#
# The DB scan is cursor-based (logs/placeholder-cursor). The first run
# baselines at the newest part so history is not retroactively red; every run
# after that fails on a new violation, and only a clean run advances the
# cursor. This makes the rule enforced for future turns without rewriting the
# past (RULES #99).
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
    local repo tool rc cursor
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
    python3 "$tool" --db --cursor "$cursor" --advance
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
