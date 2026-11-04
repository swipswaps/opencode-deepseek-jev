#!/usr/bin/env bash
#
# triage-dirty.sh — classify the working-tree's dirty files before committing.
#
# For every modified/untracked file it reports:
#   status (M/??), kind, syntax PASS/FAIL/SKIP, secret-scan PASS/FAIL/SKIP,
#   reference count (how many other files mention the basename), bucket, and
#   a recommendation: FIX / ARCHIVE / REVIEW / COMMIT.
#
# Exit 0 when no FIX is required; 1 when a file fails syntax or secret-scan;
# 2 on usage/IO error.
#
# Usage:
#   ./scripts/triage-dirty.sh
#   ./scripts/triage-dirty.sh --write data/observability/dirty-triage.txt
#   ./scripts/triage-dirty.sh --staged     # only git diff --cached files

SCRIPT_NAME="triage-dirty.sh"
REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "$0")/.." && pwd)}"
WRITE=""
STAGED=0
FAIL=0
ARCHIVE=0
REVIEW=0
COMMIT=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--write PATH] [--staged]"
  printf '%s\n' ""
  printf '%s\n' "  --write PATH  tee the report to PATH"
  printf '%s\n' "  --staged      triage only staged files"
  printf '%s\n' "  --help        this text"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --write) shift; WRITE="$1" ;;
      --staged) STAGED=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

syntax_check() {
  local f="$1" out rc
  case "$f" in
    *.sh) out=$(bash -n "$f" 2>&1); rc=$? ;;
    *.py) out=$(python3 -m py_compile "$f" 2>&1); rc=$? ;;
    *.mjs|*.js) out=$(node --check "$f" 2>&1); rc=$? ;;
    *.json) out=$(python3 -m json.tool "$f" 2>&1); rc=$? ;;
    *) printf 'SKIP'; return 0 ;;
  esac
  if [ "$rc" -eq 0 ]; then
    printf 'PASS'
  else
    printf 'FAIL'
    [ -n "$out" ] && printf '\n%s\n' "$out" >&2
  fi
}

secret_check() {
  local f="$1" out rc
  if [ -x "$REPO_DIR/scripts/secret-scan.sh" ]; then
    out=$("$REPO_DIR/scripts/secret-scan.sh" --paths "$f" --quiet 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'PASS'
    else
      printf 'FAIL'
      [ -n "$out" ] && printf '\n%s\n' "$out" >&2
    fi
  else
    printf 'SKIP'
  fi
}

ref_count() {
  local f="$1" base
  base=$(basename "$f")
  grep -rlF --exclude-dir=.git --exclude-dir=data --exclude-dir=node_modules \
    --exclude-dir=__pycache__ -- "$base" "$REPO_DIR" 2>&1 \
    | awk -v self="$REPO_DIR/$f" '$0 != self { n++ } END { print n + 0 }'
}

bucket_of() {
  local f="$1" base
  base=$(basename "$f")
  case "$base" in
    repro-*|*.orig|*.bak|*.rej) printf 'debug'; return ;;
  esac
  case "$f" in
    *.md|*/README.txt) printf 'docs'; return ;;
    *.json|*.yml|*.yaml) printf 'config'; return ;;
  esac
  printf 'code'
}

recommend() {
  local status="$1" syntax="$2" secret="$3" refs="$4" bucket="$5"
  if [ "$syntax" = "FAIL" ] || [ "$secret" = "FAIL" ]; then printf 'FIX'; return; fi
  if [ "$bucket" = "debug" ]; then printf 'ARCHIVE'; return; fi
  if [ "$status" = "??" ] && [ "$refs" -eq 0 ]; then printf 'REVIEW'; return; fi
  printf 'COMMIT'
}

main() {
  parse_args "$@"
  cd "$REPO_DIR" || die "cannot enter $REPO_DIR"
  local list
  if [ "$STAGED" -eq 1 ]; then
    list=$(git diff --cached --name-only --diff-filter=ACM)
  else
    list=$(git status --porcelain=v1 | awk '{ print $2 }' | grep -v '/$')
  fi
  [ -n "$list" ] || { log "working tree clean"; return 0; }

  local out
  out=$(mktemp) || die "mktemp failed"
  printf 'status syntax secret refs bucket rec file\n' > "$out"
  local f status syntax secret refs bucket rec
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if [ "$STAGED" -eq 1 ]; then status="A"; else status=$(git status --porcelain=v1 -- "$f" | awk '{ print $1 }'); fi
    syntax=$(syntax_check "$f")
    secret=$(secret_check "$f")
    refs=$(ref_count "$f")
    bucket=$(bucket_of "$f")
    rec=$(recommend "$status" "$syntax" "$secret" "$refs" "$bucket")
    case "$rec" in
      FIX) FAIL=$((FAIL + 1)) ;;
      ARCHIVE) ARCHIVE=$((ARCHIVE + 1)) ;;
      REVIEW) REVIEW=$((REVIEW + 1)) ;;
      COMMIT) COMMIT=$((COMMIT + 1)) ;;
    esac
    printf '%-6s %-6s %-6s %-4s %-7s %-8s %s\n' \
      "$status" "$syntax" "$secret" "$refs" "$bucket" "$rec" "$f" >> "$out"
  done <<EOF
$list
EOF

  log "=== dirty triage ($REPO_DIR) ==="
  printf '%-8s %-7s %-4s %s\n' "REC" "BUCKET" "REFS" "FILE"
  awk 'NR > 1 { printf "%-8s %-7s %-4s %s\n", $6, $5, $4, $7 }' "$out"
  log ""
  log "summary: commit=$COMMIT archive=$ARCHIVE review=$REVIEW fix=$FAIL"
  if [ -n "$WRITE" ]; then
    mkdir -p "$(dirname "$WRITE")" 2>&1
    cp "$out" "$WRITE" || die "could not write $WRITE"
    log "report: $WRITE"
  fi
  rm -f "$out"
  if [ "$FAIL" -gt 0 ]; then
    err "$FAIL file(s) failed syntax or secret-scan"
    return 1
  fi
  return 0
}

main "$@"
exit $?
