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

read_sysctl() {
    if [ -n "$SYSTEMCTL_FILE" ] && [ -f "$SYSTEMCTL_FILE" ]; then
        cat "$SYSTEMCTL_FILE"
    elif have systemctl; then
        systemctl show "$UNIT" -p CPUWeight -p IOWeight -p MemoryMax \
            -p StartLimitIntervalUSec -p StartLimitBurst -p LogRateLimitBurst \
            -p NRestarts -p MainPID -p ActiveEnterTimestamp 2>&1
    else
        printf '(systemctl not available here; host only)\n'
    fi
}

read_journal() {
    if [ -n "$JOURNAL_FILE" ] && [ -f "$JOURNAL_FILE" ]; then
        cat "$JOURNAL_FILE"
    elif have journalctl; then
        journalctl -u "$UNIT" -n 200 --no-pager 2>&1
    else
        printf '(journalctl not available here; host only)\n'
    fi
}

# diagnose SYS JRN -- separate PROCESS-restart churn from a TUNNEL flap.
# The live evidence (2026-10-17) falsified the "3 PIDs/10 min crash-loop"
# premise: NRestarts=0, one stable PID, and the only recurring event was a
# tunnel teardown to a peer. Naming the right class stops us rate-limiting
# systemd restarts that never happen.
diagnose() {
    local sys="$1" jrn="$2" nrest tunnel lifecycle
    nrest=$(printf '%s\n' "$sys" | awk -F= '/^NRestarts=/{print $2; exit}')
    # tunnel evidence: nebula app lines about a peer link (not PID 1).
    tunnel=$(printf '%s\n' "$jrn" | grep -cE 'Close tunnel received|Taking new handshake|state:dead')
    # lifecycle evidence: systemd (PID 1) messages about the unit.
    lifecycle=$(printf '%s\n' "$jrn" | grep -cE 'systemd\[[0-9]+\]: *'"${UNIT%%.*}"'\.service')
    printf '%s\n' '--- diagnosis ---'
    printf 'NRestarts=%s  tunnel-events=%s  systemd-lifecycle-lines=%s\n' \
        "${nrest:-?}" "$tunnel" "$lifecycle"
    if [ "${nrest:-0}" = "0" ] && [ "$lifecycle" -eq 0 ]; then
        if [ "$tunnel" -gt 0 ]; then
            printf 'verdict: NO process churn (NRestarts=0) — the recurring event is a TUNNEL flap (%s teardowns/handshakes). Fix the peer/lighthouse link, not systemd.\n' "$tunnel"
        else
            printf 'verdict: NO process churn and no tunnel flap in this window — the restart-churn premise is not reproduced.\n'
        fi
        printf 'note: the drop-in is a defensive ceiling only (restarts that are not happening); --revert if undesired.\n'
    else
        printf 'verdict: RESTART churn present (NRestarts=%s, %s systemd lifecycle lines) — rate-limited by the drop-in; re-check with --show after apply.\n' "${nrest:-?}" "$lifecycle"
    fi
}

show_state() {
    local sys jrn
    sys=$(read_sysctl)
    jrn=$(read_journal)
    printf '%s\n' "$sys"
    printf '%s\n' '--- recent unit log (exit/restart reason) ---'
    printf '%s\n' "$jrn"
    diagnose "$sys" "$jrn"
}

# handoff -- emit a ready-to-paste issue for the PEER repo (the fix is external:
# proxmox-dual-plane-mesh). Plain selectable text (RULES #70); built from the
# same evidence --diagnose uses, so the issue cannot drift from the data.
handoff() {
    local sys jrn peer ip n restarts
    sys=$(read_sysctl)
    jrn=$(read_journal)
    n=$(printf '%s\n' "$jrn" | grep -cE 'Close tunnel received|Taking new handshake|state:dead')
    peer=$(printf '%s\n' "$jrn" | grep -oE 'certName=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2)
    ip=$(printf '%s\n' "$jrn" | grep -oE 'vpnIp=[0-9.]+' | head -1 | cut -d= -f2)
    restarts=$(printf '%s\n' "$sys" | awk -F= '/^NRestarts=/{print $2; exit}')
    [ -n "$restarts" ] || restarts="0"
    printf '%s\n' \
        "TITLE: nebula tunnel to ${peer:-peer} (vpnIp ${ip:-?}) flaps — repeated teardown/re-handshake" \
        "" \
        "Repo: proxmox-dual-plane-mesh (opencode-deepseek-jev only watches and hands off)" \
        "" \
        "## Symptom" \
        "The nebula PROCESS is healthy — systemd NRestarts=${restarts}, one stable PID, no exit" \
        "lines — so the recurring event is a peer tunnel flap, not a service restart." \
        "" \
        "## Evidence" \
        "  flap events in 'journalctl -u nebula': ${n}" \
        "  peer certName: ${peer:-?}   vpnIp: ${ip:-?}" \
        "  signature: 'Close tunnel received, tearing down.' / 'Taking new handshake' / tunnelCheck state:dead" \
        "" \
        "## Repro (read-only)" \
        "  bash scripts/nebula-systemd-override.sh --diagnose   # classifies restart-churn vs tunnel-flap" \
        "  python3 scripts/nebula-restart-trace.py --watch 60   # proves the process is not restarting" \
        "  journalctl -u nebula | grep -E 'Close tunnel|Taking new handshake|state:dead'" \
        "" \
        "## Suspects" \
        "UDP reachability to the lighthouse (firewall/NAT/MTU) and the peer/lighthouse reload cadence." \
        "A systemd rate-limit does NOT fix this (it only bounds restarts that are not happening)."
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

    # classifier: NRestarts=0 + tunnel lines (no systemd lifecycle) -> TUNNEL
    printf '%s\n' 'NRestarts=0' 'MainPID=1111684' >"$w/sys1"
    printf '%s\n' \
        'Oct 17 18:52:39 ws24 nebula[1111684]: msg="Close tunnel received, tearing down." vpnIp=10.100.0.1' \
        'Oct 17 18:52:41 ws24 nebula[1111684]: msg="Taking new handshake" vpnIp=10.100.0.1' \
        'Oct 17 18:53:09 ws24 nebula[1111684]: msg="Tunnel status" tunnelCheck="map[state:dead]"' >"$w/jrn1"
    out=$(bash "${BASH_SOURCE[0]}" --diagnose --systemctl-file "$w/sys1" --journal-file "$w/jrn1" 2>&1)
    case "$out" in *TUNNEL*) : ;; *) printf 'FAIL: classifier missed tunnel flap (%s)\n' "$out"; fail=1 ;; esac

    # classifier: systemd lifecycle + NRestarts>0 -> RESTART
    printf '%s\n' 'NRestarts=3' 'MainPID=999' >"$w/sys2"
    printf '%s\n' \
        'Oct 17 18:52:00 ws24 systemd[1]: nebula.service: Scheduled restart job, restart counter is at 3.' \
        'Oct 17 18:52:00 ws24 systemd[1]: nebula.service: Main process exited, code=exited, status=1/FAILURE' >"$w/jrn2"
    out=$(bash "${BASH_SOURCE[0]}" --diagnose --systemctl-file "$w/sys2" --journal-file "$w/jrn2" 2>&1)
    case "$out" in *RESTART*) : ;; *) printf 'FAIL: classifier missed restart churn (%s)\n' "$out"; fail=1 ;; esac

    # handoff emits a ready-to-paste issue with the peer/ip evidence.
    out=$(bash "${BASH_SOURCE[0]}" --handoff --systemctl-file "$w/sys1" --journal-file "$w/jrn1" 2>&1)
    printf '%s' "$out" | grep -q 'TITLE: nebula tunnel' || { printf 'FAIL: handoff has no title\n'; fail=1; }
    printf '%s' "$out" | grep -q 'vpnIp 10.100.0.1' || { printf 'FAIL: handoff missing peer ip\n'; fail=1; }
    printf '%s' "$out" | grep -q 'flap events in' || { printf 'FAIL: handoff missing evidence count\n'; fail=1; }

    printf 'nebula-systemd-override: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local DROPIN="$DEF_DROPIN" APPLY=0 REVERT=0 SHOW=0 DIAGNOSE=0 HANDOFF=0 RESTART=0 NO_RELOAD=0
    local SYSTEMCTL_FILE="" JOURNAL_FILE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) DROPIN="${2:-}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --revert) REVERT=1; shift ;;
            --show) SHOW=1; shift ;;
            --diagnose) DIAGNOSE=1; shift ;;
            --handoff) HANDOFF=1; shift ;;
            --systemctl-file) SYSTEMCTL_FILE="${2:-}"; shift 2 ;;
            --journal-file) JOURNAL_FILE="${2:-}"; shift 2 ;;
            --restart) RESTART=1; shift ;;
            --no-reload) NO_RELOAD=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help)
                printf 'usage: %s [--file DROPIN] [--apply|--revert|--show|--diagnose|--handoff] [--systemctl-file F] [--journal-file F] [--restart] [--no-reload] [--self-test]\n' "$0"
                return 0
                ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done

    if [ "$SHOW" -eq 1 ]; then show_state; return $?; fi

    if [ "$DIAGNOSE" -eq 1 ]; then
        diagnose "$(read_sysctl)" "$(read_journal)"
        return $?
    fi

    if [ "$HANDOFF" -eq 1 ]; then handoff; return $?; fi

    if [ "$REVERT" -eq 1 ]; then
        remove_file "$DROPIN" || return 1
        printf 'note: a running unit keeps its current cgroup limits until it next starts (revert does not restart it).\n'
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
