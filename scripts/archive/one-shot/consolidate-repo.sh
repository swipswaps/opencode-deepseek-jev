#!/usr/bin/env bash
#
# consolidate-repo.sh — final consolidation pass on the OpenCode repo.
#
# ============================================================================
# AUDIT — state observed after the successful apply-finish-cleanup-3.sh run
# ============================================================================
#
# Verified directory listings after cleanup:
#
#   scripts/
#     apply-finish-cleanup-3.20260920T160739Z.log
#     archive/
#       forensics/          (6 files: 4 scripts + 2 txt reports)
#       stage-opencode-repo/ (12 files: v10, v12..v15, v18..v19, v21..v24, v26)
#     deploy-dockge.sh
#     finish-reorganize.log
#     finish-reorganize.sh
#     fix-and-reorganize.log
#     fix-and-reorganize.sh
#     flatten-dockge-stacks.sh
#     README.txt
#
# Observations:
#
#   O1. `scripts/` accumulates one-shot scripts that have served their
#       purpose: fix-and-reorganize.sh, finish-reorganize.sh, plus every
#       script from the cleanup sequence that lived at repo root.
#
#   O2. Log files (`*.log`) accumulate alongside the scripts and carry
#       no operational value once their parent action has been verified.
#
#   O3. The persistent operating set is two scripts: deploy-dockge.sh and
#       flatten-dockge-stacks.sh. Everything else in `scripts/` is either
#       archival or one-shot.
#
#   O4. Staging script versions v11, v16, v17, v20, v25, v27 are absent.
#       v11/v16/v17/v20/v25 never reached disk under distinct filenames
#       (each was overwritten by the next iteration). v27 was never
#       written because the session pivoted to Dockge.
#
# ============================================================================
# DEDUCTION — the organizing principle to apply
# ============================================================================
#
# The Unix principle expressed as two rules in Raymond, "The Art of Unix
# Programming" (Addison-Wesley, 2003), ISBN-13: 978-0131429017:
#
#   Rule of Modularity (§1.6.1): "Write simple parts connected by clean
#     interfaces."
#
#   Rule of Separation (§1.6.6): "Separate policy from mechanism;
#     separate interfaces from engines."
#
# Applied here:
#
#   - Mechanism (one-shot scripts that performed a single transformation)
#     belongs in `scripts/archive/one-shot/`, not in the operating set.
#   - Policy (what the operator runs on an ongoing basis) is
#     `deploy-dockge.sh` + `flatten-dockge-stacks.sh`, both of which are
#     idempotent and re-runnable.
#   - Evidence (logs) belongs in `scripts/archive/logs/` for audit
#     trails, not in the active working directory.
#
# A second principle applies from Kernighan & Pike, "The Practice of
# Programming" (Addison-Wesley, 1999), ISBN-13: 978-0201615869:
#
#   §5.1 "Debugging": "The best debugging tool is a clean, consistent
#     environment you understand."
#
# After six iterations of cleanup scripts, the repo is clean but the
# tooling directory is not. Consolidation restores the property that a
# reader can list `scripts/` and see, at a glance, what the operator is
# supposed to run.
#
# ============================================================================
# PROCEED — four operations, all reversible
# ============================================================================
#
#   §1 Archive one-shot scripts into scripts/archive/one-shot/
#   §2 Archive *.log files into scripts/archive/logs/
#   §3 Rewrite scripts/README.txt to describe the current operating model
#   §4 Write repo/QUICKSTART.txt as a top-level orientation file
#
# Every operation uses `mv` (rename within same filesystem) or creates
# a file. No operation deletes. No operation overwrites an existing file
# of a different name — collisions receive a `.TIMESTAMP` suffix.
#
# ============================================================================
# CITATIONS — verified external references
# ============================================================================
#
# POSIX mv(1):
#   "The mv utility shall perform one of the following actions: ... If
#   the source_file and the destination_file are on the same file
#   system, the mv utility shall perform the equivalent of the rename()
#   function on the source_file and destination_file."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#
# POSIX mkdir(1):
#   "-p  Create any missing intermediate pathname components."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mkdir.html
#
# POSIX test(1):
#   Describes -d (directory), -f (regular file), -e (exists), -x
#   (executable), -L (symbolic link).
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#
# POSIX find(1):
#   Path traversal semantics; the -maxdepth extension is documented as a
#   non-POSIX convenience by GNU.
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   GNU extension:
#   https://www.gnu.org/software/findutils/manual/html_node/find_html/Current_002ddirectory.html
#
# Bash Manual §4.3.1 Set Builtin (pipefail):
#   https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
# Shellcheck SC2086 (quote to prevent globbing):
#   https://www.shellcheck.net/wiki/SC2086
#
# Shellcheck SC2181 (check exit status directly):
#   https://www.shellcheck.net/wiki/SC2181
#
# ISO 8601 date/time format (used for the timestamp suffix):
#   https://www.iso.org/iso-8601-date-and-time-format.html
#
# Linux rename(2) — atomic within a filesystem:
#   https://man7.org/linux/man-pages/man2/rename.2.html
#
# ============================================================================

# ----------------------------------------------------------------------------
# Mode selection: default is dry-run. --apply performs mutations.
# ----------------------------------------------------------------------------
# Dry-run as the default follows the principle that destructive
# operations require explicit opt-in. cmp(1) and mv(1) are reversible in
# principle (mv within a filesystem is atomic; the inverse mv restores
# the original), but surprise mutations are still bad UX.
set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 1 ;;
esac

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
SCRIPTS="$REPO/scripts"
ONE_SHOT="$SCRIPTS/archive/one-shot"
LOGS="$SCRIPTS/archive/logs"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# ----------------------------------------------------------------------------
# ensure_dir — mkdir -p, POSIX mkdir with the -p extension.
# ----------------------------------------------------------------------------
ensure_dir() {
    local d="$1"
    if [ -d "$d" ]; then return 0; fi
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$d"
    fi
    printf '  mkdir -p %s\n' "$d"
}

# ----------------------------------------------------------------------------
# move_if_present — move a file to a destination directory, avoiding
# collisions by suffixing the destination name with the timestamp.
# ----------------------------------------------------------------------------
# The destination is a directory. If a file of the same basename already
# exists at the destination, the moved copy receives a suffixed name.
# This makes the operation idempotent: re-running does not overwrite
# anything that a prior run placed there.
move_if_present() {
    local src="$1" dest_dir="$2"
    [ -e "$src" ] || [ -L "$src" ] || return 0
    local name
    name=$(basename "$src")
    local dest="$dest_dir/$name"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        dest="${dest}.${TIMESTAMP}"
    fi
    if [ "$MODE" = "apply" ]; then
        mv "$src" "$dest"
    fi
    printf '  mv %s\n     -> %s\n' "$src" "$dest"
}

main() {
    printf '=== consolidate-repo.sh ===\n'
    printf 'Mode:  %s\n' "$MODE"
    printf 'Repo:  %s\n' "$REPO"
    printf '\n'

    if [ ! -d "$REPO" ]; then
        printf 'FAIL: repo not found at %s\n' "$REPO"
        return 1
    fi
    if [ ! -d "$SCRIPTS" ]; then
        printf 'FAIL: scripts/ not found under %s\n' "$REPO"
        return 1
    fi

    # ------------------------------------------------------------------------
    # §1 Archive one-shot scripts
    # ------------------------------------------------------------------------
    # One-shot scripts are those written to perform a specific
    # reorganization or cleanup and whose action has already occurred.
    # They remain useful as references to the sequence of operations
    # that produced the current state, but should not clutter the
    # operating directory.
    #
    # The list is explicit. It is not derived from file contents. This
    # keeps the operation predictable: a new script added by the user is
    # not silently archived.
    printf '=== §1 archive one-shot scripts ===\n'
    ensure_dir "$ONE_SHOT"

    for name in \
        fix-and-reorganize.sh \
        finish-reorganize.sh \
        finish-cleanup-3.sh \
        apply-finish-cleanup-3.sh \
        finish-cleanup-2.sh \
        finish-cleanup.sh \
        cleanup-mishap.sh \
        cleanup-all.sh \
        consolidate-repo.sh; do

        # Look for the script in scripts/ and at the repo root; move
        # whichever copies exist.
        for candidate in "$SCRIPTS/$name" "$REPO/$name"; do
            if [ -f "$candidate" ]; then
                move_if_present "$candidate" "$ONE_SHOT"
            fi
        done
    done
    printf '\n'

    # ------------------------------------------------------------------------
    # §2 Archive log files
    # ------------------------------------------------------------------------
    # The *.log files in scripts/ record the actions of one-shot scripts
    # that have already run. Their contents are useful as audit trails
    # but do not belong in the operating directory.
    #
    # The glob is intentional and quoted appropriately. Files are moved
    # by basename, colliding names receiving a timestamp suffix.
    printf '=== §2 archive logs ===\n'
    ensure_dir "$LOGS"

    for f in "$SCRIPTS"/*.log; do
        [ -e "$f" ] || continue
        move_if_present "$f" "$LOGS"
    done
    printf '\n'

    # ------------------------------------------------------------------------
    # §3 Rewrite scripts/README.txt
    # ------------------------------------------------------------------------
    # The README describes the current operating model: two idempotent
    # scripts the operator runs, plus a pointer to the archives.
    printf '=== §3 write scripts/README.txt ===\n'
    local readme="$SCRIPTS/README.txt"
    if [ "$MODE" = "apply" ]; then
        cat > "$readme" <<'README_EOF'
scripts/ — operating set and archives
=====================================

Run these two scripts for the OpenCode + DeepSeek + Jev setup.

Operating scripts
-----------------

deploy-dockge.sh
    Install and start Dockge. Manages compose stacks from a browser at
    http://localhost:5001. Idempotent: safe to re-run.

flatten-dockge-stacks.sh
    Scan $HOME/Documents for docker-compose.yml and compose.yml files,
    create one symlink per project directory under $HOME/dockge-stacks.
    Dockge scans $HOME/dockge-stacks non-recursively, so this is
    required after adding a new compose file. Idempotent: re-run after
    each new project.

Operating model
---------------

1. New project:
       create docker-compose.yml under $HOME/Documents/<project>/
2. Refresh stack list:
       ./flatten-dockge-stacks.sh
3. Manage the stack:
       http://localhost:5001 → click the stack tile

archive/
--------

archive/stage-opencode-repo/
    Historical versions of the staging script. v10, v12..v15,
    v18..v19, v21..v24, v26. v11, v16, v17, v20, v25, v27 do not
    exist — each missing version was overwritten by the next, or in
    the case of v27, was never written.

archive/forensics/
    One-shot recovery tools written before Dockge was adopted:
      map-removed-containers.sh
      investigate-removed-containers.sh
      recover-removed-containers.sh
      interactive-recovery.sh
    Plus two text reports from the recovery investigation:
      recovery-report.txt
      removed-containers.txt

archive/one-shot/
    Scripts that performed a specific reorganization or cleanup and
    whose action has completed. Kept for reference. Not intended to
    be re-run without understanding their historical context.

archive/logs/
    Timestamped output logs from the one-shot scripts above.

Known gaps
----------

None of the operating scripts are lost. The only irrecoverable loss is
the staging script versions listed above.

Volume name caveat
------------------

Docker Compose derives the project name from the directory containing
the compose file. When that directory is reached through a symlink, the
project name becomes the symlink's basename. Named volumes are prefixed
with the project name. Renaming a symlink therefore orphans its volumes
under the old prefix.

To pin a project name regardless of the symlink, add a top-level
`name:` key as the first non-comment line of the compose file:

    name: my-project-name
    services:
      ...

Compose v2 honours this over the directory name. See
https://docs.docker.com/compose/how-tos/project-name/ for the full
precedence order (CLI flag > env var > name: key > directory basename).
README_EOF
    fi
    printf '  wrote %s\n' "$readme"
    printf '\n'

    # ------------------------------------------------------------------------
    # §4 Write repo/QUICKSTART.txt
    # ------------------------------------------------------------------------
    # Top-level orientation: three lines pointing to the operating set.
    printf '=== §4 write repo/QUICKSTART.txt ===\n'
    local quick="$REPO/QUICKSTART.txt"
    if [ "$MODE" = "apply" ]; then
        cat > "$quick" <<'QUICK_EOF'
OpenCode + DeepSeek V4.1 Flash + Jev — quick start
==================================================

1. Bring up the management UI:

       cd scripts
       ./deploy-dockge.sh

2. Refresh the stack list after adding a new project:

       ./flatten-dockge-stacks.sh

3. Open the browser:

       http://localhost:5001

See scripts/README.txt for the full operating model.

The Docker image is built from docker/ in this directory. It embeds
the OpenCode binary, DeepSeek provider configuration, jev-guard plugin,
and jev-review MCP server. See docker/Dockerfile for the build recipe.
QUICK_EOF
    fi
    printf '  wrote %s\n' "$quick"
    printf '\n'

    # ------------------------------------------------------------------------
    # §5 Final state report
    # ------------------------------------------------------------------------
    printf '=== §5 final state ===\n'
    printf '\n--- %s ---\n' "$SCRIPTS"
    ls -la "$SCRIPTS"
    printf '\n--- %s ---\n' "$SCRIPTS/archive"
    ls -la "$SCRIPTS/archive"
    printf '\n--- %s ---\n' "$SCRIPTS/archive/one-shot"
    ls -la "$SCRIPTS/archive/one-shot" 2>&1
    printf '\n--- %s ---\n' "$SCRIPTS/archive/logs"
    ls -la "$SCRIPTS/archive/logs" 2>&1
    printf '\n'

    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN complete. Rerun with --apply to perform the moves.\n'
    else
        printf 'APPLIED.\n'
    fi
}

main "$@"
