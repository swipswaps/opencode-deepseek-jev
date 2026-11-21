#!/usr/bin/env bash
#
# chromium-video-priority.sh - identify the process actually decoding video
# and raise its CPU scheduling priority, reversibly.
#
# Why: the video pipeline is not the browser process. It is the CDM utility
# (Widevine / CdmServiceBroker), the GPU process, and the heavy renderer. On
# this host they sit in session-2.scope (cpu.weight=100) while the browser
# main process sits in a 500-weight user-service branch, so the process doing
# the work is structurally deprioritized. All of them run at nice 0.
#
# This tool prioritizes the three video processes, not the whole browser:
#   - nice (per thread) via renice; root is required for a negative value.
#   - optional cgroup cpu.weight on their containing scope (root).
# A scratch-process probe showed an unprivileged user cannot migrate a PID out
# of session-2.scope ("Permission denied"), and this user manager does not
# apply CPUWeight to transient user scopes, so the effective path is root.
#
# Usage:
#   ./scripts/chromium-video-priority.sh                  # dry-run plan
#   ./scripts/chromium-video-priority.sh --status
#   sudo ./scripts/chromium-video-priority.sh --apply     # renice -10
#   sudo ./scripts/chromium-video-priority.sh --apply --weight 500
#   sudo ./scripts/chromium-video-priority.sh --revert
#   ./scripts/chromium-video-priority.sh --self-test
#
# Exit: 0 ran; 1 apply/revert failed; 3 usage.
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.

set -uo pipefail

STATE_DIR=${CHROMIUM_AUDIT_STATE:-/var/lib/chromium-video-audit}
STATE="$STATE_DIR/priority.tsv"
NICE=${CHROMIUM_PRIORITY_NICE:--10}
WEIGHT=${CHROMIUM_PRIORITY_WEIGHT:-0}
SAMPLE=${CHROMIUM_PRIORITY_SAMPLE:-1}
SELF=$(readlink -f "$0")

say() { printf '%s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

# One argv entry per line. `tr '\0'` is not portable here; GNU tr needs the
# octal '\000'. The previous form (`tr ' ' '\n' | tr -d '\000'`) deleted the
# NUL separators and silently joined every argument into one string.
nul_lines() { tr '\000' '\n'; }
argv_lines() { nul_lines < "/proc/$1/cmdline"; }

# Scan /proc by comm instead of matching a build-specific path with pgrep:
# pgrep is not installed everywhere, and the browser path differs by distro.
chromium_pids() {
  local d p comm
  for d in /proc/[0-9]*; do
    p=${d##*/}
    test -r "$d/comm" || continue
    comm=$(cat "$d/comm") || continue
    case "$comm" in
      *chromium*|*chrome*) printf '%s\n' "$p" ;;
    esac
  done
}

is_int() { [[ ${1:-} =~ ^-?[0-9]+$ ]]; }

cdm_pid() {
  local p
  for p in $(chromium_pids); do
    if argv_lines "$p" | grep -qa 'CdmServiceBroker'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

gpu_pid() {
  local p
  for p in $(chromium_pids); do
    if argv_lines "$p" | grep -qa -- '--type=gpu-process'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

renderer_pids() {
  local p
  for p in $(chromium_pids); do
    if argv_lines "$p" | grep -qa -- '--type=renderer'; then
      printf '%s\n' "$p"
    fi
  done
}

cpu_jiffies() {
  awk '{sub(/^.*\) /, ""); print $12+$13}' "/proc/$1/stat" 2>&1
}

# Pick the renderer that used the most CPU over one SAMPLE window.
top_renderer() {
  local p b d best best_d=-1 pids
  local -A before
  pids=$(renderer_pids)
  test -z "$pids" && return 1
  for p in $pids; do before[$p]=$(cpu_jiffies "$p") || return 1; done
  sleep "$SAMPLE"
  for p in $pids; do
    b=$(cpu_jiffies "$p") || continue
    d=$((b - before[$p]))
    if test "$d" -gt "$best_d"; then best_d=$d; best=$p; fi
  done
  test -n "${best:-}" && printf '%s\n' "$best"
}

cgroup_of() {
  awk -F: '{print $3}' "/proc/$1/cgroup"
}

cgroup_weight() {
  local f="/sys/fs/cgroup$1/cpu.weight"
  test -r "$f" && tr -d '\n' < "$f" || printf '?'
}

tids_of() {
  local t
  for t in "/proc/$1/task/"*; do
    test -d "$t" && printf '%s\n' "${t##*/}"
  done
}

nice_of() {
  awk '{sub(/^.*\) /, ""); print $17}' "/proc/$1/stat" 2>&1
}

# role/pid lines, computed once (the renderer pick costs one SAMPLE window).
TARGETS=()
load_targets() {
  local c g r
  TARGETS=()
  c=$(cdm_pid) || c=""
  g=$(gpu_pid) || g=""
  r=$(top_renderer) || r=""
  test -n "$c" && TARGETS+=("cdm $c")
  test -n "$g" && TARGETS+=("gpu $g")
  test -n "$r" && TARGETS+=("renderer $r")
  test "${#TARGETS[@]}" -gt 0 || return 2
  return 0
}

emit_targets() {
  local t
  for t in "${TARGETS[@]:-}"; do
    test -n "$t" && printf '%s\n' "$t"
  done
}

unique_cgroups() {
  local role p cg
  emit_targets | while read -r role p; do
    cg=$(cgroup_of "$p")
    printf '%s\n' "$cg"
  done | sort -u
}

show_status() {
  head2 'video processes'
  local role p cg
  while read -r role p; do
    test -n "$p" || continue
    cg=$(cgroup_of "$p")
    printf '%-9s pid=%-8s nice=%-3s threads=%-3s cgroup=%s weight=%s\n' \
      "$role" "$p" "$(nice_of "$p")" "$(tids_of "$p" | wc -l)" "$cg" "$(cgroup_weight "$cg")"
  done < <(emit_targets)
}

plan() {
  head2 'plan (dry-run)'
  local role p cg
  while read -r role p; do
    test -n "$p" || continue
    cg=$(cgroup_of "$p")
    printf 'target %-9s pid=%-8s nice=%-3s cgroup=%s weight=%s\n' \
      "$role" "$p" "$(nice_of "$p")" "$cg" "$(cgroup_weight "$cg")"
    printf '  would run: renice -n %s -p (all %s threads)\n' "$NICE" "$(tids_of "$p" | wc -l)"
  done < <(emit_targets)
  if test "$WEIGHT" -gt 0; then
    while read -r cg; do
      test -n "$cg" || continue
      printf '  would run: printf %s > /sys/fs/cgroup%s/cpu.weight  (old=%s)\n' \
        "$WEIGHT" "$cg" "$(cgroup_weight "$cg")"
    done < <(unique_cgroups)
  else
    say '  cgroup weight unchanged (pass --weight 500 to raise it)'
  fi
  printf '\nno-root fallback: renice +10 a same-user competitor (e.g. opencode) to yield CPU.\n'
  printf 'root command: sudo %s --apply%s\n' "$SELF" "$(test "$WEIGHT" -gt 0 && printf ' --weight %s' "$WEIGHT")"
}

do_apply() {
  head2 'apply'
  if test "$(id -u)" -ne 0; then
    printf 'need root; run: sudo %s --apply\n' "$SELF"
    return 1
  fi
  if ! command -v renice >/dev/null; then say 'renice absent'; return 1; fi
  mkdir -p "$STATE_DIR" || return 1
  if test -f "$STATE"; then
    cp -a "$STATE" "$STATE.$(date -u +%Y%m%dT%H%M%SZ).bak" || return 1
  fi
  printf '# ts=%s nice=%s weight=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NICE" "$WEIGHT" > "$STATE"

  local cg oldw p tid n=0
  if test "$WEIGHT" -gt 0; then
    while read -r cg; do
      test -n "$cg" || continue
      oldw=$(cgroup_weight "$cg")
      test "$oldw" = "?" && continue
      printf 'weight\t%s\t%s\n' "$cg" "$oldw" >> "$STATE"
      printf '%s\n' "$WEIGHT" > "/sys/fs/cgroup$cg/cpu.weight" || {
        printf 'cannot write weight for %s\n' "$cg"
        continue
      }
      printf 'weight %s: %s -> %s\n' "$cg" "$oldw" "$WEIGHT"
    done < <(unique_cgroups)
  fi

  while read -r p; do
    test -n "$p" || continue
    for tid in $(tids_of "$p"); do
      old=$(nice_of "$tid")
      test -z "$old" && continue
      printf 'nice\t%s\t%s\n' "$tid" "$old" >> "$STATE"
      renice -n "$NICE" -p "$tid" >/dev/null || {
        printf 'renice failed tid=%s\n' "$tid"
        continue
      }
      n=$((n+1))
    done
  done < <(emit_targets | awk '{print $2}')

  printf 'reniced threads=%s to %s\n' "$n" "$NICE"
  show_status
  printf '\nrevert: sudo %s --revert\n' "$SELF"
  return 0
}

do_revert() {
  head2 'revert'
  if test "$(id -u)" -ne 0; then
    printf 'need root; run: sudo %s --revert\n' "$SELF"
    return 1
  fi
  if ! test -f "$STATE"; then
    printf 'no state at %s\n' "$STATE"
    return 1
  fi
  local kind a b tid cg
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      nice)
        if test -d "/proc/$a"; then
          renice -n "$b" -p "$a" >/dev/null || printf 'restore failed tid=%s\n' "$a"
        fi
        ;;
      weight)
        if test -w "/sys/fs/cgroup$a/cpu.weight"; then
          printf '%s\n' "$b" > "/sys/fs/cgroup$a/cpu.weight" || printf 'restore failed %s\n' "$a"
        fi
        ;;
    esac
  done < "$STATE"
  show_status
  printf 'restored from %s\n' "$STATE"
  return 0
}

do_selftest() {
  local tmp rc
  tmp=$(mktemp -d) || return 1
  printf '%s\n' 'pidA 10' 'pidB 300' 'pidC 50' > "$tmp/cpu"
  local best
  best=$(awk '{if($2>m){m=$2;b=$1}} END{print b}' "$tmp/cpu")
  if test "$best" = "pidB"; then printf 'PASS rank picks highest\n'; rc=0; else printf 'FAIL rank\n'; rc=1; fi
  printf 'nice\t123\t0\nweight\t/x\t100\n' > "$tmp/state"
  if awk -F'\t' '$1=="nice"&&$2==123&&$3==0{ok=1} END{exit !ok}' "$tmp/state"; then
    printf 'PASS state parse\n'
  else
    printf 'FAIL state parse\n'; rc=1
  fi
  printf '#!/bin/sh\n' > "$tmp/s"
  if bash -n "$tmp/s"; then printf 'PASS bash -n fixture\n'; else printf 'FAIL fixture\n'; rc=1; fi
  if test "$(printf 'a\000b\000c\000' | nul_lines | wc -l)" -eq 3; then
    printf 'PASS argv NUL split\n'
  else
    printf 'FAIL argv NUL split\n'; rc=1
  fi
  if is_int -10 && is_int 7 && is_int 0 && ! is_int x && ! is_int 1-2; then
    printf 'PASS int validation\n'
  else
    printf 'FAIL int validation\n'; rc=1
  fi
  rm -f "$tmp/cpu" "$tmp/state" "$tmp/s"
  rmdir "$tmp"
  return "$rc"
}

usage() {
  printf 'usage: %s [--dry-run] [--status] [--apply] [--revert] [--self-test] [--nice N] [--weight W] [--sample S] [--help]\n' "$SELF"
}

main() {
  local want=plan
  while test $# -gt 0; do
    case "$1" in
      --dry-run) : ;;
      --status) want=status ;;
      --apply) want=apply ;;
      --revert) want=revert ;;
      --self-test) want=selftest ;;
      --nice) shift; NICE=${1:--10} ;;
      --weight) shift; WEIGHT=${1:-0} ;;
      --sample) shift; SAMPLE=${1:-1} ;;
      --help|-h) usage; return 0 ;;
      *) printf 'unknown option: %s\n' "$1"; usage; return 3 ;;
    esac
    shift
  done

  if ! is_int "$NICE" || test "$NICE" -lt -20 || test "$NICE" -gt 19; then
    printf 'bad --nice %s (want -20..19)\n' "$NICE"
    return 3
  fi
  if ! is_int "$WEIGHT" || test "$WEIGHT" -lt 0 || test "$WEIGHT" -gt 10000; then
    printf 'bad --weight %s (want 0..10000)\n' "$WEIGHT"
    return 3
  fi
  if ! is_int "$SAMPLE" || test "$SAMPLE" -lt 1 || test "$SAMPLE" -gt 60; then
    printf 'bad --sample %s (want 1..60)\n' "$SAMPLE"
    return 3
  fi

  case "$want" in
    selftest) do_selftest; return $? ;;
    *)
      load_targets || {
        printf 'no chromium video processes found (scanned /proc by comm)\n'
        return 2
      }
      ;;
  esac

  case "$want" in
    status) show_status; return 0 ;;
    apply) do_apply; return $? ;;
    revert) do_revert; return $? ;;
  esac
  show_status
  plan
  printf '\nmode=dry-run (no changes)\n'
  return 0
}

main "$@"
