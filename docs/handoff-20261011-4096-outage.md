# Handoff Addendum — 2026-10-11 :4096 Outage (PhD Framing)

> Scope: why `https://192.168.4.24:4096` and `https://localhost:4096/.../session/ses_ee4ec6b14ffeN7ssA582NZBWgJ`
> failed post-reboot while `ping 8.8.8.8`, `ping google.com`, and Firefox-to-internet worked.
> Intervention applied and verified below. This file is the durable state; `TODO.md` holds next actions.

## 1. Research question and thesis

**Q:** Given intact L3 (ICMP) and egress L7 (internet via Firefox) on host `.24`
(`192.168.4.24`), why did all L7 access to the local OpenCode Web service on TCP/4096
fail with connection-refused / "site can't be reached"?

**Thesis (confirmed):** the failure was *not* a network-partition event but a
**service-binding + protocol-stratum mismatch**: (a) the TLS terminator (`opencode-caddy`)
was in `Created` state, having failed to bind a non-local address; (b) the upstream
(`opencode-web`) speaks plaintext HTTP with Basic auth and is only `expose`d on the
compose network; (c) clients probed the wrong stratum (`http://` against an `https://`
endpoint, or `https://` against a port with no host listener). Each layer was healthy
in isolation; the composition was unsatisfiable.

## 2. Ontology (what the system is)

- `opencode-web` (container `opencode-deepseek-web`): `opencode web --hostname 0.0.0.0 --port 4096`,
  plaintext HTTP, Basic realm `Secure Area`, `401` = alive-and-authed. Compose `expose`s
  4096/5099 to the compose network only — no host listener by design.
- `opencode-caddy` (container `opencode-caddy`, `caddy:2-alpine`, `user 1000:1000`):
  the sole TLS terminator and sole host-published listener for 4096/5099.
  `Caddyfile`: `:4096 → reverse_proxy opencode-web:4096`, `:5099 → reverse_proxy opencode-web:5099`
  with `/certs/opencode.{crt,key}`.
- Mesh overlay (Nebula): this host `.24` = `10.100.0.24/24` on `nebula0`;
  lighthouse `.45` = `192.168.4.45` / mesh `10.100.0.1`. Documented service addresses
  (`docs/ANYWHERE.md`): `https://10.100.0.24:4096|5099` over mesh.
- Store of record: `data/opencode/opencode.db` (SQLite, 549 MB), mounted into the
  container at `/home/node/.local/share/opencode`. Session rows in `session`,
  turns in `message.data` (JSON), content in `part.data` (JSON).

## 3. Methodology (differential diagnosis, L3 → L7 → control plane)

1. **L3:** `ping 8.8.8.8`, `ping 192.168.4.45`, `ping 10.100.0.1` — all pass. Excludes partition.
2. **L4:** host `ss -ltnp` shows no `:4096` listener despite PID 208741
   (`opencode web --hostname 0.0.0.0 --port 4096`, container PID 1 via `containerd-shim`).
   `curl -vk https://localhost:4096/`, `https://127.0.0.1:4096/`,
   `https://192.168.4.24:4096/` → all `Connection refused` (SYN, no SYN-ACK).
3. **Netns isolation check:** `docker exec opencode-deepseek-web curl http://localhost:4096/`
   → `401 Basic realm="Secure Area"`; `curl https://localhost:4096/` → `SSL wrong version
   number`. Proves upstream is alive on plaintext HTTP inside its netns and unreachable
   from the host netns — a publish/terminate gap, not a crashed process.
4. **Control plane:** `docker inspect opencode-caddy` → `Status: created, ExitCode: 128`,
   `Error: failed to bind host port for 10.100.0.2:4096 ... cannot assign requested address`;
   `NetworkSettings.Ports {4096/tcp: null}`, `HostConfig.PortBindings {}` on web.
   `docker/docker-compose.yml` (caddy): `10.100.0.2:4096/5099` — `.2` is not a local
   address on this host (`.24`). Caddy could never start here.
5. **Store query:** `session WHERE id='ses_ee4ec6b14ffeN7ssA582NZBWgJ'` exists
   (`DeepSeek chat review and missing parts`, 2026-10-08, 160 messages, 564 parts);
   full transcript materialised to `logs/transcript-ses_ee4ec6b14ffe.md`.
6. **Host/event history:** `uptime`/`last`/`journalctl --list-boots` (.24 up 4 days, no
   reboot today); `sestatus` enforcing; `journalctl -b0 -p err`; Nebula logs showing
   `Close tunnel` flap vs `.45`; `ssh owner@192.168.4.45 uptime` → up 32 min (rebooted
   per operator report); `ausearch -m AVC -ts recent` on `.45` → no matches.

## 4. Results

### R1. Session record recovered (operator request)
- `ses_ee4ec6b14ffeN7ssA582NZBWgJ`: Oct 8 → Oct 11, DeepSeek share-link review
  (unfetchable via `webfetch`, no Chrome/CDP in container → operator asked to paste/PDF)
  → Playwright/CDP dead-end → Fedora boot-audit / compose `-f` override lesson
  → Oct 11 `probe-diagnose.sh` dashboard STALE work. Transcript:
  `logs/transcript-ses_ee4ec6b14ffe.md` (363 KB, 4235 lines).

### R2. SELinux / "network unreachable" on `.45`, reconciled
- `.45` did reboot (~18:04 EDT); now healthy, SELinux `enforcing`, no recent AVCs,
  `setroubleshootd` empty. Pre-reboot denial burst is no longer in the journal and
  cannot be reconstructed from `.24` — classified as transient, resolved by reboot.
- `.24` was never down. The recurring `mesh-dispatcher: FAIL: loopback down and repair
  refused` is a **false positive**: `lo` is `LOOPBACK,UP,LOWER_UP`; the probe shells
  `sudo ip link set lo up` without a passwordless grant, so it fails every minute.
  Genuine mesh event 15:09 EDT: peer `10.100.0.1` unreachable → `nebula.service`
  restarted → recovered. Residual: tunnel `Close tunnel` / re-handshake vs `.45`
  approximately every 2 min; data plane passes (ping OK both underlays).

### R3. :4096 root cause and intervention (applied, verified)
- Cause: stale publish address `10.100.0.2` (predates this host's `.24` address;
  cf. commit `932e335` caddy-TLS workstream). Caddy `Created`, zero host listeners,
  hence SYN-refused on `localhost`, `192.168.4.24`, and mesh IP alike.
- Fix in `docker/docker-compose.yml` (caddy `ports:`): publish each service port on
  exactly the three documented identities —
  `127.0.0.1:4096/5099` (loopback/`docs` verify + `scripts/web.sh` probe),
  `10.100.0.24:4096/5099` (mesh, `ANYWHERE.md`), `192.168.4.24:4096/5099`
  (LAN, `scripts/enable-lan-cert.sh`; cert already carries all four SANs).
  Deliberately not `0.0.0.0`: Basic auth gates it, but least-exposure is preserved.
- `docker compose up -d caddy` → `Up 8s`, six published bindings.
- Verification matrix (all pass): `https://{127.0.0.1,10.100.0.24,192.168.4.24}:4096/ → 401`;
  `:5099/api/rev → 200`; `http://127.0.0.1:4096/ → "Client sent an HTTP request to an
  HTTPS server."` (proves TLS stratum); `scripts/certs-verify.sh → ALL CHECKS PASSED`
  (fingerprint match, SAN coverage, dates, chain, `--cacert` on both ports).

## 5. Threats to validity / limitations

- Pre-reboot `.45` journal (SELinux burst + unreachable window) unavailable; R2's
  "transient" classification rests on post-reboot absence, not on the original trace.
- `jev-guard` flagged the analyst's own SQLite-dump commands as prompt-injection
  (scores 0.76–0.79, two occurrences); treated as false positives after inspection —
  the matched text was store content being exported, not an instruction to follow.
  No store phrases were copied into commands or submissions.
- `scripts/web.sh` in the working tree is drifted (TLS/certs block deleted, uncommitted;
  starts only `opencode-web`, probes `http://127.0.0.1:4096` which can never answer
  under the TLS-via-Caddy design). The fix above starts Caddy explicitly; `web.sh`
  still needs reconciliation (see §7).

## 6. Operational corollary (how to access now)

- Browser on `.24`: `https://127.0.0.1:4096/` (or `https://192.168.4.24:4096/` from LAN,
  `https://10.100.0.24:4096/` over mesh). User `opencode`, password =
  `OPENCODE_SERVER_PASSWORD` in `.env.local` (never paste the value into chat).
  Expect one-time CA warning until `./docker/certs-trust.sh` + browser relaunch.
- `curl`: always `https://` + `-k` (or `--cacert docker/certs/ca.crt`):
  `curl -kI https://192.168.4.24:4096/` → `401`; bare `curl -I http://…` → `400` by design.
- Session deep-link shape `https://<host>:4096/server/<b64(server)>/session/<id>`:
  the embedded base64 must denote the host actually dialed
  (`aHR0cHM6Ly9sb2NhbGhvc3Q6NDA5Ng==` = `https://localhost:4096`, valid only via loopback).

## 7. Residual risks and next steps (for TODO.md)

1. Reconcile `scripts/web.sh` with the Caddy design (restore cert-init + `up -d caddy` /
   restart-on-`ROTATED`, fix readiness probe to `https://127.0.0.1:4096` expecting 401).
2. Grant or remove the mesh-dispatcher's `ip link set lo up` passworded sudo (currently
   a per-minute false-alarm generator masking real mesh signals).
3. Investigate Nebula tunnel flap (~2 min `Close tunnel` vs `.45`); harmless now, but
   the 15:09 peer-unreachable restart shows the watchdog path works — confirm timer
   vs. dispatcher ownership.
4. Decide whether `.2` in compose history denotes a retired lighthouse address; if so,
   grep remaining references (`10.100.0.2`) and correct or document them.
