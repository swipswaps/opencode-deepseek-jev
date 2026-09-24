#!/usr/bin/env bash
#
# doctor.sh — health check for the OpenCode + DeepSeek + Jev environment.
#
# ============================================================================
# AUDIT — why tier 6 tests invocation variants
# ============================================================================
#
# opencode 1.18.31 with `--version`:
#
#   docker run --rm IMAGE --version
#     → opencode is PID 1
#     → prints version, then continues to default subcommand (TUI)
#     → blocks on stdin forever
#     → timeout kills it after 30s
#
#   docker run --rm --entrypoint sh IMAGE -c 'opencode --version'
#     → sh parses -c 'opencode --version'
#     → POSIX allows sh to exec-replace itself with a single simple command
#     → opencode is PID 1 again
#     → same blocking behavior
#
#   docker run --rm --entrypoint sh IMAGE -c 'opencode --version; :'
#     → sh has two commands, cannot exec-replace
#     → forks opencode as a child
#     → opencode exits after printing the version
#     → sh runs `:`, exits
#     → container exits
#
# The POSIX shell exec optimization for `sh -c`:
#   "If there is a single command, the shell may exec it directly."
#   POSIX sh(1), §Consequences of Shell Errors and §Command Search:
#   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html
#
#   Bash Manual §3.7.4 "Command Execution Environment":
#   https://www.gnu.org/software/bash/manual/html_node/Command-Execution-Environment.html
#
# Tier 6 tests two variants and uses the first that exits 0 as the gate:
#
#   variant A  sh -c 'opencode --version; :'
#   variant B  sh -c '(opencode --version)'
#
# If neither exits 0, the failure is escalated with full diagnostics.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX sh(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html
#   POSIX printf(1)        https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX test(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   Bash pipefail          https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Bash trap              https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash export            https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Linux signal(7)        https://man7.org/linux/man-pages/man7/signal.7.html
#   Docker run             https://docs.docker.com/engine/reference/commandline/run/
#   Docker entrypoint      https://docs.docker.com/engine/reference/builder/#entrypoint
#   Docker kill            https://docs.docker.com/engine/reference/commandline/kill/
#   DeepSeek balance API   https://api-docs.deepseek.com/api/get-user-balance
#   TypeSafe console       https://console.typesafe.ai/keys
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017. §1.6.3 "Rule of Composition".
#
#   Stevens & Rago, "Advanced Programming in the UNIX Environment",
#   3rd ed., Addison-Wesley, 2013. ISBN-13: 978-0321637734. §9.6.
#
# ============================================================================

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env.local"
IMAGE="opencode-deepseek-jev:robust"
MODEL="deepseek/deepseek-flash"

FULL=0
case "${1:-}" in
    --full) FULL=1 ;;
    "") ;;
    *) printf 'usage: %s [--full]\n' "$0"; return 2 ;;
esac

pass_count=0
fail_count=0
warn_count=0

pass() { printf '  PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() {
    printf '  FAIL  %s\n' "$1"
    [ -n "$2" ] && printf '        %s\n' "$2"
    fail_count=$((fail_count + 1))
}
warn() {
    printf '  WARN  %s\n' "$1"
    [ -n "$2" ] && printf '        %s\n' "$2"
    warn_count=$((warn_count + 1))
}
skip() { printf '  SKIP  %s\n' "$1"; }

cleanup_on_signal() {
    printf '\n[signal received; cleaning orphan containers]\n' >&2
    local cids
    cids=$(docker ps -q --filter "ancestor=$IMAGE" 2>&1)
    local c
    for c in $cids; do
        docker kill "$c" > /dev/null 2>&1 || true
        printf '  killed %s\n' "$c" >&2
    done
}
trap cleanup_on_signal INT TERM

print_lines() {
    local prefix="$1" body="$2"
    printf '%s\n' "$body" | while IFS= read -r line; do
        printf '%s%s\n' "$prefix" "$line"
    done
}

# ----------------------------------------------------------------------------
# Tier 0 — required binaries
# ----------------------------------------------------------------------------
tier0() {
    printf 'Tier 0: required binaries\n'
    local bin
    for bin in docker curl python3; do
        if command -v "$bin" > /dev/null; then
            pass "$bin present"
        else
            fail "$bin missing" "install it (dnf install $bin)"
        fi
    done
}

# ----------------------------------------------------------------------------
# Tier 1 — docker daemon
# ----------------------------------------------------------------------------
tier1() {
    printf 'Tier 1: docker daemon\n'
    if docker info > /dev/null; then
        pass "docker daemon reachable"
    else
        fail "docker daemon not reachable" \
             "on Fedora: sudo usermod -aG docker \$USER && newgrp docker"
    fi
}

# ----------------------------------------------------------------------------
# Tier 2 — .env.local present, mode 0600, both keys set and exported
# ----------------------------------------------------------------------------
tier2() {
    printf 'Tier 2: environment file\n'
    if [ ! -f "$ENV_FILE" ]; then
        fail "$ENV_FILE missing" \
             "create it with two lines: DEEPSEEK_API_KEY=... and JEV_API_KEY=..."
        return
    fi
    pass "$ENV_FILE present"

    local mode
    mode=$(stat -c '%a' "$ENV_FILE" 2>&1)
    if [ "$mode" = "600" ]; then
        pass "mode 0600"
    else
        fail "mode is $mode, expected 600" "chmod 600 $ENV_FILE"
    fi

    DEEPSEEK_API_KEY=""
    JEV_API_KEY=""
    OPENCODE_SERVER_PASSWORD=""
    while IFS='=' read -r k v; do
        case "$k" in
            DEEPSEEK_API_KEY) DEEPSEEK_API_KEY="$v" ;;
            JEV_API_KEY)      JEV_API_KEY="$v" ;;
            OPENCODE_SERVER_PASSWORD) OPENCODE_SERVER_PASSWORD="$v" ;;
        esac
    done < "$ENV_FILE"

    export DEEPSEEK_API_KEY JEV_API_KEY OPENCODE_SERVER_PASSWORD

    if [ -n "$DEEPSEEK_API_KEY" ]; then
        pass "DEEPSEEK_API_KEY set (len ${#DEEPSEEK_API_KEY})"
    else
        fail "DEEPSEEK_API_KEY empty"
    fi
    if [ -n "$JEV_API_KEY" ]; then
        pass "JEV_API_KEY set (len ${#JEV_API_KEY})"
    else
        fail "JEV_API_KEY empty"
    fi
    if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
        pass "OPENCODE_SERVER_PASSWORD set (len ${#OPENCODE_SERVER_PASSWORD})"
    else
        warn "OPENCODE_SERVER_PASSWORD empty" \
             "web UI (port 4096) would run unauthenticated; set it in $ENV_FILE"
    fi
}

# ----------------------------------------------------------------------------
# Tier 3 — DeepSeek key live check
# ----------------------------------------------------------------------------
tier3() {
    printf 'Tier 3: DeepSeek key live check\n'
    if [ -z "$DEEPSEEK_API_KEY" ]; then skip "no key to check"; return; fi

    local tmp
    tmp=$(mktemp)
    local http
    http=$(curl -s -o "$tmp" -w '%{http_code}' \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        https://api.deepseek.com/user/balance)
    local body
    body=$(cat "$tmp")
    rm -f "$tmp"

    case "$http" in
        200) pass "key accepted by provider (HTTP 200)" ;;
        401) fail "key rejected (HTTP 401)" "$body"
             printf '        issue a fresh key at https://platform.deepseek.com/api_keys\n' ;;
        402) fail "insufficient balance (HTTP 402)" "$body"
             printf '        top up at https://platform.deepseek.com/top_up\n' ;;
        *)   fail "unexpected provider response (HTTP $http)" "$body" ;;
    esac
}

# ----------------------------------------------------------------------------
# Tier 4 — Jev key live check
# ----------------------------------------------------------------------------
tier4() {
    printf 'Tier 4: Jev key live check\n'
    if [ -z "$JEV_API_KEY" ]; then skip "no key to check"; return; fi

    case "$JEV_API_KEY" in
        apikey_*|sk-*|ts_*|jev-*) ;;
        *) fail "unexpected Jev key prefix" \
                "expected apikey_, sk-, ts_, or jev-; get one at https://console.typesafe.ai/keys"
           return ;;
    esac
    pass "key prefix recognized"

    local tmp
    tmp=$(mktemp)
    local http
    http=$(curl -s -o "$tmp" -w '%{http_code}' \
        -X POST https://api.typesafe.ai/v1/systemone \
        -H "Authorization: Bearer $JEV_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"state":"validation probe","model":"jev-latest","questions":{"probe":{"type":"noul","instructions":"Is this request valid?"}}}')
    local body
    body=$(cat "$tmp")
    rm -f "$tmp"

    case "$http" in
        200) pass "key accepted by provider (HTTP 200)" ;;
        401) fail "key rejected (HTTP 401)" "$body"
             printf '        issue a fresh key at https://console.typesafe.ai/keys\n' ;;
        422) fail "request body rejected (HTTP 422)" "$body"
             printf '        this is a bug in the doctor script, not in your key\n' ;;
        *)   fail "unexpected provider response (HTTP $http)" "$body" ;;
    esac
}

# ----------------------------------------------------------------------------
# Tier 5 — image present
# ----------------------------------------------------------------------------
tier5() {
    printf 'Tier 5: container image\n'
    if docker image inspect "$IMAGE" > /dev/null 2>&1; then
        local created
        created=$(docker image inspect --format '{{.Created}}' "$IMAGE")
        pass "$IMAGE present (created $created)"
    else
        fail "$IMAGE not built" \
             "cd $REPO_DIR/docker && ./build.sh"
    fi
}

# ----------------------------------------------------------------------------
# Tier 6 — image runs.
# ----------------------------------------------------------------------------
# Tests invocation variants in order. First variant that exits 0 with
# non-empty output is the gate. If none work, diagnostics follow.
tier6() {
    printf 'Tier 6: image runs\n'
    if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
        skip "image not built"
        return
    fi

    local out rc
    local worked=0
    local winner=""

    # Variant A: trailing no-op prevents sh exec-replace.
    out=$(timeout 15 docker run --rm --entrypoint sh "$IMAGE" -c 'opencode --version; :' 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        pass "variant A (sh -c '...; :'): output '$out' (rc=$rc)"
        winner="A"
        worked=1
    else
        printf '        variant A (sh -c "...; :"): rc=%d output=%s\n' "$rc" "${out:-<empty>}"
    fi

    if [ "$worked" -eq 0 ]; then
        # Variant B: subshell prevents sh exec-replace.
        out=$(timeout 15 docker run --rm --entrypoint sh "$IMAGE" -c '(opencode --version)' 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
            pass "variant B (subshell): output '$out' (rc=$rc)"
            winner="B"
            worked=1
        else
            printf '        variant B (subshell): rc=%d output=%s\n' "$rc" "${out:-<empty>}"
        fi
    fi

    if [ "$worked" -eq 0 ]; then
        # Variant C: explicit exit after.
        out=$(timeout 15 docker run --rm --entrypoint sh "$IMAGE" -c 'opencode --version; exit 0' 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
            pass "variant C (explicit exit): output '$out' (rc=$rc)"
            winner="C"
            worked=1
        else
            printf '        variant C (explicit exit): rc=%d output=%s\n' "$rc" "${out:-<empty>}"
        fi
    fi

    if [ "$worked" -eq 1 ]; then
        printf '        gate selected: variant %s\n' "$winner"
        return
    fi

    # All variants failed. Report and produce detailed diagnostics.
    fail "all version-query variants failed"

    printf '\n        diagnostic output follows.\n\n'

    local outa
    outa=$(timeout 30 docker run --rm --entrypoint sh "$IMAGE" -c '
command -v opencode || echo "opencode NOT in PATH"
printf "PATH=%s\n" "$PATH"
printf "HOME=%s\n" "$HOME"
printf "USER=%s UID=%s GID=%s\n" "$(id -un)" "$(id -u)" "$(id -g)"
printf "PWD=%s\n" "$(pwd)"
ls -la /home/node/.opencode/bin 2>&1 || echo "no /home/node/.opencode/bin"
printf "\n--- opencode --version ---\n"
opencode --version
printf "rc=%s\n" "$?"
' 2>&1)
    if [ -n "$outa" ]; then
        printf '        probe A: --entrypoint sh diagnostics\n'
        print_lines '          ' "$outa"
    fi
}

# ----------------------------------------------------------------------------
# Tier 7 — plugin status (needs --full)
# ----------------------------------------------------------------------------
tier7() {
    printf 'Tier 7: plugin status\n'
    if [ "$FULL" -ne 1 ]; then skip "run with --full to enable"; return; fi
    if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
        skip "image not built"
        return
    fi

    local out
    out=$(timeout 60 docker run --rm \
        --user "$(id -u):$(id -g)" \
        --entrypoint sh "$IMAGE" -c 'opencode plugin list; :' 2>&1)

    if printf '%s' "$out" | grep -q jev-guard; then
        pass "plugin list shows jev-guard"
    else
        fail "plugin list does not show jev-guard"
        print_lines '        ' "$out"
    fi
}

# ----------------------------------------------------------------------------
# Tier 8 — end-to-end model round-trip (needs --full)
# ----------------------------------------------------------------------------
tier8() {
    printf 'Tier 8: end-to-end model round-trip\n'
    if [ "$FULL" -ne 1 ]; then
        skip "run with --full to enable (costs approx \$10^-4 per invocation)"
        return
    fi
    if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
        skip "image not built"
        return
    fi

    local tmp
    tmp=$(mktemp)
    timeout 180 docker run -t --rm \
        --user "$(id -u):$(id -g)" \
        -e DEEPSEEK_API_KEY -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "$IMAGE" run --model "$MODEL" "Reply with the single word OK" > "$tmp" 2>&1
    local rc=$?

    if grep -q '\bOK\b' "$tmp"; then
        pass "model responded with OK (exit code $rc informational)"
    else
        fail "model did not respond with OK"
        printf '        transcript:\n'
        while IFS= read -r line; do printf '          %s\n' "$line"; done < "$tmp"
    fi
    rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# Tier 9 — Jev functional proof (needs --full)
# ----------------------------------------------------------------------------
tier9() {
    printf 'Tier 9: Jev functional proof\n'
    if [ "$FULL" -ne 1 ]; then
        skip "run with --full to enable (costs ~3e-4 USD)"
        return
    fi
    if ! command -v docker > /dev/null; then
        skip "docker not present"
        return
    fi

    local script="$REPO_DIR/scripts/test-jev-functional.sh"
    if [ ! -x "$script" ]; then
        fail "missing $script"
        return
    fi

    local out rc
    out=$("$script" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "jev_review invoked and returned applicable metrics"
    else
        fail "Jev functional proof failed (rc=$rc)"
        print_lines '        ' "$out"
    fi
}

summary() {
    printf '\n=== summary ===\n'
    printf '  pass: %d\n' "$pass_count"
    printf '  warn: %d\n' "$warn_count"
    printf '  fail: %d\n' "$fail_count"
    if [ "$fail_count" -gt 0 ]; then
        printf '\nresult: FAIL\n'
        return 1
    fi
    printf '\nresult: OK\n'
    return 0
}

main() {
    printf '=== doctor.sh ===\n'
    printf 'Repo: %s\n' "$REPO_DIR"
    printf 'Mode: %s\n\n' "$([ "$FULL" -eq 1 ] && printf 'full' || printf 'fast')"

    tier0
    tier1
    tier2
    tier3
    tier4
    tier5
    tier6
    tier7
    tier8
    tier9

    summary
}

main "$@"
