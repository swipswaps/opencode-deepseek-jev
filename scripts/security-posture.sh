#!/usr/bin/env bash
#
# security-posture.sh — read-only gate for the residuals that are not a single
# command: host-home exposure, container capabilities, loopback-only LiteLLM,
# secret-file modes, artifact cleanliness, TLS, and the local red-team layer.
#
# This is a posture check, not a sandbox. A FAIL names the exact fix.
#
# Usage:
#   ./scripts/security-posture.sh
#   ./scripts/security-posture.sh --offline   # skip live docker/SubQ checks
#
# Exit 0 all pass, 1 a check failed, 2 usage/docker missing.

SCRIPT_NAME="security-posture.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="opencode-deepseek-web"
DB="litellm-db"
OFFLINE=0
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--offline]"
  printf '%s\n' ""
  printf '%s\n' "  --offline  skip live docker checks (compose/file checks only)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --offline) OFFLINE=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

compose_checks() {
  log "=== desired compose ==="
  local f="$REPO/docker/docker-compose.override.yml"
  if [ ! -f "$f" ]; then
    bad "missing $f"
    return
  fi
  if grep -qE '^[[:space:]]*-[[:space:]]*/home/owner:/home/owner' "$f"; then
    bad "override mounts the whole host home (/home/owner)"
  else
    ok "no whole-host-home mount in the override"
  fi
  if grep -qE '^[[:space:]]*-[[:space:]]*/home/owner/Documents/[^:]+:rw' "$f"; then
    bad "override has a read-write host Documents mount"
  else
    ok "no read-write host Documents mount in the override"
  fi
  if grep -q '/dev/null:/workspace/.env.local' "$f" \
    && grep -q '/dev/null:/workspace/docker/litellm-db.env' "$f" \
    && grep -q 'empty-certs:/workspace/docker/certs' "$f"; then
    ok "repo-mounted secrets hidden by empty binds"
  else
    bad "override does not hide repo-mounted secrets"
  fi
}

live_mounts() {
  log "=== live web mounts ==="
  local out
  out=$(docker inspect "$C" --format '{{json .Mounts}}' 2>&1 | python3 -c '
import json, sys
try: ms = json.load(sys.stdin)
except Exception as e: print("PARSE", e); raise SystemExit
issues = []
for m in ms:
    dst, src, rw = m.get("Destination", ""), m.get("Source", ""), m.get("RW", False)
    if dst == "/home/owner" or src == "/home/owner":
        issues.append("host home mounted at " + dst + " rw=" + str(rw))
    if dst.startswith("/home/owner/Documents/") and rw:
        issues.append("host Documents rw mount: " + dst)
    if dst == "/var/run/docker.sock":
        issues.append("docker socket mounted")
for i in issues: print("ISSUE", i)
' 2>&1)
  case "$out" in
    *"ISSUE"*) printf '%s\n' "$out" | awk '/^ISSUE/{print "        " $0}'; bad "live container has an over-broad mount (recreate web to apply the override)";;
    *PARSE*) printf '%s\n' "$out"; bad "could not inspect mounts";;
    *) ok "live web mounts are repo/config/notes only";;
  esac
}

repo_secrets() {
  log "=== repo-mounted secrets ==="
  if docker exec "$C" test -s /workspace/.env.local; then
    bad ".env.local is non-empty inside the web container (empty bind not applied; recreate web)"
  else
    ok ".env.local hidden from the web container"
  fi
  if docker exec "$C" test -s /workspace/docker/litellm-db.env; then
    bad "litellm-db.env is non-empty inside the web container (recreate web)"
  else
    ok "litellm-db.env hidden from the web container"
  fi
  local files
  files=$(docker exec "$C" sh -c 'find /workspace/docker/certs -type f 2>&1 | head -1')
  if [ -z "$files" ]; then
    ok "docker/certs hidden from the web container"
  else
    bad "docker/certs exposes a file inside the web container: $files (recreate web)"
  fi
}

container_hardening() {
  log "=== container hardening ==="
  local sec caps user
  sec=$(docker inspect "$C" --format '{{json .HostConfig.SecurityOpt}}' 2>&1)
  caps=$(docker inspect "$C" --format '{{json .HostConfig.CapDrop}}' 2>&1)
  user=$(docker inspect "$C" --format '{{.Config.User}}' 2>&1)
  case "$sec" in *no-new-privileges:true*) ok "no-new-privileges" ;; *) bad "no-new-privileges missing" ;; esac
  case "$caps" in *ALL*) ok "cap_drop ALL" ;; *) bad "cap_drop does not include ALL" ;; esac
  case "$user" in 0|root|"") bad "container runs as root (user=$user)" ;; *) ok "container runs as non-root ($user)" ;; esac
}

litellm_loopback() {
  log "=== LiteLLM exposure ==="
  local ui db
  ui=$(docker inspect litellm --format '{{json .NetworkSettings.Ports}}' 2>&1 | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("PARSE"); raise SystemExit
b = d.get("4000/tcp") or []
ok = any(x.get("HostIp") == "127.0.0.1" and x.get("HostPort") == "4000" for x in b)
print("OK" if ok else "BAD")
' 2>&1)
  db=$(docker inspect "$DB" --format '{{json .NetworkSettings.Ports}}' 2>&1 | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("PARSE"); raise SystemExit
print("PUBLISHED" if (d.get("5432/tcp") or []) else "OK")
' 2>&1)
  [ "$ui" = "OK" ] && ok "LiteLLM UI bound to 127.0.0.1:4000" || bad "LiteLLM UI is not loopback-only ($ui)"
  [ "$db" = "OK" ] && ok "Postgres is internal-only (no published 5432)" || bad "Postgres publishes 5432 ($db)"
}

file_modes() {
  log "=== secret-file modes ==="
  local f m
  for f in "$REPO/.env.local" "$REPO/docker/litellm-db.env"; do
    if [ -f "$f" ]; then
      m=$(stat -c %a "$f" 2>&1)
      [ "$m" = "600" ] && ok "$(basename "$f") mode 600" || bad "$(basename "$f") mode $m (want 600)"
    else
      bad "missing $f"
    fi
  done
  for f in "$REPO/docker/certs/opencode.key" "$REPO/docker/certs/ca.key"; do
    if [ -f "$f" ]; then
      m=$(stat -c %a "$f" 2>&1)
      case "$m" in 600|640) ok "$(basename "$f") mode $m" ;; *) bad "$(basename "$f") mode $m (want 600/640)" ;; esac
    else
      bad "missing $f"
    fi
  done
}

artifact_checks() {
  log "=== artifacts and TLS ==="
  if "$REPO/scripts/secret-scan.sh" --quiet 2>&1; then
    ok "secret-scan clean"
  else
    bad "secret-scan findings remain; run scrub-secrets.sh"
  fi
  if [ -x "$REPO/scripts/rotate-tls.sh" ]; then
    if "$REPO/scripts/rotate-tls.sh" --check >/dev/null 2>&1; then
      ok "live TLS key not in snapshots; served fingerprint matches"
    else
      bad "TLS check failed; run rotate-tls.sh --check for the evidence"
    fi
  else
    bad "rotate-tls.sh missing"
  fi
}

hardening_checks() {
  log "=== 2026-11-10 hardening invariants ==="
  local f
  f="$REPO/scripts/dashboard.mjs"
  if grep -q 'function authOk' "$f" && grep -q 'if (!authOk(req))' "$f"; then
    ok "dashboard authenticates every route when OPENCODE_SERVER_PASSWORD is set"
  else
    bad "dashboard auth gate missing (see docs/SECURITY-AUDIT-2026-11-10.md V1)"
  fi
  if grep -q 'DASH_ALLOW_ORIGIN' "$f" && ! grep -q '"https://swipswaps.github.io"' "$f"; then
    ok "dashboard CORS is opt-in (no hardcoded public origin)"
  else
    bad "dashboard still grants a hardcoded public CORS origin"
  fi
  if grep -q "script-src 'self' 'nonce-" "$f" && ! grep -q "script-src 'self' 'unsafe-inline'" "$f"; then
    ok "dashboard CSP uses a per-response nonce (no unsafe-inline scripts)"
  else
    bad "dashboard CSP still allows unsafe-inline scripts"
  fi
  if grep -q 'RESTRICT="${RESTRICT:-1}"' "$REPO/scripts/authorize-container-key.sh"; then
    ok "container key defaults to OpenSSH restrict"
  else
    bad "container key authorization still defaults to unrestricted"
  fi
  if grep -q '127.0.0.1:${DOCKGE_PORT}:5001' "$REPO/scripts/deploy-dockge.sh" \
    && grep -q '127.0.0.1:5001:5001' "$REPO/scripts/flatten-dockge-stacks.sh"; then
    ok "Dockge publishes on loopback only"
  else
    bad "Dockge still publishes on all interfaces (root-equivalent socket)"
  fi
  if grep -q 'OPENCODE_SEMANTIC_GUARD === "on"' "$REPO/.opencode/plugins/blacklist-guard.js"; then
    ok "semantic classifier is opt-in (no command text sent by default)"
  else
    bad "semantic classifier is not opt-in"
  fi
  if grep -q 'def redact' "$REPO/scripts/guard-classify.py"; then
    ok "classifier redacts secret shapes before upload"
  else
    bad "classifier uploads command text without redaction"
  fi
  if grep -q 'trusted="${X11_TRUSTED:-0}"' "$REPO/scripts/ssh-x11-setup.sh" \
    && grep -q 'trusted="${4:-0}"' "$REPO/scripts/ssh-x11-setup.sh"; then
    ok "X11 forwarding defaults to untrusted (trusted is opt-in)"
  else
    bad "X11 forwarding still defaults to trusted"
  fi
  if grep -q 'head -c 200' "$REPO/scripts/rotate-api-keys.sh"; then
    bad "rotate-api-keys.sh prints auth.json bytes"
  else
    ok "rotate-api-keys.sh prints provider names, not key bytes"
  fi
  if grep -q 'chmodSync(file, 0o600)' "$REPO/docker/web-entrypoint.sh"; then
    ok "auth.json is written mode 0600"
  else
    bad "auth.json is not forced to mode 0600"
  fi
  if grep -q 'file:// is blocked by default' "$REPO/scripts/harvest.py"; then
    ok "harvest.py blocks file:// and private/loopback targets by default"
  else
    bad "harvest.py does not block file:// / private targets"
  fi
  if [ -x "$REPO/scripts/install-global-guard.sh" ]; then
    if "$REPO/scripts/install-global-guard.sh" --check >/dev/null 2>&1; then
      ok "global blacklist-guard link is not dangling"
    else
      bad "global blacklist-guard link is dangling (run install-global-guard.sh --install)"
    fi
  else
    bad "install-global-guard.sh missing"
  fi
  if grep -q 'CRITICAL_TIMEOUT' "$REPO/scripts/hotspot-reconnect.sh" \
    && ! grep -q 'timeout=0; else' "$REPO/scripts/hotspot-reconnect.sh"; then
    ok "hotspot notifications are bounded and replaceable (no -t 0)"
  else
    bad "hotspot notifications can persist forever (timeout=0)"
  fi
}

local_redteam() {
  log "=== local red-team layer ==="
  if [ -x "$REPO/scripts/red-team.sh" ]; then
    if "$REPO/scripts/red-team.sh" --offline >/dev/null 2>&1; then
      ok "red-team offline (blacklist + env rules)"
    else
      bad "red-team offline failed"
    fi
  else
    bad "red-team.sh missing"
  fi
}

main() {
  parse_args "$@"
  compose_checks
  file_modes
  artifact_checks
  hardening_checks
  local_redteam
  if [ "$OFFLINE" -eq 0 ]; then
    have docker || die "docker missing (use --offline for compose/file checks)"
    live_mounts
    repo_secrets
    container_hardening
    litellm_loopback
  else
    log "=== live checks skipped (--offline) ==="
  fi
  log ""
  log "summary: pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
exit $?
