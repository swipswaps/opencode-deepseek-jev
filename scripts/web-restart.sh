#!/usr/bin/env bash
#
# web-restart.sh — restart the observability dashboard so :5099 serves the
# current checkout, then verify the served revision matches HEAD.
#
# Why this script exists: `opencode-web` is a compose SERVICE name, not a
# command — typing it bare at a shell prints "command not found". This
# wrapper is the command. Run it from anywhere inside the repo checkout:
#
#   ./scripts/web-restart.sh
#   ./scripts/web-restart.sh --self-test
#
# Three modes:
#   docker present        -> `docker compose restart opencode-web` (the host path)
#   --recreate            -> `docker compose up -d --force-recreate opencode-web`
#                            (REQUIRED after .env.local or compose changes:
#                            restart keeps the container's original environment)
#   docker absent         -> restart the local `dashboard.mjs` process (the
#                            sandbox path; this is why :5099 goes STALE after
#                            every commit here — nothing was restarting it)
#
# Two failure modes this script now closes instead of leaving to the operator:
#   * compose's TTY progress UI emits cursor-move/colour escapes that leak into
#     the shell after the prompt returns. Force plain, no-ANSI output.
#   * `restart` returns when compose says "running", NOT when opencode has
#     loaded the guard (~30s later). A guard-health run in that window reports a
#     false "loaded hash differs". Wait for the `loaded` marker with the current
#     plugin sha before declaring success.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# ============================================================================

set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

rev_json() {
    # Print "served stale=" from :5099. HTTPS first (caddy on the host), then
    # plain HTTP (the sandbox binds :5099 without TLS). Empty when unreachable.
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("served","?"))+" stale="+str(d.get("stale","?")))
except Exception:
    pass'
}

dash_password() {
    local p="${OPENCODE_SERVER_PASSWORD:-}"
    if [ -z "$p" ] && [ -f "$REPO_DIR/.env.local" ]; then
        p=$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENCODE_SERVER_PASSWORD=' "$REPO_DIR/.env.local" | tail -n 1)
        p=${p#*=}
        p=${p%$'\r'}
        p=${p%\"}; p=${p#\"}
        p=${p%\'}; p=${p#\'}
    fi
    printf '%s' "$p"
}

dash_curl() {
    local url="$1" pass esc
    pass=$(dash_password)
    if [ -z "$pass" ]; then
        curl -k -s --max-time 8 "$url"
        return
    fi
    esc=${pass//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf 'user = "opencode:%s"\n' "$esc" | curl -k -s --max-time 8 --config - "$url"
}

probe_rev() {
    local out
    out=$(dash_curl https://127.0.0.1:5099/api/rev | rev_json)
    [ -n "$out" ] || out=$(dash_curl http://127.0.0.1:5099/api/rev | rev_json)
    printf '%s' "$out"
}

dashboard_pids() {
    # ALL dashboard.mjs processes on :5099, space-separated (may be several after
    # a raced restart — killing one left another holding the port).
    local p cl out=""
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cl=$(tr '\0' ' ' < "$p/cmdline" 2>&1)
        case "$cl" in
            *dashboard.mjs*5099*) out="$out $(basename "$p")" ;;
        esac
    done
    printf '%s' "${out# }"
}

plugin_sha() {
    sha256sum "$REPO_DIR/.opencode/plugins/blacklist-guard.js" | awk '{print $1}'
}

# Print the log whose newest "loaded" marker carries $1, or nothing. The guard
# is loaded from the repo file or the global copy, and an older build anchored
# its log to the copy; check both so a healthy load is found either way.
guard_loaded_log() {
    local want="$1" log
    for log in "$REPO_DIR/data/observability/guard.log" \
               "${XDG_CONFIG_HOME:-$HOME/.config}/data/observability/guard.log" \
               "/home/node/.config/data/observability/guard.log"; do
        [ -f "$log" ] || continue
        if grep '"verdict":"loaded"' "$log" | tail -1 | grep -q "$want"; then
            printf '%s' "$log"
            return 0
        fi
    done
    return 1
}

self_test() {
    printf '=== web-restart.sh --self-test ===\n'
    local tmp fails=0 want hit miss log
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/webrestart.XXXXXX" 2>&1) || { printf 'FAIL mktemp\n'; return 2; }
    want="abc123def456"
    mkdir -p "$tmp/data/observability"
    printf '{"verdict":"loaded","sha":"%s"}\n' "$want" > "$tmp/data/observability/guard.log"
    REPO_DIR="$tmp"
    log=$(guard_loaded_log "$want") && [ "$log" = "$tmp/data/observability/guard.log" ] && hit=1 || hit=0
    miss=0
    if guard_loaded_log "000000000000" > /dev/null; then miss=1; fi
    [ "$hit" -eq 1 ] && printf '  PASS found a matching loaded marker\n' || { fails=$((fails + 1)); printf '  FAIL matching marker not found\n'; }
    [ "$miss" -eq 0 ] && printf '  PASS rejects a stale/mismatched sha\n' || { fails=$((fails + 1)); printf '  FAIL accepted a mismatched sha\n'; }
    if printf '{"verdict":"loaded","sha":"%s"}\n' "$want" | grep -q "$want"; then
        printf '  PASS sha compare works on the real log shape\n'
    else
        fails=$((fails + 1)); printf '  FAIL sha compare on the real log shape\n'
    fi
    local stripped
    stripped=$(printf '\033[35;59;1Mok\033[0m\r\n' | strip_ansi)
    if [ "$stripped" = "ok" ]; then
        printf '  PASS strip_ansi removes the 35;59;1M residue\n'
    else
        fails=$((fails + 1)); printf '  FAIL strip_ansi left: %s\n' "$stripped"
    fi
    if [ "$(printf 'plain line\n' | strip_ansi)" = "plain line" ]; then
        printf '  PASS strip_ansi keeps plain output\n'
    else
        fails=$((fails + 1)); printf '  FAIL strip_ansi altered plain output\n'
    fi
    find "$tmp" -depth -delete 2>&1
    printf 'result: %s\n' "$([ "$fails" -eq 0 ] && printf PASS || printf FAIL)"
    [ "$fails" -eq 0 ] && return 0 || return 1
}

# Never let a TTY progress renderer write bytes to the operator's terminal.
# Compose's interactive UI uses cursor-move/colour escapes (the `35;59;1M…`
# residue). Run it with output redirected to a file — no TTY, so it falls back
# to plain — then print an ANSI-stripped copy as a belt-and-suspenders.
strip_ansi() {
    python3 -c 'import re,sys
for line in sys.stdin:
    line = re.sub("\x1b\\[[0-9;?]*[ -/]*[@-~]", "", line)
    line = re.sub("\x1b\\][^\x07]*\x07", "", line)
    line = line.replace("\r", "")
    sys.stdout.write(line)'
}

run_compose() {
    local out rc
    out=$(mktemp) || return 1
    COMPOSE_PROGRESS=plain COMPOSE_ANSI=never docker compose "$@" > "$out" 2>&1
    rc=$?
    strip_ansi < "$out"
    rm -f "$out"
    return "$rc"
}

# `docker compose restart` returns when compose says "running", not when the
# guard has been imported (~30s later). A guard-health run in that window is a
# false FAIL. Poll for the loaded marker carrying the CURRENT plugin sha.
wait_guard() {
    local want log i=0 iters="${WEB_RESTART_GUARD_ITERS:-24}"
    case "$iters" in '' | *[!0-9]*) iters=24 ;; esac
    want=$(plugin_sha)
    if [ -z "$want" ]; then
        printf 'WARN: cannot hash the plugin; cannot verify the guard load\n'
        return 1
    fi
    while [ "$i" -lt "$iters" ]; do
        if log=$(guard_loaded_log "$want"); then
            printf 'PASS: guard loaded (%s…) from %s\n' "${want:0:12}" "$log"
            return 0
        fi
        i=$((i + 1))
        sleep 5
    done
    printf 'FAIL: guard did not register %s within %ss; serving without it is the #98 outage\n' \
        "${want:0:12}" "$((iters * 5))"
    printf 'hint: docker logs --tail 40 opencode-deepseek-web (look for blacklist-guard)\n'
    return 1
}

main() {
    local MODE="restart"
    case "${1:-}" in
        --recreate) MODE="recreate" ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) printf 'usage: %s [--recreate|--self-test]\n' "$0"; return 0 ;;
        "") ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    printf '=== web-restart.sh ===\n'
    local head
    head=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>&1) || head="unknown"
    printf 'HEAD: %s\n' "$head"

    if have docker; then
        if [ "$MODE" = "recreate" ]; then
            printf 'mode: docker compose up -d --force-recreate opencode-web\n'
            ( cd "$REPO_DIR/docker" && run_compose up -d --force-recreate opencode-web ) || {
                printf 'FAIL: docker compose up --force-recreate failed\n'
                printf 'hint: is the docker daemon reachable? try: docker ps\n'
                return 1
            }
        else
            printf 'mode: docker compose restart opencode-web\n'
            ( cd "$REPO_DIR/docker" && run_compose restart opencode-web ) || {
                printf 'FAIL: docker compose restart failed\n'
                printf 'hint: is the docker daemon reachable? try: docker ps\n'
                return 1
            }
            # restart keeps the container's ORIGINAL environment; warn when the
            # env file is newer, because the change silently did not apply.
            local created envm ce
            created=$(docker inspect -f '{{.Created}}' opencode-deepseek-web 2>&1)
            envm=$(stat -c %Y "$REPO_DIR/.env.local" 2>&1)
            ce=$(date -d "$created" +%s 2>&1)
            case "$ce" in ""|*[!0-9]*) ;; *)
                case "$envm" in ""|*[!0-9]*) ;; *)
                    if [ "$envm" -gt "$ce" ]; then
                        printf 'WARN: .env.local is newer than the container; restart does NOT reload env_file.\n'
                        printf '      re-run: %s --recreate\n' "$0"
                    fi
                    ;;
                esac
                ;;
            esac
        fi
    else
        printf 'mode: dockerless (local dashboard.mjs process)\n'
        local pids first args pid k
        pids=$(dashboard_pids)
        [ -n "$pids" ] || { printf 'FAIL: no dashboard.mjs process and docker absent\n'; return 1; }
        first=$(printf '%s' "$pids" | awk '{print $1}')
        args=$(tr '\0' ' ' < "/proc/$first/cmdline")   # read BEFORE killing
        printf 'stopping dashboard pid(s): %s\n' "$pids"
        for pid in $pids; do kill -TERM "$pid"; done
        k=0
        while [ "$k" -lt 10 ] && [ -n "$(dashboard_pids)" ]; do sleep 1; k=$((k + 1)); done
        [ -z "$(dashboard_pids)" ] || printf 'WARN: dashboard pid(s) remain: %s\n' "$(dashboard_pids)"
        printf 'relaunching one dashboard\n'
        # shellcheck disable=SC2086
        setsid $args > /tmp/dashboard.log 2>&1 < /dev/null &
    fi

    printf 'restart issued; waiting for :5099 (boot + health pre-warm)\n'
    local i served
    local iters="${WEB_RESTART_ITERS:-24}"
    case "$iters" in '' | *[!0-9]*) iters=24 ;; esac
    i=1
    while [ "$i" -le "$iters" ]; do
        sleep 5
        served=$(probe_rev)
        if [ -n "$served" ]; then
            printf 'rev: %s (HEAD %s)\n' "$served" "$head"
            case "$served" in
                "$head"*stale=False*)
                    printf 'PASS: :5099 serves current checkout\n'
                    wait_guard || return 1
                    return 0 ;;
            esac
        fi
        i=$((i + 1))
    done
    printf 'FAIL: :5099 did not serve %s within %ss (last: %s)\n' "$head" "$((iters * 5))" "$served"
    printf 'hint: docker logs --tail 20 opencode-deepseek-web (https probe; http:// -> 400 by design)\n'
    return 1
}

main "$@"
