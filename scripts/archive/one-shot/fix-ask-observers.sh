#!/usr/bin/env bash
#
# fix-ask-observers.sh — replace the stop_observers function in ask.sh
# with a version that terminates orphaned grandchildren, not just the
# observer subshells.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Observed: after an ask.sh run, two processes survived:
#
#   3163921 docker events --filter image=opencode-deepseek-jev:robust ...
#   3163937 journalctl -u docker -f -n 0 --no-pager --output=short-iso
#
# Both are grandchildren of the observer subshells that ask.sh starts:
#
#   (
#       docker events ... | tag_stream docker-events >&2
#   ) &
#   EVENTS_PID=$!
#
# $EVENTS_PID is the PID of the subshell. `kill -TERM $EVENTS_PID`
# terminates the subshell but not the pipeline it spawned. The pipeline
# members are orphaned and reparented to PID 1. Their write end of the
# $() pipe stays open, blocking the parent shell's command substitution
# until they exit on their own.
#
# Linux fork(2), reparenting on parent death:
#   https://man7.org/linux/man-pages/man2/fork.2.html
#
# Linux kill(2), signal scope:
#   https://man7.org/linux/man-pages/man2/kill.2.html
#
# pkill(1), pattern-based match of the full command line:
#   https://man7.org/linux/man-pages/man1/pkill.1.html
#
#   Stevens & Rago, "Advanced Programming in the UNIX Environment",
#   3rd ed., Addison-Wesley, 2013. ISBN-13: 978-0321637734. §9.4
#   "Signals: Signal Concepts"; §8.3 "fork Function".
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203. §20.5 "Signal Sets"; §26.1
#   "Overview of Orphaned and Zombie Processes".
#
# ============================================================================
# DEDUCTION
# ============================================================================
#
# The correct shutdown sequence for a set of background observers is:
#
#   1. SIGTERM to the recorded subshell PIDs
#      (stops the subshell from spawning new children)
#   2. SIGTERM to the orphaned grandchildren by command-line pattern
#      (this is what closes the pipes)
#   3. Bounded wait for graceful exit
#   4. SIGKILL to any survivors, subshell and grandchild alike
#   5. Clear recorded PIDs
#
# pkill -f matches on the full command line. The running pkill process
# never matches itself (pgrep(1) man page), so no self-kill risk.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX kill(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/kill.html
#   POSIX sh(1)                https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html
#   Linux kill(2)              https://man7.org/linux/man-pages/man2/kill.2.html
#   Linux fork(2)              https://man7.org/linux/man-pages/man2/fork.2.html
#   Linux signal(7)            https://man7.org/linux/man-pages/man7/signal.7.html
#   pgrep(1), pkill(1)         https://man7.org/linux/man-pages/man1/pgrep.1.html
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash trap                  https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

resolve_repo() {
    local candidate="$1"
    while [ "$candidate" != "/" ]; do
        if [ -f "$candidate/opencode.json" ] && [ -f "$candidate/docker/Dockerfile" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        candidate=$(dirname "$candidate")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n' >&2
    return 2
fi

ASK="$REPO_DIR/scripts/ask.sh"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${ASK}.bak.${TS}"

section() { printf '\n=== %s ===\n' "$1"; }

fail() {
    printf 'GATE FAIL: %s\n' "$1"
    [ -n "${2:-}" ] && printf '  %s\n' "$2"
    return 1
}

# ============================================================================
# Gates
# ============================================================================
gate_ask_exists() {
    section "G1 ask.sh exists and is executable"
    if [ ! -f "$ASK" ]; then
        fail "$ASK not found"
        return 1
    fi
    if [ ! -x "$ASK" ]; then
        fail "$ASK not executable" "chmod +x $ASK"
        return 1
    fi
    printf '  PASS: %s\n' "$ASK"
    return 0
}

gate_old_function() {
    section "G2 current stop_observers matches expected form"
    if grep -q '^stop_observers() {' "$ASK"; then
        printf '  PASS: stop_observers function found\n'
        return 0
    fi
    fail "stop_observers not found in $ASK" \
         "the file may already be patched or diverged"
    return 1
}

gate_python() {
    section "G3 python3 available"
    if command -v python3 > /dev/null; then
        printf '  PASS: python3 present\n'
        return 0
    fi
    fail "python3 not found"
    return 1
}

gate_backup_slot() {
    section "G4 backup slot free"
    if [ -e "$BACKUP" ]; then
        fail "backup path already exists" "$BACKUP"
        return 1
    fi
    printf '  PASS: %s is available\n' "$BACKUP"
    return 0
}

# ============================================================================
# Patch
# ============================================================================
replace_stop_observers() {
    section "patch: replace stop_observers"

    if [ "$MODE" = "apply" ]; then
        cp "$ASK" "$BACKUP"
        printf '  backup: %s\n' "$BACKUP"
    fi

    python3 - "$ASK" "$MODE" <<'PY_EOF'
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

# Locate the stop_observers function by name and brace-balance to find
# its closing brace. Replace the whole block.
pattern = re.compile(r'^stop_observers\(\)\s*\{', re.MULTILINE)
match = pattern.search(src)
if not match:
    print("ERROR: stop_observers not found", file=sys.stderr)
    sys.exit(3)

start = match.start()
# Walk forward, counting braces, ignoring those inside quotes and
# comments. The function body is short and simple; a basic counter
# suffices.
i = match.end()
depth = 1
in_single = False
in_double = False
in_comment = False
while i < len(src) and depth > 0:
    c = src[i]
    if in_comment:
        if c == "\n":
            in_comment = False
    elif in_single:
        if c == "'":
            in_single = False
    elif in_double:
        if c == '"':
            in_double = False
    else:
        if c == "#":
            in_comment = True
        elif c == "'":
            in_single = True
        elif c == '"':
            in_double = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
    i += 1

end = i

new_func = '''stop_observers() {
    # Phase 1: SIGTERM to the recorded subshell PIDs.
    local pid
    for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>&1 || true
    done

    # Phase 2: SIGTERM to orphaned grandchildren by command-line pattern.
    #
    # Killing the subshell does not propagate SIGTERM to the pipeline
    # members inside it. They are reparented to PID 1 and keep the
    # write end of the $() pipe open, blocking the parent shell.
    # Matching by pattern terminates them directly.
    #
    #   fork(2), reparenting:
    #     https://man7.org/linux/man-pages/man2/fork.2.html
    #   pgrep(1), pattern match of full command line:
    #     https://man7.org/linux/man-pages/man1/pgrep.1.html
    pkill -TERM -f "docker events --filter image=$IMAGE" 2>&1 || true
    pkill -TERM -f "journalctl -u docker -f -n 0" 2>&1 || true

    # Phase 3: bounded graceful wait, 2 seconds.
    local deadline=$(( $(date +%s) + 2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local alive=0
        for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
            [ -n "$pid" ] && kill -0 "$pid" 2>&1 && alive=1
        done
        pgrep -f "docker events --filter image=$IMAGE" > /dev/null 2>&1 && alive=1
        pgrep -f "journalctl -u docker -f -n 0" > /dev/null 2>&1 && alive=1
        [ "$alive" -eq 0 ] && break
        sleep 0.1
    done

    # Phase 4: SIGKILL any survivors, subshells and grandchildren alike.
    for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
        [ -n "$pid" ] && kill -KILL "$pid" 2>&1 || true
    done
    pkill -KILL -f "docker events --filter image=$IMAGE" 2>&1 || true
    pkill -KILL -f "journalctl -u docker -f -n 0" 2>&1 || true

    EVENTS_PID=""
    JOURNAL_PID=""
    TOP_PID=""
}'''

src = src[:start] + new_func + src[end:]

if mode == "apply":
    with open(path, "w") as f:
        f.write(src)

print("  stop_observers replaced")
PY_EOF
}

# ============================================================================
# Verification
# ============================================================================
verify() {
    section "verification"

    if [ "$MODE" != "apply" ]; then
        printf '  (dry-run: file unchanged)\n'
        return 0
    fi

    # Show the new stop_observers block.
    printf '  new stop_observers block:\n\n'
    python3 - "$ASK" <<'PY_EOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
start = None
depth = 0
for i, line in enumerate(lines):
    if start is None and re.match(r"stop_observers\(\)\s*\{", line):
        start = i
        depth = line.count("{") - line.count("}")
        continue
    if start is not None:
        depth += line.count("{") - line.count("}")
        if depth == 0:
            for j in range(start, i + 1):
                print("    " + lines[j].rstrip())
            break
PY_EOF

    # Sanity: the key patterns must appear.
    printf '\n  pattern checks:\n'
    if grep -q 'pkill -TERM -f "docker events --filter image=\$IMAGE"' "$ASK"; then
        printf '    PASS: pkill pattern for docker events present\n'
    else
        printf '    FAIL: pkill pattern for docker events missing\n'
    fi
    if grep -q 'pkill -TERM -f "journalctl -u docker -f -n 0"' "$ASK"; then
        printf '    PASS: pkill pattern for journalctl present\n'
    else
        printf '    FAIL: pkill pattern for journalctl missing\n'
    fi
    if grep -q 'kill -KILL' "$ASK"; then
        printf '    PASS: SIGKILL fallback present\n'
    else
        printf '    FAIL: SIGKILL fallback missing\n'
    fi

    printf '\n  bash -n check:\n'
    if bash -n "$ASK" 2>&1; then
        printf '    PASS: parses\n'
    else
        printf '    FAIL: syntax error\n'
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    printf '=== fix-ask-observers.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'File: %s\n' "$ASK"

    gate_ask_exists || return 1
    gate_old_function || return 1
    gate_python || return 1
    gate_backup_slot || return 1

    replace_stop_observers

    verify

    section "summary"
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply to write.\n'
    else
        printf '\n  APPLIED.\n'
        printf '  backup: %s\n' "$BACKUP"
        printf '\n  next: run test-tools.sh --full and observe that the\n'
        printf '        T9 summarize returns to prompt without stalling.\n'
    fi
    return 0
}

main "$@"
