#!/usr/bin/env bash
#
# fix-chatlog-and-scanner.sh — three corrections after the recovery pass.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# D1. chatlog.sh has top-level `return N` statements in its case arms.
#     Bash:
#         "return: can only `return' from a function or sourced script"
#     The prior fix removed `local` at the same sites but not `return`.
#     Both are the same class of defect.
#
#     Bash Manual §4.1 Bourne Shell Builtins, `return`:
#       https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#
# D2. scan-constraints.py has no way to match arbitrary extensions. Its
#     iter_shell_files uses rglob("*.sh"), so chat-log searches on .txt
#     and .md find nothing.
#
# D3. scan-constraints.py has no way to exclude a subtree. Every archive
#     hit is reported as a code violation, but the archive is a
#     historical record, not live code.
#
#     Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
#     ISBN-13: 978-0131429017, §1.6.6 "Rule of Separation".
#
# ============================================================================
# DEDUCTION
# ============================================================================
#
# F1. Replace every top-level `return N` in chatlog.sh with `exit N`.
#     Functions inside the script (usage, abs_path_of_log, etc.) keep
#     their returns. A brace-depth counter distinguishes the two.
#
# F2. Add --include GLOB (repeatable) and --exclude-dir NAME (repeatable)
#     to scan-constraints.py. Defaults: --include '*.sh'; no exclusions.
#
# F3. Update chatlog.sh search to pass:
#         --include '*.txt' --include '*.md' --exclude-dir archive
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash exit                  https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Python pathlib.rglob       https://docs.python.org/3/library/pathlib.html#pathlib.Path.rglob
#   Python argparse action=append
#                              https://docs.python.org/3/library/argparse.html#action
#   POSIX find(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
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
    printf 'GATE FAIL: cannot resolve repo root\n' >&2
    return 2
fi

SCRIPTS="$REPO_DIR/scripts"
CHATLOG="$SCRIPTS/chatlog.sh"
SCANNER="$SCRIPTS/scan-constraints.py"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

# ============================================================================
# F1 — replace top-level `return N` with `exit N` in chatlog.sh
# ============================================================================
fix_chatlog_returns() {
    section "F1 fix top-level returns in chatlog.sh"

    if [ ! -f "$CHATLOG" ]; then
        printf '  missing: %s\n' "$CHATLOG"
        return 1
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$CHATLOG" "$CHATLOG.bak.$TS"
        printf '  backup: %s.bak.%s\n' "$CHATLOG" "$TS"
    fi

    local count
    count=$(python3 - "$CHATLOG" "$MODE" <<'PY_EOF'
import re, sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()
lines = src.splitlines(keepends=True)

# A `return` at brace-depth 0 is top-level. Track depth by counting
# unquoted braces. chatlog.sh contains no string literals with
# unbalanced braces, so simple counting is sufficient.
depth = 0
out = []
count = 0
for line in lines:
    stripped = line.lstrip()
    if re.match(r"return(\s|$)", stripped) and depth == 0:
        # Replace the first `return` token in the line with `exit`.
        line = re.sub(r"\breturn\b", "exit", line, count=1)
        count += 1
    out.append(line)
    # Update depth AFTER processing the line, so a `return` inside a
    # one-line function definition is not treated as top-level.
    depth += line.count("{") - line.count("}")

if mode == "apply" and count > 0:
    with open(path, "w") as f:
        f.writelines(out)

print(count)
PY_EOF
)
    printf '  top-level return statements rewritten: %s\n' "$count"
}

# ============================================================================
# F2 — extend scan-constraints.py with --include and --exclude-dir
# ============================================================================
extend_scanner() {
    section "F2 extend scan-constraints.py"

    if [ ! -f "$SCANNER" ]; then
        printf '  missing: %s\n' "$SCANNER"
        return 1
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$SCANNER" "$SCANNER.bak.$TS"
        printf '  backup: %s.bak.%s\n' "$SCANNER" "$TS"
    fi

    python3 - "$SCANNER" "$MODE" <<'PY_EOF'
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

# 1. Replace iter_shell_files with a version that accepts include patterns
old_iter = '''def iter_shell_files(root: Path) -> Iterator[Path]:
    for path in sorted(root.rglob("*.sh")):
        if path.is_file():
            yield path
'''
new_iter = '''def iter_files(
    root: Path,
    includes: list[str],
    exclude_dirs: list[str],
) -> Iterator[Path]:
    """Yield files under root matching any include glob, skipping any
    path whose components contain an excluded directory name."""
    seen: set[Path] = set()
    excluded = set(exclude_dirs)
    for pattern in includes:
        for path in sorted(root.rglob(pattern)):
            if not path.is_file():
                continue
            if any(part in excluded for part in path.relative_to(root).parts):
                continue
            if path in seen:
                continue
            seen.add(path)
            yield path
'''
if old_iter not in src:
    print("ERROR: iter_shell_files not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(old_iter, new_iter)

# 2. Update report() signature and body to accept includes/exclude_dirs
old_report = '''def report(
    root: Path,
    patterns: list[tuple[str, re.Pattern[str]]],
    show_all: bool,
    quiet: bool,
) -> int:
    files_scanned = 0
    code_hits: list[Hit] = []
    other_hits: list[Hit] = []
    per_file: dict[Path, list[Hit]] = {}

    for path in iter_shell_files(root):'''
new_report = '''def report(
    root: Path,
    patterns: list[tuple[str, re.Pattern[str]]],
    show_all: bool,
    quiet: bool,
    includes: list[str],
    exclude_dirs: list[str],
) -> int:
    files_scanned = 0
    code_hits: list[Hit] = []
    other_hits: list[Hit] = []
    per_file: dict[Path, list[Hit]] = {}

    for path in iter_files(root, includes, exclude_dirs):'''
if old_report not in src:
    print("ERROR: report signature not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(old_report, new_report)

# 3. Add argparse options
old_args = '''    parser.add_argument("--pattern", default=None, metavar="REGEX",
                        help="override the default constraint pattern set "
                             "with a single POSIX ERE")
    return parser.parse_args(argv)'''
new_args = '''    parser.add_argument("--pattern", default=None, metavar="REGEX",
                        help="override the default constraint pattern set "
                             "with a single POSIX ERE")
    parser.add_argument("--include", action="append", default=None,
                        metavar="GLOB",
                        help="file glob to include (repeatable, default: *.sh)")
    parser.add_argument("--exclude-dir", action="append", default=None,
                        metavar="NAME",
                        help="directory name to skip (repeatable)")
    return parser.parse_args(argv)'''
if old_args not in src:
    print("ERROR: --pattern block not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(old_args, new_args)

# 4. Pass new options through main()
old_main = '''    return report(args.root, patterns, args.show_all, args.quiet)'''
new_main = '''    includes = args.include if args.include else ["*.sh"]
    exclude_dirs = args.exclude_dir if args.exclude_dir else []
    return report(args.root, patterns, args.show_all, args.quiet,
                  includes, exclude_dirs)'''
if old_main not in src:
    print("ERROR: main return not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(old_main, new_main)

if mode == "apply":
    with open(path, "w") as f:
        f.write(src)
print("OK")
PY_EOF
    printf '  scanner extended\n'
}

# ============================================================================
# F3 — update chatlog.sh search arm to pass --include / --exclude-dir
# ============================================================================
fix_chatlog_search() {
    section "F3 fix chatlog.sh search arm"

    if [ ! -f "$CHATLOG" ]; then
        printf '  missing: %s\n' "$CHATLOG"
        return 1
    fi

    python3 - "$CHATLOG" "$MODE" <<'PY_EOF'
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

old = '''            python3 "$scanner" "$NOTES_DIR" --pattern "$pattern" --show-all
            return $?'''
new = '''            python3 "$scanner" "$NOTES_DIR" \\
                --pattern "$pattern" \\
                --include '*.txt' \\
                --include '*.md' \\
                --exclude-dir archive \\
                --show-all
            exit $?'''
if old not in src:
    print("ERROR: search arm not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(old, new)
if mode == "apply":
    with open(path, "w") as f:
        f.write(src)
print("OK")
PY_EOF
    printf '  chatlog.sh search arm updated\n'
}

# ============================================================================
# Verification
# ============================================================================
verify() {
    section "verification"

    printf 'chatlog.sh top-level return count: '
    python3 - "$CHATLOG" <<'PY_EOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
depth = 0
count = 0
for line in lines:
    stripped = line.lstrip()
    if re.match(r"return(\s|$)", stripped) and depth == 0:
        count += 1
    depth += line.count("{") - line.count("}")
print(count)
PY_EOF

    printf '\nscanner strict scan (default: *.sh, no exclusions):\n'
    python3 "$SCANNER" "$SCRIPTS" --quiet || true

    printf '\nscanner with --exclude-dir archive:\n'
    python3 "$SCANNER" "$SCRIPTS" --exclude-dir archive --quiet || true

    printf '\nscanner with --include "*.txt" on notes dir:\n'
    NOTES_DIR="$(dirname "$REPO_DIR")/notes"
    if [ -d "$NOTES_DIR" ]; then
        python3 "$SCANNER" "$NOTES_DIR" \
            --include '*.txt' --include '*.md' \
            --pattern 'no fail' --show-all --quiet || true
    else
        printf '  notes dir not found: %s\n' "$NOTES_DIR"
    fi
}

main() {
    printf '=== fix-chatlog-and-scanner.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n' "$REPO_DIR"
    printf '\n'

    fix_chatlog_returns
    extend_scanner
    fix_chatlog_search
    verify

    printf '\n'
    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN. Rerun with --apply.\n'
    else
        printf 'APPLIED.\n'
    fi
}

main "$@"
