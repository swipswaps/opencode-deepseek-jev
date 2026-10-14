#!/usr/bin/env bash
#
# handoff-brief.sh — deterministic carry-over brief from a session transcript.
#
# An over-budget session cannot be fixed in place: every turn re-sends the
# whole context, and --fork/--continue copies the context back into the new
# session. The way out is a FRESH session plus a small brief. This script
# builds that brief deterministically (no model call, no spend) from the
# existing transcript (logs/transcript-<id>.md, else the re-extract-session.sh
# artifact logs/ses_<id>.txt). If no transcript exists it refuses and points
# at re-extract-session.sh instead of guessing.
#
# The brief is egress-shaped (pasted into a new session, possibly quoted
# onward), so every extracted field is passed through scripts/redact.mjs:
# transcripts can contain pasted `env` output with live keys.
#
#   ./scripts/handoff-brief.sh <session-id> [--out FILE]
#   ./scripts/handoff-brief.sh <session-id> --model NAME
#       policy-check NAME via scripts/models.py (must be ALLOW), then print
#       the ready brief-prompt plus the exact spend command. NEVER executes a
#       model call itself: auto-spend from a recovery script would break the
#       fail-closed spend doctrine; the operator runs the command.
#   ./scripts/handoff-brief.sh --self-test   # offline fixture
#
# Exit 0 on brief, 1 when no transcript exists, 2 on usage errors.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

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

have() { command -v "$1" >/dev/null 2>&1; }

find_transcript() {
    # Transcripts may carry a shortened id (transcript-ses_<prefix>.md), so
    # match by filename containment first, then by the "# <id>" header line.
    local id="$1" f head1
    for f in "$REPO"/logs/transcript-*.md "$REPO"/logs/ses_*.txt; do
        [ -f "$f" ] || continue
        case "$f" in
            *"$id"*) printf '%s' "$f"; return 0 ;;
        esac
        head1=$(head -n 1 "$f" 2>&1 || true)
        case "$head1" in
            *"$id"*) printf '%s' "$f"; return 0 ;;
        esac
    done
}

extract_brief() {
    # extract_brief FILE ID -> markdown brief on stdout (unredacted; caller
    # pipes through redact.mjs). Pure python3, stdlib only.
    python3 - "$1" "$2" << 'PYEOF'
import re, sys
path, sid = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
users, assistants, tools = [], [], []
cur_role, cur_head, cur_buf = None, "", []
def flush():
    if cur_role == "user" and cur_buf:
        users.append((cur_head, " ".join(cur_buf).strip()))
    elif cur_role == "assistant" and cur_buf:
        assistants.append((cur_head, " ".join(cur_buf).strip()))
for line in text.splitlines():
    m = re.match(r"##\s+(user|assistant)\s+(\S+)", line)
    if m:
        flush()
        cur_role, cur_head, cur_buf = m.group(1), m.group(2), []
    elif cur_role:
        cur_buf.append(line.strip())
        tm = re.match(r"\[(\w[\w-]*)\s+call_", line.strip())
        if tm:
            tools.append(tm.group(1))
flush()
def short(s, n):
    s = re.sub(r"\s+", " ", s).strip()
    return s[:n] + ("..." if len(s) > n else "")
seen, uniq_tools = set(), []
for t in tools:
    if t not in seen:
        seen.add(t)
        uniq_tools.append(t)
print("# Handoff brief \u2014 %s" % sid)
print("Source: %s (%d bytes, %d user turns); full history stays there, NOT copied here." % (path, len(text), len(users)))
print("")
print("## Goal")
print(short(users[0][1], 500) if users else "(no user turn found)")
print("")
print("## Key findings (last assistant text)")
print(short(assistants[-1][1], 800) if assistants else "(no assistant text found)")
print("")
print("## Recent asks")
for head, body in users[-8:]:
    print("- " + short(body, 200))
print("")
print("## Tools used")
print(", ".join(uniq_tools) if uniq_tools else "(none seen)")
print("")
print("## Open question (last user turn)")
print(short(users[-1][1], 500) if users else "(none)")
print("")
print("Do NOT --fork/--continue %s; start a fresh session and paste this brief." % sid)
PYEOF
}

policy_allows() {
    # policy_allows NAME -> 0 iff scripts/models.py verdict is ALLOW.
    have python3 || return 1
    [ -f "$REPO/scripts/models.py" ] || return 1
    local cat="$REPO/data/observability/models.json" v=""
    if [ -f "$cat" ]; then
        v=$(python3 "$REPO/scripts/models.py" --catalog "$cat" --current "$1" --json 2>&1 \
            | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["verdict"])
except Exception:
    print("UNKNOWN")')
    else
        v=$(python3 - "$REPO/models.policy.json" "$1" << 'PYEOF2'
import json, sys
try:
    p = json.load(open(sys.argv[1]))
except Exception:
    print("UNKNOWN"); raise SystemExit
m = sys.argv[2]
allow, deny = p.get("allow", []), p.get("deny", [])
s = m.split("/")[-1]
if m in deny or s in deny:
    print("BLOCK")
elif m in allow or s in allow:
    print("ALLOW")
else:
    print("UNKNOWN")
PYEOF2
        )
    fi
    [ "$v" = "ALLOW" ]
}

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    cat > "$work/transcript-s_fix.md" << 'FIXEOF'
# s_fix - fixture

## user m1 2026-10-12 10:00:00 UTC

goal line one two three

## assistant m2 2026-10-12 10:01:00 UTC

[reasoning] thinking

finding alpha here

[bash call_abc123]
input: {"command": "ls"}
output: ok

## user m3 2026-10-12 10:02:00 UTC

open question here?
FIXEOF
    local o=""
    o=$(bash "${BASH_SOURCE[0]}" --transcript "$work/transcript-s_fix.md" s_fix 2>&1 || true)
    printf '%s' "$o" | grep -q '## Goal' || { printf 'FAIL goal section\n'; fail=1; }
    printf '%s' "$o" | grep -q 'goal line one' || { printf 'FAIL goal text\n'; fail=1; }
    printf '%s' "$o" | grep -q 'finding alpha' || { printf 'FAIL findings text\n'; fail=1; }
    printf '%s' "$o" | grep -q 'open question here' || { printf 'FAIL open question\n'; fail=1; }
    printf '%s' "$o" | grep -q 'Do NOT --fork/--continue' || { printf 'FAIL no-fork rule\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" s_does_not_exist > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL missing transcript exits 1\n'; fail=1; }
    o=$(bash "${BASH_SOURCE[0]}" --transcript "$work/transcript-s_fix.md" s_fix --model "opencode/muse-spark-1.3-contributor-free" 2>&1 || true)
    printf '%s' "$o" | grep -q 'refusing: model .* not ALLOW' || { printf 'FAIL deny-listed model refused\n'; fail=1; }
    printf '%s\n' '## user m9 2026-10-12 11:00:00 UTC' 'leak check' 'DEEPSEEK_API_KEY=sk-cccccccccccccccccccccccccccccc' >> "$work/transcript-s_fix.md"
    o=$(bash "${BASH_SOURCE[0]}" --transcript "$work/transcript-s_fix.md" s_fix 2>&1 || true)
    printf '%s' "$o" | grep -q 'WARNING: .* holds secret-shaped lines at rest' || { printf 'FAIL at-rest warning\n'; fail=1; }
    printf '%s' "$o" | grep -q 'rotate-api-keys.sh' || { printf 'FAIL rotation guidance\n'; fail=1; }
    printf '%s' "$o" | grep -q 'cccccccccccccccccccccccccccccc' && { printf 'FAIL warning leaked value\n'; fail=1; }
    rm -f "$work/transcript-s_fix.md"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'handoff-brief: self-test PASS\n'; else printf 'handoff-brief: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local SESSION="" OUTF="" MODEL="" TRANSCRIPT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return "$?" ;;
            --out) OUTF="${2:-}"; shift 2 ;;
            --out=*) OUTF="${1#--out=}"; shift ;;
            --model) MODEL="${2:-}"; shift 2 ;;
            --model=*) MODEL="${1#--model=}"; shift ;;
            --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
            --transcript=*) TRANSCRIPT="${1#--transcript=}"; shift ;;
            -h | --help)
                printf 'usage: %s <session-id> [--out FILE] [--model NAME] [--self-test]\n' "$0"
                return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) SESSION="$1"; shift ;;
        esac
    done
    [ -n "$SESSION" ] || { printf 'usage: %s <session-id> [--out FILE] [--model NAME]\n' "$0"; return 2; }
    local TR=""
    if [ -n "$TRANSCRIPT" ]; then
        TR="$TRANSCRIPT"
    else
        TR=$(find_transcript "$SESSION")
    fi
    if [ -z "$TR" ] || [ ! -f "$TR" ]; then
        # DB-direct fallback: extract-transcript.sh reads the store (no browser),
        # unlike re-extract-session.sh which needs a reachable CDP/browser. When
        # a transcript is simply missing, generate it here and retry the lookup.
        if [ -x "$REPO/scripts/extract-transcript.sh" ]; then
            if "$REPO/scripts/extract-transcript.sh" "$SESSION" >&2; then
                TR=$(find_transcript "$SESSION")
            fi
        fi
    fi
    if [ -z "$TR" ] || [ ! -f "$TR" ]; then
        printf 'FAIL: no transcript for %s\n' "$SESSION"
        printf 'tried logs/transcript-*.md, logs/ses_*.txt, and DB-direct extract-transcript.sh\n'
        printf 'if the store has no such session: ./scripts/re-extract-session.sh %s (needs a browser)\n' "$SESSION"
        return 1
    fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local brief=""
    brief=$(extract_brief "$TR" "$SESSION")
    if have node && [ -f "$REPO/scripts/redact.mjs" ]; then
        brief=$(printf '%s' "$brief" | node "$REPO/scripts/redact.mjs" 2>&1 || printf '%s' "$brief")
    fi
    # The transcript itself may hold live keys at rest (pasted env blocks);
    # the brief above is redacted, but the source is not. Scan it and warn.
    local scanwarn=""
    if [ -x "$REPO/scripts/secret-scan.sh" ]; then
        if ! "$REPO/scripts/secret-scan.sh" --paths "$TR" --quiet > /dev/null 2>&1; then
            scanwarn="WARNING: $TR holds secret-shaped lines at rest. Rotate before sharing it further: ./scripts/rotate-api-keys.sh (revoke at https://platform.deepseek.com/api_keys and https://console.typesafe.ai/keys), then re-run ./scripts/secret-scan.sh until clean."
        fi
    fi
    if [ -n "$MODEL" ]; then
        if ! policy_allows "$MODEL"; then
            printf 'refusing: model %s not ALLOW under models.policy.json\n' "$MODEL"
            return 1
        fi
        local chars=""
        chars=$(printf '%s' "$brief" | wc -c | tr -d ' ')
        if [ -n "$OUTF" ]; then
            printf '%s\n' "$brief" > "$OUTF"
            printf 'brief: %s (%s chars)\n' "$OUTF" "$chars"
        else
            printf '%s\n' "$brief"
        fi
        [ -n "$scanwarn" ] && printf '\n%s\n' "$scanwarn"
        printf '\n--model %s is ALLOW; to spend, run:\n' "$MODEL"
        printf '  ./scripts/ask.sh --json "Summarize into goal/findings/open-question: <paste brief above>"\n'
        printf 'estimate: brief ~%s chars (~%s tokens), synthesis adds one model turn\n' "$chars" "$((chars / 4))"
        return 0
    fi
    if [ -n "$OUTF" ]; then
        printf '%s\n' "$brief" > "$OUTF"
        printf 'brief: %s\n' "$OUTF"
    else
        printf '%s\n' "$brief"
    fi
    [ -n "$scanwarn" ] && printf '\n%s\n' "$scanwarn"
    return 0
}

main "$@"
