#!/usr/bin/env bash
#
# secret-leak-response.sh — F1: contain a credential leak instead of re-leaking it.
#
# The leak surface is NOT the repo: .env.local is 0600, node:node, and ignored.
# The surface is the terminal/transcript, where `cat .env.local` lands live keys
# in scrollback and in every model context that reads the paste back. This
# script automates the machine-doable containment and prints the human-only
# part (provider revocation):
#
#   AUDIT    scan at-rest artifacts via secret-scan.sh; findings are
#            file:line:kind only, never a value
#   IGNORE   prove .env* and auth.json-shaped paths are ignored, and fail on
#            any untracked-but-NOT-ignored credential file (the auth.json
#            near-miss: untracked but invisible to `dirty`)
#   GUARD    install a tracked pre-commit hook (.githooks/pre-commit) and point
#            core.hooksPath at it: credential-shaped paths and staged secret
#            patterns are refused
#   PRIV     flag a browser running as uid 0 (a root renderer makes the
#            sandbox moot)
#   ROTATE   print the rotation matrix; revocation has no CLI, so the actual
#            rotation stays human (rotate-api-keys.sh / rotate-server-password.sh)
#
#   ./scripts/secret-leak-response.sh [--audit] [--install] [--json] [--self-test]
#
# Exit 0 = clean, 1 = findings (contain/rotate), 2 = usage/resolve error.
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. printf only.
#
set -o pipefail

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

# Credential-shaped paths that must never be staged, and the consoles that own
# the revocation. Names only: this script never prints a value.
credential_paths() {
    printf '%s\n' \
        '.env.local' \
        'data/opencode/auth.json'
}

rotation_matrix() {
    printf '%s\n' \
        '  NAME                      ROTATE WITH'
    printf '%s\n' \
        '  DEEPSEEK_API_KEY          ./scripts/rotate-api-keys.sh (console: platform.deepseek.com/api_keys)'
    printf '%s\n' \
        '  JEV_API_KEY               ./scripts/rotate-api-keys.sh (console: console.typesafe.ai/keys)'
    printf '%s\n' \
        '  OPENCODE_SERVER_PASSWORD  ./scripts/rotate-server-password.sh'
    printf '%s\n' \
        '  LITELLM_MASTER_KEY        LiteLLM proxy admin UI (no CLI) — revoke, then rewrite .env.local'
    printf '%s\n' \
        '  SUBQ_API_KEY              provider console (no CLI) — revoke, then rewrite .env.local'
    printf '%s\n' \
        '  ANTHROPIC_API_KEY         console.anthropic.com (no CLI) — revoke, then rewrite .env.local'
    printf '%s\n' \
        '  GEMINI_API_KEY            aistudio.google.com (placeholder here; rotate only if real)'
    printf '%s\n' \
        '  Treat every key printed to a terminal as DISCLOSED, even if the paste stayed local.'
    printf '%s\n' \
        '  Snapshots under data/observability/snapshots/ can hold litellm env vars and TLS keys:' \
        '  rotate those too, then purge the snapshot dirs (they are historical copies).'
}

audit_artifacts() {
    local rc=0
    if [ ! -x "$REPO/scripts/secret-scan.sh" ]; then
        printf '  [warn] secret-scan.sh missing; artifact scan skipped\n'
        return 0
    fi
    "$REPO/scripts/secret-scan.sh" --paths "$REPO/logs $REPO/notes $REPO/data/observability"
    rc=$?
    if [ "$rc" -eq 1 ]; then
        printf '  [FAIL] at-rest secret pattern(s) found — rotate, then purge the artifact\n'
        return 1
    elif [ "$rc" -eq 2 ]; then
        printf '  [warn] scan error (exit 2)\n'
        return 0
    fi
    printf '  [ ok ] no secret patterns in logs/ notes/ data/observability/\n'
    return 0
}

path_ignored() {
    # A path under an ignored symlinked dir (data/opencode -> elsewhere) makes
    # `git check-ignore <child>` exit 128 ("beyond a symbolic link"), so walk up
    # to the nearest ignored ancestor. stderr is captured, never printed.
    local probe="$1" out=""
    while [ -n "$probe" ] && [ "$probe" != "." ]; do
        if out=$(git -C "$REPO" check-ignore -q -- "$probe" 2>&1); then return 0; fi
        probe=$(dirname "$probe")
    done
    return 1
}

audit_ignore() {
    local bad=0 p drift
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if path_ignored "$p"; then
            printf '  [ ok ] ignored: %s\n' "$p"
        else
            printf '  [FAIL] NOT ignored: %s\n' "$p"
            bad=1
        fi
    done <<EOF
$(credential_paths)
EOF
    drift=$(git -C "$REPO" ls-files --others --exclude-standard \
        | grep -Ei '(^|/)(\.env(\..*)?|auth\.json(\..*)?|.*\.(pem|key|p12|pfx|jks))$' || true)
    if [ -n "$drift" ]; then
        printf '  [FAIL] untracked and NOT ignored (would be committed):\n'
        printf '%s\n' "$drift" | while IFS= read -r p; do printf '         %s\n' "$p"; done
        bad=1
    else
        printf '  [ ok ] no untracked credential-shaped files\n'
    fi
    return "$bad"
}

audit_privilege() {
    local rootpids="" d u comm
    if have ps; then
        rootpids=$(ps -eo user=,pid=,args= | awk '$1=="root" && $0 ~ /[c]hrome/ {print $2}' | head -5)
    else
        # Minimal containers have no procps: read /proc directly (comm + owner).
        for d in /proc/[0-9]*; do
            [ -r "$d/comm" ] || continue
            comm=$(<"$d/comm")
            case "$comm" in *chrome*) ;; *) continue ;; esac
            u=$(stat -c %u "$d" 2>&1)
            [ "$u" = "0" ] || continue
            rootpids="$rootpids ${d#/proc/}"
        done
    fi
    if [ -n "$rootpids" ]; then
        printf '  [FAIL] chrome running as root (pids: %s) — a root parent voids the renderer sandbox\n' \
            "$(printf '%s' "$rootpids" | tr '\n' ' ')"
        return 1
    fi
    printf '  [ ok ] no root-owned chrome\n'
    return 0
}

install_guard() {
    local hook="$REPO/.githooks/pre-commit"
    mkdir -p "$REPO/.githooks" || return 1
    cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# Managed by scripts/secret-leak-response.sh --install. Do not edit in place.
# Refuse credential-shaped paths and staged secret patterns. Values are never
# printed: secret-scan.sh reports file:line:kind only.
set -o pipefail
staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -n "$staged" ] || exit 0
bad=0
blocked=$(printf '%s\n' "$staged" \
    | grep -Ei '(^|/)(\.env(\..*)?|auth\.json(\..*)?|.*\.(pem|key|p12|pfx|jks))$' || true)
if [ -n "$blocked" ]; then
    printf 'BLOCK: credential-shaped path staged:\n%s\n' "$blocked"
    bad=1
fi
if [ -x ./scripts/secret-scan.sh ]; then
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -f "$p" ] || continue
        if ! ./scripts/secret-scan.sh --paths "$p" --quiet; then
            printf 'BLOCK: secret pattern in staged file: %s\n' "$p"
            bad=1
        fi
    done <<EOF
$staged
EOF
fi
if [ "$bad" -eq 0 ]; then printf 'secret-leak-response: pre-commit clean\n'; fi
exit "$bad"
HOOK
    chmod +x "$hook" || return 1
    git -C "$REPO" config core.hooksPath .githooks || return 1
    printf '  [ ok ] hook: .githooks/pre-commit (executable)\n'
    printf '  [ ok ] core.hooksPath=%s\n' "$(git -C "$REPO" config --get core.hooksPath)"
    return 0
}

self_test() {
    have git || { printf 'FAIL git missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d) || { printf 'FAIL mktemp\n'; return 1; }
    mkdir -p "$work/scripts" "$work/docker" || { printf 'FAIL mkdir\n'; return 1; }
    printf '{}\n' > "$work/opencode.json"
    printf 'FROM scratch\n' > "$work/docker/Dockerfile"
    git -C "$work" init -q || { printf 'FAIL git init\n'; return 1; }
    cp "$REPO/scripts/secret-leak-response.sh" "$work/scripts/secret-leak-response.sh" \
        || { printf 'FAIL cp\n'; return 1; }
    bash "$work/scripts/secret-leak-response.sh" --install > "$work/install.txt" 2>&1 \
        || { printf 'FAIL install_guard\n'; fail=1; }
    printf 'X=1\n' > "$work/.env.local"
    printf 'ok\n' > "$work/safe.txt"
    git -C "$work" add -f .env.local
    if ( cd "$work" && bash .githooks/pre-commit ) > "$work/h1.txt" 2>&1; then
        printf 'FAIL hook allowed .env.local\n'; fail=1
    fi
    git -C "$work" reset -q
    git -C "$work" add safe.txt
    if ! ( cd "$work" && bash .githooks/pre-commit ) > "$work/h2.txt" 2>&1; then
        printf 'FAIL hook blocked a clean commit\n'; fail=1
    fi
    grep -q 'credential-shaped path' "$work/h1.txt" || { printf 'FAIL hook reason\n'; fail=1; }
    grep -q 'pre-commit clean' "$work/h2.txt" || { printf 'FAIL hook clean message\n'; fail=1; }
    rm -r "$work"
    if [ "$fail" -eq 0 ]; then printf 'secret-leak-response: self-test PASS\n'; else printf 'secret-leak-response: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo root\n'
        return 2
    fi
    local AUDIT=0 INSTALL=0 JSON=0 SELFTEST=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --audit) AUDIT=1; shift ;;
            --install) INSTALL=1; shift ;;
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--audit] [--install] [--json] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ "$AUDIT" -eq 0 ] && [ "$INSTALL" -eq 0 ] && AUDIT=1

    local findings=0 ignore_ok=1 priv_ok=1 hook_ok=1 rev
    rev=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')

    if [ "$JSON" -eq 0 ]; then
        printf '=== secret-leak-response.sh ===\n'
        printf 'rev: %s\n' "$rev"
        printf 'leak surface: terminal/transcript (the repo store is 0600 + ignored)\n'
    fi

    if [ "$AUDIT" -eq 1 ]; then
        section 'audit: artifacts'
        audit_artifacts || findings=1
        section 'audit: ignore rules'
        audit_ignore || { findings=1; ignore_ok=0; }
        section 'audit: privilege'
        audit_privilege || { findings=1; priv_ok=0; }
    fi

    if [ "$INSTALL" -eq 1 ]; then
        section 'guard: pre-commit'
        install_guard || { findings=1; hook_ok=0; }
    fi

    if [ "$JSON" -eq 0 ]; then
        section 'rotate (human-only: provider consoles have no CLI)'
        rotation_matrix
        section 'verdict'
        if [ "$findings" -eq 0 ]; then
            printf 'PASS: containment clean; still rotate anything that touched a terminal\n'
        else
            printf 'FAIL: findings above — contain, then rotate the disclosed names\n'
        fi
    else
        printf '{"ts":"%s","rev":"%s","findings":%d,"ignore_ok":%s,"priv_ok":%s,"hook_ok":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rev" "$findings" \
            "$([ "$ignore_ok" -eq 1 ] && printf true || printf false)" \
            "$([ "$priv_ok" -eq 1 ] && printf true || printf false)" \
            "$([ "$hook_ok" -eq 1 ] && printf true || printf false)"
    fi
    [ "$findings" -eq 0 ] && return 0
    return 1
}

main "$@"
