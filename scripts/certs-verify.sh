#!/usr/bin/env bash
#
# certs-verify.sh — the TLS verification battery as code. Everything once
# typed by hand during the BAD_CERT_DOMAIN incident, now one command:
#
#   ./scripts/certs-verify.sh [--playwright]
#
# Checks (each prints PASS/FAIL, exit 0 only if all pass):
#   1. served fingerprint == file fingerprint (no impostor/mismatch)
#   2. SANs cover localhost, 127.0.0.1, this host's nebula IPv4
#   3. dates valid (notBefore <= now <= notAfter)
#   4. chain verifies against the local CA
#   5. curl --cacert (real verification, no -k) succeeds on :5099/:4096
#   6. --playwright: strict load fails with cert-authority error AND
#      bypass load renders (proves warning-class, not site breakage)
#
# Principle: if it can be typed, it MUST be scripted.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${CERT_DIR:-$REPO_DIR/docker/certs}"
CA_CRT="$CERT_DIR/ca.crt"
CRT="$CERT_DIR/opencode.crt"

FAIL=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

main() {
    local pw=0
    case "${1:-}" in
        --playwright) pw=1 ;;
        "") ;;
        *) printf 'usage: %s [--playwright]\n' "$0"; return 2 ;;
    esac

    if [ ! -f "$CRT" ]; then
        bad "no cert at $CRT (run docker/certs-init.sh)"
        return 1
    fi

    printf '== 1. served == file fingerprint ==\n'
    local f_file f_served
    f_file="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 2>&1)" || f_file=""
    f_served="$(printf '' | openssl s_client -connect 127.0.0.1:5099 -servername 10.100.0.24 2>&1 | openssl x509 -noout -fingerprint -sha256 2>&1)" || f_served=""
    if [ -n "$f_file" ] && [ "$f_file" = "$f_served" ]; then
        ok "fingerprints match"
        printf '  %s\n' "$f_file"
    else
        bad "mismatch (file: ${f_file:-?} served: ${f_served:-?})"
    fi

    printf '== 2. SAN coverage ==\n'
    local sans neb=""
    sans="$(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>&1)" || sans=""
    if command -v ip > /dev/null; then
        neb="$(ip -brief addr show nebula0 2>&1 | awk '{for (i=3; i<=NF; i++) {split($i,a,"/"); if (a[1] ~ /^10\./) print a[1]}}')" || neb=""
    fi
    local want="localhost 127.0.0.1 $neb" w hit=0 miss=0
    for w in $want; do
        [ -n "$w" ] || continue
        case "$sans" in *"$w"*) hit=$((hit + 1)) ;; *) miss=$((miss + 1)); bad "SAN missing: $w" ;; esac
    done
    [ "$miss" -eq 0 ] && ok "SANs cover localhost + 127.0.0.1 + nebula ($hit names)"

    printf '== 3. dates ==\n'
    if openssl x509 -in "$CRT" -noout -checkend 0 > /dev/null 2>&1; then
        ok "currently valid: $(openssl x509 -in "$CRT" -noout -dates 2>&1 | tr '\n' ' ')"
    else
        bad "expired or not yet valid"
    fi

    printf '== 4. chain vs local CA ==\n'
    if [ -f "$CA_CRT" ] && openssl verify -CAfile "$CA_CRT" "$CRT" > /dev/null 2>&1; then
        ok "server cert verifies against $CA_CRT"
    else
        bad "chain does not verify (legacy self-signed? run certs-init.sh to migrate)"
    fi

    printf '== 5. curl --cacert (full verification) ==\n'
    local code
    if [ -f "$CA_CRT" ]; then
        code="$(curl -s --cacert "$CA_CRT" --max-time 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:5099/api/rev 2>&1)" || code="000"
        [ "$code" = "200" ] && ok ":5099 verifies + 200" || bad ":5099 curl=$code"
        code="$(curl -s --cacert "$CA_CRT" --max-time 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:4096/ 2>&1)" || code="000"
        [ "$code" = "401" ] && ok ":4096 verifies + 401 (alive, authed)" || bad ":4096 curl=$code"
    else
        bad "no CA file; cannot verify without -k"
    fi

    if [ "$pw" -eq 1 ]; then
        printf '== 6. playwright ==\n'
        python3 - "$CERT_DIR" 2>&1 << 'PYEOF' || bad "playwright battery failed"
import sys
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    try:
        pg.goto('https://127.0.0.1:5099/', wait_until='domcontentloaded', timeout=15000)
        print('UNEXPECTED: strict load succeeded')
        sys.exit(3)
    except Exception as e:
        first = str(e).splitlines()[0][:100]
        assert 'CERT' in first or 'cert' in first or 'SSL' in first, first
        print('strict blocked on cert (expected):', first)
    pg.close()
    ctx = b.new_context(ignore_https_errors=True)
    pg2 = ctx.new_page()
    pg2.goto('https://127.0.0.1:5099/', wait_until='domcontentloaded', timeout=20000)
    pg2.wait_for_timeout(12000)
    rows = pg2.evaluate("document.querySelectorAll('#sessions tr[data-id]').length")
    loading = pg2.evaluate("document.querySelectorAll('[data-loading]').length")
    print('bypass rows=%s loading=%s' % (rows, loading))
    assert loading == 0 and rows > 0, 'page did not settle'
    b.close()
print('PLAYWRIGHT_OK')
PYEOF
    fi

    if [ "$FAIL" -eq 0 ]; then
        printf 'ALL CHECKS PASSED\n'
        return 0
    fi
    printf 'CHECKS FAILED\n'
    return 1
}

main "$@"
