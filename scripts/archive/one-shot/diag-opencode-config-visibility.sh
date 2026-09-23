#!/usr/bin/env bash
#
# diag-opencode-config-visibility.sh — determine why the web UI shows no
# providers even though opencode.json declares one.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Observed:
#   - Web UI at http://127.0.0.1:4096 loads.
#   - Providers page: "No connected providers".
#   - Models page: "No model results".
#
# Hypotheses:
#   H1. Server CWD inside the container is not /workspace.
#   H2. Server reads config from ~/.config/opencode/opencode.json only,
#       never from the project root.
#   H3. /workspace/opencode.json is not visible to the container process.
#   H4. The config block is present but OpenCode rejects it silently.
#
# This script collects the evidence for each. No changes are made.
#
#   OpenCode config discovery:
#     https://opencode.ai/docs/config/
#   OpenCode provider config:
#     https://opencode.ai/docs/providers/
#   Docker exec:
#     https://docs.docker.com/engine/reference/commandline/exec/
#   Linux procfs, cwd:
#     https://man7.org/linux/man-pages/man5/proc.5.html
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   OpenCode config:
#     https://opencode.ai/docs/config/
#   OpenCode providers:
#     https://opencode.ai/docs/providers/
#   OpenCode CLI:
#     https://opencode.ai/docs/cli/
#   Docker inspect:
#     https://docs.docker.com/engine/reference/commandline/inspect/
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
# ============================================================================

set -o pipefail

CID="opencode-deepseek-web"

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== diag-opencode-config-visibility.sh ===\n'
    printf 'container: %s\n' "$CID"

    section "1. container state"
    docker inspect "$CID" \
        --format 'status={{.State.Status}} pid={{.State.Pid}} restarts={{.RestartCount}}'

    section "2. WorkingDir as configured in the image/compose"
    docker inspect "$CID" --format 'Config.WorkingDir={{.Config.WorkingDir}}'

    section "3. server process CWD (from /proc/<pid>/cwd)"
    local pid
    pid=$(docker inspect "$CID" --format '{{.State.Pid}}')
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        sudo readlink "/proc/$pid/cwd" 2>&1 || printf '  cannot read /proc/%s/cwd\n' "$pid"
    else
        printf '  container not running\n'
    fi

    section "4. env the server sees (filtered)"
    docker exec "$CID" sh -c 'env | sort' 2>&1 | \
        grep -E 'OPENCODE|DEEPSEEK|JEV|HOME|PWD|PATH' | while IFS= read -r line; do
            printf '  %s\n' "$line"
        done

    section "5. /workspace listing from inside the container"
    docker exec "$CID" sh -c 'ls -la /workspace | head -30' 2>&1 || \
        printf '  cannot list /workspace\n'

    section "6. /workspace/opencode.json head"
    docker exec "$CID" sh -c 'head -40 /workspace/opencode.json' 2>&1 || \
        printf '  cannot read /workspace/opencode.json\n'

    section "7. ~/.config/opencode/ inside the container"
    docker exec "$CID" sh -c 'ls -la "$HOME/.config/opencode/" 2>&1 | head -20' 2>&1 || true

    section "8. opencode providers list (inside container, cwd=/workspace)"
    docker exec -w /workspace "$CID" sh -c 'opencode providers list 2>&1 | head -40' 2>&1 || \
        printf '  opencode providers list not available or failed\n'

    section "9. opencode models list (inside container, cwd=/workspace)"
    docker exec -w /workspace "$CID" sh -c 'opencode models 2>&1 | head -40' 2>&1 || \
        printf '  opencode models not available or failed\n'

    section "10. does opencode see config at all? (debug)"
    docker exec -w /workspace "$CID" sh -c 'opencode debug config 2>&1 | head -60' 2>&1 || \
        printf '  opencode debug config not available\n'

    section "11. summary of evidence"
    printf 'interpretation:\n'
    printf '  If section 6 shows the DeepSeek block -> file is visible.\n'
    printf '  If section 7 is empty (no files)      -> no user-global config.\n'
    printf '  If section 8 lists deepseek            -> server has provider.\n'
    printf '  If section 8 shows an error            -> capture the error text.\n'
    printf '  If section 10 dumps JSON with deepseek -> config is loaded.\n'
    printf '  If section 10 dumps empty provider {}  -> config was not read.\n'
    return 0
}

main "$@"
