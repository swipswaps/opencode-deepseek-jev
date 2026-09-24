#!/usr/bin/env bash
# run-and-explain.sh — run a command in the container, watch it, and on
# stall emit a snapshot that says WHY. No 2>/dev/null anywhere.
set -o pipefail

C="opencode-deepseek-web"
OC_LOG="/home/node/.local/share/opencode/log/opencode.log"
STALL_S=10

snapshot() {
    printf '%s\n' '--- opencode internal log (last 5) ---'
    docker exec "$C" sh -c "tail -5 $OC_LOG"
    printf '%s\n' '--- processes in container (pid state cmd) ---'
    docker exec "$C" sh -c '
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            c=$(tr "\0" " " < "$p/cmdline")
            [ -z "$c" ] && continue
            s=$(awk "/^State:/{print \$2}" "$p/status")
            printf "  %s %s %s\n" "$(basename "$p")" "$s" "$c"
        done
    '
    printf '%s\n' '--- TCP established count ---'
    docker exec "$C" sh -c 'awk "\$4 == \"01\"" /proc/net/tcp | wc -l'
}

main() {
    local label="$1" limit="$2"
    shift 2
    [ "$1" = "--" ] && shift

    local log="/tmp/${label}-$(date -u +%H%M%S).log"; : > "$log"
    local start; start=$(date +%s)
    local last_size=0 last_change=$start stalled=0

    printf '[%s] cmd: %s\n' "$label" "$*"
    printf '[%s] log: %s\n' "$label" "$log"
    docker exec -w /workspace "$C" "$@" > "$log" 2>&1 &
    local pid=$!

    while [ -d "/proc/$pid" ]; do
        sleep 2
        local now el size idle
        now=$(date +%s); el=$((now-start))
        size=$(wc -c < "$log" | tr -d ' ')
        if [ "$size" -gt "$last_size" ]; then
            last_change=$now; last_size=$size; stalled=0
        fi
        idle=$((now - last_change))
        if [ "$idle" -ge "$STALL_S" ] && [ "$stalled" -eq 0 ]; then
            stalled=1
            printf '\n'
            printf '[%s] STALL: %ss elapsed, %ss without new output\n' "$label" "$el" "$idle"
            printf '[%s] tail of output:\n' "$label"
            tail -3 "$log" | awk '{ printf "  %s\n", $0 }'
            snapshot
            printf '\n'
        fi
        if [ "$el" -ge "$limit" ]; then
            printf '[%s] hard limit %ss reached; killing client\n' "$label" "$limit"
            kill -TERM "$pid"; sleep 1; kill -KILL "$pid"
            break
        fi
    done

    wait "$pid"
    local rc=$?
    printf '[%s] exit=%s elapsed=%ss\n' "$label" "$rc" "$(( $(date +%s) - start ))"
    printf '[%s] tail:\n' "$label"
    tail -5 "$log" | awk '{ printf "  %s\n", $0 }'
}

main "$@"
