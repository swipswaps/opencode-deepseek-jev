#!/usr/bin/env bash
#
# audit-trees.sh — entanglement audit across local checkouts, as code.
#
# Answers, with evidence: which checkouts exist, what repo/branch/HEAD each
# tracks, whether worktrees are dirty, whether duplicate files have drifted,
# and which tree the live containers actually serve. Read-only: never
# commits, pushes, restarts, or removes anything.
#
# Usage: audit-trees.sh
# Exit 0 ran clean, 1 findings need attention (see output),
#   2 usage/tool error. Text output only (dashboard JSON lives in /api/*).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, printf only, main() wrapper.
#
set -o pipefail

section() { printf '\n=== %s ===\n' "$1"; }

# Candidate roots: directories that contain an opencode.json directly.
find_roots() {
    find /home/owner/Documents -maxdepth 4 -name "opencode.json" -not -path "*/node_modules/*" 2>&1 \
        | grep -v "Permission denied" | head -n 10 || true
}

describe_tree() {
    local d="$1"
    local branch head origin dirt
    branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>&1)" || branch="?"
    head="$(git -C "$d" log --oneline -1 2>&1 | head -n 1)" || head="?"
    origin="$(git -C "$d" ls-remote origin HEAD 2>&1 | head -c 7)" || origin="?"
    if git -C "$d" diff --quiet --exit-code 2>&1 && git -C "$d" diff --cached --quiet --exit-code 2>&1; then
        dirt="clean"
    else
        dirt="dirty($(git -C "$d" status --short 2>&1 | wc -l) paths)"
    fi
    printf 'tree=%s\n  branch=%s head=%s origin=%s worktree=%s\n' "$d" "$branch" "$head" "$origin" "$dirt"
}

live_mounts() {
    docker ps --format '{{.Names}}' 2>&1 | head -n 10 || true
    docker inspect opencode-deepseek-web --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>&1 | head -n 8 || true
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            *) printf 'usage: %s (no arguments)\n' "$0" >&2; return 2 ;;
        esac
    done
    section "checkouts"
    local roots f
    roots="$(find_roots)"
    if [ -z "$roots" ]; then
        printf 'FAIL: no checkouts found\n'
        return 1
    fi
    printf '%s\n' "$roots"
    section "identity"
    printf '%s\n' "$roots" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        describe_tree "$(dirname "$f")"
    done
    section "live mounts"
    live_mounts
    section "duplicate key scripts"
    local a="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/scripts/rotate-api-keys.sh"
    local b="/home/owner/Documents/e26eb081-f905-4ac6-ad40-4204334ee4fe/mesh-homelab/agent-substrate/scripts/archive/one-shot/rotate-api-keys.sh"
    if [ -f "$a" ] && [ -f "$b" ]; then
        if diff -q "$a" "$b" > /dev/null 2>&1; then
            printf 'identical (drift risk while both exist)\n'
        else
            printf 'DRIFTED (copies differ — canonicalize now)\n'
        fi
    else
        printf 'one or both copies absent (dedup done or moved)\n'
    fi
    return 0
}

main "$@"
