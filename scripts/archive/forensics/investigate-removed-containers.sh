#!/usr/bin/env bash
# Investigate Docker containers removed by stage-opencode-repo-v26.sh.
# Reads staging.log, cross-references journalctl, checks dangling volumes
# and remaining images, and prints recovery suggestions.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/staging.log"
OUT_FILE="$SCRIPT_DIR/removed-containers.txt"

main() {
    echo "=== Investigating removed containers ==="

    if [ ! -f "$LOG_FILE" ]; then
        echo "FAIL: $LOG_FILE not found"
        return 1
    fi

    : > "$OUT_FILE"
    local in_list=0
    while IFS= read -r line; do
        case "$line" in
            *"removing containers"*)
                in_list=1
                continue
                ;;
            *"containers removed"*|*"End orphan cleanup"*)
                in_list=0
                continue
                ;;
        esac
        if [ "$in_list" -eq 1 ]; then
            case "$line" in
                *[!0-9a-f]*) ;;
                *)
                    if [ "${#line}" = "12" ] || [ "${#line}" = "64" ]; then
                        printf '%s\n' "$line" >> "$OUT_FILE"
                    fi
                    ;;
            esac
        fi
    done < "$LOG_FILE"

    local count
    count=$(wc -l < "$OUT_FILE")
    echo "Removed IDs found in staging.log: $count"
    echo "List written to: $OUT_FILE"
    echo ""

    echo "=== journalctl search (last 6 hours) ==="
    if command -v journalctl > /dev/null; then
        while IFS= read -r cid; do
            echo "  --- container $cid ---"
            journalctl -u docker --since "6 hours ago" --no-pager 2>&1 | \
                grep "$cid" 2>&1 || echo "    no journalctl events"
        done < "$OUT_FILE"
    else
        echo "  journalctl not available"
    fi
    echo ""

    echo "=== leftover /var/lib/docker/containers/ metadata ==="
    if [ -d /var/lib/docker/containers ]; then
        local found_any=0
        while IFS= read -r cid; do
            if [ -d "/var/lib/docker/containers/$cid" ]; then
                echo "  $cid: metadata still present"
                ls -la "/var/lib/docker/containers/$cid" 2>&1
                found_any=1
            fi
        done < "$OUT_FILE"
        if [ "$found_any" -eq 0 ]; then
            echo "  no leftover metadata (expected after docker rm)"
        fi
    else
        echo "  /var/lib/docker/containers not readable (need root):"
        echo "    sudo ls /var/lib/docker/containers/"
    fi
    echo ""

    echo "=== orphaned (dangling) volumes ==="
    docker volume ls -f dangling=true 2>&1
    echo ""

    echo "=== all named volumes ==="
    docker volume ls 2>&1
    echo ""

    echo "=== containers currently present ==="
    docker ps -a 2>&1
    echo ""

    echo "=== images present ==="
    docker image ls -a 2>&1
    echo ""

    echo "=== shell history references ==="
    local hist_file="$HOME/.bash_history"
    if [ -f "$hist_file" ]; then
        while IFS= read -r cid; do
            echo "  --- container $cid ---"
            grep "$cid" "$hist_file" 2>&1 || echo "    no history reference"
        done < "$OUT_FILE"
    else
        echo "  no $hist_file"
    fi
    echo ""

    echo "=== compose file search (containers managed by docker compose) ==="
    echo "  Searching for docker-compose.yml under $HOME/Documents ..."
    find "$HOME/Documents" -maxdepth 5 -name "docker-compose.yml" -o -name "compose.yml" 2>&1 | head -50
    echo ""

    echo "=== Recovery suggestions ==="
    echo "For each removed container, determine how it was originally created:"
    echo ""
    echo "  1. If managed by docker compose:"
    echo "       cd <project-dir> && docker compose up -d"
    echo ""
    echo "  2. If started by docker run with saved args:"
    echo "       re-run the original command (check shell history)"
    echo ""
    echo "  3. Named volumes survive docker rm (no -v was used in v26)."
    echo "       To attach an existing volume to a new container:"
    echo "       docker run -v <volume-name>:<mount-point> <image>"
    echo ""
    echo "  4. Bind mounts point to host paths that were never touched."
    echo "       Confirm: ls -la <original-host-path>"
    echo ""
    echo "  5. Anonymous volumes appear as dangling."
    echo "       Inspect: docker volume inspect <volume>"
    echo "       Look for the 'CreatedAt' field to match timing."
    echo ""
    echo "  6. The image the container used is still present:"
    echo "       docker image ls"
    echo "     Recreate the container from its original image if the"
    echo "     original run command is recoverable."
}

main "$@"
