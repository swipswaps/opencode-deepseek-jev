#!/usr/bin/env bash
#
# patch-printf.sh — fix the printf option-parsing bug in apply-consolidate.sh.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# GNU printf parses its first argument for options if that argument begins
# with `-`. A format string beginning with `---` is therefore treated as
# an option sequence, and `---` is not recognized, so printf fails.
#
#   Bash manual, printf builtin:
#   https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html#index-printf
#
#   POSIX printf, §OPTIONS:
#   "If the first argument is --, it shall be treated as a delimiter
#    indicating the end of options."
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   GNU coreutils printf-invocation:
#   https://www.gnu.org/software/coreutils/manual/html_node/printf-invocation.html
#
# The canonical fix is to insert `--` between the command name and the
# format string. `printf -- FORMAT [ARGS]` disables further option
# parsing, so `---` in the format is treated as literal text.
#
# This patcher rewrites every occurrence of the pattern:
#     printf '--- X
# to:
#     printf -- '--- X
# ============================================================================

set -o pipefail

TARGET="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/apply-consolidate.sh"

if [ ! -f "$TARGET" ]; then
    printf 'FAIL: target not found: %s\n' "$TARGET"
    return 1
fi

# Back up the original. Use a timestamped suffix so re-runs do not clobber.
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$TARGET.bak.$TIMESTAMP"
cp "$TARGET" "$BACKUP"
printf 'backup written: %s\n' "$BACKUP"

# Apply the replacement via python3, which is available (the user's
# scripts already rely on it).
#
# The replacement is literal: find the exact substring:
#     printf '---
# and rewrite it as:
#     printf -- '---
# This is a pure text substitution. No regex metacharacters are involved
# in the search string, so Python's str.replace() is a safe choice.
python3 - "$TARGET" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = "printf '--- "
new = "printf -- '--- "
count = content.count(old)
content = content.replace(old, new)

with open(path, 'w') as f:
    f.write(content)

print(f"patched {count} occurrences of \"printf '--- \" -> \"printf -- '--- \"")
PY_EOF

printf '\nverify:\n'
grep -n "printf -- '--- " "$TARGET" 2>&1 || printf '  (none found)\n'

printf '\nRemaining unfixed printf with leading dash (if any):\n'
grep -n "printf '--" "$TARGET" 2>&1 || printf '  (none)\n'
