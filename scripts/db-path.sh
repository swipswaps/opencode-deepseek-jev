#!/usr/bin/env bash
#
# db-path.sh — one resolver for the opencode SQLite database.
#
# WHY: scripts hardcoded $REPO/data/opencode/opencode.db. The host has that
# path, but the opencode-web container mounts the real store at
# ~/.local/share/opencode/opencode.db. One resolver keeps every reader on the
# same file instead of failing closed on a path that only exists on one side.
#
#   ./scripts/db-path.sh            # first existing candidate
#   ./scripts/db-path.sh --exists   # exit 0 if any candidate exists
#   ./scripts/db-path.sh --list     # candidates in precedence order
#   ./scripts/db-path.sh --self-test
#
# Precedence: --db PATH · OPENCODE_DB · $REPO/data/opencode/opencode.db ·
#   $XDG_DATA_HOME/opencode/opencode.db · $HOME/.local/share/opencode/opencode.db ·
#   /home/node/.local/share/opencode/opencode.db · /home/owner/... (last resort).
# When none exists, prints the repo path so callers see the intended location.
#
# Constraints: no stream editor, no stderr-to-null, no set -e, no top-level
#   exit, no recursive delete, printf only, main() wrapper.

set -o pipefail

REPO=""

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

candidates() {
    [ -n "$DB_OVERRIDE" ] && printf '%s\n' "$DB_OVERRIDE"
    [ -n "${OPENCODE_DB:-}" ] && printf '%s\n' "$OPENCODE_DB"
    [ "${DB_PATH_STRICT:-0}" = "1" ] && return 0
    [ -n "$REPO" ] && printf '%s\n' "$REPO/data/opencode/opencode.db"
    [ -n "${XDG_DATA_HOME:-}" ] && printf '%s\n' "$XDG_DATA_HOME/opencode/opencode.db"
    [ -n "${HOME:-}" ] && printf '%s\n' "$HOME/.local/share/opencode/opencode.db"
    printf '%s\n' /home/node/.local/share/opencode/opencode.db
    printf '%s\n' /home/owner/.local/share/opencode/opencode.db
}

resolve_db() {
    local c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done < <(candidates)
    [ -n "$REPO" ] && printf '%s' "$REPO/data/opencode/opencode.db"
    return 0
}

self_test() {
    local work fails=0 out want
    work=$(mktemp -d "${TMPDIR:-/tmp}/dbpath.XXXXXX" 2>&1) || {
        printf 'FAIL mktemp\n'; return 1; }
    mkdir -p "$work/repo/docker" "$work/xdg/opencode" "$work/home/.local/share/opencode"
    printf '{}\n' > "$work/repo/opencode.json"
    printf 'FROM scratch\n' > "$work/repo/docker/Dockerfile"
    printf 'db\n' > "$work/xdg/opencode/opencode.db"
    printf 'db\n' > "$work/home/.local/share/opencode/opencode.db"

    DB_OVERRIDE="$work/xdg/opencode/opencode.db"
    out=$(OPENCODE_DB= bash "${BASH_SOURCE[0]}" --db "$DB_OVERRIDE" 2>&1)
    [ "$out" = "$DB_OVERRIDE" ] && printf 'PASS explicit override\n' || {
        printf 'FAIL explicit override (%s)\n' "$out"; fails=$((fails + 1)); }

    DB_OVERRIDE=""
    out=$(OPENCODE_DB= XDG_DATA_HOME="$work/xdg" HOME="$work/home" \
        bash "${BASH_SOURCE[0]}" 2>&1)
    want="$work/xdg/opencode/opencode.db"
    [ "$out" = "$want" ] && printf 'PASS XDG before HOME\n' || {
        printf 'FAIL XDG before HOME (%s)\n' "$out"; fails=$((fails + 1)); }

    OPENCODE_DB="$work/xdg/opencode/opencode.db" bash "${BASH_SOURCE[0]}" --exists
    [ "$?" -eq 0 ] && printf 'PASS --exists found\n' || {
        printf 'FAIL --exists found\n'; fails=$((fails + 1)); }
    DB_PATH_STRICT=1 OPENCODE_DB="$work/nope.db" bash "${BASH_SOURCE[0]}" --exists
    [ "$?" -eq 1 ] && printf 'PASS --exists missing\n' || {
        printf 'FAIL --exists missing\n'; fails=$((fails + 1)); }

    find "$work" -depth -delete 2>&1
    if [ "$fails" -eq 0 ]; then printf 'self-test: PASS\n'; return 0; fi
    printf 'self-test: FAIL (%s)\n' "$fails"
    return 1
}

main() {
    local mode="print"
    while [ $# -gt 0 ]; do
        case "$1" in
            --db) DB_OVERRIDE="${2:-}"; shift 2 ;;
            --db=*) DB_OVERRIDE="${1#--db=}"; shift ;;
            --exists) mode="exists"; shift ;;
            --list) mode="list"; shift ;;
            --self-test) self_test; return $? ;;
            -h|--help) printf 'usage: %s [--db PATH] [--exists] [--list] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--db PATH] [--exists] [--list] [--self-test]\n' "$0"; return 2 ;;
        esac
    done
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    case "$mode" in
        list) candidates; return 0 ;;
        exists)
            local d
            d=$(resolve_db)
            [ -f "$d" ] && return 0
            return 1 ;;
        *) resolve_db; printf '\n' ;;
    esac
}

main "$@"
