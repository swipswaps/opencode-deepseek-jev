#!/usr/bin/env bash
#
# guard-env-read.sh — make "never print .env" an enforced rule, not a habit.
#
# F1's leak surface is the terminal: `cat .env.local` prints live keys into the
# scrollback/transcript, where rotation is the only remedy. The blacklist guard
# already blocks destructive commands; this adds the read class:
#   - cat/less/more/head/tail/nl/xxd/od/strings ... .env*   -> block
#   - grep ... .env*                                        -> block, EXCEPT
#     -c / -q (count/match: no value is printed)
#
#   ./scripts/guard-env-read.sh --check     # report only
#   ./scripts/guard-env-read.sh --install   # patch guard + self-test, run them
#
# Idempotent. A restart of the opencode session is required to load the rule.
# Exit 0 installed/clean, 1 not installed (--check), 2 error.
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. printf only.
#
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

have() { command -v "$1" >/dev/null 2>&1; }

main() {
    local REPO MODE="check"
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi
    case "${1:-}" in
        --check) MODE="check" ;;
        --install) MODE="install" ;;
        -h | --help) printf 'usage: %s [--check|--install]\n' "$0"; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac

    local GUARD="$REPO/.opencode/plugins/blacklist-guard.js"
    local ST="$REPO/scripts/blacklist-guard-self-test.mjs"
    [ -f "$GUARD" ] || { printf 'FAIL: guard missing: %s\n' "$GUARD"; return 2; }
    have python3 || { printf 'FAIL: python3 required\n'; return 2; }
    have node || { printf 'FAIL: node required\n'; return 2; }

    if grep -q 'name: "env-read"' "$GUARD"; then
        printf 'env-read rules: installed\n'
        [ "$MODE" = "check" ] && return 0
    else
        printf 'env-read rules: NOT installed\n'
        [ "$MODE" = "check" ] && return 1
    fi

    if [ "$MODE" = "install" ]; then
        python3 - "$GUARD" "$ST" <<'PY'
import pathlib, sys

guard = pathlib.Path(sys.argv[1]); st = pathlib.Path(sys.argv[2])
s = guard.read_text()
if 'name: "env-read"' not in s:
    anchor = "const RULES = [\n"
    assert anchor in s, "RULES anchor missing"
    block = r'''  { name: "env-read", pattern: "(?:^|[;&|()]\\s*)(?:cat|less|more|head|tail|nl|xxd|od|strings)\\b[^\\n]*\\.env", sev: "block",
    fix: "never print .env: use awk -F= '/^KEY=/{print length($2)}' .env.local, or the rotate scripts (they mask)", rule: "security" },
  { name: "env-grep", pattern: "(?:^|[;&|()]\\s*)grep\\s+(?![^\\n]*(?:\\s*-[A-Za-z]*[qc]\\b|\\s*--count\\b|\\s*--quiet\\b))[^\\n]*\\.env", sev: "block",
    fix: "grep -c/-q only (count/match, no value); otherwise awk length or the rotate scripts", rule: "security" },
'''
    s = s.replace(anchor, anchor + block, 1)
    guard.write_text(s)
    print("patched " + str(guard))

st_s = st.read_text()
if 'env-read' not in st_s:
    anchor = "  [\"grep 'rm -rf' .\", \"rm -rf\", false],\n"
    assert anchor in st_s, "self-test anchor missing"
    block = '''  ["cat -n .env.local", "env-read", true],
  ["head -n 5 .env.production", "env-read", true],
  ["cat .env.local | less", "env-read", true],
  ["grep '^KEY=' .env.local", "env-grep", true],
  ["grep -c '^KEY=' .env.local", "env-grep", false],
  ["grep -q '^KEY=' .env.local", "env-grep", false],
  ["cat README.md", "env-read", false],
'''
    st_s = st_s.replace(anchor, anchor + block, 1)
    st.write_text(st_s)
    print("patched " + str(st))
PY
        if [ "$?" -ne 0 ]; then printf 'FAIL: patch step failed\n'; return 2; fi
        node --check "$GUARD" || { printf 'FAIL: guard does not parse\n'; return 2; }
        node "$ST" || { printf 'FAIL: guard self-test\n'; return 2; }
        printf 'installed. restart the opencode session (web-restart.sh) to load the rule.\n'
    fi
    return 0
}

main "$@"
