#!/usr/bin/env bash
#
# plan-docker-migration.sh — read-only survey of the storage layout.
# Gathers the facts needed before migrating /var/lib/docker to NVMe.
# Does not change anything.
#
# ============================================================================
# AUDIT — why this script exists
# ============================================================================
#
# Evidence:
#
#   lsblk -o NAME,ROTA,MODEL /dev/sda
#     sda   1  ST1000LM035-1RK172  931.5G   /home
#
#   iostat -x sda:
#     f_await 111.47 ms     ← flush await is 111 ms per fsync
#     %util   23.10
#
#   time docker run --rm alpine:latest echo __HELLO__
#     real 0m34.261s
#
# ST1000LM035 is a Seagate 5400 RPM 2.5-inch mobile HDD:
#   https://www.seagate.com/content/dam/seagate/migrated-assets/www-content/product-content/laptop-hdd/_shared/docs/100807760g.pdf
#
# ROTA=1 in /sys/block/<dev>/queue/rotational means rotational.
#   Linux kernel block layer documentation:
#   https://www.kernel.org/doc/Documentation/block/queue-sysfs.rst
#
# f_await is the average flush request await time in milliseconds,
# reported by iostat. Values above 20 ms indicate a saturated or slow
# device for a workload that issues fsync.
#   sysstat iostat manual:
#   https://sysstat.github.io/man-pages/iostat.5.html
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Linux lsblk(8)         https://man7.org/linux/man-pages/man8/lsblk.8.html
#   Linux blkid(8)         https://man7.org/linux/man-pages/man8/blkid.8.html
#   POSIX df(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/df.html
#   POSIX du(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/du.html
#   POSIX find(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   Docker daemon.json     https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file
#
#   Brendan Gregg, "Systems Performance: Enterprise and the Cloud",
#   2nd ed., Addison-Wesley, 2020. ISBN-13: 978-0136820154.
#     Chapter 8 "File Systems" — flush latency as a first-order metric.
#
#   Michael Kerrisk, "The Linux Programming Interface", No Starch Press,
#   2010. ISBN-13: 978-1593272203.
#     §13.3 "Buffered I/O and Kernel Buffering" — why fsync blocks.
#
# ============================================================================

set -o pipefail

section() {
    printf '\n=== %s ===\n' "$1"
}

section "block devices"
lsblk -o NAME,ROTA,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL

section "rotational status"
for dev in /sys/block/sd* /sys/block/nvme*; do
    [ -e "$dev" ] || continue
    name=$(basename "$dev")
    rot=$(cat "$dev/queue/rotational" 2>&1)
    sched=$(cat "$dev/queue/scheduler" 2>&1)
    printf '  %-12s rotational=%s scheduler=%s\n' "$name" "$rot" "$sched"
done

section "filesystem usage"
df -hT / /home /var/lib/docker /boot 2>&1

section "docker data directory"
if [ -d /var/lib/docker ]; then
    printf 'path:     /var/lib/docker\n'
    printf 'device:   %s\n' "$(df --output=source /var/lib/docker | tail -1)"
    printf 'usage:\n'
    du -sh /var/lib/docker 2>&1
    printf 'top-level contents:\n'
    du -sh /var/lib/docker/* 2>&1 | sort -h | tail -10
fi

section "nvme devices — current use"
for dev in /sys/block/nvme*n*; do
    [ -e "$dev" ] || continue
    name=$(basename "$dev")
    printf '  %s\n' "$name"
    lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "/dev/$name" 2>&1 | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
done

section "nvme free space"
df -hT /dev/nvme* 2>&1 || printf '  no mounted nvme partitions\n'

section "current docker data-root setting"
if [ -f /etc/docker/daemon.json ]; then
    printf '/etc/docker/daemon.json:\n'
    cat /etc/docker/daemon.json
else
    printf '/etc/docker/daemon.json not present. data-root defaults to /var/lib/docker\n'
fi

section "recommendation"
NVME_FREE=$(df -BG /dev/nvme0n1p3 2>&1 | tail -1 | awk '{print $4}' | tr -d 'G')
DOCKER_SIZE_KB=$(du -sk /var/lib/docker 2>&1 | awk '{print $1}')
DOCKER_SIZE_GB=$(( DOCKER_SIZE_KB / 1024 / 1024 ))

printf 'docker data size:  %d GB\n' "$DOCKER_SIZE_GB"
printf 'nvme0n1p3 free:    %s GB\n' "${NVME_FREE:-unknown}"
printf '\n'
printf 'if nvme free space > docker data size, migration is safe.\n'
printf 'procedure:\n'
printf '  1. sudo systemctl stop docker docker.socket containerd\n'
printf '  2. sudo rsync -aHAX --progress /var/lib/docker/ /mnt/nvme/docker/\n'
printf '  3. write /etc/docker/daemon.json with {"data-root": "/mnt/nvme/docker"}\n'
printf '  4. sudo systemctl start docker\n'
printf '  5. verify: docker system df, docker ps\n'
printf '  6. after verification, remove /var/lib/docker (do not run until step 5 passes)\n'
