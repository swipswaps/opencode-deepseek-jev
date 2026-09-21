#!/usr/bin/env bash
# Deploy Dockge — a Compose-first Docker management UI — on Fedora 43.
# Replaces the interactive-recovery.sh prompt loop with a real dashboard.
# Dockge reads compose.yaml files from disk; no database, no sync issues.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

DOCKGE_DIR="$HOME/dockge"
DOCKGE_STACKS_DIR="$HOME/Documents"
DOCKGE_PORT="5001"
LOG="$DOCKGE_DIR/deploy.log"

main() {
    mkdir -p "$DOCKGE_DIR"
    : > "$LOG"

    echo "=== Dockge deployment ===" | tee -a "$LOG"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"
    echo "Install dir:  $DOCKGE_DIR" | tee -a "$LOG"
    echo "Stacks dir:   $DOCKGE_STACKS_DIR" | tee -a "$LOG"
    echo "Web UI port:  $DOCKGE_PORT" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ----- Gate: docker daemon -----
    if docker info > /dev/null; then
        echo "  PASS: docker daemon reachable" | tee -a "$LOG"
    else
        echo "  FAIL: docker daemon not reachable. Output:" | tee -a "$LOG"
        docker info 2>&1 | tee -a "$LOG"
        return 1
    fi

    # ----- Gate: port availability -----
    if ss -tlnp 2>&1 | grep -q ":$DOCKGE_PORT "; then
        echo "  FAIL: port $DOCKGE_PORT already in use" | tee -a "$LOG"
        ss -tlnp 2>&1 | grep ":$DOCKGE_PORT " | tee -a "$LOG"
        return 1
    fi
    echo "  PASS: port $DOCKGE_PORT available" | tee -a "$LOG"

    # ----- Write compose file -----
    cat > "$DOCKGE_DIR/docker-compose.yml" <<COMPOSE_EOF
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports:
      - "${DOCKGE_PORT}:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DOCKGE_DIR}/data:/app/data
      - ${DOCKGE_STACKS_DIR}:${DOCKGE_STACKS_DIR}
    environment:
      - DOCKGE_STACKS_DIR=${DOCKGE_STACKS_DIR}
COMPOSE_EOF

    echo "  wrote $DOCKGE_DIR/docker-compose.yml" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ----- Bring up -----
    echo "  Running: (cd $DOCKGE_DIR && docker compose up -d)" | tee -a "$LOG"
    (cd "$DOCKGE_DIR" && docker compose up -d 2>&1 | tee -a "$LOG")
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: docker compose up -d returned $rc" | tee -a "$LOG"
        echo "  Full output above. Inspect $LOG" | tee -a "$LOG"
        return 1
    fi

    echo "" | tee -a "$LOG"
    echo "=== Dockge deployed ===" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Open: http://localhost:${DOCKGE_PORT}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "First launch: create an admin account." | tee -a "$LOG"
    echo "Dockge auto-discovers compose files under $DOCKGE_STACKS_DIR" | tee -a "$LOG"
    echo "Each existing stack appears as a tile. Click any tile to:" | tee -a "$LOG"
    echo "  - Start / stop / restart the stack" | tee -a "$LOG"
    echo "  - Edit the compose.yaml in a live editor" | tee -a "$LOG"
    echo "  - View per-service logs" | tee -a "$LOG"
    echo "  - Open an interactive shell in any container" | tee -a "$LOG"
    echo "  - Recreate containers after image updates" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Log: $LOG" | tee -a "$LOG"

    # ----- Copy this script into repo scripts folder -----
    local repo_scripts
    repo_scripts="$(pwd)/scripts"
    if [ -d "$repo_scripts" ]; then
        cp "$0" "$repo_scripts/deploy-dockge.sh" 2>&1 | tee -a "$LOG"
        echo "  copied script to $repo_scripts/deploy-dockge.sh" | tee -a "$LOG"
    fi
}

main "$@"
