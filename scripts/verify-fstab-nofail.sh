#!/usr/bin/env bash
#
# verify-fstab-nofail.sh — report and, on request, apply the nofail and
# x-systemd.device-timeout options to the /mnt/nvme fstab entry.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   fstab(5)                   https://man7.org/linux/man-pages/man5/fstab.5.html
#   systemd.mount(5)           https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
#   systemd-fstab-generator(8) https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
#   systemd.target(5)          https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
#   systemd.special(7)         https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html
#   Arch Wiki, fstab           https://wiki.archlinux.org/title/Fstab
#   systemd-devel mailing list https://lists.freedesktop.org/archives/systemd-devel/
#
#   Lennart Poettering, "systemd for Administrators, Part IV: Killing
#   Services the Right Way" — the Requires/Wants distinction.
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
# ============================================================================

set -o pipefail

FSTAB=/etc/fstab
MOUNT_POINT=/mnt/nvme
TIMEOUT=10

MODE="report"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --report|"") MODE="report" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

main() {
    if [ "$(id -u)" -ne 0 ]; then
        printf 'must be root: sudo %s %s\n' "$0" "$*"
        return 2
    fi

    if ! grep -qE "[[:space:]]$MOUNT_POINT[[:space:]]" "$FSTAB"; then
        printf 'no entry for %s in %s\n' "$MOUNT_POINT" "$FSTAB"
        return 1
    fi

    local line
    line=$(grep -E "[[:space:]]$MOUNT_POINT[[:space:]]" "$FSTAB")
    printf 'current line:\n  %s\n\n' "$line"

    # Evaluate what is present and what is missing.
    local has_nofail=0 has_timeout=0
    case "$line" in
        *nofail*) has_nofail=1 ;;
    esac
    case "$line" in
        *x-systemd.device-timeout*) has_timeout=1 ;;
    esac

    printf 'assessment:\n'
    if [ "$has_nofail" -eq 1 ]; then
        printf '  nofail:                      present\n'
    else
        printf '  nofail:                      ABSENT\n'
        printf '    consequence: boot blocks on the mount. if /dev/nvme0n1p1\n'
        printf '                 is unavailable, local-fs.target fails and the\n'
        printf '                 system enters emergency mode.\n'
    fi
    if [ "$has_timeout" -eq 1 ]; then
        printf '  x-systemd.device-timeout:    present\n'
    else
        printf '  x-systemd.device-timeout:    ABSENT\n'
        printf '    consequence: even with nofail, systemd waits the default\n'
        printf '                 90 seconds for the device before giving up.\n'
    fi

    if [ "$has_nofail" -eq 1 ] && [ "$has_timeout" -eq 1 ]; then
        printf '\nnothing to change.\n'
        return 0
    fi

    printf '\nrecommended line:\n'
    printf '  UUID=812537d8-61a8-424f-a5fb-d37ba443718f %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=%d 0 2\n' \
        "$MOUNT_POINT" "$TIMEOUT"

    if [ "$MODE" = "report" ]; then
        printf '\nreport mode. to apply:\n  sudo %s --apply\n' "$0"
        return 0
    fi

    local ts backup
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    backup="${FSTAB}.${ts}.bak"
    cp "$FSTAB" "$backup"
    printf '\nbackup: %s\n' "$backup"

    python3 - "$FSTAB" "$MOUNT_POINT" "$TIMEOUT" <<'PY_EOF'
import sys
path, mount, timeout = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out = []
for line in lines:
    if mount in line.split() and not line.lstrip().startswith("#"):
        parts = line.split()
        if len(parts) >= 4:
            opts = parts[3].split(",")
            if "nofail" not in opts:
                opts.append("nofail")
            has_to = any(o.startswith("x-systemd.device-timeout") for o in opts)
            if not has_to:
                opts.append(f"x-systemd.device-timeout={timeout}")
            parts[3] = ",".join(opts)
            line = "  ".join(parts) + "\n"
    out.append(line)
with open(path, "w") as f:
    f.writelines(out)
print("fstab updated")
PY_EOF

    printf '\nnew line:\n'
    grep -E "[[:space:]]$MOUNT_POINT[[:space:]]" "$FSTAB" | while IFS= read -r l; do
        printf '  %s\n' "$l"
    done

    printf '\nreloading systemd:\n'
    systemctl daemon-reload
    printf 'verifying mount still works:\n'
    findmnt "$MOUNT_POINT" || true

    printf '\nrollback:\n  sudo cp %s %s\n' "$backup" "$FSTAB"
    return 0
}

main "$@"
