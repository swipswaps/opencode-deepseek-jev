#!/usr/bin/env bash
#
# certs-trust.sh — trust the machine-local CA once, stop all warnings.
# Installs docker/certs/ca.crt (minted by certs-init.sh) into:
#   1. system trust (Fedora: /etc/pki/ca-trust/source/anchors + update-ca-trust)
#   2. every Firefox profile found (certutil, trust "C,,")
#   3. prints the Chrome/Chromium note (uses system trust: covered by 1)
#
# Idempotent: re-runs change nothing when the same CA is already trusted.
# Needs sudo for (1); (2) runs as the invoking user (never sudo -H here,
# so profiles resolve to YOUR $HOME, not root's).
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"
CA_CRT="$CERT_DIR/ca.crt"

main() {
    case "${1:-}" in
        "") ;;
        *) printf 'usage: %s (no arguments)\n' "$0"; return 2 ;;
    esac

    if [ ! -f "$CA_CRT" ]; then
        printf 'GATE FAIL: no CA at %s; run ./docker/certs-init.sh first\n' "$CA_CRT"
        return 1
    fi

    # Invoked via sudo: HOME is /root, but the browser profiles live in
    # the invoking user's home. Resolve that first, always.
    local sudo_run=""
    local target_home="$HOME"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        sudo_run="sudo -u ${SUDO_USER} -H"
        target_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)" || target_home="$HOME"
    fi
    local do_sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        do_sudo="sudo"
    fi

    printf '%s\n' '--- 1. system trust ---'
    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        if [ -n "$do_sudo" ] && ! sudo -n true 2>&1; then
            printf 'WARN: sudo needed for system trust; skipping (Firefox step still runs)\n'
            printf 'hint: sudo ./docker/certs-trust.sh (profiles still resolve to you)\n'
        else
            $do_sudo cp "$CA_CRT" /etc/pki/ca-trust/source/anchors/opencode-local-ca.crt || return 1
            $do_sudo update-ca-trust 2>&1 || return 1
            printf 'system trust: installed\n'
        fi
    else
        printf 'system trust: no Fedora anchor dir; skipping\n'
    fi

    printf '%s\n' '--- 2. firefox profiles ---'
    if ! command -v certutil > /dev/null; then
        printf 'certutil not found (nss-tools); Firefox step skipped\n'
        printf 'hint: sudo dnf install nss-tools, then re-run\n'
    else
        local prof n=0
        for prof in "$target_home"/.mozilla/firefox/*.default*; do
            [ -d "$prof" ] || continue
            if $sudo_run certutil -A -d "sql:$prof" -t "C,," -n opencode-local-ca -i "$CA_CRT" 2>&1; then
                printf 'firefox: trusted in %s\n' "$(basename "$prof")"
                n=$((n + 1))
            else
                printf 'WARN: certutil failed for %s\n' "$(basename "$prof")"
            fi
        done
        [ "$n" -gt 0 ] || printf 'firefox: no profiles found under %s/.mozilla/firefox\n' "$target_home"
    fi

    printf '%s\n' '--- 3. chrome/chromium ---'
    printf 'uses the system store: covered by step 1 (relaunch the browser)\n'
    printf 'verify: curl --cacert %s https://10.100.0.24:5099/api/rev\n' "$CA_CRT"
    return 0
}

main "$@"
