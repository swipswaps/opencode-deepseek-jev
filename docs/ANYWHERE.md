# Run it anywhere — clone, run, join

One machine or many, home LAN or remote network: same steps. Two repos
are involved:

- this repo — services (opencode web :4096, dashboard :5099, both TLS
  via caddy) and their docs/tests;
- `proxmox-dual-plane-mesh` — the nebula overlay (`10.100.0.0/24`)
  that makes every node reachable from any network.

Only the **lighthouse** needs inbound internet (one UDP forward, done
once on the home router). Roaming nodes make **outbound** connections
only — no port work on remote networks, no VPN client beyond nebula.

## 1. Clone

```bash
git clone https://github.com/swipswaps/opencode-deepseek-jev.git
git clone https://github.com/swipswaps/proxmox-dual-plane-mesh.git
```

Needs: Docker Engine (daemon reachable), `openssl`, `curl`, `python3`.
On the mesh side: `sudo`, `nebula` binary (via that repo's `install.sh`).

## 2. Keys (once per machine)

```bash
cd opencode-deepseek-jev
./scripts/ensure-env.sh      # creates .env.local (0600): API keys + server password
```

`.env.local` is the only source of truth and is gitignored. Never paste
its values into chat — refer to key names, not key material.

## 3. TLS (self-healing)

```bash
./docker/certs-init.sh       # also runs inside scripts/web.sh on every start
./docker/certs-trust.sh      # trust the CA once: system store + Firefox
```

Model: a stable machine-local CA (`docker/certs/ca.crt`, 10y, gitignored)
signs short server certs (825d). `certs-init.sh` ensures coverage on every
run — minting the CA if missing, migrating legacy self-signed pairs, and
**reissuing automatically when SANs no longer cover this host** (prints
`ROTATED`; `web.sh` restarts caddy on that word). Needed SANs: `localhost`
+ `127.0.0.1` + the host's nebula IPv4 + `CERT_EXTRA_SANS`. `--check`
verifies only (exit 1 + gaps listed), `--rotate` forces reissue,
`--rotate-ca` starts over (re-trust everywhere afterwards).

Kill the warnings permanently: `./docker/certs-trust.sh` installs the CA
into the system store (covers Chrome/curl/`--cacert`-free clients after a
relaunch) and every Firefox profile (via `certutil`). Until trusted:
accept the one-time browser warning, `curl -k`,
`NODE_TLS_REJECT_UNAUTHORIZED=0` for node.

## 4. Start services (any host)

```bash
./scripts/web.sh             # checks env + certs, then: compose up -d opencode-web
```

Verify:

```bash
curl -k https://127.0.0.1:5099/api/rev        # {"stale":false} + HEAD match
curl -k https://127.0.0.1:4096/ -o /dev/null -w '%{http_code}\n'  # 401 = alive+authed
```

Plain `http://` on these ports fails by design with
`Client sent an HTTP request to an HTTPS server` — always use `https://`.

Where things live (2026-10-08): the dashboard and opencode web run
wherever **you** start them. Our instances live on `.24`, so over the
mesh they are `https://10.100.0.24:5099/` and
`https://10.100.0.24:4096/`. The lighthouse (`.1`) serves no web ports.

## 5. Join the mesh (any network)

On the lighthouse (`.45`), mint a bundle (needs its `ca.key`):

```bash
sudo ./scripts/mesh.sh onboard <name> 10.100.0.<n>/24 "agents,telemetry"
```

On the new node — pick ONE (C needs no network path at all):

```bash
# A. same LAN:
sudo ./scripts/mesh.sh join-from owner@192.168.4.45 <name>
# B. copy the file first:
scp owner@192.168.4.45:/var/lib/mesh-onboard/offers/<name>.tar.gz ~/<name>.tar.gz
sudo ./scripts/mesh.sh join ~/<name>.tar.gz
# C. paste base64 (air-gap friendly):
sudo ./scripts/mesh.sh join-b64 '<paste>'
```

Then:

```bash
sudo ./scripts/mesh.sh verify 10.100.0.1
ping -c3 10.100.0.1
systemctl is-active mesh-lh-refresh@mesh-lh01.duckdns.org.timer   # hourly, auto-installed
```

Join installs the DuckDNS refresher automatically, so a home-WAN
change re-points the lighthouse path within the hour instead of
stranding roamers. Afterwards `shred` the bundle on both ends
(`sudo ./scripts/mesh.sh shred <name>` on the lighthouse,
`shred -u` the local copy) — it contains the node's private key.

## 6. Reach anything from anywhere

- Overlay first: `ping -c3 10.100.0.1`. If this fails, fix mesh before
  touching services (`verify` tells you which layer).
- Then service URLs with the **serving host's** mesh IP
  (`.24` for ours): `https://10.100.0.24:5099/`,
  `https://10.100.0.24:4096/`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Client sent an HTTP request to an HTTPS server` | plain http on a TLS port | use `https://` (+ `-k` / accept warning) |
| `ERR_CERT_COMMON_NAME_INVALID` | self-signed cert | expected; accept once, or add `-k` |
| `401` on `:4096` | alive, auth missing | Basic `opencode` + `.env.local` password |
| `nebula0` missing / `cannot reach 10.100.0.1` | not joined or stale path | `join` again; check refresher timer + log |
| `scp: Permission denied` on join-from | fixed in `feature/duckdns` | pull, or use path B/C |
| `303 → blocked.eero.com` on gateway:80 | eero has no LAN admin by design | use the eero phone app, not the browser |
| Dashboard shows `STALE served … vs HEAD` | container runs old code | `docker compose -f docker/docker-compose.yml restart opencode-web` |
