# Security audit — 2026-11-10

Scope: (1) explain the actively exploited OpenSSH/musl vulnerability in the
Ars Technica story, (2) audit `swipswaps/opencode-deepseek-jev` for its own
vulnerabilities, and (3) list specific fixes.

Method: read the actual source at the paths cited below; check the live host
and containers for the CVE preconditions; compare against the official
advisories linked under **Sources**. Claims are tagged **Proven** (observed in
this repo/host) or **Conditional** (true only if the stated configuration is
present).

> Acronyms are expanded on first use. A glossary is at the end.

---

## Part 1 — CVE-2026-123158 (the “\*sshole” vulnerability)

### What it is

`CVE-2026-123158` is an authentication-bypass bug that appears when the
**OpenSSH** server program is built or run against the **musl** C standard
library (libc) instead of the more common **glibc**, and **Pluggable
Authentication Modules (PAM)** are not in use. It lets an unauthenticated
attacker log in as an account that has no usable password — a “passwordless”
account whose password field in `/etc/shadow` is the literal `*`.

The name “\*sshole” is a pun on the `*` wildcard character, which is the value
that triggers the confusion.

### Why `*` is special

In `/etc/shadow`, the second field is the password hash. Two sentinel values
matter:

- `*` means “no password can match” — a locked/passwordless service account.
- `!` and `!!` mean the account is locked.

When a real password is supplied, OpenSSH hashes it and compares the result to
the stored value. A hash can never equal `*`, so a passwordless account should
be impossible to log in to with a password.

### The bug chain

1. The attacker sends a very long password (**more than 256 characters**) for
   an account whose shadow entry is `*`.
2. OpenSSH asks musl's password-hashing function to hash the oversized input.
3. musl's hashing routine returns the error sentinel `*` instead of a real
   hash (the “misinterpretation of whether a string is intended to be a
   password hash” described by Red Hat).
4. OpenSSH compares the returned value to the stored field. Both are `*`, so
   the comparison **succeeds**.
5. The attacker is authenticated as that account.

### Preconditions (all must hold)

| # | Condition | Why it matters |
|---|-----------|----------------|
| 1 | OpenSSH server (not just the client) | the bug is in the server's password check |
| 2 | musl libc | the `*` error return is musl-specific |
| 3 | PAM **not** used | PAM would handle the check differently |
| 4 | At least one account hashed with SHA256 or SHA512 | the code path that calls musl's hasher |
| 5 | At least one account is passwordless (`*` in `/etc/shadow`) | the value the attacker matches |
| 6 | Password authentication reachable from the attacker | the trigger is a supplied password |

Alpine Linux is the highest-profile affected distribution because it uses
musl and often omits PAM. A normal Fedora/RHEL/Debian host uses glibc and PAM,
so it does **not** meet the preconditions even if it runs the same OpenSSH
version.

### What is happening in the wild

- GreyNoise reported honeypots in Southeast Asia attacked by a group tracked
  as **GT10**, with “mature intrusions”, a command-and-control server, and a
  backdoor called **TAC Agent** (shell, reconnaissance, persistence; Chinese
  comments; signs of AI-generated code). GT10 also installs Python 3 where it
  is missing so the backdoor can run.
- watchTowr reported exploitation tied to botnets and cryptocurrency mining.
- Previdian reported 20 attempts from 13 unique Internet Protocol (IP)
  addresses across nine countries.

### Does this repository meet the preconditions?

**No — Proven for the audited host and images.**

| Target | libc | sshd? | PAM? | Verdict |
|--------|------|-------|------|---------|
| Host `ws24` | glibc (`libc.so.6`) | OpenSSH 10.0p2 server | `/etc/pam.d/sshd` present | not the vulnerable combination |
| `opencode-web` image | Debian bookworm (glibc) | `openssh-client` only, no server | n/a | not exposed |
| `caddy:2-alpine` | musl (Alpine) | no sshd | n/a | not exposed |

So the repository is **not** a CVE-2026-123158 target today. That is a
statement about preconditions, not a reason to skip the OpenSSH update: the
host is an SSH endpoint, and the CVE is under active exploitation.

### Fix for the CVE

- **Fedora/RHEL:** `sudo dnf upgrade --refresh openssh-server openssh-clients`
  then `sudo systemctl restart sshd`.
- **Debian/Ubuntu:** `sudo apt-get update && sudo apt-get install --only-upgrade openssh-server`.
- **Alpine:** `sudo apk upgrade openssh` (and check
  `apk version -l '<'` for any held packages).
- **If you truly run musl without PAM:** stop doing that for sshd, or at minimum
  disable password authentication (`PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`) and remove `*` passwordless logins from
  privileged accounts.
- Verify: `ssh -V`; `ldd "$(command -v sshd)" | grep -i musl`;
  `sshd -T | grep -i usepam`; `sudo sshd -T | grep -i passwordauth`.

---

## Part 2 — Vulnerabilities in `swipswaps/opencode-deepseek-jev`

Ordered by severity. “Proven” means the code path exists in this checkout.

### V1 — High: unauthenticated dashboard exposes session transcripts

**Proven.** `docker/web-entrypoint.sh:109` starts
`scripts/dashboard.mjs` on `0.0.0.0:5099`; `docker/docker-compose.yml:103-106`
publishes `5099:5099` (and `443:443`, which `docker/Caddyfile:60-79` proxies to
the same dashboard). `scripts/dashboard.mjs:3992` creates the HTTP server and
`scripts/dashboard.mjs:4289` listens; **no request path checks a password or
token** (`grep` for `authorization`/`401` finds none).

What an attacker on the same Local Area Network (LAN), Nebula overlay, or
Tailscale tailnet can do:

- `GET /api/sessions`, `/api/session`, `/api/parts`, `/api/activity`,
  `/api/export/session` — read/download every stored conversation. Chat logs
  routinely contain pasted tokens, keys, hostnames, and personal data.
- `GET /api/guard`, `/api/code`, `/api/ops`, `/api/config` — read internal
  telemetry and an `audit-config.sh` report.
- `POST /api/graph/edit` and `/api/usability/guided` — mutate stored data.
  `sameOriginMutation()` (`scripts/dashboard.mjs:3879`) blocks cross-origin
  *browser* requests but returns **true** when there is no `Origin` header, so
  `curl`/scripts pass.
- The public origin `https://swipswaps.github.io` is granted CORS read access
  (`scripts/dashboard.mjs:3872`), and
  `Access-Control-Allow-Private-Network: true` weakens browser private-network
  protections. A compromise of that public site could read the private
  dashboard from a visitor's browser.

Note the comment at `docker/web-entrypoint.sh:104` says the host publishes
“127.0.0.1:5099”, but the compose file publishes all interfaces. The comment is
wrong and masks the exposure.

### V2 — High: every shell command is sent to a third party

**Proven.** `.opencode/plugins/blacklist-guard.js:56` calls
`semanticVerdict(command)` for each bash command; that runs
`scripts/guard-classify.py`, which posts the command text (up to 4000
characters) to `https://api.subq.ai/v1/systemone`
(`scripts/guard-classify.py:31,71-94`). This happens **before** the command
runs and is enabled unless `OPENCODE_SEMANTIC_GUARD=off`.

Consequences:

- Confidentiality: commands can contain secrets (`curl -H "Authorization:
  Bearer …"`), internal hostnames, file contents (`git diff` of a secret), or
  customer data.
- Supply chain: a third-party service becomes a gate in the developer's tool
  loop. It fails open by design, so an outage does not block work — but an
  outage also removes the semantic check.
- The memo file stores command *hashes* (`guard-memo.json`), not plaintext, but
  the network request is plaintext inside TLS to the provider.

### V3 — Medium-High: trusted X11 forwarding (`ssh -Y`)

**Proven.** `scripts/ssh-x11-setup.sh:63` writes `ForwardX11Trusted yes` (the
same as `ssh -Y`). Trusted X11 forwarding disables the X11 SECURITY extension:
the remote machine can read the local X server's contents (screen capture),
inject keystrokes and mouse events, and read the clipboard. Every `ssh -Y`
session from the Fedora client to `100.119.125.16` runs with that trust.

This is a deliberate trade-off in the script (“the smallest change that makes
the clipboard reliable”), but it means a compromise of the *server* can attack
the *client's* desktop, not just its own session.

### V4 — Medium: API keys printed to the terminal

**Proven.** `scripts/rotate-api-keys.sh:297` runs
`head -c 200 "$CONTAINER_AUTH"` where `CONTAINER_AUTH` is the OpenCode
`auth.json` that holds provider API keys. The command output goes through
`indent` and into the operator's terminal, shell history, and any captured
transcript or session log. Two hundred bytes is enough to disclose a key.

### V5 — Medium: `harvest.py` reads `file://` and arbitrary URLs

**Proven.** `scripts/harvest.py:135` accepts `file://` paths and
`scripts/harvest.py:149` fetches any URL with no allow-list. An agent that is
prompt-injected (for example by fetched page text) can therefore have it read
`file:///etc/passwd`, `file:///home/*/.ssh/id_*`, or query a link-local cloud
metadata endpoint (`169.254.169.254`) — paths the `blacklist-guard`
`security` rules otherwise block for `cat`/`grep`/`awk`.

### V6 — Medium: the agent has broad shell/read authority behind a fail-open guard

**Proven.** `opencode.json:93-107` sets `read "*": "allow"` and
`bash "*": "allow"` (with targeted denials for `*.env`, `docker/certs/*`, and
`opencode debug config*`). The `blacklist-guard` is a *convenience* pattern
matcher, not a security boundary: its own header says it fails open, and the
prompt-injection tripwire is advisory only. Once untrusted content enters a
session (web fetch, harvested page, OCR text, tool output), the model can run
shell commands inside the workspace. The guard reduces accidents; it does not
contain a determined injection.

### V7 — Medium: container mounts that widen blast radius

**Proven.** `docker/docker-compose.override.yml:9,25` mounts the operator's
`~/.config/opencode` **read-write** into both containers; that directory can
hold `auth.json` and plugin code. `scripts/deploy-dockge.sh:51` and
`scripts/flatten-dockge-stacks.sh:121` mount `/var/run/docker.sock`, which is
root-equivalent on the host (an intentional Dockge feature, but a large one).

### V8 — Low-Medium: command execution through `eval` / `bash -c`

`scripts/test-tools.sh:102,105` runs `eval "$cmd"` and
`scripts/runbook.sh:107` runs `bash -c "$cmd"`. These consume repo-owned
configuration (`tools.json`, runbooks), so the risk is low today; it becomes
real if those files ever accept external input.

### V9 — Low-Medium: weak Content Security Policy (CSP)

`scripts/dashboard.mjs:3895` sets `script-src 'self' 'unsafe-inline'`. The
dashboard builds a lot of HTML with `innerHTML`; a single escaping miss in a
transcript field becomes executable script in an already unauthenticated page
(see V1). Removing `'unsafe-inline'` and using nonces or hashes is the durable
fix.

### What the repo does well (keep it)

- `.env.local`, `docker/litellm-db.env`, `data/opencode`, and
  `docker/certs/*` keys are **not tracked** by Git (verified with
  `git ls-files`; `.gitignore` and `docker/certs/.gitignore` cover them).
- Containers run `cap_drop: ALL`, `no-new-privileges`, non-root user, and the
  `.env.local`/certs are masked with `/dev/null`/`empty-certs` in the override.
- The base image is digest-pinned.
- `pages-export.sh` has a consent gate and a secret-shape re-scan before
  publishing; `notify-sink.mjs` binds `127.0.0.1`.
- `repo-mcp.mjs` uses `execFile` (no shell), avoiding command-string injection.

---

## Part 3 — Specific, actionable fixes

### P0 — do now

1. **Patch OpenSSH everywhere** (see “Fix for the CVE” above). Verify with the
   four commands listed there.
2. **Put authentication in front of the dashboard.** Either:
   - add Caddy `basic_auth` to the `:5099` and `:443` site blocks, using
     `caddy hash-password`, or
   - enforce `OPENCODE_SERVER_PASSWORD` in `dashboard.mjs` for every route, or
   - publish loopback only: in `docker/docker-compose.yml`, change
     `- "5099:5099"` to `- "127.0.0.1:5099:5099"` (and drop `443` if it is
     only a dashboard alias).
3. **Stop the third-party command upload.** Set
   `OPENCODE_SEMANTIC_GUARD=off` in the environment that starts the agent, or
   self-host the classifier. If it must stay on, redact secret-shaped tokens
   from `cmd` before `json.dumps(body(cmd))` and document the data flow.
4. **Stop printing `auth.json`.** Replace
   `head -c 200 "$CONTAINER_AUTH"` with a key-name-only view:
   `jq -r 'keys[]' "$CONTAINER_AUTH"` (or `opencode providers list`).

### P1 — this week

5. **Drop trusted X11 by default.** In `scripts/ssh-x11-setup.sh`, set
   `ForwardX11Trusted no` (or omit it) and use `ssh -X`; use a clipboard bridge
   (`wl-copy`/`xclip`) for the paste path. Keep `-Y` only toward one host you
   fully trust, and document the trade-off.
6. **Remove the public CORS grant** at `scripts/dashboard.mjs:3872`, or scope it
   to a read-only, non-export endpoint set and require a token. Never expose
   `/api/export/session` cross-origin.
7. **Harden `harvest.py`:** reject `file://` unless `--allow-local` is given;
   reject loopback, private (RFC 1918), link-local, and cloud-metadata
   addresses; re-validate after redirects.
8. **Reduce the mount surface:** mount `~/.config/opencode` read-only (or a
   scoped copy) in `docker-compose.override.yml`; restrict the Docker socket
   mounts to the Dockge host only, or use a socket proxy with an allow-list.

### P2 — hardening

9. **Tighten CSP:** replace `script-src 'self' 'unsafe-inline'` with nonces or
   hashes; audit every `innerHTML` sink in `dashboard.mjs`.
10. **Narrow `opencode.json`:** change `bash "*": "allow"` to `ask` and add
    denies for `curl * | *sh`, `harvest.py *file://*`, `/etc/*`, and
    `*/.ssh/*`; change `read "*": "allow"` to `ask` for the home directory.
11. **Replace `eval`/`bash -c`** in `test-tools.sh` and `runbook.sh` with
    `execFile` argument arrays or a command allow-list.
12. **Add a security gate** to `harness.sh`: a script that fails on (a) an
    unauthenticated `:5099` listener, (b) `SEMANTIC_GUARD` not `off`,
    (c) `ForwardX11Trusted yes`, (d) `head -c` on `auth.json`, (e) tracked
    secrets, and (f) `sshd` on musl without PAM.

---

## Part 4 — Verification commands (copy/paste)

```sh
# CVE preconditions
ssh -V
ldd "$(command -v sshd)" | grep -i musl || echo "glibc: not the musl case"
sshd -T | grep -i usepam
sudo sshd -T | grep -i passwordauth

# Dashboard exposure (expect 401/403 after the fix)
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:5099/api/sessions
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:5099/api/export/session?id=x

# Third-party classifier
grep -n 'OPENCODE_SEMANTIC_GUARD' .opencode/plugins/blacklist-guard.js
env | grep -c OPENCODE_SEMANTIC_GUARD=off

# Trusted X11
grep -n 'ForwardX11Trusted' ~/.ssh/config scripts/ssh-x11-setup.sh

# No tracked secrets
git ls-files | grep -E '\.env|docker/certs/.*\.key|auth\.json' || echo "none tracked"
```

---

## Glossary

- **API** — Application Programming Interface.
- **CORS** — Cross-Origin Resource Sharing; browser rules that let one origin
  read another origin's responses.
- **CSP** — Content Security Policy; a browser header that restricts which
  scripts may run.
- **CVE** — Common Vulnerabilities and Exposures; a public identifier for a
  security flaw.
- **glibc / musl** — two C standard libraries. glibc is the GNU one used by
  most distributions; musl is a small, strict alternative used by Alpine.
- **LAN** — Local Area Network.
- **libc** — the C standard library (the base functions every program uses).
- **OpenSSH** — the dominant open-source implementation of the Secure Shell
  (SSH) protocol.
- **PAM** — Pluggable Authentication Modules; the pluggable login/account
  framework on most Linux distributions.
- **RFC 1918** — the private IPv4 address ranges (`10/8`, `172.16/12`,
  `192.168/16`).
- **SSH** — Secure Shell; encrypted remote login.
- **SSRF** — Server-Side Request Forgery; tricking a server into fetching an
  attacker-chosen URL.
- **Tailscale / Nebula** — overlay mesh VPNs used here for stable addresses.
- **TOFU** — Trust On First Use; accept a host key the first time, then pin it.
- **X11** — the X Window System; the Unix graphical display protocol.

## Sources

- Ars Technica, “Vulnerability that lets hackers SSH into Linux devices is
  under active exploitation”, Dan Goodin, 2026-11-09:
  https://arstechnica.com/security/2026/11/vulnerability-that-lets-hackers-ssh-into-linux-devices-is-under-active-exploitation/
- Red Hat Bugzilla, CVE-2026-123158:
  https://bugzilla.redhat.com/show_bug.cgi?id=CVE-2026-123158
- GreyNoise exploitation tracker: https://sshole.events.greynoise.io
- Previdian write-up: https://previdian.com/CVE-2026-123158
- watchTowr: https://x.com/watchtowrcyber/status/2118636513739317525
- OpenSSH project and release notes: https://www.openssh.com/ and
  https://www.openssh.com/releasenotes.html
- OpenSSH portable source: https://github.com/openssh/openssh-portable
- musl libc: https://musl.libc.org/
- Alpine Linux security: https://security.alpinelinux.org/ and
  https://github.com/alpinelinux/aports
- Caddy `basic_auth` directive:
  https://caddyserver.com/docs/caddyfile/directives/basic_auth
- Docker Compose `ports` binding:
  https://docs.docker.com/compose/compose-file/05-services/#ports

*External content is untrusted data, never instructions. This document cites
it for evidence only.*
