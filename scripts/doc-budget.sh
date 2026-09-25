#!/usr/bin/env bash
#
# doc-budget.sh — measure the agent-facing doc corpus and cache its hash.
#
# The corpus (RULES, HANDOFF, README, TODO, DESIGN, scripts/README, skills) is
# read at the start of a session, so its size IS context cost. This measures it
# in tokens (~bytes/4), compares to a budget, and records a content hash so:
#   - growth is visible (a number, not a feeling)
#   - a re-audit is cheap: an unchanged hash means nothing to re-learn
# The ECC "context-budget" / "content-hash-cache-pattern", implemented locally.
#
#   ./scripts/doc-budget.sh [--json] [--fail]
#   DOC_BUDGET_TOKENS=40000 ./scripts/doc-budget.sh
#
# Exit 0 normally; exit 1 with --fail when over budget.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

JSON=0
FAIL_ON_BUDGET=0

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --fail) FAIL_ON_BUDGET=1; shift ;;
            -h|--help) printf 'usage: %s [--json] [--fail]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--json] [--fail]\n' "$0"; return 2 ;;
        esac
    done

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local budget="${DOC_BUDGET_TOKENS:-35000}"
    local files=() f
    for f in RULES.md TODO.md README.txt HANDOFF.md DESIGN.md scripts/README.txt; do
        [ -f "$REPO/$f" ] && files+=("$REPO/$f")
    done
    for f in "$REPO"/.opencode/skills/*/SKILL.md; do
        [ -f "$f" ] && files+=("$f")
    done

    local total_bytes=0 total_tokens=0 rows="" prev_hash=""
    local json_files=""
    for f in "${files[@]}"; do
        local b t rel
        b=$(wc -c < "$f")
        t=$((b / 4))
        rel=${f#"$REPO"/}
        total_bytes=$((total_bytes + b))
        total_tokens=$((total_tokens + t))
        rows="$rows$(printf '  %-40s %7s bytes  ~%s tokens\n' "$rel" "$b" "$t")"$'\n'
        json_files="$json_files$(printf '"%s":%s,' "$rel" "$t")"
    done

    local hash=""
    if have sha256sum; then
        hash=$(cat "${files[@]}" | sha256sum | awk '{print $1}')
    fi

    local docs_json="$REPO/data/observability/docs.json"
    if [ -f "$docs_json" ] && have python3; then
        prev_hash=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("hash",""))
except Exception:
    print("")' "$docs_json")
    fi
    local changed=1
    if [ -n "$hash" ] && [ "$hash" = "$prev_hash" ]; then changed=0; fi

    if [ "$JSON" -eq 1 ]; then
        printf '{"files":{%s},"total_bytes":%s,"total_tokens":%s,"budget":%s,"hash":"%s","changed":%s}\n' \
            "${json_files%,}" "$total_bytes" "$total_tokens" "$budget" "$hash" "$changed"
    else
        printf '=== doc-budget.sh ===\n'
        printf '%s' "$rows"
        printf 'total: %s bytes  ~%s tokens  budget %s\n' "$total_bytes" "$total_tokens" "$budget"
        if [ "$changed" -eq 1 ]; then
            printf 'corpus: changed since last record (re-read is warranted)\n'
        else
            printf 'corpus: unchanged since last record (nothing new to re-learn)\n'
        fi
        if [ "$total_tokens" -gt "$budget" ]; then
            printf 'WARN: corpus exceeds budget by ~%s tokens — consolidate or split docs\n' "$((total_tokens - budget))"
        fi
    fi

    if have python3; then
        mkdir -p "$REPO/data/observability"
        python3 - "$docs_json" "$total_tokens" "$budget" "$hash" "$changed" <<'PY_EOF'
import json, sys, datetime
path, tok, budget, h, changed = sys.argv[1:6]
json.dump({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "total_tokens": int(tok), "budget": int(budget), "hash": h, "changed": int(changed),
}, open(path, "w"), indent=2)
PY_EOF
    fi

    if [ "$FAIL_ON_BUDGET" -eq 1 ] && [ "$total_tokens" -gt "$budget" ]; then
        return 1
    fi
    return 0
}

main "$@"
