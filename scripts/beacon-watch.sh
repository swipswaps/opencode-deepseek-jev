#!/usr/bin/env bash
#
# beacon-watch.sh - count b43 BEACON-LOSS events per hour and split them at the
# intervention timestamp, so the 24-48 h judgement is reproducible and does not
# confuse pre-intervention history with the post-fix rate.
#
#   ./scripts/beacon-watch.sh --hours 24
#   ./scripts/beacon-watch.sh --hours 24 --intervention ~/.local/state/b43-tune.applied
#   ./scripts/beacon-watch.sh --hours 24 --json --write
#   ./scripts/beacon-watch.sh --self-test
#
# The intervention file is an epoch written by `b43-tune.sh --apply --reload`.
# If it is absent, pass --intervention EPOCH or --intervention FILE.
# Output: per-hour table; pre/post totals when an intervention is known.
# `--write` stores ~/.local/state/beacon-watch.json (override with
# BEACONWATCH_OUT).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

HOURS="${BEACONWATCH_HOURS:-24}"
SINCE="${BEACONWATCH_SINCE:-}"
INTERVENTION="${BEACONWATCH_INTERVENTION:-$HOME/.local/state/b43-tune.applied}"
OUT="${BEACONWATCH_OUT:-$HOME/.local/state/beacon-watch.json}"
JSON=0
WRITE=0
FIXTURE="${BEACONWATCH_FIXTURE:-}"
TOTAL=0
PRE=0
POST=0
INT_HOUR=""

usage() {
    printf 'usage: %s [--hours N] [--since DATE] [--intervention EPOCH|FILE] [--json] [--write] [--self-test]\n' "$0"
}

have() { command -v "$1" > /dev/null; }

journal_lines() {
    if [ -n "$FIXTURE" ]; then
        cat "$FIXTURE"
        return 0
    fi
    have journalctl || return 0
    if [ -n "$SINCE" ]; then
        journalctl -u wpa_supplicant --since "$SINCE" -g BEACON-LOSS -o short-iso --no-pager 2>&1
    else
        journalctl -u wpa_supplicant --since "-${HOURS} hours" -g BEACON-LOSS -o short-iso --no-pager 2>&1
    fi
}

intervention_hour() {
    [ -n "$INTERVENTION" ] || return 1
    local epoch="$INTERVENTION"
    if [ -f "$INTERVENTION" ]; then
        epoch="$(cat "$INTERVENTION" 2>&1 | awk 'NR==1{print $1}')"
    fi
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    date -d "@$epoch" +%Y-%m-%dT%H 2>&1
}

collect() {
    local lines="" per_hour=""
    INT_HOUR="$(intervention_hour 2>&1 || printf '')"
    lines="$(journal_lines | grep 'BEACON-LOSS' 2>&1)"
    case "$lines" in
        '') TOTAL=0; PRE=0; POST=0; PER_HOUR=""; return 0 ;;
    esac
    per_hour="$(printf '%s\n' "$lines" | awk -v int_hour="$INT_HOUR" '
        {
            h = substr($1, 1, 13)
            c[h]++
            if (int_hour != "" && h < int_hour) pre++
            else if (int_hour != "") post++
        }
        END {
            for (h in c) printf "%s %d\n", h, c[h]
            printf "__PRE__ %d\n", pre
            printf "__POST__ %d\n", post
            printf "__TOTAL__ %d\n", pre + post
        }')"
    TOTAL="$(printf '%s\n' "$per_hour" | awk '/^__TOTAL__/{print $2}')"
    PRE="$(printf '%s\n' "$per_hour" | awk '/^__PRE__/{print $2}')"
    POST="$(printf '%s\n' "$per_hour" | awk '/^__POST__/{print $2}')"
    PER_HOUR="$(printf '%s\n' "$per_hour" | awk '!/^__/ {print}' | sort)"
    [ -n "$TOTAL" ] || TOTAL=0
    [ -n "$PRE" ] || PRE=0
    [ -n "$POST" ] || POST=0
}

report() {
    printf 'beacon-watch: last %sh (since=%s)\n' "$HOURS" "${SINCE:-auto}"
    printf 'per hour (count):\n'
    if [ -n "${PER_HOUR:-}" ]; then
        printf '%s\n' "$PER_HOUR" | awk '{printf "  %s  %s\n", $1, $2}'
    else
        printf '  (none)\n'
    fi
    printf 'total=%s\n' "$TOTAL"
    if [ -n "$INT_HOUR" ]; then
        printf 'intervention_hour=%s pre=%s post=%s\n' "$INT_HOUR" "$PRE" "$POST"
    else
        printf 'intervention: (none; pass --intervention EPOCH|FILE)\n'
    fi
}

emit_json() {
    printf '{"hours":%s,"since":"%s","total":%s,"intervention_hour":"%s","pre":%s,"post":%s,"per_hour":{' \
        "$HOURS" "${SINCE:-auto}" "$TOTAL" "$INT_HOUR" "$PRE" "$POST"
    local first=1 h c
    if [ -n "${PER_HOUR:-}" ]; then
        while read -r h c; do
            [ -n "$h" ] || continue
            [ "$first" -eq 1 ] || printf ','
            printf '"%s":%s' "$h" "$c"
            first=0
        done <<EOF
$PER_HOUR
EOF
    fi
    printf '}}\n'
}

write_json() {
    mkdir -p "$(dirname "$OUT")" 2>&1 || true
    emit_json > "$OUT"
    printf 'wrote %s\n' "$OUT"
}

self_test() {
    local tmp fail=0
    tmp="$(mktemp -d)"
    FIXTURE="$tmp/fixture.log"
    printf '%s\n' \
        '2026-11-10T10:00:00-05:00 host wpa_supplicant[1]: wlp2s0b1: CTRL-EVENT-BEACON-LOSS' \
        '2026-11-10T10:30:00-05:00 host wpa_supplicant[1]: wlp2s0b1: CTRL-EVENT-BEACON-LOSS' \
        '2026-11-10T11:00:00-05:00 host wpa_supplicant[1]: wlp2s0b1: CTRL-EVENT-BEACON-LOSS' \
        '2026-11-10T12:00:00-05:00 host wpa_supplicant[1]: wlp2s0b1: CTRL-EVENT-BEACON-LOSS' \
        > "$FIXTURE"
    INTERVENTION="$(date -d '2026-11-10 12:00:00' +%s)"
    collect
    [ "$TOTAL" -eq 4 ] || { printf 'FAIL total=%s\n' "$TOTAL"; fail=1; }
    [ "$PRE" -eq 3 ] || { printf 'FAIL pre=%s\n' "$PRE"; fail=1; }
    [ "$POST" -eq 1 ] || { printf 'FAIL post=%s\n' "$POST"; fail=1; }
    rm -f "$FIXTURE"
    rmdir "$tmp" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'beacon-watch: self-test PASS (per-hour + pre/post split)\n'
    else
        printf 'beacon-watch: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --hours) HOURS="${2:-24}"; shift 2 ;;
            --since) SINCE="${2:-}"; shift 2 ;;
            --intervention) INTERVENTION="${2:-}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --write) WRITE=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$HOURS" in ''|*[!0-9]*) HOURS=24 ;; esac
    if [ "$WRITE" -eq 1 ]; then
        collect
        write_json
        return 0
    fi
    collect
    if [ "$JSON" -eq 1 ]; then emit_json; else report; fi
    return 0
}

main "$@"
