#!/usr/bin/env bash
#
# stop-stale-asciinema.sh — enumerate and terminate stale asciinema
# recording sessions, sparing the current one.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Evidence:
#
#   htop shows 33 rows with Command "asciinema rec ...", spread across
#   five recording files. Four of the five correspond to sessions that
#   have ended. The fifth is the current session.
#
#   `killall asciinema` returns immediately and does not terminate them.
#
# Reason:
#
#   killall(1) matches on the kernel comm field, which on Linux is a
#   15-character identifier taken from the executable basename. On
#   Fedora 43, /usr/bin/asciinema is a Python shebang wrapper; the
#   recording process runs as comm=python3, not comm=asciinema.
#
#   The Command column in htop shows argv[0], which is "asciinema"
#   because that is the name the wrapper re-execs itself under. It is
#   not what killall compares.
#
#   pgrep(1) §"Matching rules":
#     https://man7.org/linux/man-pages/man1/pgrep.1.html
#
#   Linux proc(5), /proc/[pid]/comm:
#     https://man7.org/linux/man-pages/man5/proc.5.html
#
# Correct primitive:
#
#   pkill -f 'asciinema rec' matches against the full command line
#   (argv array), which contains the wrapper path and the recording
#   file name.
#
# ============================================================================
# DESIGN
# ============================================================================
#
#   1. Identify the current session by walking up from this shell to
#      find the recording file in the process ancestry. If found,
#      exclude that PID.
#   2. Enumerate all remaining asciinema processes by pattern.
#   3. SIGTERM each. Wait up to 2 seconds.
#   4. SIGKILL any survivors.
#   5. Report.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX kill(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/kill.html
#   Linux kill(2)              https://man7.org/linux/man-pages/man2/kill.2.html
#   Linux signal(7)            https://man7.org/linux/man-pages/man7/signal.7.html
#   Linux proc(5)              https://man7.org/linux/man-pages/man5/proc.5.html
#   Linux clone(2)             https://man7.org/linux/man-pages/man2/clone.2.html
#   pgrep(1), pkill(1)         https://man7.org/linux/man-pages/man1/pgrep.1.html
#   ps(1)                      https://man7.org/linux/man-pages/man1/ps.1.html
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203. §20 "Signals: Fundamental Concepts";
#   §26 "Threads: Introduction".
#
#   Stevens & Rago, "Advanced Programming in the UNIX Environment",
#   3rd ed., Addison-Wesley, 2013. ISBN-13: 978-0321637734. §9.4, §11.4.
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

PATTERN='asciinema rec'

# ----------------------------------------------------------------------------
# Identify the current session's asciinema PID by walking the process
# ancestry of this shell. Returns the PID, or empty.
# ----------------------------------------------------------------------------
current_recorder_pid() {
    local pid=$$
    local comm args
    # Walk up to 20 levels.
    local i=0
    while [ "$i" -lt 20 ] && [ "$pid" -gt 1 ]; do
        args=$(ps -o args= -p "$pid" 2>&1)
        case "$args" in
            *"$PATTERN"*)
                printf '%s' "$pid"
                return 0
                ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>&1 | tr -d ' ')
        case "$pid" in
            ""|0) break ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# ----------------------------------------------------------------------------
# List all asciinema PIDs matching the pattern.
# ----------------------------------------------------------------------------
list_asciinema_pids() {
    pgrep -f "$PATTERN" 2>&1
}

main() {
    printf '=== stop-stale-asciinema.sh ===\n'
    printf 'Mode:    %s\n' "$MODE"
    printf 'Pattern: %s\n\n' "$PATTERN"

    # --- current session ---
    local current=""
    current=$(current_recorder_pid) || true
    if [ -n "$current" ]; then
        printf 'current session recorder PID: %s\n' "$current"
        printf '  command: %s\n' "$(ps -o args= -p "$current" 2>&1)"
    else
        printf 'current session recorder PID: not found (shell is not running under asciinema)\n'
    fi

    # --- enumerate all asciinema PIDs ---
    local all_pids
    all_pids=$(list_asciinema_pids)
    if [ -z "$all_pids" ]; then
        printf '\nno asciinema processes found\n'
        return 0
    fi

    local count
    count=$(printf '%s\n' "$all_pids" | wc -l)
    printf '\ntotal asciinema-matching PIDs: %d\n' "$count"

    # --- filter to stale (exclude current) ---
    local stale_pids=""
    local p
    for p in $all_pids; do
        [ "$p" = "$current" ] && continue
        stale_pids="$stale_pids $p"
    done
    stale_pids="${stale_pids# }"

    if [ -z "$stale_pids" ]; then
        printf 'no stale asciinema processes to stop\n'
        return 0
    fi

    local stale_count
    stale_count=$(printf '%s\n' $stale_pids | wc -l)
    printf 'stale PIDs to stop: %d\n\n' "$stale_count"

    printf 'listing:\n'
    for p in $stale_pids; do
        printf '  %-8s %s\n' "$p" "$(ps -o args= -p "$p" 2>&1)"
    done

    if [ "$MODE" = "dry-run" ]; then
        printf '\nDRY-RUN. Rerun with --apply to send signals.\n'
        return 0
    fi

    # --- signal SIGTERM ---
    printf '\nphase 1: SIGTERM\n'
    for p in $stale_pids; do
        if kill -TERM "$p" 2>&1; then
            printf '  TERM %s\n' "$p"
        else
            printf '  TERM %s failed (already gone?)\n' "$p"
        fi
    done

    # --- bounded wait ---
    printf '\nphase 2: wait up to 2s\n'
    local deadline=$(( $(date +%s) + 2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local alive=0
        for p in $stale_pids; do
            kill -0 "$p" 2>&1 && alive=1
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.1
    done

    # --- SIGKILL survivors ---
    printf '\nphase 3: SIGKILL survivors\n'
    local survivors=0
    for p in $stale_pids; do
        if kill -0 "$p" 2>&1; then
            if kill -KILL "$p" 2>&1; then
                printf '  KILL %s\n' "$p"
                survivors=$((survivors + 1))
            fi
        fi
    done

    printf '\nsummary:\n'
    printf '  stale signaled with SIGTERM: %d\n' "$stale_count"
    printf '  killed with SIGKILL:         %d\n' "$survivors"

    printf '\nremaining asciinema-matching PIDs:\n'
    local remaining
    remaining=$(list_asciinema_pids)
    if [ -z "$remaining" ]; then
        printf '  none\n'
    else
        for p in $remaining; do
            printf '  %-8s %s\n' "$p" "$(ps -o args= -p "$p" 2>&1)"
        done
    fi

    return 0
}

main "$@"
