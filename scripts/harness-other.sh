#!/usr/bin/env bash
#
# harness-other.sh — run THIS workspace's harness against another repo.
#
# The harness resolves its repo from its own location, so it normally gates
# this workspace. This wrapper keeps the tooling here (harness.sh,
# gate-bound.py, ledger.py, lib/heartbeat.sh) and points it at <repo>:
#   - gates run from <repo>/scripts/<gate>.sh
#   - verdict, timings and ledger go INSIDE <repo> by default (its own
#     preflight/next-action can read them)
#   - --shadow-state writes them to a temp dir instead (read-only target)
#
# usage: ./scripts/harness-other.sh <repo> [--shadow-state] [-- <harness args>]
#   ./scripts/harness-other.sh ~/src/app --fast
#   ./scripts/harness-other.sh /srv/readonly --shadow-state --fast
#
# Verification: prints target, rev, which gates exist, and where state lands;
# then the harness's own output. Exit code is the harness's.
#
# Constraints: no stream editor, no stderr-to-null, no set -e, printf only.

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

usage() {
    printf 'usage: %s <repo> [--shadow-state] [-- <harness args>]\n' "$0"
}

main() {
    local ws tgt="" shadow=0
    ws=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)") || {
        printf 'harness-other: cannot find the workspace root (opencode.json + docker/Dockerfile)\n'
        return 2
    }
    while [ $# -gt 0 ]; do
        case "$1" in
            --shadow-state) shadow=1; shift ;;
            --) shift; break ;;
            -h|--help) usage; return 0 ;;
            -*) break ;;
            *) tgt="$1"; shift ;;
        esac
    done
    [ -n "$tgt" ] || { usage; return 2; }
    [ -d "$tgt" ] || { printf 'harness-other: not a directory: %s\n' "$tgt"; return 2; }
    tgt=$(cd "$tgt" && pwd)

    local state gates="" g rev="(no git)"
    if [ "$shadow" -eq 1 ]; then
        state=$(mktemp -d "${TMPDIR:-/tmp}/harness-state.XXXXXX")
    else
        state="$tgt"
    fi
    for g in lint test-hygiene test-patterns test-dashboard; do
        if [ -f "$tgt/scripts/$g.sh" ]; then gates="$gates $g"; else gates="$gates -$g"; fi
    done
    if command -v git > /dev/null && [ -d "$tgt/.git" ]; then
        rev=$(git -C "$tgt" rev-parse --short HEAD 2>&1)
    fi

    printf 'target: %s\n' "$tgt"
    printf 'rev:    %s\n' "$rev"
    printf 'gates:  %s   (+ = present, - = SKIP)\n' "$gates"
    printf 'state:  %s%s\n' "$state" "$([ "$shadow" -eq 1 ] && printf ' (shadow; target untouched)')"
    printf '%s\n' '---'

    HARNESS_REPO="$tgt" HARNESS_STATE="$state" \
        "$ws/scripts/harness.sh" "$@"
    local rc=$?
    printf '%s\n' '---'
    printf 'verdict: %s/data/observability/last-gate.json\n' "$state"
    return "$rc"
}

main "$@"
