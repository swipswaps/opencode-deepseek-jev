#!/usr/bin/env bash
#
# laya-wire.sh — find a running Laya server and point jev-guard at it.
#
# Laya speaks the same POST /v1/systemone wire protocol as Jev, and jev-guard
# honors JEV_BASE_URL (takes precedence over every Jev key). This script does
# NOT install Laya: it probes the docker bridge gateway, loopback, and the two
# host addresses, then (with --wire) writes the env and restarts the web
# container. A loopback-only server is rejected: the container cannot reach the
# host's 127.0.0.1, so the URL must be the bridge gateway or a LAN address.
#
#   ./scripts/laya-wire.sh                 # probe only
#   ./scripts/laya-wire.sh --wire          # probe, write env, restart, verify
#   ./scripts/laya-wire.sh --url http://172.18.0.1:8000 --wire
#   ./scripts/laya-wire.sh --url ... --key "$LAYA_KEY" --wire   # 401 servers
#   ./scripts/laya-wire.sh --json
#   ./scripts/laya-wire.sh --self-test     # offline: env rewrite + classify
#
# Host-only (needs docker). Exit 0 found/wired, 1 not found/no change, 2 error.
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. printf only.
#
set -o pipefail

C="opencode-deepseek-web"
PAYLOAD='{"state":"ping","model":"english","questions":[]}'
TIMEOUT=2000

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

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$1"; }

classify() {
    case "$1" in
        200|400|422) printf 'up' ;;
        401)         printf 'auth' ;;
        *)           printf 'down' ;;
    esac
}

valid_gw() {
    case "$1" in
        ""|*[!0-9.]*) return 1 ;;
    esac
    return 0
}

gws() {
    # A container can be on several networks; the template MUST separate names
    # (the missing space produced "docker_defaultlitellm_default"). Print every
    # valid gateway, and never leak a docker error as if it were an IP.
    local nets net out
    nets=$(docker inspect "$C" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>&1) || return 1
    for net in $nets; do
        out=$(docker network inspect "$net" -f '{{(index .IPAM.Config 0).Gateway}}' 2>&1) || continue
        if valid_gw "$out"; then printf '%s\n' "$out"; fi
    done
}

probe() {
    # probe URL [KEY] -> http code (000 on failure)
    local u="$1" key="$2" args
    args=(-s -m 3 -o /dev/null -w '%{http_code}' -X POST "${u%/}/v1/systemone"
          -H 'content-type: application/json' -d "$PAYLOAD")
    [ -n "$key" ] && args+=(-H "Authorization: Bearer $key")
    curl "${args[@]}" 2>&1
}

write_env() {
    # write_env ENVFILE URL [KEY] — idempotent, preserves other lines, 0600.
    python3 - "$1" "$2" "${3:-}" "${4:-2000}" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); url = sys.argv[2].rstrip("/"); key = sys.argv[3]
want = {"JEV_BASE_URL": url, "JEV_GUARD_TIMEOUT_MS": (sys.argv[4] or "2000"), "JEV_MODEL": "english"}
if key:
    want["JEV_BASE_API_KEY"] = key
lines = p.read_text().splitlines() if p.exists() else []
out, seen = [], set()
for ln in lines:
    k = ln.split("=", 1)[0] if ("=" in ln and not ln.lstrip().startswith("#")) else None
    if k in want:
        out.append(k + "=" + want[k]); seen.add(k)
    else:
        out.append(ln)
for k, v in want.items():
    if k not in seen:
        out.append(k + "=" + v)
p.write_text("\n".join(out) + "\n")
os.chmod(p, 0o600)
print("env updated: " + ", ".join(sorted(want)))
PY
}

verify() {
    section "verify"
    if ! have docker; then
        printf 'docker missing; cannot verify the container\n'
        return 0
    fi
    docker exec "$C" sh -lc '
        if grep -q "jev-guard@0.3.1" /home/node/.config/opencode/opencode.jsonc; then
            printf "guard: ON\n"
        else
            printf "guard: OFF (patch did not add jev-guard)\n"
        fi
        printf "JEV_BASE_URL=%s\n" "$(printenv JEV_BASE_URL)"
    ' 2>&1
}

self_test() {
    local work fail=0
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    printf '%s\n' 'A=1' 'JEV_BASE_URL=http://old:1' '# keep' > "$work/.env.local"
    write_env "$work/.env.local" "http://10.0.0.1:8000" "k" > "$work/o1.txt" 2>&1 || fail=1
    grep -q '^JEV_BASE_URL=http://10.0.0.1:8000$' "$work/.env.local" || { printf 'FAIL url\n'; fail=1; }
    grep -q '^JEV_GUARD_TIMEOUT_MS=2000$' "$work/.env.local" || { printf 'FAIL timeout\n'; fail=1; }
    grep -q '^JEV_MODEL=english$' "$work/.env.local" || { printf 'FAIL model\n'; fail=1; }
    grep -q '^JEV_BASE_API_KEY=k$' "$work/.env.local" || { printf 'FAIL key\n'; fail=1; }
    grep -q '^A=1$' "$work/.env.local" || { printf 'FAIL preserve\n'; fail=1; }
    grep -q '^# keep$' "$work/.env.local" || { printf 'FAIL comment\n'; fail=1; }
    local n1 n2
    n1=$(wc -l < "$work/.env.local")
    write_env "$work/.env.local" "http://10.0.0.1:8000" "k" > "$work/o2.txt" 2>&1 || fail=1
    n2=$(wc -l < "$work/.env.local")
    [ "$n1" = "$n2" ] || { printf 'FAIL idempotent (%s != %s)\n' "$n1" "$n2"; fail=1; }
    [ "$(classify 200)" = "up" ]   || { printf 'FAIL classify 200\n'; fail=1; }
    [ "$(classify 422)" = "up" ]   || { printf 'FAIL classify 422\n'; fail=1; }
    [ "$(classify 401)" = "auth" ] || { printf 'FAIL classify 401\n'; fail=1; }
    [ "$(classify 000)" = "down" ] || { printf 'FAIL classify 000\n'; fail=1; }
    valid_gw 172.18.0.1 || { printf 'FAIL valid_gw ip\n'; fail=1; }
    valid_gw "docker_defaultlitellm_default" && { printf 'FAIL valid_gw names\n'; fail=1; }
    rm -r "$work"
    if [ "$fail" -eq 0 ]; then printf 'laya-wire: self-test PASS\n'; else printf 'laya-wire: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local REPO URL="" KEY="" GWARG="" WIRE=0 JSON=0 SELFTEST=0 GATEWAYS=0 TIMEOUT=2000
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --wire) WIRE=1; shift ;;
            --url) URL="${2:-}"; shift 2 ;;
            --key) KEY="${2:-}"; shift 2 ;;
            --gateway) GWARG="${2:-}"; shift 2 ;;
            --timeout) TIMEOUT="${2:-2000}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --gateways) GATEWAYS=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--wire] [--url URL] [--key KEY] [--gateway IP] [--timeout MS] [--gateways] [--json] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    if [ "$GATEWAYS" -eq 1 ]; then
        have docker || { printf 'FAIL: docker missing\n'; return 2; }
        local OUT
        OUT=$(gws) || return 2
        [ -n "$OUT" ] || { printf 'FAIL: no gateway (container down?)\n'; return 2; }
        printf '%s\n' "$OUT"
        return 0
    fi

    local GWS=() G
    if [ -n "$GWARG" ]; then
        GWS=("$GWARG")
    elif have docker; then
        while IFS= read -r G; do [ -n "$G" ] && GWS+=("$G"); done < <(gws)
    fi

    local candidates=()
    [ -n "$URL" ] && candidates+=("$URL")
    if [ -z "$URL" ]; then
        for G in "${GWS[@]}"; do candidates+=("http://$G:8000"); done
        candidates+=("http://127.0.0.1:8000" "http://192.168.4.24:8000" "http://10.100.0.24:8000")
    fi

    local FOUND="" CODE="" U
    if [ "$JSON" -eq 0 ]; then
        section "probe"
        if [ "${#GWS[@]}" -gt 0 ]; then printf 'docker gateways: %s\n' "${GWS[*]}"; else printf 'docker gateways: (unknown; docker missing or container down)\n'; fi
    fi
    for U in "${candidates[@]}"; do
        CODE=$(probe "$U" "$KEY")
        if [ "$JSON" -eq 0 ]; then printf '%s -> %s (%s)\n' "$U" "$CODE" "$(classify "$CODE")"; fi
        if [ "$(classify "$CODE")" = "up" ]; then FOUND="${U%/}"; break; fi
        if [ "$(classify "$CODE")" = "auth" ] && [ -z "$KEY" ]; then
            printf 'auth required at %s; rerun with --key "$LAYA_KEY"\n' "$U"
        fi
    done

    if [ -z "$FOUND" ]; then
        if [ "$JSON" -eq 1 ]; then printf '{"found":"","code":"%s"}\n' "$CODE"; fi
        printf 'no Laya found; nothing changed\n'
        return 1
    fi
    if [ "$JSON" -eq 1 ]; then printf '{"found":"%s","code":"%s"}\n' "$FOUND" "$CODE"; fi

    case "$FOUND" in
        *127.0.0.1*)
            printf 'Laya is loopback-only; the container cannot reach it. Restart it with LAYA_HOST=%s or pass --url http://%s:8000\n' "${GWS[0]:-<bridge-gw>}" "${GWS[0]:-<bridge-gw>}"
            return 2
            ;;
    esac

    if [ "$WIRE" -eq 0 ]; then
        printf 'found %s; re-run with --wire to point jev-guard at it\n' "$FOUND"
        return 0
    fi

    section "wire"
    write_env "$REPO/.env.local" "$FOUND" "$KEY" "$TIMEOUT" || return 2
    # `docker compose restart` reuses the old container config, so env_file
    # changes (JEV_BASE_URL) are NOT applied. Recreate the service instead.
    if have docker; then
        ( cd "$REPO/docker" && docker compose up -d --force-recreate opencode-web ) \
            || printf 'WARN: recreate failed; run: (cd docker && docker compose up -d --force-recreate opencode-web)\n'
    else
        printf 'WARN: docker missing; recreate opencode-web manually\n'
    fi
    verify
    return 0
}

main "$@"
