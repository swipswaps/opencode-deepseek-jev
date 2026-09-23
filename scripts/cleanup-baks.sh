#!/usr/bin/env bash
#
# cleanup-baks.sh — list or remove the *.bak.* snapshot files that
# accumulate during script iteration.
#
# Two categories (both matched by *.bak.*):
#   env-backups   .env.local.bak.*  stale API keys — should be removed
#   code-backups  *.bak.*           script snapshots — safe to remove
#
# Modes:
#   (default)      list only — count, size, and paths; no changes
#   --apply        add *.bak.* to .gitignore, then remove every *.bak.*
#   -h|--help      usage
#
# Removal uses `rm -f` on named files only (never `rm -rf`).
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

section() { printf '\n=== %s ===\n' "$1"; }

usage() {
    printf 'usage: %s [--list|--apply]\n' "$(basename "$0")"
    printf '  (default)  list *.bak.* files, no changes\n'
    printf '  --apply    gitignore *.bak.* and remove them\n'
}

scan() {
    local count env_count code_count total
    count=$(find "$REPO" -type f -name '*.bak.*' | wc -l | tr -d ' ')
    env_count=$(find "$REPO" -type f -name '.env.local.bak.*' | wc -l | tr -d ' ')
    code_count=$((count - env_count))
    total=$(find "$REPO" -type f -name '*.bak.*' -printf '%s\n' | awk '{s+=$1} END{print s+0}')

    printf 'total:  %s files (%s bytes)\n' "$count" "$total"
    printf '  env-backups  (.env.local.bak.*): %s\n' "$env_count"
    printf '  code-backups (*.bak.*):          %s\n' "$code_count"
    [ "$count" -gt 0 ]
}

list_paths() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '  %s\n' "${f#$REPO/}"
    done < <(find "$REPO" -type f -name '*.bak.*' | sort)
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local mode="list"
    case "${1:-}" in
        --apply) mode="apply" ;;
        --list|"") mode="list" ;;
        -h|--help) usage; return 0 ;;
        *) usage; return 2 ;;
    esac

    printf '=== cleanup-baks.sh ===\n'
    printf 'Repo: %s\n' "$REPO"
    section "scan"

    if ! scan; then
        printf 'nothing to do\n'
        return 0
    fi

    if [ "$mode" = "list" ]; then
        section "files (run --apply to remove)"
        list_paths
        return 0
    fi

    section "apply"

    if [ -f "$REPO/.gitignore" ] && ! grep -q '^\*\.bak\.\*$' "$REPO/.gitignore"; then
        printf '*.bak.*\n' >> "$REPO/.gitignore"
        printf 'added *.bak.* to .gitignore\n'
    else
        printf '.gitignore already ignores *.bak.*\n'
    fi

    local removed=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f"
        removed=$((removed + 1))
    done < <(find "$REPO" -type f -name '*.bak.*')

    printf 'removed %s files\n' "$removed"
    return 0
}

main "$@"
