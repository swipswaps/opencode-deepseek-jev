#!/usr/bin/env bash
#
# repair-telemetry-patch.sh — restore test-tools.sh from the backup made
# by add-test-tools-telemetry.sh, then reapply telemetry with a
# corrected argument-passing strategy.
#
# ============================================================================
# AUDIT — why the previous telemetry patch broke the tests
# ============================================================================
#
# The generated call sites looked like:
#
#     _tt_run "step" bash -c 'cd "$REPO_DIR" && "$doctor" 2>&1'
#
# Single quotes suppress expansion. $REPO_DIR and $doctor reached the
# inner bash as literal text. The inner bash had no such variables, so
# they expanded to empty. `cd ""` prints `cd: null directory`.
#
# The correct pattern: expand the variables in the outer shell (where
# they live), pass the resulting command as a double-quoted argument,
# and let the helper `eval` it inside a subshell that inherits the
# caller's variables.
#
#   Bash manual, Quoting and Command Substitution:
#     https://www.gnu.org/software/bash/manual/html_node/Quoting.html
#     https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html
#   Bash `eval`:
#     https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Bash quoting:
#     https://www.gnu.org/software/bash/manual/html_node/Quoting.html
#   Bash `eval`:
#     https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash command substitution:
#     https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html
#   POSIX kill(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/kill.html
#   Python re:
#     https://docs.python.org/3/library/re.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
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

TEST_TOOLS="$REPO_DIR/scripts/test-tools.sh"

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== repair-telemetry-patch.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'File: %s\n\n' "$TEST_TOOLS"

    if [ ! -f "$TEST_TOOLS" ]; then
        printf 'GATE FAIL: %s not found\n' "$TEST_TOOLS"
        return 1
    fi

    # ---- locate the newest backup made by the broken patch --------------
    local backup
    backup=$(find "$REPO_DIR/scripts" -maxdepth 1 -name 'test-tools.sh.bak.*' \
             2>&1 | sort | tail -1)

    if [ -z "$backup" ] || [ ! -f "$backup" ]; then
        printf 'GATE FAIL: no test-tools.sh.bak.* found\n'
        return 1
    fi
    printf '  restoring from: %s\n' "$backup"

    if [ "$MODE" = "apply" ]; then
        cp "$backup" "$TEST_TOOLS"
        printf '  restored\n\n'
    else
        printf '  would restore\n\n'
    fi

    # ---- apply corrected telemetry patch -------------------------------
    section "apply corrected telemetry patch"

    if [ "$MODE" = "apply" ]; then
        python3 - "$TEST_TOOLS" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# 1. Insert telemetry scaffolding after `set -o pipefail`.
anchor = "set -o pipefail\n"
scaffold = '''set -o pipefail

# Telemetry scaffolding ------------------------------------------------------
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

# _tt_run LABEL CMD — run CMD via eval in a subshell. CMD was expanded
# by the caller; it is a concrete shell command string with no variable
# references that need resolving at this level.
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

# 2. Replace `out=$(...)` captures with `_tt_run "label" "cmd"`.
#    The cmd is escaped for safe placement inside a double-quoted
#    argument: backslashes and double quotes get a preceding backslash,
#    newlines collapse to spaces.
capture_re = re.compile(
    r'    local out\n'
    r'    out=\$\((.*?)\)\n'
    r'    local rc=\$\?',
    re.DOTALL,
)

def make_replace(m):
    cmd = m.group(1)
    label = "step"
    for candidate in ("doctor", "chatlog", "ask", "scan-constraints"):
        if candidate in cmd:
            label = candidate
            break
    escaped = cmd.replace("\\", "\\\\").replace('"', '\\"')
    escaped = re.sub(r"\s+", " ", escaped).strip()
    return (
        f'    _tt_run "{label}" "{escaped}"\n'
        f'    local rc=$?\n'
        f'    local out\n'
        f'    out=$(cat "$TT_LOGS_DIR/{label}.log" 2>&1)'
    )

src, n = capture_re.subn(make_replace, src)

with open(path, "w") as f:
    f.write(src)
print(f"  replaced {n} capture site(s)")
PY_EOF

        printf '\n  syntax check:\n'
        if bash -n "$TEST_TOOLS" 2>&1; then
            printf '    PASS\n'
        else
            printf '    FAIL\n'
        fi
    else
        printf '  would restore and reapply\n'
    fi

    printf '\n=== summary ===\n'
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED. verify:\n'
        printf '    grep -c _tt_run %s\n' "$TEST_TOOLS"
        printf '    bash -n %s\n' "$TEST_TOOLS"
        printf '    ./scripts/run-with-telemetry.sh\n'
    fi
    return 0
}

main "$@"
