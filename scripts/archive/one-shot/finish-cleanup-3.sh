#!/usr/bin/env bash
#
# finish-cleanup-3.sh — deduplicate the nested scripts/scripts/ tree against
# the destination archive, then remove the nested tree.
#
# Run from: /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
#
# Modes:
#   ./finish-cleanup-3.sh           dry-run
#   ./finish-cleanup-3.sh --apply   perform
#
# For each file in the nested tree:
#   - identical to same-named destination file  -> rm -f (dedup)
#   - different from same-named destination     -> mv with .TIMESTAMP suffix
#   - no same-named destination file            -> mv normally
#
# Constraints honored: no rm -rf, no sed, no 2>/dev/null, no set -e,
# no exit 1, no subprocess.run, no kill without signal.
#
# Citations:
#   cmp(1): "cmp -s ... exit status 0 if inputs are the same, 1 if
#   different, >1 if error"
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#   POSIX rm -f: single-file removal, no recursion without -r
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#   POSIX rmdir: empty directories only
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rmdir.html
#   Shellcheck SC2181: check exit status directly, prefer if cmp; then
#     https://www.shellcheck.net/wiki/SC2181

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

# Counters
n_dedup=0
n_moved=0
n_conflict=0
n_skipped=0

reconcile() {
    local src="$1" dest_dir="$2"
    local name
    name=$(basename "$src")
    local dest="$dest_dir/$name"

    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        # Destination has no file with this name; move normally.
        if [ "$MODE" = "apply" ]; then
            mkdir -p "$dest_dir"
            mv "$src" "$dest"
        fi
        printf '  MOVE     %s\n           -> %s\n' "$src" "$dest"
        n_moved=$((n_moved + 1))
        return 0
    fi

    # Destination exists; compare content.
    if cmp -s "$src" "$dest"; then
        # Byte-identical duplicate. Remove the nested copy.
        if [ "$MODE" = "apply" ]; then
            rm -f "$src"
        fi
        printf '  DEDUP    %s\n           (identical to %s)\n' "$src" "$dest"
        n_dedup=$((n_dedup + 1))
        return 0
    fi

    # Destination exists and differs. Preserve both.
    local suffixed="$dest.$TIMESTAMP"
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$dest_dir"
        mv "$src" "$suffixed"
    fi
    printf '  CONFLICT %s\n           differs from %s\n           -> %s\n' "$src" "$dest" "$suffixed"
    n_conflict=$((n_conflict + 1))
    return 0
}

main() {
    echo "=== finish-cleanup-3.sh ==="
    echo "Mode: $MODE"
    echo ""

    if [ ! -d "$NESTED" ]; then
        echo "  no nested tree at $NESTED"
        return 0
    fi

    echo "=== §1 nested tree contents ==="
    find "$NESTED" -type f 2>&1
    echo ""

    echo "=== §2 reconcile ==="

    # stage scripts
    if [ -d "$NESTED/archive/stage-opencode-repo" ]; then
        for f in "$NESTED/archive/stage-opencode-repo"/*; do
            [ -e "$f" ] || continue
            reconcile "$f" "$STAGE_DEST"
        done
    fi

    # forensics scripts
    if [ -d "$NESTED/archive/forensics" ]; then
        for f in "$NESTED/archive/forensics"/*; do
            [ -e "$f" ] || continue
            reconcile "$f" "$FOREN_DEST"
        done
    fi

    # loose files directly under scripts/scripts/ (excluding archive/)
    for f in "$NESTED"/*; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in
            archive) continue ;;
        esac
        reconcile "$f" "$REPO/scripts"
    done

    echo ""

    echo "=== §3 remove now-empty nested directories ==="
    for d in \
        "$NESTED/archive/stage-opencode-repo" \
        "$NESTED/archive/forensics" \
        "$NESTED/archive" \
        "$NESTED"; do
        if [ -d "$d" ]; then
            if [ "$MODE" = "apply" ]; then
                rmdir "$d" 2>&1
                printf '  rmdir    %s\n' "$d"
            else
                printf '  would rmdir    %s\n' "$d"
            fi
        fi
    done

    echo ""
    echo "=== §4 totals ==="
    echo "  dedup (identical, nested removed): $n_dedup"
    echo "  moved (unique, relocated):          $n_moved"
    echo "  conflict (kept both):               $n_conflict"

    echo ""
    if [ "$MODE" = "dry-run" ]; then
        echo "DRY-RUN. Rerun with --apply to perform."
    else
        echo "APPLIED."
        if [ -d "$NESTED" ]; then
            echo ""
            echo "  WARN: $NESTED still exists. Remaining contents:"
            find "$NESTED" -mindepth 1 -maxdepth 4 2>&1
        else
            echo "  $NESTED removed."
        fi
    fi
}

main
