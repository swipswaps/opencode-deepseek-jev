#!/usr/bin/env bash
#
# diagnose-docker.sh — isolate why a docker container spawn is slow or
# empty. Run this before touching doctor.sh again.
#
# ============================================================================
# AUDIT — what the symptom looks like
# ============================================================================
#
# In the last doctor.sh run, all three `docker run` variants returned
# rc=124 (timeout) with zero bytes of output. In the run 11 minutes
# earlier, the same invocations succeeded in under one second.
#
# That is not a code defect. Something about the host changed:
#
#   - containers accumulated (each spawn allocates overlay layers)
#   - the disk hosting /var/lib/docker filled
#   - the daemon entered a degraded state
#   - the kernel throttled the daemon (OOM pressure)
#
# This script gathers the evidence needed to choose the fix.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Docker ps             https://docs.docker.com/engine/reference/commandline/ps/
#   Docker container prune https://docs.docker.com/engine/reference/commandline/container_prune/
#   Docker image prune    https://docs.docker.com/engine/reference/commandline/image_prune/
#   Docker system df      https://docs.docker.com/engine/reference/commandline/system_df/
#   Docker info           https://docs.docker.com/engine/reference/commandline/info/
#   POSIX df(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/df.html
#   POSIX du(1)           https://pubs.opengroup.org/onlinepubs/9699919799/utilities/du.html
#   POSIX time(1)         https://pubs.opengroup.org/onlinepubs/9699919799/utilities/time.html
#   Linux free(1)         https://man7.org/linux/man-pages/man1/free.1.html
#   Linux uptime(1)       https://man7.org/linux/man-pages/man1/uptime.1.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017. §1.6.3 "Rule of Composition".
#
# ============================================================================

set -o pipefail

IMAGE="opencode-deepseek-jev:robust"
TINY_IMAGE="alpine:latest"

section() {
    printf '\n=== %s ===\n' "$1"
}

# ----------------------------------------------------------------------------
# 1. System load and memory
# ----------------------------------------------------------------------------
section "system load and memory"
uptime
printf '\n'
free -h
printf '\n'

# ----------------------------------------------------------------------------
# 2. Disk hosting docker
# ----------------------------------------------------------------------------
section "disk"
df -h /var/lib/docker 2>&1 || df -h / 2>&1
printf '\n'

# ----------------------------------------------------------------------------
# 3. Docker object counts
# ----------------------------------------------------------------------------
section "docker object counts"
printf 'containers (all):      %s\n' "$(docker ps -aq 2>&1 | wc -l)"
printf 'containers (running):  %s\n' "$(docker ps -q 2>&1 | wc -l)"
printf 'images:                %s\n' "$(docker images -q 2>&1 | wc -l)"
printf 'volumes:               %s\n' "$(docker volume ls -q 2>&1 | wc -l)"
printf 'networks:              %s\n' "$(docker network ls -q 2>&1 | wc -l)"
printf '\n'

section "docker system df"
docker system df 2>&1
printf '\n'

# ----------------------------------------------------------------------------
# 4. Docker daemon state
# ----------------------------------------------------------------------------
section "docker info summary"
docker info 2>&1 | grep -E 'Server Version|Storage Driver|Cgroup|Total Memory|CPUs|Containers|Images|Running|Paused|Stopped' || docker info 2>&1 | head -30
printf '\n'

# ----------------------------------------------------------------------------
# 5. Tiny container spawn test — is docker globally slow?
# ----------------------------------------------------------------------------
section "tiny container spawn test (alpine:latest)"
printf 'command: docker run --rm alpine:latest echo __HELLO__\n'
START=$(date +%s%N)
OUT=$(timeout 30 docker run --rm "$TINY_IMAGE" echo __HELLO__ 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
printf 'rc=%d elapsed=%dms output=%s\n' "$RC" "$ELAPSED_MS" "${OUT:-<empty>}"
printf '\n'

# ----------------------------------------------------------------------------
# 6. OpenCode image spawn test — is this specific image slow?
# ----------------------------------------------------------------------------
section "opencode image spawn test (no opencode, just /bin/true)"
printf 'command: docker run --rm --entrypoint sh %s -c "true"\n' "$IMAGE"
START=$(date +%s%N)
OUT=$(timeout 30 docker run --rm --entrypoint sh "$IMAGE" -c 'true' 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
printf 'rc=%d elapsed=%dms output=%s\n' "$RC" "$ELAPSED_MS" "${OUT:-<empty>}"
printf '\n'

# ----------------------------------------------------------------------------
# 7. OpenCode binary spawn test
# ----------------------------------------------------------------------------
section "opencode --version with 60s timeout"
printf 'command: docker run --rm --entrypoint sh %s -c "opencode --version; :"\n' "$IMAGE"
START=$(date +%s%N)
OUT=$(timeout 60 docker run --rm --entrypoint sh "$IMAGE" -c 'opencode --version; :' 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
printf 'rc=%d elapsed=%dms output=%s\n' "$RC" "$ELAPSED_MS" "${OUT:-<empty>}"
printf '\n'

# ----------------------------------------------------------------------------
# 8. Container list (last 20)
# ----------------------------------------------------------------------------
section "last 20 containers"
docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' 2>&1 | head -25
printf '\n'

# ----------------------------------------------------------------------------
# 9. Recent docker daemon log lines (last 20)
# ----------------------------------------------------------------------------
section "dockerd recent log lines"
if command -v journalctl > /dev/null; then
    journalctl -u docker.service --since '30 minutes ago' --no-pager 2>&1 | tail -20
else
    printf 'journalctl not available\n'
fi
printf '\n'

# ----------------------------------------------------------------------------
# 10. Summary and suggested fix
# ----------------------------------------------------------------------------
section "summary"

CONTAINERS=$(docker ps -aq 2>&1 | wc -l)
IMAGES=$(docker images -q 2>&1 | wc -l)

if [ "$CONTAINERS" -gt 50 ]; then
    printf 'containers accumulated: %d\n' "$CONTAINERS"
    printf '  suggested: docker container prune -f\n'
fi
if [ "$IMAGES" -gt 100 ]; then
    printf 'images accumulated: %d\n' "$IMAGES"
    printf '  suggested: docker image prune -f\n'
fi

DF_USE=$(df --output=pcent /var/lib/docker 2>&1 | tail -1 | tr -d ' %')
if [ -n "$DF_USE" ] && [ "$DF_USE" -gt 85 ] 2>/dev/null; then
    printf 'disk /var/lib/docker is %s%% full\n' "$DF_USE"
    printf '  suggested: docker system prune -a -f (removes unused images and volumes)\n'
fi

printf '\nprobe results above determine the fix.\n'
printf 'if section 5 (tiny container) also shows rc=124 with empty output,\n'
printf 'the daemon is degraded and needs pruning or restart:\n'
printf '  sudo systemctl restart docker\n'
