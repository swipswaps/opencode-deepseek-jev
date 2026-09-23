#!/usr/bin/env bash
#
# diag-web-bind.sh — determine where opencode-web is actually listening.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Container is up, restarts=0, banner printed. Host-side probe returns
# HTTP 000. Three hypotheses:
#
#   H1. The server is bound to 127.0.0.1 inside the container. Docker's
#       port forward targets the container's eth0 IP, where nothing is
#       listening. HTTP 000 from the host, but a probe from inside the
#       container succeeds.
#
#   H2. The server ignored --hostname. Same as H1 for our purposes.
#
#   H3. The server is bound but on a different interface or port.
#
# This script interrogates the container's /proc/net/tcp{,6} to read the
# actual bind address. Port 4096 in hex is 0x1000. A line whose local
# port is 1000 and local address is 00000000 is bound to 0.0.0.0. A line
# whose local address is 0100007F is bound to 127.0.0.1.
#
#   Linux procfs, /proc/net/tcp:
#     https://man7.org/linux/man-pages/man5/proc.5.html
#   RFC 7235, HTTP authentication status codes:
#     https://www.rfc-editor.org/rfc/rfc7235
#   Docker port forwarding:
#     https://docs.docker.com/engine/network/
#   OpenCode Web:
#     https://opencode.ai/docs/web/
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Linux procfs, /proc/net/tcp:
#     https://man7.org/linux/man-pages/man5/proc.5.html
#   Docker networking:
#     https://docs.docker.com/engine/network/
#   OpenCode Web UI:
#     https://opencode.ai/docs/web/
#   OpenCode Server:
#     https://opencode.ai/docs/server/
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
# ============================================================================

set -o pipefail

CID="opencode-deepseek-web"

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== diag-web-bind.sh ===\n'
    printf 'container: %s\n' "$CID"

    section "1. container state"
    docker inspect "$CID" \
        --format 'status={{.State.Status}} pid={{.State.Pid}} restarts={{.RestartCount}} exit={{.State.ExitCode}}'

    section "2. processes inside container"
    docker exec "$CID" ps -ef 2>&1 || printf '  ps not available\n'

    section "3. /proc/net/tcp (IPv4) — bind addresses"
    docker exec "$CID" cat /proc/net/tcp 2>&1 | head -20 || true

    section "4. /proc/net/tcp6 (IPv6) — bind addresses"
    docker exec "$CID" cat /proc/net/tcp6 2>&1 | head -20 || true

    section "5. decode port 4096 (hex 1000) binds"
    # Local address in /proc/net/tcp is little-endian hex for IPv4.
    # 0100007F = 127.0.0.1
    # 00000000 = 0.0.0.0
    docker exec "$CID" sh -c '
        for proto in tcp tcp6; do
            file="/proc/net/$proto"
            [ -f "$file" ] || continue
            tail -n +2 "$file" | while read -r line; do
                laddr=$(printf "%s" "$line" | awk "{print \$2}")
                lport=$(printf "%s" "$laddr" | cut -d: -f2)
                if [ "$lport" = "1000" ]; then
                    printf "  %s: local=%s\n" "$proto" "$laddr"
                fi
            done
        done
    ' 2>&1 || true

    section "6. HTTP probe from inside the container (Node)"
    docker exec "$CID" node -e '
        const http = require("http");
        const req = http.request(
            { host: "127.0.0.1", port: 4096, method: "GET", path: "/" },
            res => {
                console.log("  status:", res.statusCode);
                res.on("data", d => process.stdout.write("  " + d));
                res.on("end", () => console.log("\n  --end--"));
            }
        );
        req.on("error", e => console.log("  error:", e.message));
        req.setTimeout(3000, () => { req.destroy(); console.log("  timeout"); });
        req.end();
    ' 2>&1 || true

    section "7. HTTP probe from the host"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/ 2>&1 || true)
    printf '  127.0.0.1:4096   -> HTTP %s\n' "$code"

    code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4096/ 2>&1 || true)
    printf '  localhost:4096   -> HTTP %s\n' "$code"

    local cip
    cip=$(docker inspect "$CID" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    if [ -n "$cip" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' "http://$cip:4096/" 2>&1 || true)
        printf '  %s:4096        -> HTTP %s\n' "$cip" "$code"
    fi

    section "8. summary"
    printf 'interpretation:\n'
    printf '  if section 5 shows 00000000:1000      -> bound 0.0.0.0, host probe should work\n'
    printf '  if section 5 shows 0100007F:1000      -> bound 127.0.0.1, host probe cannot reach\n'
    printf '  if section 5 is empty                 -> not listening on 4096 at all\n'
    printf '  if section 6 returns 200 or 401       -> server is alive on localhost\n'
    printf '  if section 7 returns 000              -> Docker port forward not reaching\n'
    return 0
}

main "$@"
