#!/usr/bin/env bash
#
# diag-harness-stall.sh — "wait, slow, or wedged?" for a live gate run.
#
# Why: harness.sh prints a gate's result only after the gate returns. A slow
# self-test is therefore indistinguishable from a hang. This reads the live
# run's own log (via /proc/<pid>/fd, not "newest /tmp file"), samples growth,
# and attributes the block: host I/O (D state + pressure), a lock (futex),
# compute (R + CPU), or genuine wedging.
#
#   ./scripts/diag-harness-stall.sh                 # 10s sample
#   ./scripts/diag-harness-stall.sh --sample 30
#   ./scripts/diag-harness-stall.sh --json
#   ./scripts/diag-harness-stall.sh --tmp DIR       # scan DIR instead of /tmp
#   ./scripts/diag-harness-stall.sh --self-test
#
# Exit: 0 progressing/busy · 2 no log/bad args · 3 blocked (slow) ·
#       4 stalled · 5 stale log from a finished run.
#
# Verdicts: PROGRESSING · BUSY · BLOCKED_IO · BLOCKED_LOCK · STALLED · STALE.
# STALLED writes one ADVISORY ledger row per incident (stable key) unless
# --no-ledger. The process tree comes from /proc (no ps/pgrep: absent in the
# container, and feeding "command not found" into a pid walk recursed forever).
#
# Constraints: no stream editor, no stderr-to-null, no set -e, no top-level
#   exit, no recursive delete, no subprocess.run, no bare kill, printf only,
#   main() wrapper.

set -o pipefail

SAMPLE=10
TMPROOT=/tmp
JSON=0
LEDGER=1
PROC="${DIAG_PROC_ROOT:-/proc}"
SCRIPT="${BASH_SOURCE[0]}"
REPO=""

usage() {
    printf 'usage: %s [--sample SECONDS] [--tmp DIR] [--json] [--no-ledger] [--self-test]\n' "$0"
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

have() { command -v "$1" > /dev/null 2>&1; }

# --- /proc primitives (fields after the comm field) ----------------------
proc_state() { awk '{ sub(/^[^)]*\) /, ""); printf "%s", $1 }' "$PROC/$1/stat"; }
proc_ppid()  { awk '{ sub(/^[^)]*\) /, ""); printf "%s", $2 }' "$PROC/$1/stat"; }
proc_ticks() { awk '{ sub(/^[^)]*\) /, ""); printf "%d", $12 + $13 }' "$PROC/$1/stat"; }
proc_wchan() {
    [ -r "$PROC/$1/wchan" ] || { printf '%s' '-'; return; }
    awk 'NR == 1 { printf "%s", $0 }' "$PROC/$1/wchan"
}
proc_io() {
    [ -r "$PROC/$1/io" ] || { printf '%s' '-/-'; return; }
    awk '/^rchar:/ { r = $2 } /^wchar:/ { w = $2 } END { printf "%s/%s", r, w }' "$PROC/$1/io"
}
proc_cmd() { tr '\0' ' ' < "$PROC/$1/cmdline"; }

# Match the script path as its own argv token, not a substring of some
# unrelated shell's "-c" text (that produced ancestor noise).
hosts_harness() {
    local pid="$1" arg
    [ -r "$PROC/$pid/cmdline" ] || return 1
    while IFS= read -r -d '' arg; do
        case "$arg" in
            scripts/harness.sh|./scripts/harness.sh|*/scripts/harness.sh) return 0 ;;
        esac
    done < "$PROC/$pid/cmdline"
    return 1
}

harness_roots() {
    local d p
    for d in "$PROC"/[0-9]*; do
        [ -d "$d" ] || continue
        p=${d##*/}
        hosts_harness "$p" && printf '%s\n' "$p"
    done
}

log_name_ok() {
    case "${1##*/}" in
        lint.log|test-hygiene.log|test-patterns.log|test-dashboard.log) return 0 ;;
    esac
    return 1
}

# Exact log the live harness holds open — no cross-run ambiguity.
live_log() {
    local pid="$1" f target best="" best_m=0 m
    for f in "$PROC/$pid/fd"/*; do
        [ -e "$f" ] || continue
        target=$(readlink "$f" 2>&1)
        case "$target" in *" (deleted)") continue ;; esac
        [ -f "$target" ] || continue
        log_name_ok "$target" || continue
        m=$(stat -c %Y "$target" 2>&1)
        case "$m" in ''|*[!0-9]*) m=0 ;; esac
        if [ -z "$best" ] || [ "$m" -ge "$best_m" ]; then best="$target"; best_m=$m; fi
    done
    printf '%s' "$best"
}

latest_log() {
    local root="$1"
    [ -d "$root" ] || { printf ''; return; }
    find "$root" -maxdepth 2 -type f \
        \( -name 'lint.log' -o -name 'test-hygiene.log' \
        -o -name 'test-patterns.log' -o -name 'test-dashboard.log' \) \
        -printf '%T@ %p\n' 2>&1 \
        | sort -nr | head -n 1 \
        | awk '{ $1 = ""; sub(/^ /, ""); print }'
}

# BFS over a ppid map; the seen set makes cycles impossible.
tree_from() {
    local roots="$1" d p pp c r i
    local -A child_of=()
    local -A seen=()
    local -a queue=() order=()
    for d in "$PROC"/[0-9]*; do
        [ -d "$d" ] || continue
        p=${d##*/}
        pp=$(proc_ppid "$p")
        case "$pp" in ''|*[!0-9]*) continue ;; esac
        child_of["$pp"]="${child_of[$pp]:-} $p"
    done
    for r in $roots; do
        case "$r" in ''|*[!0-9]*) continue ;; esac
        [ -z "${seen[$r]:-}" ] || continue
        seen[$r]=1; queue+=("$r")
    done
    i=0
    while [ "$i" -lt "${#queue[@]}" ]; do
        p="${queue[$i]}"; i=$((i + 1)); order+=("$p")
        for c in ${child_of[$p]:-}; do
            [ -z "${seen[$c]:-}" ] || continue
            seen[$c]=1; queue+=("$c")
        done
    done
    [ "${#order[@]}" -gt 0 ] && printf '%s\n' "${order[@]}"
}

# Event-driven when the kernel API is reachable, else a plain poll.
# Prints: delta=<bytes> last_age=<sec> method=<inotify|poll>
growth_sample() {
    local log="$1" secs="$2"
    if have python3; then
        python3 - "$log" "$secs" <<'PY'
import ctypes, ctypes.util, os, select, sys, time
log, secs = sys.argv[1], float(sys.argv[2])
try:
    libc = ctypes.CDLL(ctypes.util.find_library("c") or None, use_errno=True)
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    fd = libc.inotify_init1(os.O_NONBLOCK)
    if fd < 0:
        raise OSError("inotify_init1")
    if libc.inotify_add_watch(fd, log.encode(), 0x2 | 0x4) < 0:  # MODIFY|ATTRIB
        raise OSError("inotify_add_watch")
    s1 = os.stat(log).st_size
    start = last = time.monotonic()
    end = start + secs
    while True:
        rem = end - time.monotonic()
        if rem <= 0:
            break
        r, _, _ = select.select([fd], [], [], min(rem, 0.25))
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if data:
                last = time.monotonic()
    s2 = os.stat(log).st_size
    print(f"delta={s2 - s1} last_age={time.monotonic() - last:.2f} method=inotify")
except Exception:
    s1 = os.stat(log).st_size
    time.sleep(secs)
    s2 = os.stat(log).st_size
    print(f"delta={s2 - s1} last_age={secs:.2f} method=poll")
PY
        return
    fi
    local s1 s2
    s1=$(stat -c %s "$log" 2>&1)
    sleep "$secs"
    s2=$(stat -c %s "$log" 2>&1)
    printf 'delta=%d last_age=%s method=poll' "$((s2 - s1))" "$secs"
}

field() { printf '%s' "$1" | awk -v k="$2=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { sub(k, "", $i); printf "%s", $i } }'; }

json_safe() { awk '{ gsub(/[\\"]/, " "); printf "%s", $0 }'; }

ledger_advisory() {
    local pid="$1" gate="$2" detail="$3" ino
    [ "$LEDGER" -eq 1 ] || return 0
    [ -n "$REPO" ] && [ -f "$REPO/scripts/ledger.py" ] || return 0
    have python3 || return 0
    ino=$(stat -c %i "$4" 2>&1)
    case "$ino" in ''|*[!0-9]*) ino=0 ;; esac
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor diag-harness-stall.sh --verdict STALLED --detail "$detail" \
        --source diag-harness-stall --key "diag-stall-$pid-$gate-$ino" 2>&1 \
        || printf 'diag: advisory ledger record failed (non-fatal)\n'
}

self_test() {
    local work rc fails=0 out
    work=$(mktemp -d "${TMPDIR:-/tmp}/diagst.XXXXXX" 2>&1) || {
        printf 'FAIL mktemp\n'; return 1; }
    mkdir -p "$work/proc" "$work/logs/tmp.live" "$work/logs/tmp.stale"
    local live="$work/logs/tmp.live/test-hygiene.log"
    local stale="$work/logs/tmp.stale/lint.log"
    printf 'ts=1 status=PASS alpha\nts=2 status=PASS beta\n' > "$live"
    printf 'ts=1 status=PASS old\n' > "$stale"

    # live fixture: pid 100 runs scripts/harness.sh with the log on fd 3
    mkdir -p "$work/proc/100/fd"
    printf '100 (bash) S 1 100 100 0 -1 0 0 0 0 0 5 5 0 0 20 0 1 0 100 0 0 0 0 0 0 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' > "$work/proc/100/stat"
    printf 'bash\0./scripts/harness.sh\0--fast\0' > "$work/proc/100/cmdline"
    ln -s "$live" "$work/proc/100/fd/3"
    mkdir -p "$work/proc/101"
    printf '101 (self-test) S 100 100 100 0 -1 0 0 0 0 0 1 1 0 0 20 0 1 0 101 0 0 0 0 0 0 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' > "$work/proc/101/stat"
    printf 'sleep\00030\0' > "$work/proc/101/cmdline"

    out=$(DIAG_PROC_ROOT="$work/proc" "$SCRIPT" --tmp "$work/logs/tmp.live" --sample 0 --json --no-ledger 2>&1)
    rc=$?
    if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then
        printf 'PASS live fixture classified (%s)\n' "$rc"
    else
        printf 'FAIL live fixture rc=%s out=%s\n' "$rc" "$out"; fails=$((fails + 1))
    fi
    case "$out" in
        *'"pid":100'*) printf 'PASS live pid named\n' ;;
        *) printf 'FAIL live pid named\n'; fails=$((fails + 1)) ;;
    esac
    case "$out" in
        *'"pid":101'*) printf 'PASS child in tree\n' ;;
        *) printf 'FAIL child in tree\n'; fails=$((fails + 1)) ;;
    esac
    if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["verdict"] in ("PROGRESSING","BUSY","BLOCKED_IO","BLOCKED_LOCK","STALLED"); assert d["children"]' 2>&1; then
        printf 'PASS JSON schema\n'
    else
        printf 'FAIL JSON schema\n'; fails=$((fails + 1))
    fi

    mkdir -p "$work/proc.empty"
    out=$(DIAG_PROC_ROOT="$work/proc.empty" "$SCRIPT" --tmp "$work/logs/tmp.stale" --sample 0 2>&1)
    rc=$?
    if [ "$rc" -eq 5 ]; then printf 'PASS stale run -> rc=5\n'; else
        printf 'FAIL stale run rc=%s\n' "$rc"; fails=$((fails + 1)); fi
    case "$out" in
        *STALE*) printf 'PASS stale verdict (not STALLED)\n' ;;
        *) printf 'FAIL stale verdict\n'; fails=$((fails + 1)) ;;
    esac

    mkdir -p "$work/logs/tmp.empty"
    out=$(DIAG_PROC_ROOT="$work/proc.empty" "$SCRIPT" --tmp "$work/logs/tmp.empty" --sample 0 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then printf 'PASS no log -> rc=2\n'; else
        printf 'FAIL no log rc=%s\n' "$rc"; fails=$((fails + 1)); fi

    out=$("$SCRIPT" --sample 2>&1); rc=$?
    if [ "$rc" -eq 2 ]; then printf 'PASS --sample without value -> rc=2\n'; else
        printf 'FAIL --sample without value rc=%s\n' "$rc"; fails=$((fails + 1)); fi
    out=$("$SCRIPT" --sample abc 2>&1); rc=$?
    if [ "$rc" -eq 2 ]; then printf 'PASS non-numeric --sample -> rc=2\n'; else
        printf 'FAIL non-numeric --sample rc=%s\n' "$rc"; fails=$((fails + 1)); fi

    find "$work" -depth -delete 2>&1
    if [ "$fails" -eq 0 ]; then printf 'self-test: PASS\n'; return 0; fi
    printf 'self-test: FAIL (%s)\n' "$fails"
    return 1
}

render() {
    local verdict="$1" rc="$2" log="$3" gate="$4" size="$5" delta="$6" age="$7" \
        method="$8" checks="$9" last="${10}" pids="${11}" psi="${12}"
    local p out="" sep="" cpu state wchan io pp hz
    hz=$(getconf CLK_TCK 2>&1)
    case "$hz" in ''|*[!0-9]*) hz=100 ;; esac
    if [ "$JSON" -eq 1 ]; then
        for p in $pids; do
            state=$(proc_state "$p"); pp=$(proc_ppid "$p")
            wchan=$(proc_wchan "$p"); io=$(proc_io "$p")
            cpu=$(awk -v a="${pre_ticks[$p]:-0}" -v b="${post_ticks[$p]:-0}" \
                -v h="$hz" -v s="$SAMPLE" \
                'BEGIN { if (s > 0) printf "%.1f", (b - a) * 100 / h / s; else printf "0.0" }')
            out="$out$sep{\"pid\":$p,\"ppid\":${pp:-0},\"state\":\"$(json_safe <<< "$state")\",\"wchan\":\"$(json_safe <<< "$wchan")\",\"io\":\"$(json_safe <<< "$io")\",\"cpu_pct\":$cpu}"
            sep=","
        done
        printf '{"verdict":"%s","exit":%d,"log":"%s","gate":"%s","bytes":%s,"delta":%s,"last_write_age":%s,"method":"%s","checks":%s,"last":"%s","psi_io":%s,"children":[%s]}\n' \
            "$verdict" "$rc" "$(json_safe <<< "$log")" "$gate" "$size" "$delta" \
            "$age" "$method" "$checks" "$(json_safe <<< "$last")" "${psi:-null}" "$out"
        return
    fi
    printf '=== diag-harness-stall ===\n'
    printf 'log:        %s\n' "$log"
    printf 'gate:       %s\n' "$gate"
    printf 'size:       %s bytes (delta %+d in %ss, %s)\n' "$size" "$delta" "$SAMPLE" "$method"
    printf 'last write: %ss ago\n' "$age"
    printf 'checks:     %s status line(s) so far\n' "$checks"
    printf 'last check: %s\n' "${last:-(none yet)}"
    printf '\n--- process tree under harness.sh ---\n'
    if [ -n "$pids" ]; then
        for p in $pids; do
            state=$(proc_state "$p"); pp=$(proc_ppid "$p")
            wchan=$(proc_wchan "$p"); io=$(proc_io "$p")
            cpu=$(awk -v a="${pre_ticks[$p]:-0}" -v b="${post_ticks[$p]:-0}" \
                -v h="$hz" -v s="$SAMPLE" \
                'BEGIN { if (s > 0) printf "%.1f", (b - a) * 100 / h / s; else printf "0.0" }')
            printf 'pid=%s ppid=%s state=%s cpu=%s%% wchan=%s io=%s cmd=%s\n' \
                "$p" "${pp:-?}" "$state" "$cpu" "$wchan" "$io" "$(proc_cmd "$p")"
        done
    else
        printf '(no scripts/harness.sh process)\n'
    fi
    printf '\n--- host pressure ---\n'
    printf 'loadavg: %s\n' "$(cat "$PROC/loadavg" 2>&1)"
    if [ -r "$PROC/pressure/io" ]; then
        printf 'psi io:  %s\n' "$(awk '/^some/ { print }' "$PROC/pressure/io")"
    fi
    printf '\n--- verdict ---\n'
    printf '%s\n' "$verdict"
    case "$verdict" in
        PROGRESSING|BUSY) printf 'the gate is alive; wait.\n' ;;
        BLOCKED_IO) printf 'the log is quiet and the tree is I/O-blocked (D state or PSI); relieve host I/O, then wait.\n' ;;
        BLOCKED_LOCK) printf 'the log is quiet and a child waits on a lock (futex); suspect a deadlock, not load.\n' ;;
        STALLED) printf 'no growth and no attributable block: bound it with timeout 120 <deepest cmd>.\n' ;;
        STALE) printf 'this log belongs to a finished run; start harness.sh to diagnose a live one.\n' ;;
        NO_LOG) printf 'no harness gate log here; run this where harness.sh is running.\n' ;;
    esac
}

main() {
    local selftest=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --sample)
                if [ $# -lt 2 ]; then printf 'missing value for --sample\n'; usage; return 2; fi
                SAMPLE="$2"; shift 2 ;;
            --sample=*) SAMPLE="${1#--sample=}"; shift ;;
            --tmp)
                if [ $# -lt 2 ]; then printf 'missing value for --tmp\n'; usage; return 2; fi
                TMPROOT="$2"; shift 2 ;;
            --tmp=*) TMPROOT="${1#--tmp=}"; shift ;;
            --json) JSON=1; shift ;;
            --no-ledger) LEDGER=0; shift ;;
            --self-test) selftest=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) usage; return 2 ;;
        esac
    done
    case "$SAMPLE" in
        ''|*[!0-9]*) printf 'bad --sample: %s\n' "$SAMPLE"; usage; return 2 ;;
    esac
    [ "$selftest" -eq 1 ] && { self_test; return $?; }

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")

    local roots pid="" log="" gate=""
    roots=$(harness_roots)
    if [ -n "$roots" ]; then
        for pid in $roots; do
            log=$(live_log "$pid")
            [ -n "$log" ] && break
        done
    fi
    if [ -z "$log" ]; then
        log=$(latest_log "$TMPROOT")
    fi
    if [ -z "$log" ] || [ ! -f "$log" ]; then
        render NO_LOG 2 "" "" 0 0 0 poll 0 "" "" ""
        return 2
    fi
    gate="${log##*/}"; gate="${gate%.log}"
    if [ -z "$roots" ]; then
        render STALE 5 "$log" "$gate" "$(stat -c %s "$log" 2>&1)" 0 \
            "$(( $(date +%s) - $(stat -c %Y "$log" 2>&1) ))" poll \
            "$(grep -c 'status=' "$log" 2>&1)" "$(grep 'status=' "$log" | tail -n 1)" \
            "" ""
        return 5
    fi

    local pids size_before growth delta age method checks last hz psi_io
    pids=$(tree_from "$roots")
    size_before=$(stat -c %s "$log" 2>&1)
    local -A pre_ticks=()
    for pid in $pids; do pre_ticks[$pid]=$(proc_ticks "$pid"); done
    growth=$(growth_sample "$log" "$SAMPLE")
    delta=$(field "$growth" delta); age=$(field "$growth" last_age); method=$(field "$growth" method)
    case "$delta" in ''|*[!0-9]*) delta=0 ;; esac
    case "$age" in ''|*[!0-9.]*) age=0 ;; esac
    local -A post_ticks=()
    for pid in $pids; do post_ticks[$pid]=$(proc_ticks "$pid"); done
    hz=$(getconf CLK_TCK 2>&1); case "$hz" in ''|*[!0-9]*) hz=100 ;; esac
    checks=$(grep -c 'status=' "$log" 2>&1); case "$checks" in ''|*[!0-9]*) checks=0 ;; esac
    last=$(grep 'status=' "$log" | tail -n 1)
    psi_io=$(awk '/^some/ { for (i = 1; i <= NF; i++) if (index($i, "avg10=") == 1) { sub("avg10=", "", $i); printf "%s", $i } }' "$PROC/pressure/io" 2>&1)
    case "$psi_io" in ''|*[!0-9.]*) psi_io=0 ;; esac

    local verdict rc any_cpu=0 any_d=0 any_lock=0 state wchan cpu
    for pid in $pids; do
        state=$(proc_state "$pid"); wchan=$(proc_wchan "$pid")
        cpu=$(awk -v a="${pre_ticks[$pid]:-0}" -v b="${post_ticks[$pid]:-0}" \
            -v h="$hz" -v s="$SAMPLE" \
            'BEGIN { v = (s > 0) ? (b - a) * 100 / h / s : 0; printf "%d", (v > 0.5) }')
        [ "$cpu" -eq 1 ] && any_cpu=1
        [ "$state" = "D" ] && any_d=1
        case "$wchan" in *futex*|*mutex*|*rwsem*|*lock*) any_lock=1 ;; esac
    done

    if [ "$delta" -gt 0 ]; then
        verdict=PROGRESSING; rc=0
    elif [ "$any_cpu" -eq 1 ]; then
        verdict=BUSY; rc=0
    elif [ "$any_d" -eq 1 ] || awk -v p="$psi_io" 'BEGIN { exit !(p >= 20) }'; then
        verdict=BLOCKED_IO; rc=3
    elif [ "$any_lock" -eq 1 ]; then
        verdict=BLOCKED_LOCK; rc=3
    else
        verdict=STALLED; rc=4
    fi

    if [ "$rc" -eq 4 ]; then
        local root1
        root1=$(printf '%s\n' "$roots" | head -n 1)
        ledger_advisory "$root1" "$gate" "gate=$gate age=${age}s delta=0" "$log"
    fi
    render "$verdict" "$rc" "$log" "$gate" "$size_before" "$delta" "$age" "$method" \
        "$checks" "$last" "$pids" "$psi_io"
    return "$rc"
}

main "$@"
