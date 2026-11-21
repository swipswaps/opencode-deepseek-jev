#!/usr/bin/env bash
#
# sandbox-detect.sh — host or container? One answer, one exit code.
#
# WHY: the harness gate is meaningful on the host and *expected* to fail in
# the opencode-web container (host-path guard link, host .env.local, repo DB
# path). Reporting those as FAIL every session trains the operator to ignore
# red. Checks that need the host can now skip with a reason instead.
#
#   ./scripts/sandbox-detect.sh            # "sandbox: pid1=opencode web"
#   ./scripts/sandbox-detect.sh --quiet    # exit 0 sandbox, 1 host
#   ./scripts/sandbox-detect.sh --json
#   ./scripts/sandbox-detect.sh --self-test
#
# Signals (any one): pid 1 is `opencode web`; the repo `.env.local` is a masked
# non-regular file; pid 1's cgroup names docker/containerd/kubepods.
#
# Constraints: no stream editor, no stderr-to-null, no set -e, printf only.

set -o pipefail

REPO=""

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

cgroup_container() {
    case "$1" in
        *docker*|*containerd*|*kubepods*|*libpod*) return 0 ;;
    esac
    return 1
}

env_masked() {
    [ -e "$1" ] && [ ! -f "$1" ]
}

detect() {
    local p1 cg envf
    p1=$(tr '\0' ' ' < /proc/1/cmdline 2>&1)
    case "$p1" in
        *"opencode web"*) printf 'pid1=opencode web'; return 0 ;;
    esac
    envf="${REPO:-.}/.env.local"
    if env_masked "$envf"; then printf 'env.local is a masked device'; return 0; fi
    cg=$(cat /proc/1/cgroup 2>&1)
    if cgroup_container "$cg"; then printf 'pid1 cgroup is a container'; return 0; fi
    return 1
}

self_test() {
    local fails=0 work
    work=$(mktemp -d "${TMPDIR:-/tmp}/sandbox.XXXXXX" 2>&1) || {
        printf 'FAIL mktemp\n'; return 1; }
    printf 'x\n' > "$work/.env.local"
    if env_masked "$work/.env.local"; then
        printf 'FAIL regular file read as masked\n'; fails=$((fails + 1))
    else
        printf 'PASS regular file is not masked\n'
    fi
    mkfifo "$work/.env.fifo"
    if env_masked "$work/.env.fifo"; then
        printf 'PASS non-regular file is masked\n'
    else
        printf 'FAIL non-regular file not detected\n'; fails=$((fails + 1))
    fi
    if cgroup_container '0::/docker/abc'; then
        printf 'PASS docker cgroup matched\n'
    else
        printf 'FAIL docker cgroup missed\n'; fails=$((fails + 1))
    fi
    if cgroup_container '0::/user.slice'; then
        printf 'FAIL host cgroup matched\n'; fails=$((fails + 1))
    else
        printf 'PASS host cgroup is host\n'
    fi
    find "$work" -depth -delete 2>&1
    if [ "$fails" -eq 0 ]; then printf 'self-test: PASS\n'; return 0; fi
    printf 'self-test: FAIL (%s)\n' "$fails"
    return 1
}

main() {
    local quiet=0 json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet) quiet=1; shift ;;
            --json) json=1; shift ;;
            --self-test) self_test; return $? ;;
            -h|--help) printf 'usage: %s [--quiet] [--json] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--quiet] [--json] [--self-test]\n' "$0"; return 2 ;;
        esac
    done
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    local reason rc
    if reason=$(detect); then rc=0; else reason="host"; rc=1; fi
    if [ "$quiet" -eq 1 ]; then return "$rc"; fi
    if [ "$json" -eq 1 ]; then
        printf '{"mode":"%s","reason":"%s"}\n' \
            "$([ "$rc" -eq 0 ] && printf sandbox || printf host)" "$reason"
        return 0
    fi
    printf '%s: %s\n' "$([ "$rc" -eq 0 ] && printf sandbox || printf host)" "$reason"
}

main "$@"
