#!/usr/bin/env bash
#
# key-request-install.sh — host-side applier for keys entered in /app/#settings.
#
# The dashboard (container) cannot write the host's .env.local, so it writes a
# mode-0600 request at data/observability/key-request.json. This installs a
# systemd USER path unit that runs:
#
#   python3 scripts/rotate-guided.py --action apply-request --restart
#
# on every change: it validates the key, writes .env.local atomically (0600,
# backup), deletes the request, and restarts opencode-web so the new env is
# loaded. No sudo; the units live under ~/.config/systemd/user.
#
#   ./scripts/key-request-install.sh              # install + enable (default)
#   ./scripts/key-request-install.sh --status
#   ./scripts/key-request-install.sh --print
#   ./scripts/key-request-install.sh --uninstall
#
# Values are never printed. Exit 0 ok, 1 failure, 2 usage.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
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

usage() {
    printf 'usage: %s [--install|--status|--print|--uninstall|--help]\n' "$0"
    printf '  --install    write + enable the user path unit (default)\n'
    printf '  --status     show enabled/active state\n'
    printf '  --print      print the unit files\n'
    printf '  --uninstall  disable + remove the unit files\n'
}

service_text() {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Apply a provider key queued from opencode /app settings'
    printf '%s\n' 'After=default.target'
    printf '%s\n' ''
    printf '%s\n' '[Service]'
    printf '%s\n' 'Type=oneshot'
    printf 'WorkingDirectory=%s\n' "$REPO"
    printf 'ExecStart=/usr/bin/python3 %s/scripts/rotate-guided.py --action apply-request --restart\n' "$REPO"
    printf '%s\n' 'TimeoutStartSec=240'
}

path_text() {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Watch for an in-app queued provider key'
    printf '%s\n' ''
    printf '%s\n' '[Path]'
    printf 'PathChanged=%s/data/observability/key-request.json\n' "$REPO"
    printf '%s\n' 'Unit=opencode-key-apply.service'
    printf '%s\n' ''
    printf '%s\n' '[Install]'
    printf '%s\n' 'WantedBy=default.target'
}

have_systemctl() {
    command -v systemctl > /dev/null || return 1
    systemctl --user show-environment > /dev/null
}

main() {
    local action="install"
    case "${1:-}" in
        --install) action="install" ;;
        --status) action="status" ;;
        --print) action="print" ;;
        --uninstall) action="uninstall" ;;
        -h | --help) usage; return 0 ;;
        "") action="install" ;;
        *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
    esac

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo root\n'
        return 2
    fi
    local unit_dir="$HOME/.config/systemd/user"
    local svc="$unit_dir/opencode-key-apply.service"
    local path="$unit_dir/opencode-key-apply.path"

    printf '=== key-request-install ===\n'
    printf 'repo: %s\n' "$REPO"
    printf 'units: %s\n' "$unit_dir"

    case "$action" in
        print)
            printf '\n--- %s ---\n' "$svc"
            service_text
            printf '\n--- %s ---\n' "$path"
            path_text
            return 0
            ;;
        status)
            if ! have_systemctl; then
                printf 'WARN: systemd --user is not reachable in this shell\n'
                printf '  run from the desktop session (XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS set)\n'
                return 1
            fi
            printf 'enabled: %s\n' "$(systemctl --user is-enabled opencode-key-apply.path 2>&1)"
            printf 'active:  %s\n' "$(systemctl --user is-active opencode-key-apply.path 2>&1)"
            printf 'last:    %s\n' "$(systemctl --user show opencode-key-apply.service -p Result --value 2>&1)"
            return 0
            ;;
        uninstall)
            if have_systemctl; then
                systemctl --user disable --now opencode-key-apply.path 2>&1 || true
            fi
            rm -f "$path" "$svc"
            if have_systemctl; then
                systemctl --user daemon-reload 2>&1 || true
            fi
            printf 'removed the user path unit\n'
            return 0
            ;;
        install)
            mkdir -p "$unit_dir" || { printf 'FAIL: cannot create %s\n' "$unit_dir"; return 1; }
            service_text > "$svc"
            path_text > "$path"
            if ! have_systemctl; then
                printf 'WARN: systemd --user is not reachable in this shell; units written but not enabled\n'
                printf '  run from the desktop session: systemctl --user enable --now opencode-key-apply.path\n'
                return 1
            fi
            systemctl --user daemon-reload || { printf 'FAIL: daemon-reload\n'; return 1; }
            systemctl --user enable --now opencode-key-apply.path || { printf 'FAIL: enable path unit\n'; return 1; }
            printf 'installed: %s\n' "$path"
            printf 'active:    %s\n' "$(systemctl --user is-active opencode-key-apply.path 2>&1)"
            printf 'flow: /app/#settings Set key -> host applies .env.local -> restarts opencode-web\n'
            return 0
            ;;
    esac
    return 0
}

main "$@"
