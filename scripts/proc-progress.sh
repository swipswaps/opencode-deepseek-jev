#!/usr/bin/env bash
#
# proc-progress.sh — live "is it actually making progress" for a silent job.
#
# Background jobs like `updatedb` print nothing, so they look hung. This prints,
# every few seconds: the process state/elapsed/CPU, its read counters, and the
# directory it currently has open (cwd) -- for a tree walker, cwd IS the progress
# bar. Read-only; it never signals the process.
#
#   sudo bash scripts/proc-progress.sh updatedb        # by name
#   sudo bash scripts/proc-progress.sh 1054952 10      # by pid, 10s interval
#
# Reading /proc/<pid>/io needs root -> run with sudo.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

self_test() {
    local fail=0
    grep -q 'readlink' "${BASH_SOURCE[0]}" || { printf 'FAIL: no cwd readlink\n'; fail=1; }
    grep -q '/io' "${BASH_SOURCE[0]}" || { printf 'FAIL: no /proc io read\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
    [ "$?" -eq 2 ] || { printf 'FAIL: no-arg should exit 2\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" no_such_process_xyz >/dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL: unknown process should exit 1\n'; fail=1; }
    printf 'proc-progress: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

probe() {
    local pid="$1" t0="$2" line io cwd
    if have ps; then
        line=$(ps -o pid=,etime=,time=,pcpu=,stat= -p "$pid" 2>&1)
    else
        line="(ps unavailable; io/cwd still shown)"
    fi
    io=$(awk '/^(rchar|syscr|read_bytes|write_bytes)/{printf "%s %s  ", $1, $2}' "/proc/$pid/io" 2>&1)
    cwd=$(readlink "/proc/$pid/cwd" 2>&1)
    printf '[%4ss] %s\n' "$((SECONDS - t0))" "$line"
    printf '        io:  %s\n' "${io:-?}"
    printf '        cwd: %s\n' "${cwd:-?}"
}

main() {
    local TARGET="${1:-}" INT="${2:-5}" pid
    case "$TARGET" in
        --self-test) self_test; return "$?" ;;
        -h | --help | "") printf 'usage: %s <pid|name> [interval-sec]\n' "$0"; return 2 ;;
    esac
    case "$INT" in ''|*[!0-9]*) INT=5 ;; esac
    if [ -d "/proc/$TARGET" ]; then
        pid="$TARGET"
    else
        pid=$(pgrep -x "$TARGET" | head -1)
    fi
    [ -n "$pid" ] || { printf 'no process matches %s (already finished?)\n' "$TARGET"; return 1; }
    printf 'watching %s (pid %s) every %ss -- Ctrl-C stops THIS view, not the job\n' "$TARGET" "$pid" "$INT"
    local t0=$SECONDS
    while [ -d "/proc/$pid" ]; do
        probe "$pid" "$t0"
        sleep "$INT"
        [ -r "/proc/$pid/stat" ] || { printf '(process %s gone)\n' "$pid"; break; }
        local st
        st=$(awk '{print $3}' "/proc/$pid/stat")
        case "$st" in Z*) printf '(pid %s is a zombie; its parent will reap it)\n' "$pid"; break ;; esac
    done
    return 0
}

main "$@"
