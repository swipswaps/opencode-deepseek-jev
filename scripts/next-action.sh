#!/usr/bin/env bash
#
# next-action.sh — the durable "where are we / what changed / what's next".
#
# pi-durable's law is "storage is the source of truth; a new process opens the
# same storage and continues". This is the missing CONSUMER of that storage for
# the dev loop: it reads the durable artifacts a session already leaves behind —
# git state, data/observability/last-gate.json, the observability ledger, TODO's
# queue, and docs.json — and prints the exact next unit plus the proof of
# progression since the last gate. A fresh session starts here, with zero
# re-derivation (no transcript replay, no diary: the store already says it).
#
# Read-only. No model call, no network. Sources (all optional; absent = skipped):
#   git                                   rev, ahead, dirty
#   data/observability/last-gate.json     last harness.sh gate verdict
#   $LEDGER_DB (observability.db)         last GATE_START rev + events since
#   TODO.md                               in-progress `[~]` then top Queue `[ ]`
#   data/observability/docs.json          tier-1 doc budget
#
#   ./scripts/next-action.sh [--json] [--self-test]
#
# Env seams: NEXT_ACTION_REPO (repo root), LEDGER_DB (ledger path).
# Exit 0 always (this is guidance, not a gate); 2 on usage/resolve error.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
# No subprocess.run. No bare kill. printf only. main() wrapper.
#
set -o pipefail

JSON=0
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

report() {
    # report REPO HEAD AHEAD MODIFIED UNTRACKED COMMITS — one python pass.
    local REPO="$1" HEAD="$2" AHEAD="$3" DIRTY="$4" UNTRACKED="$5" COMMITS="$6"
    NEXT_ACTION_REPO="$REPO" NA_HEAD="$HEAD" NA_AHEAD="$AHEAD" NA_DIRTY="$DIRTY" \
    NA_UNTRACKED="$UNTRACKED" NA_COMMITS="$COMMITS" NA_JSON="$JSON" \
    LEDGER_DB="${LEDGER_DB:-$REPO/data/observability/observability.db}" \
    python3 - <<'PY'
import json, os, sqlite3, datetime, re, time

repo = os.environ["NEXT_ACTION_REPO"]
head = os.environ.get("NA_HEAD", "?")
ahead = os.environ.get("NA_AHEAD", "?")
dirty = os.environ.get("NA_DIRTY", "?")
untracked = os.environ.get("NA_UNTRACKED", "0")
commits = [c for c in (os.environ.get("NA_COMMITS", "") or "").splitlines() if c.strip()]
as_json = os.environ.get("NA_JSON") == "1"

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None

gate = load(os.path.join(repo, "data/observability/last-gate.json")) or {}
docs = load(os.path.join(repo, "data/observability/docs.json")) or {}

# TODO: in-progress `[~]` wins; else the top unchecked `[ ]` inside the Queue.
next_text, next_source = None, None
try:
    todo = open(os.path.join(repo, "TODO.md"), encoding="utf-8").read()
    for line in todo.splitlines():
        m = re.match(r"^- \[~\] (.+)$", line)
        if m:
            next_text, next_source = m.group(1).strip(), "TODO.md in-progress"
            break
    if next_text is None:
        inq = False
        for line in todo.splitlines():
            if re.match(r"^## Queue", line):
                inq = True; continue
            if inq and re.match(r"^## ", line):
                break
            if inq:
                m = re.match(r"^- \[ \] (.+)$", line)
                if m:
                    next_text, next_source = m.group(1).strip(), "TODO.md Queue"
                    break
except Exception:
    pass

# Ledger: last GATE_START (rev+ts) and how many events since.
gate_rev, gate_ts, events_since = "", "", 0
db = os.environ.get("LEDGER_DB", "")
if db and os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        rows = con.execute("SELECT ts,type,verdict,detail,rev FROM ledger ORDER BY ts").fetchall()
        for ts, typ, verdict, detail, rev in rows:
            if typ == "GATE_START":
                gate_rev, gate_ts = rev or "", ts or ""
        if gate_ts:
            events_since = sum(1 for (ts, *_rest) in rows if ts and ts > gate_ts)
    except Exception:
        pass

# External issues (E2): the latest ISSUE_STATE per resource, read back by
# issue-bridge.py. A non-CLOSED issue is a live external unit — surfaced here so
# a resuming session sees the hand-off's fate without re-deriving it.
external = []
if db and os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        latest = {}
        for resource, verdict, ts in con.execute(
                "SELECT resource,verdict,ts FROM ledger WHERE type='ISSUE' ORDER BY id"):
            latest[resource] = (verdict, ts)
        for resource, verdict, ts in con.execute(
                "SELECT resource,verdict,ts FROM ledger WHERE type='ISSUE_STATE' ORDER BY id"):
            latest[resource] = (verdict, ts)
        external = [{"resource": r, "state": v[0], "ts": v[1]}
                    for r, v in latest.items() if (v[0] or "").upper() != "CLOSED"]
    except Exception:
        pass

# Task registry (E4): the latest TASK/TASK_STATE per id, written by task-id.py.
# An OPEN task is a durable, ADDRESSED unit (id -> title + owner) that survives
# every session, so begin/close/hand-off name the same thing.
tasks = []
if db and os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        tstate = {}
        for res, verdict, detail in con.execute(
                "SELECT resource,verdict,detail FROM ledger WHERE type='TASK' ORDER BY id"):
            tstate[res] = (verdict, detail)
        for res, verdict, detail in con.execute(
                "SELECT resource,verdict,detail FROM ledger WHERE type='TASK_STATE' ORDER BY id"):
            tstate[res] = (verdict, detail)
        tasks = sorted([{"id": r, "state": v[0], "title": v[1]}
                        for r, v in tstate.items()
                        if (v[0] or "").upper() != "CLOSED"], key=lambda t: t["id"])
    except Exception:
        pass

# Dev-loop lease (E3): the single-writer lock loop-state.sh acquires on --begin.
# A live holder is a hard blocker for beginning a segment (another session owns
# the loop); a stale lease is no blocker (it is reclaimable).
lock = None
try:
    lk = load(os.path.join(repo, "data/observability/dev-loop.lock"))
    if lk:
        ttl = int(os.environ.get("LOOP_LOCK_TTL", "1800") or 1800)
        age = int(time.time()) - int(lk.get("ts_epoch", 0))
        lock = {"actor": lk.get("actor"), "host": lk.get("host"),
                "unit": lk.get("unit"), "age_s": age, "ttl": ttl,
                "live": age <= ttl}
except Exception:
    lock = None

tier1 = docs.get("tier1_tokens")
budget = docs.get("budget")
docs_over = bool(tier1 is not None and budget and tier1 > budget)

blockers = []
if gate.get("failed"):
    blockers.append("last gate FAILED (%s) — run ./scripts/harness.sh and fix it" % gate.get("failed"))
if docs_over:
    blockers.append("tier-1 docs over budget (~%s > %s) — ./scripts/doc-budget.sh" % (tier1, budget))
try:
    if int(ahead) > 0:
        blockers.append("%s unpushed commit(s) — git push origin main" % ahead)
except Exception:
    pass
try:
    if int(dirty) > 0:
        blockers.append("%s uncommitted change(s)" % dirty)
except Exception:
    pass
if lock and lock.get("live"):
    blockers.append("dev loop locked by %s (unit=%s, %ss) — do not begin a segment; loop-lock.sh --force to take over"
                    % (lock.get("actor"), lock.get("unit") or "-", lock.get("age_s")))

# Loop checkpoint (dev-loop job, written by loop-state.sh): the in-flight
# segment, if any — so a fresh session resumes it instead of re-deriving it.
loop_cur = None
try:
    lpath = os.path.join(repo, "data/observability/jobs", "dev-loop.jsonl")
    begins, ended = {}, set()
    if os.path.exists(lpath):
        for line in open(lpath, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            step = str(e.get("step", ""))
            if step.startswith("b:") and e.get("ok"):
                p = step.split(":")
                if len(p) >= 2:
                    begins[p[1]] = (p[2] if len(p) > 2 else "", e.get("ts") or 0)
            elif step.startswith("e:") and e.get("ok"):
                p = step.split(":")
                if len(p) >= 2:
                    ended.add(p[1])
    inflight = [(s, v) for s, v in begins.items() if s not in ended]
    if inflight:
        s, (revv, ts) = max(inflight, key=lambda x: x[1][1])
        loop_cur = {"unit": s, "rev": revv}
except Exception:
    loop_cur = None

out = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "rev": head, "ahead": ahead, "dirty": dirty, "untracked": untracked,
    "last_gate": {"ts": gate.get("ts", "?"), "passed": gate.get("passed"), "failed": gate.get("failed")},
    "docs": {"tier1_tokens": tier1, "budget": budget, "over": docs_over},
    "since_gate": {"rev": gate_rev, "commits": commits, "n_commits": len(commits), "events": events_since},
    "next": {"text": next_text, "source": next_source},
    "loop": loop_cur,
    "external": external,
    "tasks": tasks,
    "lock": lock,
    "blockers": blockers,
}

if as_json:
    print(json.dumps(out))
    raise SystemExit

print("=== next-action @ %s ===" % out["ts"])
print("rev:  %s  ahead=%s  dirty=%s  untracked=%s" % (head, ahead, dirty, untracked))
lg = out["last_gate"]
print("last gate: %s pass / %s fail  @%s" % (lg["passed"], lg["failed"], lg["ts"]))
if tier1 is not None:
    print("docs:      tier-1 ~%s tok / budget %s  [%s]" % (tier1, budget, "OVER" if docs_over else "OK"))
sg = out["since_gate"]
print("since last gate (%s): %s commit(s), %s ledger event(s)" % (sg["rev"] or "?", sg["n_commits"], sg["events"]))
for c in commits[:5]:
    print("   " + c)
if loop_cur:
    print("in-flight: %s (at %s) — resume it, or loop-state.sh --end \"%s\" when green" % (loop_cur["unit"], loop_cur["rev"], loop_cur["unit"]))
if next_text:
    print("next unit: %s" % next_text)
    print("  source:   %s" % next_source)
else:
    print("next unit: (none queued — see TODO.md)")
if external:
    print("external: %d open issue(s) — %s" % (len(external), ", ".join(
        "%s [%s]" % (e["resource"], e["state"]) for e in external)))
if tasks:
    print("tasks:     %d open — %s" % (len(tasks), ", ".join(
        "%s (%s)" % (t["id"], (t["title"] or "")[:40]) for t in tasks)))
if lock:
    print("lock:      %s (%s, unit=%s, %ss, %s)" % (
        lock.get("actor"), lock.get("host"), lock.get("unit") or "-",
        lock.get("age_s"), "live" if lock.get("live") else "stale"))
if blockers:
    print("blockers:")
    for b in blockers:
        print("  - " + b)
else:
    print("blockers: none")
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    have git || { printf 'FAIL git missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d)
    mkdir -p "$work/docker" "$work/data/observability" || { printf 'FAIL mkdir\n'; return 1; }
    printf '%s\n' '{}' > "$work/opencode.json"
    printf '%s\n' 'FROM scratch' > "$work/docker/Dockerfile"
    printf '%s\n' '# TODO' '' '## Queue (ranked, top first)' '' '- [ ] UNIT-A do the first thing' '- [ ] UNIT-B do the second thing' > "$work/TODO.md"
    printf '%s\n' '{"ts":"20260101T000000Z","passed":3,"failed":0}' > "$work/data/observability/last-gate.json"
    printf '%s\n' '{"tier1_tokens":100,"budget":35000,"over":0}' > "$work/data/observability/docs.json"
    git -C "$work" init -q && git -C "$work" add -A && git -C "$work" -c user.email=t@t -c user.name=t commit -qm init
    local wrev=""
    wrev=$(git -C "$work" rev-parse --short HEAD)
    python3 - "$work/data/observability/observability.db" "$wrev" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rev = sys.argv[2]
con.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, type TEXT, actor TEXT, tool TEXT, resource TEXT, verdict TEXT, detail TEXT, rev TEXT, source TEXT, source_key TEXT)")
con.execute("INSERT INTO ledger(ts,type,rev) VALUES('2026-01-01T00:00:00Z','GATE_START',?)", (rev,))
con.execute("INSERT INTO ledger(ts,type,verdict,detail,rev) VALUES('2026-01-01T00:01:00Z','ADVISORY','FAIL','x',?)", (rev,))
con.commit()
PY
    local o=""
    o=$(NEXT_ACTION_REPO="$work" LEDGER_DB="$work/data/observability/observability.db" bash "${BASH_SOURCE[0]}" --json 2>&1)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(("ts","rev","ahead","dirty","last_gate","docs","since_gate","next","blockers")) <= set(d), "keys"; assert d["since_gate"]["events"]==1, "events"; assert d["since_gate"]["n_commits"]==0, "no commits since"; assert d["next"]["text"].startswith("UNIT-A"), "next unit"; assert d["next"]["source"]=="TODO.md Queue", "source"' \
        || { printf 'FAIL json contract / parse\n'; fail=1; }
    o=$(NEXT_ACTION_REPO="$work" LEDGER_DB="$work/data/observability/observability.db" bash "${BASH_SOURCE[0]}" 2>&1)
    printf '%s' "$o" | grep -q 'next unit: UNIT-A' || { printf 'FAIL text next unit\n'; fail=1; }
    printf '%s' "$o" | grep -q "since last gate ($wrev): 0 commit(s), 1 ledger event(s)" || { printf 'FAIL text since-gate\n'; fail=1; }
    rm -f "$work/TODO.md" "$work/opencode.json" "$work/docker/Dockerfile" "$work/data/observability/last-gate.json" "$work/data/observability/docs.json" "$work/data/observability/observability.db"
    rm -r "$work/.git"
    rmdir "$work/data/observability" "$work/data" "$work/docker" "$work"
    if [ "$fail" -eq 0 ]; then printf 'next-action: self-test PASS\n'; else printf 'next-action: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--json] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--json] [--self-test]\n' "$0"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }

    local REPO
    if [ -n "${NEXT_ACTION_REPO:-}" ]; then
        REPO="$NEXT_ACTION_REPO"
    else
        REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
        [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local HEAD AHEAD MODIFIED UNTRACKED COMMITS
    HEAD=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    AHEAD=$(git -C "$REPO" rev-list --count origin/main..HEAD 2>&1 || printf 0)
    case "$AHEAD" in ''|*[!0-9]*) AHEAD=0 ;; esac
    MODIFIED=$(git -C "$REPO" status --porcelain 2>&1 | grep -v '^??' | grep -c . || true)
    case "$MODIFIED" in ''|*[!0-9]*) MODIFIED=0 ;; esac
    UNTRACKED=$(git -C "$REPO" status --porcelain 2>&1 | grep -c '^??' || true)
    case "$UNTRACKED" in ''|*[!0-9]*) UNTRACKED=0 ;; esac
    local grev=""
    grev=$(LEDGER_DB="${LEDGER_DB:-$REPO/data/observability/observability.db}" python3 "$REPO/scripts/ledger.py" show --json --tail 300 2>&1 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d=[]
r=[x for x in d if isinstance(x,dict) and x.get("type")=="GATE_START" and x.get("rev")]
print(r[-1]["rev"] if r else "")' 2>&1 || true)
    if [ -n "$grev" ] && git -C "$REPO" rev-parse --verify --quiet "$grev^{commit}" >/dev/null 2>&1; then
        COMMITS=$(git -C "$REPO" log --oneline "$grev..HEAD" 2>&1 || true)
    else
        COMMITS=""
    fi

    report "$REPO" "$HEAD" "$AHEAD" "$MODIFIED" "$UNTRACKED" "$COMMITS"
    return 0
}

main "$@"
