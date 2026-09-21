#!/usr/bin/env bash
#
# patch-scanner-pattern.sh — add an optional --pattern REGEX argument to
# scan-constraints.py. When present, the provided pattern replaces the
# hardcoded constraint set. When absent, the default constraint set is
# used and the file behaves as before.
#
# ============================================================================
# AUDIT — why this is needed
# ============================================================================
#
# chatlog.sh search takes an arbitrary pattern. The prior patch routed
# that call through scan-constraints.py, but that tool's PATTERNS list
# is hardcoded. The user's pattern was silently discarded.
#
# This patch:
#   a. adds --pattern to scan-constraints.py
#   b. when --pattern is given, PATTERNS becomes a single-entry list
#   c. --show-all still works: with a custom pattern, every match is
#      classified as code/string/comment, and --show-all controls
#      whether non-code matches are printed
#
#   argparse:
#     https://docs.python.org/3/library/argparse.html
#
# ============================================================================

set -o pipefail

SCANNER="scripts/scan-constraints.py"
[ -f "$SCANNER" ] || { printf 'not found: %s\n' "$SCANNER"; exit 2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
cp "$SCANNER" "$SCANNER.bak.$TS"
printf 'backup: %s.bak.%s\n' "$SCANNER" "$TS"

python3 - "$SCANNER" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

# 1. Extend argparse with --pattern
old_parser = '''    parser.add_argument("--quiet", action="store_true",
                        help="print only the summary")
    return parser.parse_args(argv)'''

new_parser = '''    parser.add_argument("--quiet", action="store_true",
                        help="print only the summary")
    parser.add_argument("--pattern", default=None, metavar="REGEX",
                        help="override the default constraint pattern set "
                             "with a single POSIX ERE")
    return parser.parse_args(argv)'''

if old_parser not in src:
    print("ERROR: parser block not found")
    sys.exit(3)
src = src.replace(old_parser, new_parser)

# 2. Thread pattern through report()
old_report = '''def report(
    root: Path,
    show_all: bool,
    quiet: bool,
) -> int:'''

new_report = '''def report(
    root: Path,
    show_all: bool,
    quiet: bool,
    custom_pattern: str | None = None,
) -> int:
    global PATTERNS
    if custom_pattern is not None:
        import re as _re
        PATTERNS = [("user", _re.compile(custom_pattern))]'''

if old_report not in src:
    print("ERROR: report signature not found")
    sys.exit(3)
src = src.replace(old_report, new_report)

# 3. Pass through from main()
old_main = '''    return report(args.root, args.show_all, args.quiet)'''

new_main = '''    return report(args.root, args.show_all, args.quiet,
                  custom_pattern=args.pattern)'''

if old_main not in src:
    print("ERROR: main return not found")
    sys.exit(3)
src = src.replace(old_main, new_main)

with open(path, "w") as f:
    f.write(src)
print("scan-constraints.py extended with --pattern")
PY_EOF

printf '\nverify:\n'
grep -n 'pattern' "$SCANNER" | head -10
