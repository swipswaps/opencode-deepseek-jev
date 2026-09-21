#!/usr/bin/env bash
# cleanup-all.sh — finish both cleanups from one location.
#
# Run from: /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
#
# Handles:
#   §1 CFG repo cleanup     (parachute-cfd-game_1074)
#   §2 OpenCode repo cleanup (this repo)
#
# Modes:
#   ./cleanup-all.sh            dry-run
#   ./cleanup-all.sh --apply    perform

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) echo "usage: $0 [--apply]"; return 1 ;;
esac

CFG_REPO="$HOME/Documents/69f7bcc6-1f68-83ea-b9b2-95a4db8629ac/parachute-cfd-game_1074"
OPENCODE_REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"

do_rm() {
    local t="$1"; [ -e "$t" ] || [ -L "$t" ] || return 0
    if [ "$MODE" = "apply" ]; then rm -f "$t"; printf '  rm       %s\n' "$t"
    else printf '  would rm       %s\n' "$t"; fi
}

do_rmdir() {
    local t="$1"; [ -d "$t" ] || return 0
    if [ "$MODE" = "apply" ]; then rmdir "$t" 2>&1; printf '  rmdir    %s\n' "$t"
    else printf '  would rmdir    %s\n' "$t"; fi
}

do_mv() {
    local s="$1" d="$2"; [ -e "$s" ] || return 0
    if [ "$MODE" = "apply" ]; then mkdir -p "$(dirname "$d")"; mv "$s" "$d"; printf '  mv       %s -> %s\n' "$s" "$d"
    else printf '  would mv       %s -> %s\n' "$s" "$d"; fi
}

main() {
    echo "=== cleanup-all.sh ==="
    echo "Mode: $MODE"
    echo ""

    echo "=== §1 CFG repo cleanup ==="
    echo "  repo: $CFG_REPO"
    if [ ! -d "$CFG_REPO" ]; then
        echo "  SKIP: not found"
    else
        do_rm "$CFG_REPO/finish-cleanup.sh"
        do_rm "$CFG_REPO/scripts/finish-cleanup.sh"
        do_rm "$CFG_REPO/scripts/finish-cleanup.log"
        do_rmdir "$CFG_REPO/scripts/archive/stage-opencode-repo"
        do_rmdir "$CFG_REPO/scripts/archive/forensics"
        do_rmdir "$CFG_REPO/scripts/archive"
        do_rmdir "$CFG_REPO/scripts"
    fi
    echo ""

    echo "=== §2 OpenCode repo cleanup ==="
    echo "  repo: $OPENCODE_REPO"
    if [ ! -d "$OPENCODE_REPO" ]; then
        echo "  SKIP: not found"
    else
        local stage_arch="$OPENCODE_REPO/scripts/archive/stage-opencode-repo"
        local foren_arch="$OPENCODE_REPO/scripts/archive/forensics"

        if [ "$MODE" = "apply" ]; then
            mkdir -p "$stage_arch" "$foren_arch"
        fi

        # stray scripts at root -> archive
        for name in recover-removed-containers.sh map-removed-containers.sh \
                    investigate-removed-containers.sh interactive-recovery.sh; do
            do_mv "$OPENCODE_REPO/$name" "$foren_arch/$name"
        done
        for name in recovery-report.txt removed-containers.txt recovery-decisions.log; do
            do_mv "$OPENCODE_REPO/$name" "$foren_arch/$name"
        done

        # empty scripts/scripts tree
        do_rmdir "$OPENCODE_REPO/scripts/scripts/archive/stage-opencode-repo"
        do_rmdir "$OPENCODE_REPO/scripts/scripts/archive/forensics"
        do_rmdir "$OPENCODE_REPO/scripts/scripts/archive"
        do_rmdir "$OPENCODE_REPO/scripts/scripts"
    fi

    echo ""
    if [ "$MODE" = "dry-run" ]; then
        echo "DRY-RUN. Rerun with --apply to perform."
    else
        echo "APPLIED. Verify:"
        echo "  ls -la $CFG_REPO"
        echo "  ls -la $OPENCODE_REPO"
        echo "  ls -la $OPENCODE_REPO/scripts/archive/forensics"
    fi
}

main
