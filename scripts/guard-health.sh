#!/usr/bin/env bash
#
# guard-health.sh — fail-closed health check for the blacklist guard (P0, #4).
#
# A missing/dangling/stale guard is indistinguishable from "no matches": the
# guard is silently absent. This checks the plugin file, the prose (assistant
# output) hook, the irreversible rule, strict mode, the guard self-test, the
# global link, and that the loaded plugin is not older than the file (a stale
# in-memory guard needs an opencode-web restart).
#
#   ./scripts/guard-health.sh            # --check
#   ./scripts/guard-health.sh --self-test
#
# Exit: 0 healthy, 2 FAIL.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

REPO=""
FAIL=0
STATE=""

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

pass() { printf '  PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

self_test() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo\n'; return 2; fi
    REPO="$REPO"; FAIL=0
    STATE="$REPO/logs"; mkdir -p "$STATE"
    plugin_check

    # Stale-marker logic: a heartbeat older than the file must FAIL (an old
    # guard is in memory); a heartbeat after the file must PASS.
    local tmp base_fail old_delta new_delta sha mtime iso_old iso_new
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/guardhealth.XXXXXX" 2>&1) || { printf 'FAIL mktemp\n'; return 2; }
    printf 'plugin body\n' > "$tmp/plugin.js"
    sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/plugin.js" 2>&1)
    mtime=$(stat -c %Y "$tmp/plugin.js" 2>&1)
    iso_old=$(python3 -c 'import datetime,sys
t=int(sys.argv[1])-3600
print(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00","Z"))' "$mtime" 2>&1)
    iso_new=$(python3 -c 'import datetime,sys
t=int(sys.argv[1])+3600
print(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00","Z"))' "$mtime" 2>&1)
    printf '{"verdict":"loaded","ts":"%s","sha":"%s"}\n' "$iso_old" "$sha" > "$tmp/old.log"
    printf '{"verdict":"loaded","ts":"%s","sha":"%s"}\n' "$iso_new" "$sha" > "$tmp/new.log"
    base_fail=$FAIL
    loaded_check "$tmp/plugin.js" "$tmp/old.log" > "$tmp/old.out" 2>&1
    old_delta=$((FAIL - base_fail)); FAIL=$base_fail
    loaded_check "$tmp/plugin.js" "$tmp/new.log" > "$tmp/new.out" 2>&1
    new_delta=$((FAIL - base_fail)); FAIL=$base_fail
    if [ "$old_delta" -eq 1 ]; then pass "self-test: stale loaded marker fails"; else fail "self-test: stale loaded marker not caught"; fi
    if [ "$new_delta" -eq 0 ]; then pass "self-test: fresh loaded marker passes"; else fail "self-test: fresh loaded marker rejected"; fi
    find "$tmp" -depth -delete 2>&1

    printf 'guard-health: self-test %s\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf FAIL)"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

last_loaded_epoch() {
    local log="$1"
    [ -f "$log" ] || { printf '0'; return; }
    grep '"verdict":"loaded"' "$log" 2>&1 | tail -1 | python3 -c 'import json,sys,datetime
try:
    d=json.load(sys.stdin); print(int(datetime.datetime.fromisoformat(d["ts"].replace("Z","+00:00")).timestamp()))
except Exception:
    print(0)' 2>&1
}

# The running guard may be loaded from the global COPY (sessions rooted outside
# the repo), whose pre-fix build wrote to $HOME/.config/data/observability. Read
# whichever log has the newest loaded marker so a live guard is not called stale
# while the telemetry anchor is being migrated.
pick_guard_log() {
    local repo="$REPO/data/observability/guard.log"
    local alt="${XDG_CONFIG_HOME:-$HOME/.config}/data/observability/guard.log"
    local a="" b=""
    a=$(last_loaded_epoch "$repo")
    b=$(last_loaded_epoch "$alt")
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    case "$b" in ''|*[!0-9]*) b=0 ;; esac
    if [ "$b" -gt "$a" ]; then printf '%s' "$alt"; else printf '%s' "$repo"; fi
}

# A loaded marker proves a process imported the plugin, but not that it imported
# the CURRENT file: the marker can predate the last edit (the guard loads once
# per process). Compare the marker's sha AND its timestamp against the plugin
# file, so "green" cannot mean "an older guard is in memory".
loaded_check() {
    local plugin="$1" log="$2"
    local loaded="" loaded_sha="" file_sha="" file_mtime=""
    if [ -f "$log" ]; then
        loaded_sha=$(grep '"verdict":"loaded"' "$log" 2>&1 | tail -1 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("sha") or "")
except Exception:
    print("")' 2>&1)
        loaded=$(grep '"verdict":"loaded"' "$log" 2>&1 | tail -1 | python3 -c 'import json,sys,datetime
try:
    d=json.load(sys.stdin); print(int(datetime.datetime.fromisoformat(d["ts"].replace("Z","+00:00")).timestamp()))
except Exception:
    print("")' 2>&1)
    fi
    file_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$plugin" 2>&1)
    file_mtime=$(stat -c %Y "$plugin" 2>&1)
    case "$file_mtime" in ''|*[!0-9]*) file_mtime=0 ;; esac
    case "$loaded" in ''|*[!0-9]*) loaded="" ;; esac
    if [ -z "$loaded" ]; then
        fail "no loaded heartbeat in guard.log (restart opencode-web)"
    elif [ -z "$loaded_sha" ]; then
        fail "loaded heartbeat has no content hash; restart opencode-web to record it"
    elif [ "$loaded_sha" != "$file_sha" ]; then
        fail "loaded plugin hash differs from file (restart opencode-web to load it)"
    elif [ "$loaded" -lt "$file_mtime" ]; then
        fail "loaded heartbeat predates the plugin file by $((file_mtime - loaded))s; restart opencode-web to load the new rules"
    else
        pass "loaded instance is current (hash + loaded after file mtime)"
    fi
}

plugin_check() {
    local plugin="$REPO/.opencode/plugins/blacklist-guard.js"
    if [ -f "$plugin" ]; then pass "plugin present"; else fail "plugin missing: $plugin"; fi
    if grep -q 'experimental.text.complete' "$plugin"; then pass "assistant-output hook present"; else fail "assistant-output hook missing"; fi
    if grep -q 'name: "irreversible"' "$plugin"; then pass "irreversible rule present"; else fail "irreversible rule missing"; fi
    if grep -q 'strict' "$plugin"; then pass "strict mode present"; else fail "strict mode missing"; fi
    if [ -x "$REPO/scripts/blacklist-guard-self-test.mjs" ] || [ -f "$REPO/scripts/blacklist-guard-self-test.mjs" ]; then
        if node "$REPO/scripts/blacklist-guard-self-test.mjs" > "$STATE/guard-health-selftest" 2>&1; then
            pass "guard self-test"
        else
            fail "guard self-test ($(tail -1 "$STATE/guard-health-selftest"))"
        fi
    else
        fail "guard self-test missing"
    fi
}

main() {
    local selftest=0
    [ "${1:-}" = "--self-test" ] && selftest=1
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo\n'
        return 2
    fi
    STATE="$REPO/logs"; mkdir -p "$STATE"
    printf '=== guard-health ===\n'
    plugin_check
    if [ "$selftest" -eq 0 ]; then
        if [ -x "$REPO/scripts/install-global-guard.sh" ]; then
            if "$REPO/scripts/install-global-guard.sh" --check > "$STATE/guard-health-link" 2>&1; then
                pass "global guard link"
            else
                fail "global guard link ($(tail -1 "$STATE/guard-health-link"))"
            fi
        else
            fail "install-global-guard.sh missing"
        fi
        local plugin="$REPO/.opencode/plugins/blacklist-guard.js"
        local log=""
        log=$(pick_guard_log)
        printf '  info guard log: %s\n' "$log"
        loaded_check "$plugin" "$log"
    fi
    printf 'guard-health: %s\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf 'FAIL (%s)' "$FAIL")"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

main "$@"
