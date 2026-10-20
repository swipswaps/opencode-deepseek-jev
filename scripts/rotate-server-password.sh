#!/usr/bin/env bash
#
# rotate-server-password.sh — rotate OPENCODE_SERVER_PASSWORD safely.
#
# Why this exists separately from rotate-api-keys.sh: API keys are verified
# by upstream consoles (DeepSeek/JEV) and preserved here; the server
# password is verified LOCALLY by opencode-web, which reads it from
# env_file ../.env.local at container CREATION time. A plain
# `docker compose restart` keeps the old env — this script recreates the
# container, then proves the new password authenticates (200) and the old
# one does not (401). Neither value is ever printed (lengths only).
#
# Flow:
#   R0  pre-flight: repo, env file, var present, docker, compose, curl
#   R1  backup .env.local (mode 0600 kept)
#   R2  generate via python3 secrets.token_urlsafe (same as ensure-env.sh)
#   R3  atomic rewrite: the ONE line changes, every other byte identical
#   R4  recreate opencode-web (env_file is creation-time, not restart-time)
#   R5  wait for https, verify new=200 + old=401 on /global/health
#   R6  summary with rollback commands
#
#   ./scripts/rotate-server-password.sh [--env FILE] [--fresh|--resume]
#   ./scripts/rotate-server-password.sh --self-test   # offline fixture
#
# Checkpointed (RULES #74): steps backup -> rewrite -> recreate -> verify are
# recorded under data/observability/jobs/. --fresh (default) resets the job;
# after a crash/interruption use --resume to skip the steps already done
# (notably the rewrite and the container recreate) instead of rotating twice.
#
# Env seams: ROTPW_ENV (default .env.local), ROTPW_NOCONTAINER=1 (skip R4/R5).
# Exit 0 rotated+verified, 1 on any failure (rollback printed, not run).
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

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

have() { command -v "$1" >/dev/null 2>&1; }

mask() {
    local s="$1"
    if [ "${#s}" -le 8 ]; then printf '***'; return 0; fi
    printf '%s...%s(len %d)' "${s:0:3}" "${s: -2}" "${#s}"
}

gen_password() {
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2>&1
}

rewrite_env() {
    # rewrite_env FILE NEWPW — replace the ONE assignment line, keep every
    # other byte identical, write atomically, keep mode 0600. Prints OK/FAIL.
    python3 - "$1" "$2" << 'PYEOF'
import os, sys
path, newpw = sys.argv[1], sys.argv[2]
with open(path) as fh:
    lines = fh.readlines()
hits = [i for i, l in enumerate(lines) if l.startswith("OPENCODE_SERVER_PASSWORD=")]
if len(hits) != 1:
    print("FAIL: expected exactly 1 assignment, found %d" % len(hits))
    raise SystemExit(1)
lines[hits[0]] = "OPENCODE_SERVER_PASSWORD=" + newpw + "\n"
tmp = path + ".rotatetmp"
with open(tmp, "w") as fh:
    fh.writelines(lines)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("OK")
PYEOF
}

auth_code() {
    # auth_code PASSWORD URL -> http code only (value never printed).
    local code=""
    code=$(curl -k -s --max-time 10 -o /dev/null -w '%{http_code}' -u "opencode:$1" "$2" 2>&1) || code="000"
    printf '%s' "$code"
}

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    printf '%s\n' '# fixture' 'DEEPSEEK_API_KEY=sk-fixture' 'OPENCODE_SERVER_PASSWORD=oldsecretvalue123' 'JEV_API_KEY=apikey_fixture' > "$work/env.local"
    chmod 600 "$work/env.local"
    local pw=""
    pw=$(gen_password)
    [ "${#pw}" -ge 24 ] || { printf 'FAIL generator length\n'; fail=1; }
    [ "$(rewrite_env "$work/env.local" "$pw")" = "OK" ] || { printf 'FAIL rewrite\n'; fail=1; }
    grep -q '^DEEPSEEK_API_KEY=sk-fixture$' "$work/env.local" || { printf 'FAIL other lines intact\n'; fail=1; }
    grep -q "^OPENCODE_SERVER_PASSWORD=$pw$" "$work/env.local" || { printf 'FAIL new value placed\n'; fail=1; }
    [ "$(stat -c %a "$work/env.local")" = "600" ] || { printf 'FAIL mode 0600\n'; fail=1; }
    printf '%s\n' 'OPENCODE_SERVER_PASSWORD=a' 'OPENCODE_SERVER_PASSWORD=b' > "$work/dup.env"
    [ "$(rewrite_env "$work/dup.env" "$pw")" = "OK" ] && { printf 'FAIL duplicate guard\n'; fail=1; }
    local m=""
    m=$(mask "$pw")
    case "$m" in *"$pw"*) printf 'FAIL mask leaks\n'; fail=1 ;; esac

    # checkpoint/resume (#74): a fresh run rotates; a resume must skip the
    # backup+rewrite steps and leave the password unchanged (idempotent).
    printf '%s\n' 'OPENCODE_SERVER_PASSWORD=startpass000000000000' 'KEEP=1' > "$work/env2"
    chmod 600 "$work/env2"
    if ! DURABLE_JOB_DIR="$work/jobs" ROTPW_NOCONTAINER=1 ROTPW_CONFIRM=write \
        bash "${BASH_SOURCE[0]}" --env "$work/env2" --fresh > "$work/rot1.txt" 2>&1; then
        printf 'FAIL checkpoint fresh run\n'; fail=1
    fi
    local pw1=""
    pw1=$(grep '^OPENCODE_SERVER_PASSWORD=' "$work/env2" | head -1)
    case "$pw1" in *startpass*) printf 'FAIL fresh run did not rotate\n'; fail=1 ;; esac
    if ! DURABLE_JOB_DIR="$work/jobs" ROTPW_NOCONTAINER=1 \
        bash "${BASH_SOURCE[0]}" --env "$work/env2" --resume > "$work/rot2.txt" 2>&1; then
        printf 'FAIL checkpoint resume run\n'; fail=1
    fi
    local pw2=""
    pw2=$(grep '^OPENCODE_SERVER_PASSWORD=' "$work/env2" | head -1)
    [ "$pw1" = "$pw2" ] || { printf 'FAIL resume rewrote the password\n'; fail=1; }
    grep -q 'skip (done): rotate-server-password/rewrite' "$work/rot2.txt" \
        || { printf 'FAIL resume did not skip rewrite\n'; fail=1; }
    grep -q '^KEEP=1$' "$work/env2" || { printf 'FAIL resume changed other lines\n'; fail=1; }

    rm -f "$work/env.local" "$work/dup.env" "$work/env2" "$work/env2.bak.rotate" \
        "$work/jobs/rotate-server-password.jsonl" "$work/rot1.txt" "$work/rot2.txt"
    rmdir "$work/jobs" "$work"
    if [ "$fail" -eq 0 ]; then printf 'rotate-server-password: self-test PASS\n'; else printf 'rotate-server-password: self-test FAIL\n'; fi
    return "$fail"
}

# --- checkpointed steps (durable-run, RULES #74) -------------------------
step_backup() {
    cp -p "$ENVF" "$BAK" || { printf 'FAIL: backup failed\n'; return 1; }
    printf 'R1 backup: %s\n' "$BAK"
}

step_rewrite() {
    local newpw=""
    newpw=$(gen_password) || { printf 'FAIL: generator\n'; return 1; }
    [ "${#newpw}" -ge 24 ] || { printf 'FAIL: generator produced short output\n'; return 1; }
    printf 'R2 generated replacement %s\n' "$(mask "$newpw")"
    local confirm=""
    if [ -n "${ROTPW_CONFIRM:-}" ]; then
        confirm="$ROTPW_CONFIRM"
    else
        printf 'Type "write" to replace the password and recreate opencode-web, anything else to abort: '
        read -r confirm
    fi
    if [ "$confirm" != "write" ]; then
        printf 'aborted; backup kept at %s\n' "$BAK"
        return 1
    fi
    [ "$(rewrite_env "$ENVF" "$newpw")" = "OK" ] || { printf 'FAIL: rewrite refused\n'; return 1; }
    printf 'R3 atomic rewrite done (mode 0600 kept)\n'
}

step_recreate() {
    if [ "${ROTPW_NOCONTAINER:-0}" -eq 1 ]; then
        printf 'R4 container recreate skipped (ROTPW_NOCONTAINER=1)\n'
        return 0
    fi
    docker compose --project-directory "$REPO/docker" up -d --force-recreate opencode-web > /dev/null 2>&1 \
        || { printf 'FAIL: recreate failed\n'; return 1; }
    printf 'R4 container recreated (env_file is creation-time)\n'
}

step_verify() {
    if [ "${ROTPW_NOCONTAINER:-0}" -eq 1 ]; then
        printf 'R5 verification skipped (ROTPW_NOCONTAINER=1)\n'
        return 0
    fi
    local newpw="" oldpw=""
    newpw=$(grep '^OPENCODE_SERVER_PASSWORD=' "$ENVF" | head -1)
    newpw=${newpw#OPENCODE_SERVER_PASSWORD=}
    oldpw=$(grep '^OPENCODE_SERVER_PASSWORD=' "$BAK" | head -1)
    oldpw=${oldpw#OPENCODE_SERVER_PASSWORD=}
    [ -n "$newpw" ] && [ -n "$oldpw" ] || { printf 'FAIL: cannot read new/old password for verification\n'; return 1; }
    printf 'R5 waiting for https, then proving new=200 and old=401\n'
    local i code=""
    for i in $(seq 1 12); do
        sleep 5
        code=$(auth_code "$newpw" https://127.0.0.1:4096/global/health)
        if [ "$code" = "401" ] || [ "$code" = "200" ]; then break; fi
    done
    local newcode oldcode
    newcode=$(auth_code "$newpw" https://127.0.0.1:4096/global/health)
    oldcode=$(auth_code "$oldpw" https://127.0.0.1:4096/global/health)
    printf 'new password -> %s (want 200); old password -> %s (want 401)\n' "$newcode" "$oldcode"
    if [ "$newcode" = "200" ] && [ "$oldcode" = "401" ]; then
        printf 'PASS: rotation verified\n'
        printf 'tell every tab/client the new password; update any stored copy\n'
        return 0
    fi
    printf 'FAIL: verification mismatch — rollback:\n'
    printf '  cp %s %s\n' "$BAK" "$ENVF"
    printf '  docker compose -f %s/docker/docker-compose.yml up -d --force-recreate opencode-web\n' "$REPO"
    return 1
}

main() {
    local SELF=""
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local ENVF="${ROTPW_ENV:-$REPO/.env.local}"
    local MODE="fresh" RUN_STEP=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return "$?" ;;
            --env) ENVF="${2:-}"; shift 2 ;;
            --env=*) ENVF="${1#--env=}"; shift ;;
            --fresh) MODE="fresh"; shift ;;
            --resume) MODE="resume"; shift ;;
            --run-step) RUN_STEP="${2:-}"; shift 2 ;;
            -h | --help) printf 'usage: %s [--env FILE] [--fresh|--resume] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    local BAK="$ENVF.bak.rotate"
    local JOB="rotate-server-password"
    local DU="$REPO/scripts/durable-run.sh"
    if [ -n "$RUN_STEP" ]; then
        case "$RUN_STEP" in
            backup) step_backup; return "$?" ;;
            rewrite) step_rewrite; return "$?" ;;
            recreate) step_recreate; return "$?" ;;
            verify) step_verify; return "$?" ;;
            *) printf 'unknown step: %s\n' "$RUN_STEP"; return 2 ;;
        esac
    fi
    for t in python3 curl; do
        have "$t" || { printf 'GATE FAIL: %s required\n' "$t"; return 1; }
    done
    if [ "${ROTPW_NOCONTAINER:-0}" -ne 1 ]; then
        have docker || { printf 'GATE FAIL: docker required (or set ROTPW_NOCONTAINER=1)\n'; return 1; }
    fi
    printf '=== rotate-server-password.sh ===\n'
    [ -f "$ENVF" ] || { printf 'FAIL: no env file at %s\n' "$ENVF"; return 1; }
    local oldpw=""
    oldpw=$(grep '^OPENCODE_SERVER_PASSWORD=' "$ENVF" | head -1)
    oldpw=${oldpw#OPENCODE_SERVER_PASSWORD=}
    [ -n "$oldpw" ] || { printf 'FAIL: OPENCODE_SERVER_PASSWORD missing from %s\n' "$ENVF"; return 1; }
    printf 'R0 pre-flight: env present, current password %s\n' "$(mask "$oldpw")"
    if [ "$MODE" = "fresh" ]; then bash "$DU" --job "$JOB" --reset > /dev/null 2>&1; fi
    bash "$DU" --job "$JOB" --step backup -- bash "$SELF" --env "$ENVF" --run-step backup || return 1
    bash "$DU" --job "$JOB" --step rewrite -- bash "$SELF" --env "$ENVF" --run-step rewrite || return 1
    bash "$DU" --job "$JOB" --step recreate -- bash "$SELF" --env "$ENVF" --run-step recreate || return 1
    bash "$DU" --job "$JOB" --step verify -- bash "$SELF" --env "$ENVF" --run-step verify || return 1
    printf 'R6 done. rollback: cp %s %s\n' "$BAK" "$ENVF"
    return 0
}

main "$@"
