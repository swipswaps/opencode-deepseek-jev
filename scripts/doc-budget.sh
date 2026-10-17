#!/usr/bin/env bash
#
# doc-budget.sh — measure the agent-facing doc corpus and cache its hash.
#
# SPLIT BY ACTUAL SESSION-START COST (not by "is it a doc"):
#   TIER 1 (session-start, BUDGETED): the files the jev-harness skill tells a
#     fresh session to read — HANDOFF.md, RULES.md, TODO.md — plus the
#     auto-loaded skills (.opencode/skills/*/SKILL.md). This IS context cost.
#   TIER 2 (on-demand reference, REPORTED only): README.md, DESIGN.md,
#     scripts/README.txt. Read when needed, not at session start, so they are
#     NOT charged to the always-loaded budget (charging them made the WARN
#     permanently red — a cry-wolf the sentinel doctrine warns against).
#
# Measures tokens (~bytes/4), compares TIER 1 to DOC_BUDGET_TOKENS, and records
# a content hash so growth is visible and a re-audit is cheap (unchanged hash =
# nothing new to re-learn). The ECC "context-budget" / "content-hash-cache".
#
#   ./scripts/doc-budget.sh [--json] [--fail] [--self-test]
#   DOC_BUDGET_TOKENS=40000 ./scripts/doc-budget.sh
#   DOC_BUDGET_REPO=<dir> ./scripts/doc-budget.sh   # test seam
#
# Exit 0 normally; exit 1 with --fail when TIER 1 is over budget.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

JSON=0
FAIL_ON_BUDGET=0
SELFTEST=0

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

# Print "rel|bytes|tokens|tier" for one file, or nothing when absent.
measure() {
    local f="$1" repo="$2" tier="$3"
    [ -f "$f" ] || return 0
    local b t rel
    b=$(wc -c < "$f")
    t=$((b / 4))
    rel=${f#"$repo"/}
    printf '%s|%s|%s|%s\n' "$rel" "$b" "$t" "$tier"
}

run() {
    local REPO="$1" budget="$2" total_bytes=0 total_tokens=0 t1_tokens=0 t2_tokens=0
    local rows="" prev_hash="" hash="" changed=1

    local t1=() t2=() f
    for f in HANDOFF.md RULES.md TODO.md; do
        [ -f "$REPO/$f" ] && t1+=("$REPO/$f")
    done
    for f in "$REPO"/.opencode/skills/*/SKILL.md; do
        [ -f "$f" ] && t1+=("$f")
    done
    for f in README.md DESIGN.md scripts/README.txt; do
        [ -f "$REPO/$f" ] && t2+=("$REPO/$f")
    done

    local line rel b t tier
    for f in "${t1[@]}"; do
        line=$(measure "$f" "$REPO" 1)
        [ -n "$line" ] || continue
        IFS='|' read -r rel b t tier <<< "$line"
        t1_tokens=$((t1_tokens + t))
        total_bytes=$((total_bytes + b)); total_tokens=$((total_tokens + t))
        rows="$rows$(printf '  T1 %-42s %7s B  ~%s tok\n' "$rel" "$b" "$t")"$'\n'
    done
    for f in "${t2[@]}"; do
        line=$(measure "$f" "$REPO" 2)
        [ -n "$line" ] || continue
        IFS='|' read -r rel b t tier <<< "$line"
        t2_tokens=$((t2_tokens + t))
        total_bytes=$((total_bytes + b)); total_tokens=$((total_tokens + t))
        rows="$rows$(printf '  T2 %-42s %7s B  ~%s tok\n' "$rel" "$b" "$t")"$'\n'
    done

    if have sha256sum; then
        hash=$(cat "${t1[@]}" "${t2[@]}" | sha256sum | awk '{print $1}')
    fi
    local docs_json="$REPO/data/observability/docs.json"
    if [ -f "$docs_json" ] && have python3; then
        prev_hash=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("hash",""))
except Exception:
    print("")' "$docs_json")
    fi
    if [ -n "$hash" ] && [ "$hash" = "$prev_hash" ]; then changed=0; fi

    local over=0
    [ "$t1_tokens" -gt "$budget" ] && over=1

    if [ "$JSON" -eq 1 ]; then
        printf '{"tier1_tokens":%s,"tier2_tokens":%s,"total_bytes":%s,"total_tokens":%s,"budget":%s,"over":%s,"hash":"%s","changed":%s}\n' \
            "$t1_tokens" "$t2_tokens" "$total_bytes" "$total_tokens" "$budget" "$over" "$hash" "$changed"
    else
        printf '=== doc-budget.sh ===\n'
        printf '%s' "$rows"
        printf 'tier 1 (session-start, budgeted): ~%s tokens  budget %s\n' "$t1_tokens" "$budget"
        printf 'tier 2 (on-demand reference)   : ~%s tokens (not budgeted)\n' "$t2_tokens"
        printf 'total: %s bytes  ~%s tokens\n' "$total_bytes" "$total_tokens"
        if [ "$changed" -eq 1 ]; then
            printf 'corpus: changed since last record (re-read is warranted)\n'
        else
            printf 'corpus: unchanged since last record (nothing new to re-learn)\n'
        fi
        if [ "$over" -eq 1 ]; then
            printf 'WARN: tier-1 corpus exceeds budget by ~%s tokens — consolidate or split docs\n' "$((t1_tokens - budget))"
        else
            printf 'OK: tier-1 corpus within budget (~%s tokens headroom)\n' "$((budget - t1_tokens))"
        fi
    fi

    if have python3; then
        mkdir -p "$REPO/data/observability"
        python3 - "$docs_json" "$t1_tokens" "$t2_tokens" "$total_tokens" "$budget" "$hash" "$changed" <<'PY_EOF'
import json, sys, datetime
path, t1, t2, tot, budget, h, changed = sys.argv[1:8]
json.dump({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "tier1_tokens": int(t1), "tier2_tokens": int(t2), "total_tokens": int(tot),
    "budget": int(budget), "hash": h, "changed": int(changed),
}, open(path, "w"), indent=2)
PY_EOF
    fi

    if [ "$FAIL_ON_BUDGET" -eq 1 ] && [ "$over" -eq 1 ]; then
        return 1
    fi
    return 0
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d)
    mkdir -p "$work/docker" "$work/.opencode/skills/x" "$work/data/observability" || { printf 'FAIL mkdir\n'; return 1; }
    printf '%s\n' '{}' > "$work/opencode.json"
    printf '%s\n' 'FROM scratch' > "$work/docker/Dockerfile"
    printf 'HANDOFF tier1 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/HANDOFF.md"
    printf 'RULES tier1 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/RULES.md"
    printf 'TODO tier1 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/TODO.md"
    printf 'SKILL tier1 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/.opencode/skills/x/SKILL.md"
    printf 'README tier2 %.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 > "$work/README.md"
    printf 'DESIGN tier2 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/DESIGN.md"
    mkdir -p "$work/scripts"
    printf 'scripts tier2 %.0s' 1 2 3 4 5 6 7 8 9 10 > "$work/scripts/README.txt"
    local o=""
    o=$(DOC_BUDGET_REPO="$work" DOC_BUDGET_TOKENS=10000 bash "${BASH_SOURCE[0]}" --json 2>&1)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "tier1_tokens" in d and "tier2_tokens" in d and "total_tokens" in d and "budget" in d, "keys"; assert d["over"] == 0, "tier1 small should fit"; assert d["tier1_tokens"] < d["tier2_tokens"], "fixture tiers"; assert d["total_tokens"] == d["tier1_tokens"] + d["tier2_tokens"], "sum"' \
        || { printf 'FAIL json contract / tiering\n'; fail=1; }
    o=$(DOC_BUDGET_REPO="$work" DOC_BUDGET_TOKENS=1 bash "${BASH_SOURCE[0]}" --fail 2>&1)
    [ "$?" -eq 1 ] || { printf 'FAIL --fail over tier-1 should exit 1\n'; fail=1; }
    printf '%s' "$o" | grep -q 'WARN: tier-1 corpus exceeds' || { printf 'FAIL over-budget WARN missing\n'; fail=1; }
    o=$(DOC_BUDGET_REPO="$work" DOC_BUDGET_TOKENS=10000 bash "${BASH_SOURCE[0]}" --fail 2>&1)
    [ "$?" -eq 0 ] || { printf 'FAIL --fail under budget should exit 0\n'; fail=1; }
    printf '%s' "$o" | grep -q 'OK: tier-1 corpus within budget' || { printf 'FAIL headroom line missing\n'; fail=1; }
    rm -f "$work/HANDOFF.md" "$work/RULES.md" "$work/TODO.md" "$work/README.md" "$work/DESIGN.md" "$work/opencode.json" "$work/docker/Dockerfile" "$work/scripts/README.txt" "$work/.opencode/skills/x/SKILL.md" "$work/data/observability/docs.json"
    rmdir "$work/data/observability" "$work/data" "$work/scripts" "$work/.opencode/skills/x" "$work/.opencode/skills" "$work/.opencode" "$work/docker" "$work"
    if [ "$fail" -eq 0 ]; then printf 'doc-budget: self-test PASS\n'; else printf 'doc-budget: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --fail) FAIL_ON_BUDGET=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h|--help) printf 'usage: %s [--json] [--fail] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--json] [--fail] [--self-test]\n' "$0"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi

    local REPO
    if [ -n "${DOC_BUDGET_REPO:-}" ]; then
        REPO="$DOC_BUDGET_REPO"
    else
        REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
        [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local budget="${DOC_BUDGET_TOKENS:-35000}"
    run "$REPO" "$budget"
    return "$?"
}

main "$@"
