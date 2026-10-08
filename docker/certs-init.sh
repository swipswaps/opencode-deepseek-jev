#!/usr/bin/env bash
#
# certs-init.sh — mint the machine-local TLS pair caddy terminates on
# :4096/:5099 (see docker/Caddyfile). Self-signed; browsers show a
# one-time warning, curl/API clients use -k or NODE_TLS_REJECT_UNAUTHORIZED=0.
#
#   ./docker/certs-init.sh              # create if missing (safe to re-run)
#   ./docker/certs-init.sh --rotate     # replace even if present
#   CERT_DIR=/tmp/certs-test ./docker/certs-init.sh   # test target
#
# SANs: localhost + 127.0.0.1 always; the host's nebula0 IPv4 (if any);
# plus CERT_EXTRA_SANS (comma-separated, e.g. "IP:10.100.0.24,DNS:name").
# Key is 0640 so the caddy service (user 1000:1000 under cap_drop ALL)
# can read it when the host uid is 1000; cert is 0644. Never commits:
# docker/certs/.gitignore excludes *.crt/*.key.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"
CRT="$CERT_DIR/opencode.crt"
KEY="$CERT_DIR/opencode.key"

main() {
    local rotate=0
    case "${1:-}" in
        --rotate) rotate=1 ;;
        "") ;;
        *) printf 'usage: %s [--rotate]\n' "$0"; return 2 ;;
    esac

    if ! command -v openssl > /dev/null; then
        printf 'GATE FAIL: openssl not found\n'
        return 1
    fi

    if [ -f "$CRT" ] && [ -f "$KEY" ] && [ "$rotate" -ne 1 ]; then
        printf 'certs present: %s (use --rotate to replace)\n' "$CERT_DIR"
        return 0
    fi

    mkdir -p "$CERT_DIR" || return 1

    local sans="DNS:localhost,IP:127.0.0.1"
    local neb_ip=""
    if command -v ip > /dev/null; then
        neb_ip="$(ip -brief addr show nebula0 2>&1 | awk '{print $3; exit}' | cut -d/ -f1)" || neb_ip=""
        case "$neb_ip" in
            10.*|172.*|192.168.*) sans="$sans,IP:$neb_ip" ;;
        esac
    fi
    if [ -n "${CERT_EXTRA_SANS:-}" ]; then
        sans="$sans,${CERT_EXTRA_SANS}"
    fi
    printf 'SANs: %s\n' "$sans"

    local cfg
    cfg="$(mktemp)" || return 1
    printf '[req]\ndistinguished_name=dn\nreq_extensions=ext\n[dn]\n[ext]\nsubjectAltName=%s\n' "$sans" > "$cfg" || return 1

    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
        -keyout "$KEY" -out "$CRT" \
        -subj "/CN=opencode-local" -config "$cfg" -extensions ext 2>&1; then
        printf 'FAIL: openssl req failed\n'
        rm -f "$cfg"
        return 1
    fi
    rm -f "$cfg"

    chmod 640 "$KEY" || return 1
    chmod 644 "$CRT" || return 1
    printf 'wrote %s (0644) and %s (0640)\n' "$CRT" "$KEY"
    printf 'browsers: accept the one-time self-signed warning; curl: -k\n'
    return 0
}

main "$@"
