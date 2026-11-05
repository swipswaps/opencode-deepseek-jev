#!/usr/bin/env bash
#
# env-inspect.sh — inspect .env.local without printing a value.
#
# The 2026-11-05 incident started with `cat -n .env.local`. This is the safe
# replacement: names, presence, lengths, file mode, and line count only.
#
#   ./scripts/env-inspect.sh
#   ./scripts/env-inspect.sh --env .env.local --json
#   ./scripts/env-inspect.sh --check OPENCODE_SERVER_PASSWORD
#   ./scripts/env-inspect.sh --self-test
#
# Exit 0 found/ok, 1 --check key missing, 2 usage/parse error.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
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

inspect_py() {
    # inspect_py FILE JSON CHECK — prints names/lengths only, never values.
    python3 - "$@" << 'PYEOF'
import json, os, sys
path, as_json, check = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
try:
    st = os.stat(path)
except OSError as e:
    print(json.dumps({"error": str(e)}))
    raise SystemExit(2)
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
keys = []
for n, line in enumerate(lines, 1):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        continue
    k, v = s.split("=", 1)
    if not k or not k.replace("_", "").isalnum():
        continue
    keys.append({"name": k, "line": n, "len": len(v)})
out = {"file": path, "mode": oct(st.st_mode & 0o777)[2:], "lines": len(lines),
       "keys": keys, "count": len(keys)}
if check:
    out["check"] = check
    out["present"] = any(k["name"] == check for k in keys)
if as_json:
    print(json.dumps(out))
    raise SystemExit(0 if (not check or out["present"]) else 1)
print("file: %s" % path)
print("mode: %s  lines: %d  keys: %d" % (out["mode"], out["lines"], out["count"]))
for k in keys:
    print("  %-32s present len=%d (line %d)" % (k["name"], k["len"], k["line"]))
if check:
    print("check %s: %s" % (check, "present" if out["present"] else "MISSING"))
    raise SystemExit(0 if out["present"] else 1)
PYEOF
}

self_test() {
    local work="" out="" fail=0
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    {
        printf '%s\n' '# fixture'
        printf '%s\n' 'DEEPSEEK_API_KEY=sk-short'
        printf '%s\n' 'OPENCODE_SERVER_PASSWORD=short'
        printf '%s\n' 'EMPTY='
    } > "$work/env.local"
    chmod 600 "$work/env.local"
    out=$(bash "${BASH_SOURCE[0]}" --env "$work/env.local" --json 2>&1)
    printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 3, "count"; assert d["mode"] == "600", "mode"; assert any(k["name"] == "OPENCODE_SERVER_PASSWORD" for k in d["keys"]), "name"' \
        || { printf 'FAIL json contract\n'; fail=1; }
    printf '%s' "$out" | grep -q "sk-short" && { printf 'FAIL value leaked\n'; fail=1; }
    printf '%s' "$out" | grep -q "short" && { printf 'FAIL password leaked\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --env "$work/env.local" --check OPENCODE_SERVER_PASSWORD > /dev/null 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL present check\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --env "$work/env.local" --check NOPE_NOT_THERE > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL missing check\n'; fail=1; }
    rm -f "$work/env.local"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'env-inspect: self-test PASS\n'; else printf 'env-inspect: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local REPO ENVF="" JSON=0 CHECK="" SELFTEST=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'ERROR: cannot resolve repo root\n' >&2; return 2; fi
    ENVF="$REPO/.env.local"
    while [ $# -gt 0 ]; do
        case "$1" in
            --env) ENVF="${2:-}"; shift 2 ;;
            --env=*) ENVF="${1#--env=}"; shift ;;
            --json) JSON=1; shift ;;
            --check) CHECK="${2:-}"; shift 2 ;;
            --check=*) CHECK="${1#--check=}"; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help)
                printf 'usage: %s [--env FILE] [--json] [--check KEY] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have python3 || { printf 'ERROR: python3 required\n' >&2; return 2; }
    [ -f "$ENVF" ] || { printf 'ERROR: no env file at %s\n' "$ENVF" >&2; return 2; }
    inspect_py "$ENVF" "$JSON" "$CHECK"
}

main "$@"
exit $?
