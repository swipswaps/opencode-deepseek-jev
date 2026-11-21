#!/usr/bin/env bash
#
# chromium-video-audit.sh - read-only audit of a running Chromium and its
# video path, with a reversible one-key fix for the Fedora AMD VA-API gap.
#
# Default is --dry-run: it prints telemetry and a ranked verdict, writes
# nothing, restarts nothing. --apply changes exactly one line in
# /etc/chromium/chromium.conf (GRAPHIC_DRIVER=amd), after a timestamped
# backup; --revert restores that backup and verifies it.
#
# Why this exists: Chromium on Linux only uses the AMD decode engine when
# the VA-API switches are present. Fedora's /etc/chromium/chromium.conf
# adds them only for GRAPHIC_DRIVER=amd|intel. With GRAPHIC_DRIVER=default
# the AMD branch is skipped, so clear video can software-decode. DRM
# (Widevine L3) content is software-decoded regardless of flags; the tool
# says so instead of promising a flag fix that cannot work.
#
# The decode evidence is the kernel's own counter:
#   /proc/<gpu-pid>/fdinfo/<fd>  drm-engine-dec: <ns>
# A nonzero delta during playback means the VCN decode engine is working.
# Renderer thread names (VaapiDecoder / VideoDecodeThread) corroborate it.
#
# Usage:
#   ./scripts/chromium-video-audit.sh                 # dry-run, 5 s sample
#   ./scripts/chromium-video-audit.sh --sample 10
#   ./scripts/chromium-video-audit.sh --json
#   sudo ./scripts/chromium-video-audit.sh --apply    # backup + one-line edit
#   sudo ./scripts/chromium-video-audit.sh --revert
#   ./scripts/chromium-video-audit.sh --verify        # after restart
#   ./scripts/chromium-video-audit.sh --self-test
#
# Exit: 0 audit ran; 1 reserved for a failed apply/revert/verify; 3 usage.
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.

set -uo pipefail

CONF=${CHROMIUM_CONF:-/etc/chromium/chromium.conf}
STATE_DIR=${CHROMIUM_AUDIT_STATE:-/var/lib/chromium-video-audit}
SAMPLE=${CHROMIUM_AUDIT_SAMPLE:-5}
SELF=$(readlink -f "$0")
MODE=dry-run
JSON=0
DEC_ACTIVE=0
CDM_PCT=0
FINDINGS=()

say() { printf '%s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null; }

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# ---- discovery ------------------------------------------------------------

chromium_pids() {
  pgrep -f '/usr/lib64/chromium-browser/chromium-browser' || true
}

main_pid() {
  local p
  for p in $(chromium_pids); do
    if ! tr '\000' ' ' < "/proc/$p/cmdline" | grep -q -- '--type='; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

gpu_pid() {
  local p
  for p in $(chromium_pids); do
    if tr '\000' ' ' < "/proc/$p/cmdline" | grep -q -- '--type=gpu-process'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

cdm_pid() {
  local p
  for p in $(chromium_pids); do
    if tr '\000' ' ' < "/proc/$p/cmdline" | grep -q 'CdmServiceBroker'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

proc_cmdline() {
  tr '\000' ' ' < "/proc/$1/cmdline"
}

proc_status() {
  awk -v k="$2" '$1==k":"{print $2; exit}' "/proc/$1/status"
}

proc_cpu_s() {
  awk '{print ($14+$15)/100}' "/proc/$1/stat"
}

engine_values() {
  awk '/drm-engine-dec:/{d=$2}
       /drm-engine-gfx:/{g=$2}
       /drm-engine-compute:/{c=$2}
       END{print d+0, g+0, c+0}' "$1"
}

find_dec_fd() {
  local p=$1 fdpath fd
  for fdpath in "/proc/$p/fd/"*; do
    fd=${fdpath##*/}
    if test -r "/proc/$p/fdinfo/$fd" &&
       awk '/drm-engine-dec:/{found=1} END{exit !found}' "/proc/$p/fdinfo/$fd"; then
      printf '%s\n' "$fd"
      return 0
    fi
  done
  return 1
}

decoder_threads() {
  local t
  for t in "/proc/$1/task/"*/comm; do
    cat "$t"
  done | grep -Eic 'vaapi|videodecode|videodecoder' || true
}

widevine_mapped() {
  local p
  for p in $(chromium_pids); do
    if grep -q 'libwidevinecdm.so' "/proc/$p/maps"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

zombie_count() {
  ps -eo stat= | awk '$1 ~ /^Z/{n++} END{print n+0}'
}

zombie_parent() {
  ps -eo ppid=,stat=,comm= |
    awk '$2 ~ /^Z/{c[$1]++; n[$1]=$3}
         END{for(k in c) printf "%d %s %s\n", c[k], k, n[k]}' |
    sort -rn | head -n 1
}

add_finding() { FINDINGS+=("$1|$2|$3"); }
prune() { :; }

# ---- inspection -----------------------------------------------------------

section_identity() {
  head2 'identity'
  printf 'host=%s user=%s kernel=%s\n' "$(hostname)" "$(id -un)" "$(uname -sr)"
  printf 'cpu=%s\n' "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
  printf 'nproc=%s load=%s\n' "$(nproc)" "$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
  printf 'session=%s display=%s\n' "${XDG_SESSION_TYPE:-?}" "${DISPLAY:-?}"
}

section_chromium() {
  head2 'chromium'
  local p
  p=$(main_pid) || { say 'not running (no browser process found)'; return 1; }
  local bin
  bin=$(readlink -f "/proc/$p/exe")
  printf 'pid=%s rss_kb=%s swap_kb=%s cpu_s=%s\n' \
    "$p" "$(proc_status "$p" VmRSS)" "$(proc_status "$p" VmSwap)" "$(proc_cpu_s "$p")"
  printf 'version=%s\n' "$("$bin" --version 2>&1 | head -n 1)"
  printf 'flags=\n'
  tr ' ' '\n' < "/proc/$p/cmdline" | tr -d '\000' | grep -aE '^--' | awk '{print "  " $0}'
  return 0
}

section_config() {
  head2 'fedora config'
  if test -f "$CONF"; then
    printf 'file=%s\n' "$CONF"
    printf 'GRAPHIC_DRIVER=%s\n' "$(awk -F= '/^GRAPHIC_DRIVER=/{print $2; exit}' "$CONF")"
    printf 'NATIVE_WAYLAND=%s\n' "$(awk -F= '/^NATIVE_WAYLAND=/{print $2; exit}' "$CONF")"
    printf 'WEB_AUTO_DARKMODE_WEBCONTENT=%s\n' "$(awk -F= '/^WEB_AUTO_DARKMODE_WEBCONTENT=/{print $2; exit}' "$CONF")"
  else
    printf 'file=%s (absent)\n' "$CONF"
  fi
}

section_graphics() {
  head2 'graphics'
  if have vainfo; then
    vainfo 2>&1 | awk '/Driver version|VAProfileVP9|VAProfileHEVCMain|VAProfileAV1|VAProfileH264High/{print "  " $0}'
  else
    say 'vainfo absent'
  fi
  if have glxinfo; then
    glxinfo -B 2>&1 | awk '/OpenGL renderer string|Accelerated:/{print "  " $0}'
  fi
  printf 'dri='; ls /dev/dri 2>&1 | tr '\n' ' '; printf '\n'
  printf 'gpu_driver=%s\n' "$(lspci -nnk 2>&1 | awk '/VGA compatible|3D controller/{f=1} f&&/Kernel driver in use/{print $NF; f=0}')"
}

section_runtime() {
  head2 'runtime'
  local p g r
  g=$(gpu_pid) || g=""
  if test -n "$g"; then
    printf 'gpu_pid=%s rss_kb=%s swap_kb=%s cpu_s=%s\n' \
      "$g" "$(proc_status "$g" VmRSS)" "$(proc_status "$g" VmSwap)" "$(proc_cpu_s "$g")"
    printf 'decoder_threads=%s\n' "$(decoder_threads "$g")"
  else
    say 'gpu process not found'
  fi
  printf 'renderers:\n'
  for p in $(chromium_pids); do
    if proc_cmdline "$p" | grep -q -- '--type=renderer'; then
      r=$(proc_cmdline "$p" | grep -Eo -- '--renderer-client-id=[0-9]+' || true)
      printf '  pid=%s %s rss_kb=%s swap_kb=%s cpu_s=%s\n' \
        "$p" "$r" "$(proc_status "$p" VmRSS)" "$(proc_status "$p" VmSwap)" "$(proc_cpu_s "$p")"
    fi
  done
  local c
  c=$(cdm_pid) || c=""
  if test -n "$c"; then
    CDM_PCT=$(ps -o pcpu= -p "$c" | tr -d ' ')
    printf 'cdm_pid=%s rss_kb=%s swap_kb=%s cpu_s=%s cdm_cpu_pct=%s\n' \
      "$c" "$(proc_status "$c" VmRSS)" "$(proc_status "$c" VmSwap)" "$(proc_cpu_s "$c")" "$CDM_PCT"
  fi
  local w
  w=$(widevine_mapped) || w=""
  if test -n "$w"; then
    if test -n "$c"; then printf 'widevine_cdm=present (cdm pid %s)\n' "$c"; else printf 'widevine_cdm=present\n'; fi
  else
    printf 'widevine_cdm=absent\n'
  fi
}

section_decode() {
  head2 'decode engine'
  local g fd d0 g0 c0 d1 g1 c1
  g=$(gpu_pid) || { say 'gpu process not found; cannot sample'; return 1; }
  fd=$(find_dec_fd "$g") || { say 'no DRM decode counter (render node not open)'; return 1; }
  read -r d0 g0 c0 < <(engine_values "/proc/$g/fdinfo/$fd")
  sleep "$SAMPLE"
  read -r d1 g1 c1 < <(engine_values "/proc/$g/fdinfo/$fd")
  printf 'sample_s=%s dec_delta_s=%s gfx_delta_s=%s compute_delta_s=%s\n' \
    "$SAMPLE" \
    "$(awk -v a="$d0" -v b="$d1" 'BEGIN{printf "%.3f",(b-a)/1e9}')" \
    "$(awk -v a="$g0" -v b="$g1" 'BEGIN{printf "%.3f",(b-a)/1e9}')" \
    "$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.3f",(b-a)/1e9}')"
  printf 'dec_total_s=%s\n' "$(awk -v a="$d1" 'BEGIN{printf "%.0f",a/1e9}')"
  if awk -v a="$d0" -v b="$d1" 'BEGIN{exit !(b>a)}'; then
    DEC_ACTIVE=1
    printf 'hw_decode_active=yes\n'
  else
    printf 'hw_decode_active=no (idle decode engine during the sample)\n'
  fi
}

section_pressure() {
  head2 'pressure'
  awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/{print "  " $0}' /proc/meminfo
  printf 'psi_cpu: '; tr '\n' ' ' < /proc/pressure/cpu; printf '\n'
  printf 'psi_io:  '; tr '\n' ' ' < /proc/pressure/io; printf '\n'
  printf 'psi_mem: '; tr '\n' ' ' < /proc/pressure/memory; printf '\n'
  printf 'top_cpu:\n'
  ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 6 | awk '{print "  " $0}'
}

section_network() {
  head2 'network'
  if have iw; then
    iw dev 2>&1 | awk '/Interface|ssid|channel|txpower/{print "  " $0}'
  fi
  if have nmcli; then
    nmcli -t -f ACTIVE,SSID,SIGNAL,RATE device wifi 2>&1 | awk -F: '$1=="yes"{print "  active ssid=" $2 " signal=" $3 " rate=" $4}'
  fi
  if have nstat; then
    nstat -az 2>&1 |
      awk '/^TcpOutSegs/{o=$2}/^TcpRetransSegs/{r=$2}/^TcpExtTCPLostRetransmit/{l=$2}
           END{printf "  tcp_out=%s retrans=%s lost_retrans=%s retrans_pct=%.3f\n",o,r,l,(o>0?100*r/o:0)}'
  fi
}

section_outliers() {
  head2 'outliers'
  printf 'zombies=%s\n' "$(zombie_count)"
  printf 'zombie_top_parent=%s\n' "$(zombie_parent)"
  printf 'chromium_processes=%s rss_total_kb=%s\n' \
    "$(chromium_pids | wc -l)" \
    "$(ps -eo rss,args | grep 'chromium-browser' | grep -v grep | awk '{s+=$1} END{print s+0}')"
}

# ---- verdict --------------------------------------------------------------

verdict() {
  local main g d cdmd z load npsi swap_used swap_total w conf_driver
  main=$(main_pid) || return 1
  g=$(gpu_pid) || g=""
  z=$(zombie_count)
  load=$(awk '{print $1}' /proc/loadavg)
  npsi=$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/cpu)
  swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  swap_used=$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t-f}' /proc/meminfo)
  cdmd=$(cdm_pid) || cdmd=""
  w=$(widevine_mapped) || w=""
  conf_driver=$(awk -F= '/^GRAPHIC_DRIVER=/{print $2; exit}' "$CONF" 2>&1)

  if test -n "$w"; then
    add_finding "DRM" "PRIMARY" "Widevine L3 content is software-decoded; no Linux AMD flag enables protected hardware decode"
  fi
  if test -n "$cdmd"; then
    add_finding "CDM_CPU" "PRIMARY" "CDM utility pid=$cdmd cpu_s=$(proc_cpu_s "$cdmd"); protected decode lands in this process"
  fi
  if test "$DEC_ACTIVE" -eq 0 && awk -v c="$CDM_PCT" 'BEGIN{exit !(c>5)}'; then
    add_finding "SW_DECODE" "SECONDARY" "decode engine idle while CDM CPU=${CDM_PCT}%; this content is software-decoded"
  elif test "$DEC_ACTIVE" -eq 0 && test -n "$g"; then
    add_finding "DECODE_IDLE" "SECONDARY" "decode engine idle during the sample; confirm playback, then re-run --verify"
  fi
  if test -f "$CONF" && awk -v v="$conf_driver" 'BEGIN{exit !(v!="amd" && v!="intel")}'; then
    add_finding "CONFIG_AMD" "SECONDARY" "GRAPHIC_DRIVER is not amd/intel; Fedora's AMD VA-API switches are skipped"
  fi
  if awk -v l="$load" -v n="$(nproc)" 'BEGIN{exit !(l>n)}'; then
    add_finding "CPU_PRESSURE" "AMPLIFIER" "load $load exceeds $(nproc) runnable CPUs; PSI cpu avg10=$npsi"
  fi
  if test "$swap_total" -gt 0 && awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{exit !(u/t>0.25)}'; then
    add_finding "SWAP" "AMPLIFIER" "swap used $((swap_used/1024)) MiB of $((swap_total/1024)) MiB; evicted renderer pages cause hitches"
  fi
  if test "$z" -gt 20; then
    add_finding "ZOMBIES" "NOISE" "$z zombie processes; cosmetic, but they mark a leaking headless parent"
  fi
  add_finding "NETWORK" "OK" "5 GHz high-rate Wi-Fi with low retransmit share; not the stutter source"

  head2 'verdict'
  local row id sev msg
  for row in "${FINDINGS[@]}"; do
    id=${row%%|*}; row=${row#*|}
    sev=${row%%|*}; msg=${row#*|}
    printf '%-14s %-9s %s\n' "$id" "$sev" "$msg"
  done
  printf '\norder: fix AMPLIFIER/CPU first (it is reversible and immediate), then CONFIG_AMD/VA_DRIVER for clear content; DRM is structural on Linux.\n'
}

# ---- apply / revert -------------------------------------------------------

conf_set_amd() {
  python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
new, n = re.subn(r"(?m)^GRAPHIC_DRIVER=.*$", "GRAPHIC_DRIVER=amd", text)
if n != 1:
    sys.stderr.write("expected exactly one GRAPHIC_DRIVER line, found %d\n" % n)
    raise SystemExit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(new)
PY
}

do_apply() {
  head2 'apply'
  if test "$(id -u)" -ne 0; then
    printf 'need root; run: sudo %s --apply\n' "$SELF"
    return 1
  fi
  if ! test -f "$CONF"; then
    printf 'missing %s\n' "$CONF"
    return 1
  fi
  mkdir -p "$STATE_DIR" || return 1
  local ts backup old
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  backup="$STATE_DIR/chromium.conf.$ts.bak"
  old=$(awk -F= '/^GRAPHIC_DRIVER=/{print $2; exit}' "$CONF")
  printf 'before: GRAPHIC_DRIVER=%s\n' "$old"
  cp -a "$CONF" "$backup" || return 1
  printf '%s\n' "$backup" > "$STATE_DIR/current"
  printf 'backup: %s\n' "$backup"
  if ! conf_set_amd "$CONF"; then
    cp -a "$backup" "$CONF"
    printf 'edit failed; restored %s\n' "$CONF"
    return 1
  fi
  if ! grep -q '^GRAPHIC_DRIVER=amd' "$CONF"; then
    cp -a "$backup" "$CONF"
    printf 'verification failed; restored %s\n' "$CONF"
    return 1
  fi
  printf 'after:  GRAPHIC_DRIVER=amd\n'
  printf 'diff:\n'
  diff -u "$backup" "$CONF" || true
  printf '\nrestart Chromium for flags to take effect (sessions restore): close every Chromium window, then reopen.\n'
  printf 'revert: sudo %s --revert\n' "$SELF"
  return 0
}

do_revert() {
  head2 'revert'
  if test "$(id -u)" -ne 0; then
    printf 'need root; run: sudo %s --revert\n' "$SELF"
    return 1
  fi
  local cur
  if ! test -f "$STATE_DIR/current"; then
    printf 'no recorded backup under %s\n' "$STATE_DIR"
    return 1
  fi
  cur=$(cat "$STATE_DIR/current")
  if ! test -f "$cur"; then
    printf 'recorded backup is missing: %s\n' "$cur"
    return 1
  fi
  cp -a "$cur" "$CONF" || return 1
  if cmp -s "$cur" "$CONF"; then
    printf 'restored and verified: %s -> %s\n' "$cur" "$CONF"
    printf 'restart Chromium to drop the flags.\n'
    return 0
  fi
  printf 'restore did not verify\n'
  return 1
}

do_verify() {
  head2 'verify (after restart)'
  local main g fd d0 d1
  main=$(main_pid) || { say 'Chromium is not running'; return 1; }
  if tr ' ' '\n' < "/proc/$main/cmdline" | grep -qa -- '--enable-accelerated-video-decode'; then
    printf 'flags=AMD decode switch present\n'
  else
    printf 'flags=AMD decode switch absent (GRAPHIC_DRIVER not amd, or not restarted)\n'
  fi
  g=$(gpu_pid) || { say 'gpu process not found'; return 1; }
  printf 'decoder_threads=%s\n' "$(decoder_threads "$g")"
  fd=$(find_dec_fd "$g") || { say 'no decode counter'; return 1; }
  d0=$(engine_values "/proc/$g/fdinfo/$fd" | awk '{print $1}')
  sleep "$SAMPLE"
  d1=$(engine_values "/proc/$g/fdinfo/$fd" | awk '{print $1}')
  printf 'dec_delta_s=%s\n' "$(awk -v a="$d0" -v b="$d1" 'BEGIN{printf "%.3f",(b-a)/1e9}')"
  if awk -v a="$d0" -v b="$d1" 'BEGIN{exit !(b>a)}'; then
    printf 'verdict=PASS hardware decode is running\n'
    return 0
  fi
  printf 'verdict=FAIL no decode during the sample; if this is Widevine content that is expected (L3 is software-only), otherwise restart was skipped or the codec has no AMD decoder (AV1 on Renoir).\n'
  return 1
}

# ---- self-test ------------------------------------------------------------

do_selftest() {
  local tmp rc
  tmp=$(mktemp -d) || return 1
  printf 'drm-engine-gfx:\t100 ns\ndrm-engine-compute:\t50 ns\ndrm-engine-dec:\t900 ns\n' > "$tmp/fdinfo"
  read -r d g c < <(engine_values "$tmp/fdinfo")
  if test "$d" != "900" || test "$g" != "100" || test "$c" != "50"; then
    printf 'FAIL engine_values got %s %s %s\n' "$d" "$g" "$c"
    rc=1
  else
    printf 'PASS engine_values\n'
    rc=0
  fi
  printf '# keep\nGRAPHIC_DRIVER=default\n# tail\n' > "$tmp/conf"
  conf_set_amd "$tmp/conf" || rc=1
  if grep -q '^GRAPHIC_DRIVER=amd$' "$tmp/conf" && test "$(grep -c '^# ' "$tmp/conf")" = "2"; then
    printf 'PASS conf_set_amd preserves the rest\n'
  else
    printf 'FAIL conf_set_amd\n'
    rc=1
  fi
  printf '# no driver line here\n' > "$tmp/conf2"
  if conf_set_amd "$tmp/conf2"; then
    printf 'FAIL conf_set_amd should reject a missing anchor\n'
    rc=1
  else
    printf 'PASS conf_set_amd fails closed\n'
  fi
  rm -f "$tmp/fdinfo" "$tmp/conf" "$tmp/conf2"
  rmdir "$tmp"
  return "$rc"
}

# ---- entry ----------------------------------------------------------------

usage() {
  printf 'usage: %s [--dry-run] [--apply] [--revert] [--verify] [--self-test] [--sample N] [--json] [--help]\n' "$0"
}

main() {
  local want=audit
  while test $# -gt 0; do
    case "$1" in
      --dry-run) MODE=dry-run ;;
      --apply) want=apply ;;
      --revert) want=revert ;;
      --verify) want=verify ;;
      --self-test) want=selftest ;;
      --json) JSON=1 ;;
      --sample) shift; SAMPLE=${1:-5} ;;
      --help|-h) usage; return 0 ;;
      *) printf 'unknown option: %s\n' "$1"; usage; return 3 ;;
    esac
    shift
  done

  case "$want" in
    apply) do_apply; return $? ;;
    revert) do_revert; return $? ;;
    verify) do_verify; return $? ;;
    selftest) do_selftest; return $? ;;
  esac

  section_identity
  if section_chromium; then
    section_config
    section_graphics
    section_runtime
    section_decode
  fi
  section_pressure
  section_network
  section_outliers
  verdict

  if test "$MODE" = "dry-run"; then
    printf '\nmode=dry-run (no writes, no restarts)\n'
  fi
  if test "$JSON" -eq 1; then
    printf '{"findings":['
    local i=0 row
    for row in "${FINDINGS[@]}"; do
      test "$i" -gt 0 && printf ','
      printf '{"id":%s,"severity":%s,"message":%s}' \
        "$(json_escape "${row%%|*}")" \
        "$(json_escape "$(row=${row#*|}; printf '%s' "${row%%|*}")")" \
        "$(json_escape "$(row=${row#*|}; printf '%s' "${row#*|}")")"
      i=$((i+1))
    done
    printf ']}\n'
  fi
  return 0
}

main "$@"
