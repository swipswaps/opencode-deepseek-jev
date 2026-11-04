#!/usr/bin/env bash
#
# incident-resolve.sh
# Classify recurring failure signatures from logs and resolve the safe ones.
#
# Sources: a log file, stdin, or the repo's own collectors (--db uses
# logs.sh --source error and --source guard, which read opencode.db and
# guard.log).
#
# Safe auto-resolutions: tmux "no server" -> start a session; already-paused
# container errors -> success; embedding cold-load timeout -> warm the model
# and print the measured elapsed time. Everything else prints the evidence
# line and the exact corrective command (RULES #90-#92).
#
# Usage:
#   ./scripts/incident-resolve.sh --log FILE [--auto]
#   ./scripts/logs.sh --source error | ./scripts/incident-resolve.sh [--auto]
#   ./scripts/incident-resolve.sh --db [--auto]
#   ./scripts/incident-resolve.sh --self-test

SCRIPT_NAME="incident-resolve.sh"
REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "$0")/.." && pwd)}"
RAG_DIR="${RAG_DIR:-/home/owner/Documents/2282af3557819803/repo/production-local-rag}"
TMUX_SESSION="${TMUX_SESSION:-rag-recovery}"
OLLAMA_API="${OLLAMA_API:-http://127.0.0.1:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
WARM_TIMEOUT="${WARM_TIMEOUT:-120}"
SSH_KEY="${SSH_KEY:-/home/node/.ssh/opencode_container_ed25519}"
AUTH_KEYS="${AUTH_KEYS:-/home/owner/.ssh/authorized_keys}"
LOG=""
FROM_DB=0
AUTO=0
SELF_TEST=0
UNRESOLVED=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; UNRESOLVED=$((UNRESOLVED + 1)); }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--log FILE|--db] [--auto]"
  printf '%s\n' "       $SCRIPT_NAME --self-test"
  printf '%s\n' ""
  printf '%s\n' "  --log FILE   classify FILE (default: stdin)"
  printf '%s\n' "  --db         collect logs.sh error + guard sources first"
  printf '%s\n' "  --auto       apply safe resolutions (start tmux, warm embed)"
  printf '%s\n' "  --self-test  verify the classifier against known strings"
  printf '%s\n' "  --help       this text"
  printf '%s\n' ""
  printf '%s\n' "  WARM_TIMEOUT=$WARM_TIMEOUT (basis: measured 20.6s cold load, 2026-11-04)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --log) shift; LOG="$1" ;;
      --db) FROM_DB=1 ;;
      --auto) AUTO=1 ;;
      --self-test) SELF_TEST=1 ;;
      --help|-h) usage; exit 0 ;;
      *) err "unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
  done
}

classify() {
  local f="$1"
  if grep -q "error connecting to .*tmux.*No such file" "$f"; then printf 'tmux-no-server'; return 0; fi
  if grep -q "is already paused" "$f"; then printf 'pause-idempotent'; return 0; fi
  if grep -qE "Embedding request failed|HTTP 404 during embedding|model .* not found, try pulling" "$f"; then printf 'embedding'; return 0; fi
  if grep -q "pgrep: pattern that searches for process name longer than 15" "$f"; then printf 'pgrep-truncation'; return 0; fi
  if grep -q "Permission denied (publickey" "$f"; then printf 'ssh-auth'; return 0; fi
  if grep -q "I/O pressure .* still above" "$f"; then printf 'io-pressure'; return 0; fi
  if grep -q "command not found" "$f"; then printf 'missing-binary'; return 0; fi
  if grep -q "blacklist-guard blocked this command" "$f"; then printf 'guard-block'; return 0; fi
  if grep -q "Could not find oldString" "$f"; then printf 'edit-stale'; return 0; fi
  if grep -q "timed out" "$f"; then printf 'timeout'; return 0; fi
  printf 'none'
}

count_of() {
  grep -c "$1" "$2"
}

evidence_of() {
  grep -m1 "$1" "$2" | awk '{ print substr($0, 1, 200) }'
}

resolve_tmux() {
  if ! command -v tmux >/dev/null; then
    fail "tmux binary absent (command -v tmux); install tmux (RULES #90)"
    return 1
  fi
  if tmux has-session -t "$TMUX_SESSION" >/dev/null; then
    pass "tmux server/session already present: $TMUX_SESSION"
    return 0
  fi
  tmux new-session -d -s "$TMUX_SESSION" || { fail "could not start tmux session $TMUX_SESSION"; return 1; }
  tmux list-sessions | grep -F "$TMUX_SESSION" >/dev/null \
    && { pass "started tmux session $TMUX_SESSION (binary was present; only the server was absent)"; return 0; }
  fail "tmux session $TMUX_SESSION did not start"
  return 1
}

resolve_embedding() {
  if ! command -v curl >/dev/null; then
    fail "curl absent; cannot warm $EMBED_MODEL"
    return 1
  fi
  local start end rc
  start=$(date +%s)
  curl -sS --max-time "$WARM_TIMEOUT" "$OLLAMA_API/api/embed" \
    -d "{\"model\":\"$EMBED_MODEL\",\"input\":\"search_query: warm\"}" \
    >/tmp/incident-embed.json 2>&1
  rc=$?
  end=$(date +%s)
  log "embed warm: rc=${rc} elapsed=$((end - start))s bound=${WARM_TIMEOUT}s (basis: measured 20.6s cold load)"
  if [ "$rc" -eq 0 ]; then
    pass "embedding model warm; retry the retrieval"
    return 0
  fi
  tail -c 200 /tmp/incident-embed.json
  printf '\n'
  fail "embedding warm failed; check: journalctl -u ollama -n 20 --no-pager"
  return 1
}

resolve_ssh() {
  if [ ! -f "$SSH_KEY.pub" ] || [ ! -f "$AUTH_KEYS" ]; then
    fail "missing $SSH_KEY.pub or $AUTH_KEYS; run $RAG_DIR/scripts/11-host-access.sh --install --yes"
    return 1
  fi
  if grep -qF "$(cat "$SSH_KEY.pub")" "$AUTH_KEYS"; then
    pass "container key is authorized; the denial was transient or host-side"
    return 0
  fi
  fail "container key not in $AUTH_KEYS; run $RAG_DIR/scripts/11-host-access.sh --install --yes"
  return 1
}

resolve_incident() {
  local kind="$1" count="$2" evidence="$3"
  printf 'INCIDENT %-18s count=%s\n' "$kind" "$count"
  printf '  evidence: %s\n' "$evidence"
  case "$kind" in
    tmux-no-server)
      if [ "$AUTO" -eq 1 ]; then
        resolve_tmux
      else
        fail "tmux server absent (binary present); run --auto to start $TMUX_SESSION"
      fi
      ;;
    pause-idempotent)
      pass "already-paused is success; no action needed"
      ;;
    embedding)
      if [ "$AUTO" -eq 1 ]; then
        resolve_embedding
      else
        fail "embedding cold-load timeout/missing model; run --auto to warm $EMBED_MODEL"
      fi
      ;;
    ssh-auth)
      if [ "$AUTO" -eq 1 ]; then
        resolve_ssh
      else
        fail "pubkey denied; run $RAG_DIR/scripts/11-host-access.sh --install --yes"
      fi
      ;;
    pgrep-truncation)
      fail "pgrep -x cannot match >15-char comm; use the truncated name or pgrep -f with an anchored path"
      ;;
    missing-binary)
      fail "a binary is absent (command not found); verify with command -v <name> before installing (RULES #90)"
      ;;
    guard-block)
      fail "blacklist guard blocked the call; apply the substitution named in the evidence (RULES #7/security), no auto-resolve"
      ;;
    edit-stale)
      fail "edit oldString did not match; re-read the exact region before editing (RULES #61 advisory)"
      ;;
    io-pressure)
      fail "I/O gate refused; re-measure with cat /proc/pressure/io (rule #91: report the last sample)"
      ;;
    timeout)
      fail "timeout without a measured basis; record cold-load/p95 and the last sample (RULES #91)"
      ;;
    *)
      fail "unclassified incident"
      ;;
  esac
  printf '\n'
}

collect_db() {
  "$REPO_DIR/scripts/logs.sh" --source error --tail 200
  "$REPO_DIR/scripts/logs.sh" --source guard --tail 200
}

self_test() {
  local tmp expected got line failures
  failures=0
  tmp=$(mktemp) || { err "mktemp failed"; return 2; }
  while IFS='|' read -r expected line; do
    printf '%s\n' "$line" > "$tmp"
    got=$(classify "$tmp")
    if [ "$got" = "$expected" ]; then
      pass "classify $expected"
    else
      fail "classify expected=$expected got=$got line=$line"
      failures=$((failures + 1))
    fi
  done <<'CASES'
tmux-no-server|error connecting to /tmp/tmux-1000/default (No such file or directory)
pause-idempotent|Error response from daemon: Container abc is already paused
embedding|Embedding request failed after retries: timed out
pgrep-truncation|pgrep: pattern that searches for process name longer than 15 characters will result in zero matches
ssh-auth|owner@192.168.4.24: Permission denied (publickey,gssapi-keyex,gssapi-with-mic)
io-pressure|GATE FAIL  I/O pressure 38.64% still above 20% after 60s
missing-binary|./scripts/foo.sh: line 1: docker: command not found
guard-block|blacklist-guard blocked this command:
edit-stale|Could not find oldString in the file. It must match exactly
timeout|curl: (28) Operation timed out after 30001 milliseconds
CASES
  rm -f "$tmp"
  if [ "$failures" -eq 0 ]; then
    pass "self-test"
    return 0
  fi
  fail "self-test: $failures case(s)"
  return 1
}

main() {
  parse_args "$@"
  if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    return $?
  fi

  local tmp
  tmp=$(mktemp) || { err "mktemp failed"; return 2; }
  if [ "$FROM_DB" -eq 1 ]; then
    collect_db > "$tmp"
  elif [ -n "$LOG" ]; then
    [ -f "$LOG" ] || { err "missing log: $LOG"; rm -f "$tmp"; return 2; }
    cat "$LOG" > "$tmp"
  else
    cat > "$tmp"
  fi

  if [ ! -s "$tmp" ]; then
    log "no log content; nothing to classify"
    rm -f "$tmp"
    return 0
  fi

  local kind token count found
  found=0
  while IFS='|' read -r kind token; do
    count=$(count_of "$token" "$tmp")
    [ "$count" -gt 0 ] || continue
    found=1
    resolve_incident "$kind" "$count" "$(evidence_of "$token" "$tmp")"
  done <<'KINDS'
tmux-no-server|error connecting to .*tmux.*No such file
pause-idempotent|is already paused
embedding|Embedding request failed
pgrep-truncation|pattern that searches for process name longer than 15
ssh-auth|Permission denied (publickey
io-pressure|I/O pressure .* still above
missing-binary|command not found
guard-block|blacklist-guard blocked this command
edit-stale|Could not find oldString
timeout|timed out
KINDS
  rm -f "$tmp"
  if [ "$found" -eq 0 ]; then
    pass "no known incident signatures"
    return 0
  fi

  if [ "$UNRESOLVED" -eq 0 ]; then
    pass "incidents resolved"
    return 0
  fi
  err "$UNRESOLVED incident(s) still need action"
  return 1
}

main "$@"
exit $?
