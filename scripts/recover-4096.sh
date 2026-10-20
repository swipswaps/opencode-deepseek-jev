#!/usr/bin/env bash
#
# recover-4096.sh — automated :4096 recovery probe with ledger logging.
#
# Why this exists: the web UI's "backend temporarily unavailable" banner is a
# data-plane symptom (Caddy 502 on /global/* and /api/*) behind a healthy TLS
# edge (401). Each known pain point has a distinct HTTP signature:
#   401 = healthy (Basic auth challenge) | 000 = no host listener (caddy down)
#   400 = wrong stratum (plain http against https) | 502 = upstream
#   unreachable (stale DNS after a web restart, connect-refused window, or a
#   CPU-starved single-threaded upstream on a large store).
# This script asserts every stratum, names the recovery for each failure, and
# logs one RECOVERY row per check to the observability ledger, so a watchdog
# can poll `ledger.py show --type RECOVERY` and act. Redundant by
# construction: loopback + mesh edge probes, served-vs-file cert comparison,
# edge + authenticated data-plane probes.
#
#   ./scripts/recover-4096.sh [--session ID] [--recover] [--resume]
#   ./scripts/recover-4096.sh --json [--no-log]   # machine contract
#
# --recover is checkpointed (RULES #74): the compose restart is recorded, so
# --resume after a crash skips a second restart and re-runs the probes.
#   ./scripts/recover-4096.sh --self-test         # offline, no docker/net
#
# Flags: --db PATH (store to read, opened mode=ro, never written),
# --rev REV (default: git HEAD short), --no-docker / --no-net (force SKIP,
# test seams also usable to skip strata), --no-log (skip ledger writes),
# --recover (one bounded restart + re-probe on container/dns/edge FAIL).
# Default is check-only: the only write is the ledger log
# (data/observability/observability.db, via LEDGER_DB seam); secrets appear
# by name only, never by value.
#
# References:
#   https://www.rfc-editor.org/rfc/rfc7235#section-4.1 (401 challenge)
#   https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
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

now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -z "$t" ]; then printf '%s000' "$(date +%s)"; return; fi
    local s="${t%%.*}" us="${t#*.}"
    [ -n "$us" ] || us=0
    printf '%d' "$(( s * 1000 + 10#${us:0:3} ))"
}

classify_edge() {
    # classify_edge CODE -> VERDICT|CLASS|DETAIL (pure, unit-tested).
    case "$1" in
        401) printf 'PASS|HEALTHY|alive behind Basic auth' ;;
        000) printf 'FAIL|NO_LISTENER|no host listener; caddy down or never started' ;;
        400) printf 'FAIL|WRONG_STRATUM|plain http against an https endpoint' ;;
        502) printf 'FAIL|UPSTREAM|caddy cannot reach opencode-web (DNS, restart, CPU)' ;;
        *) printf 'FAIL|UNEXPECTED|http=%s' "$1" ;;
    esac
}

hint_for() {
    # hint_for CLASS -> one-line recovery command (pure, unit-tested).
    case "$1" in
        HEALTHY) printf 'none: edge healthy, retry the deep link' ;;
        NO_LISTENER) printf './scripts/web.sh (starts web + caddy, probes https)' ;;
        WRONG_STRATUM) printf 'use https:// (http:// can never answer: caddy is https-only)' ;;
        UPSTREAM) printf './scripts/web.sh; if it persists, docker compose logs caddy | tail (DNS/CPU forensics)' ;;
        *) printf './scripts/web.sh, then docker compose logs caddy for the Referer line' ;;
    esac
}

probe() {
    # probe URL SECONDS -> "CODE SECONDS" on stdout; stderr stays visible.
    local out=""
    if out=$(curl -k -s --max-time "$2" -o /dev/null -w '%{http_code} %{time_total}' "$1"); then
        printf '%s' "$out"
    else
        printf '000 0'
    fi
}

add_check() {
    # add_check NAME VERDICT DETAIL MS — counts, TSV log, human line.
    local name="$1" verdict="$2" detail="$3" ms="$4"
    detail=${detail//$'\t'/ }
    detail=${detail//$'\n'/ }
    printf '%s\t%s\t%s\t%s\n' "$name" "$verdict" "$detail" "$ms" >> "$WORK_TSV"
    case "$verdict" in
        PASS) NPASS=$((NPASS + 1)) ;;
        FAIL) NFAIL=$((NFAIL + 1)) ;;
        *) NSKIP=$((NSKIP + 1)) ;;
    esac
    if [ "$JSON" -eq 0 ]; then
        printf '%s %s: %s\n' "$verdict" "$name" "$detail"
    fi
}

log_ledger() {
    # log_ledger VERDICT TOOL RESOURCE DETAIL — guarded, never fails the run.
    # Telemetry must never fail a gate: discard output, keep exit 0.
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    SEQ=$((SEQ + 1))
    python3 "$REPO/scripts/ledger.py" record --type RECOVERY \
        --actor recover-4096.sh --tool "$2" --resource "$3" \
        --verdict "$1" --detail "$4" --rev "$REV" \
        --source recover-4096 --key "recover-$RUN_TS-$SEQ-$2" \
        > /dev/null 2>&1 || true
    return 0
}

run_check() {
    # run_check NAME CMD... — times it, splits "VERDICT|DETAIL" from stdout.
    local name="$1"
    shift
    local t0 t1 ms out verdict detail
    t0=$(now_ms)
    out=$("$@" 2>&1 || true)
    t1=$(now_ms)
    ms=$((t1 - t0))
    verdict=${out%%|*}
    detail=${out#*|}
    [ "$verdict" = "$out" ] && detail="$out"
    case "$verdict" in PASS | FAIL | SKIP) ;; *) verdict="FAIL" ;; esac
    add_check "$name" "$verdict" "$detail" "$ms"
    local tkey="TARGET_OF_$name"
    log_ledger "$verdict" "$name" "${!tkey}" "$detail"
}

c_containers() {
    if [ "$NODOCKER" -eq 1 ] || ! have docker; then
        printf 'SKIP|docker unavailable (seam or missing); cannot assert container state'
        return 0
    fi
    local web caddy
    web=$(docker inspect opencode-deepseek-web --format '{{.State.Status}}' 2>&1 || printf 'unknown')
    caddy=$(docker inspect opencode-caddy --format '{{.State.Status}}' 2>&1 || printf 'unknown')
    if [ "$web" = "running" ] && [ "$caddy" = "running" ]; then
        printf 'PASS|web=%s caddy=%s' "$web" "$caddy"
    else
        printf 'FAIL|web=%s caddy=%s; run ./scripts/web.sh' "$web" "$caddy"
    fi
}

c_dns() {
    if [ "$NODOCKER" -eq 1 ] || ! have docker; then
        printf 'SKIP|docker unavailable (seam or missing); cannot assert compose DNS'
        return 0
    fi
    local r
    r=$(docker exec opencode-caddy getent hosts opencode-web 2>&1 || printf 'MISS')
    case "$r" in
        *172.*opencode-web* | *opencode-web*172.*)
            printf 'PASS|caddy resolves opencode-web: %s' "$r" ;;
        *) printf 'FAIL|caddy DNS miss: %s; restart web to re-register' "$r" ;;
    esac
}

c_edge() {
    if [ "$NONET" -eq 1 ] || ! have curl; then
        printf 'SKIP|curl unavailable (seam or missing); cannot probe edge'
        return 0
    fi
    local p code secs cls verdict class detail
    p=$(probe "https://127.0.0.1:4096/" 8)
    code=${p%% *}
    secs=${p#* }
    cls=$(classify_edge "$code")
    verdict=${cls%%|*}
    detail=${cls#*|}
    class=${detail%%|*}
    detail=${detail#*|}
    printf '%s|https 127.0.0.1:4096 -> %s %ss (%s)' "$verdict" "$code" "$secs" "$class"
}

c_mesh() {
    if [ "$NONET" -eq 1 ] || ! have curl; then
        printf 'SKIP|curl unavailable (seam or missing); cannot probe mesh path'
        return 0
    fi
    local mip=""
    if have ip; then
        mip=$(ip -brief addr show nebula0 2>&1 | awk '{for (i=3; i<=NF; i++) {split($i,a,"/"); if (a[1] ~ /^10\./) print a[1]}}' || true)
    fi
    if [ -z "$mip" ]; then
        printf 'SKIP|no nebula interface; loopback probe is the redundant leg'
        return 0
    fi
    local first p code
    first=${mip%% *}
    p=$(probe "https://$first:4096/" 8)
    code=${p%% *}
    if [ "$code" = "401" ]; then
        printf 'PASS|https %s:4096 -> 401' "$first"
    else
        printf 'FAIL|https %s:4096 -> %s (loopback is the fallback leg)' "$first" "$code"
    fi
}

c_dashboard() {
    if [ "$NONET" -eq 1 ] || ! have curl; then
        printf 'SKIP|curl unavailable (seam or missing); cannot probe dashboard'
        return 0
    fi
    local p code secs
    p=$(probe "https://127.0.0.1:5099/api/rev" 8)
    code=${p%% *}
    secs=${p#* }
    if [ "$code" = "200" ]; then
        printf 'PASS|/api/rev 200 %ss' "$secs"
    else
        printf 'FAIL|/api/rev -> %s; dashboard shares the web process' "$code"
    fi
}

c_certs() {
    if [ "$NONET" -eq 1 ]; then
        printf 'SKIP|no-net seam; cert battery needs local TLS probes'
        return 0
    fi
    if [ ! -x "$REPO/scripts/certs-verify.sh" ]; then
        printf 'SKIP|certs-verify.sh missing'
        return 0
    fi
    local out
    out=$("$REPO/scripts/certs-verify.sh" 2>&1 || true)
    if printf '%s' "$out" | grep -q 'ALL CHECKS PASSED'; then
        printf 'PASS|fingerprint+SAN+dates+chain+cacert agree'
    else
        printf 'FAIL|cert battery failed; run ./docker/certs-init.sh --check'
    fi
}

c_auth() {
    if [ "$NONET" -eq 1 ] || ! have curl; then
        printf 'SKIP|curl unavailable (seam or missing); cannot probe data plane'
        return 0
    fi
    local pw=""
    if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
        pw="$OPENCODE_SERVER_PASSWORD"
    elif [ -f "$REPO/.env.local" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                OPENCODE_SERVER_PASSWORD) pw="$v" ;;
            esac
        done < "$REPO/.env.local"
    fi
    if [ -z "$pw" ]; then
        printf 'SKIP|no password in env or .env.local; edge 401 already proves liveness'
        return 0
    fi
    local code
    code=$(curl -k -s --max-time 8 -o /dev/null -w '%{http_code}' -u "opencode:$pw" https://127.0.0.1:4096/global/health 2>&1 || printf '000')
    if [ "$code" = "200" ]; then
        printf 'PASS|authenticated /global/health 200 (value never printed)'
    else
        printf 'FAIL|authenticated /global/health -> %s' "$code"
    fi
}

c_session() {
    if ! have python3; then
        printf 'SKIP|python3 missing; cannot read store'
        return 0
    fi
    if [ ! -f "$DB" ]; then
        printf 'FAIL|store missing at %s' "$DB"
        return 0
    fi
    local out
    out=$(python3 - "$DB" "$SESSION" 2>&1 << 'PYEOF'
import sqlite3, sys
db, want = sys.argv[1], sys.argv[2]
con = sqlite3.connect('file:' + db + '?mode=ro', uri=True)
n = con.execute('SELECT COUNT(*) FROM session').fetchone()[0]
if want:
    row = con.execute('SELECT COUNT(*) FROM part WHERE session_id=?', (want,)).fetchone()[0]
    hit = con.execute('SELECT COUNT(*) FROM session WHERE id=?', (want,)).fetchone()[0]
    print('sessions=%d parts=%d row=%d' % (n, row, hit))
else:
    print('sessions=%d' % n)
PYEOF
    )
    [ -z "$out" ] && out="ERROR empty store read"
    case "$out" in
        sessions=*)
            if [ -n "$SESSION" ]; then
                case "$out" in
                    *row=1*) printf 'PASS|%s (readonly)' "$out" ;;
                    *) printf 'FAIL|%s; deep-link target absent' "$out" ;;
                esac
            else
                printf 'PASS|%s (readonly)' "$out"
            fi
            ;;
        *) printf 'FAIL|store unreadable: %s' "$out" ;;
    esac
}

emit_json() {
    python3 - "$RUN_TS" "$REV" "$WORK_TSV" 2>&1 << 'PYEOF' || return 1
import json, sys
ts, rev, path = sys.argv[1], sys.argv[2], sys.argv[3]
checks, p, f, s = [], 0, 0, 0
for line in open(path, encoding='utf-8', errors='replace'):
    parts = line.rstrip('\n').split('\t')
    if len(parts) != 4:
        continue
    name, verdict, detail, ms = parts
    try:
        ms = int(ms)
    except ValueError:
        ms = 0
    checks.append({'name': name, 'verdict': verdict, 'detail': detail, 'ms': ms})
    if verdict == 'PASS':
        p += 1
    elif verdict == 'FAIL':
        f += 1
    else:
        s += 1
print(json.dumps({'ts': ts, 'rev': rev, 'passed': p, 'failed': f,
                  'skipped': s, 'checks': checks}))
PYEOF
}

self_test() {
    local fail=0
    local t=""
    t=$(classify_edge 401)
    [ "$t" = "PASS|HEALTHY|alive behind Basic auth" ] || { printf 'FAIL classify 401 got=%s\n' "$t"; fail=1; }
    t=$(classify_edge 502)
    case "$t" in FAIL\|UPSTREAM\|*) ;; *) printf 'FAIL classify 502 got=%s\n' "$t"; fail=1 ;; esac
    t=$(classify_edge 000)
    case "$t" in FAIL\|NO_LISTENER\|*) ;; *) printf 'FAIL classify 000 got=%s\n' "$t"; fail=1 ;; esac
    t=$(classify_edge 400)
    case "$t" in FAIL\|WRONG_STRATUM\|*) ;; *) printf 'FAIL classify 400 got=%s\n' "$t"; fail=1 ;; esac
    t=$(hint_for UPSTREAM)
    case "$t" in *web.sh*caddy*) ;; *) printf 'FAIL hint UPSTREAM got=%s\n' "$t"; fail=1 ;; esac
    local work=""
    work=$(mktemp -d)
    python3 - "$work/fix.db" 2>&1 << 'PYEOF' || { printf 'FAIL fixture build\n'; fail=1; }
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT)')
con.execute('CREATE TABLE part(id TEXT, session_id TEXT, data TEXT)')
con.execute("INSERT INTO session VALUES('s1','t')")
con.execute("INSERT INTO part VALUES('p1','s1','{}'),('p2','s1','{}')")
con.commit()
PYEOF
    local j=""
    j=$(bash "${BASH_SOURCE[0]}" --json --no-docker --no-net --no-log --db "$work/fix.db" --session s1 2>&1 || true)
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(("ts","rev","passed","failed","skipped","checks")) <= set(d), "keys"; assert len(d["checks"]) >= 6, "checks"; assert d["failed"] == 0, "failed==0"' <<< "$j" \
        || { printf 'FAIL json contract\n'; fail=1; }
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(c["name"] == "session" and c["verdict"] == "PASS" for c in d["checks"]), "session PASS"' <<< "$j" \
        || { printf 'FAIL session check\n'; fail=1; }
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" record --type RECOVERY \
        --verdict PASS --detail self-test --source recover-4096 --key st1 > /dev/null 2>&1 \
        || { printf 'FAIL ledger record\n'; fail=1; }
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep self-test 2>&1 | grep -q 'RECOVERY' \
        || { printf 'FAIL ledger show\n'; fail=1; }
    # checkpoint/resume (#74): the restart step runs once; a resume skips it.
    local rec1="" rec2=""
    rec1=$(RECOVER_DRY=1 DURABLE_JOB_DIR="$work/jobs" bash "${BASH_SOURCE[0]}" --recover --no-net --no-docker --no-log --db "$work/fix.db" --session s1 2>&1)
    printf '%s' "$rec1" | grep -q 'durable-run: run recover-4096/restart' \
        || { printf 'FAIL checkpoint first run\n'; fail=1; }
    rec2=$(RECOVER_DRY=1 DURABLE_JOB_DIR="$work/jobs" bash "${BASH_SOURCE[0]}" --recover --resume --no-net --no-docker --no-log --db "$work/fix.db" --session s1 2>&1)
    printf '%s' "$rec2" | grep -q 'skip (done): recover-4096/restart' \
        || { printf 'FAIL checkpoint resume\n'; fail=1; }
    rm -f "$work/fix.db" "$work/obs.db" "$work/jobs/recover-4096.jsonl"
    rmdir "$work/jobs" "$work"
    if [ "$fail" -eq 0 ]; then printf 'recover-4096: self-test PASS (11 checks)\n'; else printf 'recover-4096: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    JSON=0 SELFTEST=0 DOLOG=1 NODOCKER=0 NONET=0 RECOVER=0 RESUME=0
    SESSION=""
    DB="$REPO/data/opencode/opencode.db"
    REV=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            --no-log) DOLOG=0; shift ;;
            --no-docker) NODOCKER=1; shift ;;
            --no-net) NONET=1; shift ;;
            --recover) RECOVER=1; shift ;;
            --resume) RESUME=1; shift ;;
            --session) SESSION="${2:-}"; shift 2 ;;
            --session=*) SESSION="${1#--session=}"; shift ;;
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            --rev) REV="${2:-}"; shift 2 ;;
            --rev=*) REV="${1#--rev=}"; shift ;;
            -h | --help)
                printf 'usage: %s [--session ID] [--recover] [--json] [--no-log] [--no-docker] [--no-net] [--db PATH] [--rev REV] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    if [ -z "$REV" ]; then
        REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    fi
    RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NPASS=0
    NFAIL=0
    NSKIP=0
    SEQ=0
    local work=""
    work=$(mktemp -d)
    WORK_TSV="$work/checks.tsv"
    TARGET_OF_containers="compose:opencode-web+caddy"
    TARGET_OF_dns="caddy->opencode-web"
    TARGET_OF_edge="https://127.0.0.1:4096/"
    TARGET_OF_edge_mesh="https://<nebula>:4096/"
    TARGET_OF_dashboard="https://127.0.0.1:5099/api/rev"
    TARGET_OF_certs="docker/certs/opencode.crt"
    TARGET_OF_data_auth="https://127.0.0.1:4096/global/health"
    TARGET_OF_session="$DB"
    TARGET_OF_edge_retry="https://127.0.0.1:4096/ (post-retry)"
    TARGET_OF_dns_retry="caddy->opencode-web (post-retry)"
    TARGET_OF_recover="compose:opencode-web+caddy"
    TARGET_OF_forensics="caddy tail-50"
    if [ "$JSON" -eq 0 ]; then
        printf '=== recover-4096 ===\n'
    fi
    if [ "$RECOVER" -eq 1 ] && [ "$RESUME" -eq 0 ]; then
        bash "$REPO/scripts/durable-run.sh" --job recover-4096 --reset > /dev/null 2>&1
    fi
    run_check containers c_containers
    run_check dns c_dns
    run_check edge c_edge
    run_check edge_mesh c_mesh
    run_check dashboard c_dashboard
    run_check certs c_certs
    run_check data_auth c_auth
    run_check session c_session
    if [ "$RECOVER" -eq 1 ] && { [ "${RECOVER_DRY:-0}" -eq 1 ] || { [ "$NFAIL" -gt 0 ] && [ "$NODOCKER" -eq 0 ] && have docker; }; }; then
        local sig="?" job="recover-4096" du="$REPO/scripts/durable-run.sh"
        if [ "${RECOVER_DRY:-0}" -eq 0 ] && have docker; then
            sig=$(docker compose --project-directory "$REPO/docker" logs --tail=50 caddy 2>&1 | grep -c 'reverseproxy.statusError' || true)
            log_ledger "FAIL" "forensics" "caddy tail-50" "502-signatures=$sig captured before retry"
            if [ "$JSON" -eq 0 ]; then
                printf 'forensics: caddy tail-50 502-signatures=%s; single restart attempt\n' "$sig"
            fi
        else
            if [ "$JSON" -eq 0 ]; then printf 'forensics: dry (no docker contact)\n'; fi
        fi
        # The restart is the external effect: checkpoint it so a resume does not
        # restart twice; the probes below still run on every attempt.
        if REPO="$REPO" RECOVER_DRY="${RECOVER_DRY:-0}" bash "$du" --job "$job" --step restart -- bash -c '
            if [ "${RECOVER_DRY:-0}" -eq 1 ]; then printf "dry: would compose up opencode-web caddy\n"; exit 0; fi
            docker compose --project-directory "$REPO/docker" up -d opencode-web caddy
        '; then
            if [ "${RECOVER_DRY:-0}" -eq 0 ]; then sleep 3; fi
            run_check edge_retry c_edge
            run_check dns_retry c_dns
        else
            add_check recover "FAIL" "compose up failed" 0
        fi
    fi
    local summary="recover-4096: $NPASS pass, $NFAIL fail, $NSKIP skip [$REV]"
    if [ "$JSON" -eq 1 ]; then
        emit_json
    else
        printf '%s\n' "$summary"
        if [ "$NFAIL" -gt 0 ]; then
            printf 'next: ./scripts/web.sh (or re-run with --recover for one bounded retry)\n'
        fi
    fi
    local sumverdict="PASS"
    [ "$NFAIL" -gt 0 ] && sumverdict="FAIL"
    log_ledger "$sumverdict" "recover-4096" "run $RUN_TS" "$summary"
    rm -f "$work/checks.tsv"
    rmdir "$work"
    if [ "$NFAIL" -eq 0 ]; then return 0; else return 1; fi
}

main "$@"
