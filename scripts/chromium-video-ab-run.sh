#!/usr/bin/env bash
#
# chromium-video-ab-run.sh - one-command ABBA driver for the decode A/B.
#
# WHY: chromium-video-ab.sh measures one condition and compares a pair, but the
# pre-registered A/B needs a config toggle and a FRESH browser between arms, in
# ABBA order, then the medians applied to the rule. Doing that by hand loses
# runs (a stale browser silently keeps the old switch). This driver runs the
# loop unattended and restores the config it found.
#
# RUN ON THE HOST as the desktop user (not root): it uses sudo for the one-line
# config toggle and launches its own browser with a throwaway profile, so the
# user's own browser is left running and untouched.
#
#   ./scripts/chromium-video-ab-run.sh --file ~/Videos/clip.mp4
#   ./scripts/chromium-video-ab-run.sh --file ~/Videos/clip.mp4 --apply
#   ./scripts/chromium-video-ab-run.sh --generate /tmp/video.mp4 --apply
#   ./scripts/chromium-video-ab-run.sh --self-test
#
# Default is dry-run: it prints the plan (and validates the file) but does not
# write the config, launch a browser, or measure. Add --apply to execute.
#
# Design (fixed before measurement; same rule as chromium-video-ab.sh):
#   A = GRAPHIC_DRIVER=default (switch absent), B = amd (switch present).
#   For N pairs, pair i odd -> A,B ; pair i even -> B,A  (ABBA drift control).
#   Each sample: set driver, launch a fresh browser (temp profile, own CDP
#   port), measure, SIGTERM it. measure discovers /proc by an --user-data-dir
#   marker (AB_MATCH) so a second browser cannot be mistaken for ours.
#   Verdict: median(A) vs median(B) through the pre-registered compare rule.
#   The GRAPHIC_DRIVER found at start is restored at exit.
#
# Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE, 3 usage/precondition.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf, no subprocess.run,
#   printf only, main() wrapper, graceful signals only (kill -TERM).
#
# Rule references: RULES #62 (CDP, never X11), #91 (print the basis),
#   #37 (SKIP/INCONCLUSIVE is not PASS), #92 (a signal must act).
#
set -uo pipefail

SELF=$(readlink -f "$0")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)
CONF="${AB_CONF:-/etc/chromium/chromium.conf}"
CHROME_BIN="${AB_CHROME:-}"
PORT="${AB_CDP_PORT:-9333}"
DURATION="${AB_DURATION:-20}"
PAIRS="${AB_PAIRS:-3}"
TAB="${AB_TAB:-video}"
FILE=""
URL=""
OUTDIR=""
GEN=""
APPLY=0
KEEP=0
LOCAL_SEAT=0
SOFTWARE_CONTROL=0
ACCEPT_LOAD=0
QUIET_PSI="${AB_QUIET_PSI:-20}"
QUIET_WAIT="${AB_QUIET_WAIT:-45}"
STUTTER_FLOOR="${AB_STUTTER_FLOOR:-0.005}"
ARM_FLAGS=()
PROFILE=""
WORK=""
LINK=""
ORIG_DRIVER=""

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }
say() { printf '%s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
need_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
is_root() { [ "$(id -u)" -eq 0 ]; }

get_driver() { awk -F= '/^GRAPHIC_DRIVER=/{print $2; exit}' "$CONF"; }

# ---- config toggle ---------------------------------------------------------

# Transform exactly one GRAPHIC_DRIVER line. Reads src as the user, writes dst.
transform_driver() {
    local src="$1" want="$2" dst="$3"
    python3 - "$src" "$want" "$dst" <<'PY'
import re, sys
src, want, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    text = fh.read()
new, n = re.subn(r"(?m)^GRAPHIC_DRIVER=.*$", "GRAPHIC_DRIVER=" + want, text)
if n != 1:
    sys.stderr.write("expected exactly one GRAPHIC_DRIVER line, found %d\n" % n)
    raise SystemExit(3)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(new)
PY
}

# Fallback when the audit's recorded backup cannot reach the target: a direct,
# backed-up, verified single-line edit. Never used unless the audit path fails.
set_driver_direct() {
    local desired="$1" cur
    cur=$(get_driver)
    [ "$cur" = "$desired" ] && return 0
    transform_driver "$CONF" "$desired" "$WORK/new.conf" || return 1
    sudo cp -a "$CONF" "$WORK/conf.$(stamp).bak" || return 1
    sudo cp "$WORK/new.conf" "$CONF" || return 1
    [ "$(get_driver)" = "$desired" ] || return 1
    return 0
}

# Preferred path: the audit script owns the backup/marker bookkeeping, so its
# --revert keeps working afterwards. Verify the resulting state either way.
set_driver() {
    local desired="$1" cur
    cur=$(get_driver)
    [ "$cur" = "$desired" ] && return 0
    case "$desired" in
        default) sudo "$REPO/scripts/chromium-video-audit.sh" --revert > "$WORK/audit.log" 2>&1 ;;
        amd)     sudo "$REPO/scripts/chromium-video-audit.sh" --apply > "$WORK/audit.log" 2>&1 ;;
        *) say "FAIL: unknown driver '$desired'"; return 3 ;;
    esac
    if [ "$(get_driver)" = "$desired" ]; then
        say "toggle: GRAPHIC_DRIVER=$cur -> $desired (audit)"
        return 0
    fi
    say "toggle: audit path did not reach $desired; using backed-up direct edit"
    set_driver_direct "$desired" || { say "FAIL: could not set GRAPHIC_DRIVER=$desired"; return 1; }
    say "toggle: GRAPHIC_DRIVER=$cur -> $desired (direct)"
    return 0
}

# ---- browser control -------------------------------------------------------

# SIGTERM only the browsers launched for this run, matched by our profile path.
kill_ours() {
    local d p cmd n=0
    [ -n "$PROFILE" ] || return 0
    for d in /proc/[0-9]*; do
        p=${d##*/}
        test -r "$d/cmdline" || continue
        cmd=$( { tr '\000' ' ' < "$d/cmdline"; } 2>&1) || continue
        case "$cmd" in
            *--user-data-dir="$PROFILE"*)
                kill -TERM "$p"
                n=$((n + 1))
                ;;
        esac
    done
    if [ "$n" -gt 0 ]; then
        sleep 1
        say "browser: sent SIGTERM to $n process(es) on $PROFILE"
    fi
    return 0
}

prime_video() {
    local js out ct0 ct1 i=0
    js='(function(){var v=document.querySelector("video");if(!v)return {ok:false,why:"no video element"};v.muted=true;v.loop=true;try{v.play();}catch(e){}return {ok:true,paused:v.paused,ct:v.currentTime,dur:v.duration,vw:v.videoWidth,vh:v.videoHeight,rs:v.readyState,err:(v.error&&v.error.code)||0};})()'
    out=$(CDP_PORT="$PORT" node "$REPO/scripts/cdp-tab.mjs" eval "$TAB" "$js" 2>&1) || out="probe failed"
    say "video:    $out"
    case "$out" in
        *'"ok":true'*) ;;
        *)
            say "FAIL: no <video> in tab '$TAB' (check --tab; URL is $URL)"
            return 1
            ;;
    esac
    ct0=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ct",0))' 2>&1) || ct0=0
    # A stalled decode (unsupported codec, no data) must not be measured.
    while [ "$i" -lt 10 ]; do
        sleep 1
        ct1=$(CDP_PORT="$PORT" node "$REPO/scripts/cdp-tab.mjs" eval "$TAB" 'document.querySelector("video")?document.querySelector("video").currentTime:-1' 2>&1) || ct1="-1"
        if awk -v a="$ct0" -v b="$ct1" 'BEGIN{exit !((b - a) >= 0.2)}'; then
            return 0
        fi
        i=$((i + 1))
    done
    say "FAIL: playback is not advancing (currentTime stayed at $ct1); the clip is"
    say "      unsupported by this Chromium or has no decodable video track."
    say "      codec/dims: see 'video:' above and the ffprobe line. Try H.264/VP9."
    return 1
}

probe_clip() {
    [ -n "$FILE" ] && [ -r "$FILE" ] || return 0
    if command -v ffprobe > /dev/null 2>&1; then
        local info codec
        info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate -show_entries format=duration -of default=nw=1 "$FILE" 2>&1 | tr '\n' ' ')
        say "probe:    $info"
        codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$FILE" 2>&1)
        case "$codec" in
            av1|hevc|h265) say "WARN: codec $codec has no AMD hardware decoder on Renoir; hardware decode cannot engage." ;;
        esac
    else
        say "probe:    ffprobe not found (cannot report codec)"
    fi
    return 0
}

# Hardware decode needs an active graphical seat: logind grants the render node
# to the seat's user. A plain SSH shell often has no ACL on /dev/dri/renderD*,
# and Chromium silently falls back to software (no dec fd) — which would turn a
# measurement problem into a false REFUTED. Fail closed instead.
graphics_preflight() {
    local r ok=0 vout eps init
    for r in /dev/dri/renderD*; do
        [ -e "$r" ] || continue
        if [ -r "$r" ] && [ -w "$r" ]; then say "gpu:       $r accessible"; ok=1; break; fi
    done
    if command -v vainfo > /dev/null 2>&1; then
        vout=$(vainfo 2>&1)
        say "gpu:       $(printf '%s\n' "$vout" | grep -i 'Driver version' | head -n 1)"
        eps=$(printf '%s\n' "$vout" | grep -ioE 'VAProfile(H264|VP9|AV1|HEVC)[A-Za-z]*' | sort -u | tr '\n' ' ')
        init=$(printf '%s\n' "$vout" | grep -iE 'error|fail|cannot|no display' | head -n 1)
        say "gpu:       profiles: ${eps:-none}${init:+  (init: $init)}"
    fi
    if [ "$ok" -ne 1 ]; then
        say "WARN: no writable /dev/dri/renderD*; hardware decode needs an active"
        say "      graphical seat (logind device ACL). A plain SSH shell usually"
        say "      lacks it and Chromium silently uses software decode."
        return 1
    fi
    return 0
}

is_x11_forward() {
    case "${DISPLAY:-}" in
        localhost:*|127.0.0.1:*) return 0 ;;
    esac
    return 1
}

# An ssh -Y shell forwards X to the client; Chromium opens a window there but
# its GPU process cannot convert video frames over the remote GL context and
# crash-loops (exit_code=8704, MailboxVideoFrameConverter), so decode never
# starts. Switch to the host's LOCAL seat (Wayland socket, else X :0).
use_local_seat() {
    local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" s wl=""
    if [ -d "$rt" ]; then
        for s in "$rt"/wayland-*; do
            [ -S "$s" ] || continue
            wl=$(basename "$s")
            break
        done
    fi
    if [ -n "$wl" ]; then
        export XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$wl"
        unset DISPLAY
        say "seat:     using local Wayland $wl ($rt)"
        return 0
    fi
    if [ -S /tmp/.X11-unix/X0 ]; then
        export DISPLAY=:0
        export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
        unset WAYLAND_DISPLAY
        say "seat:     using local X display :0"
        return 0
    fi
    say "seat:     no local Wayland socket under $rt and no X :0"
    return 1
}

seat_guard() {
    if [ "$LOCAL_SEAT" -eq 1 ]; then
        use_local_seat || return 1
        return 0
    fi
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        say "FAIL: no DISPLAY or WAYLAND_DISPLAY; this needs a graphical session."
        say "      Run from the .24 desktop, or pass --local-seat to use its seat."
        return 1
    fi
    if is_x11_forward; then
        say "FAIL: DISPLAY=$DISPLAY is an SSH X11 forward (ssh -Y)."
        say "      Chromium opens the window on the client, but its GPU process cannot"
        say "      convert video frames over the remote context (exit_code=8704), so"
        say "      decode never starts and the A/B is void."
        say "      Re-run with --local-seat to render on .24's own seat, or run this"
        say "      from a terminal on the .24 desktop."
        return 1
    fi
    return 0
}

psi_cpu() {
    awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/cpu
}

load1() { awk '{print $1}' /proc/loadavg; }

# Frame drops on this host track system load, not the driver. Refuse to sample
# under contention: wait for psi_cpu_avg10 <= QUIET_PSI, else abort the run.
quiet_gate() {
    local i=0 psi load
    while [ "$i" -lt "$QUIET_WAIT" ]; do
        psi=$(psi_cpu); load=$(load1)
        [ -n "$psi" ] || psi=0
        if awk -v p="$psi" -v m="$QUIET_PSI" 'BEGIN{exit !(p<=m)}'; then
            say "quiet:    psi_cpu_avg10=${psi}% load1=${load} (<= ${QUIET_PSI}%)"
            return 0
        fi
        say "quiet:    psi_cpu_avg10=${psi}% > ${QUIET_PSI}%; waiting for an idle host..."
        sleep 5
        i=$((i + 5))
    done
    say "FAIL: host stayed busy (psi_cpu_avg10=${psi}% > ${QUIET_PSI}% for ${QUIET_WAIT}s)."
    say "      Frame drops track load, not the driver setting; a run now is noise."
    say "      Wait for an idle host, or pass --accept-load (AB_QUIET_PSI=100) to run anyway."
    return 1
}

launch() {
    local i=0 v
    kill_ours
    sleep 1
    say "launch: $CHROME_BIN (profile $PROFILE, cdp :$PORT)"
    setsid "$CHROME_BIN" \
        --remote-debugging-port="$PORT" \
        --remote-allow-origins='*' \
        --user-data-dir="$PROFILE" \
        --no-first-run --no-default-browser-check \
        --autoplay-policy=no-user-gesture-required \
        --disable-backgrounding-occluded-windows \
        --disable-renderer-backgrounding \
        --disable-background-timer-throttling \
        --mute-audio "${ARM_FLAGS[@]}" "$URL" \
        > "$WORK/chromium.log" 2>&1 < /dev/null &
    while [ "$i" -lt 40 ]; do
        v=$(curl -s -m 2 "http://127.0.0.1:$PORT/json/version") || v=""
        case "$v" in
            *Browser*)
                say "cdp: listening on :$PORT after ${i}s"
                sleep 2
                prime_video || return 4
                return 0
                ;;
        esac
        sleep 1
        i=$((i + 1))
    done
    say "FAIL: CDP not reachable on :$PORT; log tail:"
    tail -n 15 "$WORK/chromium.log" 2>&1 || true
    return 1
}

# ---- one sample ------------------------------------------------------------

measure_one() {
    local label="$1" out="$2" want rc lrc
    case "$label" in
        A) want=default ;;
        B) want=amd ;;
        *) say "FAIL: bad label $label"; return 3 ;;
    esac
    say ""
    say "=== sample $label (GRAPHIC_DRIVER=$want) -> $(basename "$out") ==="
    if [ "$ACCEPT_LOAD" -eq 1 ]; then
        say "quiet:    skipped (--accept-load): results may be noisy"
    else
        quiet_gate || return 5
    fi
    # Default mode compares default (hardware decode, as shipped) with amd
    # (hardware decode + the wrapper's extra flags) on frame pacing. With
    # --software-control, A also forces software decode to test the older
    # "does hardware decode reduce stutter" question.
    ARM_FLAGS=()
    if [ "$SOFTWARE_CONTROL" -eq 1 ] && [ "$want" = default ]; then
        ARM_FLAGS=(--disable-accelerated-video-decode --disable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL)
        say "control:  software-forced (--disable-accelerated-video-decode)"
    fi
    set_driver "$want" || return 1
    launch
    lrc=$?
    if [ "$lrc" -ne 0 ]; then
        if [ -f "$WORK/chromium.log" ]; then cp "$WORK/chromium.log" "${out%.json}.chromium.log" || true; fi
        kill_ours
        return "$lrc"
    fi
    AB_MATCH="--user-data-dir=$PROFILE" CDP_PORT="$PORT" AB_TAB="$TAB" \
        "$REPO/scripts/chromium-video-ab.sh" measure \
        --label "$label" --url "$URL" --duration "$DURATION" --out "$out"
    rc=$?
    kill_ours
    if [ -f "$WORK/chromium.log" ]; then cp "$WORK/chromium.log" "${out%.json}.chromium.log" || true; fi
    return "$rc"
}

# ---- aggregate + verdict ---------------------------------------------------

# Group the sample JSONs by label, take medians, write median-A/B, and print a
# per-arm summary. Frames must be present on every sample of an arm to yield a
# numeric median; otherwise the frame field is null and compare says INCONCLUSIVE.
aggregate() {
    local dir="$1" ma="$2" mb="$3"
    python3 - "$dir" "$ma" "$mb" <<'PY'
import glob, json, os, statistics, sys
d, ma, mb = sys.argv[1], sys.argv[2], sys.argv[3]
rows = {"A": [], "B": []}
for p in sorted(glob.glob(os.path.join(d, "*.json"))):
    try:
        x = json.load(open(p))
    except Exception as e:
        print("skip unreadable %s: %s" % (p, e))
        continue
    if x.get("schema") != "ab/v1" or x.get("label") not in rows:
        continue
    rows[x["label"]].append(x)
def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    return statistics.median(vals) if vals else None
def summarize(L, rl):
    n = len(rl)
    drops = [((r.get("frames") or {}).get("drop_ratio")) for r in rl]
    decs = [r.get("dec_rate_ns_s") for r in rl]
    have_frames = n > 0 and all(isinstance(x, (int, float)) for x in drops)
    drop_med = med(drops) if have_frames else None
    dec_med = med(decs)
    sw_vals = [bool(r.get("switch_present")) for r in rl]
    fd_vals = [bool(r.get("dec_fd")) for r in rl]
    sw = (any(sw_vals) if L == "A" else (n > 0 and all(sw_vals)))
    fd = (any(fd_vals) if L == "A" else (n > 0 and all(fd_vals)))
    out = {
        "schema": "ab/v1", "label": L,
        "switch_present": bool(sw), "dec_fd": bool(fd),
        "dec_rate_ns_s": (dec_med if dec_med is not None else 0),
        "frames": ({"total": 0, "dropped": 0, "drop_ratio": drop_med}
                   if drop_med is not None else None),
    }
    print("%s: n=%d switch=%s dec_fd=%s median_drop=%s median_dec=%s frames=%s" % (
        L, n, sw, fd, drop_med, dec_med, "yes" if have_frames else "no"))
    return out
a = summarize("A", rows["A"])
b = summarize("B", rows["B"])
open(ma, "w").write(json.dumps(a, indent=2) + "\n")
open(mb, "w").write(json.dumps(b, indent=2) + "\n")
sys.exit(0 if (rows["A"] and rows["B"]) else 1)
PY
}

# ---- cleanup ---------------------------------------------------------------

cleanup() {
    kill_ours
    if [ -n "$WORK" ] && [ -f "$WORK/original.conf" ] && [ -f "$CONF" ]; then
        if ! cmp -s "$WORK/original.conf" "$CONF"; then
            say "restore: GRAPHIC_DRIVER=$(get_driver) -> as-found ($ORIG_DRIVER)"
            if sudo -n cp "$WORK/original.conf" "$CONF"; then
                say "restore: now GRAPHIC_DRIVER=$(get_driver)"
            else
                say "WARN: could not restore without a password."
                say "      run: sudo cp $WORK/original.conf $CONF"
            fi
        fi
    fi
}

# ---- self-test (no browser, no sudo, no /etc) ------------------------------

do_selftest() {
    local tmp fails=0 got
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ab-run.XXXXXX" 2>&1) || { say 'FAIL mktemp'; return 3; }
    mkfake() {
        printf '{"schema":"ab/v1","label":"%s","switch_present":%s,"dec_fd":%s,"dec_rate_ns_s":%s,"frames":{"total":1000,"dropped":%s,"drop_ratio":%s}}\n' \
            "$1" "$2" "$3" "$4" "$5" "$6" > "$7"
    }
    ord() {
        local n="$1" i=1 out=""
        while [ "$i" -le "$n" ]; do
            if [ $((i % 2)) -eq 1 ]; then out="$out A B"; else out="$out B A"; fi
            i=$((i + 1))
        done
        printf '%s' "$out"
    }
    check() {
        local name="$1" want="$2" got="$3"
        if [ "$got" = "$want" ]; then
            printf '  PASS %s\n' "$name"
        else
            printf '  FAIL %s (got=%s want=%s)\n' "$name" "$got" "$want"
            fails=$((fails + 1))
        fi
    }
    check "order 1 pair = A B" " A B" "$(ord 1)"
    check "order 2 pairs = A B B A" " A B B A" "$(ord 2)"
    check "order 3 pairs = A B B A A B" " A B B A A B" "$(ord 3)"
    if ( DISPLAY=localhost:10.0; is_x11_forward ); then
        printf '  PASS ssh -Y X11 forward detected\n'
    else
        printf '  FAIL ssh -Y X11 forward not detected\n'; fails=$((fails + 1))
    fi
    if ( DISPLAY=:0; is_x11_forward ); then
        printf '  FAIL local :0 wrongly flagged as forward\n'; fails=$((fails + 1))
    else
        printf '  PASS local :0 not flagged\n'
    fi

    printf '# keep\nGRAPHIC_DRIVER=default\n# tail\n' > "$tmp/conf"
    transform_driver "$tmp/conf" amd "$tmp/new" 2>&1
    check "transform default->amd" "amd" "$(awk -F= '/^GRAPHIC_DRIVER=/{print $2}' "$tmp/new")"

    mkdir -p "$tmp/pass"
    mkfake A false false 0 50 0.05 "$tmp/pass/1-A.json"
    mkfake B true  true  900 2 0.002 "$tmp/pass/2-B.json"
    mkfake A false false 0 48 0.05 "$tmp/pass/3-A.json"
    mkfake B true  true  880 3 0.002 "$tmp/pass/4-B.json"
    aggregate "$tmp/pass" "$tmp/pass/mA.json" "$tmp/pass/mB.json" > "$tmp/pass/agg.txt" 2>&1
    got=$("$REPO/scripts/chromium-video-ab.sh" compare "$tmp/pass/mA.json" "$tmp/pass/mB.json" 2>&1 | awk -F= '/^status=/{print $2; exit}')
    check "median pair PASS" "PASS" "$got"

    mkdir -p "$tmp/fail"
    mkfake A false false 0 50 0.05 "$tmp/fail/1-A.json"
    mkfake B true  true  900 60 0.06 "$tmp/fail/2-B.json"
    aggregate "$tmp/fail" "$tmp/fail/mA.json" "$tmp/fail/mB.json" > "$tmp/fail/agg.txt" 2>&1
    got=$("$REPO/scripts/chromium-video-ab.sh" compare "$tmp/fail/mA.json" "$tmp/fail/mB.json" 2>&1 | awk -F= '/^status=/{print $2; exit}')
    check "median pair FAIL" "FAIL" "$got"

    mkdir -p "$tmp/confound"
    mkfake A true  true  500 50 0.05 "$tmp/confound/1-A.json"
    mkfake B true  true  900 2 0.002 "$tmp/confound/2-B.json"
    aggregate "$tmp/confound" "$tmp/confound/mA.json" "$tmp/confound/mB.json" > "$tmp/confound/agg.txt" 2>&1
    got=$("$REPO/scripts/chromium-video-ab.sh" compare "$tmp/confound/mA.json" "$tmp/confound/mB.json" 2>&1 | awk -F= '/^status=/{print $2; exit}')
    check "confounded control INCONCLUSIVE" "INCONCLUSIVE" "$got"

    if bash -n "$SELF"; then printf '  PASS bash -n\n'; else fails=$((fails + 1)); printf '  FAIL bash -n\n'; fi
    find "$tmp" -depth -delete 2>&1
    say "result: $([ "$fails" -eq 0 ] && printf PASS || printf 'FAIL (%s)' "$fails")"
    [ "$fails" -eq 0 ] && return 0 || return 1
}

# ---- plan / usage ----------------------------------------------------------

usage() {
    printf 'usage: %s [--file PATH | --url URL | --generate PATH] [--duration N] [--pairs N]\n' "$0"
    printf '          [--outdir DIR] [--cdp-port N] [--tab SEL] [--chrome PATH]\n'
    printf '          [--local-seat] [--software-control] [--accept-load] [--apply] [--keep] [--self-test]\n'
}

do_plan() {
    say "=== chromium-video-ab-run (dry-run; add --apply to execute) ==="
    say "host:     $(hostname)"
    say "user:     $(id -un)"
    say "repo:     $REPO"
    say "config:   $CONF (GRAPHIC_DRIVER=$ORIG_DRIVER)"
    say "chrome:   ${CHROME_BIN:-(not found: chromium, chromium-browser)}"
    say "session:  DISPLAY=${DISPLAY:-none} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-none} type=${XDG_SESSION_TYPE:-none}"
    graphics_preflight
    say "file:     $FILE"
    say "url:      $URL"
    say "tab:      $TAB"
    say "duration: ${DURATION}s per sample, ${PAIRS} pair(s), cdp :$PORT"
    say "outdir:   $OUTDIR"
    local i=1
    while [ "$i" -le "$PAIRS" ]; do
        if [ $((i % 2)) -eq 1 ]; then
            say "  pair $i: A ($( [ "$SOFTWARE_CONTROL" -eq 1 ] && printf 'default+software' || printf 'default' )) then B (amd)"
        else
            say "  pair $i: B (amd) then A ($( [ "$SOFTWARE_CONTROL" -eq 1 ] && printf 'default+software' || printf 'default' ))"
        fi
        i=$((i + 1))
    done
    if [ "$SOFTWARE_CONTROL" -eq 1 ]; then
        say "mode:     software control — A forces --disable-accelerated-video-decode"
        say "verdict:  compare (A must not decode; hardware must reduce drops)"
    else
        say "mode:     both-hardware — default already decodes H.264 here, so the"
        say "          switch's marginal effect is frame pacing, not decode."
        say "verdict:  compare-pace (A may decode; B's pacing must beat A by the margin)"
    fi
    say "each sample: set driver -> launch fresh browser -> measure -> SIGTERM"
    say "on exit:     restore GRAPHIC_DRIVER=$ORIG_DRIVER"
}

# ---- main ------------------------------------------------------------------

main() {
    local rc i label out n=0 labels b_frames b_dec last_log
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) shift; FILE="${1:-}" ;;
            --url) shift; URL="${1:-}" ;;
            --duration) shift; DURATION="${1:-}" ;;
            --pairs) shift; PAIRS="${1:-}" ;;
            --outdir) shift; OUTDIR="${1:-}" ;;
            --cdp-port) shift; PORT="${1:-}" ;;
            --tab) shift; TAB="${1:-}" ;;
            --chrome) shift; CHROME_BIN="${1:-}" ;;
            --generate) shift; GEN="${1:-}" ;;
            --local-seat) LOCAL_SEAT=1 ;;
            --software-control) SOFTWARE_CONTROL=1 ;;
            --accept-load) ACCEPT_LOAD=1 ;;
            --apply) APPLY=1 ;;
            --keep) KEEP=1 ;;
            --self-test) do_selftest; return $? ;;
            -h|--help) usage; return 0 ;;
            *) say "unknown option: $1"; usage; return 3 ;;
        esac
        shift
    done

    need_num "$DURATION" && [ "$DURATION" -ge 5 ] || { say 'FAIL: --duration must be an integer >= 5'; return 3; }
    need_num "$PAIRS" && [ "$PAIRS" -ge 1 ] || { say 'FAIL: --pairs must be an integer >= 1'; return 3; }
    need_num "$PORT" || { say 'FAIL: --cdp-port must be numeric'; return 3; }

    if [ -n "$GEN" ]; then FILE="$GEN"; fi
    if [ -z "$FILE" ] && [ -z "$URL" ]; then
        say 'FAIL: one of --file PATH, --url URL, or --generate PATH is required'
        usage
        return 3
    fi

    if [ -n "$CHROME_BIN" ]; then
        if ! command -v "$CHROME_BIN" > /dev/null 2>&1 && ! test -x "$CHROME_BIN"; then
            say "FAIL: browser not executable: $CHROME_BIN (from --chrome/AB_CHROME)"
            return 3
        fi
    else
        local c
        for c in chromium chromium-browser; do
            if command -v "$c" > /dev/null 2>&1; then CHROME_BIN="$c"; break; fi
        done
    fi

    # Fail fast on the environment before spending time encoding a sample.
    if [ "$APPLY" -eq 1 ]; then
        is_root && { say 'FAIL: run as the desktop user, not root (sudo is used only for the toggle)'; return 3; }
        [ -n "$CHROME_BIN" ] || { say 'FAIL: no Chromium on PATH (tried chromium, chromium-browser); install it or pass --chrome PATH'; return 3; }
        have curl || { say 'FAIL: curl not found'; return 3; }
        have node || { say 'FAIL: node not found'; return 3; }
        have sudo || { say 'FAIL: sudo not found'; return 3; }
        say 'sudo: refreshing credentials for the config toggle...'
        sudo -v || { say 'FAIL: sudo authentication failed'; return 3; }
        seat_guard || { say 'FAIL: no usable local graphical seat for hardware decode.'; return 3; }
        graphics_preflight || { say 'FAIL: cannot test hardware decode without DRM access; run this from the desktop session (local terminal), not a plain SSH shell.'; return 3; }
    fi

    if [ -n "$FILE" ] && ! test -r "$FILE"; then
        if [ -n "$GEN" ] && [ "$APPLY" -eq 1 ]; then
            have ffmpeg || { say 'FAIL: --generate needs ffmpeg on PATH'; return 3; }
            say "generate: $FILE (1080p30 H.264 testsrc; plumbing smoke test only)"
            say "          1080p30, 10s, libx264 veryfast; about 5-15s (progress below)"
            timeout 120 ffmpeg -hide_banner -nostdin -loglevel warning -stats -y -f lavfi \
                -i testsrc2=size=1920x1080:rate=30 -t 10 \
                -c:v libx264 -preset veryfast -pix_fmt yuv420p -movflags +faststart "$FILE" \
                || { say 'FAIL: ffmpeg could not write the sample (see message above)'; return 3; }
        elif [ -z "$GEN" ]; then
            say "FAIL: file not readable: $FILE"
            return 3
        fi
    fi

    probe_clip

    if test -f "$CONF"; then
        ORIG_DRIVER=$(get_driver)
    else
        ORIG_DRIVER=""
    fi
    if [ -z "$ORIG_DRIVER" ]; then
        if [ "$APPLY" -eq 1 ]; then
            say "FAIL: missing or unreadable $CONF (no GRAPHIC_DRIVER line)"
            return 3
        fi
        ORIG_DRIVER="(missing: $CONF)"
    fi

    WORK=$(mktemp -d "${TMPDIR:-/tmp}/ab-run.XXXXXX" 2>&1) || { say 'FAIL: mktemp'; return 3; }
    PROFILE="$WORK/profile"
    mkdir -p "$PROFILE" || { say 'FAIL: mkdir profile'; return 3; }
    trap 'cleanup' EXIT
    trap 'cleanup; exit 130' INT TERM

    if [ -n "$FILE" ]; then
        local base ext
        base=$(basename "$FILE")
        ext="${base##*.}"
        if [ "$ext" = "$base" ] || [ -z "$ext" ]; then ext=mp4; fi
        LINK="$WORK/video-$(stamp).$ext"
        ln -s "$(readlink -f "$FILE")" "$LINK" || { say 'FAIL: could not link the sample'; return 3; }
        URL=$(python3 -c 'import pathlib,os,sys; print(pathlib.Path(os.path.abspath(sys.argv[1])).as_uri())' "$LINK")
    fi
    [ -n "$OUTDIR" ] || OUTDIR="$REPO/logs/ab-run-$(stamp)"

    if [ "$APPLY" -eq 1 ]; then
        sudo cat "$CONF" > "$WORK/original.conf" || { say 'FAIL: could not read original config'; return 3; }
        mkdir -p "$OUTDIR" || { say "FAIL: mkdir $OUTDIR"; return 3; }
        say "=== chromium-video-ab-run $(now_utc) ==="
        say "as-found: GRAPHIC_DRIVER=$ORIG_DRIVER  file=$FILE  pairs=$PAIRS  duration=${DURATION}s"
        say "outdir:   $OUTDIR"
        i=1
        while [ "$i" -le "$PAIRS" ]; do
            if [ $((i % 2)) -eq 1 ]; then labels="A B"; else labels="B A"; fi
            for label in $labels; do
                n=$((n + 1))
                out="$OUTDIR/$(printf '%02d' "$n")-$label.json"
                measure_one "$label" "$out"
                rc=$?
                if [ "$rc" -eq 5 ]; then
                    say ""
                    say "status=INCONCLUSIVE"
                    say "mechanism=PASS stutter_claim=UNPROVEN"
                    say "reason=host under load (psi_cpu_avg10 > ${QUIET_PSI}%); drops track load, not the switch. Re-run on an idle host."
                    say ""
                    say "samples: $OUTDIR"
                    cleanup
                    say "kept:    $WORK"
                    return 2
                fi
                if [ "$rc" -eq 4 ]; then
                    say ""
                    say "status=INCONCLUSIVE"
                    say "mechanism=UNPROVEN stutter_claim=UNPROVEN"
                    say "reason=clip did not decode/advance; A/B not conducted (see *.chromium.log in $OUTDIR)"
                    say ""
                    say "samples: $OUTDIR"
                    cleanup
                    say "kept:    $WORK"
                    return 2
                fi
                if [ "$rc" -ne 0 ]; then
                    cleanup
                    say "kept:    $WORK"
                    return "$rc"
                fi
            done
            i=$((i + 1))
        done

        say ""
        say "=== aggregate (median per arm) ==="
        if ! aggregate "$OUTDIR" "$OUTDIR/median-A.json" "$OUTDIR/median-B.json"; then
            say "FAIL: no samples for both arms in $OUTDIR"
            return 3
        fi
        say ""
        say "=== verdict ==="
        b_frames=$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])).get("frames") else "no")' "$OUTDIR/median-B.json")
        b_dec=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dec_rate_ns_s",0))' "$OUTDIR/median-B.json")
        a_dec=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dec_rate_ns_s",0))' "$OUTDIR/median-A.json")
        da=$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])).get("frames") or {}; print(f.get("drop_ratio"))' "$OUTDIR/median-A.json")
        db=$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])).get("frames") or {}; print(f.get("drop_ratio"))' "$OUTDIR/median-B.json")
        if [ "$b_frames" = "no" ] && awk -v x="$b_dec" -v y="$a_dec" 'BEGIN{exit !(x<=0 && y<=0)}'; then
            say "status=INCONCLUSIVE"
            say "mechanism=UNPROVEN stutter_claim=UNPROVEN"
            say "reason=treatment produced no frame counters and no decode; the clip gave no decodable video track. Not evidence against the switch."
            rc=2
        elif [ "$da" != "None" ] && [ "$db" != "None" ] && awk -v x="$da" -v y="$db" -v f="$STUTTER_FLOOR" 'BEGIN{exit !(x<f && y<f)}'; then
            say "status=INCONCLUSIVE"
            say "mechanism=PASS stutter_claim=UNPROVEN"
            say "reason=no usable stutter in either arm (drop_A=$da drop_B=$db < $STUTTER_FLOOR); this clip does not reproduce the problem."
            rc=2
        else
            if [ "$SOFTWARE_CONTROL" -eq 1 ]; then
                "$REPO/scripts/chromium-video-ab.sh" compare "$OUTDIR/median-A.json" "$OUTDIR/median-B.json"
            else
                "$REPO/scripts/chromium-video-ab.sh" compare-pace "$OUTDIR/median-A.json" "$OUTDIR/median-B.json"
            fi
            rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            last_log=$(ls "$OUTDIR"/*.chromium.log 2>&1 | tail -n 1)
            if [ -n "$last_log" ] && [ -f "$last_log" ]; then
                say ""
                say "--- chromium log signals ($(basename "$last_log")) ---"
                grep -iE 'vaapi|va-api|vulkan|egl|gpu.*(error|fail|disabled)|software|mediagpu' "$last_log" | tail -n 12
            fi
        fi
        say ""
        say "samples: $OUTDIR"
        cleanup
        if [ "$rc" -eq 0 ] && [ "$KEEP" -eq 0 ]; then
            find "$WORK" -depth -delete 2>&1
        else
            say "kept:    $WORK"
        fi
        return "$rc"
    fi

    do_plan
    cleanup
    find "$WORK" -depth -delete 2>&1
    return 0
}

main "$@"
