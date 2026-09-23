#!/usr/bin/env bash
#
# patch-verify-ui-endpoint.sh — fix verify-ui-sessions.sh so it prefers
# JSON responses over HTML, and so the endpoint it reports actually
# returns session data.
#
# Bug: the prior version accepted any 200, including the SPA HTML fallback
# at /api/v1/sessions and /sessions. The real API is /api/session (singular).
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

main() {
    local script_dir repo f
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    f="$repo/scripts/archive/one-shot/verify-ui-sessions.sh"
    if [ ! -f "$f" ]; then
        printf 'SKIP: %s not present\n' "$f"
        return 0
    fi

    cp "$f" "$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    printf '=== patch-verify-ui-endpoint.sh ===\n'
    printf 'Target: %s\n\n' "$f"

    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

# 1. Reorder endpoint list: /api/session first.
old_list = (
    "for ep in /api/session /api/sessions /session /sessions \\\n"
    "              /api/v1/session /api/v1/sessions; do"
)
new_list = (
    "for ep in /api/session /api/v1/session /api/sessions \\\n"
    "              /api/v1/sessions /session /sessions; do"
)
if old_list in src:
    src = src.replace(old_list, new_list, 1)
    print("  reordered endpoint list")
else:
    print("  endpoint list already reordered or pattern not matched")

# 2. Only accept bodies that look like JSON.
old_body = (
    '        if [ "$code" = "200" ]; then\n'
    '            body=$(curl -s -u "$user:$pass" -m 5 "${URL}${ep}" 2>&1 | head -c 400)\n'
    '            printf \'  %-22s  http=%s\\n\' "$ep" "$code"\n'
    '            printf \'    body (first 400):\\n\'\n'
    '            printf \'%s\\n\' "$body" | indent\n'
    '            UI_ENDPOINT="$ep"\n'
    '        else\n'
    '            printf \'  %-22s  http=%s\\n\' "$ep" "$code"\n'
    '        fi'
)
new_body = (
    '        if [ "$code" = "200" ]; then\n'
    '            body=$(curl -s -u "$user:$pass" -m 5 "${URL}${ep}" 2>&1 | head -c 400)\n'
    '            # Accept only JSON bodies. HTML = SPA fallback.\n'
    '            first=$(printf \'%s\' "$body" | head -c 1)\n'
    '            case "$first" in\n'
    '                "{"|"[")\n'
    '                    printf \'  %-22s  http=%s  JSON\\n\' "$ep" "$code"\n'
    '                    printf \'    body (first 400):\\n\'\n'
    '                    printf \'%s\\n\' "$body" | indent\n'
    '                    UI_ENDPOINT="$ep"\n'
    '                    ;;\n'
    '                *)\n'
    '                    printf \'  %-22s  http=%s  HTML (SPA fallback, not API)\\n\' "$ep" "$code"\n'
    '                    ;;\n'
    '            esac\n'
    '        else\n'
    '            printf \'  %-22s  http=%s\\n\' "$ep" "$code"\n'
    '        fi'
)
if old_body in src:
    src = src.replace(old_body, new_body, 1)
    print("  added JSON body check")
else:
    print("  body check pattern not found; manual edit may be required")

with open(path, "w") as fh:
    fh.write(src)
PY

    printf '\n  syntax check: '
    bash -n "$f" && printf 'OK\n'
    return 0
}

main "$@"
