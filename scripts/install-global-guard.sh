#!/usr/bin/env bash
#
# install-global-guard.sh - make the blacklist guard load from ANY project.
#
# Why this exists: opencode scans the global plugin directory
# ($XDG_CONFIG_HOME/opencode/plugins) for sessions rooted outside this
# checkout. The 2026-11-10 audit found that link pointing at the CONTAINER path
# /workspace/.opencode/plugins/blacklist-guard.js, which is DANGLING on the
# host. A dangling link is indistinguishable from "no matches": the guard is
# silently absent, so `sed` / `2>/dev/null` / `rm -rf` run unblocked.
#
#   ./scripts/install-global-guard.sh            # --check (default)
#   ./scripts/install-global-guard.sh --check    # PASS / FAIL dangling / WARN absent
#   ./scripts/install-global-guard.sh --install  # link the resolved checkout plugin
#   ./scripts/install-global-guard.sh --uninstall
#   ./scripts/install-global-guard.sh --require  # a missing link is FAIL, not WARN
#   ./scripts/install-global-guard.sh --self-test # offline, temp HOME
#
# Exit: 0 PASS/ok; 2 FAIL (dangling or required-but-missing); 3 usage.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
PLUGIN="$REPO/.opencode/plugins/blacklist-guard.js"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
LINK="$CONFIG_HOME/opencode/plugins/blacklist-guard.js"

usage() {
    printf 'usage: %s [--check|--install|--uninstall|--require|--self-test]\n' "$0"
    printf 'default: --check (PASS resolves, FAIL dangling, WARN absent)\n'
}

have() { command -v "$1" > /dev/null; }

resolve_link() {
    if have readlink; then
        readlink -f "$LINK" 2>&1
    else
        printf ''
    fi
}

check_link() {
    local resolved=""
    if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
        printf 'WARN: no global guard link at %s\n' "$LINK"
        printf '  fix: %s --install\n' "$0"
        [ "$REQUIRE" -eq 1 ] && return 2
        return 0
    fi
    resolved="$(resolve_link)"
    if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        printf 'PASS: %s -> %s\n' "$LINK" "$resolved"
        return 0
    fi
    printf 'FAIL: dangling global guard link: %s\n' "$LINK"
    printf '  target: %s\n' "$(readlink "$LINK" 2>&1)"
    printf '  fix: %s --install\n' "$0"
    return 2
}

install_link() {
    local resolved=""
    if [ ! -f "$PLUGIN" ]; then
        printf 'FAIL: plugin missing: %s\n' "$PLUGIN"
        return 2
    fi
    resolved="$(readlink -f "$PLUGIN" 2>&1)"
    if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
        printf 'FAIL: cannot resolve %s\n' "$PLUGIN"
        return 2
    fi
    mkdir -p "$(dirname "$LINK")" || return 2
    ln -sfn "$resolved" "$LINK" || return 2
    printf 'installed: %s -> %s\n' "$LINK" "$resolved"
    check_link
}

uninstall_link() {
    if [ -L "$LINK" ] || [ -e "$LINK" ]; then
        rm -f "$LINK" || return 2
        printf 'removed: %s\n' "$LINK"
    else
        printf 'nothing to remove: %s\n' "$LINK"
    fi
    return 0
}

self_test() {
    local tmp rc fail=0
    tmp="$(mktemp -d)"
    export HOME="$tmp/home"
    export XDG_CONFIG_HOME="$tmp/home/.config"
    LINK="$XDG_CONFIG_HOME/opencode/plugins/blacklist-guard.js"
    mkdir -p "$HOME"

    check_link > /dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL self-test: absent link should WARN (rc=0), got %s\n' "$rc"; fail=1; }
    REQUIRE=1 check_link > /dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL self-test: --require should FAIL on absent link, got %s\n' "$rc"; fail=1; }
    REQUIRE=0

    install_link > /dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL self-test: install rc=%s\n' "$rc"; fail=1; }
    check_link > /dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL self-test: installed link should PASS, got %s\n' "$rc"; fail=1; }

    ln -sfn "$tmp/does-not-exist" "$LINK"
    check_link > /dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL self-test: dangling link should FAIL, got %s\n' "$rc"; fail=1; }

    install_link > /dev/null 2>&1
    uninstall_link > /dev/null 2>&1
    [ ! -L "$LINK" ] || { printf 'FAIL self-test: uninstall left the link\n'; fail=1; }

    rm -f "$LINK" "$HOME/.config/opencode/plugins/.keep" 2>&1
    rmdir "$XDG_CONFIG_HOME/opencode/plugins" "$XDG_CONFIG_HOME/opencode" "$XDG_CONFIG_HOME" "$HOME" 2>&1 || true
    rmdir "$tmp" 2>&1 || true

    if [ "$fail" -eq 0 ]; then
        printf 'install-global-guard: self-test PASS (absent + required + install + dangling + uninstall)\n'
    else
        printf 'install-global-guard: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    local action="check"
    REQUIRE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) action="check"; shift ;;
            --install) action="install"; shift ;;
            --uninstall) action="uninstall"; shift ;;
            --require) REQUIRE=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$action" in
        check) check_link; return "$?" ;;
        install) install_link; return "$?" ;;
        uninstall) uninstall_link; return "$?" ;;
    esac
    usage >&2
    return 3
}

main "$@"
