#!/usr/bin/env bash
#
# rewrap-chatlog.sh — restore chatlog.sh from backup, then apply the
# correct fix: wrap top-level code in main() so `return N` is legal.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# chatlog.sh currently has top-level `return 1` statements introduced by
# fix-chatlog-and-scanner.sh's F1 step. `return 1` violates the stated
# constraint. The original code had `return 1` at top-level, which Bash
# rejects with "can only `return' from a function or sourced script".
#
# The correct fix for both: wrap the top-level logic in a function.
# Inside a function, `return 1` is legal, and no `return 1` is needed.
#
#   Bash Manual §4.1 Bourne Shell Builtins:
#     https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
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
BACKUPS="$SCRIPTS/archive/one-shot/backups"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== rewrap-chatlog.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n' "$REPO_DIR"

    # ---- Step 1: restore from the most recent backup -------------------
    section "Step 1: restore chatlog.sh from most recent backup"
    local latest_bak
    latest_bak=$(find "$SCRIPTS" "$BACKUPS" -maxdepth 1 -name 'chatlog.sh.bak.*' 2>&1 \
                 | sort | tail -1)

    if [ -z "$latest_bak" ] || [ ! -f "$latest_bak" ]; then
        printf '  no backup found under %s or %s\n' "$SCRIPTS" "$BACKUPS"
        printf '  cannot proceed without a known-good baseline\n'
        return 1
    fi

    printf '  restoring from: %s\n' "$latest_bak"
    if [ "$MODE" = "apply" ]; then
        cp "$latest_bak" "$CHATLOG"
    fi
    printf '  %s\n' "$([ "$MODE" = "apply" ] && printf restored || printf "would restore")"

    # ---- Step 2: wrap top-level logic in main() ------------------------
    section "Step 2: wrap top-level logic in main()"
    if [ "$MODE" = "apply" ]; then
        python3 - "$CHATLOG" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find the line after `set -o pipefail`. Insert `main() {` after it.
insert_at = None
for i, line in enumerate(lines):
    if line.strip() == "set -o pipefail":
        insert_at = i + 1
        break

if insert_at is None:
    print("ERROR: `set -o pipefail` not found", file=sys.stderr)
    sys.exit(3)

# Avoid double-wrapping
if any("main() {" in line for line in lines[:insert_at + 5]):
    print("already wrapped")
    sys.exit(0)

lines.insert(insert_at, "\nmain() {\n")

# Append `}` and `main "$@"` at the end.
# Ensure a trailing newline.
if lines and not lines[-1].endswith("\n"):
    lines[-1] += "\n"
lines.append("\n}\n\nmain \"$@\"\n")

with open(path, "w") as f:
    f.writelines(lines)
print("wrapped")
PY_EOF
    else
        printf '  would insert "main() {" after set -o pipefail\n'
        printf '  would append "}" and "main \\"$@\\"" at end of file\n'
    fi

    # ---- Step 3: fix the search arm (works whether return or exit) -----
    section "Step 3: fix chatlog.sh search arm"
    if [ "$MODE" = "apply" ]; then
        python3 - "$CHATLOG" <<'PY_EOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Two possible current forms, depending on whether F1 already ran.
candidates = [
'''            python3 "$scanner" "$NOTES_DIR" --pattern "$pattern" --show-all
            return $?''',
'''            python3 "$scanner" "$NOTES_DIR" --pattern "$pattern" --show-all
            exit $?''',
]

new = '''            python3 "$scanner" "$NOTES_DIR" \\
                --pattern "$pattern" \\
                --include '*.txt' \\
                --include '*.md' \\
                --exclude-dir archive \\
                --show-all
            return $?'''

for old in candidates:
    if old in src:
        src = src.replace(old, new)
        with open(path, "w") as f:
            f.write(src)
        print("search arm patched")
        sys.exit(0)

print("ERROR: search arm not found in either form", file=sys.stderr)
sys.exit(3)
PY_EOF
    else
        printf '  would replace the search arm with the include/exclude form\n'
    fi

    # ---- Verification --------------------------------------------------
    section "verification"
    if [ "$MODE" != "apply" ]; then
        printf 'skipped (dry-run)\n'
        return 0
    fi

    printf 'top-level return/exit count outside functions:\n'
    python3 - "$CHATLOG" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# After the wrap, everything between `main() {` and the closing `}` is
# inside the function. Count only `return` / `exit` before `main() {` or
# after the closing brace.
in_main = False
depth = 0
outside = 0
for line in lines:
    s = line.strip()
    if s == "main() {":
        in_main = True
        depth = 1
        continue
    if in_main:
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            in_main = False
        continue
    if re.match(r"(return|exit)\s+[0-9]", s):
        outside += 1
        print(f"  line: {s}")
print(f"  total: {outside}")
PY_EOF

    printf '\nscanner with --exclude-dir archive:\n'
    python3 "$SCRIPTS/scan-constraints.py" "$SCRIPTS" --exclude-dir archive --quiet || true

    printf '\nchatlog.sh search smoke test:\n'
    "$CHATLOG" search "no fail" | head -20 || true
}

main "$@"
