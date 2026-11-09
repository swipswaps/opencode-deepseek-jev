#!/usr/bin/env bash
#
# node-fix.sh - fixes for the non-opencode-deepseek-jev issues on the MacBook
# (.1). DRY-RUN BY DEFAULT: prints every command and writes nothing until you
# pass --apply. Pair it with node-diag.sh for the verbatim evidence.
#
#   ./scripts/node-fix.sh                 # show the plan (read-only)
#   ./scripts/node-fix.sh --apply         # execute the fixes
#   ./scripts/node-fix.sh --only getty    # one group: getty|mesh|dns|units
#   ./scripts/node-fix.sh --dns systemd   # DNS mode: tailscale (default)|systemd|none
#   ./scripts/node-fix.sh --self-test     # offline, temp fixture tree
#
# What it fixes (all unrelated to this repo):
#   getty  - disable+mask the failing serial-getty@ttyS0 (I/O-error storm).
#   mesh   - stop the mesh-recover restart loop: user timer, the NM dispatcher
#            hook, and the stale peer map .1 -> 10.100.0.2 (-> .24).
#   dns    - Tailscale DNS is disabled while resolv.conf points at
#            100.100.100.100: either enable accept-dns or restore resolved.
#   units  - reset-failed accounts-daemon/audit-rules/tor and restart accounts.
# It never edits this repo, nebula config, or the mesh config beyond the one
# peer-map line (backed up first).
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

APPLY=0
ONLY=""
DNS_MODE="${NODE_FIX_DNS:-tailscale}"
DO_PEER="${NODE_FIX_PEER:-1}"
ROOT="${FIX_ROOT:-}"
FIX_SYSTEM="${FIX_DRY_SYSTEM:-0}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${ROOT}/root/node-fix-${TS}"
DISPATCH="${ROOT}/etc/NetworkManager/dispatcher.d/50-mesh-recover"
MESH_SCRIPT="${MESH_RECOVER:-/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh/scripts/mesh-recover.sh}"
SERVICE="serial-getty@ttyS0"
ATTEMPTS="${NODE_FIX_ATTEMPTS:-2}"
FAILED=0

hr() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null; }
want() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }

run() {
    printf 'PLAN  %s\n' "$*"
    if [ "$APPLY" -eq 1 ] && [ "$FIX_SYSTEM" != "1" ]; then "$@"; fi
}
sudo_run() {
    printf 'PLAN  sudo %s\n' "$*"
    if [ "$APPLY" -eq 1 ] && [ "$FIX_SYSTEM" != "1" ]; then sudo "$@"; fi
}

move_to_backup() {
    local src="$1" dst="$BACKUP_DIR" name=""
    name="$(basename "$src")"
    if [ "$APPLY" -ne 1 ]; then
        printf 'PLAN  move %s -> %s/%s\n' "$src" "$dst" "$name"
        return 0
    fi
    if [ -n "$ROOT" ]; then
        mkdir -p "$dst" && mv "$src" "$dst/$name"
    else
        sudo mkdir -p "$dst" && sudo mv "$src" "$dst/$name"
    fi
}

restore_from_backup() {
    local name="$1" dst="$2"
    if [ ! -e "$BACKUP_DIR/$name" ] && [ ! -L "$BACKUP_DIR/$name" ]; then
        printf 'rollback: no backup %s/%s\n' "$BACKUP_DIR" "$name"
        return 0
    fi
    if [ -n "$ROOT" ]; then
        mv "$BACKUP_DIR/$name" "$dst"
    else
        sudo mv "$BACKUP_DIR/$name" "$dst"
    fi
}

verify_group() {
    local g="$1" en=""
    if [ "${NODE_FIX_FAKE_VERIFY_FAIL:-0}" = "1" ]; then return 1; fi
    if [ "$APPLY" -ne 1 ]; then return 0; fi
    # Self-test seam: no systemd; verify the file mutations only.
    if [ "$FIX_SYSTEM" = "1" ]; then
        case "$g" in
            mesh)
                [ ! -f "$DISPATCH" ] || return 1
                if [ -f "$MESH_SCRIPT" ] && grep -qE '10\.100\.0\.1\) PEER_OVL=10\.100\.0\.2([^0-9]|$)' "$MESH_SCRIPT" 2>&1; then
                    return 1
                fi
                ;;
        esac
        return 0
    fi
    case "$g" in
        getty)
            en="$(systemctl is-enabled "$SERVICE" 2>&1)"
            case "$en" in
                masked | masked-runtime) ;;
                *) return 1 ;;
            esac
            if systemctl is-active --quiet "$SERVICE" 2>&1; then return 1; fi
            ;;
        mesh)
            [ ! -f "$DISPATCH" ] || return 1
            if systemctl --user is-enabled mesh-recover.timer > /dev/null; then return 1; fi
            if [ -f "$MESH_SCRIPT" ] && grep -qE '10\.100\.0\.1\) PEER_OVL=10\.100\.0\.2([^0-9]|$)' "$MESH_SCRIPT" 2>&1; then
                return 1
            fi
            ;;
        dns)
            case "$DNS_MODE" in
                systemd)
                    if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>&1 | grep -q 'stub-resolv.conf'; then :; else return 1; fi
                    ;;
            esac
            ;;
        units)
            if systemctl is-failed --quiet accounts-daemon.service 2>&1; then return 1; fi
            ;;
    esac
    return 0
}

rollback_group() {
    local g="$1"
    [ "$APPLY" -eq 1 ] || { printf 'PLAN  rollback %s\n' "$g"; return 0; }
    printf 'ROLLBACK %s\n' "$g"
    case "$g" in
        getty)
            sudo_run systemctl unmask "$SERVICE"
            sudo_run systemctl enable --now "$SERVICE"
            ;;
        mesh)
            run systemctl --user enable --now mesh-recover.timer
            if [ -e "$BACKUP_DIR/50-mesh-recover" ] || [ -L "$BACKUP_DIR/50-mesh-recover" ]; then
                restore_from_backup 50-mesh-recover "$DISPATCH"
            fi
            if [ -f "$MESH_SCRIPT.bak.$TS" ]; then
                if [ -n "$ROOT" ]; then
                    cp "$MESH_SCRIPT.bak.$TS" "$MESH_SCRIPT"
                else
                    sudo cp "$MESH_SCRIPT.bak.$TS" "$MESH_SCRIPT"
                fi
            fi
            ;;
        dns)
            case "$DNS_MODE" in
                systemd)
                    if [ -e "$BACKUP_DIR/resolv.conf" ] || [ -L "$BACKUP_DIR/resolv.conf" ]; then
                        if [ -n "$ROOT" ]; then
                            unlink /etc/resolv.conf 2>&1 || true
                        else
                            sudo unlink /etc/resolv.conf 2>&1 || true
                        fi
                        restore_from_backup resolv.conf /etc/resolv.conf
                    fi
                    sudo_run systemctl restart systemd-resolved
                    ;;
            esac
            ;;
        units) : ;;
    esac
}

apply_checked() {
    local g="$1" fn="$2" attempt=0
    while [ "$attempt" -lt "$ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        "$fn"
        if verify_group "$g"; then
            [ "$attempt" -gt 1 ] && printf 'OK   %s verified on attempt %s\n' "$g" "$attempt"
            return 0
        fi
        if [ "$APPLY" -ne 1 ]; then return 0; fi
        printf 'WARN %s post-check failed (attempt %s/%s)\n' "$g" "$attempt" "$ATTEMPTS"
        [ "$attempt" -lt "$ATTEMPTS" ] && sleep $((attempt * 2))
    done
    printf 'FAIL %s did not converge after %s attempt(s); rolling back\n' "$g" "$ATTEMPTS"
    rollback_group "$g"
    FAILED=$((FAILED + 1))
    return 1
}

fix_getty() {
    hr 'getty: serial-getty@ttyS0 I/O-error storm'
    sudo_run systemctl disable --now "$SERVICE"
    sudo_run systemctl mask "$SERVICE"
    printf 'note: /dev/ttyS0 has no usable console here; masking stops the ~10s getty loop.\n'
}

fix_mesh() {
    hr 'mesh: stop the restart feedback loop'
    run systemctl --user disable --now mesh-recover.timer
    if [ -f "$DISPATCH" ]; then
        move_to_backup "$DISPATCH"
    else
        printf 'note: no %s (already removed)\n' "$DISPATCH"
    fi
    printf 'note: NetworkManager is NOT restarted here (it can drop SSH); the\n'
    printf '      hook is event-driven and is now inactive. Restart NM yourself if desired.\n'
    if [ "$DO_PEER" = "1" ]; then
        if [ ! -f "$MESH_SCRIPT" ]; then
            printf 'note: mesh script not found at %s; peer map unchanged\n' "$MESH_SCRIPT"
        elif grep -qE '10\.100\.0\.1\) PEER_OVL=10\.100\.0\.2([^0-9]|$)' "$MESH_SCRIPT" 2>&1; then
            printf 'PLAN  patch %s: .1 peer 10.100.0.2 -> 10.100.0.24 (backup first)\n' "$MESH_SCRIPT"
            if [ "$APPLY" -eq 1 ]; then
                cp "$MESH_SCRIPT" "$MESH_SCRIPT.bak.$TS" 2>&1 || printf 'WARN: backup failed\n'
                if have python3; then
                    python3 - "$MESH_SCRIPT" <<'PY'
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    s = fh.read()
s = s.replace("10.100.0.1) PEER_OVL=10.100.0.2", "10.100.0.1) PEER_OVL=10.100.0.24")
with open(p, "w", encoding="utf-8") as fh:
    fh.write(s)
PY
                else
                    printf 'WARN: python3 missing; patch manually\n'
                fi
            fi
        else
            printf 'note: peer map already fixed or not matching; no change\n'
        fi
    else
        printf 'note: --no-peer set; stale peer map left as-is\n'
    fi
}

fix_dns() {
    hr 'dns: Tailscale-owned resolv.conf with DNS disabled'
    case "$DNS_MODE" in
        tailscale)
            sudo_run tailscale set --accept-dns=true
            printf 'note: verify with: resolvectl query example.com\n'
            ;;
        systemd)
            sudo_run install -d "$BACKUP_DIR"
            if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
                move_to_backup /etc/resolv.conf
            fi
            sudo_run ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            sudo_run systemctl restart systemd-resolved
            printf 'note: verify with: resolvectl query example.com\n'
            ;;
        none) printf 'note: --dns none; unchanged\n' ;;
        *) printf 'FAIL: --dns must be tailscale|systemd|none\n'; return 2 ;;
    esac
}

fix_units() {
    hr 'units: reset failed units and restart accounts-daemon'
    sudo_run systemctl reset-failed accounts-daemon.service audit-rules.service tor.service
    sudo_run systemctl restart accounts-daemon.service
    printf 'note: haveged is masked by design; tor is left stopped unless you need it.\n'
}

info_nebula() {
    hr 'nebula: IPv4 listener vs IPv6 peer (informational, config lives in the mesh repo)'
    printf 'The lighthouse logs "Listener is IPv4, but writing to IPv6 remote" for\n'
    printf '10.100.0.24 because .24 advertises fde5:/202:/fd7a: underlays. Fix in\n'
    printf 'proxmox-dual-plane-mesh: bind nebula dual-stack (listen.host) or keep the\n'
    printf 'static host map IPv4-only. No change is made here.\n'
}

verify() {
    hr 'verify (run after --apply)'
    printf './scripts/node-diag.sh --section mesh --section nebula --section dns\n'
    printf 'journalctl -b 0 -u nebula --since "10 min ago" | grep -c "Caught signal"   # expect 0\n'
    printf 'systemctl --user list-timers --all | grep -c mesh-recover                 # expect 0\n'
    printf 'ip -4 route show 10.100.0.0/24 ; resolvectl query example.com\n'
    printf './scripts/overlay-status.sh\n'
}

self_test() {
    local fail=0 w="" out=""
    w="$(mktemp -d)"
    mkdir -p "$w/etc/NetworkManager/dispatcher.d"
    printf '#!/bin/bash\n' > "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover"
    printf '%s\n' \
        '  10.100.0.1) PEER_OVL=10.100.0.2; PEER_LAN_HINT=192.168.4.24 ;;' \
        '  10.100.0.2) PEER_OVL=10.100.0.1; PEER_LAN_HINT=192.168.4.45 ;;' \
        > "$w/mesh-recover.sh"

    out="$(FIX_ROOT="$w" FIX_DRY_SYSTEM=1 MESH_RECOVER="$w/mesh-recover.sh" bash "$0" --only mesh 2>&1)"
    [ "$?" -eq 0 ] || { printf 'FAIL dry-run rc\n'; fail=1; }
    printf '%s' "$out" | grep -q 'PLAN' || { printf 'FAIL dry-run plan\n'; fail=1; }
    [ -f "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover" ] || { printf 'FAIL dry-run moved hook\n'; fail=1; }
    grep -q 'PEER_OVL=10.100.0.2' "$w/mesh-recover.sh" || { printf 'FAIL dry-run patched peer\n'; fail=1; }

    FIX_ROOT="$w" FIX_DRY_SYSTEM=1 MESH_RECOVER="$w/mesh-recover.sh" bash "$0" --apply --only mesh > /dev/null 2>&1
    [ ! -f "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover" ] || { printf 'FAIL apply kept hook\n'; fail=1; }
    ls "$w"/root/node-fix-*/50-mesh-recover > /dev/null 2>&1 || { printf 'FAIL backup missing\n'; fail=1; }
    grep -q '10.100.0.1) PEER_OVL=10.100.0.24' "$w/mesh-recover.sh" || { printf 'FAIL peer patch\n'; fail=1; }
    grep -q '10.100.0.2) PEER_OVL=10.100.0.1' "$w/mesh-recover.sh" || { printf 'FAIL reverse map clobbered\n'; fail=1; }

    FIX_ROOT="$w" FIX_DRY_SYSTEM=1 MESH_RECOVER="$w/mesh-recover.sh" bash "$0" --apply --only mesh > /dev/null 2>&1
    n="$(grep -c 'PEER_OVL=10.100.0.24' "$w/mesh-recover.sh")"
    [ "$n" -eq 1 ] || { printf 'FAIL not idempotent (%s)\n' "$n"; fail=1; }

    # bounded retry + rollback: force the post-check to fail; the hook and peer
    # map must be restored and the run must exit non-zero.
    printf '#!/bin/bash\n' > "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover"
    printf '%s\n' '  10.100.0.1) PEER_OVL=10.100.0.2; PEER_LAN_HINT=192.168.4.24 ;;' > "$w/mesh-recover.sh"
    NODE_FIX_FAKE_VERIFY_FAIL=1 NODE_FIX_ATTEMPTS=1 FIX_ROOT="$w" FIX_DRY_SYSTEM=1 MESH_RECOVER="$w/mesh-recover.sh" \
        bash "$0" --apply --only mesh > /dev/null
    rc=$?
    [ "$rc" -ne 0 ] || { printf 'FAIL rollback rc\n'; fail=1; }
    [ -f "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover" ] || { printf 'FAIL rollback hook\n'; fail=1; }
    grep -q '10.100.0.1) PEER_OVL=10.100.0.2' "$w/mesh-recover.sh" || { printf 'FAIL rollback peer\n'; fail=1; }

    bash "$0" --bogus > /dev/null 2>&1
    [ "$?" -eq 2 ] || { printf 'FAIL unknown arg\n'; fail=1; }

    rm -f "$w/mesh-recover.sh" "$w"/mesh-recover.sh.bak.*
    rm -f "$w/etc/NetworkManager/dispatcher.d/50-mesh-recover"
    rm -f "$w"/root/node-fix-*/* 2>&1
    rmdir "$w"/root/node-fix-* "$w"/root "$w"/etc/NetworkManager/dispatcher.d "$w"/etc/NetworkManager "$w"/etc "$w" 2>&1 || true
    if [ "$fail" -eq 0 ]; then printf 'node-fix: self-test PASS (dry-run + apply + backup + idempotent + post-check + rollback)\n'; else printf 'node-fix: self-test FAIL\n'; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--apply] [--only getty|mesh|dns|units] [--dns tailscale|systemd|none] [--no-peer] [--self-test]\n' "$0"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=1; shift ;;
            --only) ONLY="${ONLY:+$ONLY,}${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --dns) DNS_MODE="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --no-peer) DO_PEER=0; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
    done

    case "$DNS_MODE" in tailscale | systemd | none) ;; *) printf 'FAIL: --dns must be tailscale|systemd|none\n'; return 2 ;; esac

    printf '=== node-fix @ %s  mode=%s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([ "$APPLY" -eq 1 ] && printf apply || printf dry-run)"
    want getty && apply_checked getty fix_getty
    want mesh && apply_checked mesh fix_mesh
    want dns && apply_checked dns fix_dns
    want units && apply_checked units fix_units
    info_nebula
    verify
    if [ "$APPLY" -ne 1 ]; then
        printf '\nNo changes made. Re-run with --apply to execute the PLAN lines.\n'
    fi
    if [ "$FAILED" -gt 0 ]; then
        printf '\nFAIL: %s group(s) rolled back after the bounded retry budget.\n' "$FAILED"
        return 1
    fi
    return 0
}

main "$@"
