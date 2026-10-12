#!/usr/bin/env bash
# hotspot-test.sh — roaming test from a hotspot-tethered client (.45 example).
# Proves the overlay URLs survive a LAN switch that kills LAN-bound URLs.
# Run ON THE ROAMING BOX (here .45 on the Samsung hotspot). Read-only
# except a fresh Chrome CDP profile under /tmp when Chrome is present.
# Exit 0 all-green, 2 otherwise.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'NOT-OK %s :: %s\n' "$1" "$2"; }
printf '== 1. uplink + DNS (must hold before anything else) ==\n'
if getent ahostsv4 fedoraproject.org 2>&1 | grep -q STREAM; then ok "DNS resolves"; else no "DNS" "run dns-guard.sh --fix first"; fi
printf '\n== 2. overlay endpoints (survive the switch) ==\n'
# NOTE: curl stderr is kept (never 2>/dev/null) and parsed: evidence stays.
out=$(curl -k -sS -m 10 -o /dev/null -w "HTTPCODE:%{http_code}" https://10.100.0.24:4096/session 2>&1)
code=$(printf '%s' "$out" | grep -oE "HTTPCODE:[0-9]{3}" || true); code=${code#HTTPCODE:}; code=${code:-000}
if [ "$code" = "401" ]; then ok "nebula :4096 alive (401 = TLS-OK + auth gate)"; else no "nebula :4096" "got $code (large-response stall? see MTU note in README)"; fi
out=$(curl -k -sS -m 10 -o /dev/null -w "HTTPCODE:%{http_code}" https://10.100.0.24:5099/api/health 2>&1)
code=$(printf '%s' "$out" | grep -oE "HTTPCODE:[0-9]{3}" || true); code=${code#HTTPCODE:}; code=${code:-000}
if [ "$code" = "200" ]; then ok "nebula :5099 dashboard alive"; else no "nebula :5099" "got $code"; fi
printf '\n== 3. LAN-bound URL (expected to fail off-LAN — control) ==\n'
out=$(curl -k -sS -m 8 -o /dev/null -w "HTTPCODE:%{http_code}" https://192.168.4.24:4096/session 2>&1)
code=$(printf '%s' "$out" | grep -oE "HTTPCODE:[0-9]{3}" || true); code=${code#HTTPCODE:}; code=${code:-000}
printf 'belkin URL from hotspot: %s (200/401 = still bridged, timeout/000 = LAN gone as predicted)\n' "$code"
printf '\n== 4. public Pages (UI anywhere) ==\n'
out=$(curl -sS -m 15 -o /dev/null -w "HTTPCODE:%{http_code}" https://swipswaps.github.io/opencode-deepseek-jev/ 2>&1)
code=$(printf '%s' "$out" | grep -oE "HTTPCODE:[0-9]{3}" || true); code=${code#HTTPCODE:}; code=${code:-000}
if [ "$code" = "200" ]; then ok "Pages reachable"; else no "Pages" "got $code"; fi
printf '\n== 5. Chrome (visual pass, optional) ==\n'
if command -v google-chrome-stable 2>&1 | grep -q google-chrome-stable; then
    google-chrome-stable --version 2>&1
    printf 'GUI: open https://10.100.0.24:4096/ > accept Basic login (opencode) > sessions list renders\n'
else
    printf 'SKIP visual pass (no google-chrome-stable on this box)\n'
fi
printf '\nhotspot-test: %s pass, %s fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 2; fi
exit 0
