#!/usr/bin/env bash
#
# patch-ask.sh — remove the sole 2>/dev/null occurrence from ask.sh.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The offending line:
#
#   local_cid=$(docker ps -q --filter "ancestor=$IMAGE" --latest 2>/dev/null | head -1)
#
# The redirect is unnecessary. `docker ps` returns exit 0 and empty
# stdout when no container matches the filter. It does not need stderr
# suppression. The constraint forbids 2>/dev/null unconditionally.
#
#   Docker ps reference:
#     https://docs.docker.com/engine/reference/commandline/ps/
#
#   Bash redirection:
#     https://www.gnu.org/software/bash/manual/html_node/Redirections.html
#
# ============================================================================

set -o pipefail

TARGET="scripts/ask.sh"
[ -f "$TARGET" ] || { printf 'not found: %s\n' "$TARGET"; exit 2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
cp "$TARGET" "$TARGET.bak.$TS"
printf 'backup: %s.bak.%s\n' "$TARGET" "$TS"

python3 - "$TARGET" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

old = 'local_cid=$(docker ps -q --filter "ancestor=$IMAGE" --latest 2>/dev/null | head -1)'
new = 'local_cid=$(docker ps -q --filter "ancestor=$IMAGE" --latest | head -1)'

if old not in src:
    print("ERROR: target line not found verbatim")
    sys.exit(3)

count = src.count(old)
src = src.replace(old, new)
with open(path, "w") as f:
    f.write(src)
print(f"replaced {count} occurrence(s)")
PY_EOF

printf '\nverifying no 2>/dev/null remains:\n'
if grep -n '2>/dev/null' "$TARGET"; then
    printf 'FAIL: 2>/dev/null still present\n'
    exit 1
else
    printf 'PASS: zero occurrences of 2>/dev/null in %s\n' "$TARGET"
fi
