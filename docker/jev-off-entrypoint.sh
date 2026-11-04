#!/bin/sh
#
# jev-off-entrypoint.sh — interactive container: apply JEV-OFF, then opencode.
#
# The image installs jev-guard globally, so the global config must be patched at
# every start (see patch-global-config.sh). The web service uses
# web-entrypoint.sh, which calls the same patch.
#
set -u

if [ -f /workspace/docker/patch-global-config.sh ]; then
    sh /workspace/docker/patch-global-config.sh || printf '[jev-off] global config patch failed (continuing)\n' >&2
fi
if [ -f /workspace/docker/patch-jev-guard.sh ]; then
    sh /workspace/docker/patch-jev-guard.sh || printf '[jev-off] jev-guard patch failed (continuing)\n' >&2
fi

exec opencode "$@"
