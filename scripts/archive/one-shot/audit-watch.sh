#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
NOTES_SRC="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes"
NOTES_CONT="/workspace/notes"
OC_LOG="/home/node/.local/share/opencode/log/opencode.log"
OC_DB="/home/node/.local/share/opencode/opencode.db"
TIMEOUT=1800
IDLE_WARN=30
REPO=""; LOG=""; ART=""
CHILD=""; TAIL_TR=""; TAIL_OC=""; OC_PID=""

resolve_repo() { local c="$1"; while [ "$c" != "/" ]; do [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }; c=$(dirname "$c"); done; return 1; }
log() { local l="$1" p="$2" s="$3" m="$4"; shift 4; local t; t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ); local kv="" x; for x in "$@"; do kv="$kv $x"; done; printf '%s\n' "ts=$t level=$l phase=$p status=$s msg=\"$m\"$kv" >> "$LOG"; }

deep_dump() {
  local reason="$1" d="$ART/dump-$(date -u +%H%M%S)"
  mkdir -p "$d"
  printf '    [DUMP %s] dir=%s\n' "$reason" "$d"

  docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$C" > "$d/stats.txt" 2>&1
  cat "$d/stats.txt" | while IFS= read -r l; do printf '      %s\n' "$l"; done

  # Process table with state and wchan for every PID inside the container.
  docker exec "$C" sh -c '
    for p in /proc/[0-9]*; do
      pid=$(basename "$p")
      [ -r "$p/comm" ] || continue
      comm=$(cat "$p/comm" 2>&1)
      state=$(awk "/^State:/{print \$2}" "$p/status" 2>&1)
      wchan=$(cat "$p/wchan" 2>&1)
      ppid=$(awk "/^PPid:/{print \$2}" "$p/status" 2>&1)
      rss=$(awk "/^VmRSS:/{print \$2}" "$p/status" 2>&1)
      printf "      pid=%-6s ppid=%-6s state=%-2s rss=%-8s wchan=%-24s comm=%s\n" "$pid" "$ppid" "$state" "$rss" "$wchan" "$comm"
      ls -l "$p/fd" 2>&1 | head -8 | while IFS= read -r fd; do printf "        fd: %s\n" "$fd"; done
    done
  ' > "$d/procs.txt" 2>&1
  cat "$d/procs.txt"

  # Every TCP connection with state
  docker exec "$C" cat /proc/net/tcp > "$d/tcp.txt" 2>&1
  printf '      tcp (hex local remote state):\n'
  cat "$d/tcp.txt" | while IFS= read -r l; do printf '        %s\n' "$l"; done

  # Full opencode.log tail, no filter
  docker exec "$C" sh -c "tail -60 $OC_LOG" > "$d/oc.log" 2>&1
  printf '      last 60 lines of opencode.log:\n'
  cat "$d/oc.log" | while IFS= read -r l; do printf '        %s\n' "$l"; done

  # Database state (WAL not checkpointed, WAL size, etc.)
  docker exec "$C" sh -c "ls -la $(dirname $OC_DB) 2>&1" > "$d/db-state.txt" 2>&1
  printf '      db state:\n'
  cat "$d/db-state.txt" | while IFS= read -r l; do printf '        %s\n' "$l"; done

  log WARN agent DUMP "process state" "reason=$reason" "dir=$d"
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

  printf '=== audit-watch.sh ===\nrepo: %s\n\n' "$REPO"
  log INFO session START "audit-watch" "repo=$REPO" "art=$ART"

  [ -d "$NOTES_SRC" ] || { printf 'GATE FAIL: notes at %s missing\n' "$NOTES_SRC" >&2; return 1; }
  printf '[1] notes: %s files\n' "$(ls -1 "$NOTES_SRC" | wc -l | tr -d ' ')"

  cat > "$override" <<EOF
services:
  opencode-web:
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
      - ${NOTES_SRC}:${NOTES_CONT}:ro
EOF
  printf '[2] override written\n'

  ( cd "$compose_dir" && docker compose config >/dev/null )
  [ $? -ne 0 ] && { printf '[3] FAIL: config rejected\n' >&2; return 1; }
  printf '[3] config OK\n'

  ( cd "$compose_dir" && docker compose up -d --force-recreate opencode-web )
  local t=0 code=""
  while [ "$t" -lt 60 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:4096/)
    [ "$code" = "401" ] || [ "$code" = "200" ] && break
    t=$((t + 1)); sleep 2
  done
  printf '[4] http=%s\n' "$code"

  docker inspect "$C" --format '{{json .Mounts}}' | grep -qF "\"Destination\":\"$NOTES_CONT\"" \
    || { printf '[5] FAIL: no mount\n' >&2; return 1; }
  local in_count
  in_count=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT | wc -l" | tr -d ' ')
  printf '[5] notes mounted: %s\n' "$in_count"

  local prompt="$ART/prompt.txt"
  {
    printf 'Audit the OpenCode + DeepSeek + JEV container.\n\n'
    printf 'Read /workspace/notes (read-only, %s files) and /workspace.\n\n' "$in_count"
    printf 'Write /workspace/logs/sidebar-audit.md with:\n'
    printf '1. Project identity.\n'
    printf '2. Rule system: grep -rhoE "#[0-9]+" /workspace/notes --include="*.txt" | sort | uniq -c | sort -rn | head -30.\n'
    printf '3. JEV references.\n'
    printf '4. Current state: compose block, entrypoint, session count.\n'
    printf '5. Sidebar streaming question.\n'
    printf '6. Five next steps.\n\n'
    printf 'Then call jev_review once.\nReply with:\ncorrectness=<score>\nsummary=<one sentence>\n'
  } > "$prompt"
  docker exec -i "$C" sh -c 'cat > /tmp/p.txt' < "$prompt"
  printf '[6] prompt: %s bytes\n\n' "$(wc -c < "$prompt" | tr -d ' ')"

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

  # No filter. Every line, prefixed by source.
  ( tail -F -n +1 "$tr" 2>&1 | while IFS= read -r line; do
      [ -f "$stop" ] && return 0
      printf '[tr] %s\n' "$line"
    done ) &
  TAIL_TR=$!

  ( tail -F -n +1 "$oc_tr" 2>&1 | while IFS= read -r line; do
      [ -f "$stop" ] && return 0
      printf '[oc] %s\n' "$line"
    done ) &
  TAIL_OC=$!

  local last_tr=0 last_oc=0 last_change=$start last_dump=$start
  while kill -0 "$CHILD" >/dev/null 2>&1; do
    sleep 1
    local now cur_tr cur_oc idle
    now=$(date +%s)
    cur_tr=$(wc -c < "$tr" | tr -d ' ')
    cur_oc=$(wc -l < "$oc_tr" | tr -d ' ')
    if [ "$cur_tr" -gt "$last_tr" ] || [ "$cur_oc" -gt "$last_oc" ]; then
      last_change=$now
    fi
    idle=$((now - last_change))
    if [ "$idle" -ge "$IDLE_WARN" ] && [ $((now - last_dump)) -ge "$IDLE_WARN" ]; then
      deep_dump "idle=${idle}s"
      last_dump=$now
    fi
    last_tr=$cur_tr; last_oc=$cur_oc

    if [ $((now - start)) -ge "$TIMEOUT" ]; then
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

  printf '\n=== transcript tail (last 20 non-runtime lines) ===\n'
  grep -vE '^timestamp=' "$tr" | grep -v '^$' | tail -20

  printf '\n=== report ===\n'
  if [ -f "$REPO/logs/sidebar-audit.md" ]; then
    printf 'path:  %s\n' "$REPO/logs/sidebar-audit.md"
    printf 'bytes: %s\n' "$(wc -c < "$REPO/logs/sidebar-audit.md" | tr -d ' ')"
  else
    printf 'missing\n'
  fi

  cd "$REPO" || return 1
  local f
  for f in logs/agent-*.log logs/artifacts-*/agent-transcript.log logs/artifacts-*/opencode-log-tail.log logs/artifacts-*/dump-*/*; do
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
