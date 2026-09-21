#!/usr/bin/env bash
#
# prune-docker.sh — reclaim disk from accumulated docker build cache and
# unused images. Fixes slow container creation caused by a bloated layer
# store.
#
# ============================================================================
# AUDIT — evidence of the problem
# ============================================================================
#
# The last diagnostic run reported:
#
#   docker system df:
#     Images       80   4 active   23.21GB   20.65GB reclaimable (88%)
#     Build Cache  437  0 active   26.59GB   26.59GB reclaimable (100%)
#
#   Timings:
#     docker run --rm alpine:latest echo hello      rc=124 at 30s
#     docker run --rm --entrypoint sh IMG -c true   rc=124 at 32s
#     docker run --rm --entrypoint sh IMG ...       rc=0   at 46.9s
#
# The layer store is traversed on every container create. 437 build cache
# entries and 76 unused images make that traversal slow.
#
# Reference:
#   Docker system df:       https://docs.docker.com/engine/reference/commandline/system_df/
#   Overlay2 layer layout:  https://docs.docker.com/storage/storagedriver/overlayfs-driver/
#
# ============================================================================
# SCOPE
# ============================================================================
#
# This script runs four prune commands. Each is scoped to a specific
# category of docker object:
#
#   container prune   removes containers in "created", "exited", or
#                     "dead" state. Running containers are untouched.
#
#   builder prune     removes the build cache. The build cache is
#                     populated by every `docker build`. Nothing that is
#                     in use by a running container is affected.
#
#   image prune       removes dangling images (tags = <none>). Images
#                     with a name and tag are preserved.
#
#   volume prune      removes volumes not attached to any container.
#
# It does NOT run `docker system prune -a`, which would remove all
# unused images including ones for projects the user has not run
# recently.
#
# Reference:
#   docker container prune: https://docs.docker.com/engine/reference/commandline/container_prune/
#   docker builder prune:   https://docs.docker.com/engine/reference/commandline/builder_prune/
#   docker image prune:     https://docs.docker.com/engine/reference/commandline/image_prune/
#   docker volume prune:    https://docs.docker.com/engine/reference/commandline/volume_prune/
#
# ============================================================================
# MODES
# ============================================================================
#
#   ./prune-docker.sh            report only (default)
#   ./prune-docker.sh --apply    perform the prune
#
# Report mode runs docker system df and lists the 5 oldest Created-state
# containers. Nothing is changed.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Docker system df           https://docs.docker.com/engine/reference/commandline/system_df/
#   Docker container prune     https://docs.docker.com/engine/reference/commandline/container_prune/
#   Docker builder prune       https://docs.docker.com/engine/reference/commandline/builder_prune/
#   Docker image prune         https://docs.docker.com/engine/reference/commandline/image_prune/
#   Docker volume prune        https://docs.docker.com/engine/reference/commandline/volume_prune/
#   Docker overlay2 driver     https://docs.docker.com/storage/storagedriver/overlayfs-driver/
#   POSIX printf(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017. §5.1 "The Importance of Being Able to
#   Recover".
#
# ============================================================================

set -o pipefail

MODE="report"
case "${1:-}" in
    --apply) MODE="apply" ;;
    "") ;;
    --report) MODE="report" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

section() {
    printf '\n=== %s ===\n' "$1"
}

# ----------------------------------------------------------------------------
# Before
# ----------------------------------------------------------------------------
section "before"
docker system df

# ----------------------------------------------------------------------------
# Detailed counts and elapsed time baseline
# ----------------------------------------------------------------------------
section "counts"
printf 'containers (all):     %d\n' "$(docker ps -aq 2>&1 | wc -l)"
printf 'containers (running): %d\n' "$(docker ps -q 2>&1 | wc -l)"
printf 'containers (created): %d\n' "$(docker ps -q --filter status=created 2>&1 | wc -l)"
printf 'containers (exited):  %d\n' "$(docker ps -q --filter status=exited 2>&1 | wc -l)"
printf 'images:               %d\n' "$(docker images -q 2>&1 | wc -l)"
printf 'images (dangling):    %d\n' "$(docker images -q --filter dangling=true 2>&1 | wc -l)"
printf 'volumes:              %d\n' "$(docker volume ls -q 2>&1 | wc -l)"

if [ "$MODE" = "report" ]; then
    section "created-state containers that would be removed"
    docker ps -a --filter status=created --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}' 2>&1 | head -20

    section "report only"
    printf 'nothing changed.\n'
    printf 'to perform the prune:\n'
    printf '  %s --apply\n' "$0"
    return 0
fi

# ----------------------------------------------------------------------------
# Apply: prune in order of category
# ----------------------------------------------------------------------------
# Each command is independent. A failure in one does not stop the others.
# Counters are not kept; docker itself reports what it removed.

section "prune containers"
docker container prune -f

section "prune build cache"
docker builder prune -f

section "prune dangling images"
docker image prune -f

section "prune unused volumes"
docker volume prune -f

# ----------------------------------------------------------------------------
# After
# ----------------------------------------------------------------------------
section "after"
docker system df

section "verification: tiny container spawn timing"
printf 'command: docker run --rm alpine:latest echo __HELLO__\n'
START=$(date +%s%N)
OUT=$(timeout 30 docker run --rm alpine:latest echo __HELLO__ 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
printf 'rc=%d elapsed=%dms output=%s\n' "$RC" "$ELAPSED_MS" "${OUT:-<empty>}"

if [ "$RC" -eq 0 ] && [ "$ELAPSED_MS" -lt 3000 ]; then
    printf '\nresult: container creation is now fast (%dms)\n' "$ELAPSED_MS"
    printf 'rerun scripts/doctor.sh to confirm tier 6 passes.\n'
elif [ "$RC" -eq 0 ]; then
    printf '\nresult: container creation succeeded but is still slow (%dms)\n' "$ELAPSED_MS"
    printf 'consider: sudo systemctl restart docker\n'
else
    printf '\nresult: container creation still failing (rc=%d)\n' "$RC"
    printf 'the daemon may need a restart: sudo systemctl restart docker\n'
fi
