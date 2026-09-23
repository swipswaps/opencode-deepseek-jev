#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
NOTES_SRC="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes"
NOTES_CONT="/workspace/notes"
OC_LOG="/home/node/.local/share/opencode/log/opencode.log"
TIMEOUT=1800
BEAT=2
IDLE_WARN=2
REPO=""; LOG=""; ART=""
CHILD=""; TAIL_TR=""; TAIL_OC=""; OC_PID=""; INTERRUPTED=0

resolve_repo() { local c="$1"; while [ "$c" != "/" ]; do [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }; c=$(dirname "$c"); done; return 1; }
log() { local l="$1" p="$2" s="$3" m="$4"; shift 4; local t; t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ); local kv="" x; for x in "$@"; do kv="$kv $x"; done; printf '%s\n' "ts=$t level=$l phase=$p status=$s msg=\"$m\"$kv" >> "$LOG"; }

show_tr() {
  case "$1" in
    *"message=loading path="*|*"message=tracking hash="*|*"message=\"creating instance\""*|*"message=fromDirectory"*|*"message=bootstrapping"*|*"message=\"project copy refresh"*|*"message=\"watcher backend\""*) return 1 ;;
    *) return 0 ;;
  esac
}
show_oc() {
  case "$1" in
    *"message=loading path="*|*"message=tracking hash="*|*"message=\"creating instance\""*|*"message=fromDirectory"*|*"message=bootstrapping"*|*"message=\"project copy refresh"*|*"message=\"watcher backend\""*|*"message=\"loading config from"*) return 1 ;;
    *) return 0 ;;
  esac
}

snapshot() {
  local reason="$1" d="$ART/stall-$(date -u +%H%M%S)"
  mkdir -p "$d"
  docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$C" > "$d/stats.txt" 2>&1
  docker exec "$C" cat /proc/net/tcp > "$d/net.txt" 2>&1
  docker exec "$C" sh -c '
    for p in /proc/[0-9]*; do
      [ -r "$p/comm" ] || continue
      printf "%s %s %s\n" "$(basename "$p")" "$(awk "/^State:/{print \$2}" "$p/status" 2>&1)" "$(cat "$p/comm" 2>&1)"
    done' > "$d/procs.txt" 2>&1
  docker exec "$C" sh -c "tail -20 $OC_LOG" > "$d/oc.log" 2>&1
  local cpu mem pids tcp n last
  cpu=$(grep -o 'cpu=[^ ]*' "$d/stats.txt" | head -1)
  mem=$(grep -o 'mem=[^ ]*' "$d/stats.txt" | head -1)
  pids=$(grep -o 'pids=[^ ]*' "$d/stats.txt" | head -1)
  tcp=$(awk '$4=="01"' "$d/net.txt" | wc -l | tr -d ' ')
  n=$(grep -c . "$d/procs.txt" | tr -d ' ')
  last=$(tail -1 "$d/oc.log" | head -c 160 | tr '"' "'")
  log WARN agent SNAPSHOT "diagnostic" "reason=$reason" \
    "$cpu" "$mem" "$pids" "tcp_estab=$tcp" "n_procs=$n" \
    "oc_last=\"$last\"" "dir=$d"
  printf '    [SNAP %s] %s %s %s tcp=%s procs=%s\n' "$reason" "$cpu" "$mem" "$pids" "$tcp" "$n"
  printf '    last oc line: %s\n' "$last"
}

handle_int() {
  if [ "$INTERRUPTED" -eq 1 ]; then
    printf '\n[hard abort]\n'
    exit 130
  fi
  INTERRUPTED=1
  printf '\n[SIGINT] stopping children; will push what exists\n'
  [ -n "$CHILD" ]   && kill -TERM "$CHILD"
  [ -n "$TAIL_TR" ] && kill -TERM "$TAIL_TR"
  [ -n "$TAIL_OC" ] && kill -TERM "$TAIL_OC"
  [ -n "$OC_PID" ]  && kill -TERM "$OC_PID"
}

main() {
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO=$(resolve_repo "$sd"); [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
  [ -z "$REPO" ] && { printf 'GATE FAIL: no repo\n' >&2; return 2; }
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$REPO/logs"
  LOG="$REPO/logs/telemetry-$(date -u +%Y-%m-%d).log"
  ART="$REPO/logs/artifacts-$ts"; mkdir -p "$ART"
  local compose_dir="$REPO/docker"
  local override="$compose_dir/docker-compose.override.yml"

  trap handle_int INT

  printf '=== audit-live.sh ===\nrepo: %s\n\n' "$REPO"
  log INFO session START "audit-live" "repo=$REPO" "art=$ART"

  [ -d "$NOTES_SRC" ] || { printf 'GATE FAIL: notes at %s missing\n' "$NOTES_SRC" >&2; return 1; }
  printf '[1] notes: %s files\n' "$(ls -1 "$NOTES_SRC" | wc -l | tr -d ' ')"

  printf '[2] override\n'
  cat > "$override" <<EOF
services:
  opencode-web:
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
      - ${NOTES_SRC}:${NOTES_CONT}:ro
EOF
  printf '    wrote %s\n' "$override"

  printf '[3] validate\n'
  ( cd "$compose_dir" && docker compose config >/dev/null )
  [ $? -ne 0 ] && { printf '    FAIL\n' >&2; return 1; }
  printf '    OK\n'

  printf '[4] recreate\n'
  ( cd "$compose_dir" && docker compose up -d --force-recreate opencode-web )
  local t=0 code=""
  while [ "$t" -lt 60 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:4096/)
    [ "$code" = "401" ] || [ "$code" = "200" ] && break
    t=$((t + 1)); sleep 2
  done
  printf '    http=%s\n' "$code"

  printf '[5] verify mount\n'
  docker inspect "$C" --format '{{json .Mounts}}' | grep -qF "\"Destination\":\"$NOTES_CONT\"" \
    || { printf '    FAIL\n' >&2; return 1; }
  local in_count
  in_count=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT | wc -l" | tr -d ' ')
  printf '    entries: %s\n' "$in_count"

  printf '[6] prompt\n'
  local prompt="$ART/prompt.txt"
  {
    printf 'Audit the OpenCode + DeepSeek + JEV container.\n\n'
    printf 'Read /workspace/notes (read-only, %s files) and /workspace.\n\n' "$in_count"
    printf 'Write /workspace/logs/sidebar-audit.md with:\n'
    printf '1. Project identity (README, QUICKSTART, opencode.json).\n'
    printf '2. Rule system: grep -rhoE "#[0-9]+" /workspace/notes --include="*.txt" | sort | uniq -c | sort -rn | head -30. Cross-reference /workspace/push_notes_v18.sh.\n'
    printf '3. JEV references in /workspace/notes and /workspace.\n'
    printf '4. Current state: opencode-web block, docker/web-entrypoint.sh, session count via node --experimental-sqlite.\n'
    printf '5. Sidebar streaming: is a processing session visible in the UI? yes/no + one sentence.\n'
    printf '6. Five next steps for the operator.\n\n'
    printf 'Then call jev_review once with the report as diff.\n'
    printf 'Reply with exactly:\ncorrectness=<score>\nsummary=<one sentence>\n'
  } > "$prompt"
  printf '    bytes: %s\n' "$(wc -c < "$prompt" | tr -d ' ')"
  docker exec -i "$C" sh -c 'cat > /tmp/p.txt' < "$prompt"

  printf '\n[7] audit (heartbeat=%ss)\n\n' "$BEAT"

  local tr="$ART/agent-transcript.log"; : > "$tr"
  local oc_tr="$ART/opencode-log-tail.log"; : > "$oc_tr"
  local stop="$ART/.stop"; rm -f "$stop"
  local start; start=$(date +%s)

  docker exec -t -w /workspace "$C" sh -c \
    "opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat /tmp/p.txt)\"" \
    > "$tr" 2>&1 &
  CHILD=$!

  docker exec -t "$C" sh -c "touch $OC_LOG; tail -F $OC_LOG" > "$oc_tr" 2>&1 &
  OC_PID=$!

  ( tail -F -n +1 "$tr" 2>&1 | while IFS= read -r line; do
      [ -f "$stop" ] && return 0
      show_tr "$line" && printf '    [tr] %s\n' "$line"
    done ) &
  TAIL_TR=$!

  ( tail -F -n +1 "$oc_tr" 2>&1 | while IFS= read -r line; do
      [ -f "$stop" ] && return 0
      show_oc "$line" && printf '    [oc] %s\n' "$line"
    done ) &
  TAIL_OC=$!

  local last_tr=0 last_oc=0 last_change=$start last_snap=$start
  while kill -0 "$CHILD" >/dev/null 2>&1; do
    sleep "$BEAT"
    local now el cur_tr cur_oc idle
    now=$(date +%s); el=$((now - start))
    cur_tr=$(wc -c < "$tr" | tr -d ' ')
    cur_oc=$(wc -l < "$oc_tr" | tr -d ' ')
    if [ "$cur_tr" -gt "$last_tr" ] || [ "$cur_oc" -gt "$last_oc" ]; then
      last_change=$now
    fi
    idle=$((now - last_change))

    printf '[t=%4ds tr=%8sB oc=%5sL idle=%3ds]\n' "$el" "$cur_tr" "$cur_oc" "$idle"

    if [ "$idle" -ge "$IDLE_WARN" ] && [ $((now - last_snap)) -ge "$IDLE_WARN" ]; then
      snapshot "idle=${idle}s"
      last_snap=$now
    fi

    last_tr=$cur_tr; last_oc=$cur_oc

    if [ "$el" -ge "$TIMEOUT" ]; then
      printf '\n    [timeout %ss]\n' "$el"
      kill -TERM "$CHILD"; sleep 2; kill -KILL "$CHILD"; break
    fi
  done

  wait "$CHILD"; local rc=$?
  CHILD=""
  touch "$stop"; sleep 1
  kill -TERM "$TAIL_TR" "$TAIL_OC" "$OC_PID"
  wait "$TAIL_TR"
  wait "$TAIL_OC"
  wait "$OC_PID"
  TAIL_TR=""; TAIL_OC=""; OC_PID=""

  printf '\n[7 done] rc=%s\n' "$rc"

  printf '\n=== final reply ===\n'
  grep -vE '^timestamp=' "$tr" | grep -v '^$' | tail -8

  printf '\n=== report ===\n'
  if [ -f "$REPO/logs/sidebar-audit.md" ]; then
    printf 'path:  %s\n' "$REPO/logs/sidebar-audit.md"
    printf 'bytes: %s\n' "$(wc -c < "$REPO/logs/sidebar-audit.md" | tr -d ' ')"
  else
    printf 'missing\n'
  fi

  cd "$REPO" || return 1
  local f
  for f in logs/agent-*.log logs/artifacts-*/agent-transcript.log logs/artifacts-*/opencode-log-tail.log; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
n = re.sub(r'apikey_[A-Za-z0-9_]{20,}', 'apikey_REDACTED', s)
n = re.sub(r'sk-[A-Za-z0-9]{20,}', 'sk-REDACTED', n)
n = re.sub(r'OPENCODE_SERVER_PASSWORD=[A-Za-z0-9+/=]{20,}', 'OPENCODE_SERVER_PASSWORD=REDACTED', n)
if n != s:
    open(p, 'w').write(n)
PY
  done

  printf '\n[8] push\n'
  if [ -x "$REPO/scripts/archive/one-shot/push-telemetry.sh" ]; then
    "$REPO/scripts/archive/one-shot/push-telemetry.sh" 2>&1
  fi

  log INFO session END "done" "rc=$rc" "in_count=$in_count"
  return "$rc"
}

main "$@"
