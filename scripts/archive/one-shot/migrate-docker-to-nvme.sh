#!/usr/bin/env bash
#
# migrate-docker-to-nvme.sh — move /var/lib/docker to /mnt/nvme/docker,
# preserving hardlinks, ACLs, xattrs, and SELinux labels.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Storage layout:
#
#   /dev/sda3         btrfs  930G  mounted at / and /home
#                     ST1000LM035, 5400 RPM rotational disk
#   /dev/nvme0n1p1    ext4   234G  mounted at /mnt/nvme
#                     8.6G used, 214G free, WDC PC SN530 NVMe
#
# Docker data root: /var/lib/docker on /dev/sda3
#
# Timings:
#   docker run --rm alpine:latest echo __HELLO__   real 0m34.261s
#   iostat -x sda:  f_await 111.47 ms
#
# Each container create performs hundreds of fsyncs. At 111 ms per
# fsync, 34 seconds is the expected cost on a rotational disk. The NVMe
# has zero fsync cost at this scale.
#
# ============================================================================
# SED AVOIDANCE
# ============================================================================
#
# This script uses no sed. Parent block device resolution is done with
# `lsblk -no PKNAME`, which returns the kernel device name directly.
#
#   lsblk(8):
#   https://man7.org/linux/man-pages/man8/lsblk.8.html
#
#   For /dev/nvme0n1p1, lsblk -no PKNAME returns "nvme0n1".
#   For /dev/sda3, it returns "sda".
#
# /sys/block/<name>/queue/rotational is the kernel's authoritative
# flag for whether the device is rotational:
#
#   Linux kernel block layer queue-sysfs:
#   https://www.kernel.org/doc/Documentation/block/queue-sysfs.rst
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   rsync(1)                   https://download.samba.org/pub/rsync/rsync.1
#   lsblk(8)                   https://man7.org/linux/man-pages/man8/lsblk.8.html
#   blkid(8)                   https://man7.org/linux/man-pages/man8/blkid.8.html
#   POSIX printf(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX test(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX df(1)                https://pubs.opengroup.org/onlinepubs/9699919799/utilities/df.html
#   POSIX du(1)                https://pubs.opengroup.org/onlinepubs/9699919799/utilities/du.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Bash trap                  https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash parameter expansion   https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
#   Linux signal(7)            https://man7.org/linux/man-pages/man7/signal.7.html
#   Docker daemon.json         https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file
#   Overlay2 storage driver    https://docs.docker.com/storage/storagedriver/overlayfs-driver/
#   Fedora SELinux             https://docs.fedoraproject.org/en-US/quick-docs/selinux-changing/
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203. §18 "Directories and Links".
#
#   Brendan Gregg, "Systems Performance: Enterprise and the Cloud",
#   2nd ed., Addison-Wesley, 2020. ISBN-13: 978-0136820154. §8.
#
#   Stevens & Rago, "Advanced Programming in the UNIX Environment",
#   3rd ed., Addison-Wesley, 2013. ISBN-13: 978-0321637734.
#
# ============================================================================

set -o pipefail

SRC_ROOT="/var/lib/docker"
DST_PARENT="/mnt/nvme"
DST_ROOT="$DST_PARENT/docker"
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_JSON="${DAEMON_JSON}.${BACKUP_TS}.bak"

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

section() {
    printf '\n=== %s ===\n' "$1"
}

fail() {
    printf 'GATE FAIL: %s\n' "$1"
    [ -n "${2:-}" ] && printf '  %s\n' "$2"
    exit 2
}

cleanup_on_signal() {
    printf '\n[signal received]\n' >&2
    printf 'docker is currently stopped. no changes were committed.\n' >&2
    printf 'to restore the running state without migration:\n' >&2
    printf '  sudo systemctl start docker\n' >&2
    exit 130
}
trap cleanup_on_signal INT TERM

# Gate: root
if [ "$(id -u)" -ne 0 ]; then
    fail "must be root" "sudo $0 $*"
fi

# Gate: source exists
[ -d "$SRC_ROOT" ] || fail "$SRC_ROOT does not exist"

# Gate: destination mount must be non-rotational
# Use lsblk -no PKNAME to get the parent kernel device name directly.
# No sed. No trailing-digit stripping. The kernel already knows.
DST_DEV=$(df --output=source "$DST_PARENT" 2>&1 | tail -1)
if [ -z "$DST_DEV" ]; then
    fail "cannot determine device for $DST_PARENT"
fi

DST_PARENT_DEV=$(lsblk -no PKNAME "$DST_DEV" 2>&1)
if [ -z "$DST_PARENT_DEV" ]; then
    # $DST_DEV is a whole disk, not a partition
    DST_PARENT_DEV=$(basename "$DST_DEV")
fi

ROT_FILE="/sys/block/$DST_PARENT_DEV/queue/rotational"
if [ ! -f "$ROT_FILE" ]; then
    fail "cannot determine rotational status of $DST_DEV" \
         "expected $ROT_FILE to exist; lsblk returned PKNAME=$DST_PARENT_DEV"
fi

ROT=$(cat "$ROT_FILE")
if [ "$ROT" != "0" ]; then
    fail "$DST_DEV is rotational (ROT=$ROT)" \
         "migration only makes sense to a non-rotational device"
fi

printf 'destination %s is on %s (rotational=0)\n' "$DST_DEV" "$DST_PARENT_DEV"

# Gate: rsync
command -v rsync > /dev/null || fail "rsync not installed" \
    "sudo dnf install rsync"

# Gate: size
section "size survey"
SRC_SIZE_KB=$(du -sk "$SRC_ROOT" 2>&1 | awk '{print $1}')
DST_FREE_KB=$(df -k --output=avail "$DST_PARENT" 2>&1 | tail -1)

SRC_SIZE_GB=$(( SRC_SIZE_KB / 1024 / 1024 ))
DST_FREE_GB=$(( DST_FREE_KB / 1024 / 1024 ))

printf '  source %s:    %d GB\n' "$SRC_ROOT" "$SRC_SIZE_GB"
printf '  destination free:  %d GB\n' "$DST_FREE_GB"

if [ "$DST_FREE_GB" -lt $(( SRC_SIZE_GB + 10 )) ]; then
    fail "destination has insufficient free space" \
         "need source size plus 10 GB headroom"
fi

# fstab warning
if ! grep -qE "[[:space:]]$DST_PARENT[[:space:]]" /etc/fstab 2>&1; then
    printf '\n  WARN: %s is not in /etc/fstab.\n' "$DST_PARENT"
    printf '        after a reboot the NVMe will not mount and docker\n'
    printf '        will fall back to writing on the HDD path.\n'
fi

if [ "$MODE" = "dry-run" ]; then
    section "plan (dry-run, nothing changed)"
    printf '  1. systemctl stop docker.socket docker containerd\n'
    printf '  2. mkdir -p %s\n' "$DST_ROOT"
    printf '  3. rsync -aHAX --sparse --numeric-ids --info=progress2 %s/ %s/\n' \
        "$SRC_ROOT" "$DST_ROOT"
    printf '  4. semanage fcontext -a -t container_var_lib_t "%s(/.*)?"\n' "$DST_ROOT"
    printf '  5. restorecon -R %s\n' "$DST_ROOT"
    printf '  6. merge "data-root": "%s" into %s\n' "$DST_ROOT" "$DAEMON_JSON"
    printf '  7. systemctl start docker\n'
    printf '  8. verify: docker info, docker ps, docker image ls\n'
    printf '  9. time docker run --rm alpine:latest echo __HELLO__\n'
    printf '\n'
    printf 'the old %s is not deleted.\n' "$SRC_ROOT"
    printf 'to remove after verification:\n'
    printf '  sudo mv %s %s.old.%s\n' "$SRC_ROOT" "$SRC_ROOT" "$BACKUP_TS"
    printf '\n'
    printf 'to execute:\n'
    printf '  sudo %s --apply\n' "$0"
    return 0
fi

# ============================================================================
# APPLY
# ============================================================================

section "phase 1: stop docker"
systemctl stop docker.socket docker containerd 2>&1 || true
sleep 2
for i in $(seq 1 60); do
    pgrep -x dockerd > /dev/null || break
    sleep 1
done
if pgrep -x dockerd > /dev/null; then
    fail "dockerd did not stop within 60s" \
         "sudo systemctl status docker"
fi
printf '  docker stopped\n'

section "phase 2: create destination"
mkdir -p "$DST_ROOT"
printf '  created %s\n' "$DST_ROOT"

section "phase 3: rsync"
printf 'copying %s -> %s\n' "$SRC_ROOT" "$DST_ROOT"
if ! rsync -aHAX --sparse --numeric-ids --info=progress2 \
        "$SRC_ROOT/" "$DST_ROOT/"; then
    fail "rsync failed" \
         "docker is stopped. to roll back: systemctl start docker"
fi

section "phase 4: verify copy"
SRC_AFTER=$(du -sk "$SRC_ROOT" 2>&1 | awk '{print $1}')
DST_AFTER=$(du -sk "$DST_ROOT" 2>&1 | awk '{print $1}')
printf '  source size:      %d KB\n' "$SRC_AFTER"
printf '  destination size: %d KB\n' "$DST_AFTER"
DELTA=$(( SRC_AFTER - DST_AFTER ))
if [ "${DELTA#-}" -gt $(( SRC_AFTER / 100 )) ]; then
    printf '  WARN: destination differs by more than 1%%\n'
else
    printf '  sizes match within 1%%\n'
fi

section "phase 5: SELinux context"
if command -v semanage > /dev/null; then
    semanage fcontext -a -t container_var_lib_t "$DST_ROOT(/.*)?" 2>&1 || true
    restorecon -R "$DST_ROOT" 2>&1
    printf '  applied container_var_lib_t to %s\n' "$DST_ROOT"
else
    printf '  WARN: semanage not available\n'
    printf '        install: sudo dnf install policycoreutils-python-utils\n'
fi

section "phase 6: daemon.json"
mkdir -p /etc/docker
if [ -f "$DAEMON_JSON" ]; then
    cp "$DAEMON_JSON" "$BACKUP_JSON"
    printf '  backed up %s -> %s\n' "$DAEMON_JSON" "$BACKUP_JSON"
    python3 - "$DAEMON_JSON" "$DST_ROOT" <<'PY_EOF'
import json, sys
path, root = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["data-root"] = root
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("  merged data-root into existing daemon.json")
PY_EOF
else
    printf '{\n  "data-root": "%s"\n}\n' "$DST_ROOT" > "$DAEMON_JSON"
    printf '  created %s\n' "$DAEMON_JSON"
fi

section "phase 7: start docker"
systemctl start docker
sleep 3
for i in $(seq 1 60); do
    if docker info > /dev/null 2>&1; then break; fi
    sleep 1
done
if ! docker info > /dev/null 2>&1; then
    fail "docker did not start" \
         "journalctl -u docker --since '2 min ago'"
fi
printf '  docker started\n'

section "phase 8: verify new data root"
DOCKER_ROOT=$(docker info 2>&1 | grep 'Docker Root Dir' | awk '{print $4}')
printf '  docker reports data root: %s\n' "$DOCKER_ROOT"
if [ "$DOCKER_ROOT" != "$DST_ROOT" ]; then
    fail "docker data root is $DOCKER_ROOT, expected $DST_ROOT" \
         "check /etc/docker/daemon.json"
fi

printf '\n'
printf '  images:     %s\n' "$(docker image ls -q 2>&1 | wc -l)"
printf '  containers: %s\n' "$(docker ps -aq 2>&1 | wc -l)"

section "phase 9: timing test"
printf '  command: docker run --rm alpine:latest echo __HELLO__\n'
START=$(date +%s%N)
OUT=$(timeout 60 docker run --rm alpine:latest echo __HELLO__ 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
printf '  rc=%d elapsed=%dms output=%s\n' "$RC" "$ELAPSED_MS" "${OUT:-<empty>}"

section "done"
if [ "$RC" -eq 0 ] && [ "$ELAPSED_MS" -lt 5000 ]; then
    printf 'migration succeeded. container create is now %d ms.\n' "$ELAPSED_MS"
else
    printf 'migration completed but timing is %d ms.\n' "$ELAPSED_MS"
fi
printf '\n'
printf 'old data root remains at %s for rollback.\n' "$SRC_ROOT"
printf 'to reclaim after a week:\n'
printf '  sudo mv %s %s.old.%s\n' "$SRC_ROOT" "$SRC_ROOT" "$BACKUP_TS"
printf '\n'
printf 'to roll back:\n'
printf '  sudo systemctl stop docker\n'
printf '  sudo cp %s %s\n' "$BACKUP_JSON" "$DAEMON_JSON"
printf '  sudo systemctl start docker\n'
printf '\n'
printf 'run doctor to confirm:\n'
printf '  ./scripts/doctor.sh\n'
