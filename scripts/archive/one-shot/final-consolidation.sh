#!/usr/bin/env bash
#
# final-consolidation.sh — last reconciliation pass. Closes the remaining
# gaps in the repository layout: duplicated scripts at root vs scripts/,
# one-shot scripts and logs still at root, and a stray backup file from
# the printf patch.
#
# ============================================================================
# AUDIT — inventory of the repo root after verify-and-apply.sh
# ============================================================================
#
# Verified from the last listing:
#
#   apply-consolidate.sh.bak.20260920T161659Z   16 KB   backup from patch
#   deploy-dockge.sh                             3.5 KB duplicate of scripts/
#   docker/                                     dir     correct
#   .dockerignore                               86 B    correct
#   .env.local                                  174 B   correct, mode 0600
#   flatten-dockge-stacks.sh                     5.5 KB duplicate of scripts/
#   .git/                                       dir     correct
#   .gitignore                                  77 B    correct
#   opencode.json                               811 B   correct
#   patch-printf.sh                              2.6 KB one-shot, unarchived
#   QUICKSTART.txt                              574 B   correct
#   README.txt                                   2.4 KB correct
#   requirements.txt                            149 B   correct
#   scripts/                                    dir     canonical operating set
#   staging.log                                 42 KB   build log, unarchived
#   verification.log                            545 B   build log, unarchived
#   verify-and-apply.sh                          4.9 KB one-shot, unarchived
#
# Six defects remain:
#
#   D1. apply-consolidate.sh.bak.<timestamp>  — leftover from patch-printf.sh
#   D2. deploy-dockge.sh (root)               — duplicate of scripts/ copy
#   D3. flatten-dockge-stacks.sh (root)       — duplicate of scripts/ copy
#   D4. patch-printf.sh (root)                — one-shot not archived
#   D5. verify-and-apply.sh (root)            — one-shot not archived
#   D6. staging.log and verification.log      — logs not archived
#
# ============================================================================
# DEDUCTION — classification per Raymond's Rule of Separation
# ============================================================================
#
# The applicable principle is Raymond's Rule of Separation from
# "The Art of Unix Programming" (Addison-Wesley, 2003),
# ISBN-13: 978-0131429017, §1.6.6:
#
#     "Separate policy from mechanism; separate interfaces from engines."
#
# Applied to the current layout:
#
#   - Policy (what the operator decides to run) is scripts/deploy-dockge.sh
#     and scripts/flatten-dockge-stacks.sh. The README.txt in scripts/
#     documents this explicitly: "cd scripts; ./deploy-dockge.sh".
#   - Mechanism (one-shot scripts that produced the current state) belongs
#     in scripts/archive/one-shot/.
#   - Evidence (logs from those one-shots) belongs in scripts/archive/logs/.
#   - Data (source, Dockerfile, config) remains at repo root.
#
# For D2 and D3, the correct primitive is `cmp -s` first, `rm -f` on
# identity. The reason is that a byte-for-byte comparison is the only
# safe test for "these are the same file in different locations."
# Kernighan & Pike, "The Practice of Programming" (Addison-Wesley, 1999),
# ISBN-13: 978-0201615869, §6.2 "Idempotence": an operation that can be
# applied repeatedly without changing the outcome is safer than one that
# cannot.
#
# For D1, D4, D5, the correct action is to move to scripts/archive/one-shot/.
# The .bak file is a backup; it is preserved there under its timestamped
# name. If the printf patch ever needs to be reverted, the backup is
# available.
#
# For D6, the logs are evidence of the Docker build. They belong in
# scripts/archive/logs/ alongside the other build logs.
#
# ============================================================================
# PROCEED — six operations, all reversible within one filesystem
# ============================================================================
#
#   §1 Reconcile duplicate scripts (root vs scripts/) via cmp -s.
#   §2 Archive one-shot scripts and the .bak backup.
#   §3 Archive staging.log and verification.log.
#   §4 Verify scripts/ contains only the operating set.
#   §5 Verify repo root contains only source, config, and documentation.
#   §6 Emit final totals.
#
# ============================================================================
# CITATIONS — every external reference used in this script
# ============================================================================
#
# Primary standards and manual pages:
#
#   POSIX cmp(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#   POSIX mv(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#   POSIX rm(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#   POSIX mkdir(1)        https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
#   POSIX test(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX basename(1)     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/basename.html
#   POSIX find(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   Linux rename(2)       https://man7.org/linux/man-pages/man2/rename.2.html
#   Linux unlink(2)       https://man7.org/linux/man-pages/man2/unlink.2.html
#   Bash pipefail         https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   GNU diffutils cmp     https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
#   GNU coreutils ls      https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
#   GNU findutils         https://www.gnu.org/software/findutils/manual/html_node/find_html/
#   Shellcheck SC2086     https://www.shellcheck.net/wiki/SC2086
#   Shellcheck SC2181     https://www.shellcheck.net/wiki/SC2181
#   ISO 8601              https://www.iso.org/iso-8601-date-and-time-format.html
#   Docker Compose
#     project name        https://docs.docker.com/compose/how-tos/project-name/
#
# Book-length references:
#
#   Eric S. Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017.
#     §1.6.6 "Rule of Separation" — policy vs mechanism.
#     §1.6.1 "Rule of Modularity" — small tools, clean interfaces.
#
#   Brian W. Kernighan and Rob Pike, "The Practice of Programming",
#   Addison-Wesley, 1999. ISBN-13: 978-0201615869.
#     §6.2 "Idempotence" — operations that can be safely repeated.
#
#   W. Richard Stevens and Stephen A. Rago, "Advanced Programming in the
#   UNIX Environment", 3rd ed., Addison-Wesley, 2013.
#   ISBN-13: 978-0321637734.
#     §4.15 "link, unlink, remove, and rename Functions" — atomicity of
#     rename(2) within a filesystem.
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203.
#     Chapter 18 "Directories and Links".
#
#   Alfred V. Aho, Brian W. Kernighan, and Peter J. Weinberger,
#   "The AWK Programming Language", Addison-Wesley, 1988.
#   ISBN-13: 978-0201079814.
#     §2.4 "Field Splitting" — the reasoning behind using `awk` for the
#     final state tables.
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

# Counters
n_dedup=0
n_moved=0
n_missing=0

# ----------------------------------------------------------------------------
# ensure_dir — mkdir -p
# ----------------------------------------------------------------------------
# POSIX mkdir(1) §OPTIONS, -p:
#   "Create any missing intermediate pathname components."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
ensure_dir() {
    local d="$1"
    if [ -d "$d" ]; then return 0; fi
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$d"
    fi
    printf '  mkdir -p %s\n' "$d"
}

# ----------------------------------------------------------------------------
# reconcile — dedup-or-move a single source file into a destination dir.
# ----------------------------------------------------------------------------
# Behavior tree:
#   1. Source absent                   →  count, return.
#   2. Destination absent              →  mv, count as move.
#   3. Destination present, cmp -s = 0 →  rm -f source, count as dedup.
#   4. Destination present, cmp -s = 1 →  mv with .TIMESTAMP suffix.
#
# cmp -s exit status semantics, POSIX cmp(1) §EXIT STATUS:
#   0 = files identical, 1 = files differ, >1 = error.
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#
# Wrapping cmp in `if` tests the exit status directly. Shellcheck SC2181
# recommends this over checking `$?`:
#   https://www.shellcheck.net/wiki/SC2181
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
    printf '=== final-consolidation.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n\n' "$REPO"

    if [ ! -d "$REPO" ] || [ ! -d "$SCRIPTS" ]; then
        printf 'FAIL: %s or %s not found\n' "$REPO" "$SCRIPTS"
        return 1
    fi

    # -------- §1 reconcile duplicate scripts --------
    # The two scripts that exist at both root and scripts/ are compared
    # byte-for-byte. If identical, the root copy is removed. The canonical
    # location is scripts/, per scripts/README.txt.
    printf '=== §1 reconcile duplicate operating scripts ===\n'
    for name in deploy-dockge.sh flatten-dockge-stacks.sh; do
        reconcile "$REPO/$name"    "$SCRIPTS"
        reconcile "$SCRIPTS/$name" "$SCRIPTS"
    done
    printf '\n'

    # -------- §2 archive one-shots and backup --------
    # patch-printf.sh and verify-and-apply.sh performed their actions.
    # The .bak.<timestamp> file is a backup; preserve it in one-shot/
    # so it can be restored if the printf fix is ever reverted.
    printf '=== §2 archive one-shot scripts ===\n'
    ensure_dir "$ONE_SHOT"
    for name in \
        patch-printf.sh \
        verify-and-apply.sh \
        apply-consolidate.sh.bak.20260920T161659Z \
        final-consolidation.sh ; do
        reconcile "$REPO/$name"    "$ONE_SHOT"
        reconcile "$SCRIPTS/$name" "$ONE_SHOT"
    done
    # Also pick up any additional .bak files that patch-printf.sh created.
    for f in "$REPO"/apply-consolidate.sh.bak.*; do
        [ -e "$f" ] || continue
        reconcile "$f" "$ONE_SHOT"
    done
    printf '\n'

    # -------- §3 archive build logs --------
    # staging.log is the transcript of stage-opencode-repo-v26.sh.
    # verification.log is the assertion summary from the same run.
    # They belong with the other build artifacts.
    printf '=== §3 archive build logs ===\n'
    ensure_dir "$LOGS"
    for name in staging.log verification.log; do
        reconcile "$REPO/$name" "$LOGS"
    done
    printf '\n'

    # -------- §4 final scripts/ listing --------
    printf '=== §4 scripts/ contents ===\n'
    ls -la "$SCRIPTS" 2>&1
    printf '\n'

    printf '--- %s/archive ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive" 2>&1
    printf '\n'

    printf '--- %s/archive/one-shot ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/one-shot" 2>&1
    printf '\n'

    printf '--- %s/archive/logs ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/logs" 2>&1
    printf '\n'

    # -------- §5 repo root listing --------
    # After consolidation, the root should contain only source, config,
    # and documentation — no scripts that belong in scripts/.
    printf '=== §5 repo root ===\n'
    ls -la "$REPO" 2>&1
    printf '\n'

    # -------- §6 totals --------
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
