#!/usr/bin/env bash
#
# probe-project-state.sh — read-only orientation for the opencode-deepseek
# repo. Answers: what is this project, what is JEV, what HTTP routes exist.
#
# No writes, no restart, no mutations. Safe to run repeatedly.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
#   No subprocess.run (no python). No bare kill.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX grep(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/grep.html
#   Docker inspect:
#     https://docs.docker.com/engine/reference/commandline/inspect/
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
DATA_DIR="/home/node/.local/share/opencode"
URL="http://127.0.0.1:4096"

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=$(resolve_repo "$SCRIPT_DIR")
[ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
if [ -z "$REPO" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

printf '=== probe-project-state.sh ===\n'
printf 'Repo: %s\n' "$REPO"

# --------------------------------------------------------------------------
section "1. repo identity (top of key docs)"
# --------------------------------------------------------------------------
for f in README.txt QUICKSTART.txt opencode.json .env.local; do
    if [ -f "$REPO/$f" ]; then
        printf '\n--- %s (first 25 lines) ---\n' "$f"
        head -25 "$REPO/$f" | indent
    else
        printf '\n--- %s (absent) ---\n' "$f"
    fi
done

# --------------------------------------------------------------------------
section "2. files referencing JEV (case-insensitive, text only)"
# --------------------------------------------------------------------------
if command -v grep >/dev/null; then
    printf 'search root: %s\n' "$REPO"
    grep -rilI 'jev' "$REPO" \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=.venv \
        --exclude='*.db' \
        --exclude='*.db-wal' \
        --exclude='*.db-shm' 2>&1 \
        | head -40 | indent
fi

# --------------------------------------------------------------------------
section "3. JEV hits in configs"
# --------------------------------------------------------------------------
for f in .env.local docker/docker-compose.yml docker/Dockerfile docker/web-entrypoint.sh opencode.json; do
    if [ -f "$REPO/$f" ]; then
        hits=$(grep -inI 'jev' "$REPO/$f" 2>&1)
        if [ -n "$hits" ]; then
            printf '\n--- %s ---\n' "$f"
            printf '%s\n' "$hits" | indent
        fi
    fi
done
printf '\n(no output above = no JEV references in tracked configs)\n'

# --------------------------------------------------------------------------
section "4. HTTP API endpoint discovery (no auth, 3 s timeout)"
# --------------------------------------------------------------------------
printf '%-28s %s\n' "endpoint" "http"
for ep in / /api /api/session /api/sessions /session /sessions \
          /health /api/health /openapi.json /doc /api/doc \
          /api/v1 /api/v1/session /event /api/event; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "${URL}${ep}" 2>&1)
    printf '  %-26s %s\n' "$ep" "$code"
done

# --------------------------------------------------------------------------
section "5. container entrypoint + command (what actually runs)"
# --------------------------------------------------------------------------
docker inspect -f 'Entrypoint: {{json .Config.Entrypoint}}' "$C" 2>&1 | indent
docker inspect -f 'Cmd:        {{json .Config.Cmd}}'        "$C" 2>&1 | indent
docker inspect -f 'Image:      {{.Config.Image}}'          "$C" 2>&1 | indent
docker inspect -f 'Started:    {{.State.StartedAt}}'       "$C" 2>&1 | indent

# --------------------------------------------------------------------------
section "6. fresh session-count snapshot"
# --------------------------------------------------------------------------
local_db="/tmp/opencode-probe.db"
docker cp "$C:$DATA_DIR/opencode.db" "$local_db" 2>&1 | indent
if [ -f "$local_db" ] && command -v sqlite3 >/dev/null; then
    total=$(sqlite3 "$local_db" "select count(*) from session;" 2>&1)
    printf '  session rows: %s\n' "$total"
    printf '\n  last 8 sessions:\n'
    sqlite3 -header "$local_db" \
        "select id, substr(title,1,45) as title, time_created
           from session order by time_created desc limit 8;" 2>&1 | indent
fi

# --------------------------------------------------------------------------
section "7. repo inventory"
# --------------------------------------------------------------------------
printf 'top level:\n'
ls -1 "$REPO" 2>&1 | indent

printf '\nscripts/archive/one-shot/:\n'
ls -1 "$REPO/scripts/archive/one-shot/" 2>&1 | indent

printf '\ndocker/:\n'
ls -1 "$REPO/docker/" 2>&1 | indent

if [ -f "$REPO/push_notes_v18.sh" ]; then
    printf '\n--- push_notes_v18.sh (first 20 lines) ---\n'
    head -20 "$REPO/push_notes_v18.sh" | indent
fi

printf '\n=== done ===\n'
