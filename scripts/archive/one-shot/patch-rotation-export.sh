#!/usr/bin/env bash
#
# patch-rotation-export.sh — make rotation scripts export the new keys
# into the shell before calling docker compose.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

main() {
    local script_dir repo
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi

    local f="$repo/scripts/archive/one-shot/rotate-keys-guided.sh"
    printf '=== patch-rotation-export.sh ===\n'
    printf 'Target: %s\n\n' "$f"

    if [ ! -f "$f" ]; then
        printf '  SKIP not present\n'
        return 0
    fi

    cp "$f" "$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"

    python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

if "export DEEPSEEK_API_KEY" in src:
    print("  export already present; no change")
    sys.exit(0)

# Find the section header for "4. recreate container" and insert
# export lines right before it.
marker = 'section "4. recreate container"'
inject = (
    'section "4. export keys to shell (compose reads from host env)"\n'
    '    export DEEPSEEK_API_KEY="$ds_key"\n'
    '    export JEV_API_KEY="$jev_key"\n'
    '    printf \'  exported DEEPSEEK_API_KEY and JEV_API_KEY\\n\'\n'
    '\n'
)
if marker not in src:
    print("  WARN: section marker not found")
    sys.exit(0)

src = src.replace(marker, inject + marker, 1)
with open(path, "w") as fh:
    fh.write(src)
print("  injected export block before section 4")
PY

    printf '\n  syntax check: '
    bash -n "$f" && printf 'OK\n'
    return 0
}

main "$@"
