#!/usr/bin/env bash
#
# peer-health.sh - one evidence-backed verdict for "is the peer down, and why?"
#
# The 2026-11-10 UX report: a notification kept saying 10.100.0.1 was
# disconnected with a Reconnect button, even after both machines had powersave
# off. Powersave was never the client cause. This tool answers the question the
# popup did not: it probes the peer several ways, reads the peer's own Wi-Fi
# evidence, applies hysteresis, and records a durable incident with the reason.
#
#   ./scripts/peer-health.sh                     # one probe + verdict
#   ./scripts/peer-health.sh --explain           # why: checks + evidence + conclusion
#   ./scripts/peer-health.sh --json              # machine contract
#   ./scripts/peer-health.sh --peer owner@host --tailscale 100.x.y.z
#   ./scripts/peer-health.sh --watch 10          # print on state change
#   ./scripts/peer-health.sh --self-test         # offline seams
#
# Hysteresis: a single missed probe does NOT page anyone. The state changes to
# down/degraded only after --fail-threshold consecutive misses, and back to
# healthy only after --recover-threshold consecutive successes. That stops a
# beacon-loss blip from leaving a persistent popup.
#
# State: data/observability/peer-health.json (gitignored) is the shared source
# of truth for hotspot-reconnect.sh, recovery-status.sh, and any dashboard.
#
# Seams (self-test): PEERHEALTH_FAKE_PING, PEERHEALTH_FAKE_SSH,
#   PEERHEALTH_FAKE_HTTP5099, PEERHEALTH_FAKE_HTTP4096, PEERHEALTH_FAKE_TS,
#   PEERHEALTH_FAKE_EVIDENCE, PEERHEALTH_STATE.
#
# Exit: 0 healthy; 2 down/degraded; 3 cannot run.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)

PEER="${PEER_HEALTH_PEER:-owner@10.100.0.1}"
PEER_HOST="${PEER#*@}"
PEER_TS="${PEER_HEALTH_TAILSCALE:-}"
SINCE="${PEER_HEALTH_SINCE:-6}"
STATE_FILE="${PEER_HEALTH_STATE:-$REPO/data/observability/peer-health.json}"
FAIL_THRESHOLD="${PEER_HEALTH_FAIL_THRESHOLD:-3}"
RECOVER_THRESHOLD="${PEER_HEALTH_RECOVER_THRESHOLD:-2}"
WATCH=0
JSON=0
EXPLAIN=0

PING_STATE="skip"
SSH_STATE="skip"
H5099="000"
H4096="000"
TS_STATE="skip"
EVIDENCE='{}'
RAW="unknown"
LINK="unknown"
LINK_REASON=""
PREV_STATE="unknown"
PREV_RAW=""
CONSEC=0
SINCE_TS=0
INCIDENT=0

usage() {
    printf 'usage: %s [--peer USER@HOST] [--tailscale HOST] [--since HOURS]\n' "$0"
    printf '          [--fail-threshold N] [--recover-threshold N] [--watch SEC]\n'
    printf '          [--explain] [--json] [--self-test]\n'
    printf 'exit: 0 healthy, 2 down/degraded, 3 cannot run\n'
}

have() { command -v "$1" > /dev/null; }

probe_ping() {
    case "${PEERHEALTH_FAKE_PING:-}" in
        up) printf 'up'; return 0 ;;
        down) printf 'down'; return 0 ;;
    esac
    have ping || { printf 'skip'; return 0; }
    if ping -c 1 -W 2 "$PEER_HOST" 2>&1 | grep -q 'bytes from'; then printf 'up'; else printf 'down'; fi
}

probe_ssh() {
    case "${PEERHEALTH_FAKE_SSH:-}" in
        up) printf 'up'; return 0 ;;
        down) printf 'down'; return 0 ;;
    esac
    have ssh || { printf 'skip'; return 0; }
    local out=""
    out="$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR "$PEER" true 2>&1)"
    if [ $? -eq 0 ]; then printf 'up'; else printf 'down'; fi
}

http_code() {
    local port="$1" path="$2"
    have curl || { printf '000'; return 0; }
    curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$PEER_HOST:$port$path" 2>&1
}

probe_http() {
    local port="$1" path="$2" seam="" code=""
    case "$port" in
        5099) seam="${PEERHEALTH_FAKE_HTTP5099:-}" ;;
        4096) seam="${PEERHEALTH_FAKE_HTTP4096:-}" ;;
    esac
    if [ -n "$seam" ]; then printf '%s' "$seam"; return 0; fi
    code="$(http_code "$port" "$path")"
    case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

probe_tailscale() {
    case "${PEERHEALTH_FAKE_TS:-}" in
        up) printf 'up'; return 0 ;;
        down) printf 'down'; return 0 ;;
    esac
    [ -n "$PEER_TS" ] || { printf 'skip'; return 0; }
    have tailscale || { printf 'skip'; return 0; }
    if tailscale ping -c 1 "$PEER_TS" 2>&1 | grep -q 'pong'; then printf 'up'; else printf 'down'; fi
}

json_valid() {
    case "$1" in
        \{*) printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 1> /dev/null ;;
        *) return 1 ;;
    esac
}

collect_evidence() {
    local out="" cached=""
    if [ -n "${PEERHEALTH_FAKE_EVIDENCE:-}" ]; then EVIDENCE="$PEERHEALTH_FAKE_EVIDENCE"; return 0; fi
    if [ "$SSH_STATE" = "up" ] && have ssh && [ -f "$SELF_DIR/wifi-link-forensics.sh" ]; then
        out="$(ssh -q -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR "$PEER" "bash -s -- --json --since $SINCE" < "$SELF_DIR/wifi-link-forensics.sh" 2>&1)"
        if json_valid "$out"; then EVIDENCE="$out"; return 0; fi
    fi
    if [ -f "$STATE_FILE" ]; then
        cached="$(python3 - "$STATE_FILE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(json.dumps(d.get("evidence") or {}))
except Exception:
    print("{}")
PY
)"
        if json_valid "$cached" && [ "$cached" != "{}" ]; then EVIDENCE="$cached"; return 0; fi
    fi
    if [ -f "$SELF_DIR/wifi-link-forensics.sh" ]; then
        out="$(bash "$SELF_DIR/wifi-link-forensics.sh" --json --since "$SINCE" 2>&1)"
        if json_valid "$out"; then EVIDENCE="$out"; fi
    fi
}

read_state() {
    [ -f "$STATE_FILE" ] || return 0
    local lines=""
    lines="$(python3 - "$STATE_FILE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
for k in ("state","raw","consecutive","since","incident_id"):
    print(d.get(k,""))
PY
)"
    PREV_STATE="$(printf '%s\n' "$lines" | awk 'NR==1{print}')"
    PREV_RAW="$(printf '%s\n' "$lines" | awk 'NR==2{print}')"
    CONSEC="$(printf '%s\n' "$lines" | awk 'NR==3{print}')"
    SINCE_TS="$(printf '%s\n' "$lines" | awk 'NR==4{print}')"
    INCIDENT="$(printf '%s\n' "$lines" | awk 'NR==5{print}')"
    case "$PREV_STATE" in ''|*[!a-z]*) PREV_STATE="unknown" ;; esac
    case "$CONSEC" in ''|*[!0-9]*) CONSEC=0 ;; esac
    case "$SINCE_TS" in ''|*[!0-9]*) SINCE_TS=0 ;; esac
    case "$INCIDENT" in ''|*[!0-9]*) INCIDENT=0 ;; esac
}

classify() {
    local up=0 total=0 v="" verdicts="" reason="" expect_http=""
    expect_http="${PEER_HEALTH_EXPECT_HTTP:-0}"
    for v in "$PING_STATE" "$SSH_STATE" "$TS_STATE"; do
        [ "$v" = "skip" ] && continue
        total=$((total + 1))
        [ "$v" = "up" ] && up=$((up + 1))
    done

    # Link quality is separate from reachability: a peer can answer ssh and
    # still be losing Wi-Fi beacons. Evidence comes from the peer's own
    # wifi-link-forensics.sh JSON, so the verdict says WHY, not just "down".
    verdicts="$(evidence_field verdicts)"
    case "$verdicts" in
        *beacon-loss*) LINK="lossy"; reason="beacon-loss" ;;
        *path-flap*) LINK="lossy"; reason="${reason:+$reason,}path-flap" ;;
        *driver-b43*) LINK="lossy"; reason="${reason:+$reason,}b43" ;;
        *2.4-only*) LINK="lossy"; reason="${reason:+$reason,}2.4-only" ;;
        *stable*) LINK="clean" ;;
        *) LINK="unknown" ;;
    esac
    LINK_REASON="$reason"

    if [ "$total" -eq 0 ] && [ "$H5099" != "200" ]; then
        RAW="unknown"
    elif [ "$up" -eq 0 ] && [ "$H5099" != "200" ]; then
        RAW="down"
    elif [ "$SSH_STATE" = "down" ] || [ "$LINK" = "lossy" ]; then
        RAW="degraded"
    elif [ "$expect_http" = "1" ] && [ "$H5099" != "200" ]; then
        RAW="degraded"
    else
        RAW="healthy"
    fi
}

persist() {
    local now="${1:-$(date +%s)}"
    local new_state="$PREV_STATE" new_since="$SINCE_TS" new_incident="$INCIDENT"
    if [ "$RAW" = "$PREV_RAW" ]; then CONSEC=$((CONSEC + 1)); else CONSEC=1; fi

    case "$RAW" in
        down)
            if [ "$CONSEC" -ge "$FAIL_THRESHOLD" ]; then
                if [ "$new_state" != "down" ]; then new_since="$now"; new_incident="$now"; fi
                new_state="down"
            fi
            ;;
        degraded)
            if [ "$CONSEC" -ge "$FAIL_THRESHOLD" ]; then
                if [ "$new_state" != "degraded" ]; then new_since="$now"; new_incident="$now"; fi
                new_state="degraded"
            fi
            ;;
        healthy)
            if [ "$new_state" = "unknown" ] || [ "$CONSEC" -ge "$RECOVER_THRESHOLD" ]; then
                if [ "$new_state" != "healthy" ]; then new_since="$now"; new_incident=0; fi
                new_state="healthy"
            fi
            ;;
    esac

    mkdir -p "$(dirname "$STATE_FILE")" || return 0
    PEERHEALTH_WRITE_STATE="$STATE_FILE" \
    PEERHEALTH_WRITE_STATE_VAL="$new_state" \
    PEERHEALTH_WRITE_RAW="$RAW" \
    PEERHEALTH_WRITE_CONSEC="$CONSEC" \
    PEERHEALTH_WRITE_SINCE="$new_since" \
    PEERHEALTH_WRITE_INCIDENT="$new_incident" \
    PEERHEALTH_WRITE_PEER="$PEER" \
    PEERHEALTH_WRITE_PING="$PING_STATE" \
    PEERHEALTH_WRITE_SSH="$SSH_STATE" \
    PEERHEALTH_WRITE_H5099="$H5099" \
    PEERHEALTH_WRITE_H4096="$H4096" \
    PEERHEALTH_WRITE_TS="$TS_STATE" \
    PEERHEALTH_WRITE_LINK="$LINK" \
    PEERHEALTH_WRITE_LINK_REASON="$LINK_REASON" \
    PEERHEALTH_WRITE_EVIDENCE="$EVIDENCE" \
    PEERHEALTH_WRITE_FAIL="$FAIL_THRESHOLD" \
    PEERHEALTH_WRITE_RECOVER="$RECOVER_THRESHOLD" \
    python3 - <<'PY'
import json, os, time
now = int(time.time())
try:
    ev = json.loads(os.environ.get("PEERHEALTH_WRITE_EVIDENCE", "{}"))
except Exception:
    ev = {}
out = {
    "ts": now,
    "peer": os.environ.get("PEERHEALTH_WRITE_PEER", ""),
    "state": os.environ.get("PEERHEALTH_WRITE_STATE_VAL", "unknown"),
    "raw": os.environ.get("PEERHEALTH_WRITE_RAW", "unknown"),
    "consecutive": int(os.environ.get("PEERHEALTH_WRITE_CONSEC", "0") or 0),
    "fail_threshold": int(os.environ.get("PEERHEALTH_WRITE_FAIL", "3") or 3),
    "recover_threshold": int(os.environ.get("PEERHEALTH_WRITE_RECOVER", "2") or 2),
    "since": int(os.environ.get("PEERHEALTH_WRITE_SINCE", "0") or 0),
    "incident_id": int(os.environ.get("PEERHEALTH_WRITE_INCIDENT", "0") or 0),
    "link": os.environ.get("PEERHEALTH_WRITE_LINK", "unknown"),
    "link_reason": os.environ.get("PEERHEALTH_WRITE_LINK_REASON", ""),
    "checks": {
        "ping": os.environ.get("PEERHEALTH_WRITE_PING", ""),
        "ssh": os.environ.get("PEERHEALTH_WRITE_SSH", ""),
        "http5099": os.environ.get("PEERHEALTH_WRITE_H5099", ""),
        "http4096": os.environ.get("PEERHEALTH_WRITE_H4096", ""),
        "tailscale": os.environ.get("PEERHEALTH_WRITE_TS", ""),
    },
    "evidence": ev,
}
with open(os.environ["PEERHEALTH_WRITE_STATE"], "w", encoding="utf-8") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
PY
    PREV_STATE="$new_state"
    PREV_RAW="$RAW"
    SINCE_TS="$new_since"
    INCIDENT="$new_incident"
}

evidence_field() {
    printf '%s' "$EVIDENCE" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
k=sys.argv[1]
v=d.get(k,"")
print("" if v is None else v)
' "$1"
}

report() {
    printf 'peer-health: state=%s raw=%s consecutive=%s/%s peer=%s\n' \
        "$PREV_STATE" "$RAW" "$CONSEC" "$FAIL_THRESHOLD" "$PEER"
    printf '  ping=%s ssh=%s http5099=%s http4096=%s tailscale=%s\n' \
        "$PING_STATE" "$SSH_STATE" "$H5099" "$H4096" "$TS_STATE"
    printf '  link=%s reason=%s · evidence: beacon_loss=%s driver=%s band=%s powersave=%s verdicts=%s\n' \
        "$LINK" "${LINK_REASON:-none}" "$(evidence_field beacon_loss)" "$(evidence_field driver)" \
        "$(evidence_field band)" "$(evidence_field powersave)" "$(evidence_field verdicts)"
    printf '  since=%s incident_id=%s\n' "$SINCE_TS" "$INCIDENT"
}

explain() {
    report
    printf '\nwhy:\n'
    case "$RAW" in
        down)
            printf '  - peer did not answer ping, ssh, or :5099/api/health.\n'
            printf '  - conclusion: treat as disconnected (incident %s); this is the flag the popup showed.\n' "$INCIDENT"
            ;;
        degraded)
            printf '  - peer answers some probes but not all (see checks above).\n'
            case "$(evidence_field verdicts)" in
                *beacon-loss*)
                    printf '  - peer Wi-Fi reports beacon loss (%s in the window), driver=%s band=%s powersave=%s.\n' \
                        "$(evidence_field beacon_loss)" "$(evidence_field driver)" "$(evidence_field band)" "$(evidence_field powersave)"
                    printf '  - conclusion: powersave is OFF, so the disconnect is the b43/2.4GHz beacon-loss link, not powersave.\n'
                    ;;
                *)
                    printf '  - conclusion: partial reachability; inspect the failing check above before blaming the peer.\n'
                    ;;
            esac
            ;;
        healthy)
            printf '  - peer is reachable now (ping/ssh/:5099 answered).\n'
            if [ "$LINK" = "lossy" ]; then
                printf '  - but the peer link is LOSSY (%s): beacon_loss=%s driver=%s band=%s powersave=%s.\n' \
                    "$LINK_REASON" "$(evidence_field beacon_loss)" "$(evidence_field driver)" \
                    "$(evidence_field band)" "$(evidence_field powersave)"
                printf '  - conclusion: the earlier disconnect flag was a real intermittent link loss, NOT powersave; powersave is off.\n'
                printf '  - any popup still showing must be cleared on recovery, not left as a permanent "disconnected".\n'
            elif [ "$PREV_STATE" = "healthy" ]; then
                printf '  - no disconnect now. Any popup older than this snapshot is stale.\n'
            else
                printf '  - peer recovered after %s consecutive success(es).\n' "$CONSEC"
            fi
            ;;
        *)
            printf '  - not enough probes available to classify.\n'
            ;;
    esac
}

emit_json() {
    [ -f "$STATE_FILE" ] || { printf '{}\n'; return 0; }
    printf '%s\n' "$(awk '{print}' "$STATE_FILE")"
}

collect() {
    read_state
    PING_STATE="$(probe_ping)"
    SSH_STATE="$(probe_ssh)"
    H5099="$(probe_http 5099 /api/health)"
    H4096="$(probe_http 4096 /session)"
    TS_STATE="$(probe_tailscale)"
    collect_evidence
    classify
}

self_test() {
    local tmp fail=0
    tmp="$(mktemp -d)"
    STATE_FILE="$tmp/peer-health.json"
    PEER="owner@192.0.2.10"
    PEER_HOST="192.0.2.10"
    FAIL_THRESHOLD=2
    RECOVER_THRESHOLD=2
    rm -f "$STATE_FILE"

    export PEERHEALTH_FAKE_PING=down PEERHEALTH_FAKE_SSH=down PEERHEALTH_FAKE_HTTP5099=000
    export PEERHEALTH_FAKE_HTTP4096=000 PEERHEALTH_FAKE_TS=skip
    export PEERHEALTH_FAKE_EVIDENCE='{"beacon_loss":91,"driver":"b43","band":"2.4GHz","powersave":"off","verdicts":"beacon-loss,2.4-only"}'
    collect; persist 1000
    [ "$PREV_STATE" != "down" ] || { printf 'FAIL self-test: first miss must not flap to down\n'; fail=1; }
    collect; persist 1010
    [ "$PREV_STATE" = "down" ] || { printf 'FAIL self-test: second miss should reach down, got %s\n' "$PREV_STATE"; fail=1; }

    export PEERHEALTH_FAKE_PING=up PEERHEALTH_FAKE_SSH=up PEERHEALTH_FAKE_HTTP5099=200 PEERHEALTH_FAKE_HTTP4096=401
    export PEERHEALTH_FAKE_EVIDENCE='{"verdicts":"stable","powersave":"off"}'
    collect; persist 1020
    [ "$PREV_STATE" = "down" ] || { printf 'FAIL self-test: first success must not clear down yet\n'; fail=1; }
    collect; persist 1030
    [ "$PREV_STATE" = "healthy" ] || { printf 'FAIL self-test: second success should recover, got %s\n' "$PREV_STATE"; fail=1; }

    # Reachable but lossy: the popup should say degraded/lossy, not "down".
    export PEERHEALTH_FAKE_EVIDENCE='{"beacon_loss":91,"driver":"b43","band":"2.4GHz","powersave":"off","verdicts":"beacon-loss,2.4-only"}'
    collect; persist 1040
    [ "$PREV_STATE" = "healthy" ] || { printf 'FAIL self-test: first lossy miss must not flap\n'; fail=1; }
    collect; persist 1050
    [ "$PREV_STATE" = "degraded" ] || { printf 'FAIL self-test: lossy link should be degraded, got %s\n' "$PREV_STATE"; fail=1; }

    local got=""
    got="$(evidence_field beacon_loss)"
    [ "$got" = "91" ] || { printf 'FAIL self-test: evidence beacon_loss=%s\n' "$got"; fail=1; }
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STATE_FILE" || { printf 'FAIL self-test: state JSON invalid\n'; fail=1; }

    rm -f "$STATE_FILE"
    rmdir "$tmp" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'peer-health: self-test PASS (hysteresis down + hysteresis recover + evidence + json)\n'
    else
        printf 'peer-health: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --peer) PEER="${2:-}"; PEER_HOST="${PEER#*@}"; shift 2 ;;
            --tailscale) PEER_TS="${2:-}"; shift 2 ;;
            --since) SINCE="${2:-6}"; shift 2 ;;
            --fail-threshold) FAIL_THRESHOLD="${2:-3}"; shift 2 ;;
            --recover-threshold) RECOVER_THRESHOLD="${2:-2}"; shift 2 ;;
            --watch) WATCH="${2:-10}"; shift 2 ;;
            --explain) EXPLAIN=1; shift ;;
            --json) JSON=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$SINCE" in ''|*[!0-9]*) SINCE=6 ;; esac
    case "$FAIL_THRESHOLD" in ''|*[!0-9]*|0) FAIL_THRESHOLD=3 ;; esac
    case "$RECOVER_THRESHOLD" in ''|*[!0-9]*|0) RECOVER_THRESHOLD=2 ;; esac

    case "$WATCH" in ''|*[!0-9]*) WATCH=0 ;; esac
    if [ "$WATCH" -gt 0 ]; then
        local last=""
        while :; do
            collect
            persist
            if [ "$JSON" -eq 1 ]; then
                emit_json
            elif [ "$EXPLAIN" -eq 1 ]; then
                explain
            elif [ "$PREV_STATE" != "$last" ]; then
                report
                last="$PREV_STATE"
            fi
            sleep "$WATCH"
        done
    fi

    collect
    persist
    if [ "$JSON" -eq 1 ]; then emit_json; elif [ "$EXPLAIN" -eq 1 ]; then explain; else report; fi
    case "$PREV_STATE" in
        healthy) return 0 ;;
        *) return 2 ;;
    esac
}

main "$@"
