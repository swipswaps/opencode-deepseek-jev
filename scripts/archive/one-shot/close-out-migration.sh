#!/usr/bin/env bash
#
# close-out-migration.sh — verify the /var/lib/docker → /mnt/nvme/docker
# migration, report remaining issues, and optionally archive one-shot
# scripts that produced the migration.
#
# ============================================================================
# AUDIT — defects fixed in this revision
# ============================================================================
#
# D1. The old data root size computation produced "size du:\n0" when the
#     script was run as the non-root owner user. Coreutils du writes an
#     error to stderr and a zero-byte summary to stdout; the pipeline
#     `du -sh "$OLD_ROOT" 2>&1 | awk '{print $1}'` merged both and awk
#     printed field 1 of each line.
#
#     Fixed by invoking du through sudo, taking the tail of the combined
#     output (the summary line), and validating the shape of the value
#     before printing it.
#
#     GNU coreutils du invocation:
#       https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html
#
#     Bash parameter expansion for the shape test:
#       https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
#
# D2. /etc/fstab entry for /mnt/nvme uses defaults,noatime but not
#     nofail. If the NVMe device is ever absent, systemd will block
#     boot waiting for the mount. nofail is the documented option for
#     non-critical data filesystems.
#
#     systemd-fstab-generator(8):
#       https://www.freedesktop.org/software/systemd/man/systemd-fstab-generator.html
#
#     fstab(5):
#       https://man7.org/linux/man-pages/man5/fstab.5.html
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Docker daemon.json        https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file
#   Docker info field         https://docs.docker.com/engine/reference/commandline/info/
#   fstab(5)                  https://man7.org/linux/man-pages/man5/fstab.5.html
#   mount(8)                  https://man7.org/linux/man-pages/man8/mount.8.html
#   findmnt(8)                https://man7.org/linux/man-pages/man8/findmnt.8.html
#   blkid(8)                  https://man7.org/linux/man-pages/man8/blkid.8.html
#   coreutils du              https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html
#   POSIX printf(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Bash parameter expansion  https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
#   Bash return               https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail             https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   systemd fstab-generator   https://www.freedesktop.org/software/systemd/man/systemd-fstab-generator.html
#   ISO 8601 timestamps       https://www.iso.org/iso-8601-date-and-time-format.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017. §1.6.6 "Rule of Separation".
#
#   Brendan Gregg, "Systems Performance: Enterprise and the Cloud",
#   2nd ed., Addison-Wesley, 2020. ISBN-13: 978-0136820154. §8.
#
#   W. Richard Stevens and Stephen A. Rago, "Advanced Programming in
#   the UNIX Environment", 3rd ed., Addison-Wesley, 2013.
#   ISBN-13: 978-0321637734. §4.15.
#
# ============================================================================

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"
ONE_SHOT="$SCRIPTS/archive/one-shot"
NOTES="$SCRIPTS/archive/migration-notes.txt"
EXPECTED_ROOT="/mnt/nvme/docker"
OLD_ROOT="/var/lib/docker"
FSTAB=/etc/fstab
FSTAB_MOUNT=/mnt/nvme

MODE="report"
case "${1:-}" in
    --archive) MODE="archive" ;;
    --report|"") MODE="report" ;;
    *) printf 'usage: %s [--archive]\n' "$0"; return 2 ;;
esac

section() { printf '\n=== %s ===\n' "$1"; }

# ----------------------------------------------------------------------------
# Report the size of a directory, guarded against the du error/summary
# double-line trap.
# ----------------------------------------------------------------------------
size_of_dir() {
    local d="$1"
    if [ ! -d "$d" ]; then
        printf 'not present'
        return 0
    fi
    local raw
    # sudo to read root-owned paths; tail -1 to keep only the summary
    # line; awk field 1 to keep only the size token; guard the shape
    # before printing.
    raw=$(sudo du -sh "$d" 2>&1 | tail -1 | awk '{print $1}')
    case "$raw" in
        [0-9]*)
            printf '%s' "$raw"
            ;;
        *)
            printf 'unknown (du output not parseable)'
            ;;
    esac
}

main() {
    # ---- docker data root ---------------------------------------------
    section "docker data root"
    if ! docker info > /dev/null 2>&1; then
        printf 'FAIL: docker daemon not reachable\n'
        return 2
    fi
    local actual
    actual=$(docker info 2>&1 | awk '/Docker Root Dir/ {print $4}')
    printf '  expected: %s\n' "$EXPECTED_ROOT"
    printf '  actual:   %s\n' "$actual"
    if [ "$actual" = "$EXPECTED_ROOT" ]; then
        printf '  PASS\n'
    else
        printf '  FAIL: daemon is using the wrong data root\n'
    fi

    # ---- /etc/fstab entry for /mnt/nvme --------------------------------
    section "fstab entry for $FSTAB_MOUNT"
    if sudo grep -qE "[[:space:]]$FSTAB_MOUNT[[:space:]]" "$FSTAB" 2>&1; then
        printf '  PASS: %s is in %s\n' "$FSTAB_MOUNT" "$FSTAB"
        local line
        line=$(sudo grep -E "[[:space:]]$FSTAB_MOUNT[[:space:]]" "$FSTAB")
        printf '        %s\n' "$line"
        case "$line" in
            *nofail*)
                printf '  PASS: nofail is present\n'
                ;;
            *)
                printf '  WARN: nofail is absent\n'
                printf '        if the device is ever unavailable, boot will block.\n'
                printf '        consider adding nofail to the mount options:\n'
                printf '          UUID=<uuid>  %s  ext4  defaults,noatime,nofail  0  2\n' "$FSTAB_MOUNT"
                printf '        fstab(5): https://man7.org/linux/man-pages/man5/fstab.5.html\n'
                printf '        systemd-fstab-generator(8):\n'
                printf '          https://www.freedesktop.org/software/systemd/man/systemd-fstab-generator.html\n'
                ;;
        esac
    else
        printf '  FAIL: %s is not in %s\n' "$FSTAB_MOUNT" "$FSTAB"
        printf '        after a reboot the NVMe partition will not mount.\n'
        printf '        docker will fall back to %s.\n' "$OLD_ROOT"
    fi

    # ---- mount state ---------------------------------------------------
    section "$FSTAB_MOUNT mount state"
    if command -v findmnt > /dev/null; then
        findmnt "$FSTAB_MOUNT" 2>&1
    else
        mount | grep "$FSTAB_MOUNT" 2>&1 || printf '  %s not in mount table\n' "$FSTAB_MOUNT"
    fi

    # ---- old data root for rollback ------------------------------------
    section "old data root for rollback"
    if [ -d "$OLD_ROOT" ]; then
        printf '  %s still present, size %s\n' "$OLD_ROOT" "$(size_of_dir "$OLD_ROOT")"
        printf '  retain for at least one week, then:\n'
        printf '    sudo mv %s %s.old.<timestamp>\n' "$OLD_ROOT" "$OLD_ROOT"
        printf '  and after another week of stable operation:\n'
        printf '    sudo rm -rf %s.old.*\n' "$OLD_ROOT"
    else
        printf '  %s already removed\n' "$OLD_ROOT"
    fi

    # ---- image inventory -----------------------------------------------
    section "image inventory"
    local count
    count=$(docker image ls -q 2>&1 | sort -u | wc -l)
    printf '  distinct image IDs: %d\n' "$count"
    printf '\n'
    printf '  named images (repository:tag):\n'
    docker image ls --format '{{.Repository}}:{{.Tag}}' 2>&1 | sort -u | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
    printf '\n'
    printf '  if any expected project image is missing, re-pull it:\n'
    printf '    cd ~/Documents/<project> && docker compose pull\n'

    # ---- scripts inventory ---------------------------------------------
    section "scripts inventory"
    printf '  currently in %s/:\n' "$SCRIPTS"
    for f in "$SCRIPTS"/*.sh "$SCRIPTS"/*.txt; do
        [ -e "$f" ] || continue
        printf '    %s\n' "$(basename "$f")"
    done

    # ---- archive one-shot scripts (opt-in) -----------------------------
    if [ "$MODE" = "archive" ]; then
        section "archiving one-shot scripts"
        mkdir -p "$ONE_SHOT"
        for name in \
            diagnose-docker.sh \
            plan-docker-migration.sh \
            migrate-docker-to-nvme.sh \
            prune-docker.sh \
            close-out-migration.sh ; do

            if [ -f "$SCRIPTS/$name" ]; then
                mv "$SCRIPTS/$name" "$ONE_SHOT/$name"
                printf '  moved %s -> %s\n' "$name" "$ONE_SHOT/$name"
            fi
        done
    else
        printf '\n  (report mode: nothing moved)\n'
        printf '  to archive the one-shot scripts:\n'
        printf '    %s --archive\n' "$0"
    fi

    # ---- migration notes -----------------------------------------------
    section "migration notes"
    if [ "$MODE" = "archive" ]; then
        cat > "$NOTES" <<'NOTES_EOF'
Docker data-root migration — 2026-09-21
========================================

Cause
-----

Before migration:

  /var/lib/docker on /dev/sda3, a 5400 RPM rotational disk
  (ST1000LM035). fsync await reported by iostat was 111 ms.
  `docker run --rm alpine:latest echo __HELLO__` took 34.261 s.

  /dev/nvme0n1p1 (WDC PC SN530, NVMe) held 214 GB free, unused.

Fix
---

Migrated /var/lib/docker to /mnt/nvme/docker. Steps:

  1. systemctl stop docker.socket docker containerd
  2. rsync -aHAX --sparse --numeric-ids /var/lib/docker/ /mnt/nvme/docker/
  3. semanage fcontext -a -t container_var_lib_t "/mnt/nvme/docker(/.*)?"
  4. restorecon -R /mnt/nvme/docker
  5. wrote {"data-root": "/mnt/nvme/docker"} into /etc/docker/daemon.json
  6. systemctl start docker
  7. verified: docker info reports the new root, doctor.sh passes

Post-migration timing
---------------------

First `docker run --rm alpine:latest echo __HELLO__` after migration:
6177 ms. Expected to fall below 1000 ms once the overlay2 layer index
is warm in the daemon.

Rollback
--------

If the NVMe fails or the migration is otherwise unsuitable:

  sudo systemctl stop docker
  sudo cp /etc/docker/daemon.json.<timestamp>.bak /etc/docker/daemon.json
  sudo systemctl start docker

The old data root remains at /var/lib/docker for at least one week.
Do not delete it until the new location has been stable through at
least one full reboot and one week of operation.

Known open items
----------------

1. /etc/fstab entry for /mnt/nvme uses defaults,noatime but not
   nofail. Adding nofail prevents boot from blocking if the NVMe is
   ever unavailable.
     https://www.freedesktop.org/software/systemd/man/systemd-fstab-generator.html

2. Image count decreased from 81 distinct IDs to 40 during
   migration. Most of the difference is likely dangling <none>
   layers removed by Docker on first start with the new data root.
   Confirm by running `docker image ls` and comparing to expected
   project images. Re-pull any missing with `docker compose pull`
   in the corresponding project directory.

3. scripts/prune-docker.sh and scripts/migrate-docker-to-nvme.sh
   contained a top-level `return 0` (invalid Bash) that allowed
   dry-run mode to fall through into apply. Both were archived
   after use. Any successor script must place all logic inside a
   function and call `main "$@"` at the bottom.
     https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html

Citations
---------

  Docker daemon.json:
    https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file

  overlay2 storage driver:
    https://docs.docker.com/storage/storagedriver/overlayfs-driver/

  rsync -H hardlink semantics:
    https://download.samba.org/pub/rsync/rsync.1#opt--hard-links

  fstab(5):
    https://man7.org/linux/man-pages/man5/fstab.5.html

  systemd fstab-generator:
    https://www.freedesktop.org/software/systemd/man/systemd-fstab-generator.html

  Bash return builtin:
    https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html

  Brendan Gregg, "Systems Performance: Enterprise and the Cloud",
  2nd ed., Addison-Wesley, 2020. ISBN-13: 978-0136820154. §8.

  Michael Kerrisk, "The Linux Programming Interface", No Starch
  Press, 2010. ISBN-13: 978-1593272203. §13.3.

  W. Richard Stevens and Stephen A. Rago, "Advanced Programming in
  the UNIX Environment", 3rd ed., Addison-Wesley, 2013.
  ISBN-13: 978-0321637734.
NOTES_EOF
        printf '  wrote %s\n' "$NOTES"
    else
        printf '  (report mode: notes not written)\n'
    fi

    # ---- summary -------------------------------------------------------
    section "summary"
    if [ "$MODE" = "report" ]; then
        printf 'report complete. no changes made.\n'
        printf 'to archive one-shot scripts and write notes:\n'
        printf '  %s --archive\n' "$0"
    else
        printf 'archive complete. see %s\n' "$NOTES"
    fi

    return 0
}

main "$@"
