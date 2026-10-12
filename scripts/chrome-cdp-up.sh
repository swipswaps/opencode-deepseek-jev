#!/usr/bin/env bash
# chrome-cdp-up.sh — ensure a CDP-reachable Chrome, scripted (no manual typing).
# Run ON THE HOST:
#   bash scripts/chrome-cdp-up.sh
# Starts google-chrome-stable with --remote-debugging-port=9222 on
# /tmp/chrome-cdp only if the port is closed, then polls /json/version
# for up to 30s. Prints log tail on failure. Exit 0 reachable, 2 not.
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
nohup google-chrome-stable --remote-debugging-port="$PORT" \
    --user-data-dir="$DIR" --no-first-run > /tmp/chrome-cdp.log 2>&1 &
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
