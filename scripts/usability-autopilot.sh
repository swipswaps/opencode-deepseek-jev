#!/usr/bin/env bash
#
# usability-autopilot.sh - the one command that gates every assert and then
# proceeds to the real guided retest. It is a thin, auditable front-end over
# scripts/usability-proceed.sh so a fresh terminal needs one invocation.
#
# Citations (verified 2026-11-06; full log docs/USABILITY-TESTING.md §8):
#   ISO 9241-11:2018  https://www.iso.org/standard/63500.html
#   ISO 9241-210:2019 https://www.iso.org/standard/77520.html
#   W3C WCAG 2.2      https://www.w3.org/TR/WCAG22/
#   W3C SC 2.5.8      https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html
#   W3C SC 1.4.10     https://www.w3.org/WAI/WCAG22/Understanding/reflow.html
#   Playwright a11y   https://playwright.dev/docs/accessibility-testing
#   Deque axe-core    https://github.com/dequelabs/axe-core
#   Core Web Vitals   https://web.dev/articles/vitals
#   web-vitals impl   https://github.com/GoogleChrome/web-vitals
#   NN/g heuristics   https://www.nngroup.com/articles/ten-usability-heuristics/
#   Nielsen 1993      ISBN 978-0-12-518406-9
#   SUS (Lewis 2018)  https://doi.org/10.1080/10447318.2018.1455307
#   Automation bias   https://doi.org/10.1518/001872097778543886
#   Reduced motion    https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion
#   Git config env    https://git-scm.com/docs/git-config#Documentation/git-config.txt-GITCONFIGGLOBAL
#   git commit flags  https://git-scm.com/docs/git-commit#Documentation/git-commit.txt---no-verify
#   GNU rm prompt     https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html
#   Project rule      RULES.md #93 (completion is a gate, not a claim)
#
#   ./scripts/usability-autopilot.sh --base https://10.100.0.24:5099
#   ./scripts/usability-autopilot.sh --base http://127.0.0.1:5099
#   ./scripts/usability-autopilot.sh --dry-run
#   ./scripts/usability-autopilot.sh --self-test
#
# Assert order (fail-closed; each is a falsifiable predicate):
#   A1 repo remote + required files + the three stall fixes are present
#   A2 docs/USABILITY-TESTING.md still carries the verified citation log
#   A3 usability-proceed.sh is executable
#   A4 gates: lint + test-hygiene + test-patterns, streamed and bounded
#   A5 build + restart + served==HEAD + tasks + redirect + asset hash
#   A6 RULES #93 closeout; the only allowed human block is `retest`
#   A7 push only a clean tree; a missing credential is a warning, not a pass
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
# No subprocess.run. No kill without signal. printf only. main() wrapper.
#
set -o pipefail

SCRIPT="usability-autopilot.sh"
BASE="${USABILITY_BASE:-https://10.100.0.24:5099}"
HYGIENE_TIMEOUT="${HYGIENE_TIMEOUT:-1800}"
REPO_ARG=""
DRY=0
FAILED=0

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then printf '%s' "$c"; return 0; fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad() { FAILED=1; printf 'FAIL  %s\n' "$*"; }

find_target() {
    local d
    if [ -n "$REPO_ARG" ]; then
        [ -d "$REPO_ARG/.git" ] && git -C "$REPO_ARG" remote get-url origin 2>&1 | grep -q 'opencode-deepseek-jev' && { printf '%s' "$REPO_ARG"; return 0; }
        return 1
    fi
    for d in /home/owner/Documents/*/repo "$PWD"; do
        [ -d "$d/.git" ] || continue
        [ -f "$d/opencode.json" ] || continue
        if git -C "$d" remote get-url origin 2>&1 | grep -q 'opencode-deepseek-jev'; then printf '%s' "$d"; return 0; fi
    done
    return 1
}

self_test() {
    local repo fail=0
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && repo=$(find_target)
    [ -z "$repo" ] && { printf 'FAIL repo not found\n'; return 1; }
    for f in scripts/usability-proceed.sh scripts/test-durable.sh scripts/progress-review.sh scripts/closeout-gate.py docs/USABILITY-TESTING.md; do
        [ -f "$repo/$f" ] || { printf 'FAIL missing %s\n' "$f"; fail=1; }
    done
    bash -n "$repo/scripts/usability-proceed.sh" || fail=1
    python3 "$repo/scripts/closeout-gate.py" --self-test || fail=1
    bash "$repo/scripts/usability-proceed.sh" --self-test || fail=1
    if [ "$fail" -eq 0 ]; then printf '%s: self-test PASS\n' "$SCRIPT"; else printf '%s: self-test FAIL\n' "$SCRIPT"; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--repo PATH] [--base URL] [--hygiene-timeout S] [--dry-run] [--self-test]\n' "$SCRIPT"
}

main() {
    local a
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) shift; REPO_ARG="${1:-}" ;;
            --repo=*) REPO_ARG="${1#--repo=}" ;;
            --base) shift; BASE="${1:-$BASE}" ;;
            --base=*) BASE="${1#--base=}" ;;
            --hygiene-timeout) shift; HYGIENE_TIMEOUT="${1:-$HYGIENE_TIMEOUT}" ;;
            --hygiene-timeout=*) HYGIENE_TIMEOUT="${1#--hygiene-timeout=}" ;;
            --dry-run) DRY=1 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1" >&2; usage; return 2 ;;
        esac
        shift
    done
    BASE="${BASE%/}"

    section "A1. provenance and stall fixes"
    REPO=$(find_target) || { bad "no opencode-deepseek-jev repo; pass --repo PATH"; return 1; }
    local remote head
    remote=$(git -C "$REPO" remote get-url origin 2>&1)
    head=$(git -C "$REPO" rev-parse --short HEAD 2>&1)
    printf 'repo:   %s\nremote: %s\nhead:   %s\nbase:   %s\n' "$REPO" "$remote" "$head" "$BASE"
    case "$remote" in *opencode-deepseek-jev*) ok "remote is opencode-deepseek-jev" ;; *) bad "wrong remote: $remote"; return 1 ;; esac
    local f
    for f in scripts/usability-proceed.sh scripts/test-durable.sh scripts/progress-review.sh scripts/closeout-gate.py web/src/components/Usability.jsx; do
        [ -f "$REPO/$f" ] && ok "present: $f" || { bad "missing: $f"; return 1; }
    done
    # The three host-stall fixes must be in the tree: bounded sub-checks,
    # isolated git config, and bounded fixture cleanup (GNU rm prompts on a TTY).
    grep -q 'DURABLE_STEP_TIMEOUT' "$REPO/scripts/test-durable.sh" && ok "test-durable sub-checks bounded" || { bad "test-durable lacks DURABLE_STEP_TIMEOUT"; return 1; }
    grep -q 'GIT_CONFIG_GLOBAL' "$REPO/scripts/progress-review.sh" && ok "self-test git config isolated" || { bad "progress-review lacks GIT_CONFIG_GLOBAL isolation"; return 1; }
    grep -q 'timeout 10 rm -r' "$REPO/scripts/progress-review.sh" && ok "fixture cleanup bounded" || { bad "progress-review cleanup not bounded"; return 1; }

    section "A2. citation log"
    if [ -f "$REPO/docs/USABILITY-TESTING.md" ] && grep -q 'Verification log' "$REPO/docs/USABILITY-TESTING.md"; then
        ok "docs/USABILITY-TESTING.md carries the verification log"
    else
        bad "citation verification log missing"; return 1
    fi

    section "A3. executable gate runner"
    [ -x "$REPO/scripts/usability-proceed.sh" ] && ok "usability-proceed.sh executable" || { bad "usability-proceed.sh not executable"; return 1; }

    if [ "$DRY" -eq 1 ]; then
        section "dry run"
        printf 'would run:\n  %s/scripts/usability-proceed.sh --gates-only --hygiene-timeout %s\n  %s/scripts/usability-proceed.sh --skip-gates --base %s\n' \
            "$REPO" "$HYGIENE_TIMEOUT" "$REPO" "$BASE"
        return 0
    fi

    section "A4. gates"
    if ! "$REPO/scripts/usability-proceed.sh" --gates-only --hygiene-timeout "$HYGIENE_TIMEOUT"; then
        bad "gates stopped (the named line above is the blocker)"; return 1
    fi
    ok "gates: 3 pass / 0 fail"

    section "A5-A7. build, restart, verify, closeout, retest, push"
    if ! "$REPO/scripts/usability-proceed.sh" --skip-gates --base "$BASE"; then
        bad "proceed stopped (see the named line above)"; return 1
    fi
    ok "proceed completed"

    section "result"
    if [ "$FAILED" -eq 0 ]; then
        printf 'PASS: all autopilot asserts passed; the guided retest is recorded.\n'
        return 0
    fi
    printf 'FAIL: see above.\n'
    return 1
}

main "$@"
