#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
NOTES_SRC="/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes"
NOTES_CONT="/workspace/notes"
TIMEOUT=600
REPO=""; LOG=""; ART=""; CHILD=""; STREAMER=""

resolve_repo() {
  local c="$1"
  while [ "$c" != "/" ]; do
    [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ] && { printf '%s' "$c"; return 0; }
    c=$(dirname "$c")
  done
  return 1
}

log() {
  local l="$1" p="$2" s="$3" m="$4"; shift 4
  local t; t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  local kv="" x; for x in "$@"; do kv="$kv $x"; done
  printf '%s\n' "ts=$t level=$l phase=$p status=$s msg=\"$m\"$kv" >> "$LOG"
}

show() {
  case "$1" in
    *"message=loading path="*|*"message=tracking hash="*|*"message=\"creating instance\""*|*"message=fromDirectory"*|*"message=bootstrapping"*|*"message=\"project copy refresh"*|*"message=\"watcher backend\""*) return 1 ;;
    *) return 0 ;;
  esac
}

cleanup() {
  [ -n "$CHILD" ]    && kill -TERM "$CHILD"    >/dev/null 2>&1
  [ -n "$STREAMER" ] && kill -TERM "$STREAMER" >/dev/null 2>&1
  return 0
}

main() {
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO=$(resolve_repo "$sd"); [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
  [ -z "$REPO" ] && { printf 'GATE FAIL: repo not found\n' >&2; return 2; }
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$REPO/logs"
  LOG="$REPO/logs/telemetry-$(date -u +%Y-%m-%d).log"
  ART="$REPO/logs/artifacts-$ts"; mkdir -p "$ART"
  local compose="$REPO/docker/docker-compose.yml"

  trap cleanup INT TERM

  printf '=== audit-e2e.sh ===\nrepo: %s\n\n' "$REPO"

  [ -d "$NOTES_SRC" ] || { printf 'GATE FAIL: notes not at %s\n' "$NOTES_SRC" >&2; return 1; }
  local nf; nf=$(ls -1 "$NOTES_SRC" | wc -l | tr -d ' ')
  printf '[1] notes source: %s files\n' "$nf"

  printf '[2] patch compose\n'
  if grep -qF "$NOTES_CONT:ro" "$compose"; then
    printf '    already mounted\n'
  else
    cp "$compose" "$compose.bak.${ts}"
    local out
    out=$(python3 - "$compose" "$NOTES_SRC" "$NOTES_CONT" <<'PY'
import re, sys
path, src, cont = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'^[ \t]*- [^\n]*:/notes(:ro)?[ \t]*\n', '', s, flags=re.MULTILINE)
s = re.sub(r'^[ \t]*- [^\n]*:/workspace/notes(:ro)?[ \t]*\n', '', s, flags=re.MULTILINE)
m = re.search(r'^([ \t]*- )[^\n]*:/home/node/\.local/share/opencode[^\n]*\n', s, re.MULTILINE)
if not m:
    print("ANCHOR_MISSING")
else:
    s = s[:m.end()] + f"{m.group(1)}{src}:{cont}:ro\n" + s[m.end():]
    open(path, "w").write(s)
    print("MOUNT_ADDED")
PY
)
    case "$out" in
      MOUNT_ADDED)    printf '    patched\n' ;;
      ANCHOR_MISSING) printf '    anchor missing\n' >&2; return 1 ;;
      *)              printf '    unexpected: %s\n' "$out" >&2; return 1 ;;
    esac
  fi

  printf '[3] recreate\n'
  ( cd "$REPO/docker" && docker compose up -d --force-recreate opencode-web ) || return 1
  local t=0 code=""
  while [ "$t" -lt 60 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:4096/ 2>&1)
    [ "$code" = "401" ] || [ "$code" = "200" ] && break
    t=$((t+1)); sleep 2
  done
  printf '    http=%s\n' "$code"

  printf '[4] verify /workspace/notes\n'
  local in_count
  in_count=$(docker exec "$C" sh -c "ls -1 $NOTES_CONT | wc -l" 2>&1 | tr -d ' ')
  printf '    entries: %s\n' "$in_count"
  if [ "$in_count" -lt 1 ]; then
    docker inspect "$C" --format '{{json .Mounts}}' | python3 -m json.tool
    return 1
  fi

  printf '[5] prompt\n'
  local prompt="$ART/prompt.txt"
  {
    printf 'You are auditing an OpenCode + DeepSeek + JEV container.\n\n'
    printf 'Locations:\n'
    printf '  /workspace               repo (rw)\n'
    printf '  /workspace/notes         chat logs (ro)\n'
    printf '  /workspace/logs          output (rw)\n\n'
    printf 'Write the report to /workspace/logs/sidebar-audit.md with sections:\n\n'
    printf '1. Project identity: one paragraph from README.txt, QUICKSTART.txt, opencode.json.\n'
    printf '2. Rule system: grep -rhoE "#[0-9]+" /workspace/notes --include="*.txt" | sort | uniq -c | sort -rn | head -30. Cross-reference /workspace/push_notes_v18.sh.\n'
    printf '3. JEV: where JEV appears in /workspace/notes and /workspace.\n'
    printf '4. Current state: opencode-web block of docker/docker-compose.yml, docker/web-entrypoint.sh verbatim, session count via node --experimental-sqlite against /workspace/data/opencode/opencode.db.\n'
    printf '5. Sidebar streaming: when a session is processing, is it visible in the UI? yes/no with one sentence.\n'
    printf '6. Five concrete next steps for the operator.\n\n'
    printf 'Then call jev_review once with the report as diff.\n'
    printf 'Reply with exactly two lines:\ncorrectness=<score>\nsummary=<one sentence>\n'
  } > "$prompt"
  printf '    prompt bytes: %s\n' "$(wc -c < "$prompt" | tr -d ' ')"
  docker exec -i "$C" sh -c 'cat > /tmp/p.txt' < "$prompt"

  printf '[6] run audit\n\n'
  local tr="$ART/agent-transcript.log"; : > "$tr"
  local start; start=$(date +%s)
  docker exec -w /workspace "$C" sh -c \
    "stdbuf -oL -eL opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat /tmp/p.txt)\"" \
    > "$tr" 2>&1 &
  CHILD=$!

  local stop="$ART/.stop"; rm -f "$stop"
  ( while [ ! -f "$tr" ]; do sleep 0.2; done
    tail -F -n +1 "$tr" 2>&1 | while IFS= read -r line; do
      [ -f "$stop" ] && return 0
      show "$line" && printf '    %s\n' "$line"
    done ) &
  STREAMER=$!

  while kill -0 "$CHILD" >/dev/null 2>&1; do
    sleep 2
    local now el; now=$(date +%s); el=$((now-start))
    if [ "$el" -ge "$TIMEOUT" ]; then
      kill -TERM "$CHILD" >/dev/null 2>&1
      sleep 2
      kill -KILL "$CHILD" >/dev/null 2>&1
      break
    fi
  done
  wait "$CHILD" 2>&1; local rc=$?
  CHILD=""
  touch "$stop"; sleep 1
  kill -TERM "$STREAMER" >/dev/null 2>&1
  wait "$STREAMER" >/dev/null 2>&1
  STREAMER=""

  printf '\n[6 done] rc=%s\n' "$rc"

  printf '\n=== final reply ===\n'
  grep -vE '^timestamp=' "$tr" | grep -v '^$' | tail -6

  printf '\n=== report ===\n'
  if [ -f "$REPO/logs/sidebar-audit.md" ]; then
    printf 'path:  %s\n' "$REPO/logs/sidebar-audit.md"
    printf 'bytes: %s\n' "$(wc -c < "$REPO/logs/sidebar-audit.md" | tr -d ' ')"
  else
    printf 'missing\n'
  fi

  cd "$REPO" || return 1
  local f
  for f in logs/agent-*.log logs/artifacts-*/agent-transcript.log; do
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

  printf '\n[7] push\n'
  if [ -x "$REPO/scripts/archive/one-shot/push-telemetry.sh" ]; then
    "$REPO/scripts/archive/one-shot/push-telemetry.sh" 2>&1
  else
    printf '    push script missing\n'
  fi

  return "$rc"
}

main "$@"
