#!/usr/bin/env bash
#
# scrub-secrets.sh — remove secret-shaped values from historical artifacts
# after the credentials have been rotated.
#
# Rotation makes a leaked value worthless; the artifact still holds it, so a
# later transcript/export can re-disclose it. This script:
#   - redacts text logs in place with scripts/redact.mjs (atomic, mode kept)
#   - optionally purges snapshot dirs that contain a private key or yaml secret
#   - optionally removes .env.local.bak.* files (old/new key copies)
#   - reports whether the LIVE TLS key matches a leaked snapshot
#
# Default is a dry run. Writes require --apply --yes.
#
# Usage:
#   ./scripts/scrub-secrets.sh
#   ./scripts/scrub-secrets.sh --apply --yes
#   ./scripts/scrub-secrets.sh --apply --yes --purge-snapshots --purge-env-backups
#   ./scripts/scrub-secrets.sh --check-tls
#
# Values are never printed. Exit 0 clean/applied, 1 findings remain, 2 usage.

SCRIPT_NAME="scrub-secrets.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0
YES=0
PURGE_SNAPSHOTS=0
PURGE_ENV_BACKUPS=0
CHECK_TLS=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--apply --yes] [--purge-snapshots] [--purge-env-backups] [--check-tls]"
  printf '%s\n' ""
  printf '%s\n' "  --apply             rewrite text artifacts (requires --yes)"
  printf '%s\n' "  --yes               confirm writes/purges"
  printf '%s\n' "  --purge-snapshots   delete snapshot dirs containing private keys/secrets"
  printf '%s\n' "  --purge-env-backups delete .env.local.bak.*"
  printf '%s\n' "  --check-tls         compare the live TLS key with leaked snapshots"
  printf '%s\n' "  --help              this text"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1 ;;
      --yes) YES=1 ;;
      --purge-snapshots) PURGE_SNAPSHOTS=1 ;;
      --purge-env-backups) PURGE_ENV_BACKUPS=1 ;;
      --check-tls) CHECK_TLS=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

scan_json() {
  "$REPO/scripts/secret-scan.sh" --paths "$REPO/logs $REPO/data/observability" --json 2>&1
}

redact_file() {
  local f="$1" tmp
  tmp=$(mktemp "$(dirname "$f")/.scrub.XXXXXX") || return 1
  if node "$REPO/scripts/redact.mjs" < "$f" > "$tmp"; then
    chmod --reference="$f" "$tmp" 2>&1 || chmod 600 "$tmp"
    mv "$tmp" "$f"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

purge_dir() {
  local d="$1"
  find "$d" -type f -delete 2>&1 || true
  find "$d" -depth -type d -empty -delete 2>&1 || true
}

check_tls() {
  local live="$REPO/docker/certs/opencode.key" found=0 snap
  [ -f "$live" ] || { log "tls: no live key at $live"; return 0; }
  while IFS= read -r snap; do
    [ -f "$snap" ] || continue
    if cmp -s "$live" "$snap"; then
      log "tls: LIVE key matches leaked snapshot: ${snap#$REPO/}"
      found=1
    fi
  done < <(find "$REPO/data/observability/snapshots" -type f -name 'opencode.key' 2>&1)
  if [ "$found" -eq 1 ]; then
    fail "live TLS key matches a snapshot; rotate the cert pair before trusting it"
    return 1
  fi
  pass "live TLS key does not match a leaked snapshot"
}

main() {
  parse_args "$@"
  [ -x "$REPO/scripts/secret-scan.sh" ] || die "secret-scan.sh missing"
  [ -f "$REPO/scripts/redact.mjs" ] || die "redact.mjs missing"

  local json files
  json=$(scan_json)
  printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 \
    || die "secret-scan returned invalid JSON"
  files=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("\n".join(sorted({f["file"] for f in d.get("findings", [])})))
' 2>&1)
  local count
  count=$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("findings", [])))' 2>&1)
  log "findings=$count files=$(printf '%s\n' "$files" | grep -c .)"
  if [ "$count" -eq 0 ]; then
    pass "no secret-shaped values in logs/ or data/observability/"
    [ "$CHECK_TLS" -eq 1 ] && check_tls
    return 0
  fi

  local f kind private_files="" text_files=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind=$(printf '%s' "$json" | python3 -c '
import json, sys
f = sys.argv[1]
d = json.load(sys.stdin)
ks = sorted({x["kind"] for x in d.get("findings", []) if x["file"] == f})
print(",".join(ks))
' "$f" 2>&1)
    case ",$kind," in
      *,private_key,*) private_files="$private_files$f\n" ;;
      *) text_files="$text_files$f\n" ;;
    esac
    printf '  %s [%s]\n' "${f#$REPO/}" "$kind"
  done <<EOF
$files
EOF

  local tls_rc=0
  if [ "$CHECK_TLS" -eq 1 ]; then
    check_tls
    tls_rc=$?
  fi

  if [ "$APPLY" -eq 0 ]; then
    log "dry run: pass --apply --yes to redact text artifacts"
    [ "$PURGE_SNAPSHOTS" -eq 1 ] && log "dry run: --purge-snapshots would delete ${private_files:-no private-key files}"
    [ "$PURGE_ENV_BACKUPS" -eq 1 ] && log "dry run: --purge-env-backups would delete .env.local.bak.*"
    [ "$tls_rc" -eq 0 ] || return 1
    return 1
  fi

  [ "$YES" -eq 1 ] || die "writes require --yes"

  local changed=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if redact_file "$f"; then
      changed=$((changed + 1))
    else
      err "could not redact $f"
    fi
  done <<EOF
$(printf '%b' "$text_files")
EOF
  pass "redacted $changed text artifact(s)"

  if [ "$PURGE_SNAPSHOTS" -eq 1 ]; then
    local d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      d=$(dirname "$f")
      case "$d" in
        "$REPO"/data/observability/snapshots/*)
          case "$d" in
            *" "*|*$'\n'*) err "skip suspicious snapshot path: $d" ;;
            *) log "purge $d"; purge_dir "$d" ;;
          esac
          ;;
      esac
    done <<EOF
$(printf '%b' "$private_files")
EOF
    pass "purged secret-bearing snapshot dirs"
  fi

  if [ "$PURGE_ENV_BACKUPS" -eq 1 ]; then
    local n=0 b
    while IFS= read -r b; do
      [ -f "$b" ] || continue
      rm -f "$b" && n=$((n + 1))
    done < <(find "$REPO" -maxdepth 1 -type f -name '.env.local.bak.*' 2>&1)
    pass "removed $n .env.local.bak.* file(s)"
  fi

  local remaining
  remaining=$(scan_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("findings", [])))' 2>&1)
  if [ "$remaining" -eq 0 ] && [ "$tls_rc" -eq 0 ]; then
    pass "post-scrub scan clean"
    return 0
  fi
  [ "$tls_rc" -eq 0 ] || fail "live TLS key matched a leaked snapshot; rotate the cert pair"
  [ "$remaining" -eq 0 ] || fail "post-scrub findings remain: $remaining (private-key snapshots need --purge-snapshots)"
  return 1
}

main "$@"
exit $?
