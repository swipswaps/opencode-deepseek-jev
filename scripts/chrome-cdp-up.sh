#!/usr/bin/env bash
# chrome-cdp-up.sh — ensure a CDP-reachable Chrome, scripted (no manual typing).
# Run ON THE HOST (where the display/browser live):
#   bash scripts/chrome-cdp-up.sh
# Starts google-chrome-stable with --remote-debugging-port=9222 on
# /tmp/chrome-cdp only if the port is closed, then polls /json/version
# for up to 30s. --remote-allow-origins=* is set so a client on ANOTHER host
# (the sandbox) can attach over websocket. The debug port binds loopback by
# default, so to reach it from the sandbox forward it, e.g. on the host:
#   socat TCP-LISTEN:9223,fork,reuseaddr TCP:127.0.0.1:9222
# then in the sandbox (see RULES #62):
#   CDP_HOST=<host-ip> CDP_PORT=9223 node scripts/cdp-tab.mjs tabs
# Prints log tail on failure. Exit 0 reachable, 2 not.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
PORT="${CDP_PORT:-9222}"
DIR="/tmp/chrome-cdp"
if curl -s -m 3 "http://127.0.0.1:${PORT}/json/version" 2>&1 | grep -q Browser; then
    printf 'CDP already listening on %s\n' "$PORT"
    exit 0
fi
printf 'starting chrome --remote-debugging-port=%s ...\n' "$PORT"
mkdir -p "$DIR" || exit 2
# setsid: put Chrome in its OWN session so a ^C on this script's wait loop
# does NOT signal Chrome (nohup only ignores SIGHUP, not SIGINT).
setsid google-chrome-stable --remote-debugging-port="$PORT" \
    --remote-allow-origins='*' \
    --user-data-dir="$DIR" --no-first-run > /tmp/chrome-cdp.log 2>&1 < /dev/null &
i=0
while [ "$i" -lt 30 ]; do
    if curl -s -m 3 "http://127.0.0.1:${PORT}/json/version" 2>&1 | grep -q Browser; then
        printf 'CDP listening on %s after %ss\n' "$PORT" "$i"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done
printf 'GATE FAIL: CDP not reachable after 30s; log tail:\n'
tail -n 15 /tmp/chrome-cdp.log 2>&1 || true
exit 2
