#!/usr/bin/env bash
# probe-diagnose.sh — scripted probe telemetry, no manual typing.
# Run ON THE HOST from the repo root:
#   bash scripts/probe-diagnose.sh
# Sources .env.local (never prints it), runs the probe, then reports
# verdict/counts/reasons + screenshot sizes + live DOM markers, and
# prints the deterministic next action. Exit 0 PASS, 2 FAIL.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
if [ -f .env.local ]; then
    set -a
    . ./.env.local
    set +a
fi
export OPENCODE_API_URL="${OPENCODE_API_URL:-https://192.168.4.24:4096}"
export DASH_URL="${DASH_URL:-https://192.168.4.24:5099}"
export NODE_TLS_REJECT_UNAUTHORIZED=0
if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    printf 'GATE FAIL: OPENCODE_SERVER_PASSWORD not set (sourced .env.local, still empty)\n'
    exit 2
fi
node scripts/cdp-tab.mjs probe 2>&1 | grep -v "trace-warnings" || true
printf '\n== telemetry (probe-latest.json) ==\n'
python3 -c "
import json
r = json.load(open('logs/cdp/probe-latest.json'))
print('verdict:', r.get('verdict'))
print('counts:', r.get('counts'))
for s in r.get('steps', []):
    print(('ok   ' if s.get('ok') else 'NOT-OK ') + s.get('name') + ' :: ' + str(s.get('detail'))[:100])
for x in r.get('reasons', []):
    print('reason:', x)
for x in r.get('notes', []):
    print('note:', x)
"
printf '\n== screenshots ==\n'
ls -l logs/cdp/probe-5099.png logs/cdp/probe-4096.png 2>&1 || true
printf '\n== live DOM markers (scripted, no typing) ==\n'
node scripts/cdp-tab.mjs eval ":5099" "location.href + ' :: ' + document.title" 2>&1 | grep -v "trace-warnings" || true
node scripts/cdp-tab.mjs eval ":5099" "document.querySelectorAll('[data-loading]').length" 2>&1 | grep -v "trace-warnings" || true
node scripts/cdp-tab.mjs eval ":5099" "document.querySelectorAll('#list .card').length" 2>&1 | grep -v "trace-warnings" || true
node scripts/cdp-tab.mjs eval ":5099" "Array.prototype.slice.call(document.querySelectorAll('[id]'),0,40).map(function(e){return e.id;}).join(',')" 2>&1 | grep -v "trace-warnings" || true
node scripts/cdp-tab.mjs eval ":5099" "document.body ? document.body.innerText.slice(0,200) : 'no body'" 2>&1 | grep -v "trace-warnings" || true
printf '\n== next action ==\n'
python3 -c "
import json
r = json.load(open('logs/cdp/probe-latest.json'))
v = r.get('verdict')
reasons = ' '.join(r.get('reasons', []))
if v == 'PASS':
    print('GREEN: nothing to do. drift note (if any) is by design (project slice vs all projects).')
elif 'opencode api unreachable' in reasons:
    print('RED: password/env. verify .env.local sets OPENCODE_SERVER_PASSWORD, then re-run this script.')
elif 'loading markers left' in reasons:
    print('AMBER: dashboard still settling. inspect logs/cdp/probe-5099.png size above; if 0 cards, check opencode-web logs for dashboard.mjs errors.')
elif 'no rendered session rows' in reasons:
    print('AMBER: dashboard rendered 0 cards. check #count text above and container dashboard log.')
else:
    print('RED: see reasons above.')
"
