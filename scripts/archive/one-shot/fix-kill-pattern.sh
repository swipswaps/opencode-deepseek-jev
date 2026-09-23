#!/usr/bin/env bash
#
# fix-kill-pattern.sh — narrow the `kill N` pattern in scan-constraints.py.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The previous revision of this patch used a grep precondition that
# matched an exact run of spaces before `re.compile`. When the file's
# indentation differed by one space, the precondition failed and the
# patch aborted.
#
# This revision replaces the check with a name-based one: find the line
# containing `"kill N"` and `re.compile`, then replace the whole line.
# Indentation-independent.
#
# Old pattern: `kill\s+-?[0-9]+` matches both `kill 1234` (violation)
# and `kill -0 $pid` (liveness probe, not a violation).
#
# New pattern: `kill\s+[1-9][0-9]*` matches only the first form.
#
#   Linux kill(2) signal 0 semantics:
#     https://man7.org/linux/man-pages/man2/kill.2.html
#   POSIX kill(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/kill.html
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
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")
SCANNER="$REPO_DIR/scripts/scan-constraints.py"
TS=$(date -u +%Y%m%dT%H%M%SZ)

main() {
    printf '=== fix-kill-pattern.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'File: %s\n\n' "$SCANNER"

    if [ ! -f "$SCANNER" ]; then
        printf 'GATE FAIL: %s not found\n' "$SCANNER"
        return 1
    fi

    # Inspect the current kill pattern line.
    printf 'current kill N line:\n'
    grep -n '"kill N"' "$SCANNER" | while IFS= read -r line; do
        printf '  %s\n' "$line"
    done
    printf '\n'

    if ! grep -q '"kill N"' "$SCANNER"; then
        printf 'GATE FAIL: no line contains "kill N"\n'
        return 1
    fi

    if grep -q '"kill N".*kill\\s+\[1-9\]' "$SCANNER"; then
        printf 'PASS: pattern already narrowed (kill\\s+[1-9]...)\n'
        printf '      nothing to do.\n'
        return 0
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$SCANNER" "$SCANNER.bak.${TS}"
        printf 'backup: %s.bak.%s\n\n' "$SCANNER" "$TS"
    fi

    python3 - "$SCANNER" "$MODE" <<'PY_EOF'
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()

new_line = '    ("kill N",         re.compile(r"(?:^|[^A-Za-z0-9_])kill\\s+[1-9][0-9]*(?:[^0-9]|$)")),\n'

found = -1
for i, line in enumerate(lines):
    if '"kill N"' in line and 're.compile' in line:
        found = i
        break

if found < 0:
    print("ERROR: no line with \"kill N\" and re.compile", file=sys.stderr)
    sys.exit(3)

old_line = lines[found].rstrip("\n")
print(f"  old line {found + 1}:")
print(f"    {old_line}")
print(f"  new line {found + 1}:")
print(f"    {new_line.rstrip()}")

if mode == "apply":
    lines[found] = new_line
    with open(path, "w") as f:
        f.writelines(lines)
    print("\n  written")
PY_EOF

    if [ "$MODE" = "apply" ]; then
        printf '\n  syntax check:\n'
        if python3 -c "import ast,sys; ast.parse(open('$SCANNER').read())" 2>&1; then
            printf '    PASS\n'
        else
            printf '    FAIL\n'
        fi
        printf '\n  scanner smoke test:\n'
        python3 "$SCANNER" "$REPO_DIR/scripts" --exclude-dir archive --quiet 2>&1 || true
    fi

    printf '\n=== summary ===\n'
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED. backup: %s.bak.%s\n' "$SCANNER" "$TS"
    fi
    return 0
}

main "$@"
