#!/usr/bin/env bash
#
# test-patterns.sh — gate for the tool-sequence substrate behind the
# "patterns view (tool-sequence n-grams)" candidate. Read-only over the
# opencode SQLite database: it proves that (a) tool calls are stored as
# `part` rows with JSON `data.type='tool'` / `data.tool` /
# `data.state.status`, and (b) an ordered per-session tool sequence can
# be recovered and turned into n-gram counts with a single window query.
#
# This is a data-layer proof, not the visualisation. It fails (non-zero)
# unless the tool-use method is real: >=1 tool part, >=1 distinct tool,
# and >=1 bigram across the whole corpus. It also reports the error-tool
# share, which feeds the "error-prone chains" view.
#
# Runs in the container and on the host (the database is mounted at
# data/opencode/opencode.db from either side). Requires node.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0

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

ok()  { PASS=$((PASS+1)); printf 'ts=%s level=INFO  status=PASS msg=%s\n' "$(date -u +%H:%M:%S)" "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'ts=%s level=ERROR status=FAIL msg=%s\n' "$(date -u +%H:%M:%S)" "$1"; }

get() {
    local k="$1" f="$2" a b
    while IFS='=' read -r a b; do
        [ "$a" = "$k" ] && { printf '%s' "$b"; return 0; }
    done < "$f"
    printf '0'
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local db="$REPO/data/opencode/opencode.db"
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi
    if ! have node; then
        printf 'FAIL: node is required to read the database\n'
        return 1
    fi

    local work
    work=$(mktemp -d)

    printf '=== test-patterns.sh ===\n'
    printf 'db: %s\n' "$db"

    node --no-warnings --experimental-sqlite - "$db" > "$work/out.txt" 2>&1 <<'NODE_EOF'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2], { readOnly: true });
const toolParts = db.prepare("SELECT COUNT(*) n FROM part WHERE json_extract(data, '$.type') = 'tool'").get();
const distinct = db.prepare("SELECT COUNT(DISTINCT json_extract(data, '$.tool')) n FROM part WHERE json_extract(data, '$.type') = 'tool'").get();
const errs = db.prepare("SELECT COUNT(*) n FROM part WHERE json_extract(data, '$.type') = 'tool' AND json_extract(data, '$.state.status') = 'error'").get();
const seqs = db.prepare("SELECT COUNT(*) n FROM (SELECT session_id FROM part WHERE json_extract(data,'$.type')='tool' GROUP BY session_id HAVING COUNT(*) >= 2)").get();
const bigrams = db.prepare(
  "SELECT tool || '->' || next_tool AS bigram, COUNT(*) n FROM (SELECT session_id, json_extract(data,'$.tool') tool, lead(json_extract(data,'$.tool')) OVER (PARTITION BY session_id ORDER BY time_created) next_tool FROM part WHERE json_extract(data,'$.type')='tool') WHERE next_tool IS NOT NULL GROUP BY bigram ORDER BY n DESC LIMIT 10"
).all();
console.log("tool_parts=" + toolParts.n);
console.log("distinct_tools=" + distinct.n);
console.log("error_tool_parts=" + errs.n);
console.log("sessions_with_seq=" + seqs.n);
console.log("bigram_count=" + bigrams.length);
if (bigrams[0]) { console.log("top_bigram=" + bigrams[0].bigram); console.log("top_bigram_n=" + bigrams[0].n); }
else { console.log("top_bigram="); console.log("top_bigram_n=0"); }
for (const r of bigrams) console.log("  " + r.bigram + "  x" + r.n);
NODE_EOF

    if [ -s "$work/out.txt" ]; then
        ok 'node read the database (tool-use method reachable)'
    else
        bad 'node read the database (tool-use method reachable)'
    fi

    local tool_parts distinct_tools error_tool_parts sessions_with_seq bigram_count top_bigram top_bigram_n
    tool_parts=$(get tool_parts "$work/out.txt")
    distinct_tools=$(get distinct_tools "$work/out.txt")
    error_tool_parts=$(get error_tool_parts "$work/out.txt")
    sessions_with_seq=$(get sessions_with_seq "$work/out.txt")
    bigram_count=$(get bigram_count "$work/out.txt")
    top_bigram=$(get top_bigram "$work/out.txt")
    top_bigram_n=$(get top_bigram_n "$work/out.txt")

    printf 'tool parts: %s (distinct tools %s, error %s)\n' "$tool_parts" "$distinct_tools" "$error_tool_parts"
    printf 'sessions with a tool sequence (>=2 tools): %s\n' "$sessions_with_seq"
    printf 'bigrams: %s  (top: %s x%s)\n' "$bigram_count" "$top_bigram" "$top_bigram_n"

    if [ "$tool_parts" -gt 0 ]; then ok 'tool parts present'; else bad 'tool parts present'; fi
    if [ "$distinct_tools" -gt 0 ]; then ok 'distinct tools present'; else bad 'distinct tools present'; fi
    if [ "$bigram_count" -gt 0 ]; then ok 'at least one tool bigram'; else bad 'at least one tool bigram'; fi
    if [ -n "$top_bigram" ]; then
        case "$top_bigram" in
            *"->"*) ok 'top bigram is a tool->tool edge';;
            *) bad 'top bigram is a tool->tool edge';;
        esac
    else
        bad 'top bigram is a tool->tool edge'
    fi
    if [ "$error_tool_parts" -gt 0 ]; then ok 'error tool parts present (error-chain signal available)'; else bad 'error tool parts present (error-chain signal available)'; fi

    rm -f "$work/out.txt"
    rmdir "$work"

    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
