#!/usr/bin/env bash
#
# thinking.sh — live view of what the agent is doing while "thinking".
#
# Polls the opencode SQLite database and prints new activity as it is
# written: step-start/step-finish, tool calls (with running/completed/error
# state and the command), reasoning text, answer text, and patches. It is
# the equivalent of `tail -F`, but for the agent's internal state instead
# of its stdout.
#
# At startup it also prints the current session title and the agent's todo
# plan (status/priority). Only NEW activity is printed after that.
#
# Usage:
#   ./scripts/thinking.sh
#   THINKING_POLL=1 ./scripts/thinking.sh    poll every 1s (default 2s)
#
# Runs in the container and on the host (the database is mounted at
# data/opencode/opencode.db from either side). Requires node.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

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

db_path() { printf '%s' "$REPO/data/opencode/opencode.db"; }

state_dump() {
    node --no-warnings --experimental-sqlite -e '
        const { DatabaseSync } = require("node:sqlite");
        const db = new DatabaseSync(process.argv[1], { readOnly: true });
        const s = db.prepare("SELECT id, title FROM session ORDER BY time_created DESC LIMIT 1").get();
        console.log("session: " + (s && s.title ? s.title : "(none)"));
        const todos = s ? db.prepare("SELECT content, status, priority FROM todo WHERE session_id = ? ORDER BY position ASC").all(s.id) : [];
        console.log("todos:");
        for (const t of todos) console.log("  [" + t.status + "] (" + t.priority + ") " + t.content);
    ' "$(db_path)"
}

max_time() {
    node --no-warnings --experimental-sqlite -e '
        const { DatabaseSync } = require("node:sqlite");
        const db = new DatabaseSync(process.argv[1], { readOnly: true });
        const t = db.prepare("SELECT MAX(time_created) m FROM part").get();
        console.log(t.m || 0);
    ' "$(db_path)"
}

dump_since() {
    local since="$1"
    node --no-warnings --experimental-sqlite -e '
        const { DatabaseSync } = require("node:sqlite");
        const db = new DatabaseSync(process.argv[1], { readOnly: true });
        const since = Number(process.argv[2] || 0);
        const short = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "..." : s; };
        const rows = db.prepare("SELECT time_created, data FROM part WHERE time_created > ? ORDER BY time_created ASC").all(since);
        for (const r of rows) {
            let d; try { d = JSON.parse(r.data); } catch { continue; }
            const ts = new Date(r.time_created).toISOString().slice(11, 23);
            if (d.type === "tool") {
                const st = d.state && d.state.status ? d.state.status : "?";
                let cmd = "";
                if (d.state && d.state.input) cmd = d.state.input.command || d.state.input.description || "";
                console.log(`[${ts}] TOOL  ${d.tool}  [${st}]  ${short(cmd, 80)}`);
            } else if (d.type === "reasoning") {
                console.log(`[${ts}] REASON  ${short(d.text, 100)}`);
            } else if (d.type === "text") {
                console.log(`[${ts}] TEXT   ${short(d.text, 100)}`);
            } else if (d.type === "patch") {
                console.log(`[${ts}] PATCH  ${short((d.files || []).join(","), 60)}`);
            } else if (d.type === "step-start" || d.type === "step-finish") {
                console.log(`[${ts}] ${d.type.toUpperCase()}`);
            } else {
                console.log(`[${ts}] ${String(d.type).toUpperCase()}`);
            }
        }
        const t = db.prepare("SELECT MAX(time_created) m FROM part").get();
        console.log("@@MAX=" + (t.m || 0));
    ' "$(db_path)" "$since"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local db
    db=$(db_path)
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi
    if ! have node; then
        printf 'FAIL: node is required to read the database\n'
        return 1
    fi

    local poll="${THINKING_POLL:-2}"
    printf '=== thinking.sh ===\n'
    printf 'Watching: %s\n' "$db"
    printf 'Poll:     every %ss (Ctrl-C to stop)\n\n' "$poll"

    state_dump
    printf '\n--- live activity (new only) ---\n'

    local since
    since=$(max_time)
    local out max
    while :; do
        out=$(dump_since "$since")
        max=$(printf '%s\n' "$out" | grep '^@@MAX=' | tail -1)
        max=${max#@@MAX=}
        printf '%s\n' "$out" | grep -v '^@@MAX=' | grep -v '^$'
        if [ -n "$max" ] && [ "$max" -gt "$since" ]; then
            since=$max
        fi
        sleep "$poll"
    done
}

main "$@"
