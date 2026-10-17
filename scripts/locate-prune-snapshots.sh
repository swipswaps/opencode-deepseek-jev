#!/usr/bin/env bash
#
# locate-prune-snapshots.sh — keep /.snapshots out of the locate index (host).
#
# updatedb indexes every BTRFS snapshot unless PRUNEPATHS prunes it; on a
# USB-HDD root that bloats the database and slows updatedb and searches. This
# adds /.snapshots to PRUNEPATHS idempotently, with a timestamped backup.
#
#   bash scripts/locate-prune-snapshots.sh                 # dry-run (show)
#   sudo bash scripts/locate-prune-snapshots.sh --apply    # edit + updatedb
#   bash scripts/locate-prune-snapshots.sh --file F --apply # another conf (test)
#   bash scripts/locate-prune-snapshots.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

conf_has_snapshot() {
    python3 - "$1" << 'PYEOF'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'PRUNEPATHS\s*=\s*"([^"]*)"', txt)
sys.exit(0 if (m and ".snapshots" in m.group(1)) else 1)
PYEOF
}

conf_add() {
    python3 - "$1" << 'PYEOF'
import re, sys
path = sys.argv[1]
txt = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r'(PRUNEPATHS\s*=\s*")([^"]*)(")', txt)
if m:
    if ".snapshots" in m.group(2):
        print("already pruned"); sys.exit(0)
    new = m.group(1) + m.group(2).rstrip() + " /.snapshots" + m.group(3)
    txt = txt[:m.start()] + new + txt[m.end():]
else:
    txt = txt.rstrip("\n") + '\nPRUNEPATHS="/.snapshots"\n'
open(path, "w", encoding="utf-8").write(txt)
print("added /.snapshots to PRUNEPATHS")
PYEOF
}

self_test() {
    local w c fail=0 out
    w=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    c="$w/updatedb.conf"
    printf '%s\n' 'PRUNEFS = "nfs"' 'PRUNEPATHS = "/tmp /media"' > "$c"
    bash "${BASH_SOURCE[0]}" --file "$c" --apply > /dev/null 2>&1
    conf_has_snapshot "$c" || { printf 'FAIL: /.snapshots not added\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" --file "$c" --apply 2>&1)
    case "$out" in *already*) : ;; *) printf 'FAIL: not idempotent\n'; fail=1 ;; esac
    local n
    n=$(grep -c '\.snapshots' "$c")
    [ "$n" -eq 1 ] || { printf 'FAIL: duplicated (count=%s)\n' "$n"; fail=1; }
    printf 'locate-prune-snapshots: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local CONF="/etc/updatedb.conf" APPLY=0 NO_UPDATE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) CONF="${2:-}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --no-updatedb) NO_UPDATE=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--file CONF] [--apply] [--no-updatedb] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    [ -f "$CONF" ] || { printf 'GATE FAIL: no %s\n' "$CONF"; return 1; }
    if conf_has_snapshot "$CONF"; then
        printf 'OK: %s already prunes /.snapshots\n' "$CONF"; return 0
    fi
    printf 'current PRUNEPATHS in %s:\n' "$CONF"
    grep -E '^PRUNEPATHS' "$CONF" 2>&1
    printf 'would append: /.snapshots\n'
    if [ "$APPLY" -eq 0 ]; then
        printf 'dry-run; re-run with --apply (sudo) to edit + run updatedb\n'; return 0
    fi
    local bak="$CONF.bak.$(date +%s)"
    cp "$CONF" "$bak" || { printf 'FAIL: backup\n'; return 1; }
    printf 'backup: %s\n' "$bak"
    conf_add "$CONF" || { printf 'FAIL: edit\n'; return 1; }
    if [ "$NO_UPDATE" -eq 1 ]; then
        printf 'PRUNEPATHS updated; rebuild when ready: sudo updatedb\n'; return 0
    fi
    if have updatedb; then
        printf 'running updatedb in the background (silent; can take many minutes on a USB-HDD)\n'
        updatedb &
        local u=$!
        printf 'updatedb pid=%s\n' "$u"
        printf '  monitor from another terminal: grep read_bytes /proc/%s/io ; iostat -x 2\n' "$u"
        if wait "$u"; then printf 'updatedb: done\n'; else printf 'WARN: updatedb failed (run: sudo updatedb)\n'; fi
    else
        printf '(updatedb not on PATH; run it from a root shell)\n'
    fi
    return 0
}

main "$@"
