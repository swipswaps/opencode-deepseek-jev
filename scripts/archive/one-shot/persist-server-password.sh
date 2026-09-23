#!/usr/bin/env bash
#
# persist-server-password.sh — make OPENCODE_SERVER_PASSWORD stable across
# container recreates without depending on the caller's shell state.
#
#   P1  Read the current password from the running container's env.
#   P2  Append it to .env.local if not already present.
#   P3  Remove the redundant line from the compose environment: block
#       so env_file becomes the single source of truth.
#   P4  Validate, recreate, and verify the password survives.
#
# Idempotent. Backs up .env.local and docker-compose.yml.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No bare kill. main() wrapper. python3 for text edits.
#
set -o pipefail

C="opencode-deepseek-web"
COMPOSE_REL="docker/docker-compose.yml"
ENV_REL=".env.local"

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

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' '    ' "$line"
    done
}

main() {
    local script_dir repo compose env_file ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    compose="$repo/$COMPOSE_REL"
    env_file="$repo/$ENV_REL"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    printf '=== persist-server-password.sh ===\n'
    printf 'Compose: %s\n' "$compose"
    printf 'Env:     %s\n' "$env_file"

    section "P1  read password from container"
    local current
    current=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    if [ -z "$current" ]; then
        printf '  GATE FAIL: OPENCODE_SERVER_PASSWORD empty in container\n'
        return 1
    fi
    printf '  length: %d chars\n' "${#current}"

    section "P2  append to .env.local if absent"
    if grep -q '^OPENCODE_SERVER_PASSWORD=' "$env_file" 2>&1; then
        printf '  already present — leaving as-is\n'
    else
        cp "$env_file" "$env_file.bak.${ts}"
        printf '  backup: %s.bak.%s\n' "$env_file" "$ts"
        printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$current" >> "$env_file"
        chmod 600 "$env_file"
        printf '  appended\n'
    fi
    ls -la "$env_file" | indent

    section "P3  remove redundant pass-through from compose"
    if ! grep -q 'OPENCODE_SERVER_PASSWORD: "\${OPENCODE_SERVER_PASSWORD:-}"' "$compose"; then
        printf '  already absent — nothing to do\n'
    else
        cp "$compose" "$compose.bak.${ts}"
        printf '  backup: %s.bak.%s\n' "$compose" "$ts"
        python3 - "$compose" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()
target = '      OPENCODE_SERVER_PASSWORD: "${OPENCODE_SERVER_PASSWORD:-}"\n'
if target in src:
    src = src.replace(target, "", 1)
    with open(path, "w") as fh:
        fh.write(src)
    print("  removed pass-through line")
else:
    print("  WARN: target line not found")
PY
    fi

    section "P4  recreate and verify persistence"
    ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 ) || {
        printf '  FAIL: compose config rejected file\n'
        printf '  rollback: cp %s.bak.%s %s\n' "$compose" "$ts" "$compose"
        return 1
    }
    printf '  compose config: OK\n'

    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web ) || {
        printf '  FAIL: compose up\n'
        return 1
    }

    # Wait for HTTP
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:4096/" 2>&1)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1))
        sleep 2
    done
    printf '  http=%s\n' "$code"

    local after
    after=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    if [ "$after" = "$current" ]; then
        printf '  PASS password stable across recreate\n'
    else
        printf '  FAIL password changed\n'
        printf '    before: length %d\n' "${#current}"
        printf '    after:  length %d\n' "${#after}"
        return 1
    fi

    section "P5  sanity: auth + providers"
    docker exec -w /workspace "$C" sh -c 'opencode providers list' 2>&1 | indent

    printf '\n=== done ===\n'
    printf 'Password persists in %s. Restart-safe.\n' "$env_file"
    printf 'Browser basic-auth user: opencode, password: %s\n' "$current"
    return 0
}

main "$@"
