#!/usr/bin/env bash
#
# probe-jev-activation.sh — confirm whether the JEV guard/review stack is
# actually active in the running container.
#
# Read-only. No writes, no restart, no mutations.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
#   No subprocess.run (no python). No bare kill.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX read(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/read.html
#   Docker exec:
#     https://docs.docker.com/engine/reference/commandline/exec/
#   Docker logs:
#     https://docs.docker.com/engine/reference/commandline/logs/
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
DATA_DIR="/home/node/.local/share/opencode"
CONFIG_DIR="/home/node/.config/opencode"
MODEL="deepseek/deepseek-flash"
PROBE_PROMPT="Reply with exactly: JEVPING"

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
    printf 'GATE FAIL: cannot resolve repo\n'
    return 2
fi

printf '=== probe-jev-activation.sh ===\n'
printf 'Repo: %s\n' "$REPO"

# --------------------------------------------------------------------------
section "1. /opt/jev-review baked into image?"
# --------------------------------------------------------------------------
docker exec "$C" sh -c '
    echo "--- /opt/jev-review ---"
    ls -la /opt/jev-review/ 2>&1
    echo
    echo "--- /opt/jev-review/dist ---"
    ls -la /opt/jev-review/dist/ 2>&1
    echo
    echo "--- /opt/jev-review/skills ---"
    ls -la /opt/jev-review/skills/ 2>&1
' | indent

# --------------------------------------------------------------------------
section "2. processes inside container"
# --------------------------------------------------------------------------
docker exec "$C" sh -c '
    for p in /proc/[0-9]*; do
        pid=$(basename "$p")
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr "\000" " " < "$p/cmdline" 2>&1)
        [ -z "$cmd" ] && continue
        printf "%6s  %s\n" "$pid" "$cmd"
    done
' 2>&1 | indent

# --------------------------------------------------------------------------
section "3. plugin + config locations under HOME"
# --------------------------------------------------------------------------
docker exec "$C" sh -c "
    echo '--- $CONFIG_DIR ---'
    ls -la $CONFIG_DIR 2>&1
    echo
    echo '--- $DATA_DIR ---'
    ls -la $DATA_DIR 2>&1
    echo
    echo '--- any path matching *jev* under /home/node ---'
    find /home/node -maxdepth 6 -iname '*jev*' 2>&1
    echo
    echo '--- any path matching *jev* under /opt ---'
    find /opt -maxdepth 4 -iname '*jev*' 2>&1
" | indent

# --------------------------------------------------------------------------
section "4. JEV lines in container logs (last 500)"
# --------------------------------------------------------------------------
docker logs --tail=500 "$C" 2>&1 | grep -i 'jev' | head -40 | indent
printf '(end of JEV log lines)\n'

# --------------------------------------------------------------------------
section "5. live run with --print-logs, grep for plugin/mcp/guard/jev"
# --------------------------------------------------------------------------
printf 'running: opencode run --print-logs --log-level DEBUG --model %s ...\n' "$MODEL"
printf 'prompt:  %s\n\n' "$PROBE_PROMPT"
docker exec -w /workspace "$C" sh -c \
    "opencode run --print-logs --log-level DEBUG --model '$MODEL' '$PROBE_PROMPT'" 2>&1 \
    | grep -iE 'jev|guard|mcp|plugin' \
    | head -60 | indent
printf '(end of grep)\n'

# --------------------------------------------------------------------------
section "6. evidence pipeline state"
# --------------------------------------------------------------------------
if [ -d "$REPO/notes" ]; then
    printf 'notes/ exists: '
    ls -1 "$REPO/notes/" 2>&1 | wc -l | tr -d ' '
    printf ' file(s)\n'
    ls -la "$REPO/notes/" 2>&1 | head -15 | indent
else
    printf 'notes/ absent at %s\n' "$REPO/notes"
fi
printf '\npush_notes_v18.sh: '
[ -f "$REPO/push_notes_v18.sh" ] && printf 'present\n' || printf 'absent\n'
printf 'requirements.txt:   '
[ -f "$REPO/requirements.txt" ] && printf 'present\n' || printf 'absent\n'

# --------------------------------------------------------------------------
section "7. Dockerfile: what got installed at build time"
# --------------------------------------------------------------------------
if [ -f "$REPO/docker/Dockerfile" ]; then
    printf '--- Dockerfile lines mentioning jev (case-insensitive) ---\n'
    grep -niI 'jev' "$REPO/docker/Dockerfile" 2>&1 | indent
    printf '\n--- Dockerfile lines mentioning plugin / mcp ---\n'
    grep -niIE 'plugin|mcp' "$REPO/docker/Dockerfile" 2>&1 | indent
fi

printf '\n=== done ===\n'
