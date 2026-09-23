#!/usr/bin/env bash
#
# sweep-exit1.sh
#
# Stipulation: no `exit 1`. return 1 instead.
# exit 2, exit 3, exit 130 are permitted and left untouched.
#
# Only touches scripts that define a main() function, because return
# outside a function fails with "can only return from a function or
# sourced script".
#
# Idempotent. Backs up. Syntax-checks; rolls back on failure.
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
    local script_dir repo ts target_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n' >&2
        return 2
    fi
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    target_dir="$repo/scripts/archive/one-shot"

    printf '=== sweep-exit1.sh ===\n'
    printf 'target: %s\n\n' "$target_dir"

    local scanned=0 changed=0 rolled=0 f

    for f in "$target_dir"/*.sh; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            sweep-exit1.sh) continue ;;
            *.bak.*) continue ;;
        esac
        scanned=$((scanned + 1))

        grep -qE '^[[:space:]]*main[[:space:]]*\(\)' "$f" || continue
        grep -qE '\bexit[[:space:]]+1\b' "$f" || continue

        cp "$f" "$f.bak.${ts}"

        local out
        out=$(python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
new, n = re.subn(r'\bexit[ \t]+1\b', 'return 1', src)
if n == 0:
    print("NO_CHANGE")
    sys.exit(0)
open(path, "w").write(new)
print(f"CHANGED {n}")
PY
)
        case "$out" in
            CHANGED*)
                printf '  %s: %s\n' "$(basename "$f")" "$out"
                if bash -n "$f" 2>&1; then
                    changed=$((changed + 1))
                else
                    printf '    syntax FAIL, rollback\n'
                    cp "$f.bak.${ts}" "$f"
                    rolled=$((rolled + 1))
                fi
                ;;
            NO_CHANGE)
                rm -f "$f.bak.${ts}"
                ;;
        esac
    done

    printf '\nscanned=%d changed=%d rolled=%d\n' "$scanned" "$changed" "$rolled"

    printf '\nremaining exit 1 in one-shot (excluding .bak and this sweep):\n'
    local rem
    rem=$(grep -lE '\bexit[[:space:]]+1\b' "$target_dir"/*.sh 2>&1 \
          | grep -v '\.bak\.' | grep -v 'sweep-exit1')
    if [ -z "$rem" ]; then
        printf '  (none)\n'
    else
        printf '%s\n' "$rem" | while IFS= read -r line; do printf '  %s\n' "$line"; done
    fi

    return 0
}

main "$@"
