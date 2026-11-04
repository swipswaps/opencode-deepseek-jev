#!/usr/bin/env bash
#
# dashboard-restart.sh — restart the :5099 dashboard with full segments.
#
# RUN ON THE HOST. The dashboard runs inside opencode-deepseek-web as a
# background node process. This finds it via /proc (not pgrep; the image lacks
# it), excludes itself, TERMs it, starts the new code with
# DASH_SEGMENTS=cost,activity,todos, and proves the first SSE snapshot carries
# activity and todos.
#
# Usage:
#   ./scripts/dashboard-restart.sh
#   ./scripts/dashboard-restart.sh --status
#   ./scripts/dashboard-restart.sh --dry-run
#   PORT=5099 ./scripts/dashboard-restart.sh
#
# Exit 0 verified, 1 failed, 2 usage/docker error.

SCRIPT_NAME="dashboard-restart.sh"
C="${C:-opencode-deepseek-web}"
PORT="${PORT:-5099}"
DB="/home/node/.local/share/opencode/opencode.db"
AUDIT="/workspace/scripts/audit-config.sh"
MJS="/workspace/scripts/dashboard.mjs"
LOG="${LOG:-/tmp/dashboard.log}"
MODE="apply"
PORT_BOUND="${PORT_BOUND:-15}"
START_BOUND="${START_BOUND:-30}"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--apply|--status|--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --apply    restart the dashboard and verify the snapshot (default)"
  printf '%s\n' "  --status   read-only: process list + /api/resources + snapshot shape"
  printf '%s\n' "  --dry-run  print the plan"
  printf '%s\n' ""
  printf '%s\n' "  C=$C PORT=$PORT LOG=$LOG"
  printf '%s\n' "  PORT_BOUND=${PORT_BOUND}s START_BOUND=${START_BOUND}s (dashboard start measured ~18s)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) MODE="apply" ;;
      --status) MODE="status" ;;
      --dry-run) MODE="dry-run" ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

dashboard_pids() {
  docker exec -i "$C" sh -s <<'IN'
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  c=$(tr '\000' ' ' < "$p/cmdline")
  case "$c" in *node*dashboard.mjs*) echo "$pid" ;; esac
done
IN
}

snapshot_check() {
  python3 - "$PORT" <<'PY'
import http.client, json, ssl, sys, time
port = int(sys.argv[1])
ctx = ssl._create_unverified_context()
for _ in range(20):
    try:
        c = http.client.HTTPSConnection("127.0.0.1", port, timeout=5, context=ctx)
        c.request("GET", "/api/stream")
        r = c.getresponse()
        lines = []
        while True:
            line = r.readline()
            if not line:
                break
            lines.append(line)
            if line in (b"\n", b"\r\n") and lines:
                break
        for line in lines:
            if line.startswith(b"data: "):
                d = json.loads(line[6:])
                a, t = d.get("activity"), d.get("todos")
                if isinstance(a, list) and isinstance(t, list):
                    print("activity=%d todos=%d shed=%s" % (len(a), len(t), d.get("shed")))
                    sys.exit(0)
        time.sleep(1)
    except Exception:
        time.sleep(1)
print("dashboard snapshot missing activity/todos")
sys.exit(1)
PY
}

resources_check() {
  curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/api/resources" 2>&1
}

container_resources() {
  docker exec "$C" curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/resources" 2>&1
}

status() {
  log "=== dashboard status ==="
  docker top "$C" 2>&1 | grep 'dashboard.mjs' | head -3 || log "  no dashboard process"
  printf 'host resources (caddy): %s\n' "$(resources_check)"
  printf 'container resources: %s\n' "$(container_resources)"
  snapshot_check
}

apply() {
  have docker || die "docker missing (host-only)"
  local pids
  pids=$(dashboard_pids)
  if [ -z "$pids" ]; then
    log "no running dashboard; starting a new one"
  else
    log "stopping dashboard pid(s): $(printf '%s ' $pids)"
    for pid in $pids; do docker exec "$C" sh -c "kill $pid" || fail "kill $pid"; done
    local i=0
    while [ "$i" -lt 10 ]; do
      [ -z "$(dashboard_pids)" ] && break
      i=$((i + 1)); sleep 1
    done
    [ -z "$(dashboard_pids)" ] || { fail "dashboard did not stop"; return 1; }
    pass "dashboard stopped"
  fi
  local i=0 code=""
  while [ "$i" -lt "$PORT_BOUND" ]; do
    code=$(container_resources)
    printf '  port sample=%s elapsed=%ss container=%s bound=%ss\n' "$((i + 1))" "$i" "${code:-unknown}" "$PORT_BOUND"
    [ "$code" = "000" ] && break
    i=$((i + 1)); sleep 1
  done
  [ "$code" = "000" ] || { fail "container port $PORT still in use after ${PORT_BOUND}s (last=$code)"; return 1; }
  pass "container port $PORT free at ${i}s"
  docker exec -d "$C" sh -c "DASH_SEGMENTS=cost,activity,todos DASH_SSE_MS=30000 DASH_AUTO_SHED=1 exec node --no-warnings --experimental-sqlite $MJS $DB $PORT 0.0.0.0 $AUDIT >>$LOG 2>&1" \
    || die "could not start the dashboard"
  i=0
  while [ "$i" -lt "$START_BOUND" ]; do
    code=$(container_resources)
    printf '  start sample=%s elapsed=%ss container=%s bound=%ss\n' "$((i + 1))" "$i" "${code:-unknown}" "$START_BOUND"
    if [ "$code" = "200" ] && snapshot_check >/dev/null 2>&1; then
      snapshot_check
      pass "snapshot carries activity and todos at ${i}s"
      log "refresh the page; if CPU PSI > 30 the activity card says 'paused'"
      return 0
    fi
    i=$((i + 1)); sleep 1
  done
  fail "dashboard did not reach /api/resources=200 with activity/todos after ${START_BOUND}s; see $LOG"
  docker exec "$C" tail -20 "$LOG" 2>&1 || true
  return 1
}

main() {
  parse_args "$@"
  case "$MODE" in
    status) status; return $? ;;
    dry-run)
      printf '[dry-run] stop dashboard pids in %s, start %s with full segments on :%s, verify SSE\n' "$C" "$MJS" "$PORT"
      ;;
    apply) apply ;;
  esac
}

main "$@"
exit $?
