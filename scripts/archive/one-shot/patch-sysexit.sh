#!/usr/bin/env bash
#
# patch-sysexit.sh -- remove sys.exit(N) from Python heredocs in
# one-shot scripts. Shell inspects the marker; Python exits 0 always.
#
# Idempotent. Excludes itself by basename. Backs up.
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
    [ -z "$repo" ] && { printf 'GATE FAIL\n'; return 2; }
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    target_dir="$repo/scripts/archive/one-shot"

    printf '=== patch-sysexit.sh ===\n'
    printf 'repo: %s\n\n' "$repo"

    # Find every file with sys.exit inside a PY heredoc.
    printf 'offenders:\n'
    local f
    for f in "$target_dir"/*.sh; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            patch-sysexit.sh) continue ;;
        esac
        if grep -q 'sys\.exit' "$f"; then
            printf '  %s\n' "$(basename "$f")"
        fi
    done

    printf '\nno automated rewrite -- this is a structural change.\n'
    printf 'edit each file: delete every `sys.exit(N)`, add a stdout marker\n'
    printf 'in the failure branch, wrap the python3 call in $(...) and a\n'
    printf 'case on the marker.\n'
    printf '\nfor the immediate offenders (patch-ls-2devnull-v2.sh, final-audit.sh):\n\n'

    cat <<'SUGGEST'
# patch-ls-2devnull-v2.sh, inside the for loop, replace:

    python3 - "$f" "$ts" <<'PY'
    ...
    if n == 0:
        sys.exit(1)
    with open(path + ".bak." + ts, "w") as fh:
        fh.write(src)
    with open(path, "w") as fh:
        fh.write(new)
    print(f"  {path}: {n} replacement(s)")
    sys.exit(0)
    PY
    [ $? -eq 0 ] && changed=$((changed + 1))

# with:

    result=$(python3 - "$f" "$ts" <<'PY'
    ...
    if n == 0:
        print("NO_MATCH")
    else:
        with open(path + ".bak." + ts, "w") as fh:
            fh.write(src)
        with open(path, "w") as fh:
            fh.write(new)
        print(f"REPLACED={n}")
    PY
    )
    case "$result" in
        REPLACED=*) printf '  %s\n' "$result"; changed=$((changed + 1)) ;;
        NO_MATCH)   ;;
        *)          printf '  WARN unexpected: %s\n' "$result" ;;
    esac
SUGGEST

    return 0
}

main "$@"
