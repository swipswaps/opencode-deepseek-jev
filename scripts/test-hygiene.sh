#!/usr/bin/env bash
#
# test-hygiene.sh — gate for the blacklist tooling and the prompt linter.
#
#   scan-constraints.py   file-level blacklist scan is clean on scripts/*.sh
#   audit-tool-calls.py   reads the DB, emits valid JSON, matches its schema
#   prompt-lint.py        flags a known-bad prompt, passes a clean one,
#                         fuzzy-matches the latest prompt in the DB
#
# These are the tools that surface persisting mistakes (blacklisted runtime
# commands) and lint user prompts against known preferences. This gate proves
# they run and discriminate; it does NOT fail on runtime blacklist hits (the
# agent's echo/sed usage is reported, not enforced, until the model is clean).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0

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

have() { command -v "$1" >/dev/null 2>&1; }

# --- diagnostic telemetry: ms= on every check line (see lint.sh) ---------
now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -z "$t" ]; then printf '%s000' "$(date +%s)"; return; fi
    local s="${t%%.*}" us="${t#*.}"
    [ -n "$us" ] || us=0
    printf '%d' "$(( s * 1000 + 10#${us:0:3} ))"
}
LAST_MS=$(now_ms)
SLOW_MS=0
SLOW_MSG=""
_stamp() {
    local n
    n=$(now_ms)
    D=$((n - LAST_MS))
    LAST_MS=$n
    if [ "$D" -gt "$SLOW_MS" ]; then SLOW_MS=$D; SLOW_MSG="$1"; fi
}
ok()  { PASS=$((PASS+1)); _stamp "$1"; printf 'ts=%s ms=%s level=INFO  status=PASS msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }
bad() { FAIL=$((FAIL+1)); _stamp "$1"; printf 'ts=%s ms=%s level=ERROR status=FAIL msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if ! have python3; then
        printf 'FAIL: python3 required\n'
        return 1
    fi

    local db="$REPO/data/opencode/opencode.db"
    local work
    work=$(mktemp -d)

    printf '=== test-hygiene.sh ===\n'

    if python3 "$REPO/scripts/scan-constraints.py" "$REPO/scripts" \
            --exclude-dir archive --include '*.sh' --quiet > "$work/sc.txt" 2>&1; then
        ok 'scan-constraints: scripts/*.sh clean (code-level)'
    else
        bad 'scan-constraints: scripts/*.sh clean (code-level)'
        tail -6 "$work/sc.txt"
    fi

    if [ -f "$db" ]; then
        if python3 "$REPO/scripts/audit-tool-calls.py" --json > "$work/atc.json" 2>&1; then
            ok 'audit-tool-calls: runs'
        else
            bad 'audit-tool-calls: runs'
            tail -6 "$work/atc.json"
        fi
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "blacklist_hits" in d and "patterns" in d and "tool_calls_scanned" in d' "$work/atc.json"; then
            ok 'audit-tool-calls: JSON schema'
        else
            bad 'audit-tool-calls: JSON schema'
        fi

        if python3 "$REPO/scripts/prompt-lint.py" --last --json > "$work/pl_last.json" 2>&1; then
            ok 'prompt-lint: --last runs'
        else
            bad 'prompt-lint: --last runs'
            tail -6 "$work/pl_last.json"
        fi
    else
        bad 'database present for audit-tool-calls/prompt-lint'
    fi

    if python3 "$REPO/scripts/audit-tool-calls.py" --self-test > "$work/atc_st.txt" 2>&1; then
        ok 'audit-tool-calls: self-test'
    else
        bad 'audit-tool-calls: self-test'
        cat "$work/atc_st.txt"
    fi

    if python3 "$REPO/scripts/prompt-lint.py" --self-test > "$work/pl_st.txt" 2>&1; then
        ok 'prompt-lint: self-test'
    else
        bad 'prompt-lint: self-test'
        cat "$work/pl_st.txt"
    fi

    if python3 "$REPO/scripts/issue-solutions.py" --self-test > "$work/is_st.txt" 2>&1; then
        ok 'issue-solutions: self-test'
    else
        bad 'issue-solutions: self-test'
        cat "$work/is_st.txt"
    fi

    if have node && [ -f "$REPO/scripts/blacklist-guard-self-test.mjs" ]; then
        if node "$REPO/scripts/blacklist-guard-self-test.mjs" > "$work/bg_st.txt" 2>&1; then
            ok 'blacklist-guard: self-test'
        else
            bad 'blacklist-guard: self-test'
            cat "$work/bg_st.txt"
        fi
    else
        bad 'blacklist-guard-self-test.mjs present + node'
    fi

    if [ -x "$REPO/scripts/logs.sh" ]; then
        if "$REPO/scripts/logs.sh" --source packet > "$work/logs.txt" 2>&1; then
            ok 'logs.sh runs (packet)'
        else
            bad 'logs.sh runs (packet)'
            tail -4 "$work/logs.txt"
        fi
    else
        bad 'logs.sh present + executable'
    fi

    rm -f "$work/sc.txt" "$work/atc.json" "$work/pl_last.json" "$work/atc_st.txt" "$work/pl_st.txt" "$work/is_st.txt" "$work/bg_st.txt" "$work/logs.txt"
    rmdir "$work"

    if [ -n "$SLOW_MSG" ]; then
        printf 'slowest: %s (%sms)\n' "$SLOW_MSG" "$SLOW_MS"
    fi
    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
