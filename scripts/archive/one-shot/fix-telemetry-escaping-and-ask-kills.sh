#!/usr/bin/env bash
#
# fix-telemetry-escaping-and-ask-kills.sh
#
# Two corrections in one run:
#
#   1. Restore test-tools.sh from the pre-telemetry backup, then reapply
#      the telemetry patch with correct line-continuation handling. The
#      prior patch escaped backslashes BEFORE collapsing newlines, so the
#      line-continuation backslash survived as a literal `\ ` in the
#      eval'd command. That turned `--pattern` into ` --pattern` with a
#      leading space, and argparse rejected it.
#
#   2. Replace stop_observers in scripts/ask.sh with a version that
#      checks /proc/<pid> before calling kill, avoiding the
#      "kill: (PID) - No such process" messages when the observer
#      subshell has already exited.
#
#   Bash line continuation:
#     https://www.gnu.org/software/bash/manual/html_node/Commands.html
#   Bash eval:
#     https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Linux procfs:
#     https://man7.org/linux/man-pages/man5/proc.5.html
#   POSIX kill(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/kill.html
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
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

TEST_TOOLS="$REPO_DIR/scripts/test-tools.sh"
ASK="$REPO_DIR/scripts/ask.sh"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

# ============================================================================
# 1. test-tools.sh: restore and reapply with corrected escaping
# ============================================================================
fix_test_tools() {
    section "1. test-tools.sh telemetry reapply"

    # Find the newest pre-telemetry backup.
    local backup
    backup=$(find "$REPO_DIR/scripts" -maxdepth 1 -name 'test-tools.sh.bak.*' 2>&1 \
              | sort | tail -1)

    if [ -z "$backup" ] || [ ! -f "$backup" ]; then
        printf '  FAIL: no test-tools.sh.bak.* found\n'
        return 1
    fi
    printf '  restoring from: %s\n' "$backup"

    if [ "$MODE" = "apply" ]; then
        cp "$backup" "$TEST_TOOLS"
    fi

    # Show the current broken T2 line before patching.
    printf '  pre-patch T2 line (if present):\n'
    grep -n 'Docker Root Dir' "$TEST_TOOLS" | head -1 | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done

    if [ "$MODE" = "apply" ]; then
        python3 - "$TEST_TOOLS" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Scaffolding ------------------------------------------------------------
anchor = "set -o pipefail\n"
scaffold = '''set -o pipefail

if [ -n "${TEST_TOOLS_TRACE:-}" ]; then
    set -x
fi

_tt_resolve_repo() {
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
_TT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TT_REPO_DIR=$(_tt_resolve_repo "$_TT_SCRIPT_DIR")
[ -z "$_TT_REPO_DIR" ] && _TT_REPO_DIR=$(_tt_resolve_repo "$PWD")
TT_LOGS_ROOT="$_TT_REPO_DIR/scripts/archive/logs"
TT_LOGS_DIR="$TT_LOGS_ROOT/test-tools"
TT_STATUS_FILE="$TT_LOGS_ROOT/test-tools.status"

_tt_status() {
    local msg="$1"
    mkdir -p "$TT_LOGS_DIR"
    printf '[%s] %s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$TT_STATUS_FILE"
    if [ -n "${TEST_TOOLS_VERBOSE:-}" ]; then
        printf '        [status] %s\\n' "$msg" >&2
    fi
}

_tt_run() {
    local label="$1"
    local cmd="$2"
    local log="$TT_LOGS_DIR/${label}.log"
    mkdir -p "$TT_LOGS_DIR"
    : > "$log"

    _tt_status "start $label"

    if [ -n "${TEST_TOOLS_VERBOSE:-}" ]; then
        ( eval "$cmd" ) 2>&1 | tee -a "$log"
        local rc=${PIPESTATUS[0]}
    else
        ( eval "$cmd" ) > "$log" 2>&1 &
        local pid=$!
        local start=$SECONDS
        while kill -0 "$pid" 2>&1; do
            printf '        [%s] running %ds\\r' "$label" "$(( SECONDS - start ))" >&2
            sleep 1
        done
        wait "$pid"
        local rc=$?
        printf '                                          \\r' >&2
    fi

    _tt_status "done  $label rc=$rc"
    return "$rc"
}

'''
if anchor not in src:
    print("ERROR: anchor not found", file=sys.stderr)
    sys.exit(3)
src = src.replace(anchor, scaffold, 1)

# Capture replacement --------------------------------------------------
capture_re = re.compile(
    r'    local out\n'
    r'    out=\$\((.*?)\)\n'
    r'    local rc=\$\?',
    re.DOTALL,
)

def make_replace(m):
    cmd = m.group(1)
    # 1. Remove line continuations: backslash followed by newline.
    cmd = re.sub(r"\\\s*\n\s*", " ", cmd)
    # 2. Escape remaining backslashes.
    cmd = cmd.replace("\\", "\\\\")
    # 3. Escape double quotes so they survive inside the outer quotes.
    cmd = cmd.replace('"', '\\"')
    # 4. Collapse remaining whitespace.
    cmd = re.sub(r"\s+", " ", cmd).strip()
    label = "step"
    for candidate in ("doctor", "chatlog", "ask", "scan-constraints"):
        if candidate in cmd:
            label = candidate
            break
    return (
        f'    _tt_run "{label}" "{cmd}"\n'
        f'    local rc=$?\n'
        f'    local out\n'
        f'    out=$(cat "$TT_LOGS_DIR/{label}.log" 2>&1)'
    )

src, n = capture_re.subn(make_replace, src)

with open(path, "w") as f:
    f.write(src)
print(f"  replaced {n} capture site(s)")
PY_EOF

        printf '  post-patch T2 line:\n'
        grep -n 'Docker Root Dir' "$TEST_TOOLS" | head -1 | while IFS= read -r line; do
            printf '    %s\n' "$line"
        done

        printf '  syntax:\n'
        if bash -n "$TEST_TOOLS" 2>&1; then
            printf '    PASS\n'
        else
            printf '    FAIL\n'
            return 1
        fi
    else
        printf '  (dry-run: would restore and reapply)\n'
    fi

    return 0
}

# ============================================================================
# 2. ask.sh: liveness check before kill
# ============================================================================
fix_ask_kills() {
    section "2. ask.sh stop_observers liveness check"

    if [ ! -f "$ASK" ]; then
        printf '  FAIL: %s not found\n' "$ASK"
        return 1
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$ASK" "$ASK.bak.${TS}"
        printf '  backup: %s.bak.%s\n' "$ASK" "$TS"
    fi

    if [ "$MODE" = "apply" ]; then
        python3 - "$ASK" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

pattern = re.compile(r'^stop_observers\(\)\s*\{', re.MULTILINE)
match = pattern.search(src)
if not match:
    print("ERROR: stop_observers not found", file=sys.stderr)
    sys.exit(3)

i = match.end()
depth = 1
in_s = False
in_d = False
in_c = False
while i < len(src) and depth > 0:
    c = src[i]
    if in_c:
        if c == "\n":
            in_c = False
    elif in_s:
        if c == "'":
            in_s = False
    elif in_d:
        if c == '"':
            in_d = False
    else:
        if c == "#":
            in_c = True
        elif c == "'":
            in_s = True
        elif c == '"':
            in_d = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
    i += 1

new_func = '''stop_observers() {
    # pid_alive — true if PID exists on this host.
    # /proc/<pid> exists only for live processes. No signal is sent,
    # so no "No such process" message is ever produced.
    #   Linux procfs:
    #     https://man7.org/linux/man-pages/man5/proc.5.html
    _pid_alive() {
        [ -n "$1" ] && [ -d "/proc/$1" ]
    }

    # Phase 1: TERM live recorded PIDs.
    local pid
    for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
        if _pid_alive "$pid"; then
            kill -TERM "$pid"
        fi
    done

    # Phase 2: TERM orphaned grandchildren by pattern.
    # pkill prints nothing when no match. || true catches return 1.
    pkill -TERM -f "docker events --filter image=$IMAGE" 2>&1 || true
    pkill -TERM -f "journalctl -u docker -f -n 0" 2>&1 || true

    # Phase 3: 2-second bounded wait.
    local deadline=$(( $(date +%s) + 2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local alive=0
        for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
            _pid_alive "$pid" && alive=1
        done
        pgrep -f "docker events --filter image=$IMAGE" > /dev/null && alive=1
        pgrep -f "journalctl -u docker -f -n 0" > /dev/null && alive=1
        [ "$alive" -eq 0 ] && break
        sleep 0.1
    done

    # Phase 4: KILL survivors.
    for pid in "$EVENTS_PID" "$JOURNAL_PID" "$TOP_PID"; do
        if _pid_alive "$pid"; then
            kill -KILL "$pid"
        fi
    done
    pkill -KILL -f "docker events --filter image=$IMAGE" 2>&1 || true
    pkill -KILL -f "journalctl -u docker -f -n 0" 2>&1 || true

    EVENTS_PID=""
    JOURNAL_PID=""
    TOP_PID=""
}'''

src = src[:match.start()] + new_func + src[i:]

with open(path, "w") as f:
    f.write(src)
print("  stop_observers replaced")
PY_EOF

        printf '  syntax:\n'
        if bash -n "$ASK" 2>&1; then
            printf '    PASS\n'
        else
            printf '    FAIL\n'
            return 1
        fi
    else
        printf '  (dry-run: would replace stop_observers)\n'
    fi

    return 0
}

# ============================================================================
# Main
# ============================================================================
main() {
    printf '=== fix-telemetry-escaping-and-ask-kills.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n' "$REPO_DIR"

    fix_test_tools || return 1
    fix_ask_kills || return 1

    section "summary"
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED.\n'
        printf '\n  verify:\n'
        printf '    bash -n %s\n' "$TEST_TOOLS"
        printf '    bash -n %s\n' "$ASK"
        printf '    grep -n "Docker Root Dir" %s | head -1\n' "$TEST_TOOLS"
        printf '    ./scripts/run-with-telemetry.sh --full\n'
    fi
    return 0
}

main "$@"
