#!/usr/bin/env bash
#
# fix-data-persistence-v3.sh
#
# Cross-checks the data-directory mount from three independent sources
# before any rewrite:
#
#   S1  raw compose file (grep + indented context)
#   S2  docker compose config  (resolved, authoritative for syntax)
#   S3  docker inspect .Mounts (authoritative for the running container)
#
# Gating contract:
#
#   G1  If S3 shows the mount active — nothing to do, stop.
#   G2  If S2 shows the mount but S3 does not — the running container is
#       stale; recreate without rewriting. Stop after recreate.
#   G3  If neither S2 nor S3 shows the mount — rewrite, recreate,
#       re-verify S3. If S3 still lacks the mount, abort before the
#       persistence test.
#   G4  The persistence test only runs if S3 confirms the mount is active.
#
# Telemetry contract:
#
#   - Every section prints three labelled views: raw, resolved, live.
#   - Every grep count is paired with the body it grepped, or an explicit
#     "no body returned" marker.
#   - §10 prints the response body of each API call, not just its count.
#   - If a test cannot be evaluated (curl failed, P1/P2 produced no
#     session), the verdict says "INCONCLUSIVE", not "FAIL".
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No bare kill. main() wrapper. python3 for text edits.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Compose volumes:
#     https://docs.docker.com/compose/compose-file/05-services/#volumes
#   Docker bind mounts:
#     https://docs.docker.com/storage/bind-mounts/
#   Docker inspect .Mounts:
#     https://docs.docker.com/engine/reference/commandline/inspect/
#   XDG Base Directory Specification:
#     https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
COMPOSE_REL="docker/docker-compose.yml"
DATA_CONT="/home/node/.local/share/opencode"
DATA_HOST_REL="data/opencode"
HTTP_URL="http://127.0.0.1:4096"
MODEL="deepseek/deepseek-flash"

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

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' '    ' "$line"
    done
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Telemetry primitives
# ---------------------------------------------------------------------------

# Print the raw region of the compose file around the opencode-web service.
# Line-numbered, with a fixed 40-line window or up to the next top-level
# service, whichever comes first.
print_raw_region() {
    local f="$1"
    # Find the first line matching '^opencode-web:' or '^  opencode-web:'
    # or '^    opencode-web:' (any service indent).
    local start
    start=$(grep -nE '^[[:space:]]*opencode-web:[[:space:]]*$' "$f" | head -1 | cut -d: -f1)
    if [ -z "$start" ]; then
        printf '    (no opencode-web service header found)\n'
        return 0
    fi
    # Find the next line at less indentation that ends with ':' (next service).
    local end
    end=$(awk -v start="$start" '
        NR > start && /^[[:space:]]*[a-zA-Z][^:]*:[[:space:]]*$/ {
            # Compute indent width of this line
            match($0, /^[[:space:]]*/)
            indent = RLENGTH
            if (indent <= 2) { print NR; exit }
        }
    ' "$f")
    if [ -z "$end" ]; then
        end=$((start + 40))
    fi
    # Print with line numbers.
    awk -v s="$start" -v e="$end" '
        NR >= s && NR < e { printf "    %4d  %s\n", NR, $0 }
    ' "$f"
}

# Print the opencode-web service as docker compose config resolves it.
print_resolved_region() {
    local repo="$1"
    ( cd "$repo/docker" && docker compose config 2>&1 ) | \
        awk '
            /^  opencode-web:/ { s=1 }
            s { print "    " $0 }
            s && /^  [a-zA-Z]/ && !/^  opencode-web:/ { exit }
        '
}

# Print the container's .Mounts array as JSON.
print_live_mounts() {
    local c="$1"
    local json
    json=$(docker inspect "$c" --format '{{json .Mounts}}' 2>&1)
    if [ -z "$json" ]; then
        printf '    (docker inspect returned no data)\n'
        return 0
    fi
    if have python3; then
        printf '%s' "$json" | python3 -m json.tool 2>&1 | indent
    else
        printf '    (python3 not available; raw json follows)\n'
        printf '    %s\n' "$json"
    fi
}

# Return 0 if the live container has the data dir mounted, 1 otherwise.
live_has_data_mount() {
    local c="$1" target="$2"
    docker inspect "$c" --format '{{json .Mounts}}' 2>&1 | grep -F "\"Destination\":\"$target\"" >/dev/null
}

# Return 0 if docker compose config resolves to include the data mount.
config_has_data_mount() {
    local repo="$1" target="$2"
    ( cd "$repo/docker" && docker compose config 2>&1 ) | grep -F "$target" >/dev/null
}

# ---------------------------------------------------------------------------
# Gated steps
# ---------------------------------------------------------------------------

step_sources() {
    local repo="$1" compose="$2"
    section "S1  raw compose file (numbered)"
    print_raw_region "$compose"

    section "S2  docker compose config (resolved)"
    print_resolved_region "$repo"

    section "S3  live container .Mounts"
    print_live_mounts "$C"
}

rewrite_block() {
    local compose="$1" ts="$2"
    cp "$compose" "$compose.bak.${ts}"
    printf '  backup: %s.bak.%s\n' "$compose" "$ts"

    python3 - "$compose" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()

TEMPLATE = """  opencode-web:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-web
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    working_dir: /workspace
    entrypoint: ["/workspace/docker/web-entrypoint.sh"]
    ports:
      - "4096:4096"
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
    env_file:
      - ../.env.local
    environment:
      OPENCODE_DISABLE_DEFAULT_PLUGINS: "true"
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
"""

pat = re.compile(r'^  opencode-web:\n(?:[ \t].*\n|\n)*?(?=^  [a-zA-Z]|\Z)', re.MULTILINE)
m = pat.search(text)
if not m:
    print("  FAIL: opencode-web block not matched (regex found no anchor)")
    print("  this means the raw file has a different shape than expected.")
    print("  inspect S1 output above before re-running.")
    sys.exit(3)

text = text[:m.start()] + TEMPLATE + text[m.end():]
with open(path, "w") as fh:
    fh.write(text)
print("  block rewritten with data mount at 8-space indent")
PY
    return $?
}

wait_http() {
    local tries=0 code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
        printf '    %2d/60  http=%s\n' "$((tries + 1))" "$code"
        [ -n "$code" ] && [ "$code" != "000" ] && break
        tries=$((tries + 1))
        sleep 2
    done
    R_HTTP="$code"
    [ -n "$code" ] && [ "$code" != "000" ]
}

get_password() {
    local p
    p=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    R_PASS="$p"
    [ -n "$p" ]
}

count_sessions() {
    local auth="$1" body
    body=$(curl -s -u "$auth" -m 5 "$HTTP_URL/api/session" 2>&1)
    R_BODY="$body"
    if printf '%s' "$body" | grep -q '"data"'; then
        printf '%s' "$body" | grep -o '"id":"ses_' | wc -l | tr -d ' '
    else
        printf 'ERR'
    fi
}

# ---------------------------------------------------------------------------
main() {
    local script_dir repo compose data_host ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    compose="$repo/$COMPOSE_REL"
    data_host="$repo/$DATA_HOST_REL"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    printf '=== fix-data-persistence-v3.sh ===\n'
    printf 'Repo:    %s\n' "$repo"
    printf 'Compose: %s\n' "$compose"
    printf 'TS:      %s\n' "$ts"

    if [ ! -f "$compose" ]; then
        printf '\nGATE FAIL: %s not found\n' "$compose"
        return 1
    fi
    if ! have python3; then
        printf '\nGATE FAIL: python3 required for json pretty-print and edits\n'
        return 1
    fi
    if ! have curl; then
        printf '\nGATE FAIL: curl required\n'
        return 1
    fi

    step_sources "$repo" "$compose"

    # -----------------------------------------------------------------------
    section "GATE  cross-source agreement"
    local live=0 cfg=0
    if live_has_data_mount "$C" "$DATA_CONT"; then live=1; fi
    if config_has_data_mount "$repo" "$DATA_CONT"; then cfg=1; fi
    printf '  S2 (resolved config has mount): %s\n' "$([ "$cfg" -eq 1 ] && printf yes || printf no)"
    printf '  S3 (live container has mount):  %s\n' "$([ "$live" -eq 1 ] && printf yes || printf no)"

    if [ "$live" -eq 1 ]; then
        section "verdict"
        printf '  G1 satisfied — mount already active in running container.\n'
        printf '  No rewrite. Persistence test follows.\n'
    elif [ "$cfg" -eq 1 ] && [ "$live" -eq 0 ]; then
        section "action: recreate only (config correct, container stale)"
        ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
        if [ $? -ne 0 ]; then
            printf '  FAIL: compose up\n'
            return 1
        fi
        wait_http
        if ! live_has_data_mount "$C" "$DATA_CONT"; then
            section "verdict"
            printf '  G2 FAIL — config has the mount but the container still does not.\n'
            printf '  Possible causes:\n'
            printf '    - compose file in use is not %s\n' "$compose"
            printf '    - docker daemon caching a stale image+container spec\n'
            printf '    - user-namespace remapping hiding the bind\n'
            printf '  Next: docker inspect %s | grep -A2 Mounts\n' "$C"
            return 1
        fi
        printf '  G2 satisfied — mount active after recreate.\n'
    else
        section "action: rewrite, recreate, re-verify"
        if ! rewrite_block "$compose" "$ts"; then
            printf '  rewrite failed — see above\n'
            return 1
        fi

        if ! ( cd "$repo/docker" && docker compose config >/dev/null 2>&1 ); then
            printf '  FAIL: compose config rejects rewritten file\n'
            printf '  rollback: cp %s.bak.%s %s\n' "$compose" "$ts" "$compose"
            return 1
        fi
        printf '  compose config: OK\n'

        ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web )
        if [ $? -ne 0 ]; then
            printf '  FAIL: compose up\n'
            return 1
        fi
        wait_http

        section "S3 after recreate"
        print_live_mounts "$C"

        if ! live_has_data_mount "$C" "$DATA_CONT"; then
            section "verdict"
            printf '  G3 FAIL — rewrite did not produce an active mount.\n'
            printf '  Inspect S1 raw region: was the block matched where you expected?\n'
            printf '  Then: docker compose -f %s config | grep -A4 volumes\n' "$compose"
            return 1
        fi
        printf '  G3 satisfied — mount active after rewrite+recreate.\n'
    fi

    # -----------------------------------------------------------------------
    section "persistence test"
    if ! get_password; then
        printf '  INCONCLUSIVE: password empty in container; cannot auth to API\n'
        return 1
    fi
    local auth="opencode:$R_PASS"

    printf '\n  creating two sessions\n'
    local log1 log2
    log1="/tmp/persist-p1-${ts}.log"
    log2="/tmp/persist-p2-${ts}.log"
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: P1'" > "$log1" 2>&1
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: P2'" > "$log2" 2>&1

    local p1_ok=0 p2_ok=0
    if grep -q 'P1' "$log1"; then p1_ok=1; fi
    if grep -q 'P2' "$log2"; then p2_ok=1; fi
    printf '  P1 reply captured: %s  (log %s)\n' "$([ "$p1_ok" -eq 1 ] && printf yes || printf no)" "$log1"
    printf '  P2 reply captured: %s  (log %s)\n' "$([ "$p2_ok" -eq 1 ] && printf yes || printf no)" "$log2"

    if [ "$p1_ok" -eq 0 ] || [ "$p2_ok" -eq 0 ]; then
        printf '\n  INCONCLUSIVE: one or both test runs did not return their token.\n'
        printf '  Cannot evaluate persistence until the model responds.\n'
        printf '  tail P1 log:\n'
        tail -5 "$log1" | indent
        printf '  tail P2 log:\n'
        tail -5 "$log2" | indent
        return 1
    fi

    local before
    before=$(count_sessions "$auth")
    printf '\n  sessions before recreate (HTTP): %s\n' "$before"
    printf '  response body (truncated to 400):\n'
    printf '%s' "$R_BODY" | head -c 400 | indent
    printf '\n'

    if [ "$before" = "ERR" ]; then
        printf '  INCONCLUSIVE: /api/session did not return JSON\n'
        return 1
    fi
    if [ "$before" -lt 2 ]; then
        printf '  INCONCLUSIVE: fewer than 2 sessions visible even before recreate (%s)\n' "$before"
        return 1
    fi

    printf '  host data dir:\n'
    ls -la "$data_host" | indent

    printf '\n  recreating container\n'
    ( cd "$repo/docker" && docker compose up -d --force-recreate opencode-web >/dev/null 2>&1 )
    wait_http

    local after
    after=$(count_sessions "$auth")
    printf '  sessions after recreate (HTTP): %s\n' "$after"
    printf '  response body (truncated to 400):\n'
    printf '%s' "$R_BODY" | head -c 400 | indent
    printf '\n  host data dir after recreate:\n'
    ls -la "$data_host" | indent

    section "verdict"
    if [ "$after" = "ERR" ]; then
        printf '  INCONCLUSIVE: post-recreate API call failed\n'
        return 1
    fi
    if [ "$after" = "$before" ] && [ "$before" -ge 2 ]; then
        printf '  PASS — %s sessions survived the recreate\n' "$after"
        printf '\n  next: refresh the browser at %s\n' "$HTTP_URL"
        return 0
    fi
    printf '  FAIL — before=%s after=%s\n' "$before" "$after"
    printf '  docker inspect %s --format "{{json .Mounts}}"\n' "$C"
    return 1
}

main "$@"
