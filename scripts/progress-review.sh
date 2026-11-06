#!/usr/bin/env bash
#
# progress-review.sh — periodic supervisor of the DEV LOOP's progression.
#
# The sentinel watches session/model health (cost, stalls, gateway). This is its
# sibling for pi-durable's other half: is the *loop* still advancing? One sweep
# reads `next-action.sh` (rev, last gate, next unit, blockers), compares it to
# the previous sweep, and:
#   - ADVANCE: rev or gate advanced since the last sweep -> one durable PASS row
#     (the progression is recorded, not just felt).
#   - STALL:   no rev/gate advance for PROGRESS_STALL_TICKS sweeps -> one durable
#     FAIL row with the next unit + blockers (a stalled loop is news).
#   - INIT/QUIET: first sweep initialises silently; a single unchanged tick is
#     not yet a stall. Only news trips (the sentinel's cry-wolf doctrine).
#
# Stable per-incident keys (`progress-advance-<rev>` / `progress-stall-<rev>`)
# mean a persisting condition is ONE ledger row (UNIQUE(source,key)), never one
# per sweep. Read-only except the ledger and a small state file.
#
#   ./scripts/progress-review.sh [--once] [--json] [--no-log] [--self-test]
#
# A "blocked-external" PASS is a CLAIM, not an observation: every open external
# unit must carry the observed state and the time it was observed, and the PASS
# expires after PROGRESS_EXTERNAL_TTL consecutive sweeps. An expired claim is
# external-stale (FAIL) with a re-audit instruction — a wrong "external" label
# must never become a progress sink (F2).
#
# Env seams: PROGRESS_STATE (state file), PROGRESS_STALL_TICKS (default 2),
# PROGRESS_EXTERNAL_TTL (default 8 sweeps), LEDGER_DB, NEXT_ACTION_REPO
# (forwarded). Install: ./scripts/progress-review-install.sh.
# Exit 0 clean/quiet, 1 stalled, 2 usage/resolve error.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
# No subprocess.run. No bare kill. printf only. main() wrapper.
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

# self-test git must not inherit host hooks/filters/signing
git_clean() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"; }

log_row() {
    # log_row VERDICT DETAIL KEY RESOURCE — guarded, never fails the sweep.
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor progress-review --tool progress-review --resource "$4" \
        --verdict "$1" --detail "$2" --rev "$REV" \
        --source progress-review --key "$3" \
        > /dev/null 2>&1 || true
    return 0
}

decide() {
    # decide STALL_TICKS REPO TMPFILE — reads next-action + prior state,
    # writes the new state, prints the decision JSON. One python pass.
    if [ -n "${PROGRESS_NEXT_JSON:-}" ]; then
        printf '%s' "$PROGRESS_NEXT_JSON" > "$3"
    else
        NEXT_ACTION_REPO="${NEXT_ACTION_REPO:-$2}" \
        bash "$REPO/scripts/next-action.sh" --json > "$3" 2>&1 || true
    fi
    NA_STATE="$3" PROGRESS_STATE="$STATE" PROGRESS_STALL_TICKS="$1" \
    python3 - <<'PY'
import json, os, datetime

na = {}
try:
    na = json.load(open(os.environ["NA_STATE"]))
except Exception:
    na = {}
stall_ticks = int(os.environ.get("PROGRESS_STALL_TICKS", "2") or 2)
state_path = os.environ["PROGRESS_STATE"]

rev = str(na.get("rev", "?"))
gate = (na.get("last_gate") or {})
gate_ts = str(gate.get("ts", ""))
next_txt = (na.get("next") or {}).get("text") or ""
blockers = na.get("blockers") or []
external = na.get("external") or []
# A stall whose next unit is itself external is not a stalled loop: it is
# waiting on someone else (RULE #79's cry-wolf rule). Record a quiet PASS —
# but only on EVIDENCE (an observed state + observation time), and only while
# the claim is fresh (ext_ttl sweeps). Otherwise the label is a sink (F2).
ext_ttl = int(os.environ.get("PROGRESS_EXTERNAL_TTL", "8") or 8)


def observed(e):
    if not isinstance(e, dict):
        return False
    return bool(str(e.get("state", "")).strip()) and bool(str(e.get("ts", "")).strip())


ext_evidence = bool(external) and all(observed(e) for e in external)
blocked_external = ext_evidence and ("external" in next_txt.lower())
since = na.get("since_gate") or {}

prev = {}
try:
    prev = json.load(open(state_path))
except Exception:
    prev = {}

first = not prev
advanced = (not first) and (rev != str(prev.get("rev", "")) or gate_ts != str(prev.get("gate_ts", "")))
if first:
    ticks = 0
elif advanced:
    ticks = 0
else:
    ticks = int(prev.get("unchanged_ticks", 0)) + 1

if first:
    ext_ticks = 1 if blocked_external else 0
elif advanced or not blocked_external:
    ext_ticks = 0
else:
    ext_ticks = int(prev.get("external_ticks", 0)) + 1

if first:
    decision = "init"
elif advanced:
    decision = "advance"
elif ticks >= stall_ticks and blocked_external and ext_ticks <= ext_ttl:
    decision = "blocked-external"
elif ticks >= stall_ticks and blocked_external:
    decision = "external-stale"
elif ticks >= stall_ticks:
    decision = "stall"
else:
    decision = "quiet"

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.dirname(state_path), exist_ok=True)
json.dump({"ts": ts, "rev": rev, "gate_ts": gate_ts, "unchanged_ticks": ticks,
           "external_ticks": ext_ticks}, open(state_path, "w"), indent=2)

if decision == "blocked-external":
    ext = ", ".join(str(e.get("resource", e)) for e in external)
    detail = "loop blocked on an external unit (rev %s, %d sweep(s), claim %d/%d): %s | external: %s" % (rev, ticks, ext_ticks, ext_ttl, next_txt or "(none)", ext)
    verdict, key = "PASS", "progress-blocked-" + rev
elif decision == "external-stale":
    ext = ", ".join(str(e.get("resource", e)) for e in external)
    detail = "external claim unverified for %d sweep(s) (TTL %d, rev %s): %s | re-audit the attribution and probe the local side | external: %s" % (ext_ticks, ext_ttl, rev, next_txt or "(none)", ext)
    verdict, key = "FAIL", "progress-external-stale-" + rev
elif decision == "stall":
    detail = "dev loop stalled: no rev/gate advance for %d sweep(s) (rev %s). next: %s" % (ticks, rev, next_txt or "(none)")
    if external and not ext_evidence:
        detail += " | external claim lacks observed state/ts (not accepted as blocked)"
    if blockers:
        detail += " | blockers: " + "; ".join(blockers)
    verdict, key = "FAIL", "progress-stall-" + rev
elif decision == "advance":
    n = since.get("n_commits", 0)
    detail = "loop advanced: rev %s (+%s commit(s) since gate, %s event(s))" % (rev, n, since.get("events", 0))
    verdict, key = "PASS", "progress-advance-" + rev
else:
    verdict, key = "", ""

print(json.dumps({"ts": ts, "rev": rev, "decision": decision, "ticks": ticks,
                  "gate_ts": gate_ts, "next": next_txt, "blockers": blockers,
                  "verdict": verdict, "detail": detail if verdict else "",
                  "key": key, "stall_ticks": stall_ticks,
                  "external_ticks": ext_ticks, "external_ttl": ext_ttl}))
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    have git || { printf 'FAIL git missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d)
    mkdir -p "$work/repo/docker" "$work/repo/data/observability" "$work/state" || { printf 'FAIL mkdir\n'; return 1; }
    printf '%s\n' '{}' > "$work/repo/opencode.json"
    printf '%s\n' 'FROM scratch' > "$work/repo/docker/Dockerfile"
    printf '%s\n' '# TODO' '' '## Queue (ranked, top first)' '' '- [ ] UNIT-A' > "$work/repo/TODO.md"
    printf '%s\n' '{"ts":"20260101T000000Z","passed":3,"failed":0}' > "$work/repo/data/observability/last-gate.json"
    printf '%s\n' '{"tier1_tokens":100,"budget":35000,"over":0}' > "$work/repo/data/observability/docs.json"
    git_clean -C "$work/repo" init -q && git_clean -C "$work/repo" add -A && git_clean -C "$work/repo" -c user.email=t@t -c user.name=t commit --no-verify -qm init
    local S="$work/state/p.json" L="$work/obs.db" N="$work/repo"
    local o=""
    printf "  stage: tick1-init\n"
    # tick 1: init (no trip)
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "init"' || { printf 'FAIL tick1 init\n'; fail=1; }
    printf "  stage: tick2-quiet\n"
    # tick 2: one quiet tick (no trip)
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "quiet"' || { printf 'FAIL tick2 quiet\n'; fail=1; }
    printf "  stage: tick3-stall\n"
    # tick 3: stall trips
    NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/t3.txt" 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL tick3 exit 1\n'; fail=1; }
    grep -q '"decision": "stall"' "$work/t3.txt" || { printf 'FAIL tick3 stall\n'; fail=1; }
    printf "  stage: advance-commit\n"
    # a commit advances -> PASS row, ticks reset
    printf 'x\n' > "$work/repo/NEW"; git_clean -C "$work/repo" add -A && git_clean -C "$work/repo" -c user.email=t@t -c user.name=t commit --no-verify -qm advance
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "advance"' || { printf 'FAIL advance\n'; fail=1; }
    LEDGER_DB="$L" python3 "$REPO/scripts/ledger.py" show --grep progress 2>&1 | grep -q 'ADVISORY' || { printf 'FAIL ledger rows\n'; fail=1; }
    printf "  stage: blocked-external\n"
    # blocked-external: an external next unit WITH observed state+ts is a quiet
    # PASS, not a FAIL.
    local S2="$work/state/blocked.json"
    local NJ='{"rev":"abc","last_gate":{"ts":"20261020T000000Z"},"next":{"text":"TUNNEL-1: the link fix is external"},"external":[{"resource":"o/r#5","state":"OPEN","ts":"2026-10-20T17:00:00Z"}],"blockers":[],"since_gate":{}}'
    PROGRESS_NEXT_JSON="$NJ" NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S2" PROGRESS_STALL_TICKS=1 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/b1.txt" 2>&1
    PROGRESS_NEXT_JSON="$NJ" NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S2" PROGRESS_STALL_TICKS=1 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/b2.txt" 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL blocked-external exit\n'; fail=1; }
    grep -q '"decision": "blocked-external"' "$work/b2.txt" || { printf 'FAIL blocked-external decision\n'; fail=1; }
    printf "  stage: unobserved-claim\n"
    # F2: an unobserved claim (no state/ts) is NOT accepted as blocked-external.
    local S3="$work/state/unobserved.json"
    local NE='{"rev":"abc","last_gate":{"ts":"20261020T000000Z"},"next":{"text":"TUNNEL-1: the link fix is external"},"external":[{"resource":"o/r#5"}],"blockers":[],"since_gate":{}}'
    PROGRESS_NEXT_JSON="$NE" NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S3" PROGRESS_STALL_TICKS=1 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/b3.txt" 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL unobserved init exit\n'; fail=1; }
    PROGRESS_NEXT_JSON="$NE" NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S3" PROGRESS_STALL_TICKS=1 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/b4.txt" 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL unobserved claim accepted (want stall)\n'; fail=1; }
    grep -q '"decision": "stall"' "$work/b4.txt" || { printf 'FAIL unobserved decision\n'; fail=1; }
    grep -q 'lacks observed state/ts' "$work/b4.txt" || { printf 'FAIL unobserved detail\n'; fail=1; }
    printf "  stage: external-ttl\n"
    # F2: a fresh-but-stale claim decays after PROGRESS_EXTERNAL_TTL sweeps.
    local S4="$work/state/ttl.json"
    local i rc
    for i in 1 2 3; do
        PROGRESS_NEXT_JSON="$NJ" NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S4" PROGRESS_STALL_TICKS=1 PROGRESS_EXTERNAL_TTL=2 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/t$i.txt" 2>&1
        rc=$?
        if [ "$i" -eq 3 ] && [ "$rc" -ne 1 ]; then printf 'FAIL external TTL exit\n'; fail=1; fi
    done
    grep -q '"decision": "blocked-external"' "$work/t2.txt" || { printf 'FAIL external TTL still fresh\n'; fail=1; }
    grep -q '"decision": "external-stale"' "$work/t3.txt" || { printf 'FAIL external TTL decay\n'; fail=1; }
    grep -q 're-audit the attribution' "$work/t3.txt" || { printf 'FAIL external TTL detail\n'; fail=1; }
    printf "  stage: cleanup\n"
    rm -f "$work/repo/NEW" "$work/repo/TODO.md" "$work/repo/opencode.json" "$work/repo/docker/Dockerfile" "$work/repo/data/observability/last-gate.json" "$work/repo/data/observability/docs.json" "$work/state/p.json" "$S2" "$S3" "$S4" "$work/t3.txt" "$work/t1.txt" "$work/t2.txt" "$work/b1.txt" "$work/b2.txt" "$work/b3.txt" "$work/b4.txt" "$work/obs.db"
    rm -r "$work/repo/.git"
    rmdir "$work/repo/data/observability" "$work/repo/data" "$work/repo/docker" "$work/repo" "$work/state" "$work"
    if [ "$fail" -eq 0 ]; then printf 'progress-review: self-test PASS\n'; else printf 'progress-review: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local ONCE=1 JSON=0 DOLOG=1 SELFTEST=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --once) ONCE=1; shift ;;
            --json) JSON=1; shift ;;
            --no-log) DOLOG=0; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--once] [--json] [--no-log] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ "$ONCE" -eq 1 ] || { printf 'usage: periodic runs go through the systemd timer\n'; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    have node || { printf 'GATE FAIL: node required\n'; return 2; }

    STATE="${PROGRESS_STATE:-$REPO/data/observability/.watch/progress-review.json}"
    export STATE REPO DOLOG
    REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    export REV
    local TICKS="${PROGRESS_STALL_TICKS:-2}"
    local tmp="" out=""
    tmp=$(mktemp)
    out=$(decide "$TICKS" "$REPO" "$tmp")
    rm -f "$tmp"
    [ -n "$out" ] || { printf 'FAIL: no decision\n'; return 2; }

    local decision verdict detail key
    decision=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')
    verdict=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')
    detail=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["detail"])')
    key=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')

    if [ "$decision" = "advance" ] || [ "$decision" = "stall" ] || [ "$decision" = "blocked-external" ] || [ "$decision" = "external-stale" ]; then
        log_row "$verdict" "$detail" "$key" "loop/progress-review"
    fi

    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' "$out"
    else
        printf '=== progress-review @ %s ===\n' "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ts"])')"
        case "$decision" in
            init) printf 'init: first sweep, baseline recorded (no trip)\n' ;;
            quiet) printf 'quiet: no rev/gate advance this sweep (%s tick(s); stall at %s)\n' \
                "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticks"])')" \
                "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["stall_ticks"])')" ;;
            advance) printf 'ADVANCE: %s\n' "$detail" ;;
            blocked-external) printf 'BLOCKED: %s\n' "$detail" ;;
            external-stale) printf 'STALE: %s\n' "$detail"
                printf 're-audit the external label: ./scripts/next-action.sh; probe the local side first\n' ;;
            stall) printf 'STALL: %s\n' "$detail"
                printf 'run ./scripts/next-action.sh for the verdict\n' ;;
        esac
    fi

    if { [ "$decision" = "stall" ] || [ "$decision" = "external-stale" ]; } && [ -n "${NOTIFY_WEBHOOK:-}" ] && [ -x "$REPO/scripts/notify.sh" ]; then
        "$REPO/scripts/notify.sh" --last 20 || printf 'WARN: notify.sh post failed\n'
    fi
    if [ "$decision" = "stall" ] || [ "$decision" = "external-stale" ]; then return 1; fi
    return 0
}

main "$@"
