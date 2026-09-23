#!/usr/bin/env bash
#
# test-tools.sh — exercise every tool in scripts/ and report pass/fail.
#
# ============================================================================
# AUDIT — what this test exercises
# ============================================================================
#
# Each tool in scripts/ is invoked once, with the smallest input that
# exercises its core path. The goal is behavioral verification: does the
# tool do what its README claims, in the environment the repo describes.
#
# Tools covered:
#
#   doctor.sh               environment health check
#   scan-constraints.py     constraint scanner
#   chatlog.sh              list / find / search subcommands
#   ask.sh                  model round-trip (--full only)
#   chatlog.sh summarize    grounded model call (--full only)
#
# Two modes:
#
#   ./test-tools.sh         fast — no API calls, sub-second
#   ./test-tools.sh --full  adds ask.sh and chatlog summarize
#
# Exit status:
#
#   0   no test reported FAIL
#   1   at least one test reported FAIL
#
# ============================================================================
# CONSTRAINTS HONORED
# ============================================================================
#
#   no sed
#   no rm -rf
#   no set -e
#   no exit 1 as a command (main() returns 1 instead)
#   no 2>/dev/null
#   no subprocess.run
#   no kill without signal
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX test(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX printf(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Docker run                 https://docs.docker.com/engine/reference/commandline/run/
#   OpenCode CLI               https://opencode.ai/docs/cli/
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.1 "Testing".
#
# ============================================================================

set -o pipefail

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
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$TT_STATUS_FILE"
    if [ -n "${TEST_TOOLS_VERBOSE:-}" ]; then
        printf '        [status] %s\n' "$msg" >&2
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
            printf '        [%s] running %ds\r' "$label" "$(( SECONDS - start ))" >&2
            sleep 1
        done
        wait "$pid"
        local rc=$?
        printf '                                          \r' >&2
    fi

    _tt_status "done  $label rc=$rc"
    return "$rc"
}


FULL=0
case "${1:-}" in
    --full) FULL=1 ;;
    "") ;;
    *) printf 'usage: %s [--full]\n' "$0"; return 2 ;;
esac

# ----------------------------------------------------------------------------
# Repo root by marker
# ----------------------------------------------------------------------------
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

SCRIPTS="$REPO_DIR/scripts"
NOTES_DIR="$(dirname "$REPO_DIR")/notes"

PASS=0
FAIL=0
WARN=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL  %s\n' "$1"
    [ -n "${2:-}" ] && printf '        %s\n' "$2"
    FAIL=$((FAIL + 1))
}
warn() {
    printf '  WARN  %s\n' "$1"
    [ -n "${2:-}" ] && printf '        %s\n' "$2"
    WARN=$((WARN + 1))
}
info() { printf '  INFO  %s\n' "$1"; }

section() { printf '\n=== %s ===\n' "$1"; }

# ----------------------------------------------------------------------------
# T0 — every tool exists and is executable
# ----------------------------------------------------------------------------
test_presence() {
    section "T0 tool presence"
    local name
    for name in doctor.sh scan-constraints.py chatlog.sh ask.sh \
                deploy-dockge.sh flatten-dockge-stacks.sh test-repo.sh; do
        local path="$SCRIPTS/$name"
        if [ ! -e "$path" ]; then
            fail "$name missing"
            continue
        fi
        if [ -x "$path" ]; then
            pass "$name present and executable"
        else
            warn "$name present but not executable" \
                 "chmod +x $path"
        fi
    done
}

# ----------------------------------------------------------------------------
# T1 — scan-constraints.py default mode
# ----------------------------------------------------------------------------
test_scanner_default() {
    section "T1 scanner default (operating set, archive excluded)"
    local scanner="$SCRIPTS/scan-constraints.py"
    if [ ! -x "$scanner" ]; then
        fail "scanner not executable"
        return
    fi

    _tt_run "step" "python3 \"$scanner\" \"$SCRIPTS\" --exclude-dir archive --quiet 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/step.log" 2>&1)

    if [ "$rc" -eq 0 ]; then
        pass "operating set clean"
        printf '%s\n' "$out" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    else
        fail "operating set reports code hits" "$out"
    fi
}

# ----------------------------------------------------------------------------
# T2 — scan-constraints.py --pattern override
# ----------------------------------------------------------------------------
test_scanner_pattern() {
    section "T2 scanner --pattern override"
    local scanner="$SCRIPTS/scan-constraints.py"
    if [ ! -x "$scanner" ]; then
        fail "scanner not executable"
        return
    fi

    _tt_run "step" "python3 \"$scanner\" \"$SCRIPTS\" --pattern 'Docker Root Dir' --show-all --quiet 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/step.log" 2>&1)

    if [ "$rc" -eq 0 ]; then
        pass "--pattern override accepted, no hits"
    else
        fail "--pattern override reported hits" "$out"
    fi
}

# ----------------------------------------------------------------------------
# T3 — doctor.sh fast mode
# ----------------------------------------------------------------------------
test_doctor() {
    section "T3 doctor.sh fast"
    local doctor="$SCRIPTS/doctor.sh"
    if [ ! -x "$doctor" ]; then
        fail "doctor.sh not executable"
        return
    fi

    _tt_run "doctor" "cd \"$REPO_DIR\" && \"$doctor\" 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/doctor.log" 2>&1)

    local passes
    passes=$(printf '%s\n' "$out" | grep -c '^  PASS')
    local fails
    fails=$(printf '%s\n' "$out" | grep -c '^  FAIL')
    info "doctor reports: $passes pass, $fails fail"

    if [ "$rc" -eq 0 ]; then
        pass "doctor.sh exited 0"
    else
        fail "doctor.sh exited $rc" "$(printf '%s\n' "$out" | tail -5)"
    fi
}

# ----------------------------------------------------------------------------
# T4 — chatlog.sh list
# ----------------------------------------------------------------------------
test_chatlog_list() {
    section "T4 chatlog.sh list"
    local chatlog="$SCRIPTS/chatlog.sh"
    if [ ! -x "$chatlog" ]; then
        fail "chatlog.sh not executable"
        return
    fi

    if [ ! -d "$NOTES_DIR" ]; then
        warn "notes directory absent" "$NOTES_DIR"
        return
    fi

    _tt_run "chatlog" "cd \"$REPO_DIR\" && \"$chatlog\" list 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/chatlog.log" 2>&1)
    if [ "$rc" -ne 0 ]; then
        fail "chatlog.sh list exited $rc" "$out"
        return
    fi

    local count
    count=$(printf '%s\n' "$out" | grep -c '.')
    pass "chatlog.sh list returned $count entries"
}

# ----------------------------------------------------------------------------
# T5 — chatlog.sh find
# ----------------------------------------------------------------------------
test_chatlog_find() {
    section "T5 chatlog.sh find"
    local chatlog="$SCRIPTS/chatlog.sh"
    if [ ! -x "$chatlog" ]; then
        fail "chatlog.sh not executable"
        return
    fi
    if [ ! -d "$NOTES_DIR" ]; then
        warn "notes directory absent"
        return
    fi

    _tt_run "chatlog" "cd \"$REPO_DIR\" && \"$chatlog\" find '.txt' 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/chatlog.log" 2>&1)
    if [ "$rc" -ne 0 ]; then
        fail "chatlog.sh find exited $rc" "$out"
        return
    fi
    pass "chatlog.sh find returned successfully"
}

# ----------------------------------------------------------------------------
# T6 — chatlog.sh search via scanner
# ----------------------------------------------------------------------------
test_chatlog_search() {
    section "T6 chatlog.sh search (scanner-backed)"
    local chatlog="$SCRIPTS/chatlog.sh"
    if [ ! -x "$chatlog" ]; then
        fail "chatlog.sh not executable"
        return
    fi
    if [ ! -d "$NOTES_DIR" ]; then
        warn "notes directory absent"
        return
    fi

    _tt_run "chatlog" "cd \"$REPO_DIR\" && \"$chatlog\" search \"no fail\" 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/chatlog.log" 2>&1)

    # A clean search that finds nothing is a valid outcome. What matters
    # is that the command did not crash and produced a summary line.
    if [ "$rc" -eq 1 ]; then
        # scanner returns 1 when code hits are present; that is a normal
        # signal that the pattern matched code somewhere.
        pass "chatlog.sh search ran and reported code hits"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        pass "chatlog.sh search ran cleanly"
        return
    fi
    fail "chatlog.sh search exited $rc" "$out"
}

# ----------------------------------------------------------------------------
# T7 — chatlog.sh usage without args
# ----------------------------------------------------------------------------
test_chatlog_usage() {
    section "T7 chatlog.sh usage"
    local chatlog="$SCRIPTS/chatlog.sh"
    if [ ! -x "$chatlog" ]; then
        fail "chatlog.sh not executable"
        return
    fi

    _tt_run "chatlog" "cd \"$REPO_DIR\" && \"$chatlog\" 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/chatlog.log" 2>&1)
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Commands:'; then
        pass "chatlog.sh printed usage and returned $rc"
    else
        fail "chatlog.sh did not print usage" "$out"
    fi
}

# ----------------------------------------------------------------------------
# T8 — ask.sh (--full only)
# ----------------------------------------------------------------------------
test_ask() {
    section "T8 ask.sh model round-trip"
    if [ "$FULL" -ne 1 ]; then
        warn "skipped (run with --full to enable)"
        return
    fi

    local ask="$SCRIPTS/ask.sh"
    if [ ! -x "$ask" ]; then
        fail "ask.sh not executable"
        return
    fi

    _tt_run "ask" "cd \"$REPO_DIR\" && \"$ask\" --quiet --timeout 180 \"Reply with the single word OK\" 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/ask.log" 2>&1)

    if printf '%s' "$out" | grep -q 'OK'; then
        pass "model responded with OK (exit $rc)"
    else
        fail "model did not respond with OK" "$out"
    fi
}

# ----------------------------------------------------------------------------
# T9 — chatlog.sh summarize (--full only)
# ----------------------------------------------------------------------------
test_chatlog_summarize() {
    section "T9 chatlog.sh summarize"
    if [ "$FULL" -ne 1 ]; then
        warn "skipped (run with --full to enable)"
        return
    fi
    if [ ! -d "$NOTES_DIR" ]; then
        warn "notes directory absent"
        return
    fi

    # Find the smallest log file to minimize cost and latency.
    local smallest
    smallest=$(find "$NOTES_DIR" -maxdepth 2 -type f \
        \( -name '*.txt' -o -name '*.md' \) -printf '%s %p\n' 2>&1 \
        | sort -n | head -1 | awk '{print $2}')

    if [ -z "$smallest" ]; then
        warn "no log files to summarize"
        return
    fi

    info "summarizing: $(basename "$smallest")"
    _tt_run "chatlog" "cd \"$REPO_DIR\" && \"$SCRIPTS/chatlog.sh\" summarize \"$smallest\" 2>&1"
    local rc=$?
    local out
    out=$(cat "$TT_LOGS_DIR/chatlog.log" 2>&1)

    if [ "$rc" -eq 0 ]; then
        local lines
        lines=$(printf '%s\n' "$out" | grep -c '.')
        pass "summarize returned $lines lines"
    else
        fail "summarize exited $rc" "$(printf '%s\n' "$out" | tail -5)"
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    printf '=== test-tools.sh ===\n'
    printf 'Repo:  %s\n' "$REPO_DIR"
    printf 'Notes: %s\n' "$NOTES_DIR"
    printf 'Mode:  %s\n' "$([ "$FULL" -eq 1 ] && printf full || printf fast)"

    test_presence
    test_scanner_default
    test_scanner_pattern
    test_doctor
    test_chatlog_list
    test_chatlog_find
    test_chatlog_search
    test_chatlog_usage
    test_ask
    test_chatlog_summarize

    section "summary"
    printf '  pass: %d\n' "$PASS"
    printf '  warn: %d\n' "$WARN"
    printf '  fail: %d\n' "$FAIL"

    if [ "$FAIL" -gt 0 ]; then
        printf '\nresult: FAIL\n'
        return 1
    fi
    printf '\nresult: OK\n'
    return 0
}

main "$@"
