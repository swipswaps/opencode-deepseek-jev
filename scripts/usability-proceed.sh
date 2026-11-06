#!/usr/bin/env bash
#
# usability-proceed.sh - one gated command: find the correct repo, assert the
# patch/build/server state, build, restart, verify, run the closeout gate, and
# launch the real guided retest. It never fakes the human session.
#
#   ./scripts/usability-proceed.sh                 # auto repo/base, guided retest
#   ./scripts/usability-proceed.sh --no-retest     # stop at the retest BLOCK
#   ./scripts/usability-proceed.sh --no-push       # do not try git push
#   ./scripts/usability-proceed.sh --base https://10.100.0.24:5099
#   ./scripts/usability-proceed.sh --repo /path/to/opencode-deepseek-jev
#   ./scripts/usability-proceed.sh --dry-run
#   ./scripts/usability-proceed.sh --self-test
#
# Assert order (any failure stops before the next step):
#   1 repo remote is swipswaps/opencode-deepseek-jev and the usability files exist
#   2 web build succeeds and web/dist is newer than web/src
#   3 web-restart.sh succeeds
#   4 /app/ 200, served==HEAD, /api/usability/tasks 200, /app/explore 302,
#     served asset hash == built asset hash
#   5 closeout-gate --check: if the only block is `retest`, launch the guided
#     human test and re-check; any other block stops
#   6 push (optional) only when the tree is clean and credentials exist
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
# No subprocess.run. No kill without signal. printf only. main() wrapper.
#
set -o pipefail

SCRIPT="usability-proceed.sh"
EXPECT_REMOTE="opencode-deepseek-jev"
BASE="${USABILITY_BASE:-https://10.100.0.24:5099}"
OPENER="${USABILITY_OPENER:-auto}"
REPO_ARG=""
DO_RETEST=1
DO_PUSH=1
DRY=0
FAILED=0
BASE_GIVEN=0
GATES_ONLY=0
SKIP_GATES=0
GATE_TIMEOUT="${GATE_TIMEOUT:-300}"
HYGIENE_TIMEOUT="${HYGIENE_TIMEOUT:-600}"
PATTERNS_TIMEOUT="${PATTERNS_TIMEOUT:-120}"
[ -n "${USABILITY_BASE:-}" ] && BASE_GIVEN=1

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

section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad() { FAILED=1; printf 'FAIL  %s\n' "$*"; }

find_target() {
    local d
    if [ -n "$REPO_ARG" ]; then
        if [ -d "$REPO_ARG/.git" ] && git -C "$REPO_ARG" remote get-url origin 2>&1 | grep -q "$EXPECT_REMOTE"; then
            printf '%s' "$REPO_ARG"; return 0
        fi
        return 1
    fi
    for d in /home/owner/Documents/*/repo "$PWD"; do
        [ -d "$d/.git" ] || continue
        [ -f "$d/opencode.json" ] || continue
        if git -C "$d" remote get-url origin 2>&1 | grep -q "$EXPECT_REMOTE"; then
            printf '%s' "$d"; return 0
        fi
    done
    return 1
}

http_code() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>&1 || printf '000'
}

json_field() {
    # json_field URL FIELD
    curl -sS --max-time 8 "$1" 2>&1 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(d.get(sys.argv[1], ""))
' "$2" 2>&1
}

asset_name() {
    python3 -c '
import re, sys
try:
    h = open(sys.argv[1]).read()
    m = re.search(r"/app/assets/(index-[A-Za-z0-9_-]+\.js)", h)
    print(m.group(1) if m else "")
except Exception:
    print("")
' "$1"
}

self_test() {
    local repo fail=0
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && repo=$(find_target)
    [ -z "$repo" ] && { printf 'FAIL repo not found\n'; return 1; }
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    have curl || { printf 'FAIL curl missing\n'; return 1; }
    have timeout || { printf 'FAIL timeout missing\n'; return 1; }
    for s in closeout-gate.py web-build-restart.sh usability-guided.py usability-guide.sh; do
        [ -f "$repo/scripts/$s" ] || { printf 'FAIL scripts/%s missing\n' "$s"; fail=1; }
    done
    python3 "$repo/scripts/closeout-gate.py" --self-test || fail=1
    bash "$repo/scripts/web-build-restart.sh" --self-test || fail=1
    python3 "$repo/scripts/usability-guided.py" --self-test || fail=1
    bash "$repo/scripts/usability-guide.sh" --self-test || fail=1
    if [ "$fail" -eq 0 ]; then printf '%s: self-test PASS\n' "$SCRIPT"; else printf '%s: self-test FAIL\n' "$SCRIPT"; fi
    return "$fail"
}

run_gate() {
    local name="$1" secs="$2"; shift 2
    local log rc
    log=$(mktemp)
    printf '\n--- gate %s (timeout %ss) ---\n' "$name" "$secs"
    ( cd "$REPO" && timeout -k 10 "$secs" "$@" ) 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 124 ]; then
        printf 'FAIL  gate %s timed out after %ss; last lines:\n' "$name" "$secs"
        tail -n 10 "$log"
        rm -f "$log"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL  gate %s rc=%s; last lines:\n' "$name" "$rc"
        tail -n 10 "$log"
        rm -f "$log"
        return 1
    fi
    ok "gate $name pass"
    rm -f "$log"
    return 0
}

write_gate() {
    # write_gate PASSED FAILED
    local ts
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$REPO/data/observability"
    printf '{"ts":"%s","passed":%s,"failed":%s}\n' "$ts" "$1" "$2" > "$REPO/data/observability/last-gate.json"
    printf 'last-gate: ts=%s passed=%s failed=%s\n' "$ts" "$1" "$2"
}

run_gates() {
    section "gates (streamed, bounded; no silent harness buffering)"
    run_gate lint "$GATE_TIMEOUT" bash scripts/lint.sh || { write_gate 0 1; return 1; }
    run_gate test-hygiene "$HYGIENE_TIMEOUT" bash scripts/test-hygiene.sh || { write_gate 1 1; return 1; }
    run_gate test-patterns "$PATTERNS_TIMEOUT" bash scripts/test-patterns.sh || { write_gate 2 1; return 1; }
    write_gate 3 0
    ok "gates: 3 pass / 0 fail"
    return 0
}

usage() {
    printf 'usage: %s [--repo PATH] [--base URL] [--opener auto|xdg|playwright|selenium|cdp|print]\n' "$SCRIPT"
    printf '       [--no-retest] [--no-push] [--dry-run] [--self-test]\n'
}

main() {
    local a
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) shift; REPO_ARG="${1:-}" ;;
            --repo=*) REPO_ARG="${1#--repo=}" ;;
            --base) shift; BASE="${1:-$BASE}"; BASE_GIVEN=1 ;;
            --base=*) BASE="${1#--base=}"; BASE_GIVEN=1 ;;
            --opener) shift; OPENER="${1:-auto}" ;;
            --opener=*) OPENER="${1#--opener=}" ;;
            --no-retest) DO_RETEST=0 ;;
            --no-push) DO_PUSH=0 ;;
            --gates-only) GATES_ONLY=1 ;;
            --skip-gates) SKIP_GATES=1 ;;
            --gate-timeout) shift; GATE_TIMEOUT="${1:-$GATE_TIMEOUT}" ;;
            --gate-timeout=*) GATE_TIMEOUT="${1#--gate-timeout=}" ;;
            --hygiene-timeout) shift; HYGIENE_TIMEOUT="${1:-$HYGIENE_TIMEOUT}" ;;
            --hygiene-timeout=*) HYGIENE_TIMEOUT="${1#--hygiene-timeout=}" ;;
            --patterns-timeout) shift; PATTERNS_TIMEOUT="${1:-$PATTERNS_TIMEOUT}" ;;
            --patterns-timeout=*) PATTERNS_TIMEOUT="${1#--patterns-timeout=}" ;;
            --dry-run) DRY=1 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1" >&2; usage; return 2 ;;
        esac
        shift
    done
    BASE="${BASE%/}"

    section "1. locate and assert the repo"
    REPO=$(find_target) || {
        bad "no repo with origin containing '$EXPECT_REMOTE'; pass --repo /path/to/opencode-deepseek-jev"
        printf 'repos found:\n'
        for d in /home/owner/Documents/*/repo; do
            [ -d "$d/.git" ] || continue
            printf '  %s -> %s\n' "$d" "$(git -C "$d" remote get-url origin 2>&1)"
        done
        return 1
    }
    local remote head branch
    remote=$(git -C "$REPO" remote get-url origin 2>&1)
    head=$(git -C "$REPO" rev-parse --short HEAD 2>&1)
    branch=$(git -C "$REPO" branch --show-current 2>&1)
    printf 'repo:   %s\nremote: %s\nhead:   %s\nbranch: %s\nbase:   %s\n' "$REPO" "$remote" "$head" "$branch" "$BASE"
    case "$remote" in *"$EXPECT_REMOTE"*) ok "remote is $EXPECT_REMOTE" ;; *) bad "wrong remote: $remote"; return 1 ;; esac

    local missing=0 s
    for s in scripts/closeout-gate.py scripts/web-build-restart.sh scripts/usability-guided.py scripts/usability-guide.sh web/src/components/Usability.jsx; do
        if [ -f "$REPO/$s" ]; then ok "present: $s"; else bad "missing: $s"; missing=1; fi
    done
    if [ "$missing" -eq 1 ]; then
        if [ -f /tmp/opencode-usability.patch ]; then
            printf 'applying /tmp/opencode-usability.patch (3-way)...\n'
            if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
                bad "tree is dirty; refusing git am. Commit/stash, or use the existing 6ab9859 commit."
                return 1
            fi
            git -C "$REPO" am -3 /tmp/opencode-usability.patch || { git -C "$REPO" am --abort; bad "patch failed"; return 1; }
            ok "patch applied"
        else
            bad "files missing and /tmp/opencode-usability.patch absent; deliver the patch or check out 6ab9859"
            return 1
        fi
    fi

    if [ "$DRY" -eq 1 ]; then
        section "dry run"
        printf 'would run:\n  cd %s/web && npm run build\n  %s/scripts/web-restart.sh\n  gates: lint/%ss, test-hygiene/%ss, test-patterns/%ss (streamed, bounded)\n  %s/scripts/closeout-gate.py --check --base %s\n' "$REPO" "$REPO" "$GATE_TIMEOUT" "$HYGIENE_TIMEOUT" "$PATTERNS_TIMEOUT" "$REPO" "$BASE"
        [ "$DO_RETEST" -eq 1 ] && printf '  %s/scripts/usability-guide.sh --opener %s --base %s\n' "$REPO" "$OPENER" "$BASE"
        [ "$DO_PUSH" -eq 1 ] && printf '  git -C %s push origin %s\n' "$REPO" "$branch"
        return 0
    fi

    if [ "$BASE_GIVEN" -eq 0 ] && [ "$(http_code "$BASE/app/")" != "200" ]; then
        if [ "$(http_code "http://127.0.0.1:5099/app/")" = "200" ]; then
            BASE="http://127.0.0.1:5099"
            warn "https base not reachable by curl; using $BASE (pass --base to override)"
        fi
    fi

    if [ "$GATES_ONLY" -eq 1 ]; then
        run_gates || return 1
        printf '\nPASS: gates only (no build/restart/retest)\n'
        return 0
    fi

    section "2. build web/"
    ( cd "$REPO/web" && npm run build ) || { bad "npm run build"; return 1; }
    dist_asset=$(asset_name "$REPO/web/dist/index.html")
    src_mtime=$(python3 -c 'import os,sys; p=sys.argv[1]; print(int(max([os.path.getmtime(os.path.join(r,f)) for r,_,fs in os.walk(p) for f in fs] or [0])))' "$REPO/web/src" 2>&1)
    dist_mtime=$(python3 -c 'import os,sys; p=sys.argv[1]; print(int(max([os.path.getmtime(os.path.join(r,f)) for r,_,fs in os.walk(p) for f in fs] or [0])))' "$REPO/web/dist" 2>&1)
    [ -n "$dist_asset" ] && ok "built asset: $dist_asset" || { bad "web/dist/index.html has no asset"; return 1; }
    [ "$dist_mtime" -ge "$src_mtime" ] && ok "web/dist newer than web/src ($dist_mtime >= $src_mtime)" || { bad "web/dist older than web/src"; return 1; }

    section "3. restart from the repo root"
    ( cd "$REPO" && ./scripts/web-restart.sh ) || { bad "web-restart.sh"; return 1; }
    ok "web-restart.sh rc=0"

    section "4. verify the served build"
    local code rev served tasks appexp asset
    code=$(http_code "$BASE/app/")
    [ "$code" = "200" ] && ok "/app/ 200" || { bad "/app/ -> $code"; return 1; }
    served=$(json_field "$BASE/api/rev" served)
    [ -n "$head" ] && [ "$served" = "$head" ] && ok "served==HEAD ($served)" || { bad "served=$served head=$head"; return 1; }
    tasks=$(http_code "$BASE/api/usability/tasks")
    [ "$tasks" = "200" ] && ok "/api/usability/tasks 200" || { bad "/api/usability/tasks -> $tasks"; return 1; }
    appexp=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 8 "$BASE/app/explore" 2>&1)
    case "$appexp" in 302*"/explore") ok "/app/explore -> /explore" ;; *) bad "/app/explore -> $appexp"; return 1 ;; esac
    asset=$(curl -sS --max-time 8 "$BASE/app/" 2>&1 | python3 -c 'import re,sys; h=sys.stdin.read(); m=re.search(r"/app/assets/(index-[A-Za-z0-9_-]+\.js)",h); print(m.group(1) if m else "")' 2>&1)
    [ "$asset" = "$dist_asset" ] && ok "served asset == built asset" || { bad "served asset=$asset built=$dist_asset"; return 1; }

    section "4b. gates (streamed, bounded)"
    if [ "$SKIP_GATES" -eq 1 ]; then
        warn "skipping gates (--skip-gates); closeout will verify last-gate freshness"
    else
        run_gates || return 1
    fi

    section "5. closeout gate"
    local out rc
    out=$(mktemp)
    python3 "$REPO/scripts/closeout-gate.py" --check --base "$BASE" > "$out" 2>&1
    rc=$?
    cat "$out"
    if [ "$rc" -eq 0 ]; then
        ok "closeout already PASS"
    else
        local blocking
        blocking=$(python3 - "$out" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
ids = re.findall(r"^(FAIL|WARN|DEFER)\s+(\S+)", text, re.M)
print(",".join(i for st, i in ids if st == "FAIL"))
PY
)
        if [ "$blocking" = "retest" ] && [ "$DO_RETEST" -eq 1 ]; then
            warn "only blocking item is retest; launching the guided human test"
            ( cd "$REPO" && ./scripts/usability-guide.sh --opener "$OPENER" --base "$BASE" ) || { bad "guided test did not complete"; rm -f "$out"; return 1; }
            python3 "$REPO/scripts/closeout-gate.py" --check --base "$BASE" > "$out" 2>&1
            rc=$?
            cat "$out"
            [ "$rc" -eq 0 ] && ok "closeout PASS after retest" || { bad "closeout still BLOCKED"; rm -f "$out"; return 1; }
        else
            bad "closeout blocking=[$blocking]; resolve those first (or use --no-retest to stop here)"
            rm -f "$out"
            return 1
        fi
    fi
    rm -f "$out"

    section "6. push (optional)"
    if [ "$DO_PUSH" -eq 0 ]; then
        warn "push disabled (--no-push)"
    elif [ -n "$(git -C "$REPO" status --porcelain)" ]; then
        warn "tree is dirty; not pushing (commit the docs/generated state first)"
    else
        if git -C "$REPO" push origin "$branch"; then
            ok "pushed origin/$branch"
        else
            warn "push failed (no credentials in this shell); the commit is local"
        fi
    fi

    section "result"
    if [ "$FAILED" -eq 0 ]; then
        printf 'PASS: gated build, restart, serve, closeout, and retest.\n'
        return 0
    fi
    printf 'FAIL: see the lines above.\n'
    return 1
}

main "$@"
