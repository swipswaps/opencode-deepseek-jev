#!/usr/bin/env bash
#
# ensure-env.sh — idempotent guard for .env.local (single source of truth).
#
# Contract (now true, unlike the earlier version):
#   * a rerun with nothing to change is a STRICT NO-OP: no write, no backup,
#     no password on stdout, exit 0;
#   * every key already present is preserved verbatim, including keys this
#     script does not know about, plus comments and blank lines;
#   * OPENCODE_SERVER_PASSWORD is regenerated ONLY when it is missing/empty or
#     when --rotate is passed. A short-but-present password only WARNS — it is
#     never silently replaced;
#   * the write is atomic (temp + rename) so a killed run cannot truncate the
#     file;
#   * GEMINI_API_KEY is restored from the newest .env.local.bak.* only when it
#     is missing;
#   * a generation is announced (PASSWORD_ROTATED marker) so the caller
#     (web.sh) can tell the operator to re-login; values never otherwise print.
#
# Usage: ensure-env.sh [--rotate] [--repo <dir>]   (--repo is the test seam)
#
# Layout:
#   repo/.env.local            mode 0600, gitignored — the ONLY secret store
#   repo/.env.local.bak.*      one backup per actual change; cleanup-baks.sh
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
    local rotate=0 repo_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rotate) rotate=1; shift ;;
            --repo)   repo_arg="${2:-}"; shift 2 ;;
            *) printf 'usage: %s [--rotate] [--repo <dir>]\n' "$0" >&2; return 2 ;;
        esac
    done

    if ! command -v python3 > /dev/null; then
        printf 'GATE FAIL: python3 not found\n'
        return 1
    fi

    local repo=""
    if [ -n "$repo_arg" ]; then
        repo="$repo_arg"
    else
        repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
        if [ -z "$repo" ]; then
            repo=$(resolve_repo "$PWD")
        fi
    fi
    if [ -z "$repo" ] || [ ! -d "$repo" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    printf '=== ensure-env.sh ===\n'
    printf 'Repo: %s\n' "$repo"

    python3 - "$repo" "$rotate" <<'PY_EOF'
import os
import pathlib
import secrets
import sys
from datetime import datetime, timezone

repo = pathlib.Path(sys.argv[1])
rotate = sys.argv[2] == "1"
env = repo / ".env.local"
wanted = ("DEEPSEEK_API_KEY", "JEV_API_KEY", "GEMINI_API_KEY",
          "OPENCODE_SERVER_PASSWORD")
known = set(wanted)

def parse_values(p):
    """key -> value for the known keys (unknown keys are preserved as lines)."""
    d = {}
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                if k.strip() in known:
                    d[k.strip()] = v.strip()
    return d

cur_lines = env.read_text().splitlines() if env.exists() else []
cur = parse_values(env)
baks = sorted(repo.glob(".env.local.bak.*"))
bak = parse_values(baks[-1]) if baks else {}

merged = dict(cur)
# Restore GEMINI only when it is missing (never overwrite a present value).
if not merged.get("GEMINI_API_KEY") and bak.get("GEMINI_API_KEY"):
    merged["GEMINI_API_KEY"] = bak["GEMINI_API_KEY"]

# Password: regenerate ONLY on missing/empty or explicit --rotate.
generated = False
pw = merged.get("OPENCODE_SERVER_PASSWORD", "")
short_present = bool(pw) and len(pw) < 12
if (not pw) or rotate:
    merged["OPENCODE_SERVER_PASSWORD"] = secrets.token_urlsafe(24)
    generated = True

# Rebuild the file: keep every existing line verbatim except that a known key
# gets its (possibly updated) value; append any known key that is absent.
out_lines, seen = [], set()
for line in cur_lines:
    stripped = line.lstrip()
    if "=" in line and not stripped.startswith("#"):
        k = line.split("=", 1)[0].strip()
        if k in known:
            if merged.get(k, ""):
                out_lines.append(k + "=" + merged[k])
            seen.add(k)
            continue
    out_lines.append(line)  # comments, blank lines, unknown keys: verbatim
for k in wanted:
    if k not in seen and merged.get(k, ""):
        out_lines.append(k + "=" + merged[k])
text = ("\n".join(out_lines) + "\n") if out_lines else ""

before = env.read_text() if env.exists() else None
changed = text != before

print("changed: " + ("yes" if changed else "no"))
if changed:
    if env.exists():
        # Microsecond precision: two changes in the same second must not
        # collide and silently drop a backup (observed as a flaky behavior test).
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = repo / (".env.local.bak." + ts)
        backup.write_text(before if before is not None else "")
        os.chmod(backup, 0o600)
        print("backup: " + backup.name)
    tmp = repo / (".env.local.tmp." + str(os.getpid()))
    tmp.write_text(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, env)  # atomic
    print("wrote: " + env.name)

# Only touch the mode if it is actually wrong, so a no-op really is a no-op.
if env.exists() and (env.stat().st_mode & 0o777) != 0o600:
    os.chmod(env, 0o600)

for k in wanted:
    v = merged.get(k, "")
    print(("present " if v else "missing ") + k + (" len=" + str(len(v)) if v else ""))

for k in ("DEEPSEEK_API_KEY", "JEV_API_KEY"):
    if not merged.get(k):
        print("WARN: " + k + " empty — add it to .env.local")
if short_present and not generated:
    print("WARN: OPENCODE_SERVER_PASSWORD is shorter than 12 chars — left as-is; pass --rotate to replace it")

if generated:
    print("PASSWORD_ROTATED")
    print("GENERATED_PASSWORD_BEGIN")
    print(merged["OPENCODE_SERVER_PASSWORD"])
    print("GENERATED_PASSWORD_END")
    print("SAVE this password in a password manager; it is shown only once.")
PY_EOF
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: ensure-env step returned %d\n' "$rc"
        return 1
    fi

    if [ -f "$repo/.env.local" ]; then
        local mode=""
        mode=$(stat -c '%a' "$repo/.env.local")
        if [ "$mode" = "600" ]; then
            printf 'mode 0600 OK\n'
        else
            printf 'GATE FAIL: mode is %s, expected 600\n' "$mode"
            return 1
        fi
    fi
    return 0
}

main "$@"
