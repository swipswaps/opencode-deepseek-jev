#!/usr/bin/env bash
#
# 09-refresh-handoff.sh
# Rebuild the CURRENT session transcript from opencode.db (no browser), then
# regenerate the redacted, leak-checked handoff brief and print the rotation
# sequence. Deterministic: no model call, no spend, no fork/continue.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/09-refresh-handoff.sh
#   ./scripts/09-refresh-handoff.sh --session ses_...
#   ./scripts/09-refresh-handoff.sh --dry-run
#   ./scripts/09-refresh-handoff.sh --help

SCRIPT_NAME="09-refresh-handoff.sh"
REPO=""
SID=""
DB=""
BRIEF=""
TRANSCRIPT=""
DRY_RUN=0
RAG_DIR="${RAG_DIR:-/home/owner/Documents/2282af3557819803/repo/production-local-rag}"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--session ID] [--db PATH] [--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --session ID   session to rotate (default: latest by time_updated)"
  printf '%s\n' "  --db PATH      opencode.db (default: <repo>/data/opencode/opencode.db)"
  printf '%s\n' "  --dry-run      print the plan; do not write transcript/brief"
  printf '%s\n' "  --help         this text"
}

resolve_repo() {
  local c="$1"
  while [ "$c" != "/" ]; do
    if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
      printf '%s' "$c"
      return 0
    fi
    c=$(dirname "$c")
  done
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) shift; SID="$1" ;;
      --db) shift; DB="$1" ;;
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

valid_sid() {
  case "$1" in
    ses_*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

main() {
  parse_args "$@"

  REPO=$(resolve_repo "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)")
  [ -n "$REPO" ] || die "cannot resolve repo root"
  [ -n "$DB" ] || DB="$REPO/data/opencode/opencode.db"
  [ -f "$DB" ] || die "missing $DB"
  command -v sqlite3 >/dev/null || die "sqlite3 missing"
  command -v python3 >/dev/null || die "python3 missing"

  if [ -z "$SID" ]; then
    SID=$(sqlite3 "$DB" "select id from session order by time_updated desc limit 1;")
  fi
  valid_sid "$SID" || die "invalid session id: $SID"
  [ -n "$BRIEF" ] || BRIEF="$REPO/logs/brief-$SID.md"
  [ -n "$TRANSCRIPT" ] || TRANSCRIPT="$REPO/logs/ses_$SID.txt"

  local row title cost tokens
  row=$(sqlite3 "$DB" "select title || char(9) || cost || char(9) || tokens_input from session where id='$SID';")
  [ -n "$row" ] || die "session not found: $SID"
  title=$(printf '%s' "$row" | cut -f1)
  cost=$(printf '%s' "$row" | cut -f2)
  tokens=$(printf '%s' "$row" | cut -f3)

  log "=== session ==="
  log "id:     $SID"
  log "title:  $title"
  log "cost:   $cost"
  log "tokens: $tokens input"
  log "db:     $DB"

  local json verdict
  json=$("$REPO/scripts/session-guard.sh" --json --no-log --session "$SID" 2>&1)
  [ -n "$json" ] || die "session-guard returned no JSON"
  verdict=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("verdict",""))' 2>&1) \
    || die "cannot parse session-guard JSON"
  case "$verdict" in
    FAIL|WARN) log "verdict: $verdict (handoff due)" ;;
    *) log "verdict: ${verdict:-unknown} (no handoff due)"; return 0 ;;
  esac

  log ""
  log "=== transcript (DB-direct) ==="
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s %s --out %s\n' "$REPO/scripts/extract-transcript.sh" "$SID" "$TRANSCRIPT"
    printf '[dry-run] %s --handoff --session %s --transcript %s --out %s --no-log\n' \
      "$REPO/scripts/session-guard.sh" "$SID" "$TRANSCRIPT" "$BRIEF"
    return 0
  fi
  "$REPO/scripts/extract-transcript.sh" "$SID" --out "$TRANSCRIPT" \
    || die "extract-transcript failed"
  [ -s "$TRANSCRIPT" ] || die "empty transcript: $TRANSCRIPT"
  log "wrote: $TRANSCRIPT ($(wc -c < "$TRANSCRIPT" | tr -d ' ') bytes)"

  log ""
  log "=== brief (redacted, leak-checked) ==="
  "$REPO/scripts/session-guard.sh" --handoff --session "$SID" \
    --transcript "$TRANSCRIPT" --out "$BRIEF" --no-log \
    || die "handoff-brief failed"
  [ -s "$BRIEF" ] || die "empty brief: $BRIEF"
  grep -q 'Handoff brief' "$BRIEF" || die "brief missing header: $BRIEF"
  local open
  open=$(awk '/^## Open question/{getline; print; exit}' "$BRIEF")
  [ -n "$open" ] || die "brief has an empty Open question (stale transcript?)"
  log "brief: $BRIEF ($(wc -c < "$BRIEF" | tr -d ' ') bytes)"
  log "open:  ${open:0:160}"

  log ""
  log "=== repos ==="
  for repo in "$REPO" "$RAG_DIR"; do
    log "$repo"
    git -C "$repo" status -sb | head -2
    git -C "$repo" log --oneline origin/main..HEAD | head -5
  done

  log ""
  log "=== ROTATE (do this now) ==="
  log "1. Pause this session."
  log "2. Open a FRESH session (never --fork/--continue)."
  log "3. Paste the brief: $BRIEF"
  log "4. On the host, after the fresh session:"
  log "   cd $RAG_DIR"
  log "   ./scripts/08-gated-recovery.sh --diagnose"
  log "   ./scripts/08-gated-recovery.sh --all --yes"
  log "   ~/.local/bin/push-opencode-repos.sh   # only if 08 did not push"
  return 0
}

main "$@"
exit $?
