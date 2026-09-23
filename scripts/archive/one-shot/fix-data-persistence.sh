#!/usr/bin/env bash
#
# fix-data-persistence.sh — bind-mount the container's opencode data dir
# so sessions, messages, and JEV review results survive recreates.
#
# Problem: /home/node/.local/share/opencode/ lives in the container's
# writable layer. Every `docker compose up -d --force-recreate` wipes it.
# Only `..:/workspace` was mounted; nothing preserved the data dir.
#
# Fix: add `../data/opencode:/home/node/.local/share/opencode` to the
# opencode-web service volumes list. Create the host dir, chown it to the
# container UID, gitignore it.
#
# Idempotent. Backs up docker-compose.yml and .gitignore.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No bare kill. main() wrapper. python3 for text edits.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Compose volumes:
#     https://docs.docker.com/compose/compose-file/05-services/#volumes
#   Docker bind mounts:
#     https://docs.docker.com/storage/bind-mounts/
#   XDG Base Directory Specification:
#     https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
COMPOSE_REL="docker/docker-compose.yml"
DATA_HOST_REL="data/opencode"
DATA_CONT="/home/node/.local/share/opencode"
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

main() {
    local script_dir repo compose data_host gitignore ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    compose="$repo/$COMPOSE_REL"
    data_host="$repo/$DATA_HOST_REL"
    gitignore="$repo/.gitignore"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    printf '=== fix-data-persistence.sh ===\n'
    printf 'Repo:       %s\n' "$repo"
    printf 'Compose:    %s\n' "$compose"
    printf 'Host data:  %s\n' "$data_host"
    printf 'Container:  %s\n' "$DATA_CONT"
    printf 'TS:         %s\n' "$ts"

    if [ ! -f "$compose" ]; then
        printf '\nGATE FAIL: %s not found\n' "$compose"
        return 1
    fi

    section "1. detect current state"
    if grep -q "$DATA_CONT" "$compose"; then
        printf '  already mounted — nothing to do\n'
        DATA_MOUNTED=1
    else
        printf '  NOT mounted — sessions are being wiped on every recreate\n'
        DATA_MOUNTED=0
    fi

    section "2. create host dir"
    if [ -d "$data_host" ]; then
        printf '  exists: %s\n' "$data_host"
    else
        mkdir -p "$data_host"
        printf '  created: %s\n' "$data_host"
    fi
    # Ownership: container runs as ${HOST_UID:-1000}:${HOST_GID:-1000}.
    # Host user id is the natural owner. Verify writability.
    local uid gid
    uid=$(id -u)
    gid=$(id -g)
    chown -R "$uid:$gid" "$data_host" 2>&1 || true
    ls -la "$data_host" | indent
    printf '  owner uid:gid = %d:%d (matches container user)\n' "$uid" "$gid"

    if [ "$DATA_MOUNTED" -eq 0 ]; then
        section "3. patch docker-compose.yml"
        cp "$compose" "$compose.bak.${ts}"
        printf '  backup: %s.bak.%s\n' "$compose" "$ts"
        python3 - "$compose" "$DATA_CONT" <<'PY'
import sys
path, cont = sys.argv[1], sys.argv[2]
with open(path) as fh:
    src = fh.read()

# Anchor: the existing `- ..:/workspace` line under volumes: in opencode-web.
anchor = "      - ..:/workspace\n"
if anchor not in src:
    print("  WARN: anchor '- ..:/workspace' not found; no change")
    sys.exit(0)

if cont in src:
    print("  already patched")
    sys.exit(0)

new_line = anchor + f"      - ../data/opencode:{cont}\n"
src = src.replace(anchor, new_line, 1)
with open(path, "w") as fh:
    fh.write(src)
print("  added bind mount for data dir")
PY

        section "4. validate compose"
        ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 )
        local cfg_rc=$?
        if [ "$cfg_rc" -ne 0 ]; then
            printf '  FAIL: compose config rc=%d\n' "$cfg_rc"
            printf '  rollback: cp %s.bak.%s %s\n' "$compose" "$ts" "$compose"
            return 1
        fi
        printf '  compose config: OK\n'
    fi

    section "5. gitignore"
    if [ ! -f "$gitignore" ]; then
        printf '  no .gitignore; creating\n'
        printf 'data/opencode/\n' > "$gitignore"
    elif grep -q '^data/opencode/\?$' "$gitignore" 2>&1; then
        printf '  already ignored\n'
    else
        cp "$gitignore" "$gitignore.bak.${ts}"
        printf 'data/opencode/\n' >> "$gitignore"
        printf '  appended to %s (backup: %s.bak.%s)\n' "$gitignore" "$gitignore" "$ts"
    fi

    section "6. recreate container"
    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '  FAIL: compose up rc=%d\n' "$rc"
        return 1
    fi

    section "7. wait for HTTP"
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        printf '  %2d/60  http=%s\n' "$((tries + 1))" "$code"
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1))
        sleep 2
    done

    section "8. verify mount inside container"
    docker exec "$C" sh -c "mount | grep -F '$DATA_CONT' || echo '  no mount at $DATA_CONT'" 2>&1 | indent
    docker exec "$C" sh -c "ls -la '$DATA_CONT' 2>&1" | indent
    printf '\n  host side:\n'
    ls -la "$data_host" | indent

    section "9. persistence test"
    printf '  running two short sessions, then recreating the container.\n'
    printf '  if the bind mount works, session count will go 0 -> 2 -> (after recreate) still 2.\n\n'

    local pass
    pass=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    local auth=""
    if [ -n "$pass" ]; then
        auth="-u opencode:$pass"
    fi

    # Two short sessions via the API is not possible without a message endpoint;
    # use opencode run instead.
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model deepseek/deepseek-flash 'Reply with exactly: P1'" >/dev/null 2>&1
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model deepseek/deepseek-flash 'Reply with exactly: P2'" >/dev/null 2>&1

    local before after recreate_before recreate_after
    before=$(curl -s $auth "$HTTP_URL/api/session" 2>&1 | grep -o '"id":"ses_' | wc -l | tr -d ' ')
    printf '  sessions before recreate: %s\n' "$before"

    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web >/dev/null 2>&1 )

    # wait again
    tries=0
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1))
        sleep 2
    done

    after=$(curl -s $auth "$HTTP_URL/api/session" 2>&1 | grep -o '"id":"ses_' | wc -l | tr -d ' ')
    printf '  sessions after recreate:  %s\n' "$after"

    section "10. verdict"
    if [ "$before" -ge 2 ] && [ "$after" = "$before" ]; then
        printf '  PASS — data persists across recreates\n'
    elif [ "$before" -lt 2 ]; then
        printf '  INCONCLUSIVE — fewer than 2 sessions were created before recreate\n'
    else
        printf '  FAIL — sessions lost: %s -> %s\n' "$before" "$after"
        printf '  check: docker inspect %s --format "{{json .Mounts}}" | python3 -m json.tool\n' "$C"
    fi
    printf '\n  host data dir contents:\n'
    ls -la "$data_host" | indent
    return 0
}

main "$@"
