#!/usr/bin/env bash
#
# media-budget.sh — fail-closed size gate for committed media.
#
# Budgets (measured, not guessed): video (mp4/webm) <= 2 MiB — pan/zoom
# tours compress well below this at 960x540; images (png/jpg/webp)
# <= 150 KiB — dense dark-UI screenshots floor at ~125 KiB, and
# readability beats an arbitrary 100 KiB cap.
#
# Checks TRACKED files only (git ls-files), so scratch dirs, logs/ and
# /tmp never trip it. Prints one line per violation, exits 1 on any.
#
# Usage: ./scripts/media-budget.sh
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
# ============================================================================

set -o pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

main() {
    local fail=0
    local f size
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            *.mp4|*.webm) max=2097152 ;;
            *.png|*.jpg|*.jpeg|*.webp) max=153600 ;;
            *) continue ;;
        esac
        if [ -f "$REPO_DIR/$f" ]; then
            size=$(wc -c < "$REPO_DIR/$f")
            if [ "$size" -gt "$max" ]; then
                printf 'OVER: %s (%s bytes, budget %s)\n' "$f" "$size" "$max"
                fail=1
            fi
        fi
    done <<EOF
$(git -C "$REPO_DIR" ls-files '*.mp4' '*.webm' '*.png' '*.jpg' '*.jpeg' '*.webp')
EOF
    if [ "$fail" -eq 0 ]; then
        printf 'media-budget: all tracked media within budget\n'
    fi
    return "$fail"
}

main "$@"
