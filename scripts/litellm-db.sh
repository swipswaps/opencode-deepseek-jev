#!/usr/bin/env bash
#
# litellm-db.sh — give the LiteLLM proxy a private Postgres so the admin UI
# can authenticate and budgets/spend are enforced.
#
# The proxy keeps its master key in .env.local. This script adds a dedicated
# DB credential file (docker/litellm-db.env, 0600, gitignored), writes the
# matching DATABASE_URL into .env.local, starts postgres + litellm, waits for
# both, and proves /v2/login accepts admin + LITELLM_MASTER_KEY.
#
# Usage:
#   ./scripts/litellm-db.sh            # apply + verify
#   ./scripts/litellm-db.sh --status   # read-only state + login check
#   ./scripts/litellm-db.sh --dry-run  # print the plan, change nothing
#
# Values are never printed. Exit 0 on success, 2 on failure.

SCRIPT_NAME="litellm-db.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="$REPO/.env.local"
DBENV="$REPO/docker/litellm-db.env"
COMPOSE_DIR="$REPO/docker"
COMPOSE_FILE="docker-compose.litellm.yml"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
MODE="apply"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--apply|--status|--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --apply    create/repair the DB, start postgres + litellm, verify login"
  printf '%s\n' "  --status   read-only: container health, proxy health, login status"
  printf '%s\n' "  --dry-run  print the plan without changing files or containers"
  printf '%s\n' ""
  printf '%s\n' "  WAIT_SECONDS=$WAIT_SECONDS CURL_TIMEOUT=$CURL_TIMEOUT"
  printf '%s\n' "  DB env: docker/litellm-db.env (0600, gitignored)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) MODE="apply" ;;
      --status) MODE="status" ;;
      --dry-run) MODE="dry-run" ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

read_env_value() {
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"
}

ensure_env_files() {
  [ -f "$ENVF" ] || die "missing $ENVF"
  have python3 || die "python3 required"
  local master
  master=$(read_env_value LITELLM_MASTER_KEY "$ENVF")
  [ -n "$master" ] || die "LITELLM_MASTER_KEY missing from $ENVF; run rotate-provider-keys.sh"
  local pw=""
  if [ -f "$DBENV" ]; then
    pw=$(read_env_value POSTGRES_PASSWORD "$DBENV")
  fi
  if [ -z "$pw" ]; then
    pw=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))') || die "password generation failed"
    umask 077
    printf '%s\n' \
      'POSTGRES_USER=litellm' \
      'POSTGRES_DB=litellm' \
      "POSTGRES_PASSWORD=$pw" > "$DBENV" || die "cannot write $DBENV"
    chmod 600 "$DBENV"
    pass "created $DBENV (0600)"
  else
    pass "reuse $DBENV (0600)"
  fi
  chmod 600 "$DBENV"
  local url="postgresql://litellm:${pw}@postgres:5432/litellm"
  python3 - "$ENVF" "$url" <<'PY'
import os, sys, tempfile
path, url = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
out, seen = [], False
for line in lines:
    if line.startswith("LITELLM_DATABASE_URL="):
        out.append("LITELLM_DATABASE_URL=" + url)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append("LITELLM_DATABASE_URL=" + url)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".env.", text=True)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
  [ "$?" -eq 0 ] || die "could not update $ENVF"
  pass "$ENVF has LITELLM_DATABASE_URL (0600)"
}

compose_up() {
  ( cd "$COMPOSE_DIR" && docker compose -f "$COMPOSE_FILE" up -d postgres ) \
    || die "docker compose up postgres failed"
  ( cd "$COMPOSE_DIR" && docker compose -f "$COMPOSE_FILE" up -d --force-recreate litellm ) \
    || die "docker compose up litellm failed"
  pass "compose started postgres + recreated litellm"
}

wait_db() {
  local i=0 status=""
  while [ "$i" -lt "$WAIT_SECONDS" ]; do
    status=$(docker inspect --format '{{.State.Health.Status}}' litellm-db 2>&1)
    printf '  db sample=%s elapsed=%ss status=%s\n' "$((i / 2 + 1))" "$i" "${status:-unknown}"
    [ "$status" = "healthy" ] && { pass "litellm-db healthy after ${i}s"; return 0; }
    i=$((i + 2))
    sleep 2
  done
  fail "litellm-db not healthy after ${WAIT_SECONDS}s (last=${status:-unknown})"
  docker logs litellm-db --tail 20 2>&1
  return 1
}

wait_proxy() {
  local i=0 code=""
  while [ "$i" -lt "$WAIT_SECONDS" ]; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
      http://127.0.0.1:4000/health/liveliness 2>&1)
    printf '  proxy sample=%s elapsed=%ss status=%s\n' "$((i / 2 + 1))" "$i" "${code:-unknown}"
    [ "$code" = "200" ] && { pass "litellm healthy after ${i}s"; return 0; }
    i=$((i + 2))
    sleep 2
  done
  fail "litellm not healthy after ${WAIT_SECONDS}s (last=${code:-unknown})"
  docker logs litellm --tail 30 2>&1
  return 1
}

login_check() {
  python3 - "$ENVF" "$CURL_TIMEOUT" <<'PY'
import json, sys, urllib.request, urllib.error
path = sys.argv[1]
timeout = float(sys.argv[2])
env = {}
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k] = v
master = env.get("LITELLM_MASTER_KEY", "")
body = json.dumps({"username": "admin", "password": master}).encode()
req = urllib.request.Request("http://127.0.0.1:4000/v2/login", data=body,
    headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        print("login_status", r.status)
        sys.exit(0 if r.status == 200 else 1)
except urllib.error.HTTPError as e:
    print("login_status", e.code)
    print(e.read(200).decode("utf-8", "replace"))
    sys.exit(1)
except Exception as e:
    print("login_status", type(e).__name__)
    sys.exit(1)
PY
}

models_check() {
  python3 - "$ENVF" "$CURL_TIMEOUT" <<'PY'
import sys, urllib.request, urllib.error
path = sys.argv[1]
timeout = float(sys.argv[2])
env = {}
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k] = v
req = urllib.request.Request("http://127.0.0.1:4000/v1/models",
    headers={"Authorization": "Bearer " + env.get("LITELLM_MASTER_KEY", "")})
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        print("models_status", r.status)
        sys.exit(0 if r.status == 200 else 1)
except urllib.error.HTTPError as e:
    print("models_status", e.code)
    print(e.read(200).decode("utf-8", "replace"))
    sys.exit(1)
except Exception as e:
    print("models_status", type(e).__name__)
    sys.exit(1)
PY
}

status_readonly() {
  docker ps --format '{{.Names}} | {{.Status}}' 2>&1 | grep -E '^(litellm|litellm-db) ' || log "containers: not running"
  printf 'db_health: '
  docker inspect --format '{{.State.Health.Status}}' litellm-db 2>&1 || true
  printf 'proxy: '
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time "$CURL_TIMEOUT" \
    http://127.0.0.1:4000/health/liveliness 2>&1
  login_check
  models_check
}

apply() {
  have docker || die "docker required"
  ensure_env_files
  compose_up
  wait_db || return 2
  wait_proxy || return 2
  login_check || { fail "admin login failed"; return 2; }
  models_check || { fail "/v1/models failed"; return 2; }
  pass "admin login + /v1/models"
  log ""
  log "UI: http://127.0.0.1:4000/ui"
  log "user: admin"
  log "password: the LITELLM_MASTER_KEY value in .env.local (never printed)"
  return 0
}

main() {
  parse_args "$@"
  if [ "$MODE" = "dry-run" ]; then
    log "[dry-run] ensure $DBENV (0600) and LITELLM_DATABASE_URL in .env.local"
    log "[dry-run] docker compose -f $COMPOSE_FILE up -d postgres litellm"
    log "[dry-run] wait for litellm-db healthy and /health/liveliness, then POST /v2/login"
    return 0
  fi
  if [ "$MODE" = "status" ]; then
    status_readonly
    return $?
  fi
  apply
}

main "$@"
exit $?
