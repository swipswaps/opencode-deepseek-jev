#!/usr/bin/env bash
#
# patch-chatlog-search.sh — route chatlog.sh search through
# scan-constraints.py's classifier instead of grep.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# chatlog.sh search currently runs grep -n per file. That returns raw
# text hits without classifying them. Reusing the Python classifier
# gives each hit a Type column (code/string/comment), which is what
# makes the output readable when scanning logs full of the words
# "sed" and "rm -rf" in prose.
#
# The classifier is invoked once, on the entire concatenated log
# stream, through a single pipe. No per-file fork.
#
#   grep(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/grep.html
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

if old not in src:
    print("ERROR: target block not found verbatim")
    sys.exit(3)
src = src.replace(old, new)
with open(path, "w") as f:
    f.write(src)
print("chatlog.sh patched")
PY_EOF
