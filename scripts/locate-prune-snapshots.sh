#!/usr/bin/env bash
#
# locate-prune-snapshots.sh — keep heavy trees out of the locate index (host).
#
# updatedb walks the WHOLE tree unless PRUNEPATHS prunes it. On this host the
# costly trees are BTRFS snapshots (/.snapshots) and huge/virtual dirs
# (/var/lib/docker, flatpak, libvirt, /mnt). Pruning them shrinks the database
# and cuts updatedb time dramatically. Idempotent; timestamped backup.
#
#   bash scripts/locate-prune-snapshots.sh                    # dry-run (show)
#   sudo bash scripts/locate-prune-snapshots.sh --apply       # edit, then updatedb (idle priority)
#   sudo bash scripts/locate-prune-snapshots.sh --apply --no-updatedb
#   sudo bash scripts/locate-prune-snapshots.sh --apply --paths "/.snapshots /var/lib/docker"
#   bash scripts/locate-prune-snapshots.sh --self-test
#
# Default paths: /.snapshots /var/lib/docker /var/lib/flatpak /var/lib/libvirt /mnt
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

disable_timer() {
    local u s found=0
    for u in plocate-updatedb.timer mlocate-updatedb.timer updatedb.timer; do
        s=$(systemctl list-unit-files "$u" 2>&1)
        case "$s" in
            *"$u"*)
                found=1
                printf 'disabling %s (stops the recurring background crawl)\n' "$u"
                systemctl disable --now "$u" || printf 'WARN: could not disable %s\n' "$u"
                ;;
        esac
    done
    if [ "$found" -eq 0 ]; then
        printf '(no updatedb timer unit found; check: systemctl list-timers | grep -i updatedb)\n'
    else
        printf '(re-enable later: sudo systemctl enable --now <unit>)\n'
    fi
    return 0
}

DEF_PATHS="/.snapshots /var/lib/docker /var/lib/flatpak /var/lib/libvirt /mnt"

# conf_has FILE "p1 p2 ..." -> exit 0 if ALL are in PRUNEPATHS
conf_has() {
    python3 - "$1" "$2" << 'PYEOF'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'PRUNEPATHS\s*=\s*"([^"]*)"', txt)
cur = set(m.group(1).split()) if m else set()
sys.exit(0 if all(p in cur for p in sys.argv[2].split()) else 1)
PYEOF
}

conf_add() {
    python3 - "$1" "$2" << 'PYEOF'
import re, sys
path, want = sys.argv[1], sys.argv[2].split()
txt = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r'(PRUNEPATHS\s*=\s*")([^"]*)(")', txt)
cur = m.group(2).split() if m else []
added = [p for p in want if p not in cur]
if not added:
    print("already pruned"); sys.exit(0)
merged = cur + added
if m:
    txt = txt[:m.start()] + m.group(1) + " ".join(merged) + m.group(3) + txt[m.end():]
else:
    txt = txt.rstrip("\n") + '\nPRUNEPATHS="' + " ".join(merged) + '"\n'
open(path, "w", encoding="utf-8").write(txt)
print("added: " + " ".join(added))
PYEOF
}

run_updatedb() {
    printf 'running updatedb in the background at IDLE priority (silent; can take many minutes)\n'
    if have ionice && have nice; then
        ionice -c3 nice -n19 updatedb &
    else
        updatedb &
    fi
    local u=$!
    printf 'updatedb pid=%s  monitor: grep read_bytes /proc/%s/io ; iostat -x 2\n' "$u" "$u"
    if wait "$u"; then printf 'updatedb: done\n'; else printf 'WARN: updatedb failed (run: sudo updatedb)\n'; fi
}

self_test() {
    local w c fail=0 out n
    w=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    c="$w/updatedb.conf"
    printf '%s\n' 'PRUNEFS = "nfs"' 'PRUNEPATHS = "/tmp /media"' > "$c"
    bash "${BASH_SOURCE[0]}" --file "$c" --apply --no-updatedb --paths "/.snapshots /var/lib/docker" > /dev/null 2>&1
    conf_has "$c" "/.snapshots /var/lib/docker" || { printf 'FAIL: paths not added\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" --file "$c" --apply --no-updatedb --paths "/.snapshots /var/lib/docker" 2>&1)
    case "$out" in *already*) : ;; *) printf 'FAIL: not idempotent\n'; fail=1 ;; esac
    n=$(grep -c '\.snapshots' "$c")
    [ "$n" -eq 1 ] || { printf 'FAIL: duplicated (count=%s)\n' "$n"; fail=1; }
    printf 'locate-prune-snapshots: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local CONF="/etc/updatedb.conf" APPLY=0 NO_UPDATE=0 PATHS="$DEF_PATHS" DISABLE_TIMER=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) CONF="${2:-}"; shift 2 ;;
            --paths) PATHS="${2:-}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --no-updatedb) NO_UPDATE=1; shift ;;
            --disable-timer) DISABLE_TIMER=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--file CONF] [--paths "P ..."] [--apply] [--no-updatedb] [--disable-timer] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$DISABLE_TIMER" -eq 1 ]; then disable_timer; return $?; fi
    [ -f "$CONF" ] || { printf 'GATE FAIL: no %s\n' "$CONF"; return 1; }
    printf 'paths to prune: %s\n' "$PATHS"
    if conf_has "$CONF" "$PATHS"; then
        printf 'OK: %s already prunes them\n' "$CONF"; return 0
    fi
    printf 'current PRUNEPATHS in %s:\n' "$CONF"
    grep -E '^PRUNEPATHS' "$CONF" 2>&1
    if [ "$APPLY" -eq 0 ]; then
        printf 'dry-run; re-run with --apply (sudo) to edit + run updatedb\n'; return 0
    fi
    local bak="$CONF.bak.$(date +%s)"
    cp "$CONF" "$bak" || { printf 'FAIL: backup\n'; return 1; }
    printf 'backup: %s\n' "$bak"
    conf_add "$CONF" "$PATHS" || { printf 'FAIL: edit\n'; return 1; }
    if [ "$NO_UPDATE" -eq 1 ]; then
        printf 'PRUNEPATHS updated; rebuild when ready: sudo updatedb\n'; return 0
    fi
    if have updatedb; then run_updatedb; else printf '(updatedb not on PATH; run it from a root shell)\n'; fi
    return 0
}

main "$@"
