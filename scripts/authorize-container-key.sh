#!/usr/bin/env bash
#
# authorize-container-key.sh — RUN ON THE HOST.
#
# The web container writes its current public key to <repo>/container-key.pub.
# This appends it to ~/.ssh/authorized_keys (0600) so the container can SSH
# back to the host after a recreate. Only the public key is read; nothing is
# printed except its fingerprint.
#
# Usage:
#   ./scripts/authorize-container-key.sh
#   ./scripts/authorize-container-key.sh /path/to/key.pub
#   RESTRICT=0 ./scripts/authorize-container-key.sh /path/to/key.pub
#
# Default is RESTRICT=1: OpenSSH `restrict` disables port/agent/X11/pty
# forwarding, user rc files, and tunnels for this key. Set RESTRICT=0 only for
# a trusted, local-only key.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${1:-$REPO/container-key.pub}"
AUTH="$HOME/.ssh/authorized_keys"
RESTRICT="${RESTRICT:-1}"

[ -f "$KEY" ] || { printf 'missing public key: %s\n' "$KEY" >&2; exit 2; }
command -v ssh-keygen >/dev/null || { printf 'ssh-keygen missing on host\n' >&2; exit 2; }
mkdir -p "$HOME/.ssh" || exit 2
chmod 700 "$HOME/.ssh"
[ -f "$AUTH" ] || : > "$AUTH"
chmod 600 "$AUTH"

if grep -qF "$(cat "$KEY")" "$AUTH"; then
    printf 'already authorized: '
else
    # An existing last line without a trailing newline would swallow the new
    # key into the previous entry. Guarantee a line boundary first.
    if [ -s "$AUTH" ] && [ -n "$(tail -c 1 "$AUTH")" ]; then
        printf '\n' >> "$AUTH"
    fi
    if [ "$RESTRICT" -eq 1 ]; then printf 'restrict ' >> "$AUTH"; fi
    cat "$KEY" >> "$AUTH" || { printf 'could not append to %s\n' "$AUTH" >&2; exit 2; }
    printf 'authorized: '
fi
ssh-keygen -lf "$KEY"
case "$KEY" in
    "$REPO"/container-key.pub) rm -f "$KEY" ;;
esac
printf 'container key added to %s (mode 600)\n' "$AUTH"
