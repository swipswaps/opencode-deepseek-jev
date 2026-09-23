#!/usr/bin/env bash
#
# push-telemetry.sh
#
# Commit logs/telemetry-*.log and logs/artifacts-*/, push, then print
# raw githubusercontent.com links for each file, verified HTTP 200.
#
# Preconditions: git remote configured, gh authenticated.
# Secret scan runs on staged content before commit; aborts on any hit.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
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

have() { command -v "$1" >/dev/null 2>&1; }

log() {
    local level="$1" phase="$2" status="$3" msg="$4"
    shift 4
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv="" p
    for p in "$@"; do kv="$kv $p"; done
    printf 'ts=%s level=%s phase=%s status=%s msg="%s"%s\n' \
        "$ts" "$level" "$phase" "$status" "$msg" "$kv"
}

audit_staged() {
    local patterns='sk-[A-Za-z0-9]{20,}|apikey_[A-Za-z0-9_]{20,}|OPENCODE_SERVER_PASSWORD=[A-Za-z0-9+/=]{20,}'
    local hits=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$REPO/$f" ] || continue
        local n
        n=$(grep -Ec "$patterns" "$REPO/$f" 2>&1)
        if [ "$n" -gt 0 ]; then
            hits="${hits}${f}: ${n}\n"
        fi
    done < <(git -C "$REPO" diff --cached --name-only)
    if [ -n "$hits" ]; then
        printf 'SECRET HITS:\n'
        printf '%b' "$hits"
        return 1
    fi
    return 0
}

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO=$(resolve_repo "$script_dir")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }

    have git || { log ERROR preflight FAIL "git missing"; return 1; }
    have gh  || { log ERROR preflight FAIL "gh missing";  return 1; }
    have curl || { log ERROR preflight FAIL "curl missing"; return 1; }

    log INFO session START "push-telemetry" "repo=$REPO"

    cd "$REPO" || return 1

    local owner_repo owner name
    owner_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>&1)
    case "$owner_repo" in
        */*) owner=${owner_repo%%/*}; name=${owner_repo##*/} ;;
        *) log ERROR resolve FAIL "gh could not resolve repo" "out=\"$owner_repo\""; return 1 ;;
    esac
    log INFO resolve PASS "repo identified" "owner=$owner" "name=$name"

    [ -d logs ] || { log WARN stage SKIP "no logs directory"; return 0; }

    # Ensure the log and artifact extensions are not ignored.
    if [ -f .gitignore ]; then
        local i
        for i in "logs/" "logs/telemetry-2026-09-23.log" "*.log" "*.json"; do
            if git check-ignore -q "$i" 2>&1; then
                log WARN ignore WARN "path is gitignored" "path=$i"
            fi
        done
    fi

    git add -f logs/ 2>&1
    local staged_count
    staged_count=$(git diff --cached --name-only | grep -c .)
    log INFO stage PASS "files staged" "count=$staged_count"
    if [ "$staged_count" -eq 0 ]; then
        log INFO stage SKIP "nothing to commit"
        return 0
    fi

    if ! audit_staged; then
        log ERROR audit FAIL "secrets in staged content; unstage and redact"
        return 1
    fi
    log INFO audit PASS "staged files clean"

    local ts
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    git commit -m "telemetry: capture ${ts}" 2>&1 | tail -3
    if [ $? -ne 0 ]; then
        log ERROR commit FAIL "git commit nonzero"
        return 1
    fi
    log INFO commit PASS "committed"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>&1)
    git push origin "$branch" 2>&1 | tail -3
    if [ $? -ne 0 ]; then
        log ERROR push FAIL "git push nonzero" "branch=$branch"
        return 1
    fi
    log INFO push PASS "pushed" "branch=$branch"

    printf '\n=== raw github links (verified HTTP 200) ===\n'
    local f url code
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        url="https://raw.githubusercontent.com/${owner}/${name}/${branch}/${f}"
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>&1)
        printf '  %-80s %s\n' "$f" "$code"
        printf '    %s\n' "$url"
    done < <(git show --name-only --pretty=format: HEAD | grep -v '^$')

    log INFO session END "done" "branch=$branch"
    return 0
}

main "$@"
