#!/usr/bin/env bash
#
# repro-full-a1286.sh - full cycle: launch audit --watch, trigger XFCE logout,
# detect login, ping at each stage, pull artifacts. Run from the CONTROL host
# (.24), not from .45.
#
# Constraints honoured: no sed, no 2>/dev/null, no set -e, no exit 1
# (only exit 0 / exit 2), no subprocess.run.
#
set -uo pipefail

TARGET="${TARGET:-owner@192.168.4.45}"
TARGET_HOME="${TARGET_HOME:-/home/owner}"
AUDIT_REL="${AUDIT_REL:-Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/scripts/audit-a1286-network.sh}"
AUDIT_PATH="$TARGET_HOME/$AUDIT_REL"
DURATION="${DURATION:-600}"
LOGOUT_TIMEOUT="${LOGOUT_TIMEOUT:-60}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-300}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="${OUTDIR:-/tmp/a1286-repro-full-$STAMP}"
REMOTE_OUT="$TARGET_HOME/a1286-trial-$STAMP"
REMOTE_PING="$TARGET_HOME/a1286-ping-$STAMP.log"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

mkdir -p "$OUTDIR" || { printf 'cannot mkdir %s\n' "$OUTDIR"; exit 2; }
LOG="$OUTDIR/repro.log"

log() {
    local line
    line=$(printf '[%s] %s' "$(date -u +%H:%M:%SZ)" "$*")
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG"
}
die() { log "FATAL: $*"; exit 2; }

ssh_t()  { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
scp_t()  { scp -q "${SSH_OPTS[@]}" "$TARGET:$1" "$2"; }
ssh_up() { ssh_t true >/dev/null; }

# ------------------------------------------------------------------ preflight
log "repro-full starting"
log "  target=$TARGET"
log "  audit=$AUDIT_PATH"
log "  duration=${DURATION}s logout_timeout=${LOGOUT_TIMEOUT}s login_timeout=${LOGIN_TIMEOUT}s"
log "  out=$OUTDIR"

ssh_up || die "cannot ssh to $TARGET"
ssh_t "test -x $AUDIT_PATH" >/dev/null || die "audit not executable: $AUDIT_PATH"
ssh_t 'sudo -n true' >/dev/null || die "sudo -n fails on $TARGET"
ssh_t 'ip -4 route show default' | grep -q '^default via' || die "target has no default route; reboot and re-run"
ssh_t 'ip route get 1.1.1.1' | grep -q 'unreachable' && die "target route to 1.1.1.1 is unreachable; reboot and re-run"
log "preflight OK"

# ------------------------------------------------------------- helper scripts
cat > "$OUTDIR/trigger-logout.sh" <<'EOS'
#!/bin/bash
# Trigger XFCE logout via the running X session's D-Bus bus.
uid=$(id -u)
xid=$(pgrep -u "$uid" -x xfce4-session | head -1)
if [ -z "$xid" ]; then echo "no-xfce4-session"; exit 2; fi
bus=$(tr '\0' '\n' < "/proc/$xid/environ" | grep -a '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2-)
dpy=$(tr '\0' '\n' < "/proc/$xid/environ" | grep -a '^DISPLAY=' | cut -d= -f2-)
if [ -z "$bus" ]; then echo "no-session-bus"; exit 2; fi
if command -v xfce4-session-logout >/dev/null; then
    DBUS_SESSION_BUS_ADDRESS="$bus" DISPLAY="$dpy" xfce4-session-logout --logout --fast
    echo "sent-xfce4-session-logout"
elif command -v dbus-send >/dev/null; then
    DBUS_SESSION_BUS_ADDRESS="$bus" DISPLAY="$dpy" dbus-send --session --type=method_call \
      --dest=org.xfce.SessionManager /org/xfce/SessionManager \
      org.xfce.Session.Manager.Logout uint32:0 boolean:false
    echo "sent-dbus"
else
    echo "no-logout-method"; exit 2
fi
EOS

cat > "$OUTDIR/start-ping-logger.sh" <<'EOS'
#!/bin/bash
# Continuous ping + route sampler. Detached; survives SSH disconnect.
out="$1"
tag=$(basename "$out")
nohup bash -c '
  while true; do
    ts=$(date -Is)
    ping_result=$(ping -c 1 -W 1 1.1.1.1 2>&1 | tail -1)
    route_result=$(ip route get 1.1.1.1 2>&1 | head -1)
    default_route=$(ip -4 route show default 2>&1 | head -1)
    printf "%s ping=%s route=%s default=%s\n" "$ts" "$ping_result" "$route_result" "$default_route"
    sleep 2
  done
' "$tag" > "$out" 2>&1 &
echo "$!"
EOS

scp -q "${SSH_OPTS[@]}" "$OUTDIR/trigger-logout.sh"    "$TARGET:/tmp/trigger-logout.sh"    || die "scp trigger-logout failed"
scp -q "${SSH_OPTS[@]}" "$OUTDIR/start-ping-logger.sh" "$TARGET:/tmp/start-ping-logger.sh" || die "scp start-ping-logger failed"
log "helper scripts uploaded"

# -------------------------------------------------------------- launch audit
log "launching audit detached: --watch $DURATION --out $REMOTE_OUT"
ssh_t "sudo -n setsid -f $AUDIT_PATH --watch $DURATION --out $REMOTE_OUT >/dev/null 2>&1" || die "audit launch ssh failed"
sleep 5
ssh_t "test -e $REMOTE_OUT.raw" >/dev/null || die "audit did not start (no $REMOTE_OUT.raw after 5s)"
log "audit launched"

# --------------------------------------------------------- launch ping logger
log "launching ping logger -> $REMOTE_PING"
ssh_t "bash /tmp/start-ping-logger.sh $REMOTE_PING" >/dev/null || log "ping logger launch returned non-zero (continuing)"
sleep 2
ssh_t "test -s $REMOTE_PING" >/dev/null || log "ping logger not yet populated (continuing)"

# --------------------------------------------------------------- trigger logout
log "triggering logout"
ssh_t 'bash /tmp/trigger-logout.sh' || log "trigger-logout returned non-zero"

log "waiting for xfce4-session to exit (max ${LOGOUT_TIMEOUT}s)"
died=0; i=0
while [ "$i" -lt "$LOGOUT_TIMEOUT" ]; do
    if ssh_up; then
        if ! ssh_t 'pgrep -x xfce4-session' >/dev/null; then died=1; break; fi
    else
        died=1; log "  ssh unreachable at ${i}s -- likely the failure itself"; break
    fi
    sleep 1; i=$((i+1))
done
if [ "$died" -eq 1 ]; then
    log "logout observed at ~${i}s"
else
    log "logout NOT observed within ${LOGOUT_TIMEOUT}s; falling back to loginctl terminate-session"
    sid=$(ssh_t "loginctl list-sessions --no-legend" | awk -v u="$(id -un)" '$3==u && $4=="seat0" {print $1; exit}')
    if [ -n "$sid" ]; then
        ssh_t "loginctl terminate-session $sid" || true
        sleep 5
        if ssh_up && ! ssh_t 'pgrep -x xfce4-session' >/dev/null; then
            died=1; log "logout forced via loginctl session $sid"
        fi
    fi
fi

# ------------------------------------------- immediate post-logout ping probe
if ssh_up; then
    log "post-logout ping over ssh (from .45):"
    out=$(ssh_t 'ping -c 1 -W 2 1.1.1.1' 2>&1) || true
    log "  $out"
    out=$(ssh_t 'ip route get 1.1.1.1' 2>&1) || true
    log "  route: $out"
else
    log "SSH UNREACHABLE post-logout -- network failure reproduced"
fi

# ------------------------------------------------------------- wait for login
log "waiting for xfce4-session to reappear (max ${LOGIN_TIMEOUT}s)"
logged_in=0; i=0
while [ "$i" -lt "$LOGIN_TIMEOUT" ]; do
    if ssh_up && ssh_t 'pgrep -x xfce4-session' >/dev/null; then logged_in=1; break; fi
    if [ $((i % 20)) -eq 0 ] && [ "$i" -gt 0 ]; then log "  ${i}s elapsed"; fi
    sleep 1; i=$((i+1))
done
if [ "$logged_in" -eq 1 ]; then
    log "login observed at ~${i}s"
else
    log "LOGIN DID NOT COMPLETE within ${LOGIN_TIMEOUT}s -- login-failure bug reproduced"
fi

# ------------------------------------------------------------ post-login state
if ssh_up; then
    log "post-login ping (from .45):"
    out=$(ssh_t 'ping -c 2 -W 2 1.1.1.1' 2>&1) || true
    log "  $out"
    out=$(ssh_t 'ip -4 route show default; ip route get 1.1.1.1; nmcli -f DEVICE,STATE device status' 2>&1) || true
    log "  state: $out"
fi

# ---------------------------------------------------------- wait for audit end
log "waiting for audit sentinel (max $((DURATION + 180))s)"
deadline=$((DURATION + 180)); i=0
while [ "$i" -lt "$deadline" ]; do
    if ssh_up && ssh_t "grep -q 'END a1286-net-audit' $REMOTE_OUT" >/dev/null; then
        log "audit sentinel seen at ~${i}s"; break
    fi
    if [ $((i % 30)) -eq 0 ] && [ "$i" -gt 0 ]; then log "  ${i}s elapsed waiting for audit"; fi
    sleep 2; i=$((i+2))
done

# ---------------------------------------------------------- stop ping sampler
ssh_up && ssh_t "pkill -f 'a1286-ping-$STAMP.log' >/dev/null" >/dev/null || true

# ------------------------------------------------------------ pull artifacts
log "pulling artifacts"
pull_one() {
    local remote="$1" base tries=0
    base=$(basename "$remote")
    while [ "$tries" -lt 30 ]; do
        if scp_t "$remote" "$OUTDIR/$base"; then log "  pulled $base"; return 0; fi
        tries=$((tries+1))
        if [ "$tries" -eq 10 ] || [ "$tries" -eq 20 ]; then
            log "  retry $base attempt $tries (if network on .45 is down, reboot .45 to recover)"
        fi
        sleep 10
    done
    log "  FAILED to pull $base after 30 attempts"
    return 1
}

pull_one "$REMOTE_OUT"
pull_one "$REMOTE_OUT.watch.journal"
pull_one "$REMOTE_OUT.watch.nmcli"
pull_one "$REMOTE_OUT.watch.iw"
pull_one "$REMOTE_OUT.watch.dbus"
pull_one "$REMOTE_OUT.raw"
pull_one "$REMOTE_OUT.raw.journal-boot0"
pull_one "$REMOTE_OUT.raw.journal-boot-1"
pull_one "$REMOTE_PING"

# ---------------------------------------------------------------- summary
log "=== ANALYSIS ==="
log "logout_observed=$died login_observed=$logged_in"
report="$OUTDIR/$(basename "$REMOTE_OUT")"
if [ -f "$report" ]; then
    log "HIGH findings:"
    grep -n '^\[HIGH\] ' "$report" | head -20 | while IFS= read -r l; do log "  $l"; done
    log "VERDICT:"
    grep '^VERDICT' "$report" | while IFS= read -r l; do log "  $l"; done
fi
plog="$OUTDIR/$(basename "$REMOTE_PING")"
if [ -f "$plog" ]; then
    log "ping transitions (first 'Network is unreachable' or '0 received'):"
    grep -nE 'Network is unreachable|0 received' "$plog" | head -5 | while IFS= read -r l; do log "  $l"; done
fi

log "artifacts in $OUTDIR"
ls -la "$OUTDIR" | while IFS= read -r l; do log "  $l"; done

exit 0
