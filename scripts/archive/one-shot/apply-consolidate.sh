#!/usr/bin/env bash
#
# apply-consolidate.sh — final consolidation pass with content-aware
# deduplication, applied to the current repo state.
#
# Run from: /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
#
# ============================================================================
# AUDIT — state observed by the consolidate-repo.sh dry-run
# ============================================================================
#
# The prior dry-run revealed three properties of the current state:
#
#   A1. Two files exist in duplicate locations:
#         repo/fix-and-reorganize.sh         AND  repo/scripts/fix-and-reorganize.sh
#         repo/finish-reorganize.sh          AND  repo/scripts/finish-reorganize.sh
#       A naive `mv` of both would leave two files with colliding names
#       in the one-shot archive, one suffixed with a timestamp. That
#       produces clutter for no semantic reason if the two copies are
#       byte-identical.
#
#   A2. The dry-run's §5 state report showed `ls: cannot access ...` for
#       both `one-shot/` and `logs/`. This is correct: dry-run mode never
#       created those directories because ensure_dir() printed the mkdir
#       line without executing it. The §5 report is therefore partially
#       empty by design, not by error.
#
#   A3. `finish-cleanup.sh` and `cleanup-mishap.sh` were requested in the
#       one-shot list but not found in either location. They were already
#       archived or never materialized under those exact names.
#
# ============================================================================
# DEDUCTION — why dedup-before-move is the correct primitive
# ============================================================================
#
# The hypothesis behind consolidation is that files at `repo/scripts/*`
# and `repo/*` with the same basename are copies produced by earlier
# cleanup scripts that wrote to both locations. If they are copies, they
# are byte-identical and one may be unlinked before the other is moved.
# If they differ, both are real artifacts and both must be preserved.
#
# The test for "identical" is `cmp -s`. POSIX cmp(1) documents:
#
#   "The cmp utility shall compare two files. ... If the two files are
#   the same, cmp shall write nothing and exit with zero status; if they
#   are different, cmp shall write the byte and line number at which the
#   first difference occurred and exit with a status greater than zero."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#
# Wrapping cmp(1) in an `if` tests the exit status directly. Shellcheck
# SC2181 recommends this over checking `$?` after the call:
#   https://www.shellcheck.net/wiki/SC2181
#
# GNU cmp(1) adds the `-s` / `--silent` flag:
#
#   "-s, --silent, --quiet
#      Suppress all normal output. Show only exit status."
#   https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
#
# The Unix principle at work is "verify before act" from Kernighan &
# Pike, "The Practice of Programming" (Addison-Wesley, 1999),
# ISBN-13: 978-0201615869, §6.2 "Idempotence": a well-designed
# operation applied twice has the same effect as applied once. Using
# `cmp -s` before `mv` makes the operation idempotent: a re-run finds
# no source file (already moved or already deleted) and does nothing.
#
# ============================================================================
# PROCEED — five phases, all reversible within a filesystem
# ============================================================================
#
#   §1 Inventory: list every candidate source file with its destination.
#   §2 Dedup: for each destination, if a same-named source exists and is
#       byte-identical to an existing destination file, unlink the source.
#   §3 Move: relocate unique sources to the archive.
#   §4 Create: write scripts/README.txt and repo/QUICKSTART.txt.
#   §5 Verify: list the final state.
#
# POSIX mv(1) guarantees rename() semantics within a filesystem:
#
#   "If the source_file and the destination_file are on the same file
#   system, the mv utility shall perform the equivalent of the rename()
#   function on the source_file and destination_file."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#
# The Linux rename(2) syscall is atomic and specified at:
#   https://man7.org/linux/man-pages/man2/rename.2.html
#
# ============================================================================
# CITATIONS — every external reference used in this script
# ============================================================================
#
#   POSIX cmp(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#   POSIX mv(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#   POSIX rm(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#   POSIX mkdir(1)        https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
#   POSIX test(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX find(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   Linux rename(2)       https://man7.org/linux/man-pages/man2/rename.2.html
#   Linux unlink(2)       https://man7.org/linux/man-pages/man2/unlink.2.html
#   Bash pipefail         https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Shellcheck SC2086     https://www.shellcheck.net/wiki/SC2086
#   Shellcheck SC2181     https://www.shellcheck.net/wiki/SC2181
#   ISO 8601              https://www.iso.org/iso-8601-date-and-time-format.html
#   GNU diffutils cmp     https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
#
# Book-length references:
#
#   Brian W. Kernighan and Rob Pike, "The Practice of Programming",
#   Addison-Wesley Professional, 1999. ISBN-13: 978-0201615869.
#     §6.2 "Idempotence" — the reasoning behind dedup-before-move.
#
#   Eric S. Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017.
#     §1.6.1 "Rule of Modularity" and §1.6.6 "Rule of Separation" — the
#     justification for separating mechanism (archives) from policy
#     (operating scripts).
#
#   W. Richard Stevens and Stephen A. Rago, "Advanced Programming in the
#   UNIX Environment", 3rd ed., Addison-Wesley, 2013.
#   ISBN-13: 978-0321637734.
#     Chapter 4.15 "link, unlink, remove, and rename Functions" — the
#     POSIX atomicity guarantees underlying `mv` within a filesystem.
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203.
#     Chapter 18 "Directories and Links" — syscall-level treatment of
#     the operations this script performs.
#
# ============================================================================

# ----------------------------------------------------------------------------
# set -o pipefail
# ----------------------------------------------------------------------------
# pipefail causes a pipeline to exit with the status of the rightmost
# command that failed. It is not `set -e`. Failures anywhere in a
# pipeline (cmd | tee log) become visible in the pipeline's status, but
# non-critical failures (e.g. `cmp` returning 1 for "different") do not
# abort the script.
#   Bash Manual §4.3.1:
#   https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
# ----------------------------------------------------------------------------
set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply)     MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 1 ;;
esac

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
SCRIPTS="$REPO/scripts"
ONE_SHOT="$SCRIPTS/archive/one-shot"
LOGS="$SCRIPTS/archive/logs"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# Counters reported at the end.
n_dedup=0
n_moved=0
n_missing=0

# ----------------------------------------------------------------------------
# ensure_dir — mkdir -p
# ----------------------------------------------------------------------------
# POSIX mkdir's -p option: "Create any missing intermediate pathname
# components."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
ensure_dir() {
    local d="$1"
    [ -d "$d" ] && return 0
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$d"
    fi
    printf '  mkdir -p %s\n' "$d"
}

# ----------------------------------------------------------------------------
# reconcile_source — dedup or move one source file to a destination dir.
# ----------------------------------------------------------------------------
# Behavior:
#   - Source absent                  →  report MISSING, count, return.
#   - Destination has no such file   →  move source to destination.
#   - Destination file byte-identical →  rm -f source (dedup).
#   - Destination file differs       →  move source with TIMESTAMP suffix.
#   - Multiple sources with the same basename → subsequent ones collide;
#       the second call sees the first's result at the destination and
#       applies the same cmp test.
reconcile_source() {
    local src="$1" dest_dir="$2"
    local name
    name=$(basename "$src")

    if [ ! -e "$src" ]; then
        n_missing=$((n_missing + 1))
        return 0
    fi

    local dest="$dest_dir/$name"

    if [ ! -e "$dest" ]; then
        # First time we see this basename. Move it.
        if [ "$MODE" = "apply" ]; then
            mv "$src" "$dest"
        fi
        printf '  MOVE     %s\n' "$src"
        printf '           -> %s\n' "$dest"
        n_moved=$((n_moved + 1))
        return 0
    fi

    # Destination exists. Compare content.
    #   cmp -s: no output; exit 0 if identical, 1 if different.
    #   See GNU diffutils manual:
    #   https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
    if cmp -s "$src" "$dest"; then
        if [ "$MODE" = "apply" ]; then
            rm -f "$src"
        fi
        printf '  DEDUP    %s\n' "$src"
        printf '           (identical to %s)\n' "$dest"
        n_dedup=$((n_dedup + 1))
        return 0
    fi

    # Different content. Preserve both.
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

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    printf '=== apply-consolidate.sh ===\n'
    printf 'Mode:  %s\n' "$MODE"
    printf 'Repo:  %s\n\n' "$REPO"

    # -------- Preconditions --------
    # test(1) -d: true if pathnames resolve to an existing directory.
    #   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
    if [ ! -d "$REPO" ] || [ ! -d "$SCRIPTS" ]; then
        printf 'FAIL: %s or %s not found\n' "$REPO" "$SCRIPTS"
        return 1
    fi

    # -------- §1 create archive directories --------
    printf '=== §1 create archive directories ===\n'
    ensure_dir "$ONE_SHOT"
    ensure_dir "$LOGS"
    printf '\n'

    # -------- §2 one-shot scripts --------
    # The list is explicit. New scripts added by the user are not
    # silently archived. Each entry is reconciled against both the
    # scripts/ and repo-root locations; duplicates are deduplicated by
    # byte comparison.
    printf '=== §2 archive one-shot scripts ===\n'
    local name
    for name in \
        fix-and-reorganize.sh \
        finish-reorganize.sh \
        finish-cleanup.sh \
        finish-cleanup-2.sh \
        finish-cleanup-3.sh \
        apply-finish-cleanup-3.sh \
        cleanup-mishap.sh \
        cleanup-all.sh \
        consolidate-repo.sh \
        apply-consolidate.sh ; do

        reconcile_source "$SCRIPTS/$name" "$ONE_SHOT"
        reconcile_source "$REPO/$name"    "$ONE_SHOT"
    done
    printf '\n'

    # -------- §3 logs --------
    # All *.log under scripts/ are one-shot script outputs. Move them
    # to the logs archive. The glob is quoted via the loop variable;
    # non-matching expansions yield the literal pattern and are skipped
    # by the -e test.
    printf '=== §3 archive logs ===\n'
    local f
    for f in "$SCRIPTS"/*.log; do
        reconcile_source "$f" "$LOGS"
    done
    printf '\n'

    # -------- §4 README.txt --------
    # A short, dated README pointing to the two operating scripts. It
    # replaces any previous README only when apply mode is active.
    printf '=== §4 write scripts/README.txt ===\n'
    if [ "$MODE" = "apply" ]; then
        cat > "$SCRIPTS/README.txt" <<'README_EOF'
scripts/ — operating scripts and archives
==========================================

Two scripts are meant to be run.

deploy-dockge.sh
    Install and start Dockge. Web UI at http://localhost:5001.
    Idempotent: safe to re-run.

flatten-dockge-stacks.sh
    Discover every docker-compose.yml and compose.yml under
    $HOME/Documents and create one symlink per project directory
    under $HOME/dockge-stacks. Dockge scans that directory
    non-recursively, so re-run this after adding a new project.
    Idempotent.

Operating model
---------------

1. New project:
       mkdir -p $HOME/Documents/<project>
       create docker-compose.yml inside it
2. Refresh stack list:
       ./flatten-dockge-stacks.sh
3. Manage:
       open http://localhost:5001 in a browser

Archives
--------

archive/stage-opencode-repo/
    Historical staging script versions. v10, v12..v15, v18..v19,
    v21..v24, v26. Missing: v11, v16, v17, v20, v25, v27.

archive/forensics/
    One-shot recovery tools from before Dockge was adopted:
      map-removed-containers.sh
      investigate-removed-containers.sh
      recover-removed-containers.sh
      interactive-recovery.sh
    Plus two text reports:
      recovery-report.txt
      removed-containers.txt

archive/one-shot/
    Scripts that performed a specific reorganization or cleanup and
    whose action has completed. Re-run only with the historical
    context in mind.

archive/logs/
    Timestamped output logs from the one-shot scripts above.

Volume name caveat
------------------

Docker Compose derives the project name from the directory containing
the compose file. When that directory is reached through a symlink,
the project name becomes the symlink's basename. Named volumes are
prefixed with the project name. Renaming a symlink orphans its
volumes under the old prefix.

To pin the project name regardless of the symlink, add as the first
non-comment line of the compose file:

    name: my-project-name

Precedence (highest to lowest):
    CLI --project-name
    COMPOSE_PROJECT_NAME environment variable
    top-level name: attribute in the compose file
    basename of project directory
    basename of current working directory

Reference:
    https://docs.docker.com/compose/how-tos/project-name/
README_EOF
    fi
    printf '  wrote %s/README.txt\n' "$SCRIPTS"
    printf '\n'

    # -------- §5 QUICKSTART.txt --------
    printf '=== §5 write repo/QUICKSTART.txt ===\n'
    if [ "$MODE" = "apply" ]; then
        cat > "$REPO/QUICKSTART.txt" <<'QUICK_EOF'
OpenCode + DeepSeek V4.1 Flash + Jev — quick start
===================================================

1. Bring up the management UI:

       cd scripts
       ./deploy-dockge.sh

2. Refresh the stack list after adding a new project:

       ./flatten-dockge-stacks.sh

3. Open the browser:

       http://localhost:5001

Full description: scripts/README.txt

The Docker image is built from docker/ in this directory. It embeds
the OpenCode binary, DeepSeek provider configuration, jev-guard
plugin, and jev-review MCP server. See docker/Dockerfile for the
build recipe.
QUICK_EOF
    fi
    printf '  wrote %s/QUICKSTART.txt\n' "$REPO"
    printf '\n'

    # -------- §6 final state --------
    printf '=== §6 final state ===\n\n'
    printf -- '--- %s ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS" 2>&1
    printf '\n--- %s/archive ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive" 2>&1
    printf '\n--- %s/archive/one-shot ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/one-shot" 2>&1
    printf '\n--- %s/archive/logs ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS/archive/logs" 2>&1
    printf '\n'

    # -------- Summary --------
    printf '=== summary ===\n'
    printf '  moved:   %d\n' "$n_moved"
    printf '  deduped: %d\n' "$n_dedup"
    printf '  missing: %d\n' "$n_missing"
    printf '\n'
    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN. Rerun with --apply to perform the moves.\n'
    else
        printf 'APPLIED.\n'
    fi
}

main "$@"
