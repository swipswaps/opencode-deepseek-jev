#!/usr/bin/env bash
# receipts-pages-monitor.sh — gh Pages/deploy/quality monitor for the receipts trio.
#
# Run on the host (needs gh auth, curl, python3, and a display for --open).
#
#   ./scripts/receipts-pages-monitor.sh
#   ./scripts/receipts-pages-monitor.sh --open
#   ./scripts/receipts-pages-monitor.sh --watch --open
#   ./scripts/receipts-pages-monitor.sh --json
set -uo pipefail

REPOS=(
  "receipts-ocr|main|https://swipswaps.github.io/receipts-ocr/"
  "receipts-ocr-rag|gh-pages|https://swipswaps.github.io/receipts-ocr-rag/"
  "receipts-ocr-rag-v2|master|https://swipswaps.github.io/receipts-ocr-rag-v2/"
)

OPEN=0
WATCH=0
JSON=0

usage() {
  printf '%s\n' "Usage: $0 [--open] [--watch] [--json]" "Checks Pages, deploy, quality, and HTTP for the receipts trio."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --open) OPEN=1 ;;
    --watch) WATCH=1 ;;
    --json) JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || { echo "gh not found" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

fail=0

for entry in "${REPOS[@]}"; do
  IFS='|' read -r repo branch url <<<"$entry"
  pages_json=$(gh api "repos/swipswaps/$repo/pages" || true)
  runs_json=$(gh run list --repo "swipswaps/$repo" --limit 12 --json databaseId,status,conclusion,workflowName,url || true)
  code=$(curl -L -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)

  pages=$(printf '%s' "$pages_json" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 print("%s|%s|%s" % (d.get("status"), d.get("build_type"), (d.get("source") or {}).get("branch","")))
except Exception:
 print("unavailable||")' || echo "unavailable||")

  runs=$(printf '%s' "$runs_json" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 def pick(names):
  for r in d:
   if r.get("workflowName") in names: return r
  return {}
 dep=pick({"Deploy to GitHub Pages","pages-build-deployment"})
 qual=pick({"Quality Gates"})
 def fmt(r):
  if not r: return "none|none|none|none"
  return "%s|%s|%s|%s" % (r.get("status"), r.get("conclusion"), r.get("databaseId"), r.get("url"))
 print(fmt(dep)+"|"+fmt(qual))
except Exception:
 print("none|none|none|none|none|none|none|none")' || echo "none|none|none|none|none|none|none|none")

  IFS='|' read -r pstatus pbuild pbranch <<<"$pages"
  IFS='|' read -r dstatus dconclusion did durl qstatus qconclusion qid qurl <<<"$runs"

  if [ "$JSON" -eq 1 ]; then
    printf '{"repo":"%s","branch":"%s","url":"%s","http":%s,"pages_status":"%s","pages_build":"%s","pages_branch":"%s","deploy_status":"%s","deploy_conclusion":"%s","deploy_id":"%s","quality_status":"%s","quality_conclusion":"%s"}\n' \
      "$repo" "$branch" "$url" "${code:-0}" "$pstatus" "$pbuild" "$pbranch" "$dstatus" "$dconclusion" "$did" "$qstatus" "$qconclusion"
  else
    printf '%-22s http=%s pages=%s/%s deploy=%s/%s quality=%s/%s\n' \
      "$repo" "${code:-000}" "${pstatus:-?}" "${pbuild:-?}" "${dstatus:-?}" "${dconclusion:-?}" "${qstatus:-?}" "${qconclusion:-?}"
    printf '  %s\n' "$url"
  fi

  if [ "${code:-000}" != "200" ]; then
    fail=1
  fi
  if [ "$dconclusion" = "failure" ] || [ "$qconclusion" = "failure" ]; then
    fail=1
  fi

  if [ "$WATCH" -eq 1 ] && [ -n "${did:-}" ] && [ "$did" != "none" ]; then
    gh run watch "$did" --repo "swipswaps/$repo" --interval 5 --exit-status || fail=1
  fi

  if [ "$OPEN" -eq 1 ]; then
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      xdg-open "$url" >/dev/null 2>&1 &
    else
      echo "  (--open skipped: no DISPLAY/WAYLAND_DISPLAY)" >&2
    fi
  fi
done

exit "$fail"
