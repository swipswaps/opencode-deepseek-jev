#!/usr/bin/env bash
#
# apply-post-rotation-fixes.sh — one shot. Everything broken or missing
# after the first rotation attempt on 2026-09-23.
#
#   F1  Wrong TypeSafe URL: console.typesafe.ai/settings/keys (404)
#       -> console.typesafe.ai/keys. Replace across repo.
#   F2  rotate-keys-guided.sh hardcoded --ozone-platform=wayland; fails
#       when WAYLAND_DISPLAY socket is absent. Gate Playwright on a real
#       display check; auto-fall back to stdin.
#   F3  verify-api-keys.sh missing. Create it.
#
# Idempotent. Re-running is safe.
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No bare kill. main() wrapper. python3 for text edits only.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX test(1) -S:
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   Docker exec / inspect:
#     https://docs.docker.com/engine/reference/commandline/exec/
#   DeepSeek keys console:
#     https://platform.deepseek.com/api_keys
#   TypeSafe keys console (corrected):
#     https://console.typesafe.ai/keys
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

WRONG_URL="https://console.typesafe.ai/keys"
RIGHT_URL="https://console.typesafe.ai/keys"
GUIDED_REL="scripts/archive/one-shot/rotate-keys-guided.sh"
VERIFY_REL="scripts/archive/one-shot/verify-api-keys.sh"

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

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' '    ' "$line"
    done
}

# ---------------------------------------------------------------------------
f1_fix_url() {
    section "F1  correct TypeSafe URL across repo"
    python3 - "$1" "$WRONG_URL" "$RIGHT_URL" "$2" <<'PY'
import os, shutil, sys
root, old, new, ts = sys.argv[1:5]
skip_dirs = {".git", "node_modules", ".venv"}
changed = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    for name in filenames:
        if ".bak." in name:
            continue
        path = os.path.join(dirpath, name)
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                src = fh.read()
        except (IsADirectoryError, PermissionError, OSError):
            continue
        if old not in src:
            continue
        n = src.count(old)
        shutil.copy2(path, path + ".bak." + ts)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(src.replace(old, new))
        print(f"  {path}: {n} replacement(s)")
        changed += 1
print(f"  files changed: {changed}")
PY
    return 0
}

# ---------------------------------------------------------------------------
f2_patch_guided() {
    section "F2  patch rotate-keys-guided.sh"
    local f="$1"
    if [ ! -f "$f" ]; then
        printf '  SKIP: %s not present\n' "$f"
        return 0
    fi
    cp "$f" "$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()
orig = src

# 1. Remove the --ozone-platform=wayland line wherever it appears.
new_lines = []
removed_ozone = 0
for line in src.split("\n"):
    if "--ozone-platform=wayland" in line:
        removed_ozone += 1
        continue
    new_lines.append(line)
src = "\n".join(new_lines)
if removed_ozone:
    print(f"  removed {removed_ozone} --ozone-platform=wayland line(s)")
else:
    print("  --ozone-platform not present, skipping")

# 2. Insert display_is_live() before detect_backend().
if "display_is_live()" in src:
    print("  display_is_live() already present")
else:
    marker = "detect_backend() {"
    helper = (
        "display_is_live() {\n"
        "    if [ -n \"${WAYLAND_DISPLAY:-}\" ]; then\n"
        "        local sock=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}\"\n"
        "        [ -S \"$sock\" ] && return 0\n"
        "    fi\n"
        "    if [ -n \"${DISPLAY:-}\" ]; then\n"
        "        local xsock=\"/tmp/.X11-unix/X${DISPLAY#*:}\"\n"
        "        xsock=\"${xsock%%.*}\"\n"
        "        [ -S \"$xsock\" ] && return 0\n"
        "    fi\n"
        "    return 1\n"
        "}\n\n"
    )
    if marker in src:
        src = src.replace(marker, helper + marker, 1)
        print("  inserted display_is_live()")
    else:
        print("  WARN: detect_backend() marker not found")

# 3. Gate detect_backend() on display_is_live().
old_head = (
    "detect_backend() {\n"
    "    if have python3 && python3 -c 'import playwright' >/dev/null 2>&1; then"
)
new_head = (
    "detect_backend() {\n"
    "    if ! display_is_live; then\n"
    "        printf 'stdin'\n"
    "        return 0\n"
    "    fi\n"
    "    if have python3 && python3 -c 'import playwright' >/dev/null 2>&1; then"
)
if old_head in src:
    src = src.replace(old_head, new_head, 1)
    print("  gated detect_backend on display_is_live()")
elif "if ! display_is_live" in src:
    print("  detect_backend already gated")
else:
    print("  WARN: detect_backend head not matched")

# 4. Fix xdotool check: 'have import' -> 'have xclip'
if "have xdotool && have import" in src:
    src = src.replace("have xdotool && have import", "have xdotool && have xclip", 1)
    print("  fixed xdotool/xclip check")

if src == orig:
    print("  no changes needed")
else:
    with open(path, "w") as fh:
        fh.write(src)
    print("  written")
PY
    return 0
}

# ---------------------------------------------------------------------------
f3_create_verify() {
    section "F3  create verify-api-keys.sh"
    local f="$1"
    if [ -f "$f" ]; then
        printf '  already present: %s\n' "$f"
        return 0
    fi
    cat > "$f" <<'VERIFY_EOF'
#!/usr/bin/env bash
#
# verify-api-keys.sh — confirm the currently configured keys work.
# Read-only. No writes, no restart.
#
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
DATA_DIR="/home/node/.local/share/opencode"
HTTP_URL="http://127.0.0.1:4096"
section() { printf '\n=== %s ===\n' "$1"; }
indent() { local line; while IFS= read -r line; do printf '%s%s\n' '    ' "$line"; done; }
mask() {
    local s="$1"
    if [ ${#s} -le 12 ]; then printf '***'; return 0; fi
    printf '%s...%s' "$(printf '%s' "$s" | cut -c1-8)" "$(printf '%s' "$s" | rev | cut -c1-6 | rev)"
}
main() {
    printf '=== verify-api-keys.sh ===\n'
    printf 'TS: %s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
    section "0. container state"
    local cstate
    cstate=$(docker inspect -f '{{.State.Status}}' "$C" 2>&1)
    printf '  state: %s\n' "$cstate"
    if [ "$cstate" != "running" ]; then
        printf 'GATE FAIL: not running\n'
        return 1
    fi
    section "1. container env (masked)"
    docker exec "$C" sh -c 'env | grep -E "^(DEEPSEEK|JEV)_API_KEY="' 2>&1 | \
        while IFS='=' read -r k v; do printf '  %s=%s\n' "$k" "$(mask "$v")"; done
    section "2. auth.json"
    docker exec "$C" sh -c "ls -la '$DATA_DIR/auth.json' 2>&1 && head -c 200 '$DATA_DIR/auth.json'" | indent
    section "3. HTTP listener"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/" 2>&1)
    printf '  http=%s\n' "$code"
    section "4. providers"
    docker exec -w /workspace "$C" sh -c 'opencode providers list' 2>&1 | indent
    section "5. DeepSeek one-shot"
    local log
    log="/tmp/verify-keys-$(date -u +%Y%m%dT%H%M%SZ).log"
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: KEYSOK'" \
        > "$log" 2>&1
    tail -8 "$log" | indent
    if grep -q 'KEYSOK' "$log"; then
        printf '\n  PASS DeepSeek key works\n'
    else
        printf '\n  FAIL DeepSeek key — see %s\n' "$log"
    fi
    section "6. JEV MCP status"
    docker exec -w /workspace "$C" sh -c 'opencode mcp list' 2>&1 | indent
    printf '\n  If jev-review is NOT "connected", the JEV key is invalid.\n'
    printf '  Verify at https://console.typesafe.ai/keys\n'
    return 0
}
main "$@"
VERIFY_EOF
    chmod +x "$f"
    printf '  created: %s\n' "$f"
    return 0
}

# ---------------------------------------------------------------------------
main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo\n'
        return 2
    fi
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    printf '=== apply-post-rotation-fixes.sh ===\n'
    printf 'Repo: %s\n' "$repo"
    printf 'TS:   %s\n' "$ts"

    f1_fix_url "$repo" "$ts"
    f2_patch_guided "$repo/$GUIDED_REL"
    f3_create_verify "$repo/$VERIFY_REL"

    section "syntax check"
    bash -n "$repo/$GUIDED_REL" && printf '  %s: syntax OK\n' "$GUIDED_REL"
    bash -n "$repo/$VERIFY_REL" && printf '  %s: syntax OK\n' "$VERIFY_REL"
    return 0
}

main "$@"
