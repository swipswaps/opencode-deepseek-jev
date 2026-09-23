#!/usr/bin/env bash
#
# add-xdg-open-shim.sh — add a no-op xdg-open to the image so
# `opencode web` does not crash when it tries to auto-launch a browser.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The opencode-web container starts, prints its banner, then attempts
# `spawn xdg-open http://localhost:4096`. xdg-open is not present in
# node:22-bookworm-slim. Bun's spawn throws ENOENT. The opencode process
# exits. The restart policy restarts it. The cycle repeats.
#
# Fix: install a two-line shell script at /usr/local/bin/xdg-open that
# exits 0. `opencode web` treats that as "browser launched" and proceeds
# to serve. The actual client is the host browser, hitting the mapped
# port 4096.
#
# This is the standard pattern for headless containers whose CLI tries
# to open a browser. Freedesktop xdg-utils is the reference implementation
# of xdg-open; a shim is simpler than installing the full desktop stack.
#
#   xdg-utils / xdg-open:
#     https://www.freedesktop.org/wiki/Software/xdg-utils/
#   Dockerfile reference, RUN:
#     https://docs.docker.com/engine/reference/builder/#run
#   Bun.spawn, ENOENT on missing executable:
#     https://bun.sh/docs/api/spawn
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   xdg-utils / xdg-open:
#     https://www.freedesktop.org/wiki/Software/xdg-utils/
#   Dockerfile reference:
#     https://docs.docker.com/engine/reference/builder/
#   OpenCode Web UI:
#     https://opencode.ai/docs/web/
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX chmod(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

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

DOCKERFILE="$REPO_DIR/docker/Dockerfile"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== add-xdg-open-shim.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n\n' "$REPO_DIR"

    if [ ! -f "$DOCKERFILE" ]; then
        printf 'GATE FAIL: %s not found\n' "$DOCKERFILE"
        return 1
    fi
    printf '  PASS: Dockerfile present\n'

    if grep -q 'xdg-open' "$DOCKERFILE"; then
        printf '  PASS: xdg-open shim already present; nothing to do\n'
        return 0
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$DOCKERFILE" "$DOCKERFILE.bak.${TS}"
        printf '  backup: %s.bak.%s\n' "$DOCKERFILE" "$TS"
    fi

    # Insert the shim after the first FROM line. The Dockerfile in this
    # repo uses a single FROM, so the addition is unambiguous.
    section "insert xdg-open shim"

    if [ "$MODE" = "apply" ]; then
        python3 - "$DOCKERFILE" <<'PY_EOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find the first FROM and insert after it.
insert_at = None
for i, line in enumerate(lines):
    if line.lstrip().upper().startswith("FROM "):
        insert_at = i + 1
        break

if insert_at is None:
    print("ERROR: no FROM line found", file=sys.stderr)
    sys.exit(3)

shim = (
    "\n"
    "# xdg-open shim ----------------------------------------------------------\n"
    "# opencode web tries to spawn xdg-open to launch a browser. That\n"
    "# binary is not present in node:22-bookworm-slim; Bun's spawn throws\n"
    "# ENOENT and the process exits. A no-op shim that returns 0 lets\n"
    "# opencode proceed to serve; the actual client is the host browser.\n"
    "#   https://www.freedesktop.org/wiki/Software/xdg-utils/\n"
    "RUN printf '#!/bin/sh\\nexit 0\\n' > /usr/local/bin/xdg-open \\\n"
    "    && chmod +x /usr/local/bin/xdg-open\n"
    "\n"
)

lines.insert(insert_at, shim)
with open(path, "w") as f:
    f.writelines(lines)
print("  shim inserted")
PY_EOF

        printf '  syntax preview (first 25 lines):\n'
        head -25 "$DOCKERFILE" | while IFS= read -r line; do
            printf '    %s\n' "$line"
        done
    else
        printf '  would insert after first FROM:\n'
        printf '    RUN printf %s > /usr/local/bin/xdg-open && chmod +x /usr/local/bin/xdg-open\n' "'#!/bin/sh\\nexit 0\\n'"
    fi

    section "summary"
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply, then rebuild.\n'
    else
        printf '\n  APPLIED.\n'
        printf '\n  next steps:\n'
        printf '    1. rebuild the image:   cd %s/docker && ./build.sh\n' "$REPO_DIR"
        printf '    2. restart the web UI:  %s/scripts/web-stop.sh && %s/scripts/web.sh\n' "$REPO_DIR" "$REPO_DIR"
        printf '    3. open the browser:    http://127.0.0.1:4096\n'
    fi
    return 0
}

main "$@"
