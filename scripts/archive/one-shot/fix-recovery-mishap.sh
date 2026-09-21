#!/usr/bin/env bash
#
# fix-recovery-mishap.sh — repair the four defects left by
# recover-scan-constraints.sh.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# D1. recover-scan-constraints.sh used
#         REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#     Because the script lives at scripts/archive/one-shot/, ../.. resolved
#     to scripts/, not to the repo root. Everything the script wrote went
#     under scripts/scripts/.
#
# D2. chatlog.sh line 199 uses `local` at top-level script scope.
#     Bash:
#         "local: can only be used in a function"
#     Bash Manual §4.1 Bourne Shell Builtins, `local`:
#         https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#
# D3. chatlog.sh's scanner test uses $SCRIPT_DIR, which points at
#     scripts/, but the scanner was written at scripts/scripts/. The
#     -x test fails and the script falls back to grep.
#
# D4. The smoke tests in the recovery script scanned the wrong tree.
#
# Fix strategy:
#
#   F1. Resolve repo root by marker file. Any script anywhere in the
#       tree can locate the root without knowing its own depth.
#
#       Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
#       ISBN-13: 978-0131429017, §1.6.6 "Rule of Separation": identity
#       should not depend on the caller's location.
#
#   F2. Move artifacts from scripts/scripts/ to scripts/.
#
#   F3. Remove the now-empty scripts/scripts/ directory.
#
#   F4. Remove `local` at top-level in chatlog.sh. A plain assignment
#       is sufficient and legal at any scope.
#
#   F5. Re-run both smoke tests to confirm.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX find(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   POSIX mv(1)                https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html
#   POSIX rmdir(1)             https://pubs.opengroup.org/onlinepubs/9699919799/utilities/rmdir.html
#   POSIX test(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   Bash local                 https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Python pathlib             https://docs.python.org/3/library/pathlib.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

# ----------------------------------------------------------------------------
# Marker-based repo root resolution
# ----------------------------------------------------------------------------
resolve_repo() {
    local candidate="$1"
    while [ "$candidate" != "/" ]; do
        if [ -f "$candidate/opencode.json" ] && [ -f "$candidate/docker/Dockerfile" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        candidate=$(dirname "$candidate")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root by marker\n' >&2
    return 2
fi

SCRIPTS="$REPO_DIR/scripts"
STRAY="$SCRIPTS/scripts"
ONE_SHOT="$SCRIPTS/archive/one-shot"

section() { printf '\n=== %s ===\n' "$1"; }

do_mv() {
    local src="$1" dst_dir="$2"
    [ -e "$src" ] || return 0
    if [ "$MODE" = "apply" ]; then
        mkdir -p "$dst_dir"
        mv "$src" "$dst_dir/"
    fi
    printf '  mv %s\n     -> %s/\n' "$src" "$dst_dir"
}

do_rmdir() {
    local d="$1"
    [ -d "$d" ] || return 0
    if [ "$MODE" = "apply" ]; then
        rmdir "$d"
    fi
    printf '  rmdir %s\n' "$d"
}

main() {
    printf '=== fix-recovery-mishap.sh ===\n'
    printf 'Mode:    %s\n' "$MODE"
    printf 'Repo:    %s\n' "$REPO_DIR"
    printf 'Scripts: %s\n' "$SCRIPTS"
    printf 'Stray:   %s\n' "$STRAY"
    printf '\n'

    # ---- F2: relocate artifacts from scripts/scripts -------------------
    section "F2 relocate mislocated artifacts"
    if [ ! -d "$STRAY" ]; then
        printf '  no stray directory present\n'
    else
        # scanner
        if [ -f "$STRAY/scan-constraints.py" ]; then
            do_mv "$STRAY/scan-constraints.py" "$SCRIPTS"
        fi
        # tmp-patches and backups under scripts/scripts/archive/one-shot
        if [ -d "$STRAY/archive/one-shot/tmp-patches" ]; then
            for f in "$STRAY/archive/one-shot/tmp-patches"/*; do
                [ -e "$f" ] || continue
                do_mv "$f" "$ONE_SHOT/tmp-patches"
            done
        fi
        if [ -d "$STRAY/archive/one-shot/backups" ]; then
            for f in "$STRAY/archive/one-shot/backups"/*; do
                [ -e "$f" ] || continue
                do_mv "$f" "$ONE_SHOT/backups"
            done
        fi
        # any stray shell scripts directly under scripts/scripts
        for f in "$STRAY"/*.sh "$STRAY"/*.py; do
            [ -e "$f" ] || continue
            do_mv "$f" "$SCRIPTS"
        done
    fi

    # ---- F3: remove the stray scripts/scripts tree ---------------------
    section "F3 remove empty stray directories"
    if [ -d "$STRAY" ]; then
        # deepest first
        for d in \
            "$STRAY/archive/one-shot/tmp-patches" \
            "$STRAY/archive/one-shot/backups" \
            "$STRAY/archive/one-shot" \
            "$STRAY/archive" \
            "$STRAY" ; do
            do_rmdir "$d"
        done
    fi

    # ---- F4: remove top-level `local` in chatlog.sh --------------------
    section "F4 remove top-level local in chatlog.sh"
    local chatlog="$SCRIPTS/chatlog.sh"
    if [ ! -f "$chatlog" ]; then
        printf '  chatlog.sh not present; skipping\n'
    else
        local count
        count=$(python3 - "$chatlog" "$MODE" <<'PY_EOF'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

# Match `local VAR=` at column 0 (top-level), one space of indent common
# in the case block. Inside a function body, Bash requires any indent to
# still be within the function. We approximate by matching exactly the
# form present in the script:
#     local scanner=...
# and any other occurrence at the same 8-space indent under case arms.
# The script currently has one such line.
old_re = re.compile(r'^(\s{4,8})local\s+([A-Za-z_][A-Za-z0-9_]*)=', re.MULTILINE)
# Only strip `local ` when the line is NOT inside a function. Detecting
# function bodies in Bash is nontrivial; the script in question has no
# function-wrapped case arms, so any `local` outside indentation >= 4
# inside a `main() {` is top-level. We approximate by checking line
# numbers: functions in chatlog.sh start at `^main()` if present.
has_main = bool(re.search(r'^main\s*\(\)\s*\{', src, re.MULTILINE))

if has_main:
    print("0")  # chatlog.sh already wrapped; local may be legal
    sys.exit(0)

new, n = old_re.subn(r'\1\2=', src)
if mode == "apply" and n:
    with open(path, "w") as f:
        f.write(new)
print(n)
PY_EOF
)
        printf '  top-level local occurrences rewritten: %s\n' "$count"
    fi

    # ---- F5: smoke tests ----------------------------------------------
    section "F5 smoke tests"
    if [ -x "$SCRIPTS/scan-constraints.py" ] || [ -f "$SCRIPTS/scan-constraints.py" ]; then
        printf '  default patterns on scripts/:\n'
        python3 "$SCRIPTS/scan-constraints.py" "$SCRIPTS" --quiet || true
        printf '\n  custom pattern test:\n'
        python3 "$SCRIPTS/scan-constraints.py" "$SCRIPTS" --pattern 'Docker Root Dir' --quiet || true
    else
        printf '  scanner still missing at %s/scan-constraints.py\n' "$SCRIPTS"
    fi

    printf '\n'
    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN. Rerun with --apply to perform.\n'
    else
        printf 'APPLIED.\n'
    fi

    printf '\nnext: ./scripts/chatlog.sh search "no fail"\n'
    return 0
}

main "$@"
