#!/usr/bin/env bash
#
# net-rst.sh — list TCP resets in a capture, read-only.
#
# Prints timestamp, direction, and ports for every RST in PCAP, so the
# operator can see which endpoint sent resets and when. Uses tcpdump
# itself in read mode (no tshark/Wireshark needed, no GUI needed).
# A reset's source address is evidence, not proof: middleboxes can
# inject packets and captures can miss traffic.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   printf only, main() wrapper. Reads only; never captures, never writes
#   except stdout.
#
set -o pipefail

usage() { printf 'usage: %s FILE.pcap\n' "$0"; }

main() {
    if [ $# -ne 1 ]; then
        usage >&2
        return 2
    fi
    local f="$1"
    [ -f "$f" ] || { printf 'FAIL: not a file: %s\n' "$f"; return 2; }
    [ -r "$f" ] || { printf 'FAIL: not readable: %s\n' "$f"; return 2; }
    command -v tcpdump >/dev/null || { printf 'FAIL: tcpdump not installed\n'; return 2; }
    local n
    # The "reading from file ..." preamble goes to stderr; filter that one
    # known line explicitly so it is never counted as a reset. Anything
    # else on stderr (e.g. "truncated dump file") stays visible.
    n=$(tcpdump -r "$f" 'tcp[tcpflags] & tcp-rst != 0' 2>&1 | tee /dev/stderr | grep -v "^reading from file" | grep -c . || true)
    printf 'resets: %s in %s\n' "$n" "$f"
    if [ "$n" -eq 0 ]; then
        printf 'no TCP resets captured (capture may have missed the window — recapture with net-capture.sh)\n'
    fi
    return 0
}

main "$@"
