#!/usr/bin/env bash
#
# gh-pages.sh — scripted GitHub Pages flow (no Settings clicking).
#
# Subcommands (all print telemetry; mutating steps state intent first):
#   status               pages source + latest "Deploy panel" run state
#   enable               PUT pages build_type=workflow (idempotent)
#   dispatch             run the "Deploy panel" workflow (the allow-once)
#   watch                follow the latest run to completion (exit 1 on fail)
#   url                  print the expected Pages URL
#
# Usage: ./scripts/gh-pages.sh status|enable|dispatch|watch|url
# Requires: gh authenticated (gh auth login), repo slug from gh or --repo.
# Exit 0 ok, 1 run failed/degraded, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only,
#   printf only, main() wrapper.
#
set -o pipefail

REPO_SLUG=""

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }

have() { command -v "$1" >/dev/null 2>&1; }

slug() {
    if [ -n "$REPO_SLUG" ]; then
        printf '%s' "$REPO_SLUG"
        return 0
    fi
    gh repo view --json nameWithOwner -q .nameWithOwner 2>&1 || return 2
    return 0
}

cmd_status() {
    local slug pages_url run
    slug="$(slug)" || return 2
    printf 'repo: %s\n' "${slug}"
    pages_url="$(gh api "repos/${slug}/pages" -q .html_url 2>&1)" || pages_url="(pages not configured)"
    printf 'pages: %s\n' "${pages_url}"
    run="$(gh run list --workflow "Deploy panel" --limit 1 --json status,conclusion,headBranch,createdAt -q '.[0] | "\(.status)/\(.conclusion) \(.headBranch) \(.createdAt)"' 2>&1)" || run="(no runs)"
    printf 'latest deploy run: %s\n' "${run}"
    return 0
}

cmd_enable() {
    local slug
    slug="$(slug)" || return 2
    printf 'enabling Pages (build_type=workflow) on %s\n' "${slug}"
    # PUT updates an existing site; POST creates the first one (404 on PUT
    # means "pages not configured", which is exactly the fresh-repo case).
    if gh api -X PUT "repos/${slug}/pages" -f build_type=workflow --jq .html_url 2>&1; then
        return 0
    fi
    printf 'PUT missed; creating site with POST\n'
    gh api -X POST "repos/${slug}/pages" -f build_type=workflow --jq .html_url 2>&1 || return 2
    return 0
}

cmd_dispatch() {
    gh workflow run "Deploy panel" 2>&1 || return 2
    printf 'dispatched (this click is the allow-once)\n'
    return 0
}

cmd_watch() {
    if gh run watch --exit-status 2>&1; then
        printf 'deploy: SUCCESS\n'
        return 0
    fi
    printf 'deploy: FAILED (see run log above)\n' >&2
    return 1
}

cmd_url() {
    local slug
    slug="$(slug)" || return 2
    printf 'https://%s.github.io/%s/\n' "${slug%%/*}" "${slug##*/}"
    return 0
}

main() {
    if [ "$#" -eq 0 ]; then
        fail 'usage: gh-pages.sh {status|enable|dispatch|watch|url} [--repo OWNER/REPO]'
        return 2
    fi
    local cmd="$1"
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) shift; REPO_SLUG="${1:-}"; shift ;;
            --help|-h) printf 'usage: %s {status|enable|dispatch|watch|url}\n' "$0"; return 0 ;;
            *) fail "usage: $0 {status|enable|dispatch|watch|url}"; return 2 ;;
        esac
    done
    if ! have gh; then
        fail 'gh not installed (or not on PATH)'
        return 2
    fi
    case "${cmd}" in
        status) cmd_status ;;
        enable) cmd_enable ;;
        dispatch) cmd_dispatch ;;
        watch) cmd_watch ;;
        url) cmd_url ;;
        *) fail "usage: $0 {status|enable|dispatch|watch|url}" ;;
    esac
}

main "$@"
