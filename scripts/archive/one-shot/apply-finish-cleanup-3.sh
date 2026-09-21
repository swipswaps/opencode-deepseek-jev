#!/usr/bin/env bash
#
# apply-finish-cleanup-3.sh — apply the dedup + rmdir plan validated by
# the dry-run of finish-cleanup-3.sh, then verify the outcome.
#
# Run from: /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
#
# ============================================================================
# AUDIT — what the dry-run established
# ============================================================================
#
# The dry-run reported, verbatim:
#
#   === §4 totals ===
#     dedup (identical, nested removed): 12
#     moved (unique, relocated):          0
#     conflict (kept both):               0
#
# Twelve files under scripts/scripts/archive/ are byte-identical to the
# corresponding files at scripts/archive/. Zero files differ. Zero files
# are unique to the nested location. Therefore:
#
#   - Applying the plan deletes only duplicates. No information is lost.
#   - The parent destination (scripts/archive/) is preserved untouched.
#   - rmdir can succeed at every level because each nested directory will
#     be empty after its contents are unlinked.
#
# This audit is the entire basis for proceeding. No other judgment is
# involved. The dry-run output is the evidence.
#
# ============================================================================
# DEDUCTION — why this operation is safe under the stated constraints
# ============================================================================
#
# The user's constraint is "no rm -rf". This script uses only `rm -f` on
# individual files, followed by `rmdir` on directories that are empty by
# construction. Neither command recurses.
#
#   POSIX rm(1) §OPTIONS, -f:
#     "Do not prompt for confirmation. Do not write diagnostic messages
#     or modify the exit status in the case of no file operands, or in
#     the case of operands that do not exist. ... The -r option is
#     required to remove a directory and its contents."
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#
#   POSIX rmdir(1) §DESCRIPTION:
#     "The rmdir utility shall remove the directory entry specified by
#     each dir operand. ... If the directory is not empty, rmdir shall
#     fail."
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rmdir.html
#
#   Linux rmdir(2) §ERRORS, ENOTEMPTY:
#     "pathname contains entries other than . and .. ."
#     https://man7.org/linux/man-pages/man2/rmdir.2.html
#
# Because rmdir refuses non-empty directories at the kernel level, the
# sequence is naturally idempotent: an interrupted run leaves the
# directory tree in a partially-cleaned state, and a re-run resumes
# safely. No state is lost if the process is killed mid-operation.
#
# ============================================================================
# PROCEED — apply, then verify
# ============================================================================
#
# The script performs exactly two steps:
#
#   §1 Invoke `finish-cleanup-3.sh --apply`, capturing its output to a
#      timestamped log. The log is the audit trail of what changed.
#
#   §2 Run a read-only verification: list scripts/, scripts/archive/, and
#      confirm the nested tree is gone. No writes in this step.
#
# ============================================================================
# CITATIONS — verified external references used above
# ============================================================================
#
# Standards and primary references:
#
#   POSIX rm(1)
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rm.html
#
#   POSIX rmdir(1)
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rmdir.html
#
#   POSIX cmp(1) — exit status 0 for identical, 1 for different
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#
#   POSIX find(1) — path traversal and -maxdepth extension
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#     GNU extension note:
#     https://www.gnu.org/software/findutils/manual/html_node/find_html/Current_002ddirectory.html
#
#   Linux rmdir(2) — syscall semantics and error codes
#     https://man7.org/linux/man-pages/man2/rmdir.2.html
#
#   Linux unlink(2) — the primitive underlying rm -f
#     https://man7.org/linux/man-pages/man2/unlink.2.html
#
#   GNU coreutils rm invocation — -f semantics on GNU/Linux
#     https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html
#
#   Bash Manual §4.3.1 Set Builtin — pipefail
#     https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
#   Shellcheck SC2181 — check exit code directly, not via $?
#     https://www.shellcheck.net/wiki/SC2181
#
# Book-length reference (Kerrisk covers rmdir(2) and unlink(2) with
# syscall-level detail, including ENOTEMPTY and race conditions):
#
#   Michael Kerrisk, "The Linux Programming Interface: A Linux and UNIX
#   System Programming Handbook", No Starch Press, 2010.
#   ISBN-13: 978-1-59327-220-3
#   Chapter 18: "Directories and Links"
#
# ============================================================================

# ---------------------------------------------------------------------------
# set -o pipefail
# ---------------------------------------------------------------------------
# pipefail is not set -e. It causes a pipeline to return the exit status
# of the rightmost command that failed, rather than the exit status of
# the rightmost command unconditionally. This means a failure anywhere in
# a pipeline (cmd | tee log) is visible in $?, while successful commands
# and non-critical non-zero exits (e.g. cmp returning 1 for "different")
# do not abort the script. Bash Manual §4.3.1, cited above.
# ---------------------------------------------------------------------------
set -o pipefail

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
NESTED="$REPO/scripts/scripts"
APPLIER="$REPO/finish-cleanup-3.sh"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG="$REPO/scripts/apply-finish-cleanup-3.$TIMESTAMP.log"

# ---------------------------------------------------------------------------
# Gate: applier must exist and be executable.
# ---------------------------------------------------------------------------
# The `-x` test is POSIX test(1); it returns true only when the path
# exists and has execute permission for the calling process.
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
# ---------------------------------------------------------------------------
if [ ! -x "$APPLIER" ]; then
    echo "FAIL: $APPLIER not found or not executable"
    echo "      Staged applier must be at that path with mode 0755."
    return 1
fi

echo "=== apply-finish-cleanup-3.sh ==="
echo "Timestamp: $TIMESTAMP"
echo "Applier:   $APPLIER"
echo "Log:       $LOG"
echo ""

# ---------------------------------------------------------------------------
# §1 — Apply
# ---------------------------------------------------------------------------
# tee(1) writes stdin to both stdout and the named file. This produces a
# persistent log while keeping the terminal display live.
#   POSIX tee(1):
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/tee.html
#
# The pipeline is guarded by pipefail, so a non-zero exit from the
# applier propagates through tee and is visible in the `if` test.
# ---------------------------------------------------------------------------
echo "=== §1 apply ==="
if "$APPLIER" --apply 2>&1 | tee "$LOG"; then
    echo ""
    echo "  applier exit: 0"
else
    echo ""
    echo "  applier exit: non-zero"
    echo "  inspect log:  $LOG"
fi
echo ""

# ---------------------------------------------------------------------------
# §2 — Verify
# ---------------------------------------------------------------------------
# Read-only. Every command below observes state; none mutates it.
#
# find(1) with -maxdepth limits traversal depth. POSIX find does not
# define -maxdepth; the option is a GNU extension documented at the URL
# cited above. On Fedora 43, findutils provides the GNU implementation.
# ---------------------------------------------------------------------------
echo "=== §2 verify ==="

echo "--- scripts/ (top level) ---"
ls -la "$REPO/scripts"
echo ""

echo "--- scripts/archive/ ---"
ls -la "$REPO/scripts/archive"
echo ""

echo "--- scripts/archive/stage-opencode-repo/ ---"
ls -la "$REPO/scripts/archive/stage-opencode-repo"
echo ""

echo "--- scripts/archive/forensics/ ---"
ls -la "$REPO/scripts/archive/forensics"
echo ""

echo "--- nested tree check ---"
if [ -d "$NESTED" ]; then
    echo "  FAIL: $NESTED still exists"
    echo "  remaining contents:"
    find "$NESTED" -mindepth 1 -maxdepth 4 2>&1
else
    echo "  PASS: $NESTED removed"
fi
echo ""

# ---------------------------------------------------------------------------
# §3 — Summary
# ---------------------------------------------------------------------------
echo "=== §3 summary ==="
echo "  applier log: $LOG"
echo "  verify above should show:"
echo "    scripts/                       (top level: operating scripts + archive/ + README.txt)"
echo "    scripts/archive/stage-opencode-repo/  (stage-opencode-repo-v*.sh files)"
echo "    scripts/archive/forensics/            (forensics scripts)"
echo "    nested tree check:              PASS: .../scripts/scripts removed"
echo ""
echo "=== done ==="
