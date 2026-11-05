#!/usr/bin/env bash
# trust-ca-client.sh — download and trust the local OpenCode observability CA.
#
# Run on the PC/client (not the server). It downloads the public CA from the
# reachable HTTPS endpoint, verifies the certificate, and installs it into the
# system, Firefox, and Chromium NSS stores when possible. Use --check to only
# test; --dry-run to print the operations.
#
#   ./scripts/trust-ca-client.sh --server https://10.100.0.24:5099
#   ./scripts/trust-ca-client.sh --check
#   ./scripts/trust-ca-client.sh --dry-run
#   ./scripts/trust-ca-client.sh --ca ./opencode-local-ca.crt
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
set -uo pipefail

SERVER="${SERVER:-https://10.100.0.24:5099}"
MODE=apply
CA_SRC=""
CA_OUT="${CA_OUT:-$HOME/.local/share/opencode-local-ca.crt}"
DRY=0
CHECK=0

usage() {
    printf '%s\n' \
        'Usage: trust-ca-client.sh [--server URL] [--ca FILE] [--check] [--dry-run]' \
        '  --server URL  live app base (default https://10.100.0.24:5099)' \
        '  --ca FILE     use an already downloaded CA' \
        '  --check       verify only; do not install' \
        '  --dry-run     print install commands; do not run them'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --server) SERVER="${2:-}"; shift 2 ;;
        --ca) CA_SRC="${2:-}"; shift 2 ;;
        --check) CHECK=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

log() { printf '%s\n' "$*"; }
have() { command -v "$1" > /dev/null; }

download_ca() {
    mkdir -p "$(dirname "$CA_OUT")" || return 1
    local base
    for base in "$SERVER" "https://10.100.0.24:5099" "https://10.100.0.24" "https://192.168.4.24:5099" "https://100.119.125.16:5099"; do
        log "trying $base/ca.crt"
        if curl -kfsS --max-time 15 "$base/ca.crt" -o "$CA_OUT"; then
            if grep -q 'BEGIN CERTIFICATE' "$CA_OUT"; then
                log "downloaded $CA_OUT"
                return 0
            fi
        fi
    done
    log "FAIL: could not download CA from any endpoint"
    return 1
}

verify_strict() {
    local code
    code="$(curl -s --cacert "$CA_OUT" -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/rev" 2>&1)"
    if [ "$code" = "200" ]; then
        log "PASS strict TLS verification: $SERVER/api/rev"
        return 0
    fi
    log "CHECK: strict TLS not yet trusted (HTTP ${code})"
    return 1
}

install_system() {
    if [ "$DRY" -eq 1 ]; then
        log "[dry-run] install system trust for $CA_OUT"
        return 0
    fi
    local sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        if sudo -n true; then sudo="sudo"; else
            log "WARN: sudo requires a password; run the printed command yourself"
            log "  sudo cp $CA_OUT /etc/pki/ca-trust/source/anchors/opencode-local-ca.crt && sudo update-ca-trust"
            return 0
        fi
    fi
    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        $sudo cp "$CA_OUT" /etc/pki/ca-trust/source/anchors/opencode-local-ca.crt || return 1
        $sudo update-ca-trust || return 1
        log "system trust: installed (Fedora/RHEL)"
    elif [ -d /usr/local/share/ca-certificates ]; then
        $sudo cp "$CA_OUT" /usr/local/share/ca-certificates/opencode-local-ca.crt || return 1
        $sudo update-ca-certificates || return 1
        log "system trust: installed (Debian/Ubuntu)"
    else
        log "system trust: no known anchor directory; use your OS certificate UI"
    fi
}

install_nss() {
    if ! have certutil; then
        log "nss-tools/certutil not found; browser NSS stores not updated"
        log "  Fedora: sudo dnf install nss-tools"
        return 0
    fi
    if [ "$DRY" -eq 1 ]; then
        log "[dry-run] certutil -A for Firefox profiles and ~/.pki/nssdb"
        return 0
    fi
    local prof n=0
    for prof in "$HOME"/.mozilla/firefox/*.default*; do
        [ -d "$prof" ] || continue
        if certutil -A -d "sql:$prof" -t "C,," -n opencode-local-ca -i "$CA_OUT"; then
            log "firefox: trusted $(basename "$prof")"
            n=$((n + 1))
        fi
    done
    [ "$n" -gt 0 ] || log "firefox: no profiles found under $HOME/.mozilla/firefox"
    local nssdb="$HOME/.pki/nssdb"
    mkdir -p "$nssdb" || return 1
    if [ ! -f "$nssdb/cert9.db" ]; then
        certutil -N -d "sql:$nssdb" --empty-password || true
    fi
    if certutil -A -d "sql:$nssdb" -t "C,," -n opencode-local-ca -i "$CA_OUT"; then
        log "chromium: trusted in $nssdb (relaunch the browser)"
    else
        log "WARN: Chromium NSS install failed"
    fi
}

print_other() {
    log "macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_OUT"
    log "Windows: certutil -addstore -user Root $CA_OUT"
    log "Android: Settings > Security > Encryption & credentials > Install a certificate > CA certificate"
    log "Chromium/Pages: allow local network access if prompted, or use Open live app."
}

main() {
    if [ -n "$CA_SRC" ]; then
        [ -f "$CA_SRC" ] || { log "FAIL: no CA at $CA_SRC"; return 1; }
        mkdir -p "$(dirname "$CA_OUT")" || return 1
        cp "$CA_SRC" "$CA_OUT" || return 1
    else
        download_ca || return 1
    fi
    if ! have openssl; then log "FAIL: openssl missing; cannot inspect CA"; return 1; fi
    openssl x509 -in "$CA_OUT" -noout -subject -fingerprint -sha256 || return 1
    if [ "$CHECK" -eq 1 ]; then
        verify_strict
        return $?
    fi
    install_system
    install_nss
    print_other
    verify_strict
    log "CA: $CA_OUT"
    log "verify: curl --cacert $CA_OUT $SERVER/api/rev"
    return 0
}

main "$@"
