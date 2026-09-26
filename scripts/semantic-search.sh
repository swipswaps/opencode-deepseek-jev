#!/usr/bin/env bash
#
# semantic-search.sh — on-disk FTS5 index over session parts, searchable
# across every session from the terminal. Same substrate the dashboard's
# /api/semantic builds in memory; this persists under data/search/ so it
# can be reused (for example as input to a future Laya/Jev reranker).
#
# Usage:
#   ./scripts/semantic-search.sh <query...>        # build if needed, then search
#   ./scripts/semantic-search.sh --rebuild         # rebuild the index only
#   ./scripts/semantic-search.sh [--limit N] <q...>
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

DB=""
IDX=""
LIMIT=15
REBUILD=0
FUZZY=0
QUERY=""

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

use() { printf 'usage: %s [--rebuild] [--fuzzy] [--limit N] <query...>\n' "$0"; }

build() {
    printf 'building %s\n' "$IDX"
    sqlite3 "$DB" <<SQL
ATTACH '$IDX' AS idx;
PRAGMA synchronous = OFF;
PRAGMA temp_store = MEMORY;
.once /dev/null
PRAGMA idx.journal_mode = MEMORY;
CREATE VIRTUAL TABLE IF NOT EXISTS idx.parts_fts USING fts5(part_id UNINDEXED, session_id UNINDEXED, type UNINDEXED, text);
DELETE FROM idx.parts_fts;
INSERT INTO idx.parts_fts(part_id, session_id, type, text)
    SELECT id, session_id, json_extract(data,'\$.type'),
           COALESCE(json_extract(data,'\$.text'), json_extract(data,'\$.state.input.command'), '')
    FROM main.part
    WHERE json_extract(data,'\$.text') IS NOT NULL
       OR json_extract(data,'\$.state.input.command') IS NOT NULL;
DROP TABLE IF EXISTS idx.meta;
CREATE TABLE idx.meta(n);
INSERT INTO idx.meta(n) SELECT COUNT(*) FROM idx.parts_fts;
SQL
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: index build returned %d\n' "$rc"
        return 1
    fi
    sqlite3 "$IDX" "SELECT printf('indexed %d parts', n) FROM meta;"
}

fts_terms() {
    local out="" w
    for w in $1; do
        w=$(printf '%s' "$w" | tr -cd '[:alnum:]_')
        [ -z "$w" ] && continue
        if [ -z "$out" ]; then out="\"$w\""; else out="$out AND \"$w\""; fi
    done
    printf '%s' "$out"
}

search() {
    local terms
    terms=$(fts_terms "$QUERY")
    if [ -z "$terms" ]; then
        printf 'empty query\n'
        return 2
    fi
    sqlite3 -header -column "$IDX" "
        ATTACH '$DB' AS src;
        SELECT substr(s.title,1,36) title, f.type,
               snippet(parts_fts,3,'[',']','...',10) snippet,
               printf('%.2f', bm25(parts_fts)) score
        FROM parts_fts f JOIN src.session s ON s.id = f.session_id
        WHERE parts_fts MATCH '$terms'
        ORDER BY bm25(parts_fts) LIMIT $LIMIT;"
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    DB="$REPO/data/opencode/opencode.db"
    IDX="$REPO/data/search/opencode-index.db"
    if [ ! -f "$DB" ]; then
        printf 'FAIL: no database at %s\n' "$DB"
        return 1
    fi
    if ! have sqlite3; then
        printf 'FAIL: sqlite3 required\n'
        return 1
    fi
    mkdir -p "$(dirname "$IDX")"

    while [ $# -gt 0 ]; do
        case "$1" in
            --rebuild) REBUILD=1; shift ;;
            --fuzzy) FUZZY=1; shift ;;
            --limit)
                case "${2:-}" in
                    ''|*[!0-9]*) use; return 2 ;;
                    *) LIMIT="$2"; shift 2 ;;
                esac
                ;;
            *) QUERY="$QUERY $1"; shift ;;
        esac
    done

    if [ "$REBUILD" -eq 1 ] || [ ! -f "$IDX" ]; then
        build || return 1
    fi

    if [ -z "$QUERY" ]; then
        if [ "$REBUILD" -eq 1 ]; then
            return 0
        fi
        use
        return 2
    fi

    if [ "$FUZZY" -eq 1 ]; then
        if [ ! -f "$REPO/scripts/fuzzy-search.py" ]; then
            printf 'FAIL: scripts/fuzzy-search.py missing\n'
            return 2
        fi
        python3 "$REPO/scripts/fuzzy-search.py" --index "$IDX" --db "$DB" --limit "$LIMIT" "$QUERY"
        return $?
    fi

    search
}

main "$@"
