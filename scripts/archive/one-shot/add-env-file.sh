#!/usr/bin/env bash
#
# add-env-file.sh — add `env_file: ../.env.local` to the opencode-web
# service so the container receives DEEPSEEK_API_KEY and JEV_API_KEY
# without the host shell needing to export them.
#
# Idempotent. Backs up docker-compose.yml before editing.
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

    local compose="$repo/docker/docker-compose.yml"
    if [ ! -f "$compose" ]; then
        printf 'GATE FAIL: %s not found\n' "$compose"
        return 1
    fi

    printf '=== add-env-file.sh ===\n'
    printf 'Target: %s\n\n' "$compose"

    if grep -q 'env_file:' "$compose"; then
        printf '  env_file already present; nothing to do\n'
        return 0
    fi

    cp "$compose" "$compose.bak.$(date -u +%Y%m%dT%H%M%SZ)"

    python3 - "$compose" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    lines = fh.read().split("\n")

out = []
injected = 0
for line in lines:
    out.append(line)
    # After the "environment:" block of the opencode-web service, insert env_file.
    if line.strip().startswith("- JEV_API_KEY") and injected == 0:
        # Environment block ends here; add env_file after.
        out.append("    env_file:")
        out.append("      - ../.env.local")
        injected += 1

if injected == 0:
    print("  WARN: could not find anchor '- JEV_API_KEY'; no change")
    sys.exit(0)

with open(path, "w") as fh:
    fh.write("\n".join(out))
print("  injected env_file block after JEV_API_KEY entry")
PY

    printf '\n  verify:\n'
    grep -n -A2 'env_file' "$compose" | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done

    printf '\n  next: re-run restore-keys-to-container.sh (or docker compose up -d)\n'
    return 0
}

main "$@"
