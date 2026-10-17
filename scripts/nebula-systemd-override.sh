#!/usr/bin/env bash
#
# nebula-systemd-override.sh — rate-limit + right-size the nebula service (host).
#
# NEBULA-1: nebula-restart-trace.py proved systemd (PID 1) is the restarter, so
# nebula is crash-looping under systemd and needs a start-limit + resource
# ceiling — not a hunt for another supervisor. This writes the systemd drop-in
# idempotently; dry-run by default, every change is opt-in.
#
#   bash scripts/nebula-systemd-override.sh                 # dry-run: show plan
#   sudo bash scripts/nebula-systemd-override.sh --apply    # write + daemon-reload
#   sudo bash scripts/nebula-systemd-override.sh --revert   # remove + daemon-reload
#   bash scripts/nebula-systemd-override.sh --show          # current unit limits
#   sudo bash scripts/nebula-systemd-override.sh --apply --restart   # also restart now
#   bash scripts/nebula-systemd-override.sh --file "$t" --apply --no-reload  # seam
#   bash scripts/nebula-systemd-override.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No kill.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

UNIT="nebula.service"
DEF_DROPIN="/etc/systemd/system/$UNIT.d/override.conf"

# The drop-in alone: a bounded start-limit (so a crash-loop cannot fork-bomb)
# plus a resource ceiling so a runaway nebula cannot starve this host's work.
override_body() {
    printf '%s\n' \
        '# Managed by scripts/nebula-systemd-override.sh (NEBULA-1); do not hand-edit.' \
        '[Unit]' \
        'StartLimitIntervalSec=300' \
        'StartLimitBurst=5' \
        '' \
        '[Service]' \
        'CPUWeight=50' \
        'IOWeight=50' \
        'MemoryMax=512M' \
        'LogRateLimitIntervalSec=10' \
        'LogRateLimitBurst=100'
}

install_file() {
    local dest="$1" tmp
    tmp=$(mktemp) || { printf 'FAIL: mktemp\n'; return 1; }
    override_body >"$tmp" || { rm -f "$tmp"; return 1; }
    if mkdir -p "$(dirname "$dest")" && cp "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    if have sudo; then
        printf 'need root; using sudo\n'
        if sudo mkdir -p "$(dirname "$dest")" && sudo cp "$tmp" "$dest"; then
            rm -f "$tmp"
            return 0
        fi
    fi
    rm -f "$tmp"
    printf 'FAIL: cannot write %s (re-run with sudo)\n' "$dest"
    return 1
}

remove_file() {
    local dest="$1"
    if [ ! -e "$dest" ]; then
        printf 'nothing to revert (%s absent)\n' "$dest"
        return 0
    fi
    if rm -f "$dest"; then
        :
    elif have sudo; then
        sudo rm -f "$dest" || { printf 'FAIL: cannot remove %s\n' "$dest"; return 1; }
    else
        printf 'FAIL: cannot remove %s (re-run with sudo)\n' "$dest"
        return 1
    fi
    rmdir "$(dirname "$dest")" || printf '(note: drop-in dir not empty; left in place)\n'
    return 0
}

reload_unit() {
    if have systemctl; then
        printf 'systemctl daemon-reload\n'
        systemctl daemon-reload || printf 'WARN: daemon-reload failed\n'
    else
        printf '(systemctl not available here; run daemon-reload on the host)\n'
    fi
}

show_state() {
    if have systemctl; then
        systemctl show "$UNIT" -p CPUWeight -p IOWeight -p MemoryMax \
            -p StartLimitIntervalUSec -p StartLimitBurst -p LogRateLimitBurst \
            -p NRestarts 2>&1
    else
        printf 'systemctl not available here (host only)\n'
    fi
    printf '%s\n' '--- recent unit log (exit/restart reason) ---'
    if have journalctl; then
        journalctl -u "$UNIT" -n 15 --no-pager 2>&1
    else
        printf 'journalctl not available here\n'
    fi
}

self_test() {
    local w dest fail=0 out n
    w=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    dest="$w/etc/systemd/system/$UNIT.d/override.conf"
    bash "${BASH_SOURCE[0]}" --file "$dest" --apply --no-reload >"$w/a1" 2>&1 || { printf 'FAIL: apply\n'; cat "$w/a1"; return 1; }
    [ -f "$dest" ] || { printf 'FAIL: drop-in not written\n'; fail=1; }
    grep -q 'StartLimitBurst=5' "$dest" || { printf 'FAIL: no StartLimitBurst\n'; fail=1; }
    grep -q 'CPUWeight=50' "$dest" || { printf 'FAIL: no CPUWeight\n'; fail=1; }
    grep -q '^\[Unit\]' "$dest" || { printf 'FAIL: missing [Unit] section (StartLimit lives there)\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" --file "$dest" --apply --no-reload 2>&1)
    case "$out" in *unchanged*) : ;; *) printf 'FAIL: not idempotent (%s)\n' "$out"; fail=1 ;; esac
    n=$(grep -c 'CPUWeight=50' "$dest")
    [ "$n" -eq 1 ] || { printf 'FAIL: duplicated body (count=%s)\n' "$n"; fail=1; }
    bash "${BASH_SOURCE[0]}" --file "$dest" --revert --no-reload >"$w/r1" 2>&1 || { printf 'FAIL: revert\n'; fail=1; }
    [ ! -e "$dest" ] || { printf 'FAIL: revert left the drop-in\n'; fail=1; }
    printf 'nebula-systemd-override: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local DROPIN="$DEF_DROPIN" APPLY=0 REVERT=0 SHOW=0 RESTART=0 NO_RELOAD=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) DROPIN="${2:-}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --revert) REVERT=1; shift ;;
            --show) SHOW=1; shift ;;
            --restart) RESTART=1; shift ;;
            --no-reload) NO_RELOAD=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help)
                printf 'usage: %s [--file DROPIN] [--apply|--revert|--show] [--restart] [--no-reload] [--self-test]\n' "$0"
                return 0
                ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done

    if [ "$SHOW" -eq 1 ]; then show_state; return $?; fi

    if [ "$REVERT" -eq 1 ]; then
        remove_file "$DROPIN" || return 1
        [ "$NO_RELOAD" -eq 1 ] || reload_unit
        return 0
    fi

    printf 'unit:   %s\n' "$UNIT"
    printf 'drop-in: %s\n' "$DROPIN"
    printf '%s\n' '--- proposed override ---'
    override_body
    printf '%s\n' '-------------------------'

    if [ "$APPLY" -eq 0 ]; then
        printf 'dry-run; re-run with --apply (sudo) to write + daemon-reload\n'
        return 0
    fi

    if [ -f "$DROPIN" ] && diff -q <(override_body) "$DROPIN" >/dev/null 2>&1; then
        printf 'unchanged: %s already current\n' "$DROPIN"
    else
        install_file "$DROPIN" || return 1
        printf 'wrote %s\n' "$DROPIN"
    fi
    [ "$NO_RELOAD" -eq 1 ] || reload_unit
    if [ "$RESTART" -eq 1 ]; then
        if have systemctl; then
            printf 'systemctl restart %s (disruptive)\n' "$UNIT"
            systemctl restart "$UNIT" || printf 'WARN: restart failed\n'
        else
            printf '(systemctl not available here; restart on the host)\n'
        fi
    fi
    return 0
}

main "$@"
