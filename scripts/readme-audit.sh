#!/usr/bin/env bash
#
# readme-audit.sh — check that the reader-facing docs are complete and not
# link-rotten.
#
# Checks:
#   - root README has "what this is" and "start here"/"quick start"
#   - scripts/README.txt has "start here" and "conventions"
#   - scripts/vendor/README.txt has an "integrity baseline"
#   - docs/plans/README.md links back to the root README
#   - every tracked top-level scripts/*.{sh,py,mjs} appears in
#     scripts/README.txt or tools.json
#   - every local markdown link resolves (external/anchor links skipped)
#
# Usage:
#   ./scripts/readme-audit.sh
#   ./scripts/readme-audit.sh --repo /path/to/repo
#   ./scripts/readme-audit.sh --write data/observability/readme-audit.txt
#
# Exit 0 all pass, 1 a check failed, 2 usage.

SCRIPT_NAME="readme-audit.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=""
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--repo DIR] [--write PATH]"
  printf '%s\n' ""
  printf '%s\n' "  --repo DIR    repo to audit (default: this script's repo)"
  printf '%s\n' "  --write PATH  tee the report to PATH"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift; REPO="$1" ;;
      --write) shift; OUT="$1" ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

root_readme() {
  local f
  for f in "$REPO/README.md" "$REPO/README.txt"; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

check_root() {
  log "=== root README ==="
  local f
  f=$(root_readme) || { bad "no root README.md/README.txt"; return; }
  if grep -qiE 'what this is|what this is\.' "$f"; then
    ok "root README explains what this is"
  else
    bad "root README lacks a 'what this is' section"
  fi
  if grep -qiE 'start here|quick start' "$f"; then
    ok "root README has a start/quick-start section"
  else
    bad "root README lacks a 'start here'/'quick start' section"
  fi
}

check_catalogs() {
  log "=== script catalogs ==="
  local s="$REPO/scripts/README.txt"
  if [ -f "$s" ]; then
    grep -qi 'start here' "$s" && ok "scripts/README.txt has a start-here index" || bad "scripts/README.txt lacks a start-here index"
    grep -qi 'conventions' "$s" && ok "scripts/README.txt documents conventions" || bad "scripts/README.txt lacks conventions"
  else
    bad "missing scripts/README.txt"
  fi
  local v="$REPO/scripts/vendor/README.txt"
  if [ -d "$REPO/scripts/vendor" ]; then
    if [ -f "$v" ]; then
      grep -qi 'integrity baseline' "$v" && ok "vendor README pins an integrity baseline" || bad "vendor README lacks an integrity baseline"
    else
      bad "missing scripts/vendor/README.txt"
    fi
  else
    log "  SKIP  no scripts/vendor (not a vendored-asset repo)"
  fi
  local p="$REPO/docs/plans/README.md"
  if [ -f "$p" ]; then
    grep -q 'README.md' "$p" && ok "plans README links back to the repo" || bad "plans README has no repo link"
  fi
}

check_catalog_coverage() {
  log "=== catalog coverage ==="
  python3 - "$REPO" <<'PY'
import os, subprocess, sys
repo = sys.argv[1]
try:
    tracked = subprocess.check_output(["git", "-C", repo, "ls-files"], text=True).splitlines()
except Exception as e:
    print("  SKIP  not a git worktree:", e)
    raise SystemExit(0)
names = sorted(os.path.basename(p) for p in tracked
               if os.path.dirname(p) == "scripts" and p.rsplit(".", 1)[-1] in ("sh", "py", "mjs"))
readme = open(os.path.join(repo, "scripts/README.txt"), encoding="utf-8", errors="replace").read()
tools_p = os.path.join(repo, "scripts/tools.json")
tools = open(tools_p, encoding="utf-8", errors="replace").read() if os.path.exists(tools_p) else ""
missing = [n for n in names if n not in readme and n not in tools]
if missing:
    print("  FAIL  undocumented scripts: " + ", ".join(missing))
    raise SystemExit(1)
print("  PASS  all %d tracked scripts are documented" % len(names))
PY
  [ "$?" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
}

check_links() {
  log "=== local markdown links ==="
  python3 - "$REPO" <<'PY'
import os, re, sys
repo = sys.argv[1]
bad = 0
count = 0
for dirpath, dirnames, filenames in os.walk(repo):
    dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".venv", "data", "logs"}]
    for name in filenames:
        if not name.lower().endswith(".md"):
            continue
        path = os.path.join(dirpath, name)
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        text = re.sub(r"`[^`]*`", "", text)
        for m in re.finditer(r"\]\(([^)]+)\)", text):
            target = m.group(1).strip()
            if not target or target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = target.split("#", 1)[0]
            if not target or target in {"...", "..", "."}:
                continue
            count += 1
            if not os.path.exists(os.path.normpath(os.path.join(dirpath, target))):
                bad += 1
                print("  FAIL  %s -> %s" % (os.path.relpath(path, repo), target))
if bad:
    print("  FAIL  %d broken local link(s) of %d" % (bad, count))
    raise SystemExit(1)
print("  PASS  %d local link(s) resolve" % count)
PY
  [ "$?" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
}

main() {
  parse_args "$@"
  [ -d "$REPO" ] || die "not a directory: $REPO"
  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || die "cannot create the report directory"
    exec > >(tee "$OUT") 2>&1
  fi
  log "=== readme audit ($REPO) ==="
  check_root
  check_catalogs
  check_catalog_coverage
  check_links
  log ""
  log "summary: pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
exit $?
