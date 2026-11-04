#!/usr/bin/env bash
#
# rotate-tls.sh — reissue the caddy server key/cert with the SAME local CA,
# restart caddy, and prove the served fingerprint matches the new file.
#
# The CA is unchanged, so clients that trust it keep working; only the leaf
# key/cert changes. --check also reports whether the live key matches a leaked
# snapshot (the F1 finding).
#
# Usage:
#   ./scripts/rotate-tls.sh --check
#   ./scripts/rotate-tls.sh --apply --yes
#   ./scripts/rotate-tls.sh --dry-run
#
# Values/keys are never printed. Exit 0 ok, 1 check failed, 2 usage/error.

SCRIPT_NAME="rotate-tls.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${CERT_DIR:-$REPO/docker/certs}"
CRT="$CERT_DIR/opencode.crt"
KEY="$CERT_DIR/opencode.key"
CA="$CERT_DIR/ca.crt"
CERT_EXTRA_SANS="${CERT_EXTRA_SANS:-IP:192.168.4.24}"
MODE="check"
YES=0
C="opencode-caddy"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--check|--apply|--dry-run] [--yes]"
  printf '%s\n' ""
  printf '%s\n' "  --check    print cert facts, compare live key to leaked snapshots,"
  printf '%s\n' "             and compare the served fingerprint with the file"
  printf '%s\n' "  --apply    reissue the leaf key/cert with the same CA and restart caddy"
  printf '%s\n' "  --dry-run  print the plan"
  printf '%s\n' "  --yes      confirm --apply"
  printf '%s\n' "  CERT_EXTRA_SANS=$CERT_EXTRA_SANS"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) MODE="check" ;;
      --apply) MODE="apply" ;;
      --dry-run) MODE="dry-run" ;;
      --yes) YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

file_fp() {
  openssl x509 -in "$CRT" -noout -fingerprint -sha256 2>&1 | awk -F= '{print $2}'
}

served_fp() {
  local port="$1"
  printf '' | openssl s_client -connect "127.0.0.1:$port" -servername 192.168.4.24 2>&1 \
    | openssl x509 -noout -fingerprint -sha256 2>&1 | awk -F= '{print $2}'
}

leak_check() {
  local found=0 snap
  while IFS= read -r snap; do
    [ -f "$snap" ] || continue
    if cmp -s "$KEY" "$snap"; then
      log "leak: live key matches ${snap#$REPO/}"
      found=1
    fi
  done < <(find "$REPO/data/observability/snapshots" -type f -name 'opencode.key' 2>&1)
  if [ "$found" -eq 1 ]; then
    fail "live TLS key matches a leaked snapshot; run --apply --yes"
    return 1
  fi
  pass "live TLS key does not match a leaked snapshot"
}

check() {
  [ -f "$CRT" ] || { fail "missing $CRT"; return 1; }
  [ -f "$KEY" ] || { fail "missing $KEY"; return 1; }
  log "file_fingerprint: $(file_fp)"
  log "not_before/after: $(openssl x509 -in "$CRT" -noout -dates 2>&1 | tr '\n' ' ')"
  log "sans: $(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>&1 | tail -1)"
  local rc=0
  if [ -f "$CA" ]; then
    if openssl verify -CAfile "$CA" "$CRT" >/dev/null 2>&1; then
      pass "chain verifies with $CA"
    else
      fail "chain does not verify with $CA"
      rc=1
    fi
  else
    fail "missing CA at $CA"
    rc=1
  fi
  leak_check || rc=1
  local fp f1 f2
  fp=$(file_fp)
  f1=$(served_fp 4096)
  f2=$(served_fp 5099)
  log "served_4096: $f1"
  log "served_5099: $f2"
  [ "$fp" = "$f1" ] || { fail "served :4096 differs from file"; rc=1; }
  [ "$fp" = "$f2" ] || { fail "served :5099 differs from file"; rc=1; }
  [ "$rc" -eq 0 ] && pass "served TLS matches the file"
  return "$rc"
}

apply() {
  [ "$YES" -eq 1 ] || die "--apply requires --yes"
  have openssl || die "openssl missing"
  have docker || die "docker missing"
  log "reissuing leaf with same CA (extra SAN: $CERT_EXTRA_SANS)"
  CERT_EXTRA_SANS="$CERT_EXTRA_SANS" "$REPO/docker/certs-init.sh" --rotate || die "certs-init --rotate failed"
  pass "new leaf key/cert written"
  docker restart "$C" || die "could not restart $C"
  pass "restarted $C"
  local i=0 f1="" f2="" fp
  fp=$(file_fp)
  while [ "$i" -lt 30 ]; do
    f1=$(served_fp 4096)
    f2=$(served_fp 5099)
    printf '  tls sample=%s elapsed=%ss served_4096=%s served_5099=%s\n' "$((i / 2 + 1))" "$i" "${f1:-none}" "${f2:-none}"
    if [ "$fp" = "$f1" ] && [ "$fp" = "$f2" ]; then
      pass "caddy serves the new fingerprint on both ports"
      leak_check || return 1
      return 0
    fi
    i=$((i + 2))
    sleep 2
  done
  fail "caddy did not serve the new fingerprint within 30s (file=$fp)"
  return 1
}

main() {
  parse_args "$@"
  case "$MODE" in
    check) check ;;
    apply) apply ;;
    dry-run)
      log "[dry-run] CERT_EXTRA_SANS=$CERT_EXTRA_SANS docker/certs-init.sh --rotate"
      log "[dry-run] docker restart $C"
      log "[dry-run] verify served fingerprint on :4096 and :5099"
      ;;
  esac
}

main "$@"
exit $?
