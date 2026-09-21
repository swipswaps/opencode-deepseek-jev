#!/usr/bin/env bash
# Flatten every compose-file directory under ~/Documents into a single
# directory of symlinks so Dockge's non-recursive discovery finds them.
# Also updates the Dockge compose to point DOCKGE_STACKS_DIR at the flat
# directory and restarts Dockge.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

DOCS="$HOME/Documents"
FLAT_DIR="$HOME/dockge-stacks"
DOCKGE_DIR="$HOME/dockge"
LOG="$FLAT_DIR/flatten.log"

main() {
    mkdir -p "$FLAT_DIR"
    : > "$LOG"

    echo "=== Flatten compose directories for Dockge ===" | tee -a "$LOG"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"
    echo "Scan:      $DOCS" | tee -a "$LOG"
    echo "Flat dir:  $FLAT_DIR" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ----- discovery -----
    echo "--- discovering compose files ---" | tee -a "$LOG"
    local raw_file
    raw_file=$(mktemp)
    find "$DOCS" -maxdepth 8 \( -name "docker-compose.yml" -o -name "compose.yml" \) > "$raw_file" 2>&1

    local found=0
    local linked=0
    local skipped_perm=0

    while IFS= read -r line; do
        # reject error lines (find: ... Permission denied, etc.)
        case "$line" in
            /*) ;;
            *)  skipped_perm=$((skipped_perm + 1)); continue ;;
        esac
        case "$line" in
            *.yml) ;;
            *) continue ;;
        esac

        found=$((found + 1))

        local dir
        dir=$(dirname "$line")

        # already is a direct child of FLAT_DIR? unlikely, but skip
        case "$dir" in
            "$FLAT_DIR"/*) continue ;;
        esac

        # derive a short unique name for the symlink
        local base
        base=$(basename "$dir")
        local hash
        hash=$(printf '%s' "$dir" | sha256sum | head -c 12)
        local link_name="${hash}--${base}"
        local link_path="$FLAT_DIR/$link_name"

        if [ -L "$link_path" ]; then
            local current_target
            current_target=$(readlink "$link_path")
            if [ "$current_target" = "$dir" ]; then
                # already linked and correct
                linked=$((linked + 1))
                continue
            fi
        fi

        ln -s "$dir" "$link_path"
        if [ $? -eq 0 ]; then
            echo "  LINK $link_name -> $dir" | tee -a "$LOG"
            linked=$((linked + 1))
        else
            echo "  FAIL to link $link_name -> $dir" | tee -a "$LOG"
        fi
    done < "$raw_file"

    rm -f "$raw_file"

    echo "" | tee -a "$LOG"
    echo "  compose files found:       $found" | tee -a "$LOG"
    echo "  symlinks created or kept:  $linked" | tee -a "$LOG"
    if [ "$skipped_perm" -gt 0 ]; then
        echo "  non-path lines skipped:    $skipped_perm" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"

    # ----- current symlinks -----
    echo "--- symlinks in $FLAT_DIR ---" | tee -a "$LOG"
    local count=0
    for f in "$FLAT_DIR"/*; do
        if [ -L "$f" ]; then
            count=$((count + 1))
            printf "  %-50s -> %s\n" "$(basename "$f")" "$(readlink "$f")" | tee -a "$LOG"
        fi
    done
    echo "  total: $count" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ----- update Dockge compose -----
    echo "--- updating Dockge compose ---" | tee -a "$LOG"
    if [ ! -f "$DOCKGE_DIR/docker-compose.yml" ]; then
        echo "  FAIL: $DOCKGE_DIR/docker-compose.yml not found" | tee -a "$LOG"
        echo "  Run deploy-dockge.sh first." | tee -a "$LOG"
        return 1
    fi

    cat > "$DOCKGE_DIR/docker-compose.yml" <<COMPOSE_EOF
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports:
      - "5001:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DOCKGE_DIR}/data:/app/data
      - ${FLAT_DIR}:${FLAT_DIR}
      - ${DOCS}:${DOCS}
    environment:
      - DOCKGE_STACKS_DIR=${FLAT_DIR}
COMPOSE_EOF

    echo "  wrote $DOCKGE_DIR/docker-compose.yml" | tee -a "$LOG"
    echo "  DOCKGE_STACKS_DIR=$FLAT_DIR" | tee -a "$LOG"
    echo "  also mounted: $DOCS (so symlinks resolve inside the container)" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ----- restart Dockge -----
    echo "--- restarting Dockge ---" | tee -a "$LOG"
    (cd "$DOCKGE_DIR" && docker compose up -d 2>&1 | tee -a "$LOG")
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: docker compose up -d returned $rc" | tee -a "$LOG"
        return 1
    fi

    echo "" | tee -a "$LOG"
    echo "=== Done ===" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Reload http://localhost:5001" | tee -a "$LOG"
    echo "The sidebar should now list $linked stacks." | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "If a stack shows but fails to start, check:" | tee -a "$LOG"
    echo "  - The compose file uses relative paths that resolve differently" | tee -a "$LOG"
    echo "    from the symlink location. Most stacks use named volumes or" | tee -a "$LOG"
    echo "    absolute paths and will not be affected." | tee -a "$LOG"
    echo "  - Edit the stack in Dockge; it writes back to the real file" | tee -a "$LOG"
    echo "    because the symlink points at the original directory." | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Log: $LOG" | tee -a "$LOG"

    # copy script into repo scripts/
    if [ -d "$(pwd)/scripts" ]; then
        cp "$0" "$(pwd)/scripts/flatten-dockge-stacks.sh"
        echo "Copied to $(pwd)/scripts/flatten-dockge-stacks.sh" | tee -a "$LOG"
    fi
}

main "$@"
