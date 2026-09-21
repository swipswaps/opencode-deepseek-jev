#!/usr/bin/env bash
# Recover from v26's unscoped container removal.
# Diagnostic journalctl probe: show raw output, check unit existence,
# broaden time window. Then map surviving named volumes to compose files
# and print how to bring each stack back up.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS="$HOME/Documents"
REPORT="$SCRIPT_DIR/recovery-report.txt"

main() {
    : > "$REPORT"
    echo "=== Recovery analysis ===" | tee -a "$REPORT"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$REPORT"
    echo ""

    # ----- STEP 1: journalctl diagnostics -----
    echo "=== Step 1: journalctl diagnostics ===" | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- systemd units matching docker --" | tee -a "$REPORT"
    systemctl list-units --type=service --all 2>&1 | grep -i -e docker -e containerd | tee -a "$REPORT" || echo "  (none matched)" | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- journalctl entries for docker.service last 24h (raw, last 20 lines) --" | tee -a "$REPORT"
    journalctl -u docker.service --since "24 hours ago" --no-pager -n 20 2>&1 | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- journalctl entries for docker.socket last 24h --" | tee -a "$REPORT"
    journalctl -u docker.socket --since "24 hours ago" --no-pager -n 10 2>&1 | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- journalctl entries containing 'dockerd' last 24h --" | tee -a "$REPORT"
    journalctl --since "24 hours ago" --no-pager 2>&1 | grep -i dockerd | head -20 | tee -a "$REPORT" || echo "  (no dockerd entries)" | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- journalctl entries containing 'container' last 24h --" | tee -a "$REPORT"
    journalctl --since "24 hours ago" --no-pager 2>&1 | grep -i "container" | head -20 | tee -a "$REPORT" || echo "  (no container entries)" | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    echo "-- /var/log/docker.log if it exists --" | tee -a "$REPORT"
    if [ -f /var/log/docker.log ]; then
        tail -40 /var/log/docker.log 2>&1 | tee -a "$REPORT"
    else
        echo "  /var/log/docker.log not present" | tee -a "$REPORT"
    fi

    echo "" | tee -a "$REPORT"
    echo "-- daemon.json log driver --" | tee -a "$REPORT"
    if [ -f /etc/docker/daemon.json ]; then
        cat /etc/docker/daemon.json 2>&1 | tee -a "$REPORT"
    else
        echo "  /etc/docker/daemon.json not present" | tee -a "$REPORT"
    fi

    # ----- STEP 2: named volumes and their compose files -----
    echo "" | tee -a "$REPORT"
    echo "=== Step 2: named volumes -> compose files ===" | tee -a "$REPORT"

    local named_vols
    named_vols="receipts-ocr_postgres_data repo_postgres_data"

    for vol in $named_vols; do
        echo "" | tee -a "$REPORT"
        echo "-- volume: $vol --" | tee -a "$REPORT"
        docker volume inspect "$vol" 2>&1 | tee -a "$REPORT"
        echo "-- compose files referencing $vol --" | tee -a "$REPORT"
        local found=0
        while IFS= read -r compose; do
            if grep -q "$vol" "$compose" 2>&1; then
                echo "  $compose" | tee -a "$REPORT"
                found=1
            fi
        done < <(find "$DOCS" -maxdepth 6 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1)
        if [ "$found" -eq 0 ]; then
            echo "  (no compose file under $DOCS references $vol)" | tee -a "$REPORT"
        fi
    done

    # ----- STEP 3: anonymous dangling volumes with timestamps -----
    echo "" | tee -a "$REPORT"
    echo "=== Step 3: dangling anonymous volumes ===" | tee -a "$REPORT"
    local danglings
    danglings=$(docker volume ls -q -f dangling=true 2>&1)
    if [ -z "$danglings" ]; then
        echo "  (none)" | tee -a "$REPORT"
    else
        for v in $danglings; do
            echo "" | tee -a "$REPORT"
            echo "-- $v --" | tee -a "$REPORT"
            docker volume inspect "$v" 2>&1 | tee -a "$REPORT"
        done
    fi

    # ----- STEP 4: compose projects under $DOCS -----
    echo "" | tee -a "$REPORT"
    echo "=== Step 4: compose projects found under $DOCS ===" | tee -a "$REPORT"
    while IFS= read -r compose; do
        local dir
        dir=$(dirname "$compose")
        echo "" | tee -a "$REPORT"
        echo "-- $dir --" | tee -a "$REPORT"
        echo "   compose file: $compose" | tee -a "$REPORT"
        echo "   to bring up:  (cd $dir && docker compose up -d)" | tee -a "$REPORT"
        echo "   services:" | tee -a "$REPORT"
        grep -E '^  [a-zA-Z0-9_.-]+:' "$compose" 2>&1 | head -20 | tee -a "$REPORT" || echo "     (no services parsed)" | tee -a "$REPORT"
    done < <(find "$DOCS" -maxdepth 6 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1)

    echo "" | tee -a "$REPORT"
    echo "=== Done ===" | tee -a "$REPORT"
    echo "Report: $REPORT"
    echo ""
    echo "To bring a stack back up:"
    echo "  cd <dir-from-step-4> && docker compose up -d"
    echo ""
    echo "To inspect a dangling volume before reusing it:"
    echo "  sudo ls -la \$(docker volume inspect <name> | grep Mountpoint | cut -d\\\" -f4)"
    echo ""
    echo "To attach an existing volume to a fresh container:"
    echo "  docker run -d -v <volume-name>:<container-path> <image>"
}

main "$@"
