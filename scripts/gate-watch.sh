#!/usr/bin/env bash
#
# gate-watch.sh — run a gate with a live log and heartbeat, not a deadline.
#
# It never kills the child on a timer. Instead it prints the last log line and
# elapsed seconds every HEARTBEAT, so a slow step is named by its own ms=/ts=
# line. The exit code is the child's exit code.
#
# Usage:
#   ./scripts/gate-watch.sh ./scripts/harness.sh --fast
#   LOG=/tmp/gate.log HEARTBEAT=5 ./scripts/gate-watch.sh ./scripts/harness.sh
#
# Exit: the child's status; 2 on usage.

SCRIPT_NAME="gate-watch.sh"
HEARTBEAT="${HEARTBEAT:-10}"
LOG="${LOG:-/tmp/gate-watch-$(date -u +%Y%m%dT%H%M%SZ).log}"
CMD=()

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--] COMMAND [ARGS...]"
  printf '%s\n' ""
  printf '%s\n' "  HEARTBEAT=N  seconds between log heartbeats (default $HEARTBEAT)"
  printf '%s\n' "  LOG=PATH     tee target (default $LOG)"
  printf '%s\n' "  No timer kills the child; the exit code is the child's."
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || die "a command is required"
  CMD=("$@")
  : > "$LOG" || die "cannot write $LOG"
  [ "$HEARTBEAT" -gt 0 ] 2>&1 || HEARTBEAT=10
  local start pid elapsed last rc
  start=$(date +%s)
  "${CMD[@]}" > >(tee -a "$LOG") 2>&1 &
  pid=$!
  log "gate-watch: pid=$pid log=$LOG heartbeat=${HEARTBEAT}s"
  while [ -e "/proc/$pid" ]; do
    sleep 1
    elapsed=$(( $(date +%s) - start ))
    if [ $((elapsed % HEARTBEAT)) -eq 0 ]; then
      last=$(tail -n 1 "$LOG" 2>&1)
      log "heartbeat elapsed=${elapsed}s last=${last}"
    fi
  done
  wait "$pid"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  log "gate-watch: rc=$rc elapsed=${elapsed}s log=$LOG"
  log "--- last 5 lines ---"
  tail -n 5 "$LOG"
  return "$rc"
}

main "$@"
exit $?
