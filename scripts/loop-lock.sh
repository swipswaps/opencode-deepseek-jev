#!/usr/bin/env bash
#
# loop-lock.sh — single-writer lease for the dev loop (E3 durable-agent gap).
#
# pi-durable: "one process owns storage; clients attach." The dev loop has
# several shared writers (TODO.md, HANDOFF.md, the `dev-loop` checkpoint, the
# ledger) and no merge key — two LIVE sessions can both claim the same segment
# and clobber each other. This is that missing concurrency lock: a TTL lease,
# actor-tagged, with explicit stale + forced takeover. Durable = crash-safe,
# not exactly-once (a dead holder is reclaimed by TTL, never by replaying its
# history). A waiver is explicit, never silent — same doctrine as RULE #84.
#
#   ./scripts/loop-lock.sh --acquire [--unit UNIT] [--force]
#   ./scripts/loop-lock.sh --refresh
#   ./scripts/loop-lock.sh --release [--force]
#   ./scripts/loop-lock.sh --status [--json]
#   ./scripts/loop-lock.sh --check  [--json]   # exit 3 if held by another live holder
#   ./scripts/loop-lock.sh --self-test
#
# env: LOOP_LOCK_FILE  (default <repo>/data/observability/dev-loop.lock)
#      LOOP_LOCK_ACTOR (default $OPENCODE_SESSION, else host:user)
#      LOOP_LOCK_TTL   (seconds a lease stays live, default 1800)
#
# Exit: 0 ok · 2 usage · 3 busy (another live holder) · 4 not the holder.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
# No bare kill. printf only. main() wrapper.
set -o pipefail

MODE=""
UNIT=""
FORCE=0
JSON=0
SELFTEST=0
TTL="${LOOP_LOCK_TTL:-1800}"

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

default_actor() {
    if [ -n "${LOOP_LOCK_ACTOR:-}" ]; then printf '%s' "$LOOP_LOCK_ACTOR"; return 0; fi
    if [ -n "${OPENCODE_SESSION:-}" ]; then printf '%s' "$OPENCODE_SESSION"; return 0; fi
    printf '%s:%s' "$(hostname 2>&1 || printf host)" "$(id -un 2>&1 || printf user)"
}

# core CMD LOCKFILE — the flock-serialised read-modify-write, in python3.
core() {
    LOOP_LOCK_CMD="$1" LOOP_LOCK_PATH="$2" \
    LOOP_LOCK_ACTOR="$(default_actor)" LOOP_LOCK_TTL="$TTL" \
    LOOP_LOCK_UNIT="$UNIT" LOOP_LOCK_REV="${REV:-}" \
    LOOP_LOCK_FORCE="$FORCE" LOOP_LOCK_JSON="$JSON" \
    python3 - <<'PY'
import fcntl, json, os, socket, sys, time

path = os.environ["LOOP_LOCK_PATH"]
cmd = os.environ["LOOP_LOCK_CMD"]
actor = os.environ["LOOP_LOCK_ACTOR"]
ttl = int(os.environ.get("LOOP_LOCK_TTL", "1800") or "1800")
unit = os.environ.get("LOOP_LOCK_UNIT", "")
rev = os.environ.get("LOOP_LOCK_REV", "")
force = os.environ.get("LOOP_LOCK_FORCE", "0") == "1"
as_json = os.environ.get("LOOP_LOCK_JSON", "0") == "1"
host = socket.gethostname()
now = int(os.environ.get("LOOP_LOCK_NOW") or time.time())

os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)


def load():
    try:
        with open(path, encoding="utf-8") as fh:
            s = json.load(fh)
        return s if isinstance(s, dict) else None
    except (OSError, ValueError):
        return None


def live(s):
    return bool(s) and (now - int(s.get("ts_epoch", 0))) <= ttl


def mine(s):
    return bool(s) and s.get("actor") == actor


def stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


def save(s):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(s, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def emit(code, state, note=""):
    out = {"verdict": code, "path": path, "actor": actor, "ttl": ttl,
           "live": live(state), "mine": mine(state), "holder": state,
           "note": note}
    if as_json:
        print(json.dumps(out))
        return
    if state is None:
        print("lock: free")
    else:
        who = "you" if mine(state) else str(state.get("actor", "?"))
        age = now - int(state.get("ts_epoch", 0))
        print("lock: held by %s (%s, unit=%s, age=%ss, %s)" % (
            who, state.get("host", "?"), state.get("unit", "?"), age,
            "live" if live(state) else "STALE"))
    if note:
        print("note: " + note)


rc = 0
lockf = open(path + ".flock", "a+")
fcntl.flock(lockf, fcntl.LOCK_EX)
try:
    state = load()
    if cmd == "status":
        emit(0, state)
    elif cmd == "check":
        if live(state) and not mine(state):
            emit(3, state, "held by another live holder")
            rc = 3
        else:
            emit(0, state)
    elif cmd == "acquire":
        if live(state) and not mine(state) and not force:
            emit(3, state, "busy: another live holder (--force to take over)")
            rc = 3
        else:
            note = "acquired"
            if state is not None and not mine(state):
                note = "took over from " + str(state.get("actor", "?"))
            ns = {"actor": actor, "host": host, "pid": os.getpid(), "unit": unit,
                  "rev": rev, "ts_epoch": now, "ts": stamp()}
            save(ns)
            emit(0, ns, note)
    elif cmd == "refresh":
        if not mine(state):
            emit(4, state, "not the holder; nothing to refresh")
            rc = 4
        else:
            state["ts_epoch"] = now
            state["ts"] = stamp()
            save(state)
            emit(0, state, "refreshed")
    elif cmd == "release":
        if state is None:
            emit(0, None, "already free")
        elif mine(state) or force:
            try:
                os.remove(path)
            except OSError as e:
                print("loop-lock: release unlink failed (%s)" % e, file=sys.stderr)
            emit(0, None, "released")
        else:
            emit(4, state, "not the holder (--force to take over)")
            rc = 4
    else:
        print("loop-lock: unknown command %s" % cmd, file=sys.stderr)
        rc = 2
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()
sys.exit(rc)
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    local w fail=0 SELF o rc L
    w=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    SELF="${BASH_SOURCE[0]}"
    L="$w/lock.json"
    export LOOP_LOCK_FILE="$L"

    o=$(LOOP_LOCK_ACTOR=A bash "$SELF" --status --json); rc=$?
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["holder"] is None and d["verdict"]==0, d' \
        || { printf 'FAIL fresh status is free\n'; fail=1; }
    [ "$rc" -eq 0 ] || { printf 'FAIL fresh status rc=%s\n' "$rc"; fail=1; }

    LOOP_LOCK_ACTOR=A LOOP_LOCK_TTL=1800 bash "$SELF" --acquire --unit "fix widget" >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL acquire A rc=%s\n' "$rc"; fail=1; }
    o=$(LOOP_LOCK_ACTOR=A bash "$SELF" --status --json)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["holder"]["actor"]=="A" and d["mine"] is True and d["live"] is True, d' \
        || { printf 'FAIL status shows holder A\n'; fail=1; }

    LOOP_LOCK_ACTOR=A bash "$SELF" --check >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL check by holder rc=%s\n' "$rc"; fail=1; }

    LOOP_LOCK_ACTOR=B LOOP_LOCK_TTL=1800 bash "$SELF" --acquire >/dev/null; rc=$?
    [ "$rc" -eq 3 ] || { printf 'FAIL second live acquire must be busy (rc=%s)\n' "$rc"; fail=1; }
    LOOP_LOCK_ACTOR=B bash "$SELF" --check >/dev/null; rc=$?
    [ "$rc" -eq 3 ] || { printf 'FAIL check by non-holder rc=%s\n' "$rc"; fail=1; }
    LOOP_LOCK_ACTOR=B bash "$SELF" --release >/dev/null; rc=$?
    [ "$rc" -eq 4 ] || { printf 'FAIL release by non-holder rc=%s\n' "$rc"; fail=1; }

    LOOP_LOCK_ACTOR=A bash "$SELF" --refresh >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL refresh by holder rc=%s\n' "$rc"; fail=1; }
    LOOP_LOCK_ACTOR=A bash "$SELF" --release >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL release by holder rc=%s\n' "$rc"; fail=1; }
    o=$(LOOP_LOCK_ACTOR=A bash "$SELF" --status --json)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["holder"] is None, d' \
        || { printf 'FAIL release frees the lock\n'; fail=1; }

    LOOP_LOCK_ACTOR=A LOOP_LOCK_TTL=1800 LOOP_LOCK_NOW=1000 bash "$SELF" --acquire >/dev/null
    LOOP_LOCK_ACTOR=C LOOP_LOCK_TTL=1800 bash "$SELF" --acquire >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL stale lease takeover rc=%s\n' "$rc"; fail=1; }
    o=$(LOOP_LOCK_ACTOR=C LOOP_LOCK_TTL=1800 bash "$SELF" --status --json)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["holder"]["actor"]=="C", d' \
        || { printf 'FAIL takeover holder is C\n'; fail=1; }

    LOOP_LOCK_ACTOR=A LOOP_LOCK_TTL=1800 bash "$SELF" --acquire >/dev/null
    LOOP_LOCK_ACTOR=B LOOP_LOCK_TTL=1800 bash "$SELF" --acquire --force >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL forced takeover rc=%s\n' "$rc"; fail=1; }
    o=$(LOOP_LOCK_ACTOR=B bash "$SELF" --status --json)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["holder"]["actor"]=="B", d' \
        || { printf 'FAIL forced holder is B\n'; fail=1; }

    printf 'loop-lock: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    rm -f "$L" "$L.flock" "$L.tmp"
    rmdir "$w"
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --acquire) MODE=acquire; shift ;;
            --refresh) MODE=refresh; shift ;;
            --release) MODE=release; shift ;;
            --status) MODE=status; shift ;;
            --check) MODE=check; shift ;;
            --unit) UNIT="${2:-}"; shift 2 ;;
            --force) FORCE=1; shift ;;
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s --acquire [--unit U] [--force] | --refresh | --release [--force] | --status [--json] | --check [--json] | --self-test\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ -n "$MODE" ] || { printf 'usage: %s --acquire|--refresh|--release|--status|--check [--self-test]\n' "$0"; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    case "$TTL" in ''|*[!0-9]*) printf 'bad LOOP_LOCK_TTL: %s\n' "$TTL"; return 2 ;; esac

    local REPO LOCK
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    LOCK="${LOOP_LOCK_FILE:-$REPO/data/observability/dev-loop.lock}"
    core "$MODE" "$LOCK"
    return "$?"
}

main "$@"
