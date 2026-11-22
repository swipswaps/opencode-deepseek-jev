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
#   ./scripts/authorize-container-key.sh --tighten /path/to/key.pub
#   ./scripts/authorize-container-key.sh --self-test
#
# Default is RESTRICT=1: OpenSSH `restrict` disables port/agent/X11/pty
# forwarding, user rc files, and tunnels for this key. Set RESTRICT=0 only for
# a trusted, local-only key. `--tighten` adds `restrict` to an existing entry
# (OPS-6): the old script skipped a key it had already appended.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH="$HOME/.ssh/authorized_keys"
RESTRICT="${RESTRICT:-1}"
WANT=add
case "${1:-}" in
    --tighten) WANT=tighten; shift ;;
    --self-test) WANT=selftest; shift ;;
esac
KEY="${1:-$REPO/container-key.pub}"

tighten_key() {
  python3 - "$AUTH" "$KEY" <<'PY'
import sys
auth, key = sys.argv[1], sys.argv[2]
with open(key, encoding="utf-8") as fh:
    body = fh.read().strip()
lines = open(auth, encoding="utf-8").read().splitlines(keepends=True)
hits = [i for i, line in enumerate(lines) if body in line]
if len(hits) != 1:
    sys.stderr.write("expected exactly one key line, found %d\n" % len(hits))
    raise SystemExit(3)
i = hits[0]
stripped = lines[i].lstrip()
if stripped.split()[0].startswith("restrict"):
    raise SystemExit(4)
prefix = lines[i][:len(lines[i]) - len(stripped)]
if stripped.split()[0].startswith(("ssh-", "ecdsa-", "sk-")):
    lines[i] = prefix + "restrict " + stripped
else:
    lines[i] = prefix + "restrict," + stripped
with open(auth, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
PY
}

verify_tight() {
  python3 - "$AUTH" "$KEY" <<'PY'
import sys
with open(sys.argv[2], encoding="utf-8") as fh:
    body = fh.read().strip()
hits = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if body in l]
assert len(hits) == 1 and hits[0].lstrip().split()[0].startswith("restrict"), "verification failed"
PY
}

do_tighten() {
  local bak ts trc
  [ -f "$KEY" ] || { printf 'missing public key: %s\n' "$KEY" >&2; return 2; }
  [ -f "$AUTH" ] || { printf 'no authorized_keys at %s\n' "$AUTH" >&2; return 2; }
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  bak="$AUTH.$ts.bak"
  cp -a "$AUTH" "$bak" || return 2
  tighten_key
  trc=$?
  if [ "$trc" -eq 4 ]; then
    printf 'already restricted: %s\n' "$AUTH"
    rm -f "$bak"
    return 0
  fi
  if [ "$trc" -ne 0 ]; then
    printf 'key not found exactly once in %s; no change\n' "$AUTH" >&2
    cp -a "$bak" "$AUTH"
    rm -f "$bak"
    return 2
  fi
  chmod 600 "$AUTH"
  if verify_tight; then
    printf 'tightened: %s (backup %s)\n' "$AUTH" "$bak"
    ssh-keygen -lf "$KEY" 2>&1
  else
    printf 'verification failed; restored %s\n' "$AUTH" >&2
    cp -a "$bak" "$AUTH"
    rm -f "$bak"
    return 2
  fi
  return 0
}

do_selftest() {
  local tmp trc rc=0 out
  tmp=$(mktemp -d) || return 2
  printf 'ssh-ed25519 AAAAfromrepo owner@host\n' > "$tmp/key.pub"
  printf '# keep\nssh-ed25519 AAAAold old@host\nssh-ed25519 AAAAfromrepo owner@host\n' > "$tmp/authorized_keys"
  AUTH="$tmp/authorized_keys"
  KEY="$tmp/key.pub"
  out=$(tighten_key 2>&1)
  trc=$?
  if [ "$trc" -eq 0 ] && verify_tight && grep -q '^ssh-ed25519 AAAAold old@host$' "$AUTH"; then
    printf 'PASS tighten adds restrict, preserves other lines\n'
  else
    printf 'FAIL tighten (%s %s)\n' "$trc" "$out"
    rc=1
  fi
  out=$(tighten_key 2>&1)
  trc=$?
  if [ "$trc" -eq 4 ]; then
    printf 'PASS tighten idempotent\n'
  else
    printf 'FAIL tighten idempotent (%s %s)\n' "$trc" "$out"
    rc=1
  fi
  printf '# no key here\n' > "$tmp/empty"
  AUTH="$tmp/empty"
  out=$(tighten_key 2>&1)
  trc=$?
  if [ "$trc" -eq 3 ]; then
    printf 'PASS tighten fails closed on missing key\n'
  else
    printf 'FAIL tighten missing (%s %s)\n' "$trc" "$out"
    rc=1
  fi
  rm -f "$tmp/key.pub" "$tmp/authorized_keys" "$tmp/empty"
  rmdir "$tmp"
  return "$rc"
}

if [ "$WANT" = selftest ]; then do_selftest; exit $?; fi
if [ "$WANT" = tighten ]; then do_tighten; exit $?; fi

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
