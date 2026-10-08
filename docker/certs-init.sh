#!/usr/bin/env bash
#
# certs-init.sh — self-healing TLS for caddy (:4096/:5099, see Caddyfile).
#
# Model: a stable machine-local CA (ca.crt/ca.key, 10y) signs short server
# certs (825d). Clients that trust the CA once never warn again; server
# certs rotate freely (new IPs, new hosts) without re-trust.
#
#   ./docker/certs-init.sh              # ensure: create CA if missing,
#                                       # reissue server cert if SANs lack
#                                       # a needed name. Prints ROTATED when
#                                       # the server pair changed (callers
#                                       # restart caddy on that word).
#   ./docker/certs-init.sh --check      # verify only: exit 0 covered,
#                                       # exit 1 gaps (names listed)
#   ./docker/certs-init.sh --rotate     # force server reissue (same CA)
#   ./docker/certs-init.sh --rotate-ca   # new CA + server (re-trust everywhere)
#   CERT_DIR=/tmp/x ./docker/certs-init.sh   # test target
#
# Needed SANs: localhost + 127.0.0.1 always; every nebula IPv4 present;
# plus CERT_EXTRA_SANS (comma-separated, e.g. "IP:10.100.0.24,DNS:name").
# Key files 0640 (caddy runs user 1000:1000 under cap_drop ALL), certs 0644.
# Everything here is gitignored (see certs/.gitignore): never commits.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"
CA_CRT="$CERT_DIR/ca.crt"
CA_KEY="$CERT_DIR/ca.key"
CRT="$CERT_DIR/opencode.crt"
KEY="$CERT_DIR/opencode.key"

needed_sans() {
    # Loopback + nebula overlay only: LAN/docker IPs churn (and users
    # should reach services via the stable mesh IP anyway), so covering
    # them would rotate the cert on every network change.
    local sans="DNS:localhost,IP:127.0.0.1"
    local neb=""
    if command -v ip > /dev/null; then
        neb="$(ip -brief addr show nebula0 2>&1 | awk '{for (i=3; i<=NF; i++) {split($i,a,"/"); if (a[1] ~ /^10\./) print "IP:"a[1]}}')" || neb=""
    fi
    local ip
    for ip in $neb; do
        case ",$sans," in *",$ip,"*) ;; *) sans="$sans,$ip" ;; esac
    done
    if [ -n "${CERT_EXTRA_SANS:-}" ]; then
        sans="$sans,${CERT_EXTRA_SANS}"
    fi
    printf '%s' "$sans"
}

sans_of() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>&1 \
        | grep -o -E "(DNS|IP Address):[^, ]+" \
        | awk -F: '{if ($1=="IP Address") print "IP:"$2; else print $1":"$2}' \
        | sort -u | tr '\n' ',' || true
}

covered() {
    local need="$1" have="$2" entry
    local IFS=","
    for entry in $need; do
        [ -n "$entry" ] || continue
        case ",$have," in *",$entry,"*) ;; *) return 1 ;; esac
    done
    return 0
}

ensure_ca() {
    if [ -f "$CA_CRT" ] && [ -f "$CA_KEY" ]; then
        return 0
    fi
    printf 'minting local CA (10y)\n'
    openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
        -keyout "$CA_KEY" -out "$CA_CRT" \
        -subj "/CN=opencode-local-ca" 2>&1 || return 1
    chmod 640 "$CA_KEY" || return 1
    chmod 644 "$CA_CRT" || return 1
    return 0
}

issue_server() {
    local sans="$1" cfg
    cfg="$(mktemp)" || return 1
    printf '[req]\ndistinguished_name=dn\nreq_extensions=ext\n[dn]\n[ext]\nsubjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$sans" > "$cfg" || return 1
    openssl req -newkey rsa:2048 -nodes -keyout "$KEY" -out "$cfg.csr" \
        -subj "/CN=opencode-local" -config "$cfg" 2>&1 || { rm -f "$cfg" "$cfg.csr"; return 1; }
    printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$sans" > "$cfg.ext" || return 1
    openssl x509 -req -in "$cfg.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
        -CAcreateserial -days 825 -sha256 \
        -extfile "$cfg.ext" -out "$CRT" 2>&1 || { rm -f "$cfg" "$cfg.csr" "$cfg.ext"; return 1; }
    rm -f "$cfg" "$cfg.csr" "$cfg.ext"
    chmod 640 "$KEY" || return 1
    chmod 644 "$CRT" || return 1
    return 0
}

main() {
    local mode="ensure"
    case "${1:-}" in
        --check) mode="check" ;;
        --rotate) mode="rotate" ;;
        --rotate-ca) mode="rotate-ca" ;;
        "") ;;
        *) printf 'usage: %s [--check|--rotate|--rotate-ca]\n' "$0"; return 2 ;;
    esac

    if ! command -v openssl > /dev/null; then
        printf 'GATE FAIL: openssl not found\n'
        return 1
    fi
    mkdir -p "$CERT_DIR" || return 1

    if [ "$mode" = "rotate-ca" ]; then
        rm -f "$CA_CRT" "$CA_KEY" "$CRT" "$KEY" "$CERT_DIR/ca.srl"
    fi
    ensure_ca || return 1

    local need have=""
    need="$(needed_sans)"
    if [ -f "$CRT" ] && [ -f "$KEY" ]; then
        have="$(sans_of "$CRT")"
    fi

    if [ "$mode" = "check" ]; then
        if [ -n "$have" ] && covered "$need" "$have" \
            && openssl verify -CAfile "$CA_CRT" "$CRT" > /dev/null 2>&1; then
            printf 'COVERED: %s\n' "$have"
            return 0
        fi
        printf 'GAPS: need %s; have %s\n' "$need" "${have:-nothing}"
        return 1
    fi

    if [ "$mode" != "rotate" ] && [ -n "$have" ] && covered "$need" "$have" \
        && openssl verify -CAfile "$CA_CRT" "$CRT" > /dev/null 2>&1; then
        printf 'certs present and covered: %s\n' "$have"
        return 0
    fi

    issue_server "$need" || return 1
    if ! openssl verify -CAfile "$CA_CRT" "$CRT" > /dev/null 2>&1; then
        printf 'FAIL: issued cert does not verify against local CA\n'
        return 1
    fi
    printf 'ROTATED: %s\n' "$(sans_of "$CRT")"
    printf 'trust once: ./docker/certs-trust.sh (else accept the self-signed warning)\n'
    return 0
}

main "$@"
