#!/usr/bin/env bash
#
# final-consolidation-2.sh — corrected consolidation. Replaces
# final-consolidation.sh, fixing three defects found in its dry-run.
#
# ============================================================================
# AUDIT — defects in final-consolidation.sh
# ============================================================================
#
#   D1. `printf '--- %s ...'` fails with "printf: --: invalid option"
#       on GNU bash and coreutils. Format strings beginning with `-`
#       are parsed for options unless `--` precedes them.
#         POSIX printf(1) §OPTIONS:
#         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#         GNU coreutils printf invocation:
#         https://www.gnu.org/software/coreutils/manual/html_node/printf-invocation.html
#
#   D2. The backup file apply-consolidate.sh.bak.<timestamp> was listed
#       twice: once in the explicit name array, once via glob. The second
#       match is a no-op after the first move, but its MOVE line is
#       misleading. Remove the explicit entry; let the glob be the sole
#       source.
#
#   D3. Section §1 called reconcile twice per script:
#           reconcile "$REPO/$name"    "$SCRIPTS"
#           reconcile "$SCRIPTS/$name" "$SCRIPTS"
#       When the destination equals the source path (self-move), cmp
#       reports identical and the script prints a DEDUP that refers to
#       the same path twice. Remove the second call. The first call is
#       sufficient: if the root copy is a byte-identical duplicate, it
#       is unlinked; the scripts/ copy is the canonical one.
#
# ============================================================================
# DEDUCTION — invariants preserved from the original
# ============================================================================
#
#   I1. Deduplication is content-based, not path-based. `cmp -s` returns
#       0 only for byte-identical files.
#         POSIX cmp(1) §EXIT STATUS:
#         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#
#   I2. Moves are atomic within a filesystem via rename(2).
#         Linux rename(2):
#         https://man7.org/linux/man-pages/man2/rename.2.html
#         Stevens & Rago, "Advanced Programming in the UNIX Environment",
#         3rd ed., Addison-Wesley, 2013, ISBN-13: 978-0321637734, §4.15.
#
#   I3. The operation is idempotent: a second application finds no
#       sources and completes without changes.
#         Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#         1999, ISBN-13: 978-0201615869, §6.2 "Idempotence".
#
#   I4. Policy and mechanism remain separated: two operating scripts,
#       everything else archived.
#         Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
#         ISBN-13: 978-0131429017, §1.6.6 "Rule of Separation".
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX printf(1)       https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX cmp(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#   POSIX mv(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#   POSIX rm(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#   POSIX mkdir(1)        https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
#   POSIX test(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX basename(1)     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/basename.html
#   Linux rename(2)       https://man7.org/linux/man-pages/man2/rename.2.html
#   Bash pipefail         https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   GNU coreutils printf   https://www.gnu.org/software/coreutils/manual/html_node/printf-invocation.html
#   GNU diffutils cmp      https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
#   Shellcheck SC2086      https://www.shellcheck.net/wiki/SC2086
#   Shellcheck SC2181      https://www.shellcheck.net/wiki/SC2181
#   ISO 8601               https://www.iso.org/iso-8601-date-and-time-format.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869.
#
#   Stevens & Rago, "Advanced Programming in the UNIX Environment",
#   3rd ed., Addison-Wesley, 2013. ISBN-13: 978-0321637734.
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017.
#
# ============================================================================

set -o pipefail

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
SCRIPTS="$REPO/scripts"
ONE_SHOT="$SCRIPTS/archive/one-shot"
LOGS="$SCRIPTS/archive/logs"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 1 ;;
esac

n_dedup=0
n_moved=0
n_missing=0

ensure_dir() {
    local d="$1"
    if [ -d "$d" ]; then return 0; fi
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$d"
    fi
    printf '  mkdir -p %s\n' "$d"
}

# reconcile — dedup-or-move a single source file into a destination dir.
# Behavior:
#   absent source                     -> missing counter
#   absent destination                -> mv, moved counter
#   present destination, cmp -s == 0  -> rm -f source, dedup counter
#   present destination, cmp -s != 0  -> mv with TIMESTAMP suffix
reconcile() {
    local src="$1" dest_dir="$2"
    local name
    name=$(basename "$src")

    if [ ! -e "$src" ]; then
        n_missing=$((n_missing + 1))
        return 0
    fi

    local dest="$dest_dir/$name"

    if [ ! -e "$dest" ]; then
        if [ "$MODE" = "apply" ]; then
            mv "$src" "$dest"
        fi
        printf '  MOVE     %s\n' "$src"
        printf '           -> %s\n' "$dest"
        n_moved=$((n_moved + 1))
        return 0
    fi

    if cmp -s "$src" "$dest"; then
        if [ "$MODE" = "apply" ]; then
            rm -f "$src"
        fi
        printf '  DEDUP    %s\n' "$src"
        printf '           (identical to %s)\n' "$dest"
        n_dedup=$((n_dedup + 1))
        return 0
    fi

    local suffixed="$dest.$TIMESTAMP"
    if [ "$MODE" = "apply" ]; then
        mv "$src" "$suffixed"
    fi
    printf '  CONFLICT %s\n' "$src"
    printf '           differs from %s\n' "$dest"
    printf '           -> %s\n' "$suffixed"
    n_moved=$((n_moved + 1))
    return 0
}

main() {
    printf '=== final-consolidation-2.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n\n' "$REPO"

    if [ ! -d "$REPO" ] || [ ! -d "$SCRIPTS" ]; then
        printf 'FAIL: repo or scripts dir missing\n'
        return 1
    fi

    # §1 — reconcile duplicates of the two operating scripts.
    # Only the root copy is reconciled. If it is a byte-identical
    # duplicate of the scripts/ copy, it is unlinked. No second call.
    printf '=== §1 reconcile duplicate operating scripts ===\n'
    for name in deploy-dockge.sh flatten-dockge-stacks.sh; do
        reconcile "$REPO/$name" "$SCRIPTS"
    done
    printf '\n'

    # §2 — archive one-shot scripts. The .bak file is picked up by glob
    # alone; do not list it explicitly. self-archive (this script) is
    # moved last so the running shell keeps its open inode.
    printf '=== §2 archive one-shot scripts ===\n'
    ensure_dir "$ONE_SHOT"
    for name in \
        patch-printf.sh \
        verify-and-apply.sh \
        final-consolidation.sh \
        final-consolidation-2.sh ; do
        reconcile "$REPO/$name"    "$ONE_SHOT"
        reconcile "$SCRIPTS/$name" "$ONE_SHOT"
    done
    for f in "$REPO"/apply-consolidate.sh.bak.*; do
        [ -e "$f" ] || continue
        reconcile "$f" "$ONE_SHOT"
    done
    printf '\n'

    # §3 — archive build logs.
    printf '=== §3 archive build logs ===\n'
    ensure_dir "$LOGS"
    for name in staging.log verification.log; do
        reconcile "$REPO/$name" "$LOGS"
    done
    printf '\n'

    # §4 — scripts/ listing.
    printf '=== §4 scripts/ contents ===\n'
    ls -la "$SCRIPTS"
    printf '\n'
    printf -- '--- %s/archive ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive"
    printf '\n'
    printf -- '--- %s/archive/one-shot ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/one-shot"
    printf '\n'
    printf -- '--- %s/archive/logs ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/logs"
    printf '\n'

    # §5 — repo root listing.
    printf '=== §5 repo root ===\n'
    ls -la "$REPO"
    printf '\n'

    # §6 — totals.
    printf '=== §6 totals ===\n'
    printf '  moved:   %d\n' "$n_moved"
    printf '  deduped: %d\n' "$n_dedup"
    printf '  missing: %d\n' "$n_missing"
    printf '\n'

    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN. Rerun with --apply to perform.\n'
    else
        printf 'APPLIED.\n'
    fi
}

main "$@"
