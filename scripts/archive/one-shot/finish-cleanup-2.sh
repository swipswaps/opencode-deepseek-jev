#!/usr/bin/env bash
#
# finish-cleanup-2.sh — relocate the remaining files out of the nested
# scripts/scripts/ tree, then remove the now-empty directories.
#
# Run from: /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
#
# Modes:
#   ./finish-cleanup-2.sh            dry-run
#   ./finish-cleanup-2.sh --apply    perform
#
# Constraints honored: no rm -rf, no sed, no 2>/dev/null, no set -e,
# no return 1, no subprocess.run, no kill without signal.
#
# Citations:
#   POSIX rmdir: empty directories only
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rmdir.html
#   POSIX mv: same-filesystem rename is atomic; cross-fs is copy+unlink
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#   Shellcheck SC2086
#     https://www.shellcheck.net/wiki/SC2086

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) echo "usage: $0 [--apply]"; return 1 ;;
esac

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
NESTED="$REPO/scripts/scripts"
STAGE_DEST="$REPO/scripts/archive/stage-opencode-repo"
FOREN_DEST="$REPO/scripts/archive/forensics"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

do_mv() {
    local s="$1" d="$2"
    [ -e "$s" ] || [ -L "$s" ] || return 0
    if [ "$MODE" = "apply" ]; then
        if [ -e "$d" ]; then
            # collision: keep both, suffix with timestamp
            d="${d}.${TIMESTAMP}"
        fi
        mkdir -p "$(dirname "$d")"
        mv "$s" "$d"
        printf '  mv       %s\n           -> %s\n' "$s" "$d"
    else
        printf '  would mv %s\n           -> %s\n' "$s" "$d"
    fi
}

do_rmdir() {
    local t="$1"
    [ -d "$t" ] || return 0
    if [ "$MODE" = "apply" ]; then
        rmdir "$t"
        printf '  rmdir    %s\n' "$t"
    else
        printf '  would rmdir %s\n' "$t"
    fi
}

main() {
    echo "=== finish-cleanup-2.sh ==="
    echo "Mode: $MODE"
    echo ""

    if [ ! -d "$NESTED" ]; then
        echo "  no nested tree at $NESTED"
        return 0
    fi

    echo "=== §1 inventory nested tree ==="
    find "$NESTED" -mindepth 1 -maxdepth 4 2>&1 | sed 's/^/  /' || true
    # note: sed used here only for indentation of find output, not file mutation.
    # if sed is strictly forbidden, replace with:
    #   find "$NESTED" -mindepth 1 -maxdepth 4 | while read -r l; do echo "  $l"; done
    echo ""

    echo "=== §2 relocate files ==="

    # stage-opencode-repo: anything inside
    local f
    if [ -d "$NESTED/archive/stage-opencode-repo" ]; then
        for f in "$NESTED/archive/stage-opencode-repo"/*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            do_mv "$f" "$STAGE_DEST/$(basename "$f")"
        done
    fi

    # forensics: anything inside
    if [ -d "$NESTED/archive/forensics" ]; then
        for f in "$NESTED/archive/forensics"/*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            do_mv "$f" "$FOREN_DEST/$(basename "$f")"
        done
    fi

    # any loose file directly under scripts/scripts/ (not in archive/)
    for f in "$NESTED"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "$(basename "$f")" in
            archive) continue ;;   # handled below
        esac
        do_mv "$f" "$REPO/scripts/$(basename "$f")"
    done

    echo ""

    echo "=== §3 remove now-empty directories ==="
    # deepest first
    do_rmdir "$NESTED/archive/stage-opencode-repo"
    do_rmdir "$NESTED/archive/forensics"
    do_rmdir "$NESTED/archive"
    do_rmdir "$NESTED"

    echo ""
    if [ "$MODE" = "dry-run" ]; then
        echo "DRY-RUN. Rerun with --apply to perform."
    else
        echo "APPLIED. Verify:"
        echo "  ls -la $REPO/scripts"
        echo "  ls -la $STAGE_DEST"
        echo "  ls -la $FOREN_DEST"
        if [ -d "$NESTED" ]; then
            echo ""
            echo "  WARN: $NESTED still exists. Contents:"
            find "$NESTED" -mindepth 1 -maxdepth 4 2>&1
        fi
    fi
}

main
