#!/usr/bin/env bash
#
# pages-export.sh — consent-gated static export for GitHub Pages.
#
# Flow:
#   1. Resolve repo + node + database (read-only, never written).
#   2. Consent: allow ONCE (this run only), allow ALWAYS (remembered while
#      models.policy.json is unchanged), or deny. In CI (GITHUB_ACTIONS)
#      --yes treats the workflow_dispatch click as the allow-once.
#      Offered as numbered buttons; --yes/--no for wrappers.
#   3. Gates: node builder fails closed on zero sessions/models and on any
#      secret shape surviving redaction. A second grep gate re-scans the
#      written site/ before reporting success.
#   4. Prints the next step (dispatch the Pages workflow) — never pushes.
#
# Usage:
#   ./scripts/pages-export.sh [--yes] [--no] [--out site] [--limit 500]
#   ./scripts/pages-export.sh --shell [--yes] [--out site]
#     --shell assembles site/ from committed site-data/panel.json (no DB;
#     for CI, which never sees the database).
#   PAGES_CONSENT=always ./scripts/pages-export.sh --yes   (CI shape)
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
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

STAMP=""
POLICY_HASH=""

consent_valid() {
    [ -f "$STAMP" ] || return 1
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get('scope') == 'always' and d.get('policyHash') == sys.argv[2] else 1)
" "$STAMP" "$POLICY_HASH" 2>&1
}

record_consent() {
    python3 -c "
import json, sys, datetime
open(sys.argv[1], 'w').write(json.dumps({
    'scope': sys.argv[2],
    'policyHash': sys.argv[3],
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}) + chr(10))
" "$STAMP" "$1" "$POLICY_HASH" 2>&1
}

main() {
    local YES=0 NO=0 OUT="site" LIMIT="500" SHELL=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes) YES=1; shift ;;
            --no) NO=1; shift ;;
            --shell) SHELL=1; shift ;;
            --out) shift; OUT="${1:-site}"; shift ;;
            --limit) shift; LIMIT="${1:-500}"; shift ;;
            --help|-h) printf 'usage: %s [--yes] [--no] [--shell] [--out site] [--limit 500]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--yes] [--no] [--shell] [--out site] [--limit 500]\n' "$0" >&2; return 2 ;;
        esac
    done
    if [ "$NO" -eq 1 ]; then
        printf 'denied (--no); nothing exported\n'
        return 1
    fi

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n' >&2
        return 2
    fi
    if ! have node; then
        printf 'FAIL: node is required\n' >&2
        return 2
    fi
    local DB="$REPO/data/opencode/opencode.db"
    if [ ! -f "$DB" ]; then
        printf 'FAIL: no database at %s\n' "$DB" >&2
        return 2
    fi
    STAMP="$REPO/data/observability/pages-consent.json"
    if [ "$SHELL" -eq 1 ]; then
        if [ "$YES" -ne 1 ]; then
            printf 'GATE FAIL: --shell needs --yes (assert reviewed panel data)\n' >&2
            return 2
        fi
        case "$OUT" in
            /*) OUT_DIR="$OUT" ;;
            *) OUT_DIR="$REPO/$OUT" ;;
        esac
        printf '=== pages-export.sh (shell) ===\n'
        if ! node "$REPO/scripts/pages-export.mjs" --shell-only \
            --commit site-data/panel.json --out "$OUT_DIR" 2>&1; then
            printf 'GATE FAIL: shell assembly refused; nothing published\n' >&2
            return 2
        fi
        printf 'wrote: %s/index.html\n' "$OUT_DIR"
        return 0
    fi
    POLICY_HASH=$(python3 -c "import hashlib; print(hashlib.sha256(open('$REPO/models.policy.json','rb').read()).hexdigest()[:12])" 2>&1)
    local REV="unknown"
    REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 | head -n 1) || REV="unknown"

    local SCOPE=""
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        if [ "$YES" -ne 1 ]; then
            printf 'GATE FAIL: CI requires --yes (the dispatch click is the allow-once)\n' >&2
            return 2
        fi
        SCOPE="once-ci"
    elif [ "$YES" -eq 1 ]; then
        if consent_valid; then
            SCOPE="always"
        else
            printf 'GATE FAIL: --yes needs a recorded allow-always (run interactively once first)\n' >&2
            return 2
        fi
    elif [ -t 0 ]; then
        printf 'Publish redacted aggregates (titles redacted, no message text) to GitHub Pages?\n'
        printf '  policy: %s  rev: %s\n' "$POLICY_HASH" "$REV"
        printf '  [1] allow once   (this export only)\n'
        printf '  [2] allow always (until models.policy.json changes)\n'
        printf '  [3] deny\n'
        printf 'choice [1/2/3]: '
        local ans
        IFS= read -r ans || ans=""
        case "$ans" in
            1) SCOPE="once" ;;
            2) SCOPE="always"; record_consent "always" || return 2 ;;
            *) printf 'denied; nothing exported\n'; return 1 ;;
        esac
    else
        printf 'GATE FAIL: non-interactive without --yes; nothing exported\n' >&2
        return 2
    fi
    if [ "$SCOPE" = "once" ]; then
        record_consent "once" || return 2
    fi
    local CONSENT
    CONSENT=$(python3 -c "import json,datetime; print(json.dumps({'scope':'$SCOPE','policyHash':'$POLICY_HASH','ts':datetime.datetime.now(datetime.timezone.utc).isoformat()}))" 2>&1)

    printf '=== pages-export.sh ===\n'
    printf 'consent: %s  policy: %s  rev: %s\n' "$SCOPE" "$POLICY_HASH" "$REV"
    case "$OUT" in
        /*) OUT_DIR="$OUT" ;;
        *) OUT_DIR="$REPO/$OUT" ;;
    esac
    if ! node --no-warnings --experimental-sqlite "$REPO/scripts/pages-export.mjs" \
        --db "$DB" --out "$OUT_DIR" --consent "$CONSENT" --rev "$REV" --limit "$LIMIT" \
        --commit site-data/panel.json 2>&1; then
        printf 'GATE FAIL: builder refused (see FAIL line above); nothing published\n' >&2
        return 2
    fi
    if grep -rE "sk-[A-Za-z0-9]{20,}|apikey_[A-Za-z0-9_]{16,}" "$OUT_DIR/data.json" 2>&1 | head -n 3; then
        printf 'GATE FAIL: secret shape in output (refusing)\n' >&2
        return 2
    fi
    printf 'redaction gate: clean\n'
    printf 'wrote: %s/index.html %s/data.json\n' "$OUT_DIR" "$OUT_DIR"
    printf 'committable: site-data/panel.json (review diff, then push)\n'
    printf 'next: dispatch the Pages workflow (Actions > Deploy panel > Run workflow)\n'
    return 0
}

main "$@"
