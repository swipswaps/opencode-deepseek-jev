#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
NOTES_HOST="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes"
NOTES_CONT="/workspace/notes"
TIMEOUT=900
STALL=15
REPO=""; LOG=""; ARTIFACT_DIR=""; CHILD=""

resolve_repo() { local c="$1"; while [ "$c" != "/" ]; do [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }; c=$(dirname "$c"); done; return 1; }
log() { local l="$1" p="$2" s="$3" m="$4"; shift 4; local t; t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ); local kv="" x; for x in "$@"; do kv="$kv $x"; done; printf '%s\n' "ts=$t level=$l phase=$p status=$s msg=\"$m\"$kv" >> "$LOG"; }
cleanup() { [ -n "$CHILD" ] && kill -TERM "$CHILD" >/dev/null 2>&1; exit 130; }
show_line() {
  case "$1" in
    *"message=loading path="*) return 1 ;;
    *"message=tracking hash="*) return 1 ;;
    *"message=\"creating instance\""*) return 1 ;;
    *"message=fromDirectory"*) return 1 ;;
    *"message=bootstrapping"*) return 1 ;;
    *"message=\"project copy refresh"*) return 1 ;;
    *"message=\"watcher backend\""*) return 1 ;;
    *) return 0 ;;
  esac
}
snapshot() {
  local l="$1" r="$2" d="$ARTIFACT_DIR/stall-$l-$(date -u +%H%M%S)"
  mkdir -p "$d"
  docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$C" > "$d/s.txt" 2>&1
  docker exec "$C" cat /proc/net/tcp > "$d/n.txt" 2>&1
  docker exec "$C" sh -c 'for p in /proc/[0-9]*; do [ -r "$p/comm" ] || continue; printf "%s %s %s\n" "$(basename "$p")" "$(awk "/^State:/{print \$2}" "$p/status" 2>&1)" "$(cat "$p/comm" 2>&1)"; done' > "$d/p.txt" 2>&1
  docker exec "$C" sh -c 'd=/home/node/.local/share/opencode/log; [ -d "$d" ] || { echo "(no log dir)"; exit 0; }; latest=""; for f in "$d"/*; do [ -f "$f" ] || continue; if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then latest="$f"; fi; done; [ -n "$latest" ] || { echo "(no log)"; exit 0; }; tail -10 "$latest"' > "$d/o.txt" 2>&1
  local cpu mem pids tcp n last
  cpu=$(grep -o 'cpu=[^ ]*' "$d/s.txt" | head -1)
  mem=$(grep -o 'mem=[^ ]*' "$d/s.txt" | head -1)
  pids=$(grep -o 'pids=[^ ]*' "$d/s.txt" | head -1)
  tcp=$(awk '$4=="01"' "$d/n.txt" | wc -l | tr -d ' ')
  n=$(grep -c . "$d/p.txt" | tr -d ' ')
  last=$(tail -1 "$d/o.txt" | head -c 120 | tr '"' "'")
  log WARN agent SNAPSHOT "diag" "reason=$r" "$cpu" "$mem" "$pids" "tcp_estab=$tcp" "n_procs=$n" "oc_last=\"$last\"" "dir=$d"
  printf '    [%s] %s %s %s tcp=%s procs=%s\n        %s\n' "$r" "$cpu" "$mem" "$pids" "$tcp" "$n" "$last"
}

main() {
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO=$(resolve_repo "$sd"); [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
  [ -z "$REPO" ] && { printf 'GATE FAIL\n'; return 2; }
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$REPO/logs"
  LOG="$REPO/logs/telemetry-$(date -u +%Y-%m-%d).log"
  ARTIFACT_DIR="$REPO/logs/artifacts-$ts"; mkdir -p "$ARTIFACT_DIR"
  trap cleanup INT TERM
  printf '=== final-audit.sh ===\nrepo: %s\n\n' "$REPO"

  local compose="$REPO/docker/docker-compose.yml"
  printf '[A] mount /workspace/notes\n'
  if grep -qF "$NOTES_CONT:ro" "$compose"; then printf '    ok\n'; else
    cp "$compose" "$compose.bak.${ts}"
    local out
    out=$(python3 - "$compose" "$NOTES_HOST" "$NOTES_CONT" <<'PY'
import re, sys
p, host, cont = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(p).read()
src = re.sub(r'^[ \t]*- [^\n]*notes[^\n]*\n', '', src, flags=re.MULTILINE)
m = re.search(r'^([ \t]*- )\.\./data/opencode:/home/node/\.local/share/opencode[ \t]*\n', src, re.MULTILINE)
if not m:
    print("ANCHOR_MISSING")
else:
    src = src[:m.end()] + f"{m.group(1)}{host}:{cont}:ro\n" + src[m.end():]
    open(p, "w").write(src)
    print("ADDED")
PY
)
    case "$out" in
      ADDED) printf '    added\n' ;;
      ANCHOR_MISSING) printf '    FAIL: anchor missing\n'; return 1 ;;
      *) printf '    WARN: %s\n' "$out" ;;
    esac
  fi

  printf '\n[B] recreate\n'
  ( cd "$REPO/docker" && docker compose up -d --force-recreate opencode-web )
  local t=0 c=""
  while [ "$t" -lt 60 ]; do c=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:4096/ 2>&1); [ -n "$c" ] && [ "$c" != "000" ] && break; t=$((t+1)); sleep 2; done
  printf '    http=%s\n' "$c"

  printf '\n[C] verify\n'
  local nf; nf=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT | wc -l" 2>&1 | tr -d ' ')
  printf '    entries: %s\n' "$nf"
  [ "$nf" -lt 1 ] && { docker inspect "$C" --format '{{json .Mounts}}' | python3 -m json.tool; return 1; }

  printf '\n[D] run audit\n'
  docker exec -i "$C" sh -c "cat > /tmp/p.txt" <<'PROMPT'
Audit. Read /workspace/notes (ro), /workspace (rw).

Write /workspace/logs/sidebar-audit.md with:
1. Project identity (README/QUICKSTART/opencode.json)
2. Rule system: grep -rhoE '#[0-9]+' /workspace/notes --include='*.txt' | sort | uniq -c | sort -rn | head -30; cross-reference /workspace/push_notes_v18.sh
3. JEV hits in /workspace/notes and /workspace
4. Current state: opencode-web block, docker/web-entrypoint.sh, session count via node --experimental-sqlite on /workspace/data/opencode/opencode.db
5. Sidebar streaming question: yes/no + evidence
6. Five bullets for operator next steps.

Call jev_review once. Reply exactly:
correctness=<score>
summary=<one sentence>
PROMPT

  local tr="$ARTIFACT_DIR/agent-transcript.log"; : > "$tr"
  local start; start=$(date +%s)
  docker exec -w /workspace "$C" sh -c "opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat /tmp/p.txt)\"" > "$tr" 2>&1 &
  CHILD=$!
  local stop="$ARTIFACT_DIR/.stop"; rm -f "$stop"
  ( while [ ! -f "$tr" ]; do sleep 0.2; done; tail -F -n +1 "$tr" 2>&1 | while IFS= read -r line; do [ -f "$stop" ] && exit 0; show_line "$line" && printf '    %s\n' "$line"; done ) &
  local streamer=$!
  local ls=0 lg=$start lsnap=0 ins=0
  while kill -0 "$CHILD" >/dev/null 2>&1; do
    sleep 2
    local now el cur; now=$(date +%s); el=$((now-start)); cur=$(wc -c < "$tr" | tr -d ' ')
    if [ "$cur" -gt "$ls" ]; then ls=$cur; lg=$now; [ "$ins" -eq 1 ] && { printf '    [resume]\n'; ins=0; }; else
      local idle=$((now-lg))
      if [ "$idle" -ge "$STALL" ]; then
        if [ "$ins" -eq 0 ]; then ins=1; snapshot s1 stall; lsnap=$now
        elif [ $((now-lsnap)) -ge "$STALL" ]; then snapshot s1 still; lsnap=$now; fi
      fi
    fi
    [ "$el" -ge "$TIMEOUT" ] && { printf '    [timeout %ss]\n' "$el"; kill -TERM "$CHILD" >/dev/null 2>&1; sleep 2; kill -KILL "$CHILD" >/dev/null 2>&1; break; }
  done
  wait "$CHILD" 2>&1; local rc=$?; CHILD=""
  touch "$stop"; sleep 1; kill -TERM "$streamer" >/dev/null 2>&1; wait "$streamer" >/dev/null 2>&1

  printf '\n[D done] rc=%s\n' "$rc"
  printf '\n=== agent final reply ===\n'
  grep -vE '^timestamp=' "$tr" | grep -v '^$' | tail -4
  printf '\n=== report ===\n'
  [ -f "$REPO/logs/sidebar-audit.md" ] && { printf 'path:  %s\n' "$REPO/logs/sidebar-audit.md"; printf 'bytes: %s\n' "$(wc -c < "$REPO/logs/sidebar-audit.md" | tr -d ' ')"; } || printf 'missing\n'
  printf '\n[E] push\n'
  [ -x "$REPO/scripts/archive/one-shot/push-telemetry.sh" ] && "$REPO/scripts/archive/one-shot/push-telemetry.sh" 2>&1 || printf '    no push script\n'
  return "$rc"
}
main "$@"
