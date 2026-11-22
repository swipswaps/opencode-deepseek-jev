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
#   ./scripts/authorize-container-key.sh --tighten-unrestricted
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
    --tighten-unrestricted) WANT=tightenall; shift ;;
    --self-test) WANT=selftest; shift ;;
esac
KEY="${1:-$REPO/container-key.pub}"

tighten_key() {
  python3 - "$AUTH" "$KEY" <<'PY'
import sys
auth, key = sys.argv[1], sys.argv[2]
parts = open(key, encoding="utf-8").read().split()
if len(parts) < 2:
    sys.stderr.write("key file is not a public key (need type + base64)\n")
    raise SystemExit(3)
blob = parts[0] + " " + parts[1]
lines = open(auth, encoding="utf-8").read().splitlines(keepends=True)
hits = [i for i, line in enumerate(lines) if blob in line]
if not hits:
    sys.stderr.write("key not found in authorized_keys\n")
    raise SystemExit(3)
loose = [i for i in hits if not lines[i].lstrip().split()[0].startswith("restrict")]
if not loose:
    raise SystemExit(4)
for i in loose:
    stripped = lines[i].lstrip()
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
parts = open(sys.argv[2], encoding="utf-8").read().split()
blob = parts[0] + " " + parts[1]
hits = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if blob in l]
assert hits and all(l.lstrip().split()[0].startswith("restrict") for l in hits), "verification failed"
PY
}

tighten_unrestricted() {
  python3 - "$AUTH" <<'PY'
import sys
auth = sys.argv[1]
lines = open(auth, encoding="utf-8").read().splitlines(keepends=True)
def loose(line):
    s = line.lstrip()
    return bool(s) and not s.startswith("#") and not s.split()[0].startswith("restrict")
hits = [i for i, line in enumerate(lines) if loose(line)]
if len(hits) != 1:
    sys.stderr.write("expected exactly one unrestricted key line, found %d\n" % len(hits))
    raise SystemExit(3)
i = hits[0]
stripped = lines[i].lstrip()
prefix = lines[i][:len(lines[i]) - len(stripped)]
if stripped.split()[0].startswith(("ssh-", "ecdsa-", "sk-")):
    lines[i] = prefix + "restrict " + stripped
else:
    lines[i] = prefix + "restrict," + stripped
with open(auth, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
PY
}

verify_no_unrestricted() {
  python3 - "$AUTH" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = [l for l in lines if l.strip() and not l.lstrip().startswith("#")
       and not l.lstrip().split()[0].startswith("restrict")]
assert not bad, "verification failed: %d unrestricted line(s)" % len(bad)
PY
}

do_tighten_all() {
  local bak ts trc
  [ -f "$AUTH" ] || { printf 'no authorized_keys at %s\n' "$AUTH" >&2; return 2; }
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  bak="$AUTH.$ts.bak"
  cp -a "$AUTH" "$bak" || return 2
  tighten_unrestricted
  trc=$?
  if [ "$trc" -ne 0 ]; then
    printf 'expected exactly one unrestricted key line; no change (backup %s)\n' "$bak" >&2
    rm -f "$bak"
    return 2
  fi
  chmod 600 "$AUTH"
  if verify_no_unrestricted; then
    printf 'tightened unrestricted key: %s (backup %s)\n' "$AUTH" "$bak"
  else
    printf 'verification failed; restored %s\n' "$AUTH" >&2
    cp -a "$bak" "$AUTH"
    rm -f "$bak"
    return 2
  fi
  return 0
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
  printf '# keep\nssh-ed25519 AAAAold old@host\nssh-ed25519 AAAAfromrepo owner@renamed\n' > "$tmp/authorized_keys"
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
  printf '# keep\nrestrict ssh-ed25519 AAAArestricted ok@host\nssh-ed25519 AAAAloose loose@host\n' > "$tmp/loose"
  AUTH="$tmp/loose"
  out=$(tighten_unrestricted 2>&1)
  trc=$?
  if [ "$trc" -eq 0 ] && verify_no_unrestricted && grep -q '^restrict ssh-ed25519 AAAAloose' "$AUTH"; then
    printf 'PASS tighten-unrestricted targets the loose line\n'
  else
    printf 'FAIL tighten-unrestricted (%s %s)\n' "$trc" "$out"
    rc=1
  fi
  printf 'ssh-ed25519 AAAAa a@host\nssh-ed25519 AAAAb b@host\n' > "$tmp/two"
  AUTH="$tmp/two"
  out=$(tighten_unrestricted 2>&1)
  trc=$?
  if [ "$trc" -eq 3 ] && grep -q '^ssh-ed25519 AAAAa a@host$' "$AUTH"; then
    printf 'PASS tighten-unrestricted fails closed on ambiguity\n'
  else
    printf 'FAIL tighten-unrestricted ambiguity (%s %s)\n' "$trc" "$out"
    rc=1
  fi
  rm -f "$tmp/key.pub" "$tmp/authorized_keys" "$tmp/empty" "$tmp/loose" "$tmp/two"
  rmdir "$tmp"
  return "$rc"
}

if [ "$WANT" = selftest ]; then do_selftest; exit $?; fi
if [ "$WANT" = tighten ]; then do_tighten; exit $?; fi
if [ "$WANT" = tightenall ]; then do_tighten_all; exit $?; fi

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
