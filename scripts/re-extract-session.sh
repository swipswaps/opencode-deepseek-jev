#!/usr/bin/env bash
#
# re-extract-session.sh — reproduce a browser-extracted session transcript log.
#
# Method: DOM for shape (the tab must render), API-behind-UI for substance
# (fetch /session/<id>/message in page context via scripts/cdp-tab.mjs),
# chunked transfer for size, then VERIFY before write: JSON parses, single
# session id, reassembled length equals the probed length, sha256 cross-check
# against the in-page digest. Growth mid-pull aborts unless --allow-growth.
#
# Fidelity note: reasoning capped at 300 chars, tool outputs at 1500 chars —
# shape-preserving extract, lossy on long fields (every cap prints its mark).
# The lossless artifact is the raw payload, not the transcript.
#
# Usage: re-extract-session.sh <session-id> [out-file] [--allow-growth]
#        re-extract-session.sh --check | --self-test
#   out-file defaults to <repo>/logs/ses_<id>.txt (gitignored).
# Needs: node, scripts/cdp-tab.mjs, OPENCODE_SERVER_PASSWORD in env for live
# extraction (never argv). --self-test needs no browser (stub node).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

usage() {
    printf 'usage: %s <session-id> [out-file] [--allow-growth] [--check] [--self-test]\n' "$0"
}

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

# run_transform RAW OUT SID HEX EXPLEN — verify (length, sha256, id uniformity)
# then render the transcript. No browser. Returns nonzero with a named reason.
run_transform() {
python3 - "$1" "$2" "$3" "$4" "$5" <<'PY_EOF'
import hashlib, json, sys, datetime
raw, out, sid, hexwant, explen = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
blob = open(raw, encoding="utf-8").read()
if len(blob) != int(explen):
    sys.exit("length mismatch: reassembled=%d probed=%s" % (len(blob), explen))
have = hashlib.sha256(blob.encode("utf-8")).hexdigest()
if have != hexwant.strip().strip('"'):
    sys.exit("sha256 mismatch: page=%s local=%s" % (hexwant, have))
d = json.loads(blob)
if not isinstance(d, list):
    sys.exit("payload is not a list")
ids = set()
for i, m in enumerate(d):
    if not isinstance(m, dict):
        sys.exit("message #%d is not an object" % i)
    info = m.get("info")
    sidv = info.get("sessionID") if isinstance(info, dict) else None
    if sidv is None:
        sys.exit("message #%d missing info.sessionID" % i)
    ids.add(sidv)
assert len(ids) == 1 and sid in ids, "mixed/foreign session ids: %s" % sorted(str(x) for x in ids)
def ts(info):
    try:
        ms = (info.get("time") or {}).get("created") if isinstance(info, dict) else None
        return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%m-%d %H:%M")
    except (TypeError, ValueError, OSError, AttributeError):
        return "?"
L = ["%s browser-extracted log" % sid, "=" * 70,
     "extracted_utc: " + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
     "messages: %d  parts: %d  sha256: %s" % (len(d), sum(len(m.get("parts") or []) for m in d), have), ""]
for n, m in enumerate(d):
    info = m.get("info", {}) if isinstance(m, dict) else {}
    if not isinstance(info, dict):
        info = {}
    L.append("---")
    L.append("[%s #%d] %s  %s" % (ts(info), n, info.get("role", "?"), info.get("id", "?")))
    for p in (m.get("parts") or []):
        if not isinstance(p, dict):
            continue
        t = p.get("type")
        if t == "text":
            L.append(p.get("text", ""))
        elif t == "reasoning":
            tx = p.get("text", "") or ""
            L.append("[reasoning %d chars] %s%s" % (len(tx), tx[:300], " …[truncated]" if len(tx) > 300 else ""))
        elif t == "tool":
            st = p.get("state") if isinstance(p.get("state"), dict) else {}
            L.append("[tool %s %s] %s" % (p.get("tool", "?"), st.get("status", "?"), json.dumps(st.get("input", ""))[:300]))
            if st.get("output"):
                L.append("  output [%d chars, showing 1500]: %s%s" % (len(st["output"]), st["output"][:1500], " …[truncated]" if len(st["output"]) > 1500 else ""))
        elif t == "file":
            L.append("[file] " + str(p.get("filename") or p.get("url") or ""))
        elif t not in ("step-start", "step-finish"):
            L.append("[%s] %s" % (t, json.dumps(p)[:200]))
    L.append("")
L.append("--- end (%d messages) ---" % len(d))
open(out, "w").write("\n".join(L) + "\n")
print("wrote %s (%d bytes)" % (out, len("\n".join(L)) + 1))
PY_EOF
}

# extract REPO SID OUT ALLOW — live browser pull then run_transform.
extract() {
    local repo="$1" sid="$2" out="$3" allow="$4"
    local tab="$sid" base="http://127.0.0.1:4096/server/aHR0cDovLzEyNy4wLjAuMTo0MDk2/session/$sid"
    local raw="${SES_RAW:-/tmp/ses_raw.txt}" chunk="${SES_CHUNK:-/tmp/chunk.json}"
    node "$repo/scripts/cdp-tab.mjs" openauth "$base" || return 2
    local n0 len
    n0=$(node "$repo/scripts/cdp-tab.mjs" eval "$tab" 'fetch("/session/'"$sid"'/message").then(r=>r.json()).then(a=>a.length)') || return 2
    len=$(node "$repo/scripts/cdp-tab.mjs" eval "$tab" 'fetch("/session/'"$sid"'/message").then(r=>r.text()).then(t=>(window.__sesT=t,t.length))') || return 2
    case "$n0" in ''|*[!0-9]*) printf 'bad count probe: %s\n' "$n0"; return 2;; esac
    case "$len" in ''|*[!0-9]*) printf 'bad length probe: %s\n' "$len"; return 2;; esac
    printf 'messages: %s chars: %s\n' "$n0" "$len"
    local hex
    hex=$(node "$repo/scripts/cdp-tab.mjs" eval "$tab" 'crypto.subtle.digest("SHA-256",new TextEncoder().encode(window.__sesT)).then(b=>[...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join(""))') || return 2
    rm -f "$raw" "$chunk"
    local s n=0
    for s in $(seq 0 400000 "$len"); do
        node "$repo/scripts/cdp-tab.mjs" eval "$tab" "window.__sesT.slice($s,$((s+400000)))" > "$chunk" || return 2
        SES_RAW_PATH="$raw" SES_CHUNK_PATH="$chunk" python3 -c "import json,os; open(os.environ['SES_RAW_PATH'],'a').write(json.load(open(os.environ['SES_CHUNK_PATH'])))" || return 2
        n=$((n+1))
    done
    printf 'chunks: %s\n' "$n"
    local n1
    n1=$(node "$repo/scripts/cdp-tab.mjs" eval "$tab" 'fetch("/session/'"$sid"'/message").then(r=>r.json()).then(a=>a.length)') || return 2
    case "$n1" in ''|*[!0-9]*) printf 'bad recount probe: %s\n' "$n1"; return 2;; esac
    if [ "$n1" != "$n0" ] && [ "$allow" -ne 1 ]; then
        printf 'GATE FAIL: session grew mid-pull (%s -> %s); re-run with --allow-growth\n' "$n0" "$n1"
        return 2
    fi
    [ "$n1" != "$n0" ] && printf 'NOTE: grew %s -> %s during pull; log covers probed %s\n' "$n0" "$n1" "$n0"
    run_transform "$raw" "$out" "$sid" "$hex" "$len"
}

check_prereqs() {
    local repo="$1" fail=0
    if command -v node > /dev/null; then printf 'node: present\n'; else printf 'node: MISSING\n'; fail=1; fi
    if [ -f "$repo/scripts/cdp-tab.mjs" ]; then printf 'cdp-tab.mjs: present\n'; else printf 'cdp-tab.mjs: MISSING\n'; fail=1; fi
    if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then printf 'password: set (name only, value never printed)\n'; else printf 'password: MISSING (export OPENCODE_SERVER_PASSWORD)\n'; fail=1; fi
    printf 'browser: not checkable offline (extraction fails loudly at openauth without one)\n'
    return "$fail"
}

self_test() {
    local fail=0 work=""
    work=$(mktemp -d)
    # stub `node`: emulates cdp-tab eval responses from $STUB_FIXTURE.
    # STUB_GROW=1 makes the second a.length probe return count+1 (growth path).
    cat > "$work/stubbin-node" <<'STUBEOF'
#!/usr/bin/env bash
expr="$*"
fix="${STUB_FIXTURE:-}"
state="${STUB_STATE:-/tmp}"
[ -n "$fix" ] || { printf 'stub: STUB_FIXTURE unset\n' >&2; exit 3; }
case "$expr" in
    *openauth*) exit 0 ;;
esac
nfile="$state/n"
n=0
[ -f "$nfile" ] && n=$(cat "$nfile")
n=$((n + 1))
printf '%s' "$n" > "$nfile"
case "$expr" in
    *a.length*)
        if [ "${STUB_GROW:-0}" = "1" ] && [ "$n" -gt 1 ]; then
            python3 -c "import json; print(len(json.load(open('$fix')))+1)"
        else
            python3 -c "import json; print(len(json.load(open('$fix'))))"
        fi ;;
    *crypto.subtle*)
        python3 -c "import json,hashlib; print(json.dumps(hashlib.sha256(open('$fix','rb').read()).hexdigest()))" ;;
    *slice\(*)
        ab=$(printf '%s' "$expr" | grep -oE 'slice\([0-9]+,[0-9]+\)' | head -1 | tr -cd '0-9,')
        a=${ab%,*}; b=${ab#*,}
        python3 -c "import json; t=open('$fix',encoding='utf-8').read(); print(json.dumps(t[$a:$b]))" ;;
    *__sesT*)
        python3 -c "print(len(open('$fix',encoding='utf-8').read()))" ;;
    *) printf 'stub: unhandled eval: %s\n' "$expr" >&2; exit 3 ;;
esac
STUBEOF
    chmod +x "$work/stubbin-node"
    mkdir -p "$work/stubbin"
    mv "$work/stubbin-node" "$work/stubbin/node"
    # fixture: 2 messages; m1 has null parts + a long output (truncation mark)
    python3 - "$work/fix.json" <<'FIXEOF'
import json, sys
long_out = "O" * 2000
msgs = [
    {"info": {"sessionID": "ses_test", "role": "user", "id": "m0",
              "time": {"created": 1759530000000}},
     "parts": [{"type": "text", "text": "hello"},
               {"type": "tool", "tool": "bash",
                "state": {"status": "completed", "input": {"command": "ls"},
                           "output": long_out}},
               {"type": "reasoning", "text": "R" * 500},
               {"type": "mystery", "x": 1},
               {"type": "file", "filename": "a.txt"}]},
    {"info": {"sessionID": "ses_test", "role": "assistant", "id": "m1",
              "time": {"created": 1759530060000}},
     "parts": None},
]
open(sys.argv[1], "w").write(json.dumps(msgs))
print("fixture messages=2")
FIXEOF
    export PATH="$work/stubbin:$PATH"
    export STUB_FIXTURE="$work/fix.json" STUB_STATE="$work/state" OPENCODE_SERVER_PASSWORD=dummy
    export STUB_GROW=0
    mkdir -p "$work/state"
    python3 -c "import json; open('$work/payload.txt','w').write(open('$work/fix.json').read())"
    export SES_RAW="$work/raw.txt" SES_CHUNK="$work/chunk.json"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$repo/opencode.json" ] || repo="$PWD"
    printf '%s\n' "--- T1 normal extract ---"
    if extract "$repo" "ses_test" "$work/out.txt" 0 > "$work/t1.log" 2>&1; then
        grep -q "browser-extracted log" "$work/out.txt" \
        && grep -q "truncated" "$work/out.txt" \
        && printf '  PASS normal extract writes transcript with truncation marks\n' \
        || { printf '  FAIL normal extract content\n'; fail=1; }
    else
        printf '  FAIL normal extract exit code\n'; fail=1
    fi
    printf '%s\n' "--- T2 growth without flag aborts ---"
    export STUB_GROW=1
    : > "$work/state/n"
    if extract "$repo" "ses_test" "$work/out2.txt" 0 > "$work/t2.log" 2>&1; then
        printf '  FAIL growth without flag should abort\n'; fail=1
    else
        grep -q "GATE FAIL" "$work/t2.log" && printf '  PASS growth aborts loudly\n' || { printf '  FAIL growth abort message\n'; fail=1; }
    fi
    printf '%s\n' "--- T3 growth with flag passes + NOTE ---"
    export STUB_GROW=1
    : > "$work/state/n"
    if extract "$repo" "ses_test" "$work/out3.txt" 1 > "$work/t3.log" 2>&1; then
        grep -q "NOTE: grew" "$work/t3.log" && printf '  PASS allow-growth passes with NOTE\n' || { printf '  FAIL allow-growth NOTE\n'; fail=1; }
    else
        printf '  FAIL allow-growth exit code\n'; fail=1
    fi
    export STUB_GROW=0
    printf '%s\n' "--- T4 null parts transform ---"
    if run_transform "$work/fix.json" "$work/out4.txt" "ses_test" "$(python3 -c "import json,hashlib; print(json.dumps(hashlib.sha256(open('$work/fix.json','rb').read()).hexdigest()))")" "$(python3 -c "print(len(open('$work/fix.json',encoding='utf-8').read()))")" > "$work/t4.log" 2>&1; then
        printf '  PASS null-parts transform\n'
    else
        printf '  FAIL null-parts transform\n'; fail=1
    fi
    printf '%s\n' "--- T5 missing info aborts naming index ---"
    python3 - "$work/noid.json" <<'NIXEOF'
import json, sys
open(sys.argv[1], "w").write(json.dumps([{"parts": [{"type": "text", "text": "x"}]}]))
NIXEOF
    if run_transform "$work/noid.json" "$work/out5.txt" "ses_test" "$(python3 -c "import json,hashlib; print(json.dumps(hashlib.sha256(open('$work/noid.json','rb').read()).hexdigest()))")" "$(python3 -c "print(len(open('$work/noid.json',encoding='utf-8').read()))")" > "$work/t5.log" 2>&1; then
        printf '  FAIL missing-info should abort\n'; fail=1
    else
        grep -q "message #0 missing" "$work/t5.log" && printf '  PASS missing-info aborts naming index\n' || { printf '  FAIL missing-info message\n'; fail=1; }
    fi
    printf '%s\n' "--- T6 mixed ids abort ---"
    python3 - "$work/mixed.json" <<'MIXEOF'
import json, sys
open(sys.argv[1], "w").write(json.dumps([
  {"info": {"sessionID": "a", "role": "user", "id": "m0", "time": {"created": 1}}, "parts": []},
  {"info": {"sessionID": "b", "role": "user", "id": "m1", "time": {"created": 1}}, "parts": []}]))
MIXEOF
    if run_transform "$work/mixed.json" "$work/out6.txt" "a" "$(python3 -c "import json,hashlib; print(json.dumps(hashlib.sha256(open('$work/mixed.json','rb').read()).hexdigest()))")" "$(python3 -c "print(len(open('$work/mixed.json',encoding='utf-8').read()))")" > "$work/t6.log" 2>&1; then
        printf '  FAIL mixed-ids should abort\n'; fail=1
    else
        grep -q "mixed/foreign" "$work/t6.log" && printf '  PASS mixed-ids aborts\n' || { printf '  FAIL mixed-ids message\n'; fail=1; }
    fi
    printf '%s\n' "--- T7 arg parsing ---"
    ( main --bogus > /dev/null 2>&1 ); [ "$?" -eq 2 ] && printf '  PASS unknown flag exits 2\n' || { printf '  FAIL unknown flag\n'; fail=1; }
    ( main > /dev/null 2>&1 ); [ "$?" -eq 2 ] && printf '  PASS no args exits 2\n' || { printf '  FAIL no args\n'; fail=1; }
    rm -f "$work"/payload.txt "$work"/fix.json "$work"/noid.json "$work"/mixed.json \
          "$work"/raw.txt "$work"/chunk.json "$work"/out*.txt "$work"/t*.log \
          "$work"/stubbin/node "$work"/state/n
    rmdir "$work/stubbin" "$work/state" "$work"
    printf 'result: %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local sid="" out="" allow=0 selftest=0 check=0 a=""
    for a in "$@"; do
        case "$a" in
            --allow-growth) allow=1 ;;
            --self-test) selftest=1 ;;
            --check) check=1 ;;
            -h|--help) usage; return 0 ;;
            -*) printf 'unknown flag: %s\n' "$a"; return 2 ;;
            *) if [ -z "$sid" ]; then sid="$a"; elif [ -z "$out" ]; then out="$a"; else printf 'unknown arg: %s\n' "$a"; return 2; fi ;;
        esac
    done
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$repo/opencode.json" ] || repo="$PWD"
    if [ "$selftest" -eq 1 ]; then self_test; return $?; fi
    if [ "$check" -eq 1 ]; then check_prereqs "$repo"; return $?; fi
    [ -n "$sid" ] || { usage; return 2; }
    out="${out:-$repo/logs/ses_${sid}.txt}"
    [ -n "${OPENCODE_SERVER_PASSWORD:-}" ] || { printf 'need OPENCODE_SERVER_PASSWORD in env\n'; return 2; }
    extract "$repo" "$sid" "$out" "$allow"
}

check_prereqs() {
    local repo="$1" fail=0
    if command -v node > /dev/null; then printf 'node: present\n'; else printf 'node: MISSING\n'; fail=1; fi
    if [ -f "$repo/scripts/cdp-tab.mjs" ]; then printf 'cdp-tab.mjs: present\n'; else printf 'cdp-tab.mjs: MISSING\n'; fail=1; fi
    if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then printf 'password: set (name only, value never printed)\n'; else printf 'password: MISSING (export OPENCODE_SERVER_PASSWORD)\n'; fail=1; fi
    printf 'browser: not checkable offline (extraction fails loudly at openauth without one)\n'
    return "$fail"
}

main "$@"
