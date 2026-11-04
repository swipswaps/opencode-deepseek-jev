#!/usr/bin/env bash
#
# repro-a1286.sh - orchestrate repeated A1286/MacBookPro network failure repro
# from a control host. Read-only against the target.
#
# Requires on the target: ssh key accepted, passwordless sudo for the audit,
# audit executable.
#
# Usage (on .24):
#   ./repro-a1286.sh
#   TARGET=owner@192.168.4.45 TRIALS=2 DURATION=180 ./repro-a1286.sh
#
set -uo pipefail

TARGET="${TARGET:-owner@192.168.4.45}"
DURATION="${DURATION:-180}"
TRIALS="${TRIALS:-1}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="${OUTDIR:-/tmp/a1286-repro-$STAMP}"
AUDIT_REL="${AUDIT_REL:-Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/scripts/audit-a1286-network.sh}"
LOG="$OUTDIR/repro.log"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

REMOTE_HOME=""
AUDIT_PATH=""

have() { command -v "$1" >/dev/null 2>&1; }

log() {
    local line
    line=$(printf '[%s] %s' "$(date -u +%H:%M:%SZ)" "$*")
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG"
}

ssh_target() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
ssh_ok()     { ssh_target true >/dev/null 2>&1; }
ssh_sudo_ok(){ ssh_target "sudo -n ${1:-'true'}" >/dev/null 2>&1; }

prompt_enter() {
    local msg="$1"
    printf '%s\n' "$msg"
    if [ -t 0 ]; then
        read -r _
    else
        printf '(non-interactive; continuing in 10s)\n'
        sleep 10
    fi
}

preflight() {
    have ssh || { log "ssh missing"; return 1; }
    have scp || { log "scp missing"; return 1; }
    ssh_ok || {
        log "cannot ssh to $TARGET non-interactively; run: ssh-copy-id $TARGET"
        return 1
    }
    REMOTE_HOME=$(ssh_target 'printf %s "$HOME"') || {
        log "cannot read target \$HOME"
        return 1
    }
    AUDIT_PATH="$REMOTE_HOME/$AUDIT_REL"
    ssh_target "test -x '$AUDIT_PATH'" || {
        log "audit not found/executable at $TARGET:$AUDIT_PATH"
        return 1
    }
    ssh_sudo_ok "$AUDIT_PATH" || {
        log "target sudo -n cannot run $AUDIT_PATH; check /etc/sudoers.d/a1286-audit on target"
        return 1
    }
    log "preflight OK target=$TARGET audit=$AUDIT_PATH home=$REMOTE_HOME"
    return 0
}

target_healthy() {
    local out
    out=$(ssh_target 'ip -4 route show default; echo ---; ip route get 1.1.1.1' 2>&1) || return 1
    printf '%s\n' "$out" | grep -q '^default via' || return 1
    printf '%s\n' "$out" | grep -q 'unreachable' && return 1
    return 0
}

wait_for_healthy() {
    local limit="${1:-300}" t=0
    while [ "$t" -lt "$limit" ]; do
        if ssh_ok && target_healthy; then return 0; fi
        sleep 10
        t=$((t+10))
    done
    return 1
}

prompt_ready() {
    local n="$1"
    printf '\n'
    printf '========== TRIAL %d/%d  %s ==========\n' "$n" "$TRIALS" "$(date -u +%H:%M:%SZ)"
    printf 'Target: %s\n' "$TARGET"
    printf 'Watch:  %ss\n' "$DURATION"
    printf 'Out:    %s\n' "$OUTDIR"
    printf 'Remote: %s/a1286-trial-%d-%s*\n' "$REMOTE_HOME" "$n" "$STAMP"
    printf '\nON THE TARGET MacBook, DURING THE WATCH WINDOW:\n'
    printf '  1. log out of XFCE\n'
    printf '  2. log back in\n'
    printf '  3. run:  ping -c 1 1.1.1.1\n'
    printf '  4. note the message and whether login succeeded\n'
    printf '\nDo NOT reboot. Do NOT restart NetworkManager. Do NOT nmcli up.\n'
    printf 'If the machine becomes unreachable, that is the signal we want.\n\n'
    prompt_enter 'Press ENTER for a 10-second countdown, then switch to the target.'
    local i=10
    while [ "$i" -gt 0 ]; do
        printf '  %2ds...\n' "$i"
        sleep 1
        i=$((i-1))
    done
}

wait_for_remote_end() {
    local n="$1" remote_out="$2"
    local limit=$(( DURATION + 300 )) t=0
    while [ "$t" -lt "$limit" ]; do
        if ssh_target "grep -q 'END a1286-net-audit' '$remote_out'" >/dev/null 2>&1; then
            log "trial $n: remote sentinel detected after ${t}s"
            return 0
        fi
        if ! ssh_ok; then
            log "trial $n: target unreachable at ${t}s (positive signal)"
        fi
        sleep 5
        t=$((t+5))
    done
    log "trial $n: timeout waiting for remote sentinel at ${t}s"
    return 1
}

scp_pull() {
    local remote="$1" dest="$2" tries=5 t=0
    while [ "$t" -lt "$tries" ]; do
        if scp -q "${SSH_OPTS[@]}" "$TARGET:$remote" "$dest" 2>/dev/null; then
            return 0
        fi
        t=$((t+1))
        sleep 15
    done
    return 1
}

classify() {
    local n="$1" base_local="$2" sig=0
    local report="$base_local"
    local wj="$base_local.watch.journal"
    local nmw="$base_local.watch.nmcli"

    log "trial $n: classification"
    if [ -f "$report" ]; then
        if grep -qE '\[HIGH\] (DRIVER|WIFI) ' "$report"; then
            log "  [HIGH] driver/wifi"
            grep -nE '\[HIGH\] (DRIVER|WIFI) ' "$report" | head -n 6 | while IFS= read -r l; do log "    $l"; done
            sig=1
        fi
        if grep -qE '\[HIGH\] L3 ' "$report"; then
            log "  [HIGH] L3 (route/unreachable)"
            grep -nE '\[HIGH\] L3 ' "$report" | head -n 4 | while IFS= read -r l; do log "    $l"; done
            sig=1
        fi
        if grep -qE '\[HIGH\] SESSION ' "$report"; then
            log "  [HIGH] SESSION (accounts-daemon/lightdm)"
            grep -nE '\[HIGH\] SESSION ' "$report" | head -n 4 | while IFS= read -r l; do log "    $l"; done
            sig=1
        fi
        grep -qE 'Power save: on'  "$report" && log "  NOTE: power save ON in captured state"
        grep -qE 'Power save: off' "$report" && log "  power save OFF in captured state"
    else
        log "  no report file at $report"
    fi

    if [ -f "$wj" ] && grep -qE 'CTRL-EVENT-DISCONNECTED|state change: .* -> deactivated|b43-phy0: Loading firmware|BEACON-LOSS' "$wj"; then
        log "  watch journal has disconnect/reload signature"
        grep -nE 'CTRL-EVENT-DISCONNECTED|state change: .* -> deactivated|b43-phy0: Loading firmware|BEACON-LOSS' "$wj" | head -n 8 | while IFS= read -r l; do log "    $l"; done
        sig=1
    fi
    if [ -f "$nmw" ]; then
        log "  nmcli watch tail"
        tail -n 10 "$nmw" | while IFS= read -r l; do log "    $l"; done
    fi

    if [ "$sig" -eq 1 ]; then
        log "trial $n: RESULT = FAILURE CAPTURED"
    else
        log "trial $n: RESULT = no failure signature (healthy or missed)"
    fi
}

run_trial() {
    local n="$1"
    local remote="$REMOTE_HOME/a1286-trial-$n-$STAMP"
    local local_base="$OUTDIR/a1286-trial-$n-$STAMP"

    prompt_ready "$n"

    log "trial $n: launching audit detached on target"
    if ! ssh_target "sudo -n setsid -f '$AUDIT_PATH' --watch $DURATION --out '$remote' >/dev/null 2>&1"; then
        log "trial $n: launch ssh returned non-zero (continuing; .raw check below)"
    fi

    sleep 5
    if ! ssh_target "test -e '$remote.raw'"; then
        log "trial $n: $remote.raw not present 5s after launch; audit likely did not start"
        return 1
    fi

    log "trial $n: watch running; log out/in on the target now"
    wait_for_remote_end "$n" "$remote"

    log "trial $n: pulling artifacts"
    scp_pull "$remote"                    "$OUTDIR/" || log "  scp report failed"
    scp_pull "$remote.watch.journal"      "$OUTDIR/" || log "  scp watch.journal failed"
    scp_pull "$remote.watch.nmcli"        "$OUTDIR/" || log "  scp watch.nmcli failed"
    scp_pull "$remote.watch.iw"           "$OUTDIR/" || log "  scp watch.iw failed"
    scp_pull "$remote.watch.dbus"         "$OUTDIR/" || log "  scp watch.dbus failed"
    scp_pull "$remote.raw"                "$OUTDIR/" || log "  scp raw failed"
    scp_pull "$remote.raw.journal-boot0"  "$OUTDIR/" || true
    scp_pull "$remote.raw.journal-boot-1" "$OUTDIR/" || true

    classify "$n" "$local_base"
}

main() {
    mkdir -p "$OUTDIR" || { printf 'cannot mkdir %s\n' "$OUTDIR"; return 1; }
    log "repro-a1286 starting"
    log "  target=$TARGET duration=${DURATION}s trials=$TRIALS"
    log "  outdir=$OUTDIR audit_rel=$AUDIT_REL"

    preflight || return 1
    wait_for_healthy 60 || {
        log "target is not healthy; reboot it, confirm ping, re-run"
        return 1
    }
    log "target healthy"

    local i=1
    while [ "$i" -le "$TRIALS" ]; do
        run_trial "$i"
        i=$((i+1))
        if [ "$i" -le "$TRIALS" ]; then
            prompt_enter "Before the next trial, ensure the target is healthy again (reboot if needed), then press ENTER."
            wait_for_healthy 300 || {
                log "target did not become healthy; stopping remaining trials"
                break
            }
        fi
    done

    log "done"
    log "artifacts in $OUTDIR:"
    ls -la "$OUTDIR" | while IFS= read -r l; do log "  $l"; done
    return 0
}

main "$@"
