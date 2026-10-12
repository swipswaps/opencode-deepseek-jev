#!/usr/bin/env bash
# dns-audit.sh — read-only DNS-forensics collector (sections A-C).
# Run ON THE FAILING BOX (here: .45 lighthouse), paste all output back.
# Changes nothing: no restarts, no file writes outside /tmp/opencode-dns.txt.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
OUT="/tmp/opencode-dns.txt"
mkdir -p /tmp 2>&1 || true
{
printf '\n=== A1 IPv4 addresses ===\n'
ip -4 -brief address 2>&1
printf '\n=== A2 routes ===\n'
ip -4 route show table all 2>&1 | head -n 40
printf '\n=== A3 route to public IP ===\n'
ip route get 1.1.1.1 2>&1
printf '\n=== A4 route to MagicDNS ===\n'
ip route get 100.100.100.100 2>&1
printf '\n=== A5 NM devices ===\n'
nmcli device status 2>&1
printf '\n=== B1 resolv.conf ===\n'
ls -l /etc/resolv.conf 2>&1
cat /etc/resolv.conf 2>&1
printf '\n=== B2 resolved service ===\n'
systemctl is-active systemd-resolved 2>&1
printf '\n=== B3 per-interface DNS ===\n'
resolvectl dns 2>&1
printf '\n=== B4 routing domains (who owns ~. ?) ===\n'
resolvectl domain 2>&1
printf '\n=== B5 full status ===\n'
resolvectl status 2>&1 | head -n 60
printf '\n=== C1 OS lookup ===\n'
getent ahostsv4 fedoraproject.org 2>&1
printf '\n=== C2 resolved lookup ===\n'
resolvectl query fedoraproject.org 2>&1 | head -n 10
printf '\n=== C3 explicit resolver ===\n'
command -v dig 2>&1 | grep -q dig && dig +time=3 +tries=1 @1.1.1.1 fedoraproject.org A 2>&1 | head -n 12 || printf 'dig absent, skipped\n'
printf '\n=== D1 tailscale ===\n'
tailscale status 2>&1 | head -n 15
printf '\n=== D2 VPN conns ===\n'
nmcli connection show --active 2>&1
} | tee "$OUT" 2>&1
printf 'saved: %s\n' "$OUT"
