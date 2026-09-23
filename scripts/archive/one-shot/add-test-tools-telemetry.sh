#!/usr/bin/env bash
#
# add-test-tools-telemetry.sh — replace out=$(...) captures in
# test-tools.sh with a backgrounded invocation and a per-test log file.
#
# Dry-run by default. --apply writes.
#
# Bash command substitution:
#   https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html
# Bash PIPESTATUS:
#   https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
# POSIX tee(1):
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/tee.html

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
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${TEST_TOOLS}.bak.${TS}"

main() {
    printf '=== add-test-tools-telemetry.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'File: %s\n\n' "$TEST_TOOLS"

    [ -f "$TEST_TOOLS" ] || { printf 'GATE FAIL: test-tools.sh missing\n'; return 1; }
    [ -x "$TEST_TOOLS" ] || { printf 'GATE FAIL: not executable\n'; return 1; }
    command -v python3 > /dev/null || { printf 'GATE FAIL: python3 missing\n'; return 1; }
    [ -e "$BACKUP" ] && { printf 'GATE FAIL: backup exists\n'; return 1; }

    printf '  PASS: gates\n\n'

    if [ "$MODE" = "apply" ]; then
        cp "$TEST_TOOLS" "$BACKUP"
        printf '  backup: %s\n' "$BACKUP"
    fi

    python3 - "$TEST_TOOLS" "$MODE" <<'PY_EOF'
import re, sys

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

anchor = "set -o pipefail\n"
scaffold = '''set -o pipefail

# Telemetry scaffolding ------------------------------------------------------
# See scripts/archive/one-shot/add-test-tools-telemetry.sh for rationale.

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
    local label="$1"; shift
    local log="$TT_LOGS_DIR/${label}.log"
    mkdir -p "$TT_LOGS_DIR"
    : > "$log"

    _tt_status "start $label"

    if [ -n "${TEST_TOOLS_VERBOSE:-}" ]; then
        "$@" 2>&1 | tee -a "$log"
        local rc=${PIPESTATUS[0]}
    else
        "$@" > "$log" 2>&1 &
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

capture_re = re.compile(
    r'    local out\n'
    r'    out=\$\((.*?)\)\n'
    r'    local rc=\$\?',
    re.DOTALL,
)

def replace(m):
    cmd = m.group(1)
    label = "step"
    for candidate in ("doctor", "chatlog", "ask", "scan-constraints"):
        if candidate in cmd:
            label = candidate
            break
    return (
        f'    _tt_run "{label}" bash -c \'{cmd}\'\n'
        f'    local rc=$?\n'
        f'    local out\n'
        f'    out=$(cat "$TT_LOGS_DIR/{label}.log" 2>&1)'
    )

src, n = capture_re.subn(replace, src)

if mode == "apply":
    with open(path, "w") as f:
        f.write(src)
print(f"  replaced {n} capture site(s)")
PY_EOF

    if [ "$MODE" = "apply" ]; then
        printf '\n  syntax check:\n'
        if bash -n "$TEST_TOOLS" 2>&1; then
            printf '    PASS\n'
        else
            printf '    FAIL\n'
        fi
    fi

    printf '\n=== summary ===\n'
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED. backup: %s\n' "$BACKUP"
    fi
    return 0
}

main "$@"
