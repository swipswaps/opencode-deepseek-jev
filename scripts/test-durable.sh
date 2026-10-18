#!/usr/bin/env bash
#
# test-durable.sh — lock in the durable properties (pi-durable, RULES #73/#74).
#
# A green run proves, offline, that the durability mechanisms are wired and
# behave: the source of truth is read (not the delivery log), long jobs
# checkpoint and resume, and derived state rebuilds from storage.
#
#   ./scripts/test-durable.sh
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0

ok()  { pass=$((pass + 1)); printf '  [PASS] %s\n' "$1"; }
no()  { fail=$((fail + 1)); printf '  [FAIL] %s\n' "$1"; }

chk() { # chk "name" cmd...
    local name="$1"; shift
    if "$@" > /dev/null 2>&1; then ok "$name"; else no "$name"; fi
}

printf '=== test-durable ===\n'
# #73: triage reads the durable source, not the delivery log.
chk "triage-alerts self-test (durable ledger reader)" python3 "$REPO/scripts/triage-alerts.py" --self-test
# E2: an external issue hand-off round-trips into the durable ledger.
chk "issue-bridge self-test (external issue state -> ledger)" python3 "$REPO/scripts/issue-bridge.py" --self-test
# #74: long jobs checkpoint + resume.
chk "durable-run self-test (checkpoint/resume)" bash "$REPO/scripts/durable-run.sh" --self-test
# #80: the in-flight loop segment is checkpointed.
chk "loop-state self-test (segment checkpoint + lease)" bash "$REPO/scripts/loop-state.sh" --self-test
# E3: a single-writer lease stops two live sessions owning the same loop.
chk "loop-lock self-test (TTL lease, stale/forced takeover)" bash "$REPO/scripts/loop-lock.sh" --self-test
chk "caddy-reload self-test (checkpointed adopter)" bash "$REPO/scripts/caddy-reload.sh" --self-test
# storage is the source of truth: derived state rebuilds from it.
chk "rebuild-derived self-test (rebuild from storage)" bash "$REPO/scripts/rebuild-derived.sh" --self-test
# one more client of the same committed state.
chk "grafana-up self-test (attach a read-only client)" bash "$REPO/scripts/grafana-up.sh" --self-test
# never assume a port (conflicts recur).
chk "free-port self-test (discover, not assume)" bash "$REPO/scripts/free-port.sh" --self-test
# the delivery channel itself.
chk "notify-sink self-test (delivery log)" node "$REPO/scripts/notify-sink.mjs" --self-test

printf '\n=== result: %d pass, %d fail ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 2
