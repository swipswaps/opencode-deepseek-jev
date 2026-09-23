#!/usr/bin/env bash
#
# fix-env-file-injection.sh — fix the mis-injection from add-env-file.sh.
#
# Bug: add-env-file.sh inserted `env_file:` immediately after `- JEV_API_KEY`
# inside the environment: block. Every environment item that followed —
# OPENCODE_DISABLE_DEFAULT_PLUGINS=true and OPENCODE_SERVER_PASSWORD —
# got orphaned into the env_file list, where they are treated as file
# paths instead of environment variables.
#
# Result: the container starts, but those two variables are no longer set.
#
# This script:
#   1. Shows the current environment:/env_file: structure
#   2. Checks which OPENCODE_* vars the container actually sees
#   3. Removes the misplaced env_file block
#   4. Re-inserts it after the last environment item
#   5. Runs `docker compose config` to validate
#   6. Recreates the container and re-checks
#
# Idempotent. Backs up docker-compose.yml.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No bare kill. main() wrapper. python3 for text edits.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Compose env_file:
#     https://docs.docker.com/compose/compose-file/05-services/#env_file
#   Compose environment:
#     https://docs.docker.com/compose/compose-file/05-services/#environment
#   Docker compose config:
#     https://docs.docker.com/reference/cli/docker/compose/config/
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
COMPOSE_REL="docker/docker-compose.yml"
HTTP_URL="http://127.0.0.1:4096"

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

mask() {
    local s="$1"
    if [ ${#s} -le 12 ]; then printf '***'; return 0; fi
    printf '%s...%s' \
        "$(printf '%s' "$s" | cut -c1-8)" \
        "$(printf '%s' "$s" | rev | cut -c1-6 | rev)"
}

dump_container_env() {
    docker exec "$C" sh -c 'env | grep -E "^(DEEPSEEK|JEV|OPENCODE)" | sort' 2>&1 | \
        while IFS='=' read -r k v; do
            case "$k" in
                OPENCODE_SERVER_PASSWORD|DEEPSEEK_API_KEY|JEV_API_KEY)
                    printf '  %s=%s\n' "$k" "$(mask "$v")" ;;
                *)
                    printf '  %s=%s\n' "$k" "$v" ;;
            esac
        done
}

main() {
    local script_dir repo compose ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    compose="$repo/$COMPOSE_REL"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    printf '=== fix-env-file-injection.sh ===\n'
    printf 'Repo:    %s\n' "$repo"
    printf 'Compose: %s\n' "$compose"
    printf 'TS:      %s\n' "$ts"

    if [ ! -f "$compose" ]; then
        printf '\nGATE FAIL: %s not found\n' "$compose"
        return 1
    fi

    section "1. current structure (env + env_file region)"
    awk '/^    environment:/{show=1} show{print} show && /^    env_file:/{ef=1} ef && /^      - \.\.\//{efdone=1} show && /^    restart:|^    ports:|^    security_opt:/{exit}' "$compose" | indent

    section "2. container env (what it ACTUALLY sees)"
    dump_container_env

    section "3. detection"
    local mis_injected=0
    if grep -A3 '^    env_file:' "$compose" | grep -q 'OPENCODE_'; then
        mis_injected=1
        printf '  CONFIRMED: env_file block contains OPENCODE_ entries\n'
        printf '  those entries are treated as file paths, not variables\n'
    else
        printf '  no OPENCODE_ entries inside env_file block\n'
    fi

    local pe_missing=0
    if ! docker exec "$C" sh -c 'env | grep -q "^OPENCODE_SERVER_PASSWORD="' 2>&1; then
        pe_missing=1
        printf '  MISSING in container: OPENCODE_SERVER_PASSWORD\n'
    fi
    if ! docker exec "$C" sh -c 'env | grep -q "^OPENCODE_DISABLE_DEFAULT_PLUGINS="' 2>&1; then
        printf '  MISSING in container: OPENCODE_DISABLE_DEFAULT_PLUGINS\n'
    fi

    if [ "$mis_injected" -eq 0 ] && [ "$pe_missing" -eq 0 ]; then
        printf '\n  nothing to fix — structure and container env both consistent.\n'
        return 0
    fi

    section "4. patch compose"
    cp "$compose" "$compose.bak.${ts}"
    printf '  backup: %s.bak.%s\n' "$compose" "$ts"

    python3 - "$compose" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

misplaced = "    env_file:\n      - ../.env.local\n"
if misplaced not in src:
    print("  WARN: expected misplaced block not found; nothing to remove")
    sys.exit(0)
src = src.replace(misplaced, "", 1)
print("  removed misplaced env_file block")

# Anchor on the final env item that was orphaned. Try SERVER_PASSWORD
# first, then DISABLE_DEFAULT_PLUGINS.
anchor = "      - OPENCODE_SERVER_PASSWORD\n"
if anchor not in src:
    anchor = "      - OPENCODE_DISABLE_DEFAULT_PLUGINS=true\n"
if anchor not in src:
    anchor = "      - JEV_API_KEY\n"
if anchor not in src:
    print("  WARN: no anchor found; env_file not reinserted")
    with open(path, "w") as fh:
        fh.write(src)
    sys.exit(0)

src = src.replace(anchor, anchor + "    env_file:\n      - ../.env.local\n", 1)
print(f"  reinserted env_file block after: {anchor.strip()}")
with open(path, "w") as fh:
    fh.write(src)
PY

    section "5. structure after patch"
    awk '/^    environment:/{show=1} show{print} show && /^    restart:|^    ports:|^    security_opt:/{exit}' "$compose" | indent

    section "6. docker compose config (parse validation)"
    cd "$repo/docker" || return 1
    docker compose config >/dev/null 2>&1
    local cfg_rc=$?
    cd "$repo" || return 1
    if [ "$cfg_rc" -ne 0 ]; then
        printf '  FAIL: compose config returned %d\n' "$cfg_rc"
        printf '  rollback: cp %s.bak.%s %s\n' "$compose" "$ts" "$compose"
        printf '  (and: docker compose -f %s/docker/docker-compose.yml up -d --force-recreate opencode-web)\n' "$repo"
        return 1
    fi
    printf '  compose config: OK\n'

    section "7. recreate container"
    cd "$repo/docker" || return 1
    docker compose up -d --force-recreate opencode-web
    local rc=$?
    cd "$repo" || return 1
    if [ "$rc" -ne 0 ]; then
        printf '  FAIL: compose up returned %d\n' "$rc"
        return 1
    fi

    section "8. wait for HTTP"
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        printf '  %2d/60  http=%s\n' "$((tries + 1))" "$code"
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1))
        sleep 2
    done
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        printf '  FAIL: no listener after 120 s\n'
        return 1
    fi

    section "9. container env after recreate"
    dump_container_env

    section "summary"
    printf '  compose backup: %s.bak.%s\n' "$compose" "$ts"
    printf '  HTTP:           %s\n' "$code"

    local still_missing=0
    for v in OPENCODE_SERVER_PASSWORD OPENCODE_DISABLE_DEFAULT_PLUGINS; do
        if ! docker exec "$C" sh -c "env | grep -q '^${v}='" 2>&1; then
            printf '  STILL MISSING: %s\n' "$v"
            still_missing=1
        fi
    done
    if [ "$still_missing" -eq 1 ]; then
        printf '\n  Rollback: cp %s.bak.%s %s\n' "$compose" "$ts" "$compose"
        return 1
    fi

    printf '  all expected vars present in container.\n'
    return 0
}

main "$@"
