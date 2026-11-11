#!/usr/bin/env bash
#
# settings-apply.sh — apply the dashboard's desired provider pause/resume state.
#
# The dashboard runs inside the container, where .env.local is masked, so it
# cannot remove the effective env key itself. It writes
# data/observability/settings-state.json; this host-side script performs the
# effective change:
#   - pause:  comment the provider's env-key line, `opencode auth logout <id>`
#   - resume: restore the commented env-key line
#   - recreate opencode-web, then verify the paused key is absent from the
#     container environment
#
#   ./scripts/settings-apply.sh                 # dry run
#   ./scripts/settings-apply.sh --apply --yes
#   ./scripts/settings-apply.sh --self-test     # offline fixture
#
# Values are never printed. Exit 0 ok, 1 failure, 2 usage/cannot run.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

REPO=""
STATE=""
ENVFILE=""
APPLY=0
YES=0
CONTAINER="${SETTINGS_CONTAINER:-opencode-deepseek-web}"

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

have() { command -v "$1" > /dev/null; }

usage() {
    printf 'usage: %s [--apply --yes] [--container NAME] [--self-test] [--help]\n' "$0"
    printf '  --apply        write the env change and recreate opencode-web\n'
    printf '  --yes          confirm writes/recreate\n'
    printf '  --container    container name (default %s)\n' "$CONTAINER"
}

rewrite_env() {
    # rewrite_env FILE VAR comment|restore TS -> prints changed=N (value-free)
    local file="$1" var="$2" mode="$3" ts="$4"
    python3 - "$file" "$var" "$mode" "$ts" <<'PY'
import re, sys
path, var, mode, ts = sys.argv[1:5]
try:
    text = open(path, encoding="utf-8").read()
except OSError as e:
    print("cannot read env file: %s" % e)
    sys.exit(2)
lines = text.splitlines(keepends=True)
on = re.compile(r"^(%s=)" % re.escape(var))
off = re.compile(r"^# PAUSED \S+ (%s=)" % re.escape(var))
out = []
changed = 0
for ln in lines:
    if mode == "comment":
        if on.match(ln):
            out.append("# PAUSED %s %s" % (ts, ln))
            changed += 1
            continue
    else:
        m = off.match(ln)
        if m:
            out.append(m.group(1) + ln[m.end():])
            changed += 1
            continue
    out.append(ln)
if changed:
    open(path, "w", encoding="utf-8").write("".join(out))
print("changed=%d" % changed)
sys.exit(0 if changed else 1)
PY
}

pending_lines() {
    python3 - "$STATE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except OSError:
    sys.exit(0)
for k, v in (d.get("providers") or {}).items():
    if v.get("applied") is False:
        print("%s\t%s\t%s" % (k, "paused" if v.get("paused") else "resume", v.get("envVar") or ""))
PY
}

mark_applied() {
    python3 - "$STATE" <<'PY'
import datetime, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for v in (d.get("providers") or {}).values():
    if v.get("applied") is False:
        v["applied"] = True
d["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")
PY
}

self_test() {
    local w rc
    w=$(mktemp -d)
    local key="ANTHROPIC_API_KEY"
    {
        printf '%s=%s\n' "$key" "test-placeholder-value"
        printf '%s\n' 'OTHER=keep'
    } > "$w/env.local"
    rewrite_env "$w/env.local" "ANTHROPIC_API_KEY" comment "2026-01-01T00:00:00Z" > /dev/null
    rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^# PAUSED .* ANTHROPIC_API_KEY=' "$w/env.local"; then
        printf 'settings-apply: self-test FAIL (comment)\n'
        rm -f "$w/env.local"; rmdir "$w"; return 1
    fi
    rewrite_env "$w/env.local" "ANTHROPIC_API_KEY" restore "2026-01-01T00:00:00Z" > /dev/null
    rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^ANTHROPIC_API_KEY=' "$w/env.local"; then
        printf 'settings-apply: self-test FAIL (restore)\n'
        rm -f "$w/env.local"; rmdir "$w"; return 1
    fi
    if ! grep -q '^OTHER=keep$' "$w/env.local"; then
        printf 'settings-apply: self-test FAIL (unrelated line changed)\n'
        rm -f "$w/env.local"; rmdir "$w"; return 1
    fi
    rm -f "$w/env.local"; rmdir "$w"
    printf 'settings-apply: self-test PASS (comment + restore + unrelated line)\n'
    return 0
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=1 ;;
            --yes) YES=1 ;;
            --container) CONTAINER="${2:-opencode-deepseek-web}"; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
        shift
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'settings-apply: cannot resolve repo root\n'
        return 2
    fi
    STATE="$REPO/data/observability/settings-state.json"
    ENVFILE="$REPO/.env.local"

    printf '=== settings-apply ===\n'
    printf 'repo: %s\n' "$REPO"
    if [ ! -f "$STATE" ]; then
        printf 'state: no settings-state.json (nothing paused)\n'
        return 0
    fi
    local pending
    pending=$(pending_lines)
    if [ -z "$pending" ]; then
        printf 'state: nothing pending\n'
        return 0
    fi

    if [ ! -f "$ENVFILE" ] || [ ! -r "$ENVFILE" ] || [ -c "$ENVFILE" ]; then
        printf 'env: .env.local is not a readable regular file (run this on the host)\n'
        return 2
    fi

    local ts id want envvar msg rc apply_fail=0 changed=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    # Dry run: plan only, never write.
    if [ "$APPLY" -eq 0 ]; then
        while IFS="$(printf '\t')" read -r id want envvar; do
            [ -n "$id" ] || continue
            case "$id" in *[!A-Za-z0-9._-]*) printf '  skip suspicious id: %s\n' "$id"; continue ;; esac
            case "$envvar" in *[!A-Za-z0-9_]*) printf '  skip suspicious env: %s\n' "$envvar"; continue ;; esac
            printf '  %s -> %s (env=%s) [dry run]\n' "$id" "$want" "${envvar:-none}"
        done <<EOF
$pending
EOF
        printf 'dry run: pass --apply --yes to comment/restore env keys and recreate %s\n' "$CONTAINER"
        return 0
    fi
    [ "$YES" -eq 1 ] || { printf 'settings-apply: writes require --yes\n'; return 2; }

    # Apply: env rewrite first, then auth logout.
    while IFS="$(printf '\t')" read -r id want envvar; do
        [ -n "$id" ] || continue
        case "$id" in *[!A-Za-z0-9._-]*) printf '  skip suspicious id: %s\n' "$id"; continue ;; esac
        case "$envvar" in *[!A-Za-z0-9_]*) printf '  skip suspicious env: %s\n' "$envvar"; continue ;; esac
        printf '  %s -> %s (env=%s)\n' "$id" "$want" "${envvar:-none}"
        if [ -n "$envvar" ]; then
            if [ "$want" = "paused" ]; then
                msg=$(rewrite_env "$ENVFILE" "$envvar" comment "$ts"); rc=$?
            else
                msg=$(rewrite_env "$ENVFILE" "$envvar" restore "$ts"); rc=$?
            fi
            printf '    env: %s\n' "$msg"
            [ "$rc" -eq 0 ] && changed=1
            [ "$rc" -eq 2 ] && apply_fail=1
        fi
        if [ "$want" = "paused" ] && have docker; then
            if docker exec "$CONTAINER" sh -c "export PATH=/home/node/.opencode/bin:\$PATH; opencode auth logout $id" > /dev/null; then
                printf '    auth: logout %s issued\n' "$id"
            else
                printf '    auth: logout %s failed (continuing)\n' "$id"
            fi
        fi
    done <<EOF
$pending
EOF

    if [ "$changed" -eq 1 ] && have docker; then
        if docker compose -f "$REPO/docker/docker-compose.yml" up -d --force-recreate opencode-web > /dev/null; then
            printf 'recreate: opencode-web issued\n'
        else
            printf 'recreate: opencode-web FAILED\n'
            apply_fail=1
        fi
    fi

    # Verify after recreate: a paused provider's key must be absent.
    while IFS="$(printf '\t')" read -r id want envvar; do
        [ -n "$id" ] || continue
        [ "$want" = "paused" ] || continue
        [ -n "$envvar" ] || continue
        case "$envvar" in *[!A-Za-z0-9_]*) continue ;; esac
        if have docker; then
            if docker exec "$CONTAINER" sh -c "test -z \"\${$envvar:-}\""; then
                printf '  verify: %s absent from %s\n' "$envvar" "$CONTAINER"
            else
                printf '  verify: %s still present in %s\n' "$envvar" "$CONTAINER"
                apply_fail=1
            fi
        fi
    done <<EOF
$pending
EOF

    if [ "$apply_fail" -eq 0 ]; then
        mark_applied
        printf 'settings-apply: applied\n'
        return 0
    fi
    printf 'settings-apply: partial; state left pending for a retry\n'
    return 1
}

main "$@"
