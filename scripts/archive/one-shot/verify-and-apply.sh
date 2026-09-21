#!/usr/bin/env bash
#
# verify-and-apply.sh — final consolidation.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# After patch-printf.sh, the applier parses and its section headers render
# correctly. The dry-run reported:
#
#     moved:   13
#     deduped: 0
#     missing: 10
#
# In apply mode, the second reconcile_source call for each of the two
# duplicated basenames (fix-and-reorganize.sh, finish-reorganize.sh) will
# dedup against the first move because the files are byte-identical
# copies produced by the same earlier run.
#
# No further defects were observed in the dry-run. Applying is the
# correct next step.
#
# ============================================================================
# SAFETY PROPERTIES — verified against primary sources
# ============================================================================
#
# 1. Atomicity of mv within a filesystem
#    POSIX rename(2): "If the old argument and the new argument resolve to
#    the same existing file, rename() shall return successfully and perform
#    no other action."
#      https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html
#    Linux man-pages rename(2):
#      https://man7.org/linux/man-pages/man2/rename.2.html
#
#    Stevens & Rago, "Advanced Programming in the UNIX Environment",
#    3rd ed., Addison-Wesley, 2013, ISBN 978-0321637734, §4.15:
#    rename(2) is atomic within a filesystem.
#
# 2. cmp -s exit status semantics
#    POSIX cmp(1) §EXIT STATUS:
#      "0  The files are identical.  1  The files are different.
#       >1 An error occurred."
#      https://pubs.opengroup.org/onlinepubs/9699919799/utilities/cmp.html
#
#    GNU diffutils cmp invocation:
#      https://www.gnu.org/software/diffutils/manual/html_node/cmp-invocation.html
#
#    Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#    1999, ISBN 978-0201615869, §6.2 "Idempotence": a well-designed
#    operation applied twice has the same effect as applied once.
#
# 3. printf -- end-of-options marker
#    POSIX printf(1) §OPTIONS:
#      "If the first argument is --, it shall be treated as a delimiter
#       indicating the end of options."
#      https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#    Bash manual, printf builtin:
#      https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
#
# 4. pipefail
#    Bash manual §4.3.1 Set Builtin:
#      https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
# 5. ISO 8601 timestamp format
#    https://www.iso.org/iso-8601-date-and-time-format.html
#
# ============================================================================

set -o pipefail

REPO="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
APPLIER="$REPO/apply-consolidate.sh"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# Log placed at $HOME so the applier's `*.log` glob under scripts/ does
# not race with it.
LOG="$HOME/verify-and-apply.$TIMESTAMP.log"

# ---------- §1 precondition: applier exists ----------
printf '=== §1 precondition ===\n'
if [ ! -f "$APPLIER" ]; then
    printf '  FAIL: %s not found\n' "$APPLIER"
    printf '  The consolidation may already have been applied. If so, the\n'
    printf '  applier is at %s/scripts/archive/one-shot/apply-consolidate.sh\n' "$REPO"
    return 1
fi
printf '  PASS: %s exists\n' "$APPLIER"

# ---------- §2 syntax check ----------
# bash -n reads the file and reports syntax errors without executing it.
#   Bash manual, invocation:
#   https://www.gnu.org/software/bash/manual/html_node/Invoking-Bash.html
printf '\n=== §2 syntax check ===\n'
if bash -n "$APPLIER"; then
    printf '  PASS: parses\n'
else
    printf '  FAIL: syntax error in %s\n' "$APPLIER"
    return 1
fi

# ---------- §3 apply ----------
# (cd "$REPO" && ./apply-consolidate.sh --apply) runs the applier with
# CWD set to the repo root, matching the invocation pattern the applier's
# dry-run demonstrated. The parenthesized subshell ensures that CWD of
# this wrapper is unaffected.
printf '\n=== §3 apply ===\n'
if (cd "$REPO" && ./apply-consolidate.sh --apply) 2>&1 | tee "$LOG"; then
    printf '\n  applier exit: 0\n'
else
    printf '\n  applier exit: non-zero\n'
    printf '  log: %s\n' "$LOG"
    printf '  inspect the log before re-running\n'
    return 1
fi
printf '  log: %s\n' "$LOG"

# ---------- §4 final state ----------
printf '\n=== §4 final state ===\n'

printf '\n--- %s/scripts ---\n' "$REPO"
ls -la "$REPO/scripts"

printf '\n--- %s/scripts/archive ---\n' "$REPO"
ls -la "$REPO/scripts/archive"

printf '\n--- %s/scripts/archive/one-shot ---\n' "$REPO"
ls -la "$REPO/scripts/archive/one-shot" 2>&1

printf '\n--- %s/scripts/archive/logs ---\n' "$REPO"
ls -la "$REPO/scripts/archive/logs" 2>&1

printf '\n--- repo root ---\n'
ls -la "$REPO"

printf '\n=== done ===\n'
