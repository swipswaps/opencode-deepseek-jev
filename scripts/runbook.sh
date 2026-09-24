#!/usr/bin/env bash
#
# runbook.sh — host-side, multiple-choice runner for the operational
# runbooks surfaced read-only on the dashboard (http://127.0.0.1:5099/runbooks).
# Reads the same scripts/runbooks.json, so the menu and the page never drift.
#
# Usage:
#   ./scripts/runbook.sh                 # interactive menu
#   ./scripts/runbook.sh --list          # list id|where|title
#   ./scripts/runbook.sh run <id>        # run one runbook (no menu)
#
# Runbooks flagged "manual" (browser steps, long-running servers, or
# secrets edits) are displayed but not executed.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

DATA=""

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

py() {
    python3 - "$DATA" "$@" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
args = sys.argv[2:]
mode = args[0] if args else "list"
if mode == "list":
    for r in data:
        print("%s|%s|%s" % (r["id"], r.get("where", ""), r.get("title", "")))
elif mode == "field":
    rid, key = args[1], args[2]
    for r in data:
        if r["id"] == rid:
            print(r.get(key, ""))
elif mode == "commands":
    rid = args[1]
    for r in data:
        if r["id"] == rid:
            for c in r["commands"]:
                print(c)
elif mode == "manual":
    rid = args[1]
    for r in data:
        if r["id"] == rid:
            print("1" if r.get("manual") else "0")
PY
}

run_one() {
    local id="$1"
    local where title note manual
    where=$(py field "$id" where)
    if [ -z "$where" ]; then
        printf 'unknown runbook: %s\n' "$id"
        return 2
    fi
    title=$(py field "$id" title)
    note=$(py field "$id" note)
    manual=$(py manual "$id")

    printf '\n=== %s ===\n' "$title"
    printf 'id:    %s\n' "$id"
    printf 'where: %s\n' "$where"
    if [ -n "$note" ]; then
        printf 'note:  %s\n' "$note"
    fi
    if [ "$where" = "host" ] && ! have docker; then
        printf 'WARN: docker not found on PATH; this runbook targets the host with docker.\n'
    fi

    printf '\ncommands:\n'
    local cmd
    while IFS= read -r cmd; do
        printf '  %s\n' "$cmd"
    done < <(py commands "$id")

    if [ "$manual" = "1" ]; then
        printf '\nMANUAL runbook: not executed. Copy and run the commands above.\n'
        return 0
    fi

    printf '\nrun these now? [y/N] '
    local ans
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) printf 'aborted\n'; return 0 ;;
    esac

    cd "$REPO" || return 1
    while IFS= read -r cmd; do
        printf '\n$ %s\n' "$cmd"
        bash -c "$cmd"
        local rc=$?
        if [ "$rc" -ne 0 ]; then
            printf 'FAIL: exited %d; stopping.\n' "$rc"
            return "$rc"
        fi
    done < <(py commands "$id")

    printf '\nrunbook "%s" complete\n' "$id"
}

menu() {
    local id where title
    local ids=()
    local labels=()
    while IFS='|' read -r id where title; do
        ids+=("$id")
        labels+=("[$where] $title")
    done < <(py list)

    printf '\n=== runbook.sh ===\n'
    local i
    for i in "${!labels[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${labels[$i]}"
    done
    printf '  q) quit\n'
    printf 'choice: '
    local choice
    read -r choice

    case "$choice" in
        q|Q|"") printf 'aborted\n'; return 0 ;;
        ''|*[!0-9]*) printf 'invalid selection: %s\n' "$choice"; return 2 ;;
    esac

    local idx=$((choice-1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#ids[@]}" ]; then
        printf 'out of range: %s\n' "$choice"
        return 2
    fi
    run_one "${ids[$idx]}"
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    DATA="$REPO/scripts/runbooks.json"
    if [ ! -f "$DATA" ]; then
        printf 'FAIL: missing %s\n' "$DATA"
        return 1
    fi
    if ! have python3; then
        printf 'FAIL: python3 required\n'
        return 1
    fi

    case "${1:-}" in
        --list|-l)
            printf 'id|where|title\n'
            py list
            return 0
            ;;
        run)
            if [ -z "${2:-}" ]; then
                printf 'usage: %s run <id>\n' "$0"
                return 2
            fi
            run_one "$2"
            return $?
            ;;
        "")
            menu
            return $?
            ;;
        *)
            printf 'usage: %s [--list | run <id>]\n' "$0"
            return 2
            ;;
    esac
}

main "$@"
