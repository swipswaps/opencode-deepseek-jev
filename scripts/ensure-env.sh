#!/usr/bin/env bash
#
# ensure-env.sh — idempotent guard for .env.local (single source of truth).
#
# Merges, never overwrites: preserves every key already present, restores
# GEMINI_API_KEY from the newest .env.local.bak.* when it is missing, and
# generates a random OPENCODE_SERVER_PASSWORD (python3 secrets, 32 chars)
# only when it is missing, empty, or shorter than 12 chars.
#
# Layout:
#   repo/.env.local            mode 0600, gitignored — the ONLY secret store
#   repo/.env.local.bak.*      transient backups, removed via cleanup-baks.sh
#   ../notes/                  0755 world-readable + mounted ro into the
#                              container — NEVER a secret store (pointer only)
#
# Prints key NAMES and lengths only; a newly generated password is printed
# once so the operator can save it in a password manager.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
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

main() {
    local repo=""
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    if [ -z "$repo" ]; then
        repo=$(resolve_repo "$PWD")
    fi
    if [ -z "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    if ! command -v python3 > /dev/null; then
        printf 'GATE FAIL: python3 not found\n'
        return 1
    fi

    printf '=== ensure-env.sh ===\n'
    printf 'Repo: %s\n' "$repo"

    python3 - "$repo" <<'PY_EOF'
import os
import pathlib
import secrets
import sys
from datetime import datetime, timezone

repo = pathlib.Path(sys.argv[1])
env = repo / ".env.local"
wanted = ("DEEPSEEK_API_KEY", "JEV_API_KEY", "GEMINI_API_KEY",
          "OPENCODE_SERVER_PASSWORD")

def parse(p):
    d = {}
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                k = k.strip()
                if k in wanted:
                    d[k] = v.strip()
    return d

cur = parse(env)
baks = sorted(repo.glob(".env.local.bak.*"))
bak = parse(baks[-1]) if baks else {}

merged = dict(cur)
if not merged.get("GEMINI_API_KEY") and bak.get("GEMINI_API_KEY"):
    merged["GEMINI_API_KEY"] = bak["GEMINI_API_KEY"]

generated = False
pw = merged.get("OPENCODE_SERVER_PASSWORD", "")
if len(pw) < 12:
    merged["OPENCODE_SERVER_PASSWORD"] = secrets.token_urlsafe(24)
    generated = True

if env.exists():
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = repo / (".env.local.bak." + ts)
    backup.write_text(env.read_text())
    os.chmod(backup, 0o600)
    print("backup: " + backup.name)
else:
    print("backup: none (no prior .env.local)")

env.write_text("".join(k + "=" + merged.get(k, "") + "\n"
                       for k in wanted if merged.get(k, "")))
os.chmod(env, 0o600)

for k in wanted:
    v = merged.get(k, "")
    print(("present " if v else "missing ") + k
          + (" len=" + str(len(v)) if v else ""))

for k in ("DEEPSEEK_API_KEY", "JEV_API_KEY"):
    if not merged.get(k):
        print("WARN: " + k + " empty — add it to .env.local")

if generated:
    print("GENERATED_PASSWORD_BEGIN")
    print(merged["OPENCODE_SERVER_PASSWORD"])
    print("GENERATED_PASSWORD_END")
    print("SAVE this password in a password manager; it is shown only once.")
PY_EOF
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: merge step returned %d\n' "$rc"
        return 1
    fi

    local mode=""
    mode=$(stat -c '%a' "$repo/.env.local")
    if [ "$mode" = "600" ]; then
        printf 'mode 0600 OK\n'
    else
        printf 'GATE FAIL: mode is %s, expected 600\n' "$mode"
        return 1
    fi
    printf 'done: %s (names only above; values never printed except a new password)\n' "$repo/.env.local"
    return 0
}

main "$@"
