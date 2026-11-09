#!/usr/bin/env bash
#
# nebula-ipv4-only.sh - stop the "Listener is IPv4, but writing to IPv6 remote"
# error (and its IPv6 preference side effects) on an IPv4-only Nebula listener.
#
# Nebula reports ALL underlay addresses (IPv4 and IPv6) to the lighthouse. A
# node bound to 0.0.0.0 then tries to handshake IPv6 remotes and logs the error
# (slackhq/nebula#1227). The supported fix for an IPv4-only listener is:
#
#   lighthouse:
#     local_allow_list:
#       "0.0.0.0/0": true    # announce only IPv4
#     remote_allow_list:
#       "0.0.0.0/0": true    # handshake only IPv4
#
# Usage (run as root / sudo on the node):
#   sudo ./scripts/nebula-ipv4-only.sh --check
#   sudo ./scripts/nebula-ipv4-only.sh --apply
#   sudo ./scripts/nebula-ipv4-only.sh --dual-stack   # listen.host "::" instead
#   ./scripts/nebula-ipv4-only.sh --self-test         # offline fixture
#
# --apply backs up config.yml, validates the candidate with `nebula -config
# ... -test`, installs it, restarts nebula, and reports the error count and
# tunnel reachability. --dual-stack is the other supported option (bind both
# families) and is mutually exclusive with the allow lists.
#
# Env: NEBULA_CONF, NEBULA_NO_RESTART=1, NEBULA_SKIP_TEST=1 (self-test).
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

CONF="${NEBULA_CONF:-/etc/nebula/config.yml}"
MODE="check"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

have() { command -v "$1" >/dev/null; }
is_root() { [ "$(id -u)" -eq 0 ]; }

show_check() {
    printf 'config: %s\n' "$CONF"
    if [ ! -r "$CONF" ]; then
        printf 'cannot read %s (run with sudo)\n' "$CONF"
        return 2
    fi
    printf '\n-- listen / allow lists / host map --\n'
    grep -nE '^[[:space:]]*(listen:|host:|port:|local_allow_list:|remote_allow_list:|static_host_map:|10\.100\.0\.1:)' "$CONF" 2>&1
    printf '\n-- IPv4/IPv6 error count (last 30m) --\n'
    if have journalctl; then
        journalctl -u nebula --since '-30 min' --no-pager 2>&1 | grep -c 'Listener is IPv4, but writing to IPv6 remote'
    fi
    printf '\n-- underlay reachability of 10.100.0.24 --\n'
    if have ping; then ping -c 2 -W 2 10.100.0.24 2>&1 | tail -1; fi
    return 0
}

# Insert the IPv4-only allow lists under the top-level `lighthouse:` key.
ensure_ipv4_allow_lists() {
    local src="$1" dst="$2"
    if ! have python3; then printf 'FAIL: python3 required\n'; return 1; fi
    python3 - "$src" "$dst" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    text = fh.read()
if "local_allow_list" in text and "remote_allow_list" in text:
    print("already: allow lists present")
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(text)
    sys.exit(0)
lines = text.splitlines()
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.strip() == "lighthouse:":
        out.append('  local_allow_list:')
        out.append('    "0.0.0.0/0": true')
        out.append('  remote_allow_list:')
        out.append('    "0.0.0.0/0": true')
        inserted = True
if not inserted:
    print("FAIL: no top-level 'lighthouse:' key")
    sys.exit(1)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
print("added: IPv4-only local_allow_list + remote_allow_list")
PY
}

ensure_dual_stack() {
    local src="$1" dst="$2"
    if ! have python3; then printf 'FAIL: python3 required\n'; return 1; fi
    python3 - "$src" "$dst" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    text = fh.read()
lines = text.splitlines()
out = []
in_listen = False
changed = False
for line in lines:
    stripped = line.strip()
    if stripped == "listen:":
        in_listen = True
        out.append(line)
        continue
    if in_listen and stripped.startswith("host:"):
        out.append('  host: "::"')
        changed = True
        in_listen = False
        continue
    out.append(line)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
print("listen.host -> \"::\"" if changed else "FAIL: listen.host not found")
sys.exit(0 if changed else 1)
PY
}

validate() {
    local f="$1"
    [ "${NEBULA_SKIP_TEST:-0}" = "1" ] && { printf 'skip: nebula -test\n'; return 0; }
    have nebula || { printf 'WARN: nebula binary not found; skipping -test\n'; return 0; }
    nebula -config "$f" -test > /dev/null 2>&1
}

apply_mode() {
    local which="$1" tmp=""
    if ! is_root; then
        printf 'FAIL: --apply needs root. Re-run: sudo %s %s\n' "$0" "$2"
        return 2
    fi
    [ -r "$CONF" ] || { printf 'FAIL: cannot read %s\n' "$CONF"; return 2; }
    tmp="${CONF}.candidate.$$"
    case "$which" in
        ipv4) ensure_ipv4_allow_lists "$CONF" "$tmp" || { rm -f "$tmp"; return 1; } ;;
        dual) ensure_dual_stack "$CONF" "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
    if ! validate "$tmp"; then
        printf 'FAIL: nebula -test rejected the candidate; live config untouched\n'
        printf 'candidate: %s\n' "$tmp"
        return 1
    fi
    if cmp -s "$CONF" "$tmp"; then
        printf 'unchanged %s\n' "$CONF"
        rm -f "$tmp"
        return 0
    fi
    cp "$CONF" "${CONF}.bak.$STAMP" || { printf 'FAIL: backup failed\n'; return 1; }
    install -m 644 -o root -g root "$tmp" "$CONF" || { printf 'FAIL: install failed\n'; return 1; }
    rm -f "$tmp"
    printf 'wrote %s (backup %s.bak.%s)\n' "$CONF" "$CONF" "$STAMP"
    printf 'note: restart nebula and (ideally) the OTHER nodes so their caches drop IPv6\n'
    if [ "${NEBULA_NO_RESTART:-0}" = "1" ]; then
        printf 'skip: restart (NEBULA_NO_RESTART=1)\n'
    elif have systemctl; then
        systemctl restart nebula && printf 'restarted nebula\n'
        sleep 10
        show_check
    fi
}

self_test() {
    local fail=0 w="" o="" o2=""
    w="$(mktemp)"
    o="$(mktemp)"
    o2="$(mktemp)"
    printf '%s\n' 'pki:' '  ca: /etc/nebula/ca.crt' 'lighthouse:' '  am_lighthouse: true' '  interval: 10' 'listen:' '  host: 0.0.0.0' '  port: 4242' > "$w"
    ensure_ipv4_allow_lists "$w" "$o" > /dev/null || { printf 'FAIL transform\n'; fail=1; }
    grep -q 'local_allow_list' "$o" || { printf 'FAIL local list\n'; fail=1; }
    grep -q 'remote_allow_list' "$o" || { printf 'FAIL remote list\n'; fail=1; }
    grep -q 'am_lighthouse: true' "$o" || { printf 'FAIL clobbered lighthouse\n'; fail=1; }
    ensure_ipv4_allow_lists "$o" "$o2" > /dev/null || { printf 'FAIL second pass\n'; fail=1; }
    [ "$(grep -c 'local_allow_list' "$o2")" -eq 1 ] || { printf 'FAIL not idempotent\n'; fail=1; }
    rm -f "$w" "$o" "$o2"
    if [ "$fail" -eq 0 ]; then printf 'nebula-ipv4-only: self-test PASS (insert allow lists, idempotent)\n'; else printf 'nebula-ipv4-only: self-test FAIL\n'; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--check|--apply|--dual-stack|--self-test]\n' "$0"
}

main() {
    case "${1:-}" in
        --check | '') show_check; return "$?" ;;
        --apply) apply_mode ipv4 --apply ;;
        --dual-stack) apply_mode dual --dual-stack ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
    esac
}

main "$@"
