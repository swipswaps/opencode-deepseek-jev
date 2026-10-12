#!/usr/bin/env bash
# ux.sh — one router for the web-probe workflow (hermes-style command table).
# Adapted from hermes-agent's CLI-vs-messaging quick reference: a single
# verb table, shared by interactive use and unattended runs.
# Steps mirror agents/probe.yaml in order (yaml is the contract).
#
# Usage (run ON THE HOST from the repo root):
#   bash scripts/ux.sh help              # this table
#   bash scripts/ux.sh status            # chrome + probe (full PASS check)
#   bash scripts/ux.sh chrome            # ensure CDP-reachable browser only
#   bash scripts/ux.sh probe             # probe + telemetry only
#   bash scripts/ux.sh findings          # guided :5099 findings (plain language)
#   bash scripts/ux.sh recall [keyword]  # keyword recall, default: mesh
#   bash scripts/ux.sh cost              # cost accounting
# Exit 0 all-green, 2 otherwise.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
usage() {
    printf 'usage: bash scripts/ux.sh [help|status|chrome|probe|findings|recall [kw]|cost]\n'
    printf '  status   chrome + probe (the PASS check)\n'
    printf '  chrome   ensure CDP browser\n'
    printf '  probe    probe + telemetry\n'
    printf '  findings guided :5099 findings in plain language\n'
    printf '  recall   keyword recall over sessions (default: mesh)\n'
    printf '  cost     cost accounting\n'
}
cmd="${1:-help}"
case "$cmd" in
    help) usage; exit 0 ;;
    chrome) bash scripts/chrome-cdp-up.sh; exit "$?" ;;
    probe) bash scripts/probe-diagnose.sh; exit "$?" ;;
    findings) bash scripts/ux-findings.sh; exit "$?" ;;
    recall)
        kw="${2:-mesh}"
        python3 scripts/recall-sessions.py "$kw" --limit 5
        exit "$?"
        ;;
    cost) bash scripts/cost.sh; exit "$?" ;;
    status)
        bash scripts/chrome-cdp-up.sh || exit 2
        bash scripts/probe-diagnose.sh || exit 2
        exit 0
        ;;
    *) usage; exit 2 ;;
esac
