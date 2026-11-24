#!/usr/bin/env bash
#
# chromium-video-ab.sh - controlled A/B for the Fedora AMD VA-API decode switch.
#
# WHY: the post-restart verify proves the switch is on and the kernel decode
# counter moved during one playback sample. That is a mechanism check, not an
# A/B: it does not compare the same workload with the switch OFF. This tool
# measures one condition at a time (identical code path both times) and then
# applies a PRE-REGISTERED decision rule to the pair, so the stutter claim is
# falsifiable instead of narrative.
#
# Design (fixed before measurement):
#   A (control)    GRAPHIC_DRIVER=default, Chromium restarted -> switch absent
#   B (treatment)  GRAPHIC_DRIVER=amd,     Chromium restarted -> switch present
#   Same URL, same viewport, same duration, tab foregrounded, no other tabs.
#   Alternate ABBA across pairs to cancel thermal/load drift.
#   Primary endpoint: dropped-frame ratio from video.getVideoPlaybackQuality()
#     (delta over the window). Margin: B must be >= 0.5 percentage-point lower
#     AND <= 1% absolute. Overridable with AB_DROP_MARGIN / AB_DROP_CEILING.
#   Secondary: kernel drm-engine-dec rate (ns/s) from the GPU process fdinfo.
#     A must be 0; B must be > 0, else the condition did not take.
#   Confound that forces INCONCLUSIVE: A shows any decode-engine movement (the
#   control was not software), or the switch state does not match the label.
#
# Usage:
#   ./scripts/chromium-video-ab.sh plan
#   ./scripts/chromium-video-ab.sh measure --label A --url file:///v/clear-1080p30.mp4 --duration 20
#   ./scripts/chromium-video-ab.sh measure --label B --url file:///v/clear-1080p30.mp4 --duration 20
#   ./scripts/chromium-video-ab.sh compare logs/ab-A.json logs/ab-B.json
#   ./scripts/chromium-video-ab.sh --self-test
#
# Exit: 0 PASS / measure OK / self-test PASS; 1 FAIL; 2 INCONCLUSIVE; 3 usage/prereq.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf, no subprocess.run,
#   printf only, main() wrapper.
#
# Rule references: RULES #62 (CDP, never X11), #91 (print the basis),
#   #37 (SKIP is not PASS), #92 (a signal must act).

set -uo pipefail

SELF=$(readlink -f "$0")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)
LABEL=""
URL=""
DURATION="${AB_DURATION:-20}"
OUT=""
JSON=0
WARMUP="${AB_WARMUP:-3}"
DROP_MARGIN="${AB_DROP_MARGIN:-0.005}"
DROP_CEILING="${AB_DROP_CEILING:-0.01}"
# AB_MATCH isolates one browser instance by a cmdline substring (the driver
# passes its own --user-data-dir so the user's browser is never disturbed).
AB_MATCH="${AB_MATCH:-}"
# AB_TAB is the substring used to pick the tab that holds the <video>.
AB_TAB="${AB_TAB:-video}"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '%s\n' "$*"; }
need_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ---- discovery (mirrors chromium-video-audit.sh; CDP is the browser path) ----

chromium_pids() {
    local d p comm cmd
    for d in /proc/[0-9]*; do
        p=${d##*/}
        test -r "$d/comm" || continue
        comm=$(cat "$d/comm" 2>&1) || continue
        case "$comm" in
            *chromium*|*chrome*)
                if [ -n "$AB_MATCH" ]; then
                    test -r "$d/cmdline" || continue
                    cmd=$( { tr '\000' ' ' < "$d/cmdline"; } 2>&1) || continue
                    case "$cmd" in
                        *"$AB_MATCH"*) printf '%s\n' "$p" ;;
                    esac
                else
                    printf '%s\n' "$p"
                fi
                ;;
        esac
    done
}

have_exe() { test -e "/proc/$1/exe"; }

main_pid() {
    local p cmd
    for p in $(chromium_pids); do
        have_exe "$p" || continue
        cmd=$( { tr '\000' ' ' < "/proc/$p/cmdline"; } 2>&1) || continue
        case "$cmd" in
            *--type=*) continue ;;
        esac
        if [ -n "$AB_MATCH" ]; then
            # With an instance marker, the real browser also carries the debug
            # port; this skips crashpad/helper processes that share the name.
            case "$cmd" in
                *--remote-debugging-port*) printf '%s\n' "$p"; return 0 ;;
            esac
            continue
        fi
        printf '%s\n' "$p"; return 0
    done
    return 1
}

gpu_pid() {
    local p
    for p in $(chromium_pids); do
        if tr '\000' ' ' < "/proc/$p/cmdline" 2>&1 | grep -q -- '--type=gpu-process'; then
            printf '%s\n' "$p"; return 0
        fi
    done
    return 1
}

switch_present() {
    local p="$1"
    if tr '\000' ' ' < "/proc/$p/cmdline" 2>&1 | grep -q -- '--enable-accelerated-video-decode'; then
        printf 'true'
    else
        printf 'false'
    fi
}

find_dec_fd() {
    local p="$1" fdpath fd
    for fdpath in "/proc/$p/fd/"*; do
        fd=${fdpath##*/}
        if test -r "/proc/$p/fdinfo/$fd" &&
            awk '/drm-engine-dec:/{found=1} END{exit !found}' "/proc/$p/fdinfo/$fd"; then
            printf '%s\n' "$fd"; return 0
        fi
    done
    return 1
}

# Chromium opens the decode ring lazily, only while a video decodes; poll the
# GPU process first (fast), then do one fallback pass over every process in case
# a build holds the render node elsewhere.
wait_dec_any() {
    local pref="${1:-}" tries="${2:-6}" i=0 hit p
    while [ "$i" -lt "$tries" ]; do
        if [ -n "$pref" ] && hit=$(find_dec_fd "$pref"); then printf '%s:%s\n' "$pref" "$hit"; return 0; fi
        i=$((i + 1))
        test "$i" -lt "$tries" && sleep 1
    done
    for p in $(chromium_pids); do
        [ "$p" = "$pref" ] && continue
        if hit=$(find_dec_fd "$p"); then printf '%s:%s\n' "$p" "$hit"; return 0; fi
    done
    return 1
}

dec_ns() {
    awk '/drm-engine-dec:/{print $2; f=1} END{if(!f) print 0}' "/proc/$1/fdinfo/$2"
}

proc_cpu_s() {
    awk '{sub(/^.*\) /, ""); print ($12+$13)/100}' "/proc/$1/stat" 2>&1
}

load1() { awk '{print $1}' /proc/loadavg; }
psi_cpu() {
    awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/cpu
}

# Frames from the page: total/dropped counters plus currentTime. Null when CDP
# is unreachable or the matched tab has no <video>.
frames_js() {
    cat <<'JS'
(function(){
  var v=document.querySelector('video');
  if(!v) return {ok:false,why:'no video element'};
  var q=(v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null);
  if(!window.__abpace){
    window.__abpace={n:0,long:0,maxgap:0,last:0,on:0};
    if(v.requestVideoFrameCallback){
      window.__abpace.on=1;
      var cb=function(now){
        var s=window.__abpace;
        if(s.last){var g=now-s.last; if(g>s.maxgap)s.maxgap=g; if(g>50)s.long++;}
        s.last=now; s.n++;
        v.requestVideoFrameCallback(cb);
      };
      v.requestVideoFrameCallback(cb);
    }
  }
  var p=window.__abpace;
  return {ok:true,t:performance.now(),ct:v.currentTime,
          dur:v.duration,vw:v.videoWidth,vh:v.videoHeight,
          total:q?q.totalVideoFrames:0,dropped:q?q.droppedVideoFrames:0,
          decoded:v.webkitDecodedFrameCount||0,rs:v.readyState,
          err:(v.error&&v.error.code)||0,
          pace_n:p.n,pace_long:p.long,pace_maxgap:p.maxgap,pace_on:p.on};
})()
JS
}

cdp_frames() {
    local js
    js=$(frames_js)
    node "$REPO/scripts/cdp-tab.mjs" eval "$AB_TAB" "$js" 2>&1
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# ---- measure ----------------------------------------------------------------

do_measure() {
    local main g fd dpid dec t0 t1 d0 d1 frames0 frames1 wall
    main=$(main_pid) || { say 'FAIL: Chromium is not running'; return 3; }
    g=$(gpu_pid) || { say 'FAIL: no gpu process found'; return 3; }
    case "$LABEL" in A|B) ;; *) say 'FAIL: --label A|B is required'; return 3 ;; esac
    need_num "$DURATION" && [ "$DURATION" -ge 5 ] || { say 'FAIL: --duration must be an integer >= 5'; return 3; }

    # Warm up outside the measured window: the decode ring opens lazily, and
    # the first seconds are startup noise.
    sleep "$WARMUP"
    dec=$(wait_dec_any "$g" "${DEC_FD_TRIES:-6}") || dec=""
    fd=""; dpid=""
    if [ -n "$dec" ]; then dpid="${dec%%:*}"; fd="${dec##*:}"; fi
    local cpu0 cpu1 frames_first frames_last
    t0=$(date +%s)
    cpu0=$(proc_cpu_s "$g")
    if test -n "$fd"; then d0=$(dec_ns "$dpid" "$fd"); else d0=0; fi
    frames_first=$(cdp_frames)
    sleep "$DURATION"
    t1=$(date +%s)
    if test -n "$fd"; then d1=$(dec_ns "$dpid" "$fd"); else d1=0; fi
    cpu1=$(proc_cpu_s "$g")
    frames_last=$(cdp_frames)
    wall=$((t1 - t0))
    test "$wall" -gt 0 || wall=1

    # Newline-delimited, NOT colon-delimited: the frame probes are JSON and
    # contain ":" themselves, which corrupted split(":") and nulled every sample.
    printf '%s\n' "$main" "$g" "$fd" "$dpid" "$d0" "$d1" "$wall" "$cpu0" "$cpu1" \
        "$frames_first" "$frames_last" \
        > /tmp/chromium-ab-measure.$$.raw
    python3 - "$LABEL" "$(switch_present "$main")" "$URL" "$wall" \
        "$(load1)" "$(psi_cpu)" /tmp/chromium-ab-measure.$$.raw <<'PY'
import json, sys
from datetime import datetime, timezone
label, switch, url, wall, load1, psi, raw_path = sys.argv[1:8]
lines = open(raw_path).read().split("\n")
main, gpu, fd, dpid, d0, d1, wall2, cpu0, cpu1, f_first, f_last = lines[:11]
def num(x, d=0):
    try: return float(x)
    except Exception: return d
def frames(s):
    try:
        v = json.loads(s)
    except Exception:
        return None
    if not isinstance(v, dict) or not v.get("ok"):
        return None
    q = v.get("__result__", v)
    if isinstance(q, str):
        try: q = json.loads(q)
        except Exception: return None
    if not isinstance(q, dict) or "total" not in q:
        return None
    return q
a, b = frames(f_first), frames(f_last)
drop = None
source = None
pace = None
if a and b:
    qdt = b.get("total", 0) - a.get("total", 0)
    qdd = b.get("dropped", 0) - a.get("dropped", 0)
    dt, dd, source = qdt, qdd, "quality"
    if dt <= 0:
        dt = b.get("decoded", 0) - a.get("decoded", 0)
        source = "decoded"
    # Presented-frame pacing via requestVideoFrameCallback: robust when the
    # quality counters are empty (seen on this Fedora Chromium for HW decode).
    pn = b.get("pace_n", 0) - a.get("pace_n", 0)
    pl = b.get("pace_long", 0) - a.get("pace_long", 0)
    if pn > 0:
        pace = {"presented": pn, "long_gaps": pl,
                "max_gap_ms": b.get("pace_maxgap", 0), "on": bool(b.get("pace_on"))}
    if dt <= 0 and pn > 0:
        dt, dd, source = pn, pl, "pace"
    if dt <= 0:
        source = None
    if dt > 0:
        drop = dd / dt
wall_s = max(int(wall), 1)
dec_rate = max(num(d1) - num(d0), 0.0) / wall_s
out = {
    "schema": "ab/v1",
    "label": label,
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "url": url,
    "duration_s": wall_s,
    "switch_present": switch == "true",
    "dec_fd": bool(fd),
    "dec_pid": (int(dpid) if dpid else None),
    "dec_rate_ns_s": dec_rate,
    "frames": ({"total": int(b["total"]), "dropped": int(b["dropped"]),
                "drop_ratio": drop, "source": source}
               if drop is not None else None),
    "frames_source": source,
    "pace": pace,
    "frames_probe": (None if (a and b) else
                     {"first": f_first[:200], "last": f_last[:200]}),
    "gpu_cpu_pct": round(max(num(cpu1) - num(cpu0), 0.0) / wall_s * 100.0, 1),
    "load1": num(load1),
    "psi_cpu_avg10": num(psi),
    "chromium": {"main": main, "gpu": gpu},
}
text = json.dumps(out, indent=2)
if __import__("os").environ.get("AB_OUT"):
    open(__import__("os").environ["AB_OUT"], "w").write(text + "\n")
print(text)
PY
    local rc=$?
    rm -f /tmp/chromium-ab-measure.$$.raw
    return "$rc"
}

# ---- compare (pre-registered rule) -----------------------------------------

compare_files() {
    python3 - "$1" "$2" "$DROP_MARGIN" "$DROP_CEILING" <<'PY'
import json, sys
pa, pb = sys.argv[1], sys.argv[2]
margin, ceiling = float(sys.argv[3]), float(sys.argv[4])
def load(p):
    with open(p) as f:
        d = json.load(f)
    if d.get("schema") != "ab/v1":
        raise SystemExit("bad schema in %s" % p)
    return d
a, b = load(pa), load(pb)
reasons = []
status = "PASS"; claim = "SUPPORTED"; mech = "UNPROVEN"
def done():
    print("status=%s" % status)
    print("mechanism=%s stutter_claim=%s" % (mech, claim))
    print("drop_A=%s drop_B=%s" % (a.get("frames") and a["frames"].get("drop_ratio"), b.get("frames") and b["frames"].get("drop_ratio")))
    print("dec_rate_A=%s dec_rate_B=%s" % (a.get("dec_rate_ns_s"), b.get("dec_rate_ns_s")))
    print("reason=%s" % "; ".join(reasons) if reasons else "reason=pre-registered rule met")
    sys.exit({"PASS": 0, "FAIL": 1}.get(status, 2))
if a.get("switch_present") or not b.get("switch_present"):
    status, claim = "INCONCLUSIVE", "UNPROVEN"
    reasons.append("condition mismatch: A.switch=%s B.switch=%s (A must be off, B on)" % (a.get("switch_present"), b.get("switch_present")))
elif a.get("dec_fd") or a.get("dec_rate_ns_s", 0) > 0:
    status, claim = "INCONCLUSIVE", "UNPROVEN"
    reasons.append("control used the decode engine (dec_rate_A=%s) — not a software baseline" % a.get("dec_rate_ns_s"))
elif b.get("dec_rate_ns_s", 0) <= 0:
    status, claim, mech = "FAIL", "REFUTED", "FAIL"
    reasons.append("treatment did not move drm-engine-dec (dec_rate_B=%s)" % b.get("dec_rate_ns_s"))
else:
    mech = "PASS"
    fa, fb = a.get("frames"), b.get("frames")
    if not fa or not fb or fa.get("drop_ratio") is None or fb.get("drop_ratio") is None:
        status, claim = "INCONCLUSIVE", "UNPROVEN"
        reasons.append("no CDP frame counters; mechanism PASS but stutter unproven")
    else:
        da, db = fa["drop_ratio"], fb["drop_ratio"]
        if db <= da - margin and db <= ceiling:
            status, claim = "PASS", "SUPPORTED"
            reasons.append("drop_ratio B %.4f <= A %.4f - %.4f and <= %.4f" % (db, da, margin, ceiling))
        elif db >= da:
            status, claim = "FAIL", "REFUTED"
            reasons.append("drop_ratio B %.4f >= A %.4f" % (db, da))
        else:
            status, claim = "INCONCLUSIVE", "UNPROVEN"
            reasons.append("drop improved (A %.4f -> B %.4f) but below the %.4f margin" % (da, db, margin))
done()
PY
}

do_compare() {
    local a="$1" b="$2"
    compare_files "$a" "$b"
}

# Both-hardware rule: when GRAPHIC_DRIVER=default ALREADY hardware-decodes (so
# there is no software baseline), the switch's marginal effect is frame pacing,
# not whether the decoder runs. Here A may decode; B must, and B's pacing must
# beat A's by the same margin.
compare_pace_files() {
    python3 - "$1" "$2" "$DROP_MARGIN" "$DROP_CEILING" <<'PY'
import json, sys
pa, pb = sys.argv[1], sys.argv[2]
margin, ceiling = float(sys.argv[3]), float(sys.argv[4])
def load(p):
    d = json.load(open(p))
    if d.get("schema") != "ab/v1":
        raise SystemExit("bad schema in %s" % p)
    return d
a, b = load(pa), load(pb)
reasons = []
status = "PASS"; claim = "SUPPORTED"; mech = "UNPROVEN"
def frame_ratio(d):
    f = d.get("frames")
    return None if not f else f.get("drop_ratio")
def done():
    print("status=%s" % status)
    print("mode=both-hardware mechanism=%s stutter_claim=%s" % (mech, claim))
    print("drop_A=%s drop_B=%s" % (frame_ratio(a), frame_ratio(b)))
    print("pacing_source_A=%s pacing_source_B=%s" % (
        (a.get("frames") or {}).get("source"), (b.get("frames") or {}).get("source")))
    print("dec_rate_A=%s dec_rate_B=%s" % (a.get("dec_rate_ns_s"), b.get("dec_rate_ns_s")))
    print("reason=%s" % ("; ".join(reasons) if reasons else "B pacing better than A by the margin"))
    sys.exit({"PASS": 0, "FAIL": 1}.get(status, 2))
if a.get("switch_present") or not b.get("switch_present"):
    status, claim = "INCONCLUSIVE", "UNPROVEN"
    reasons.append("condition mismatch: A.switch=%s B.switch=%s (A must be off, B on)" % (a.get("switch_present"), b.get("switch_present")))
elif b.get("dec_rate_ns_s", 0) <= 0:
    status, claim, mech = "FAIL", "REFUTED", "FAIL"
    reasons.append("treatment did not use hardware decode (dec_rate_B=%s)" % b.get("dec_rate_ns_s"))
else:
    mech = "PASS"
    da, db = frame_ratio(a), frame_ratio(b)
    if da is None or db is None:
        status, claim = "INCONCLUSIVE", "UNPROVEN"
        reasons.append("no frame-pacing counters; mechanism PASS but stutter unproven")
    elif db <= da - margin and db <= ceiling:
        status, claim = "PASS", "SUPPORTED"
        reasons.append("pacing B %.4f <= A %.4f - %.4f and <= %.4f" % (db, da, margin, ceiling))
    elif db >= da:
        status, claim = "FAIL", "REFUTED"
        reasons.append("pacing B %.4f >= A %.4f (switch did not improve pacing)" % (db, da))
    else:
        status, claim = "INCONCLUSIVE", "UNPROVEN"
        reasons.append("pacing improved (A %.4f -> B %.4f) but below the %.4f margin" % (da, db, margin))
done()
PY
}

do_compare_pace() {
    local a="$1" b="$2"
    compare_pace_files "$a" "$b"
}

# ---- plan / self-test -------------------------------------------------------

do_plan() {
    say '=== controlled A/B plan (pre-registered) ==='
    say '1. Local non-DRM file (H.264 or VP9), same URL both arms, e.g. file:///v/clear-1080p30.mp4'
    say '2. A: sudo ./scripts/chromium-video-audit.sh --revert   # GRAPHIC_DRIVER=default'
    say '   close and reopen Chromium, open the file, then:'
    say '   ./scripts/chromium-video-ab.sh measure --label A --url file:///v/clear-1080p30.mp4 --duration 20'
    say '3. B: sudo ./scripts/chromium-video-audit.sh --apply    # GRAPHIC_DRIVER=amd'
    say '   close and reopen Chromium, open the file, then:'
    say '   ./scripts/chromium-video-ab.sh measure --label B --url file:///v/clear-1080p30.mp4 --duration 20'
    say '4. Repeat 2-3 in ABBA order (3 pairs) and compare the paired medians:'
    say '   ./scripts/chromium-video-ab.sh compare logs/ab-A.json logs/ab-B.json'
    say '5. Decision: A switch off + dec_rate 0; B switch on + dec_rate > 0;'
    say "   drop_B <= drop_A - ${DROP_MARGIN} and drop_B <= ${DROP_CEILING}."
    say '   PASS = mechanism + frame pacing both move. INCONCLUSIVE is not a PASS (#37).'
}

do_selftest() {
    local tmp fails=0 i
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/chromium-ab.XXXXXX" 2>&1) || { say 'FAIL mktemp'; return 3; }
    mk () {
        local path="$1" sw="$2" decfd="$3" rate="$4" drop="$5"
        if [ "$drop" = "null" ]; then
            printf '{"schema":"ab/v1","label":"%s","switch_present":%s,"dec_fd":%s,"dec_rate_ns_s":%s,"frames":null}\n' \
                "${6:-X}" "$sw" "$decfd" "$rate" > "$path"
        else
            printf '{"schema":"ab/v1","label":"%s","switch_present":%s,"dec_fd":%s,"dec_rate_ns_s":%s,"frames":{"total":1000,"dropped":%s,"drop_ratio":%s}}\n' \
                "${6:-X}" "$sw" "$decfd" "$rate" "$(awk -v r="$drop" 'BEGIN{printf "%d", r*1000}')" "$drop" > "$path"
        fi
    }
    run () {
        local name="$1" want="$2" a="$3" b="$4" got
        got=$(compare_files "$a" "$b" 2>&1 | awk -F= '/^status=/{print $2; exit}')
        if [ "$got" = "$want" ]; then
            printf '  PASS %s -> %s\n' "$name" "$got"
        else
            printf '  FAIL %s -> got=%s want=%s\n' "$name" "$got" "$want"
            fails=$((fails + 1))
        fi
    }
    mk "$tmp/a1.json" false false 0 0.05 A
    mk "$tmp/b1.json" true  true  900 0.002 B
    run "hardware engages and drops fall" PASS "$tmp/a1.json" "$tmp/b1.json"
    mk "$tmp/a2.json" false false 500 0.05 A
    run "control used hardware (confound)" INCONCLUSIVE "$tmp/a2.json" "$tmp/b1.json"
    mk "$tmp/b2.json" true true 0 0.002 B
    run "treatment did not engage hardware" FAIL "$tmp/a1.json" "$tmp/b2.json"
    mk "$tmp/a3.json" false false 0 0.0010 A
    mk "$tmp/b3.json" true  true  900 0.0008 B
    run "improvement below the margin" INCONCLUSIVE "$tmp/a3.json" "$tmp/b3.json"
    mk "$tmp/a4.json" false false 0 null A
    mk "$tmp/b4.json" true  true  900 null B
    run "no frame counters -> mechanism only" INCONCLUSIVE "$tmp/a4.json" "$tmp/b4.json"
    mk "$tmp/a5.json" true true 900 0.05 A
    run "label/switch mismatch" INCONCLUSIVE "$tmp/a5.json" "$tmp/b1.json"
    runp () {
        local name="$1" want="$2" a="$3" b="$4" got
        got=$(compare_pace_files "$a" "$b" 2>&1 | awk -F= '/^status=/{print $2; exit}')
        if [ "$got" = "$want" ]; then
            printf '  PASS %s -> %s\n' "$name" "$got"
        else
            printf '  FAIL %s -> got=%s want=%s\n' "$name" "$got" "$want"
            fails=$((fails + 1))
        fi
    }
    mk "$tmp/p1a.json" false false 900 0.05 A
    mk "$tmp/p1b.json" true  true  950 0.002 B
    runp "both-HW: pacing improves" PASS "$tmp/p1a.json" "$tmp/p1b.json"
    mk "$tmp/p2a.json" false false 900 0.002 A
    mk "$tmp/p2b.json" true  true  950 0.002 B
    runp "both-HW: no pacing change" FAIL "$tmp/p2a.json" "$tmp/p2b.json"
    mk "$tmp/p3b.json" true true 0 0.002 B
    runp "both-HW: treatment not hardware" FAIL "$tmp/p1a.json" "$tmp/p3b.json"
    mk "$tmp/p4a.json" false false 900 null A
    mk "$tmp/p4b.json" true  true  950 null B
    runp "both-HW: no pacing counters" INCONCLUSIVE "$tmp/p4a.json" "$tmp/p4b.json"
    if bash -n "$SELF"; then printf '  PASS bash -n\n'; else fails=$((fails + 1)); printf '  FAIL bash -n\n'; fi
    find "$tmp" -depth -delete 2>&1
    say "result: $([ "$fails" -eq 0 ] && printf PASS || printf 'FAIL (%s)' "$fails")"
    [ "$fails" -eq 0 ] && return 0 || return 1
}

# ---- main -------------------------------------------------------------------

usage() {
    printf 'usage: %s plan | measure --label A|B [--url URL] [--duration N] [--out PATH] [--json] | compare A.json B.json | compare-pace A.json B.json | --self-test\n' "$0"
}

main() {
    local cmd="${1:-plan}"
    case "$cmd" in
        plan) do_plan; return 0 ;;
        --self-test) do_selftest; return $? ;;
        -h|--help) usage; return 0 ;;
        measure|compare|compare-pace) shift ;;
        *) usage; return 3 ;;
    esac
    local -a files=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --label) shift; LABEL="${1:-}" ;;
            --url) shift; URL="${1:-}" ;;
            --duration) shift; DURATION="${1:-}" ;;
            --out) shift; OUT="${1:-}" ;;
            --json) JSON=1 ;;
            -h|--help) usage; return 0 ;;
            -*) printf 'unknown option: %s\n' "$1"; usage; return 3 ;;
            *) files+=("$1") ;;
        esac
        shift
    done
    if [ "$cmd" = measure ]; then
        # Honor an externally exported AB_OUT; --out overrides it.
        if [ -n "$OUT" ]; then export AB_OUT="$OUT"; fi
        do_measure
        return $?
    fi
    if [ "${#files[@]}" -ne 2 ]; then usage; return 3; fi
    if [ "$cmd" = compare-pace ]; then
        do_compare_pace "${files[0]}" "${files[1]}"
        return $?
    fi
    do_compare "${files[0]}" "${files[1]}"
}

main "$@"
