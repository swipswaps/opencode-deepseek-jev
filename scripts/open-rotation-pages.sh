#!/usr/bin/env bash
#
# open-rotation-pages.sh — open the correct key page for each credential that
# still needs rotation, from the F1 audit matrix.
#
# Status (from secret-leak-response.sh + rotate-provider-keys.sh):
#   pending   SUBQ, Anthropic, LiteLLM (local)
#   done      DeepSeek, OPENCODE_SERVER_PASSWORD
#   optional  JEV (cloud disabled), Gemini (placeholder)
#
# Usage:
#   ./scripts/open-rotation-pages.sh --list
#   ./scripts/open-rotation-pages.sh --open
#   ./scripts/open-rotation-pages.sh --open --only subq,anthropic
#   ./scripts/open-rotation-pages.sh --all
#   ./scripts/open-rotation-pages.sh --dry-run
#
# Opener: xdg-open on the host (DISPLAY/XAUTHORITY), else cdp-tab.mjs, else
# print the URL. Values are never read or printed.

SCRIPT_NAME="open-rotation-pages.sh"
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-/home/owner/.Xauthority}"
OPEN_LOG="${OPEN_LOG:-/tmp/open-rotation-pages.log}"
export DISPLAY XAUTHORITY
OPENER="${OPENER:-auto}"
MODE="list"
ONLY=""
ALL=0
DRY_RUN=0
FAIL=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--list|--open] [--only a,b] [--all] [--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --list    print the matrix (default)"
  printf '%s\n' "  --open    open pending browser pages (SUBQ, Anthropic) and local LiteLLM"
  printf '%s\n' "  --only    comma list: subq,anthropic,litellm,deepseek,jev,gemini"
  printf '%s\n' "  --all     include done and optional entries"
  printf '%s\n' "  --dry-run print what would open"
  printf '%s\n' "  --opener  auto|xdg-open|cdp|print (env OPENER)"
  printf '%s\n' "  DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY"
  printf '%s\n' "  OPEN_LOG=$OPEN_LOG (xdg-open output; never values)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) MODE="list" ;;
      --open) MODE="open" ;;
      --only) shift; ONLY="$1" ;;
      --all) ALL=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --opener) shift; OPENER="$1" ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

# name|status|kind|env_name|url
matrix() {
  cat <<'EOF'
subq|pending|browser|SUBQ_API_KEY|https://console.subq.ai/
anthropic|pending|browser|ANTHROPIC_API_KEY|https://console.anthropic.com/settings/keys
litellm|pending|local|LITELLM_MASTER_KEY|http://127.0.0.1:4000/ui
deepseek|done|browser|DEEPSEEK_API_KEY|https://platform.deepseek.com/api_keys
jev|optional|browser|JEV_API_KEY|https://console.typesafe.ai/keys
gemini|optional|browser|GEMINI_API_KEY|https://aistudio.google.com/apikey
EOF
}

selected() {
  local name="$1"
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in
    *",$name,"*) return 0 ;;
  esac
  return 1
}

wanted() {
  local status="$1" kind="$2" name="$3"
  selected "$name" || return 1
  if [ "$ALL" -eq 1 ]; then return 0; fi
  [ "$status" = "pending" ] || return 1
  case "$kind" in
    browser|local) return 0 ;;
  esac
  return 1
}

open_url() {
  local url="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] open %s\n' "$url"
    return 0
  fi
  case "$OPENER" in
    xdg-open)
      if command -v setsid >/dev/null; then
        setsid xdg-open "$url" </dev/null >>"$OPEN_LOG" 2>&1 &
      else
        xdg-open "$url" </dev/null >>"$OPEN_LOG" 2>&1 &
      fi
      disown || true
      log "  launched; log: $OPEN_LOG"
      ;;
    cdp)
      local script
      script="$(cd -- "$(dirname -- "$0")" && pwd)/cdp-tab.mjs"
      [ -f "$script" ] || { err "cdp-tab.mjs not found"; return 1; }
      node "$script" open "$url" ;;
    print) printf 'open: %s\n' "$url"; return 0 ;;
    auto)
      if command -v xdg-open >/dev/null && [ -n "$DISPLAY" ]; then
        if command -v setsid >/dev/null; then
          setsid xdg-open "$url" </dev/null >>"$OPEN_LOG" 2>&1 &
        else
          xdg-open "$url" </dev/null >>"$OPEN_LOG" 2>&1 &
        fi
        disown || true
        log "  launched; log: $OPEN_LOG"
      elif [ -f "$(cd -- "$(dirname -- "$0")" && pwd)/cdp-tab.mjs" ]; then
        node "$(cd -- "$(dirname -- "$0")" && pwd)/cdp-tab.mjs" open "$url"
      else
        printf 'open: %s\n' "$url"
        return 1
      fi
      ;;
    *) die "unknown opener: $OPENER" ;;
  esac
}

main() {
  parse_args "$@"
  local name status kind env_name url rc
  if [ "$MODE" = "list" ]; then
    printf '%-10s %-9s %-8s %-24s %s\n' "NAME" "STATUS" "KIND" "ENV" "PAGE"
  fi
  while IFS='|' read -r name status kind env_name url; do
    [ -n "$name" ] || continue
    wanted "$status" "$kind" "$name" || continue
    if [ "$MODE" = "list" ]; then
      printf '%-10s %-9s %-8s %-24s %s\n' "$name" "$status" "$kind" "$env_name" "$url"
      continue
    fi
    log "open $name ($env_name, $status): $url"
    open_url "$url"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      log "  opened ($kind)"
    else
      err "  opener failed rc=$rc; open manually: $url"
      FAIL=$((FAIL + 1))
    fi
  done < <(matrix)
  [ "$FAIL" -eq 0 ] || return 1
  return 0
}

main "$@"
exit $?
