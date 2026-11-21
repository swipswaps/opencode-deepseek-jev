#!/usr/bin/env bash
#
# heartbeat.sh — shared live-gate primitives. SOURCE ONLY, not executed.
#
# The harness and gate-watch both need "is the child still running, and what
# was its last log line?" without ps/pgrep (absent in the container) and
# without mistaking a zombie for progress.
#
# Usage (after `. scripts/lib/heartbeat.sh`):
#   hb_alive PID                 # 0 while running, 1 when gone or a zombie
#   hb_alive_pidfile PID
#   hb_last LOG                  # last line, empty when unreadable
#   hb_watch PID LOG BOUND LABEL STYLE HEARTBEAT
#       Emit heartbeats until PID exits or BOUND elapses (0 = no bound).
#       STYLE: harness -> "ts=... status=RUN gate=..."; plain -> "heartbeat ...";
#              none -> quiet. Returns 0 on child exit, 3 on bound.
#
# Constraints match the repo: no stream editor, no stderr-to-null, printf only.

hb_alive() {
    local pid="$1" state
    [ -d "/proc/$pid" ] || return 1
    state=$(awk '{ sub(/^[^)]*\) /, ""); printf "%s", $1 }' "/proc/$pid/stat" 2>&1)
    [ "${state:-Z}" != "Z" ]
}

hb_last() {
    [ -r "$1" ] || { printf ''; return; }
    tail -n 1 "$1" 2>&1
}

hb_size() {
    stat -c %s "$1" 2>&1
}

hb_watch() {
    local pid="$1" log="$2" bound="$3" label="$4" style="$5" hb="$6"
    local start elapsed last bytes
    start=$(date +%s)
    while hb_alive "$pid"; do
        sleep 1
        elapsed=$(( $(date +%s) - start ))
        [ "$bound" -gt 0 ] && [ "$elapsed" -ge "$bound" ] && return 3
        if [ "$hb" -gt 0 ] && [ $((elapsed % hb)) -eq 0 ]; then
            last=$(hb_last "$log")
            bytes=$(hb_size "$log")
            case "$style" in
                harness) printf 'ts=%s level=INFO  status=RUN gate=%s elapsed=%ss bytes=%s last=%s\n' \
                    "$(date -u +%H:%M:%S)" "$label" "$elapsed" "$bytes" "$last" ;;
                plain) printf 'heartbeat elapsed=%ss last=%s\n' "$elapsed" "$last" ;;
                *) : ;;
            esac
        fi
    done
    return 0
}
