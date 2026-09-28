#!/usr/bin/env bash
#
# test-ensure-env.sh — behavior gate for scripts/ensure-env.sh.
#
# Proves the safety invariants (RULES: no sed / 2>/dev/null; printf only):
#   1. a rerun with nothing to change is a STRICT NO-OP (same bytes, no backup,
#      no password on stdout);
#   2. a present-but-short password only WARNS (never silently replaced);
#   3. a missing password generates one, announces PASSWORD_ROTATED, writes
#      mode 0600, and makes one backup;
#   4. unknown keys and comments survive verbatim.
# Uses --repo to run against a throwaway dir; never touches the real .env.local.
# Wired into test-hygiene.sh.
set -o pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -qF "$1" "$2"; }
nlines() { find "$1" -maxdepth 1 -name '.env.local.bak.*' | wc -l | tr -d ' '; }
hash_of() { sha256sum "$1" | cut -d' ' -f1; }
pwlen() {
    python3 - "$1" <<'PY'
import sys
for l in open(sys.argv[1]):
    if l.startswith("OPENCODE_SERVER_PASSWORD="):
        print(len(l.split("=", 1)[1].strip()))
PY
}

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

main() {
    local repo
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'; return 2
    fi
    local sh="$repo/scripts/ensure-env.sh"
    printf '=== test-ensure-env.sh ===\n'

    local d="/tmp/opencode/ensure-env-test.$$"
    mkdir -p "$d/docker"
    : > "$d/opencode.json"
    : > "$d/docker/Dockerfile"
    printf '%s\n' \
        '# my env' \
        'DEEPSEEK_API_KEY=sk-fake-deepseek-value-000000' \
        'JEV_API_KEY=apikey_fakejev000000000000' \
        'GEMINI_API_KEY=gemini-fake' \
        'OPENCODE_SERVER_PASSWORD=0123456789abcdef0123456789abcdef' \
        'CUSTOM_KEY=keep-me' > "$d/.env.local"
    chmod 600 "$d/.env.local"

    # 1. no-change rerun is a strict no-op.
    local h0; h0=$(hash_of "$d/.env.local")
    bash "$sh" --repo "$d" > "$d/out1.txt" 2>&1
    local rc1=$?
    [ "$rc1" -eq 0 ] && ok 'no-change rerun exits 0' || bad "no-change rerun exits 0 (rc=$rc1)"
    has 'changed: no' "$d/out1.txt" && ok 'no-change rerun reports changed: no' || bad 'no-change rerun reports changed: no'
    has 'PASSWORD_ROTATED' "$d/out1.txt" && bad 'no-change rerun must not rotate' || ok 'no-change rerun does not rotate'
    [ "$(hash_of "$d/.env.local")" = "$h0" ] && ok 'no-change rerun is byte-identical' || bad 'no-change rerun is byte-identical'
    [ "$(nlines "$d")" = "0" ] && ok 'no-change rerun creates no backup' || bad 'no-change rerun creates no backup'

    # 4. unknown keys/comments preserved.
    has 'CUSTOM_KEY=keep-me' "$d/.env.local" && ok 'unknown key preserved' || bad 'unknown key preserved'
    has '# my env' "$d/.env.local" && ok 'comment preserved' || bad 'comment preserved'

    # 2. short-but-present password warns, never regenerates.
    python3 - "$d/.env.local" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
open(p, "w").write("\n".join("OPENCODE_SERVER_PASSWORD=short" if l.startswith("OPENCODE_SERVER_PASSWORD=") else l for l in lines) + "\n")
PY
    local h1; h1=$(hash_of "$d/.env.local")
    bash "$sh" --repo "$d" > "$d/out2.txt" 2>&1
    has 'WARN: OPENCODE_SERVER_PASSWORD is shorter than 12 chars' "$d/out2.txt" && ok 'short password warns' || bad 'short password warns'
    [ "$(hash_of "$d/.env.local")" = "$h1" ] && ok 'short password left unchanged' || bad 'short password left unchanged'
    has 'PASSWORD_ROTATED' "$d/out2.txt" && bad 'short password must not rotate' || ok 'short password does not rotate'

    # 3. missing password generates, announces, backs up, mode 600.
    python3 - "$d/.env.local" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()          # read BEFORE opening for write
open(p, "w").write("\n".join(l for l in lines if not l.startswith("OPENCODE_SERVER_PASSWORD=")) + "\n")
PY
    bash "$sh" --repo "$d" > "$d/out3.txt" 2>&1
    has 'PASSWORD_ROTATED' "$d/out3.txt" && ok 'missing password rotates (announced)' || bad 'missing password rotates (announced)'
    has 'CUSTOM_KEY=keep-me' "$d/.env.local" && ok 'unknown key survives a rotation' || bad 'unknown key survives a rotation'
    local plen; plen=$(pwlen "$d/.env.local")
    [ "${plen:-0}" -ge 12 ] && ok "generated password length ${plen} >= 12" || bad "generated password length (${plen}) >= 12"
    [ "$(stat -c '%a' "$d/.env.local")" = "600" ] && ok 'mode 0600 after write' || bad 'mode 0600 after write'
    [ "$(nlines "$d")" = "1" ] && ok 'a real change creates exactly one backup' || bad "a real change creates exactly one backup (n=$(nlines "$d"))"

    rm -f "$d"/.env.local "$d"/.env.local.bak.* "$d"/.env.local.tmp.* \
          "$d"/out1.txt "$d"/out2.txt "$d"/out3.txt "$d"/opencode.json "$d"/docker/Dockerfile
    rmdir "$d/docker" "$d"
    printf 'result: %s (%d pass, %d fail)\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf FAIL)" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

main "$@"
