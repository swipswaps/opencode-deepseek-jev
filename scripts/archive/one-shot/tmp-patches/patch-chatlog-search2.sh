#!/usr/bin/env bash
#
# patch-chatlog-search2.sh — fix chatlog.sh search so the user's pattern
# is actually passed to scan-constraints.py.
#
# The prior patch called the scanner without an argument, discarding the
# pattern the user typed. This corrects that.
#
# ============================================================================

set -o pipefail

TARGET="scripts/chatlog.sh"
[ -f "$TARGET" ] || { printf 'not found: %s\n' "$TARGET"; exit 2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
cp "$TARGET" "$TARGET.bak.$TS"
printf 'backup: %s.bak.%s\n' "$TARGET" "$TS"

python3 - "$TARGET" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

old = '''    search)
        pattern="${1:-}"
        [ -z "$pattern" ] && { printf 'usage: chatlog.sh search <pattern>\\n'; return 2; }
        local scanner="$SCRIPT_DIR/scan-constraints.py"
        if [ -x "$scanner" ]; then
            python3 "$scanner" "$NOTES_DIR" --show-all --quiet
            printf '\\nNote: see scan-constraints.py output for typed matches.\\n'
            return 0
        fi
        find "$NOTES_DIR" -maxdepth 2 -type f \\
            \\( -name '*.txt' -o -name '*.md' \\) 2>&1 | sort | while IFS= read -r f; do
            grep -n -- "$pattern" "$f" 2>&1 | while IFS= read -r hit; do
                printf '%s:%s\\n' "${f#$NOTES_DIR/}" "$hit"
            done
        done
        ;;
'''

new = '''    search)
        pattern="${1:-}"
        [ -z "$pattern" ] && { printf 'usage: chatlog.sh search <pattern>\\n'; return 2; }
        local scanner="$SCRIPT_DIR/scan-constraints.py"
        if [ -x "$scanner" ]; then
            python3 "$scanner" "$NOTES_DIR" --pattern "$pattern" --show-all
            return $?
        fi
        find "$NOTES_DIR" -maxdepth 2 -type f \\
            \\( -name '*.txt' -o -name '*.md' \\) 2>&1 | sort | while IFS= read -r f; do
            grep -n -- "$pattern" "$f" 2>&1 | while IFS= read -r hit; do
                printf '%s:%s\\n' "${f#$NOTES_DIR/}" "$hit"
            done
        done
        ;;
'''

if old not in src:
    print("ERROR: search block not found verbatim")
    sys.exit(3)
src = src.replace(old, new)
with open(path, "w") as f:
    f.write(src)
print("chatlog.sh search patched")
PY_EOF
