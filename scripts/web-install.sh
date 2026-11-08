#!/usr/bin/env bash
#
# web-install.sh - install the user-level opencode-web access-plane unit.
#
# Copies the repo's user units into ~/.config/systemd/user/ with the repo path
# baked in, then enables them:
#   opencode-web.service        runs scripts/web.sh at boot/login.
#   opencode-web-health.timer   runs scripts/web-health.sh every 2 minutes:
#                               rotates TLS SANs on a network change, probes
#                               loopback + Nebula/Tailscale/LAN, and re-runs
#                               web.sh once when a client path is down.
# Caddy publishes on the wildcard address, so a missing DHCP/tunnel IP can no
# longer abort the port bind; the watchdog covers changes while running.
#
#   ./scripts/web-install.sh              # install + enable + linger
#   ./scripts/web-install.sh --no-linger  # enable at login only
#   ./scripts/web-install.sh --uninstall  # remove the unit, keep containers
#   ./scripts/web-install.sh --write-only # bake units, no systemd contact
#   ./scripts/web-install.sh --self-test  # offline assertions
#
# Linger lets the user unit start at boot before login (needed for a headless
# or remotely-reached host). It is best-effort: without privilege to set it,
# the unit still starts at the first login.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null; }

self_test() {
    local fail=0 work="" real=""
    real=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    work=$(mktemp -d)
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/unit" bash "${BASH_SOURCE[0]}" --write-only > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/web.sh" "$work/unit/opencode-web.service" \
        || { printf 'FAIL ExecStart baked\n'; fail=1; }
    grep -q "Restart=on-failure" "$work/unit/opencode-web.service" \
        || { printf 'FAIL restart policy\n'; fail=1; }
    grep -q "Type=oneshot" "$work/unit/opencode-web.service" \
        || { printf 'FAIL unit type\n'; fail=1; }
    grep -q "ExecStart=$real/scripts/web-health.sh" "$work/unit/opencode-web-health.service" \
        || { printf 'FAIL health ExecStart baked\n'; fail=1; }
    grep -q "OnUnitActiveSec=2min" "$work/unit/opencode-web-health.timer" \
        || { printf 'FAIL watchdog timer interval\n'; fail=1; }
    rm -f "$work/unit/opencode-web.service" "$work/unit/opencode-web-health.service" \
        "$work/unit/opencode-web-health.timer"
    rmdir "$work/unit" "$work"
    if [ "$fail" -eq 0 ]; then printf 'web-install: self-test PASS\n'; else printf 'web-install: self-test FAIL\n'; fi
    return "$fail"
}

write_units() {
    local repo="$1"
    local dest="$2"
    local name src
    mkdir -p "$dest"
    for name in opencode-web.service opencode-web-health.service opencode-web-health.timer; do
        src="$repo/systemd/$name"
        if [ ! -f "$src" ]; then
            printf 'GATE FAIL: %s missing\n' "$src"
            return 1
        fi
        python3 - "$src" "$dest/$name" "$repo" << 'PYEOF'
import sys
src, dst, repo = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().replace("__REPO__", repo)
open(dst, "w").write(text)
PYEOF
    done
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if [ -n "${REPO_OVERRIDE:-}" ]; then REPO="$REPO_OVERRIDE"; fi
    # systemd ExecStart requires the execute bit; keep the checkout honest.
    chmod +x "$REPO/scripts/web.sh" "$REPO/scripts/web-health.sh" 2>&1 || true
    local DEST="${DEST_OVERRIDE:-$HOME/.config/systemd/user}"
    local linger=1 arg="${1:-}"
    case "$arg" in
        "") ;;
        --no-linger) linger=0 ;;
        --write-only)
            write_units "$REPO" "$DEST" || return 1
            printf 'unit written to %s\n' "$DEST"
            return 0
            ;;
        --uninstall)
            rm -f "$DEST/opencode-web.service" "$DEST/opencode-web-health.service" \
                "$DEST/opencode-web-health.timer"
            have systemctl && systemctl --user daemon-reload > /dev/null || true
            printf 'opencode-web units uninstalled (containers left running)\n'
            return 0
            ;;
        --self-test) self_test; return "$?" ;;
        -h | --help)
            printf 'usage: %s [--no-linger|--write-only|--uninstall|--self-test]\n' "$0"
            return 0
            ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac

    write_units "$REPO" "$DEST" || return 1
    if ! have systemctl; then
        printf 'unit written to %s; no systemctl here - enable manually where systemd runs\n' "$DEST"
        return 0
    fi
    systemctl --user daemon-reload || printf 'WARN: daemon-reload failed (run: systemctl --user daemon-reload)\n'
    if ! systemctl --user enable --now opencode-web.service; then
        printf 'FAIL: enable --now opencode-web.service failed\n'
        return 1
    fi
    if ! systemctl --user enable --now opencode-web-health.timer; then
        printf 'FAIL: enable --now opencode-web-health.timer failed\n'
        return 1
    fi
    # A oneshot with RemainAfterExit=yes stays "active (exited)" across an
    # upgrade, so enable --now alone would not re-run web.sh with the new
    # compose/ports. Restart it to apply the checkout now.
    if ! systemctl --user restart opencode-web.service; then
        printf 'FAIL: restart opencode-web.service failed\n'
        return 1
    fi
    if [ "$linger" -eq 1 ] && have loginctl; then
        if loginctl enable-linger "$USER"; then
            printf 'linger enabled for %s (unit starts at boot)\n' "$USER"
        else
            printf 'WARN: loginctl enable-linger failed; unit starts at first login\n'
        fi
    fi
    systemctl --user --no-pager status opencode-web.service | head -n 8
    systemctl --user list-timers opencode-web-health.timer --no-pager | head -n 3
    printf 'verify: bash scripts/diag-opencode-web.sh\n'
    printf 'watchdog: bash scripts/web-health.sh\n'
    return 0
}

main "$@"
