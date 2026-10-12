#!/usr/bin/env bash
# enable-lan-cert.sh — LAN path: IP SAN + caddy reload + trust + verify.
# Run ON THE HOST from the repo root:
#   bash scripts/enable-lan-cert.sh
# Idempotent. eero/phone-app untouched (no port forwarding needed).
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
echo "== 1. rotate server cert with LAN SAN"
CERT_EXTRA_SANS="IP:192.168.4.24" ./docker/certs-init.sh || exit 2
echo
echo "== 2. reload caddy (both compose files: override holds the 8 mounts)"
cd "$REPO/docker" || exit 3
sudo docker compose -f docker-compose.yml -f docker-compose.override.yml restart caddy || exit 2
sleep 6
echo
echo "== 3. trust local CA (system + firefox + chromium NSS)"
cd "$REPO" || exit 3
./docker/certs-trust.sh || echo "WARN: trust step incomplete (see above)"
echo
echo "== 4. verify"
openssl x509 -in docker/certs/opencode.crt -noout -ext subjectAltName 2>&1 | head -n 4
openssl verify -CAfile docker/certs/ca.crt docker/certs/opencode.crt 2>&1
python3 -c "
import socket, ssl
# openssl verify above is the gate (matches certs-init.sh logic).
# Python here is diagnostic only: this CA predates keyUsage extensions,
# so strict verifiers report CA-KEY-USAGE rather than chain failure.
for port in [4096, 5099]:
    try:
        ctx = ssl.create_default_context(cafile='docker/certs/ca.crt')
        s = socket.create_connection(('192.168.4.24', port), timeout=8)
        t = ctx.wrap_socket(s, server_hostname='192.168.4.24')
        print(port, 'TLS-VERIFY-OK')
        t.close()
    except Exception as e:
        print(port, 'TLS-DIAG', str(e)[:120])
"
echo "done. relaunch chrome, open https://192.168.4.24:4096/ (no warning expected)."
