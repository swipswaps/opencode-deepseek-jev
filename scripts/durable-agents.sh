#!/usr/bin/env bash
#
# durable-agents.sh — arm/verify the durable background agents in one command.
#
# The durable loop has three always-on agents, each with its own installer:
#   sentinel         every 5 min   trip on budget/deny/gateway-failure news
#   notify-sink      service       receive + persist pushed alerts
#   progress-review  every 15 min  PASS on advance / FAIL on a stalled loop
#
# Arming them one by one is easy to half-do (and a half-armed loop looks
# healthy). This is the one idempotent command: --install runs the three
# tested installers in order, --status shows unit + enabled + active state,
# and SKIP is printed when systemctl is absent (the container) instead of
# pretending the agents are running.
#
#   ./scripts/durable-agents.sh              # status (default)
#   ./scripts/durable-agents.sh --install    # arm/refresh all three
#   ./scripts/durable-agents.sh --dry-run    # print what --install runs
#   ./scripts/durable-agents.sh --self-test  # offline: templates + installers
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
# No bare kill. printf only. main() wrapper.
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

# agent:unit:installer — one line per durable agent.
AGENTS=(
    "sentinel:opencode-sentinel.timer:scripts/sentinel-install.sh"
    "notify-sink:opencode-notify-sink.service:scripts/notify-selfhost.sh"
    "progress-review:opencode-progress-review.timer:scripts/progress-review-install.sh"
)

status() {
    local dest="$HOME/.config/systemd/user" spec agent unit installer present
    printf '=== durable agents ===\n'
    printf 'unit dir: %s\n' "$dest"
    for spec in "${AGENTS[@]}"; do
        agent="${spec%%:*}"; spec="${spec#*:}"
        unit="${spec%%:*}"; installer="${spec#*:}"
        [ -f "$dest/$unit" ] && present="unit present" || present="unit MISSING"
        if have systemctl; then
            local en ac
            en=$(systemctl --user is-enabled "$unit" 2>&1 | head -n 1)
            ac=$(systemctl --user is-active "$unit" 2>&1 | head -n 1)
            printf '  %-15s %-34s %-12s enabled=%-10s active=%s\n' \
                "$agent" "$unit" "$present" "$en" "$ac"
        else
            printf '  %-15s %-34s %-12s SKIP: systemctl absent (run on the host)\n' \
                "$agent" "$unit" "$present"
        fi
        printf '  %-15s installer: %s\n' "" "$installer"
    done
    printf '\nevidence: ./scripts/logs.sh --source ledger\n'
    printf 'arm on host: ./scripts/durable-agents.sh --install\n'
}

dry_run() {
    local spec agent unit installer
    printf '=== durable-agents --dry-run ===\n'
    for spec in "${AGENTS[@]}"; do
        agent="${spec%%:*}"; spec="${spec#*:}"
        unit="${spec%%:*}"; installer="${spec#*:}"
        printf '  %-15s bash %s   # -> %s\n' "$agent" "$installer" "$unit"
    done
    printf 'order: notify sink first, then sentinel + progress-review timers.\n'
}

install() {
    local spec agent installer fail=0 out=""
    printf '=== durable-agents --install ===\n'
    for spec in "${AGENTS[@]}"; do
        agent="${spec%%:*}"; spec="${spec#*:}"
        installer="${spec#*:}"
        printf '\n--- %s ---\n' "$agent"
        out=$(bash "$REPO/$installer" 2>&1) || fail=1
        printf '%s\n' "$out"
    done
    printf '\n'
    status
    [ "$fail" -eq 0 ] || printf 'durable-agents: one or more installers reported a failure (see above)\n'
    return "$fail"
}

self_test() {
    local fail=0 f out=""
    for f in \
        systemd/opencode-sentinel.service systemd/opencode-sentinel.timer \
        systemd/opencode-notify-sink.service \
        systemd/opencode-progress-review.service systemd/opencode-progress-review.timer; do
        if [ ! -f "$REPO/$f" ]; then printf 'FAIL unit template missing: %s\n' "$f"; fail=1; fi
    done
    for f in sentinel-install.sh progress-review-install.sh; do
        if ! out=$(bash "$REPO/scripts/$f" --self-test 2>&1); then
            printf 'FAIL %s --self-test\n%s\n' "$f" "$out"; fail=1
        fi
    done
    if ! out=$(node "$REPO/scripts/notify-sink.mjs" --self-test 2>&1); then
        printf 'FAIL notify-sink self-test\n%s\n' "$out"; fail=1
    fi
    if [ "$fail" -eq 0 ]; then
        printf 'durable-agents: self-test PASS (5 templates, 3 installers)\n'
    else
        printf 'durable-agents: self-test FAIL (%d)\n' "$fail"
    fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    case "${1:-}" in
        ""|--status) status; return 0 ;;
        --install) install; return "$?" ;;
        --dry-run) dry_run; return 0 ;;
        --self-test) self_test; return "$?" ;;
        -h|--help)
            printf 'usage: %s [--status|--install|--dry-run|--self-test]\n' "$0"
            return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
}

main "$@"
