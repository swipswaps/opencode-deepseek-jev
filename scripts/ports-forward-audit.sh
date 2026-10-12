#!/usr/bin/env bash
# ports-forward-audit.sh — deduce best steps for :4096/:5099 off-LAN.
# Run ON THE HOST (owner@192.168.4.24), not in the agent sandbox:
#   bash scripts/ports-forward-audit.sh [hostname]
# Default hostname: mesh-lh01.duckdns.org (docs/ANYWHERE.md).
# Read-only: prints verdict + next commands. No firewall changes here
# (eero has no LAN admin page — port forwards live in the eero phone app).
set -uo pipefail
HOSTNAME_ARG="${1:-mesh-lh01.duckdns.org}"
echo "== target: $HOSTNAME_ARG"
echo "--- dns"
python3 -c "import socket,sys; h=sys.argv[1]
try: print('duckdns ->', socket.gethostbyname(h))
except Exception as e: print('duckdns RESOLVE-FAIL', str(e)[:120])" "$HOSTNAME_ARG"
echo "--- wan (what the internet sees)"
curl -sS -m 10 https://api.ipify.org 2>&1; echo
echo "--- lan ports on 192.168.4.24"
python3 -c "
import socket
for port in [80,443,4096,5099]:
    s=socket.socket(); s.settimeout(3)
    try: s.connect(('192.168.4.24',port)); print(port,'OPEN')
    except Exception: print(port,'CLOSED')
    finally: s.close()"
echo "--- cert SANs"
openssl x509 -in docker/certs/opencode.crt -noout -ext subjectAltName 2>&1 | head -n 4
bash docker/certs-init.sh --check 2>&1
echo
echo "== verdict"
echo "If duckdns IP == wan IP and 443 is CLOSED: forward 443 (and 80 for HTTP-01)"
echo "  to 192.168.4.24 in the eero phone app, then enable the DuckDNS Caddyfile."
echo "If LAN-only is enough: skip forwarding entirely — rotate IP SAN + trust CA:"
echo "  CERT_EXTRA_SANS=IP:192.168.4.24 ./docker/certs-init.sh"
echo "  sudo docker compose -f docker-compose.yml -f docker-compose.override.yml restart caddy"
echo "  ./docker/certs-trust.sh   # once per client machine"
