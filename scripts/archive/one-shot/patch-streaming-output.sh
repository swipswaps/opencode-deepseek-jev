#!/usr/bin/env bash
#
# patch-streaming-output.sh
#
# v2 of run-audit-via-agent streamed every subprocess line to stdout as
# a telemetry record. Hundreds of lines per second. Terminal unusable.
# Ctrl+C did not stop it because there was no trap.
#
# This patch rewrites stream_logfile() so it:
#   - writes records ONLY to $LOG (not stdout)
#   - prints a single progress line every 10 seconds
#   - exits cleanly when the stopfile appears
#
# And adds a trap on INT/TERM to kill the child, watcher, and streamer.
#
# Constraints: no sed, no 2>/dev/null (only >/dev/null where noted),
# no set -e, no top-level exit, no rm -rf, no subprocess.run,
# no bare kill (TERM/KILL only), printf only, main() wrapper.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

main() {
    local script_dir repo target ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL\n'; return 2; }
    target="$repo/scripts/archive/one-shot/run-audit-via-agent-v2.sh"
    [ -f "$target" ] || { printf 'SKIP: not found\n'; return 0; }

    ts=$(date -u +%Y%m%dT%H%M%SZ)
    cp "$target" "$target.bak.${ts}"
    printf 'backup: %s.bak.%s\n' "$target" "$ts"

    python3 - "$target" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

old_body = '''stream_logfile() {
    local file="$1" label="$2" stopfile="$3"
    while [ ! -f "$stopfile" ]; do
        if [ -f "$file" ]; then
            break
        fi
        sleep 0.1
    done
    tail -F -n +1 "$file" 2>&1 | while IFS= read -r line; do
        [ -f "$stopfile" ] && exit 0
        local lvl="DEBUG"
        case "$line" in
            *level=ERROR*|*error*|*Error*|*failed*|*rejected*) lvl="ERROR" ;;
            *level=WARN*|*warn*)                                   lvl="WARN"  ;;
            *"event connected"*|*"permission requested"*|*"tool"*) lvl="INFO"  ;;
        esac
        local esc; esc=$(printf '%s' "$line" | tr '"' "'")
        local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
        local rec="ts=$ts level=$lvl phase=agent stage=$label status=LINE msg=\\"agent output\\" text=\\"$esc\\""
        printf '%s\\n' "$rec" >> "$LOG"
        printf '%s\\n' "$rec"
    done
}'''

new_body = '''# stream_logfile FILE LABEL STOPFILE
#   Writes each new line as a telemetry record to $LOG only.
#   Prints a one-line progress summary every 10 seconds to stdout.
#   Never echoes the individual records to the terminal.
stream_logfile() {
    local file="$1" label="$2" stopfile="$3"
    local start_epoch lines_seen last_report
    start_epoch=$(date +%s)
    lines_seen=0
    last_report=$start_epoch

    # Wait briefly for the file to appear.
    local wait=0
    while [ ! -f "$file" ] && [ "$wait" -lt 50 ]; do
        sleep 0.1
        wait=$((wait + 1))
    done

    tail -F -n +1 "$file" 2>&1 | while IFS= read -r line; do
        [ -f "$stopfile" ] && exit 0
        lines_seen=$((lines_seen + 1))

        local lvl="DEBUG"
        case "$line" in
            *level=ERROR*|*error*|*Error*|*failed*|*rejected*) lvl="ERROR" ;;
            *level=WARN*|*warn*)                                   lvl="WARN"  ;;
            *"event connected"*|*"permission requested"*)          lvl="INFO"  ;;
        esac
        local esc; esc=$(printf '%s' "$line" | tr '"' "'")
        local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
        printf '%s\\n' "ts=$ts level=$lvl phase=agent stage=$label status=LINE msg=\\"agent output\\" text=\\"$esc\\"" >> "$LOG"

        # Progress line every 10 s, only if there is a tty.
        local now
        now=$(date +%s)
        if [ $((now - last_report)) -ge 10 ]; then
            if [ -t 1 ]; then
                printf '    [%s] %3ss  lines=%d  last=%s\\n' \\
                    "$label" "$((now - start_epoch))" "$lines_seen" \\
                    "$(printf '%s' "$line" | head -c 80)"
            fi
            last_report=$now
        fi
    done
}'''

if old_body not in src:
    print("STREAM_BODY_NOT_FOUND")
    sys.exit(3)

src = src.replace(old_body, new_body, 1)

# Add traps and global child tracking.
trap_block = '''REPO=""; LOG=""; ARTIFACT_DIR=""
CHILD_PID=""
WATCHER_PID=""
STREAMER_PID=""

cleanup() {
    [ -n "$CHILD_PID"   ] && kill -TERM "$CHILD_PID"   >/dev/null 2>&1
    [ -n "$WATCHER_PID" ] && kill -TERM "$WATCHER_PID" >/dev/null 2>&1
    [ -n "$STREAMER_PID" ] && kill -TERM "$STREAMER_PID" >/dev/null 2>&1
    exit 130
}
trap cleanup INT TERM'''

old_globals = 'REPO=""; LOG=""; ARTIFACT_DIR=""'
if old_globals not in src:
    print("GLOBALS_NOT_FOUND")
    sys.exit(4)
src = src.replace(old_globals, trap_block, 1)

# Assign CHILD_PID/WATCHER_PID/STREAMER_PID at each fork site.
src = src.replace(
    'local child=$!',
    'local child=$!\n    CHILD_PID="$child"',
)
src = src.replace(
    'local watcher=$!',
    'local watcher=$!\n    WATCHER_PID="$watcher"',
)
src = src.replace(
    'local streamer=$!',
    'local streamer=$!\n    STREAMER_PID="$streamer"',
)

# Clear them after wait.
src = src.replace(
    'wait "$child"\n    local child_rc=$?',
    'wait "$child"\n    local child_rc=$?\n    CHILD_PID=""',
)
src = src.replace(
    'wait "$watcher" >/dev/null 2>&1',
    'wait "$watcher" >/dev/null 2>&1\n    WATCHER_PID=""',
)
src = src.replace(
    'wait "$streamer" >/dev/null 2>&1',
    'wait "$streamer" >/dev/null 2>&1\n    STREAMER_PID=""',
)

with open(path, "w") as fh:
    fh.write(src)
print("PATCHED")
PY
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'patch failed rc=%d -- restore from %s.bak.%s\n' "$rc" "$target" "$ts"
        return 1
    fi
    bash -n "$target" && printf 'syntax OK\n'
    return 0
}

main "$@"
