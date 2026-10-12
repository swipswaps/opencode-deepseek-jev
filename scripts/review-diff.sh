#!/usr/bin/env bash
# review-diff.sh — pre-push semantic review gate (open-code-review style).
# Reviews the working-tree diff with deterministic file selection plus an
# LLM pass; degrades to SKIP when the reviewer is not installed, never FAIL,
# because a missing optional tool must not block a push (RULES #37).
#
# Usage:
#   bash scripts/review-diff.sh
# Exit 0 clean or SKIP, 2 findings.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
if [ "${1:-}" = "--help" ]; then
    printf 'usage: bash scripts/review-diff.sh\n'
    exit 0
fi
if ! npx --no-install @alibaba-group/open-code-review --version 2>&1 | grep -qE "[0-9]+\.[0-9]+"; then
    printf 'status=SKIP open-code-review not installed (npm i -g @alibaba-group/open-code-review to enable)\n'
    exit 0
fi
npx @alibaba-group/open-code-review review 2>&1
rc="$?"
if [ "$rc" -ne 0 ]; then
    printf 'FAIL review-diff: reviewer reported findings (exit %s)\n' "$rc"
    exit 2
fi
printf 'review-diff: PASS (no findings)\n'
