#!/usr/bin/env bash
#
# host-cert-sign.sh - re-sign this host's SSH host certificate with a principal
# that matches the address clients actually use.
#
# 2026-11-10: connecting to the lighthouse as `owner@10.100.0.1` warned
#   Certificate invalid: name is not a listed principal
# because the host cert listed fedora, 100.70.43.78, 192.168.4.45 but not
# 10.100.0.1. Re-signing with the same mesh CA (in /etc/ssh/mesh-ca) adds the
# missing principal without moving the CA private key off this host.
#
#   ./scripts/host-cert-sign.sh --check      # list CA files + current principals
#   ./scripts/host-cert-sign.sh --sign       # back up, re-sign, restart sshd
#   ./scripts/host-cert-sign.sh --rollback   # restore the newest pre-rotate cert
#   ./scripts/host-cert-sign.sh --self-test  # offline temp CA + host key
#
# Principals default to: fedora,fedora.local,10.100.0.1,192.168.4.45,100.70.43.78
# Override with HOSTCERT_PRINCIPALS. The CA key never leaves the host.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

CA_DIR="${HOSTCERT_CA_DIR:-/etc/ssh/mesh-ca}"
HOST_PUB="${HOSTCERT_HOST_PUB:-/etc/ssh/ssh_host_ed25519_key.pub}"
CERT="${HOST_PUB%.pub}-cert.pub"
PRINCIPALS="${HOSTCERT_PRINCIPALS:-fedora,fedora.local,10.100.0.1,192.168.4.45,100.70.43.78}"
KEY_ID="${HOSTCERT_KEY_ID:-lighthouse-host-renew-$(date +%Y%m%d)}"
VALID="${HOSTCERT_VALID:--5m:+52w}"
CA_KEY="${HOSTCERT_CA_KEY:-}"
SELFTEST="${HOSTCERT_SELFTEST:-0}"

usage() {
    printf 'usage: %s [--check|--sign|--rollback|--self-test]\n' "$0"
    printf 'principals: %s\n' "$PRINCIPALS"
}

have() { command -v "$1" > /dev/null; }

log() { printf '%s\n' "$*"; }

find_ca_key() {
    [ -n "$CA_KEY" ] && { printf '%s' "$CA_KEY"; return 0; }
    [ -d "$CA_DIR" ] || return 1
    local f=""
    for f in "$CA_DIR"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.pub|*.README|*README*) continue ;; esac
        if ssh-keygen -y -f "$f" > /dev/null 2>&1; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

cert_principals() {
    [ -f "$CERT" ] || { printf '(no cert)'; return 0; }
    ssh-keygen -L -f "$CERT" 2>&1 | awk '
        /Principals:/{f=1; next}
        f && /^[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$/ {gsub(/^[[:space:]]+/,""); printf "%s ", $0; next}
        f{exit}
    '
}

do_check() {
    printf 'host pub   : %s\n' "$HOST_PUB"
    printf 'cert       : %s\n' "$CERT"
    printf 'CA dir     : %s\n' "$CA_DIR"
    if [ -d "$CA_DIR" ]; then
        printf 'CA files   :\n'
        ls -la "$CA_DIR" 2>&1 | awk '{print "  " $0}'
    else
        printf 'CA files   : (dir missing)\n'
    fi
    printf 'CA key     : %s\n' "$(find_ca_key 2>&1 || printf '(not found)')"
    printf 'principals : %s\n' "$(cert_principals)"
    return 0
}

do_sign() {
    local ca="" backup=""
    ca="$(find_ca_key 2>&1)" || { log "FAIL: CA private key not found in $CA_DIR"; return 2; }
    [ -f "$HOST_PUB" ] || { log "FAIL: host public key missing: $HOST_PUB"; return 2; }
    if [ -f "$CERT" ]; then
        backup="$CERT.pre-rotate-$(date -u +%Y%m%dT%H%M%SZ)"
        cp -a "$CERT" "$backup" || { log "FAIL: backup $CERT"; return 2; }
        log "backup: $backup"
    fi
    log "signing $HOST_PUB with CA $ca"
    log "key id=$KEY_ID principals=$PRINCIPALS valid=$VALID"
    if ! ssh-keygen -s "$ca" -I "$KEY_ID" -h -n "$PRINCIPALS" -V "$VALID" "$HOST_PUB"; then
        log "FAIL: ssh-keygen -s (encrypted CA key? run interactively)"
        return 2
    fi
    if [ "$SELFTEST" != "1" ] && have systemctl; then
        systemctl restart sshd 2>&1 || log "WARN: systemctl restart sshd"
    fi
    log "principals now: $(cert_principals)"
    return 0
}

do_rollback() {
    local latest=""
    latest="$(ls -1t "$CERT".pre-rotate-* 2>&1 | head -1)"
    case "$latest" in
        ''|*'No such'*) log "FAIL: no pre-rotate backup for $CERT"; return 2 ;;
    esac
    cp -a "$latest" "$CERT" || { log "FAIL: restore $latest"; return 2; }
    log "restored $CERT from $latest"
    if [ "$SELFTEST" != "1" ] && have systemctl; then
        systemctl restart sshd 2>&1 || log "WARN: systemctl restart sshd"
    fi
    log "principals now: $(cert_principals)"
    return 0
}

self_test() {
    local tmp fail=0
    tmp="$(mktemp -d)"
    CA_DIR="$tmp"
    HOST_PUB="$tmp/host.pub"
    CERT="$tmp/host-cert.pub"
    PRINCIPALS="fedora,10.100.0.1"
    SELFTEST=1
    ssh-keygen -q -t ed25519 -N '' -f "$tmp/ca" > /dev/null 2>&1 || { printf 'FAIL ca keygen\n'; return 1; }
    ssh-keygen -q -t ed25519 -N '' -f "$tmp/host" > /dev/null 2>&1 || { printf 'FAIL host keygen\n'; return 1; }
    do_sign > "$tmp/out.log" 2>&1 || { printf 'FAIL sign\n'; cat "$tmp/out.log"; fail=1; }
    [ -f "$CERT" ] || { printf 'FAIL cert missing\n'; fail=1; }
    ssh-keygen -L -f "$CERT" 2>&1 | grep -q '10.100.0.1' || { printf 'FAIL principal missing\n'; fail=1; }
    local b=""
    for b in "$CERT".pre-rotate-*; do
        [ -f "$b" ] && { printf 'note: backup present\n'; break; }
    done
    rm -f "$tmp/ca" "$tmp/ca.pub" "$tmp/host" "$tmp/host.pub" "$CERT" "$tmp/out.log"
    rmdir "$tmp" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'host-cert-sign: self-test PASS (temp CA + host key + principal)\n'
    else
        printf 'host-cert-sign: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    local action="check"
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) action="check"; shift ;;
            --sign) action="sign"; shift ;;
            --rollback) action="rollback"; shift ;;
            --self-test) self_test; return "$?" ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    if [ "$SELFTEST" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        if have sudo && sudo -n true 2>&1; then
            exec sudo -n "$0" "--$action"
        fi
        printf 'FAIL: root or passwordless sudo required\n'
        return 2
    fi
    case "$action" in
        check) do_check; return "$?" ;;
        sign) do_sign; return "$?" ;;
        rollback) do_rollback; return "$?" ;;
    esac
    usage >&2
    return 3
}

main "$@"
