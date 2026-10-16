#!/usr/bin/env bash
#
# notify-setup.sh — scripted NOTIFY_WEBHOOK setup + probe (RULES: if it can be
# typed, it MUST be scripted — RULES.md:207, typed-must-be-scripted skill).
#
# Replaces the typing that went wrong: it VALIDATES the URL (rejects
# placeholders like REPLACE-WITH-YOUR-UUID / <url> / example.), writes it to
# .env.local (mode 0600), and proves it with a real POST — so the sentinel timer
# (which loads .env.local via EnvironmentFile) pushes on a trip.
#
#   ./scripts/notify-setup.sh --url https://hooks.slack.com/services/...   # set + probe
#   ./scripts/notify-setup.sh --show          # current value (host only of the URL)
#   ./scripts/notify-setup.sh --test          # POST a probe to the current value
#   ./scripts/notify-setup.sh --unset         # remove it
#   ./scripts/notify-setup.sh --self-test     # offline: validator (no network)
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

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

validate() {
    # validate URL -> 0 ok (prints "ok"), 1 placeholder/bad (prints reason)
    python3 - "$1" << 'PYEOF'
import re, sys
u = sys.argv[1].strip()
bad = ("REPLACE", "PLACEHOLDER", "<", ">", "YOUR-", "your-", "example.", "PASTE", "TODO", "XXXX")
for b in bad:
    if b.lower() in u.lower():
        print("placeholder (%s)" % b); sys.exit(1)
loopback = re.match(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/\S*$", u)
if not loopback and not re.match(r"^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}/?\S*$", u):
    print("need https://host/path or http://127.0.0.1[:port]/path (got %r)" % u[:40]); sys.exit(1)
print("ok"); sys.exit(0)
PYEOF
}

read_current() {
    python3 - "$1" << 'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.exists():
    for line in p.read_text().splitlines():
        if line.startswith("NOTIFY_WEBHOOK="):
            print(line.split("=", 1)[1].strip()); raise SystemExit
print("")
PYEOF
}

write_env() {
    # write_env ENVFILE URL -> replace/append NOTIFY_WEBHOOK, mode 0600
    python3 - "$1" "$2" << 'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); url = sys.argv[2]
lines = p.read_text().splitlines() if p.exists() else []
lines = [l for l in lines if not l.startswith("NOTIFY_WEBHOOK=")]
lines.append("NOTIFY_WEBHOOK=" + url)
p.write_text("\n".join(lines) + "\n")
p.chmod(0o600)
print("wrote NOTIFY_WEBHOOK to %s (mode 0600)" % p)
PYEOF
}

unset_env() {
    python3 - "$1" << 'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.exists():
    lines = [l for l in p.read_text().splitlines() if not l.startswith("NOTIFY_WEBHOOK=")]
    p.write_text("\n".join(lines) + "\n")
    print("removed NOTIFY_WEBHOOK from %s" % p)
else:
    print("no %s" % p)
PYEOF
}

probe() {
    local url="$1"
    curl -sS -o /dev/null --max-time 15 -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data '{"source":"notify-setup","count":0,"flags":[],"note":"alerting probe"}' "$url"
}

self_test() {
    local fail=0 r
    r=$(validate "https://hooks.slack.com/services/T/B/X"); [ "$r" = ok ] || { printf 'FAIL valid url -> %s\n' "$r"; fail=1; }
    r=$(validate "https://webhook.site/REPLACE-WITH-YOUR-UUID"); case "$r" in placeholder*) : ;; *) printf 'FAIL placeholder not caught -> %s\n' "$r"; fail=1 ;; esac
    r=$(validate "http://insecure.example/x"); case "$r" in need*) : ;; *) printf 'FAIL http not caught -> %s\n' "$r"; fail=1 ;; esac
    if [ "$fail" -eq 0 ]; then printf 'notify-setup: self-test PASS\n'; else printf 'notify-setup: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local REPO URL="" MODE=set
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    local ENVF="$REPO/.env.local"
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) URL="${2:-}"; shift 2 ;;
            --show) MODE=show; shift ;;
            --test) MODE=test; shift ;;
            --unset) MODE=unset; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--url URL | --show | --test | --unset | --self-test]\n' "$0"; return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) URL="$1"; shift ;;
        esac
    done
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }

    if [ "$MODE" = show ]; then
        local cur; cur=$(read_current "$ENVF")
        [ -n "$cur" ] && printf 'NOTIFY_WEBHOOK=%s\n' "$cur" || printf '(unset)\n'
        return 0
    fi
    if [ "$MODE" = unset ]; then unset_env "$ENVF"; return 0; fi

    if [ "$MODE" = test ] || [ -n "$URL" ]; then
        [ -n "$URL" ] || URL=$(read_current "$ENVF")
        [ -n "$URL" ] || { printf 'FAIL: no NOTIFY_WEBHOOK (pass --url or set it first)\n'; return 1; }
        local v; v=$(validate "$URL")
        [ "$v" = ok ] || { printf 'FAIL: refusing to write — %s\n' "$v"; return 1; }
        if [ "$MODE" = set ]; then write_env "$ENVF" "$URL"; fi
        printf 'probing %s ... ' "$URL"
        local code; code=$(probe "$URL")
        printf 'http %s\n' "$code"
        case "$code" in 2*) printf 'OK: webhook accepts POSTs\n'; return 0 ;; *) printf 'WARN: non-2xx — webhook may be wrong/unreachable\n'; return 1 ;; esac
    fi
    printf 'nothing to do; see --help\n'
    return 0
}

main "$@"
