#!/usr/bin/env bash
#
# snapshot-audit.sh — is the BTRFS snapshot system costing us? (read-only, host).
#
# Answers "are snapshots slowing the OS, and what should I tune" for a
# snapper-on-BTRFS root (the /.snapshots/NNNN/snapshot layout). Read-only: it
# NEVER creates or deletes a snapshot; commands that need root are PRINTED, not
# run. The known costs are (a) locate/updatedb indexing every snapshot, (b)
# space pinned ~ CoW fragmentation on a slow (USB-HDD) root, (c) BTRFS qgroups.
#
#   bash scripts/snapshot-audit.sh
#   bash scripts/snapshot-audit.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

self_test() {
    local fail=0 k
    for k in 'snapper' 'btrfs quota' 'PRUNEPATHS' 'TIMELINE_LIMIT' 'cleanup number'; do
        grep -q "$k" "${BASH_SOURCE[0]}" || { printf 'FAIL: missing probe %s\n' "$k"; fail=1; }
    done
    printf 'snapshot-audit: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        -h | --help) printf 'usage: %s [--self-test]\n' "$0"; return 0 ;;
    esac
    printf '== root mount ==\n'
    findmnt -no SOURCE,FSTYPE,OPTIONS / 2>&1 || printf '(findmnt unavailable)\n'

    printf '\n== btrfs filesystem usage ==\n'
    if have btrfs; then btrfs filesystem usage / 2>&1 | head -16; else printf '(no btrfs tool)\n'; fi

    printf '\n== quotas / qgroups (a known snapper drag) ==\n'
    if have btrfs; then
        btrfs quota status / 2>&1 | head -4
        printf '  (ON -> consider: sudo btrfs quota disable /  — snapper works without it)\n'
    else
        printf '(no btrfs tool)\n'
    fi

    printf '\n== snapper retention limits (/etc/snapper/configs/*) ==\n'
    if have snapper; then
        local c found=0 out
        for c in /etc/snapper/configs/*; do
            [ -f "$c" ] || continue
            found=1
            printf -- '-- %s\n' "$(basename "$c")"
            out=$(grep -E '^(TIMELINE_LIMIT_|NUMBER_LIMIT|SPACE_LIMIT|BACKGROUND_COMPARISON)' "$c" 2>&1)
            case "$out" in
                *"Permission denied"*|*"permission denied"*)
                    printf '  (needs root: sudo snapper -c %s get-config | grep -E "TIMELINE|NUMBER|SPACE")\n' "$(basename "$c")" ;;
                *) printf '%s\n' "$out" ;;
            esac
        done
        [ "$found" -eq 1 ] || printf '(no configs)\n'
        printf '  snapshot count:  sudo snapper list | tail -n +3 | wc -l\n'
    else
        printf '(no snapper; if you use raw btrfs snapshots: sudo btrfs subvolume list -s /)\n'
    fi

    printf '\n== does locate index the snapshots? ==\n'
    if [ -f /etc/updatedb.conf ]; then
        grep -E '^(PRUNEPATHS|PRUNEFS)' /etc/updatedb.conf 2>&1
        if grep -q '\.snapshots' /etc/updatedb.conf; then
            printf '  OK: /.snapshots is pruned from locate\n'
        else
            printf '  WARN: /.snapshots NOT pruned -> updatedb indexes every snapshot (slow on a USB HDD)\n'
        fi
    else
        printf '(no /etc/updatedb.conf)\n'
    fi
    local db n=0
    for db in /var/lib/plocate/plocate.db /var/lib/mlocate/mlocate.db; do
        if [ -e "$db" ]; then ls -lh "$db"; n=$((n + 1)); fi
    done
    [ "$n" -eq 0 ] && printf '(no plocate/mlocate db found; run: sudo updatedb)\n'
    if have plocate; then printf '  (plocate in use -> db at /var/lib/plocate/plocate.db)\n'; fi

    printf '\n== reading ==\n'
    printf '%s\n' '- compress=zstd:1 (if shown) -> write I/O is compressed; good on a slow disk.'
    printf '%s\n' '- Quota "Enabled: no" -> no qgroup cost; skip recommendation 3.'
    printf '%s\n' '- BTRFS allocates in chunks: a Data chunk near 95% is normal while unallocated space remains.'
    printf '%s\n' '- PRUNEPATHS/PRUNEFS in /etc/updatedb.conf drive BOTH mlocate and plocate.'

    printf '\n== recommended (run on the host) ==\n'
    printf '%s\n' '1) Cap retention, e.g.: sudo snapper -c root set-config TIMELINE_LIMIT_HOURLY=6 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=4 TIMELINE_LIMIT_MONTHLY=2 TIMELINE_LIMIT_YEARLY=0'
    printf '%s\n' '2) Number cleanup: sudo snapper -c root set-config NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=10 ; sudo snapper -c root cleanup number'
    printf '%s\n' '3) If quota/qgroups are ON: sudo btrfs quota disable /  (the usual snapper perf drag)'
    printf '%s\n' '4) Prune locate: add /.snapshots to PRUNEPATHS in /etc/updatedb.conf, then: sudo updatedb'
    printf '%s\n' '5) On a USB-HDD root keep btrfs balance RARE (monthly, sudo btrfs balance start -dusage=5 /) or off; scrub monthly is fine.'
    return 0
}

main "$@"
