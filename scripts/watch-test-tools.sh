#!/usr/bin/env bash
#
# watch-test-tools.sh — tail test-tools status file and per-test logs.
#
# Usage:
#   ./scripts/watch-test-tools.sh               # follow status only
#   ./scripts/watch-test-tools.sh T8-ask        # follow status + one log
#
# Follows scripts/archive/logs/test-tools.status, created by the
# telemetry patch to test-tools.sh. In a second terminal, run this while
# test-tools.sh is executing.
#
# POSIX tail(1):
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/tail.html
# ISO 8601:
#   https://www.iso.org/iso-8601-date-and-time-format.html

set -o pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi

LOGS_ROOT="$REPO_DIR/scripts/archive/logs"
STATUS="$LOGS_ROOT/test-tools.status"
LOGS_DIR="$LOGS_ROOT/test-tools"

main() {
    if [ ! -f "$STATUS" ]; then
        printf 'status file not present: %s\n' "$STATUS"
        printf 'run test-tools.sh once with the telemetry patch to create it\n'
        return 1
    fi

    printf 'watching %s\n' "$STATUS"
    printf '(Ctrl-C to stop)\n\n'

    local specific="${1:-}"
    if [ -n "$specific" ]; then
        local log="$LOGS_DIR/${specific}.log"
        if [ ! -f "$log" ]; then
            printf 'log not present yet: %s\n' "$log"
            printf 'continuing with status only; the log appears when the test runs\n\n'
        fi
        tail -F "$STATUS" "$log"
    else
        tail -F "$STATUS"
    fi
}

main "$@"
