#!/usr/bin/env bash
#
# ffind.sh — file-name search that prefers fd, falls back to find.
#
# fd is installed on the host and is far faster than locate on the slow USB-HDD
# root (no whole-tree index, .gitignore-aware). find stays the fallback (the
# container may lack fd) and remains correct for -delete / -printf / exact
# semantics, so scripts that need those keep calling find directly.
#
#   ./scripts/ffind.sh PATTERN [PATH...]        # fd semantics (substring/regex, respects .gitignore)
#   FFIND_ALL=1 ./scripts/ffind.sh PATTERN      # include ignored + hidden (fd -u -H)
#   ./scripts/ffind.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

self_test() {
    local w fail=0 out
    w=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    printf 'x\n' > "$w/hello_target.txt"
    out=$(bash "${BASH_SOURCE[0]}" hello_target "$w" 2>&1)
    case "$out" in *hello_target.txt*) : ;; *) printf 'FAIL: did not find fixture (%s)\n' "$out"; fail=1 ;; esac
    bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
    [ "$?" -eq 2 ] || { printf 'FAIL: no-arg should exit 2\n'; fail=1; }
    printf 'ffind: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        -h | --help | "") printf 'usage: %s PATTERN [PATH...]   (FFIND_ALL=1 to include ignored/hidden)\n' "$0"; return 2 ;;
    esac
    local pat="$1"; shift
    local paths=("$@")
    [ "${#paths[@]}" -eq 0 ] && paths=(".")
    if have fd; then
        if [ "${FFIND_ALL:-0}" = "1" ]; then
            fd -u -H -- "$pat" "${paths[@]}"
        else
            fd -- "$pat" "${paths[@]}"
        fi
        return $?
    fi
    if have fdfind; then
        if [ "${FFIND_ALL:-0}" = "1" ]; then
            fdfind -u -H -- "$pat" "${paths[@]}"
        else
            fdfind -- "$pat" "${paths[@]}"
        fi
        return $?
    fi
    # fallback: substring match (find has no regex-name; glob approximation)
    find "${paths[@]}" -type f -name "*$pat*" 2>&1
}

main "$@"
