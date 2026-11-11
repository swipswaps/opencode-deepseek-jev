# OpenCode + DeepSeek V4.1 Flash + Jev

**What this is.** A self-hosted AI coding workspace. OpenCode (the agent UI)
runs in Docker, calls DeepSeek for generation, and sends risky tool calls
through a local guard. A separate RAG repo provides local document retrieval.
The stack runs on one host (`ws24`, `192.168.4.24`); there is no cloud control
plane.

## Latest verified state (2026-11-05)

- The web UI, legacy dashboard `/`, and MUI app `/app/` are live. Canonical
  access: `https://10.100.0.24:5099/app/` (MUI), `https://10.100.0.24:5099`
  (legacy dashboard), or 443 `https://10.100.0.24/app/`. The 443 site redirects
  `/5099` and `/4096` to the real ports. `:4096` is the agent UI behind Basic
  auth (`401` is alive).
- The combined **activity timeline** is live on both UIs: newest first, filters,
  30/all, expand/copy, full command/text, exact duration, start dot, relative
  bar, and a **`time · now`** legend with a red marker. Legacy and MUI headers
  no longer collide.
- TLS is redundant and verified: 443/4096/5099 on loopback, Nebula
  (`10.100.0.24`), LAN (`192.168.4.24`), and Tailscale
  (`100.119.125.16`); SANs cover all of them. The public CA is downloadable at
  `/ca.crt`; the PC was trusted for system, Firefox, and Chromium stores.
- `https-selfheal.sh` checks/repairs SANs, Caddy, ports, CA, CORS/PNA, and the
  dashboard; `trust-ca-client.sh` bootstraps a client CA. Both pass on the host
  and the client check passes on the PC.
- MUI/React `web/` is served at `/app/`; the public Pages app
  <https://swipswaps.github.io/opencode-observability/> probes the live API and
  falls back to real captured screenshots when the private API is unreachable.
- LiteLLM has a private Postgres. The admin UI at `127.0.0.1:4000/ui` accepts
  `admin` + `LITELLM_MASTER_KEY` (HTTP 200); `/v1/models` is 200.
- Provider keys were rotated. The guard allows benign reads and denies
  destructive, exfiltration, and quote/substitution-obfuscated calls.
- Security posture (2026-11-10): `security-posture.sh --offline` reports
  **22 pass / 1 fail**; the one fail is a pre-existing `secret-scan` finding in
  the host `../notes/` artifacts (outside this repo). The staged SEC-3 recreate
  still needs a restart to apply the repo-mounted-secret binds.
- Verified gates (2026-11-10): lint **403/0**, test-hygiene **99/0**,
  test-patterns **6/0**, test-dashboard **158/0**, panels **12/12**,
  inline UI/PWA test PASS, `certs-verify` ALL PASS, `https-selfheal --check`
  ALL PASS, PC strict TLS 200/verify=0 on 5099 + 443 + LAN.

## 2026-11-11 — settings controls + UX pass

**Settings is now a control surface, not a runbook.** `/settings` (classic) and
`/app/#settings` (MUI) show one redacted provider matrix — config block, env-key
presence (name only), `auth.json` entry, model policy, decision-router state —
and safe **pause/resume** with a typed provider-id confirmation. Every action
writes a `SETTINGS` ledger row and a pending-host-apply badge; the UI also links
each provider's key console and copies the matching rotate command. No secret is
ever rendered, accepted, or posted to the browser.

The container cannot edit `.env.local` (it is masked), so the dashboard writes
desired state and the host applier makes it effective:

```bash
./scripts/settings-apply.sh                 # dry run
./scripts/settings-apply.sh --apply --yes   # comment/restore key, auth logout, recreate, verify
./scripts/settings-apply.sh --self-test
```

Anthropic was hard-paused and verified absent from the container environment.

**Usability and accessibility pass.**

- `/app/#usability` is now a clear evidence summary (automated axes + recent
  guided sessions) with a single **Run the guided test** button to the dedicated
  `/usability` runner, instead of a confusing duplicate runner.
- `/recovery` gained the missing skip-link target, `:focus-visible`, base
  layout, and `pre`/table overflow handling.
- Global `:focus-visible` and `pre{overflow-x:auto}`; React tables now scroll
  horizontally on narrow screens; `prefers-reduced-motion` is honored.
- `a11y-audit.mjs` reports **11/11 on every classic page** (`/`, `/explore`,
  `/graph`, `/usability`, `/models`, `/settings`, `/runbooks`, `/manage`,
  `/docs`, `/recovery`). Lint **419/0**; `cd web && npm run build` succeeds.
- See `open a real browser` for the `/app` surface:
  `./scripts/browser-python.sh scripts/test-app-playwright.py` drives every
  `/app/#<view>` at desktop and mobile widths and checks content, console/page
  errors, overflow, the mobile nav, the Settings confirm guard, and the
  Usability link. Screenshots land in `logs/`.
  **Verified 2026-11-11:** **12/12** (desktop 1280×900 + mobile 390×844) in
  10 s; `.24` posture **23/0**; secret scan clean.
- `scripts/audit-app-ux.py` audits the React DOM (Playwright): h1/heading tree,
  accessible names, focus, tap targets, nav state, and console errors. The
  2026-11-11 run found and fixed the missing h1 on every view, then the
  residual `APP-UX-1` items (search labels, `aria-current`, 44px mobile
  targets). Current audit: **0 findings**; battery **12/12**.

`web/dist` is a build artifact (gitignored): run `cd web && npm run build` (or
`./scripts/web-build-restart.sh`) after a checkout.

**B43 (client Wi-Fi):** the Bluetooth-off / `btcoex=0` / BSSID-pin
intervention did **not** hold. Rolling 24 h at 11:22 EST: **227 total / 32 pre /
195 post** (17 h post; **127** in the 10:00 hour). H1 rejected; next is a
different 2.4 GHz AP, then a USB Wi-Fi/Ethernet adapter. Evidence:
`docs/BT-COEXISTENCE-2026-11-10.md` §9.

**Guided rotation (Playwright, 2026-11-11).** `scripts/rotate-guided.py` opens
the vendor console in a persistent Chromium profile (log in once), finds the
revoke/create controls, and remembers them in
`data/observability/observability.db` (`rotation_memory` + `rotation_run`). On a
miss it lists the candidate controls for a one-time pick and learns. The new key
is read from the page (clipboard fallback), written atomically to `.env.local`
(0600, backup), and never printed; no screenshot is taken after reveal.
`--action login|revoke|create|rotate`, `--plan`, `--report`, `--reset`,
`--self-test`, `--browser-self-test`, `--reset-login`. Login is verified
(ok/login/rejected); a rejected Google/SSO sign-in is reported, not mistaken
for a keys page.

```bash
# real Chrome over CDP (avoids Google's "browser or app may not be secure")
./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action login --browser chrome-cdp
./scripts/browser-python.sh scripts/rotate-guided.py --provider anthropic --action revoke
```

Recommended for a destructive revoke: `--action open` takes you to the keys
page (login verified), you do the row-level **Actions → Revoke** and **Create
key** in the browser, then `--action capture` reads the copied key and writes
`.env.local` (prefix-validated, clipboard cleared, value never printed). Full
`--action rotate` is best-effort; the row-level revoke menu is brittle, so a
human click is safer.

**In-app key entry (2026-11-11).** One-time host setup:
`./scripts/key-request-install.sh` (systemd user path unit; no sudo). Then:

1. `xdg-open "https://localhost:5099/app/#settings"` — or Overview -> **Provider keys**, or a provider row -> **set key**.
2. Choose the provider, paste the key, type the provider id, click **Queue key**.
3. The host writes `.env.local` (0600 + backup), deletes the request, and restarts `opencode-web`; hard-refresh if the PWA shell is stale.
4. If the provider is paused, resume/clear it first; otherwise `settings-apply` will comment the new key.

The **copy cmd** button only copies the rotate CLI command; **console** opens the vendor page. The key is never displayed or logged.

`--browser chrome-cdp` launches **real Chrome** with a dedicated persistent
profile (no `--enable-automation`), attaches over CDP, and keeps the login
profile across runs; `--browser auto` prefers an existing CDP endpoint, then
real Chrome, then Playwright's bundled Chromium. Google/SSO rejections are
reported, never treated as a keys page.

## 2026-11-10 — network UX + hardening close-out

**The persistent "10.100.0.1 disconnected" popup was real but misdiagnosed.**
Powersave is off on both ends. The client is a BCM4331 on `b43`, **2.4 GHz
only**, and lost 101 Wi-Fi beacons in 6 h; the server is on 5 GHz and stable.
The popup persisted because critical alerts used `notify-send -t 0` (never
expire), the server paged on the first missed probe, and recovery never
withdrew the alert. The Reconnect button also looked live when no client watcher
was consuming it.

New/updated:

- **`scripts/peer-health.sh`** — one evidence-backed verdict. Probes ICMP, SSH,
  TCP `:5099`/`:4096`, and Tailscale; separates **reachability** from **link
  quality**; applies hysteresis; writes `data/observability/peer-health.json`.
  `--explain` states why (e.g. `beacon_loss=101 driver=b43 band=2.4GHz
  powersave=off`), `--json`, `--watch`, `--self-test`.
- **`scripts/wifi-link-forensics.sh`** — cross-host Wi-Fi evidence
  (`--peer`), verdicts (`beacon-loss`, `driver-b43`, `2.4-only`, `path-flap`,
  `dns-commit-failure`), `--fix` to disable/persist powersave.
- **`scripts/hotspot-reconnect.sh`** — bounded TTL, replace-by-id, recovery
  clear (even when silenced), server-side failure hysteresis, and evidence in
  the notification body. `--watch` is terminal-quiet by default (`--verbose`
  for ticks), auto-resolves the session bus and X11 display, and reports a
  broken channel once instead of every tick. On X11 the popup must be raised in
  the **client's** session: `--server --watch --notify-remote owner@100.70.43.78`
  sends it over SSH into the client's own notification daemon (the server's
  daemon would display on the server). Diagnose with `--notify-check`, show a
  live test with `--notify-test`, withdraw a stale popup with `--clear-notify`;
  silence the beep with `--no-bell` or the ticker with `--quiet-terminal`.
  The server probe now treats a successful **SSH** (or Tailscale `pong`) as
  connected before blaming the optional `:5099` dashboard port, so a laptop that
  is running opencode over SSH is not reported as disconnected. Notification
  buttons act: open dashboard, run check (prints state/link/beacon evidence),
  silence 1 h, dismiss (suppressed for `HOTSPOT_DISMISS_SEC`, cleared on
  recovery), reconnect (queues + confirms), and **Fix Wi-Fi (wl)** (opens the
  reversible Apply/Cancel durable-driver confirmation).
- **Bluetooth-coexistence intervention** — `scripts/bluetooth-off.sh` powers
  off the Bluetooth **radio** (`rfkill block bluetooth`) and pins it off with
  `bluetooth-off.service`; `scripts/b43-tune.sh` sets `options b43 btcoex=0`,
  pins `belkin2` to the 2.4 GHz BSSID, sets `band bg` and powersave off, and
  auto-recovers if the live reload loses Wi-Fi. Applied on `.1`: BT
  `Soft blocked: yes`, `btcoex=0`, pinned `24:F3:E3:52:1A:06`, connected.
  `.24` service is already disabled; its radio needs one `sudo rfkill block
  bluetooth` (no passwordless sudo). Rationale, measurement plan (24–48 h
  `BEACON-LOSS` baseline) and rollback: `docs/BT-COEXISTENCE-2026-11-10.md`.
- **Beacon-loss measurement** — `scripts/beacon-watch.sh` counts
  `BEACON-LOSS` per hour and splits at the intervention timestamp
  (`~/.local/state/b43-tune.applied`). Measured 24 h split on `.1`:
  total **185**, pre-intervention **184**, post-intervention **1** (post event
  20:54:42; intervention 18:20). The post rate is far below the clustered pre
  baseline but not zero; keep watching 24–48 h. This avoids counting pre-fix
  history as post-fix evidence.
- **Hardware recognition + b43 A/B** — `scripts/hardware-profiles.json` and
  `wifi-link-forensics.sh --json` now natively recognize the client as
  `14e4:4331` = Broadcom BCM4331, `b43`, 2.4 GHz-only, `known_bad_wl=yes`,
  firmware 666.2, `btcoex=1`/`qos=0`/`nohwcrypt=1`, Bluetooth active.
  `scripts/wifi-ab-benchmark.sh` runs an A/B/A Bluetooth on/off benchmark
  without restarting Wi-Fi (beacon-loss, tx/rx-drop, ping loss/latency,
  bitrate). A 20 s screen was inconclusive (beacon loss 0, ping-loss drift was
  not BT-correlated); run `--duration 300+` or the `btcoex=0` module-param test
  for a real signal. The durable path remains a USB WiFi/Ethernet adapter.
- **Durable Wi-Fi fix** — `scripts/wifi-durable-fix.sh` replaces `b43` with the
  vendor Broadcom `wl` driver (`akmod-wl`/`kmod-wl`), hard-blocks the
  conflicting in-kernel drivers (`install b43 /bin/false`), forces `wl` and
  omits `b43`/`bcma`/`ssb`/`brcmsmac` in the initramfs, adds a `modules-load.d`
  entry for `wl`, rebuilds the initramfs, and arms a boot guard. `--rollback`
  restores `b43`; `--recover-now` stops/disables the guard and restores `b43`
  **without a reboot**. The guard waits `WIFIDF_GUARD_WAIT` (600 s) and requires
  Layer 3 (a gateway ping), not just `wl`+NM state. Because the driver renames
  the interface, the apply sets the NM connection zone
  (`WIFIDF_NM_ZONE=trusted`) and the guard adds the live interface to it. The
  client popup's **Fix Wi-Fi (wl)** button opens an Apply/Cancel confirmation
  and runs it detached. The 2026-11-10 attempt rolled back twice: the first
  `akmods` build took ~6 min (longer than the original 240 s), and the second
  boot still loaded `b43` despite `blacklist b43`. The final hardened attempt
  loaded `wlp2s0`, but `wpa_supplicant` never associated and the interface got
  no IP (the unmaintained Broadcom STA driver cannot scan/associate on this
  BCM4331 + Fedora 43). `--check` now reports `known_bad=yes` and `--apply`
  refuses unless `WIFIDF_FORCE=1`. For this hardware use a **USB WiFi adapter
  with an in-kernel driver** or **USB/Thunderbolt Ethernet**; b43 remains the
  automatic fallback. Live check on `.1`: `driver=b43 rpmfusion=yes
  wl_available=yes known_bad=yes actionable=no`.
- **Activity search** — typing a query now searches `/api/search` across **all
  sessions**, not the 12-session live window; “Show all” expands the real hit
  set. `full=1` returns the whole part (20k-char cap), so **Expand shows the
  full message**, not the 200-char search-card teaser. The request has a 45 s
  budget (the 12 s default could abort a cold worker and show a false “No
  matches”), falls back to the fast FTS `/api/semantic` index, and distinguishes
  “timed out” from “no matches”. The UI must be hard-reloaded once to drop the
  cached shell.
- **`scripts/install-global-guard.sh`** — the global blacklist-guard link was
  dangling (`/workspace/...` on the host), so the guard silently did not load.
  It now resolves to the checkout and `test-hygiene.sh` gates it.
- **Guard matcher** — separators (`&& sed`, newline), absolute paths,
  `sudo`/`env`/`xargs` prefixes, quoting/backslashes, `rm -fr`,
  `--recursive --force`, pipe-to-interpreter, `source <(curl …)`,
  `opencode debug config`, `base64`/`cp`/`cut` host reads, `set -o errexit`, and
  `subprocess` import forms are covered by regression rows.
- **Security defaults** — dashboard Basic auth (when
  `OPENCODE_SERVER_PASSWORD` is set) + opt-in CORS + a per-response CSP nonce
  (no `unsafe-inline` scripts); the semantic classifier is opt-in and redacts
  secrets before upload; X11 defaults to untrusted; the `auth.json` writer
  forces `0600` and the rotation tool no longer prints key bytes; `harvest.py`
  blocks `file://` and private/loopback/metadata targets by default; the
  container key defaults to OpenSSH `restrict`; Dockge publishes on loopback
  only (the Docker socket is still mounted, so treat Dockge as root-equivalent).
  `security-posture.sh --offline` checks all of these invariants. `secret-scan`
  no longer false-positives on `process.env` / `os.environ` reads.

Rebuild the MUI bundle after editing `web/src` (the built `web/dist` is
gitignored and served from disk):

```bash
( cd web && npm ci && npm run build )
```

Full detail and the unresolved queue:
[`docs/OUTSTANDING-ISSUES-2026-11-10.md`](docs/OUTSTANDING-ISSUES-2026-11-10.md)
and [`docs/SECURITY-AUDIT-2026-11-10.md`](docs/SECURITY-AUDIT-2026-11-10.md).

## Start here (first 10 minutes)

If you are new, read in this order:

1. this README (what exists and how to start it),
2. [`docs/HANDOFF-2026-11-05.md`](docs/HANDOFF-2026-11-05.md) (current handoff),
3. [`HANDOFF.md`](HANDOFF.md) (durable history and PINs),
4. [`RULES.md`](RULES.md) (constraints the scripts enforce),
5. [`TODO.md`](TODO.md) (what is queued),
6. [`scripts/README.txt`](scripts/README.txt) (one entry per tool).

Minimal path:

```bash
cd ~/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
# 1. secrets live in .env.local (mode 0600); never print them
#    required: DEEPSEEK_API_KEY, OPENCODE_SERVER_PASSWORD
#    optional: JEV_API_KEY (cloud Jev is disabled), SUBQ_API_KEY
./scripts/web.sh              # start/recover web + caddy
./scripts/preflight.sh        # fail-closed health + budget check
./scripts/harness.sh --fast   # gates, telemetry, cost, TODO
```

Then open the agent at `https://10.100.0.24:4096` (Basic auth from
`.env.local`) and the dashboard at `https://10.100.0.24:5099`. The MUI app is
`/app/`; use `https://10.100.0.24/app/` (443) if you want no port. Trust the CA
once with `./scripts/trust-ca-client.sh --server https://10.100.0.24:5099` or
download `/ca.crt`. `10.100.0.1` is the client PC, not the server.

## Remote client: clipboard, network, self-heal (2026-11-08)

### How we got here

- **Symptom:** pasting into the agent failed from a terminal that reached the
  server over SSH, while the browser worked. Two causes, both now gated:
  1. a display-less SSH shell has no `DISPLAY`, so `xclip` can only see the
     *server* clipboard, not the client's;
  2. an advertised **image** flavour makes OpenCode's paste probe
     (`hasClipboardImage`/`fromClipboard`) log `ImageDecodeError` and abort the
     prompt ("Failed to send prompt").
- **Fix path:** `scripts/clipboard-preflight.sh` (RULE #95) gates the paste
  path and exits `3` on an image flavour (`--clear-text`); a guarded `~/.bashrc`
  block plus `rotate-server-password.sh` recover `DISPLAY` for interactive
  shells; `scripts/network-change-probe.sh` proves the access plane after a
  roam (`--watch`, and `--peer HOST` for the client side).
- **Trust decision:** `ssh -Y` each time is not reproducible. X11 trust is now
  encoded once in a managed `~/.ssh/config` Host block by
  `scripts/ssh-x11-setup.sh` (`ForwardX11 yes` plus `ForwardX11Trusted yes`,
  scoped to that one Host; keepalives so a roam reconnects and is detected).
- **One shot:** `scripts/client-setup.sh` composes those pieces so a fresh
  client is configured with a single command and repairs itself afterwards.

### Where we are

- The server is `ws24` (`10.100.0.24` Nebula, `100.119.125.16` Tailscale,
  `192.168.4.24` LAN). The client is `10.100.0.1`. `10.100.0.24` is stable
  across the client's LAN changes, so it is the default target.
- `scripts/client-setup.sh` discovers a reachable address (mesh → Tailscale →
  LAN), writes the managed SSH block, checks the local X server (XQuartz on
  macOS), and installs a **self-heal timer** (systemd user on Linux, launchd on
  macOS) that re-discovers the server and refreshes the block after a network
  change. It is dependency-free (pure-bash editor, no `python3`, macOS
  `bash 3.2` safe) and keeps a custom alias/user/trust across heals.
- The timers: `opencode-client-heal.timer` (Linux) /
  `com.opencode.deepseek.jev.client-heal` (macOS), every 5 minutes.
- Both self-heal and the server-side watchdog are self-tested: `harness.sh` is
  **4/0** (lint, test-hygiene, test-patterns, test-dashboard).

### How to use

```bash
# One-time, on the client (Linux or macOS):
git clone https://github.com/swipswaps/opencode-deepseek-jev
./opencode-deepseek-jev/scripts/client-setup.sh      # discover + configure + install timer

# Daily use:
ssh opencode-jev                                     # managed alias (X11 + keepalives)
./scripts/client-setup.sh --check                    # platform, host, reachability, X server, timer
./scripts/client-setup.sh --heal                     # one repair pass (the timer runs this)
./scripts/client-setup.sh --discover                 # print the chosen server and exit
./scripts/client-setup.sh --uninstall                # remove SSH block + timer
./scripts/overlay-status.sh                          # read-only audit of BOTH .24 and .1
```

Options: `--server HOST` (skip discovery), `--candidates "a b c"`,
`--prefer mesh|tailscale|lan`, `--alias NAME`, `--user USER`,
`--interval SEC`, `--untrusted`, `--no-heal`, `--quiet`, `--install-deps`
(best-effort; installs XQuartz via `brew` on macOS).

Notes:

- Clipboard still crosses the network only through X11 forwarding: the server's
  `xclip` talks to the client's X server. On macOS install/run **XQuartz**; the
  setup tries to start it. On Linux run this on the desktop session that owns
  the clipboard.
- Reachability comes from the mesh: the client needs Nebula (or Tailscale) up to
  reach `10.100.0.24` when the two machines are on different networks. The
  script falls back to the LAN address when they share one.
- Changing networks (for example the `10.100.0.1` laptop to a phone hotspot):
  run `./scripts/hotspot-test.sh --before`, switch the laptop to the hotspot,
  then `./scripts/hotspot-test.sh --after` (or `--auto` to be prompted). It
  settles up to 20s for a re-handshake, then requires **either** overlay
  (Nebula `10.100.0.24` **or** Tailscale `100.119.125.16`) to answer
  `:4096`/`:5099`; `--require mesh|tailscale` pins one. It also checks the LAN
  address as the control, DNS, and runs `client-setup.sh --heal`.
- `192.168.4.45` (`10.100.0.1`) is the **Nebula lighthouse**. Moving a
  lighthouse behind a phone hotspot/CGNAT removes the inbound UDP anchor peers
  need to re-handshake, so Nebula can fail while Tailscale survives (this is
  TUNNEL-1, `proxmox-dual-plane-mesh#5`). For that box, pin the reachable path:
  `./scripts/client-setup.sh --prefer tailscale`, or keep the lighthouse wired.
- The server-side `./scripts/network-change-probe.sh --peer 10.100.0.24` is the
  same acceptance test from the other side; `--peer <LAN-IP>` proves the
  same-network path. Both must print `VERDICT: PASS`.
- Debug: `./scripts/client-setup.sh --check`, `./scripts/clipboard-preflight.sh`,
  and the heal log at `~/.local/state/opencode-client-heal.log`.

## What runs where

| Piece | Type | Where | Address | What it does |
|---|---|---|---|---|
| `opencode-web` | container | Docker | `:4096`, `:5099` | agent web UI + dashboard sidecar |
| `caddy` | container | Docker | `:443`, `:4096`, `:5099` | TLS edge; loopback + Nebula + LAN + Tailscale |
| `litellm` | container | Docker | `127.0.0.1:4000` | local model proxy / master key |
| `litellm-db` | container | Docker | internal | private Postgres for proxy auth + spend |
| `opencode-grafana` | container | Docker | `127.0.0.1:3001` | optional ops view (may be paused) |
| `dockge`, `mesh-console`, `paypal` | containers | Docker | internal | optional services |
| `ollama` | host service | host | `127.0.0.1:11434` | optional local models (RAG) |
| `scripts/*` | host tools | host | — | gates, runbooks, rotation, recovery |

Data lives under `data/` (`opencode/` store, `observability/` logs and DBs).
`.env.local` is the only secret store; it is 0600 and gitignored.

## Project words (not acronyms)

- **Jev** — the name of this stack; also the old cloud guard/review service.
  Cloud Jev is **disabled by policy** (2026-10-21).
- **SubQ** — the current guard backend (`JEV_BASE_URL=https://api.subq.ai`),
  reached through `jev-guard`, a plugin that classifies tool calls.
- **Laya** — optional self-hosted model server for the same guard protocol;
  slower on this CPU, used for batch/A-B only.
- **RAG** — the separate retrieval engine at
  `~/Documents/2282af3557819803/repo/production-local-rag`.
- **Harness** — this repo's gate/telemetry/learning layer (`scripts/harness.sh`).
- **TLS / HTTPS** — Caddy serves `443`, `4096`, and `5099` on loopback, `10.100.0.24` (Nebula), `192.168.4.24` (LAN), and `100.119.125.16` (Tailscale). Canonical URLs use the ports (`:5099`, `:4096`); the 443 site redirects `/5099` and `/4096` to those ports for convenience. The cert SANs cover all of them plus `localhost`/`127.0.0.1`. Download the public CA at `https://10.100.0.24:5099/ca.crt` and trust it once (or run `./docker/certs-trust.sh` on the host). `10.100.0.1` is a **client** address (the PC), not the server; use `.24`.
- **Dashboard** — the read-only `:5099` observability UI; it is not the agent UI.

## Common tasks

| I want to... | Run |
|---|---|
| start / restart / stop the web stack | `./scripts/web.sh` / `./scripts/web-restart.sh` / `./scripts/web-stop.sh` |
| check current state | `./scripts/preflight.sh`, `./scripts/harness.sh --fast` |
| run the full delivery gate | `./scripts/harness.sh` |
| diagnose a sick host | `./scripts/doctor.sh` |
| read logs | `./scripts/logs.sh --source error|guard|signal` |
| triage a known log signature | `./scripts/incident-resolve.sh --db --auto` |
| rotate provider keys | `./scripts/rotate-provider-keys.sh`, `./scripts/open-rotation-pages.sh --open` |
| set up / repair the LiteLLM DB + UI | `./scripts/litellm-db.sh --apply` |
| verify the guard | `./scripts/guard-verify.sh` |
| run the adversarial gate | `./scripts/red-team.sh` (`--offline` skips SubQ) |
| audit security posture | `./scripts/security-posture.sh` |
| rotate the TLS leaf (same CA) | `./scripts/rotate-tls.sh --apply --yes` |
| monitor/self-heal HTTPS + CA | `./scripts/https-selfheal.sh --check` / `--fix --watch` |
| trust the CA on the PC | `./scripts/trust-ca-client.sh --server https://10.100.0.24:5099` |
| refresh screenshots | `python3 scripts/panels-tour.py --no-video` |
| scrub leaked artifacts | `./scripts/scrub-secrets.sh --apply --yes --purge-snapshots --purge-env-backups` |
| inspect model policy/cost | `./scripts/models.sh`, `./scripts/cost.sh` |
| use the RAG engine | `cd ../2282af3557819803/repo/production-local-rag && ./scripts/04-retrieval-only.sh --query "..."` |

## If something is wrong

- **`Certificate invalid: name is not a listed principal`** on
  `ssh owner@10.100.0.1`: re-sign the client host cert with the address as a
  principal (the CA key stays on the client):
  `ssh owner@10.100.0.1 'bash /tmp/host-cert-sign.sh --sign'` (or copy
  `scripts/host-cert-sign.sh` and run `--sign`). Verified after the 2026-11-10
  re-sign: principals include `10.100.0.1` and the warning is gone.

- **opencode TUI overlap or `[Image 1]` instead of pasted text:** a server
  `wall` broadcast writes into the full-screen TUI. `hotspot-reconnect.sh` now
  logs via `logger` and sends a notification; `HOTSPOT_WALL=1` opts back in.
  For paste, the clipboard holds an image or an image path (e.g. the screenshot
  path), so opencode's paste handler inserts `[Image 1]`. Clear it with
  `printf '' | xclip -selection clipboard`, copy the text lines, and paste with
  **Ctrl-Shift-V** (or Shift-Insert); `Ctrl-V` can be the TUI's image paste.
  The durable offer is persistent: a body click keeps it open; **Cancel** ends
  it. Re-open it with `bash scripts/hotspot-reconnect.sh --offer-durable`.

- `preflight.sh` prints **STOP** for a missing key, a red last gate, low
  balance, an off-policy model, or an over-budget session. Fix the named cause;
  do not bypass it.
- Caddy publishes on the wildcard address (`ports: - "4096:4096"`), so a missing
  DHCP/tunnel IP cannot abort the bind. `web-health.timer` re-probes every 2 min
  and re-runs `web.sh` on failure; `WEB_BIND_IPS` still overrides the legacy wait list.
- The LiteLLM admin UI is DB-backed: `./scripts/litellm-db.sh --apply` starts
  the private `litellm-db`, writes `LITELLM_DATABASE_URL`, and proves
  `admin` + `LITELLM_MASTER_KEY` login. If the UI says **"Not connected to
  DB!"**, run that script before trying the console.
- A guard `401` means the running web container has an old/revoked key.
  `env_file` is read at container creation: recreate the web container to pick
  up `.env.local`.
- Host-secret reads (`/etc/passwd`, `~/.ssh`, `~/.aws`, `/proc/*/environ`) are
  blocked by the blacklist `sensitive-read` rule. A changed plugin loads only
  in a new process: `./scripts/web-restart.sh --recreate` (drops the session).
- If `rotate-tls.sh --check` says the live key matches a snapshot, run
  `./scripts/rotate-tls.sh --apply --yes` (same CA, so clients keep trust).
  Then run `./scripts/scrub-secrets.sh --apply --yes --purge-snapshots`
  yourself; the agent guard blocks destructive purges by design.
- `./scripts/incident-resolve.sh --db --auto` classifies recurring signatures
  (tmux no-server, already-paused, embedding cold-load, `pgrep` >15 chars,
  pubkey denial, guard blocks, stale edits) and resolves the safe ones.

## Security posture (residual risks)

- `./scripts/security-posture.sh` checks the invariants that are not one
  command: host-home exposure, container caps/user, loopback-only LiteLLM,
  secret-file modes, artifact cleanliness, TLS, the local red-team layer, and
  the 2026-11-10 hardening set (dashboard auth/CORS, semantic opt-in +
  redaction, untrusted X11 default, `auth.json` `0600`, `harvest.py`
  SSRF/local-read block, non-dangling global guard link, bounded hotspot
  notifications). Run `--offline` when Docker is unavailable.
- Residual risks and the exact next action for each are tracked in
  [`docs/OUTSTANDING-ISSUES-2026-11-10.md`](docs/OUTSTANDING-ISSUES-2026-11-10.md).
  The client Wi-Fi root cause (b43/2.4 GHz beacon loss) still needs a driver or
  wired-link change; dashboard auth takes effect on the next restart.
- The compose override no longer mounts `/home/owner`. The repo is still
  mounted at `/workspace`, so `.env.local`, `docker/litellm-db.env`, and
  `docker/certs/*` were readable by the web container. The override now hides
  them with empty binds (`/dev/null`, `empty-certs`); the **running** container
  still needs `./scripts/web-restart.sh --recreate` to apply them. The file-level
  posture check is **22 pass / 1 fail** (the one fail is the host `../notes/`
  secret finding). `.env.local` values still enter the container environment
  because the app needs them; a separate app/agent user is the next structural
  step.
- The RAG repo is mounted read-only at `/rag`. Host access uses the durable
  `~/.config/opencode/container_key`, authorized with OpenSSH `restrict` **by
  default** via `authorize-container-key.sh` (2026-11-10; `RESTRICT=0` is the
  explicit opt-out). A pre-existing unrestricted line must be removed and
  re-authorized. The host home is not mounted.
- Tool results are scanned for prompt-injection markers and logged as
  `"verdict":"injection"` (advisory, value-free). This is telemetry, not
  prevention: model-level prompt injection remains a residual risk.
- The regex blacklist and `sensitive-read` are defense-in-depth, not a sandbox.
  The LiteLLM UI is `127.0.0.1:4000`; Postgres has no published port.

## Read next

- Detailed tool catalog: [`scripts/README.txt`](scripts/README.txt)
- Roadmap/PR bodies: [`docs/plans/README.md`](docs/plans/README.md)
- RAG engine README: `~/Documents/2282af3557819803/repo/production-local-rag/README.txt`
- Horizon and lessons: [`ECC-SKILLS.md`](ECC-SKILLS.md), [`HANDOFF.md`](HANDOFF.md)

## Glossary — acronyms and rule citations

**Rule citations.** A rule is cited by **name, number, and link** — for example
[RULE #67 — Telemetry/visualization doctrine](RULES.md#rule-67) — never by a
bare number. [`RULES.md`](RULES.md) is the source of truth; each anchor lands on
the rule's row and carries its enforcement text plus evidence of use.

**Acronyms** used in this document, with their expansions (each is also spelled
out at its first prose use where the abbreviation could be ambiguous):

| Acronym | Expansion |
|---|---|
| API | Application Programming Interface |
| ARIA | Accessible Rich Internet Applications (W3C specification) |
| ASK | Ask-tier: a model policy verdict that requires human approval |
| BM25 | Best Matching 25 (a ranking function for full-text search) |
| CA | Certificate Authority |
| CDP | Chrome DevTools Protocol |
| CLI | Command-Line Interface |
| CSV | Comma-Separated Values |
| DB | Database |
| DNS | Domain Name System |
| DOM | Document Object Model |
| ECC | The external ECC skills catalog (`github.com/affaan-m/ECC`) |
| FTS5 | Full-Text Search version 5 (SQLite extension) |
| HTTP / HTTPS | Hypertext Transfer Protocol / HTTP Secure |
| JS | JavaScript |
| JSON | JavaScript Object Notation |
| LAN | Local Area Network |
| MCP | Model Context Protocol |
| NSS | Network Security Services (Mozilla certificate store) |
| OCR | Optical Character Recognition |
| REST | Representational State Transfer |
| RFC | Request for Comments (IETF standards document) |
| SAN | Subject Alternative Name (TLS certificate field) |
| SQL | Structured Query Language |
| SSE | Server-Sent Events |
| TLS | Transport Layer Security |
| TTL | Time To Live |
| TUI | Terminal User Interface |
| UI / UX | User Interface / User Experience |
| UID | User Identifier |
| URL | Uniform Resource Locator |
| WAI | Web Accessibility Initiative (W3C) |
| WAL | Write-Ahead Logging (SQLite journal mode) |
| WCAG | Web Content Accessibility Guidelines (W3C) |

## Current state — 2026-11-03 (CPU recovery + resource telemetry)

### How we got here
- The host (`.24`) had a platform/EC frequency lock: all Ryzen 7 4700U cores at
  **399 MHz** with `scaling_max_freq=2000 MHz` and governor `performance`. An
  EC reset (power off, unplug AC, pinhole/power hold, boot) restored
  **3.2–4.2 GHz**. The runbook records the baseline and compares after reboot.
- Caddy once exited **255** at Docker start because it bound specific host
  addresses (`192.168.4.24:4096`, `10.100.0.24:4096`, `127.0.0.1:4096`) before
  those addresses were assigned. It now publishes on the wildcard address, so
  every present interface (loopback, LAN, Nebula `10.100.0.24`, Tailscale)
  reaches it and a missing one cannot abort the set. `scripts/web-health.sh`
  runs from a 2-minute timer: it rotates TLS SANs on a network change and
  re-runs `web.sh` when a client path is down. `WEB_BIND_IPS` overrides the
  legacy per-IP wait list; `docker compose up -d opencode-web caddy` is still
  the manual recovery.
- Dashboard commit `65b8d41` adds `GET /api/resources` (cgroup, PSI, RSS, SSE
  clients), a nav badge (`cpu <psi>% rss <MB> live <n>`), and segment controls:
  `DASH_SEGMENTS`, `DASH_SSE_MS`, `DASH_AUTO_SHED` (drop activity when CPU
  PSI > 30).

### Where we are
- Stack: `opencode-web` + `caddy`, Basic auth from `.env.local`; web UI
  `https://127.0.0.1:4096` (401 = alive), dashboard `https://127.0.0.1:5099`
  (or `10.100.0.24:5099`). `/api/resources` and `/api/rev` return 200.
- CPU recovered; contention remains from the web/opencode process, the
  dashboard sidecar, Chrome, and optional containers. The dashboard stays
  enabled; use the toggles or `05-resource-toggles.sh` in the RAG repo.
- Bottleneck migration after the EC reset: CPU PSI is low (`cpu_psi_10` < 1)
  while I/O PSI can be high (observed `full` ~60%). Check for `updatedb`/
  `plocate` scans and dashboard DB/SSE load; reduce with `DASH_SSE_MS`,
  `DASH_SEGMENTS`, or `DASH_AUTO_SHED`.
- RAG engine: `~/Documents/2282af3557819803/repo/production-local-rag`
  (v1.3.1 + hardening): CLI, retrieval-only MCP (`search_docs`/`status`),
  tests, and runbooks 01–06. Retrieval works; local generation is optional.
- `reload-opencode-web.sh` is obsolete; `scripts/web.sh` and
  `scripts/web-restart.sh` are the canonical entry points.

### How to use now

```
cd ~/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
./scripts/web.sh            # start/ensure web + caddy (wildcard bind + retry)
./scripts/web-restart.sh    # restart
./scripts/web-logs.sh       # logs
./scripts/web-stop.sh       # stop
```

```
curl -sS https://127.0.0.1:5099/api/resources   # resource/segment telemetry
DASH_SEGMENTS=cost,activity,todos
DASH_SSE_MS=5000
DASH_AUTO_SHED=1
```

```
cd ~/Documents/2282af3557819803/repo/production-local-rag
./scripts/rag-cli.sh status
./scripts/04-retrieval-only.sh --query "What is the pet policy?"
./scripts/06-runbook.sh --phase 1 --stress 10
```

- Desktop: `~/.local/share/applications/opencode-web.desktop` and
  `~/Desktop/opencode-web.desktop` run `~/.local/bin/opencode-web-launch.sh`.
- If the host IP changes, nothing to edit: the wildcard bind follows the
  interface and `web-health.sh` rotates the cert SANs. `WEB_BIND_IPS` remains an
  override for a legacy per-IP compose.
- The 2026-10-16 status below is historical.

## Status — 2026-10-16 (historical)

### How we got here
A dockerized OpenCode + DeepSeek + Jev stack with a read-only `:5099` dashboard,
grown a fail-closed monitoring family (**sentinel T1–T7**, cursor-bounded,
de-cry-wolfed via stable per-incident ledger keys), a zero-dependency
**Chrome DevTools Protocol (CDP)** browser path
([**`cdp-tab.mjs`**](scripts/cdp-tab.mjs); see
[RULE #62 — Drive a live browser over CDP, never X11 automation](RULES.md#rule-62)
and [RULE #64 — Benchmark-informed browser-driver choice with failover](RULES.md#rule-64)),
a user-experience (**UX**) gate ([**`ux-smoke.py`**](scripts/ux-smoke.py),
**Document Object Model (DOM)** + local **Optical Character Recognition (OCR)**
`--vision`) with a **light theme** so tesseract can read
([RULE #65 — Prefer local OCR over a paid cloud vision-language model](RULES.md#rule-65)
and [RULE #66 — Light theme so local OCR can read the screen](RULES.md#rule-66)),
and the telemetry doctrine
([RULE #67 — Telemetry/visualization doctrine: declarative, database-driven,
drill-down-native](RULES.md#rule-67) +
`.opencode/skills/telemetry-dashboard`: Grafana/Vega-Lite/TanStack; not Flutter).
Fixed the served-page defects the operator hit (time-zone labels, poll-loop
freeze, STALE-revision banner, empty Session-detail, inline-expand collapse,
buried Gantt). Full causal chain in `HANDOFF.md`.

### Where we are
- Sentinel **T1–T7**; ledger deduped; DB-only **digests** auto-written on a trip;
  alerting now **fires** (`sentinel.sh` → `notify.sh` when `NOTIFY_WEBHOOK` is
  set; the unit loads `.env.local`).
- Dashboard: **clickable Gantt** (bar → in-page span timeline with per-part ms),
  a **Flags** panel (bottlenecks · cost · slowdowns · stalls, clickable), a
  **projected-schedule estimate Gantt**, **trends** (cost/sessions per day), a
  **light theme**, and **snapshot→deltas Server-Sent Events (SSE)**
  (`/api/stream`) instead of polling. `/api/board` is **offloaded** to
  `query-worker.mjs`.
- Browser: `cdp-tab.mjs` (Node) + `browser_bench.py` failover; a **semantic
  beforeTool guard** (`guard-classify.py`) layered into `blacklist-guard.js`.
- Ops: `web-restart.sh` kills all dashboard pids before relaunch (no more `:5099`
  down-race); `host-path-probe.sh` breaks the hop into Domain Name System
  (DNS) / Transport Layer Security (TLS) / time-to-first-byte (TTFB);
  `tui-audit.py` audits a **terminal user interface (TUI)** session causally;
  and the browser/telemetry rules
  [#62 — drive a live browser over CDP](RULES.md#rule-62) ·
  [#63 — UI-only consent steps](RULES.md#rule-63) ·
  [#64 — benchmark-informed browser drivers](RULES.md#rule-64) ·
  [#65 — local OCR over cloud vision](RULES.md#rule-65) ·
  [#66 — light theme for OCR](RULES.md#rule-66) ·
  [#67 — telemetry/visualization doctrine](RULES.md#rule-67) ·
  [#68 — Claude is ASK-tier](RULES.md#rule-68) ·
  [#69 — durable-harness doctrine](RULES.md#rule-69)
  plus the `telemetry-dashboard` skill.
- **Host-only, pending:** the CDP-bound screenshot/video capture (needs Chrome on
  `:9222` or `playwright install chromium`), the host browser-venv wiring, and
  standing up Grafana.

### Next steps (in order)
1. **Capture the README media** — `python3 scripts/panels-tour.py` (per-panel
   screenshots + a `.webm` tour); needs a launchable chromium (host).
2. **Host browser stack** — point `ux-smoke.py` / `browser_bench.py` at the host
   venv (`/home/owner/.venvs/browser`) so the vision/failover legs have a home.
3. **Host path** — the probe shows the hop is **TLS-dominated**; cut the caddy
   handshake cost (Hypertext Transfer Protocol version 2, HTTP/2, keep-alive /
   CPU contention) or bypass it.
4. **Grafana + SQLite** (below) as the non-bespoke ops view.

### Optional: a hosted-grade ops view (Grafana + SQLite)
`docker/docker-compose.observability.yml` runs Grafana with the two SQLite
stores mounted read-only and a provisioned `frser-sqlite-datasource`. On the
host: `docker compose -f docker/docker-compose.observability.yml up -d` → open
`http://127.0.0.1:3000` (anonymous viewer on localhost). Use it for metrics,
**alerting**, **annotations**, and **saved views** instead of hand-rolling
panels ([RULE #67 — Telemetry/visualization doctrine](RULES.md#rule-67));
`:5099` stays the in-app view. Verify the plugin id/schema on first run.

### Screenshots (light theme)

Regenerate every panel + a short `.webm` tour with the scripted capture:
`python3 scripts/panels-tour.py` (needs a launchable chromium —
`playwright install chromium`; the sandbox lacks the system libs, so run it on
the host). It writes
`docs/ux/status-{home,overview,board,trends,signals,patterns}.png`, a focused
`docs/ux/status-timeline.png`, `docs/ux/status-mobile.png`, the four
`docs/ux/status-mui-*.png` shots, and `docs/ux/tour.webm`, shrinking each shot
under the 150 KiB image budget (from the original, so it never double-shrinks)
and recording a separate 960x540 tour under the 2 MiB video budget.
`python3 scripts/panels-tour.py --check` lists any expected shot that is still
missing (it reports, it does not fake a pass).

Dashboard home — **Flags** (bottlenecks · cost · slowdowns · stalls), sessions
with time-zone-labelled times, cost, and the combined activity timeline. The
mobile/MUI/PWA decision and sources are in
[`docs/UX-MOBILE-AUDIT.md`](docs/UX-MOBILE-AUDIT.md):

![Dashboard home](docs/ux/status-home.png)

Activity timeline — one card for the same `/api/activity` rows (no duplicate
list). Newest first, filter chips, 30/all toggle, expand/collapse and copy per
row, a start dot on the time axis, a relative-duration bar, and the exact
duration. The red dashed line is "now"; **copy JSON** copies the visible rows:

![Activity timeline](docs/ux/status-timeline.png)

Android layout at 390 px — no horizontal page overflow, 44 px touch targets,
single-column rows, and the activity card moved near the top. The manifest +
service worker pass Chrome's installability check (`Page.getInstallabilityErrors`
returns `[]`); use Chrome's **Install app** after trusting the local CA:

![Android activity timeline](docs/ux/status-mobile.png)

### Material UI app (`/app/`)

The full React version lives in `web/` (React 19 + Material UI 9.5 + Vite 8).
It reuses the same `/api/*` endpoints and has an Overview (including a 14-day
cost trend), Activity timeline (steps hidden by default; `/` focuses search;
`time · now`/relative-duration axis), Sessions (sort by recent/cost/tokens/
duration), and Todos. Desktop uses a permanent MUI Drawer; under `md` it uses a
MUI `BottomNavigation`; rows/cards stack at 390 px; Chrome's install prompt is
wired to a visible Install action. Hash routes preserve the view.
Build once:

```bash
cd web && npm ci && npm run build
```

`scripts/dashboard.mjs` serves `web/dist` at `/app/` and the hashed assets under
`/app/assets/*`; `/app-manifest.webmanifest` sets `start_url=/app/`. See
[`web/README.md`](web/README.md) for dev/PWA notes. The app is also installable (`Page.getInstallabilityErrors: []`) and the build is
571 kB minified / 176 kB gzip. The legacy no-build page at `/` remains.

A standalone **public Pages app** is live at
<https://swipswaps.github.io/opencode-observability/> (repo
`swipswaps/opencode-observability`). It probes `https://10.100.0.24:5099` and
renders the live MUI shell when the browser permits private-network access and
trusts the CA; otherwise it shows real captures from the live UI
(`status-mui-*.png`), never synthetic metrics. The dashboard permits only
`https://swipswaps.github.io` via CORS/PNA. The local `/app/` keeps the live
APIs. The new repo's Pages deploy is active and monitored with `gh`.

![MUI Overview](docs/ux/status-mui-desktop.png)

![MUI Activity](docs/ux/status-mui-activity-desktop.png)

![MUI Android Overview](docs/ux/status-mui-mobile.png)

![MUI Android Activity](docs/ux/status-mui-activity.png)

`/explore ▸ overview` — search everything + the compact sessions table:

![Explore overview](docs/ux/status-overview.png)

`/explore ▸ board · gantt` — Kanban (pending / in-progress / completed) + the
**clickable Gantt** + the **projected-schedule estimate**:

![Explore board](docs/ux/status-board.png)

`/explore ▸ charts` — **trends**: sessions & cost per day:

![Trends](docs/ux/status-trends.png)

`/explore ▸ signals` — **session health** (stalled / blank turns) + the guard
panel; a health finding drills into the session detail:

![Explore signals](docs/ux/status-signals.png)

`/explore ▸ patterns` — recurring tool-sequence n-grams + known fixes; each
bigram drills into an example session:

![Explore patterns](docs/ux/status-patterns.png)

A short click-through tour (960x540, six panels):
[`docs/ux/tour.webm`](docs/ux/tour.webm).

Clicking a Gantt bar drills into that session's **timeline in-page** (`detail()`):

![Gantt bar drilled into a session](docs/ux/status-gantt-drill.png)

See [RULE #62 — drive a live browser over CDP](RULES.md#rule-62) through
[RULE #67 — telemetry/visualization doctrine](RULES.md#rule-67),
`.opencode/skills/telemetry-dashboard`, `HANDOFF.md`, and `TODO.md` for the
full queue.

## Prerequisites
- Docker Engine (daemon reachable by current user)
- GitHub Command-Line Interface (`gh`), authenticated
- DeepSeek Application Programming Interface (API) key (prefix sk-)
  https://platform.deepseek.com/api_keys
- Jev API key (prefix apikey_)
  https://console.typesafe.ai/keys

## Quick Start
cd docker
./build.sh
./run.sh

Keys are cached in ../.env.local (mode 0600, gitignored).

## Vision / image input
DeepSeek V4.1 Flash natively ingests images. `opencode.json` declares this
(`attachment: true` + `modalities.input: ["text","image"]`), so OpenCode
sends screenshots to DeepSeek directly — no separate provider needed.
(OpenCode gates image input on the model's declared `modalities`; a custom
provider entry without that declaration is treated as text-only.)

If a model rejects an image anyway, read it locally instead:

    ./scripts/ocr-image.sh <image.png>      # tesseract Command-Line Interface (CLI), tesseract.js, or PaddleOCR
    ./scripts/ocr-image.sh --check          # report which engine is available

Each run is persisted to data/observability/ocr_run and surfaced in the
dashboard: /api/ocr lists runs, /api/export/ocr downloads Comma-Separated
Values (CSV), and the OCR
text is folded into /api/semantic so the search box finds screenshots too.

The engines match github.com/swipswaps/receipts-ocr: tesseract.js (browser)
and PaddleOCR (backend/app.py). **tesseract.js + pngjs are pinned in
package.json** and installed via `npm install`, so it reads screenshots out
of the box with no apt/pip and no API model; oversized images are
downscaled before OCR so very tall screenshots don't stall. `tesseract-ocr`
is also baked into the image. PaddleOCR is available with
`pip install paddleocr paddlepaddle`.

## Linting
    ./scripts/lint.sh

Static gate over the repo: `bash -n` on every script, `shellcheck` (baked
into the image), `node --check` on the JavaScript (JS) (including
`.opencode/plugins/*.js`), `py_compile` on the Python, a `subprocess.run`
check, a `scan-constraints.py` pass (code vs string/comment) over
`scripts/*.sh`, and a RULES grep (no `sed`, no `2>/dev/null`).

Every check line carries `ms=<wall time since the previous check>` and the
slowest check is named at the end — the actionable signal that a bare timeout
is not. `shellcheck` runs in parallel (one background job per file); serially
it was ~40s and was what pushed the combined gate past its budget.
`test-dashboard.sh` already runs `lint.sh` and `test-hygiene.sh`, so run it
alone rather than chaining all three (chaining doubles the lint cost).

If tool output looks empty, suspect suppressed streams: the blacklist guard
exists so `2>/dev/null` cannot hide the diagnostic. Audit with
`./scripts/audit-tool-calls.py` — it reports exactly which commands hid stderr.

## Blacklist enforcement (three layers)
The blacklist (`sed`, `2>/dev/null`, `subprocess.run`, `rm -rf`, `echo`) is
enforced at three points: files (`lint.sh` + `scan-constraints.py` fail the
build), runtime detection (`scripts/audit-tool-calls.py` reports what the agent
ran), and runtime prevention (`.opencode/plugins/blacklist-guard.js`, auto-loaded
from the plugin dir — no `opencode.json` entry, which would double-load it).
The guard hooks `tool.execute.before` and acts on the agent's own bash commands
during "Thinking" before they run: **block** (`sed`/`rm -rf`/`subprocess.run`,
throws with the substitute), **fix** (`2>/dev/null` — the redirect is removed so
stderr, the proof, reaches the result), **warn** (`echo`). Matching is
quote-aware (`grep 'sed'` passes). Policy: `OPENCODE_BLACKLIST_GUARD` =
unset/`block` | `warn` | `off`; reload with
`docker compose -f docker/docker-compose.yml restart opencode-web`. Full detail:
HANDOFF "Hygiene enforcement"; unit test: `blacklist-guard-self-test.mjs`.

## Writing prompts
A prompt is an interface contract: state the falsifiable outcome, the
constraints, and the evidence. This keeps the work checkable without
re-reading the whole chat — which is also what keeps context (and cost)
down. Template:

    ## Objective
    <one sentence: the falsifiable outcome>
    ## Context (read first)
    HANDOFF.md, RULES.md, README.md; <specific files / endpoints>
    ## Constraints (non-negotiable)
    RULES.md; blacklist enforced by .opencode/plugins/blacklist-guard.js;
    read-only over data/opencode/opencode.db.
    ## Deliverable
    <exact artifacts>
    ## Acceptance criteria (each independently checkable)
    - [ ] `<command>` prints `<expected>`
    - [ ] `./scripts/<gate>.sh` exits 0
    ## Evidence (paste back)
    gate outputs, `git diff --stat`, exact commands.
    ## Out of scope
    <what not to touch>

`./scripts/prompt-lint.py --prompt "..."` classifies a prompt, fuzzy-matches
it against past prompts, surfaces recurring errors, and flags blacklist
mentions / secrets / vagueness / missing acceptance criteria. Use it before
sending a large request.

To use a *different* vision model (e.g. Muse Spark via OpenCode Zen), on a
host terminal with browser access run `opencode`, `/connect` → OpenCode Zen,
`/models`. Avoid pasting secret-bearing screenshots to Free-tier models.

## Telemetry policy
Smoke tests stream stdout and stderr live via process substitution
(> >(tee file)). No buffering. The user sees the model's response
as it arrives. The safety timeout (120s) fires only if the process
genuinely makes no progress.

## Smoke test methodology
opencode 1.18.31 exits non-zero after a successful non-TTY (teletypewriter /
terminal) response.
The staging script asserts on response text ("OK") instead of exit
code. Elapsed time and exit code are reported for diagnostic purposes
but do not determine pass/fail.

## UID (User Identifier) handling
Container runs with --user $(id -u):$(id -g). /home/node is chmod 777
at build time.

## Secrets hygiene
- Keys never appear on docker CLI argv (bare -e VAR).
- curl Authorization headers written to mode-0600 temp files.
- .env.local is gitignored and mode 0600.
- The web user interface (UI, port 4096) requires OPENCODE_SERVER_PASSWORD; web.sh
  refuses to start without it (pass --insecure to override).
- Port 4096 is bound to 127.0.0.1 only (loopback). The password is the single
  gate, so it must not be the only thing between the service and a Local Area
  Network (LAN).
  Widening it is a three-part change — rotate first, widen only the publish
  line, then firewall the CIDR; see HANDOFF "Exposing 4096 to the LAN". Never
  widen the port alone.
- data/opencode/ and data/observability/ are gitignored, so session text and
  telemetry are never pushed. Session EXPORTS (/api/export/session, the sessions
  CSV) are **redacted** at the boundary by `scripts/redact.mjs` (key shapes and
  `NAME=value` assignments), so a leaked value in the transcript does not leave
  the system; `node scripts/redact.mjs` also filters stdin.
- Stale *.bak.* snapshots (including old .env.local.bak.* key copies)
  are removed with ./scripts/cleanup-baks.sh --apply.

## Logs
Full staging output captured to ../staging.log.

## Verification (V1 command surface)
opencode V1 has no "mcp list" subcommand. **Model Context Protocol (MCP)**
servers are read from opencode.json. The staging script verifies:
- opencode --help loads the binary
- opencode.json parses and lists mcp.servers keys via python3
- the image builds
- DeepSeek smoke test returns response text "OK"
- plugin list returns output (exit code informational)

## Cost monitoring
    ./scripts/cost.sh
    ./scripts/cost-bottlenecks.sh --top N

Prints DeepSeek cost accounting from two sources: the opencode database
(per-session USD cost and input/output/reasoning/cache tokens) and the
provider balance endpoint (https://api.deepseek.com/user/balance). The
API key is read from .env.local and never printed. Note that jev-review
MCP calls are billed separately by TypeSafe and do not appear in the
DeepSeek balance.

Model choice is the dominant cost lever. Keep the agent on `deepseek-flash`
(the opencode.json default) or a free model: a non-flash reasoning model
(e.g. `deepseek-v4-pro`) re-prices the whole context every turn — 2.9x the
input price. Three long "audit" sessions on v4-pro were ~94% of lifetime
spend at their peak; the live share drifts, so read it from
`cost-bottlenecks.sh` "model mix check" (or the /models page), not from a
hard-coded number. The ceiling is `models.policy.json`.

## Live activity ("thinking")
    ./scripts/thinking.sh            (terminal)
    ./scripts/dashboard.sh           (web: http://127.0.0.1:5099)

thinking.sh tails the opencode database and prints what the agent is doing
in real time: step boundaries, tool calls (with running/completed/error
state and the command), reasoning text, and answer text. dashboard.sh is
the same data in a read-only browser view, with cost cards and the todo
list. Both poll the database (2s) and run in the container and on the
host. Predictive cost: ./scripts/cost.sh --estimate IN OUT [REASONING].

The dashboard drills down. Click a session row to see its detail panel
(cost, tokens, span, message count) and the ordered tool/reasoning/text
parts. Each detail panel offers a per-session chat-history download as
txt, md, or json (/api/export/session). The search box runs ranked
full-text search across every session — text, reasoning, and tool
commands — via an in-memory SQLite **Full-Text Search version 5 (FTS5)** /
**Best Matching 25 (BM25)** index (/api/semantic).
http://127.0.0.1:5099/runbooks lists the operational runbooks (host vs
container) with copy buttons; ./scripts/runbook.sh runs them as a menu.
scripts/runbooks.json is the single source for both — add entries there, not
in dashboard.mjs. Entries include the blacklist guard (pause/resume), balance
top-up, and the log miner below. Note the dashboard on :5099 runs inside the
opencode-web container (web-entrypoint.sh starts it), so restarting that
container takes :5099 down for a few seconds.

## Learning from the logs
    ./scripts/issue-solutions.py [--top N]        # issues -> proven fixes
    ./scripts/logs.sh [--source S] [--since MIN]  # raw telemetry

Free, local, no model call. `issue-solutions.py` reads the chat database
read-only and pairs each error tool call with the next completed call in the
same session, then ranks the recurring (issue, fix) pairs with the log
evidence. Example output: "JEV_API_KEY rejected" x8 -> the env/`.env.local`
checks that fixed it; "Could not find oldString" x4 -> the grep that located
the real text. Run it with `--write` to persist
data/observability/solutions.json, served at /api/solutions and shown as
"known fixes" on /explore ▸ patterns.

`logs.sh` is the raw layer behind that: `--source guard` (every blacklist
block/fix/warn the agent's own "Thinking" triggered, from
data/observability/guard.log), `error` (tool failures + stack trace),
`event` (the opencode event bus), `app` (~/.local/share/opencode/log/
opencode.log), `system` (docker logs; host only), `packet` (the exact
tcpdump command). Use it when a step is slow or output looks empty — the
`ms=` telemetry names the slow check; `logs.sh` shows why.

## Repo code index
    ./scripts/code-index.py            # assemble + flag the repo's own code
    ./scripts/code-index.py --flags    # file:line flag list
    ./scripts/code-index.py --grep RE  # files whose path/symbols match

Indexes the repo's own code/config/docs (per-file metadata + top-level symbols)
into data/observability/code.db and flags blacklist patterns plus TODO/FIXME —
so code can be inspected alongside the chat database and, later, classified by
Jev/Laya/DeepSeek. Surfaced at /api/code and /explore ▸ code.

## Duplicate prompts (dedup / semantic cache)
`prompt-lint.py` flags a prompt that is >= 0.9 similar to a prior user prompt
(token Jaccard): reuse the prior answer instead of spending another session.
That is the local, deterministic form of a semantic cache.

`learn-rules.py` goes a step further: it builds **(state, action, outcome)**
triples from the log — the error signature, the shape of the next call, and
whether it completed — and emits advisory *avoid* / *prefer* / *recovery*
rules to data/observability/learned-rules.json. Run it with `--since-days` so
a stale pattern expires. The guard reads the rules and records `learned`
advisories; nothing is blocked until a confirmed pattern is promoted into
RULES.md / the guard's fixed blacklist. Learn → review → codify → enforce.

`TODO.md` is the running backlog: HANDOFF.md is the durable state, TODO.md is
the queue. Update both at the end of a session.

## Navigating the observability UI

Accessibility is a gate here, not a style note: `scripts/a11y-audit.mjs` checks
`lang`, title, viewport, heading order, a named `nav` landmark, the skip-link
target (`#main` with `tabindex="-1"`), accessible names for controls, a visible
`:focus-visible` outline, reduced motion, and WCAG contrast for both themes.
`test-dashboard.sh` runs it against the scratch build on every gate.

Every page (/ dashboard, /explore, /runbooks, /docs) shares one sticky nav:
`dashboard · explore · models · runbooks · manage · docs · csv`. The /explore tabs
(overview · charts · signals · ocr) are linkable and restore from the Uniform
Resource Locator (URL) hash, so `http://127.0.0.1:5099/explore#charts` opens the
charts tab and the
browser back/forward buttons work. /docs renders this repo's own HANDOFF.md,
RULES.md, README.md, scripts/README.txt and HANDOFF-PROMPT.txt in-UI
(read-only, whitelisted names via /api/doc), so the rules are reachable
without leaving the browser. /manage (API /api/tools, source scripts/tools.json)
surfaces the repo's tools — purpose, host/container, copyable commands — so the
scripts are discoverable from the UI, not only the terminal. The nav shows the
**served git revision**; if the on-disk HEAD differs it turns red
(`STALE served … vs HEAD …`) — restart opencode-web to serve new code. Data
exports: `/api/export` (sessions CSV), `/api/export/session`, `/api/export/ocr`,
`/api/export/patterns`, `/api/export/guard`. The **signals** tab also carries a
**session-health** panel (`/api/health`) that flags stalled/blank turns from the
database alone — the route-around when the interactive web view freezes.
Async panels never render blank: each carries a `loading...` skeleton that
is replaced on render (`data-error` on failure), and the signals pane
re-renders on every tab activation so live adjudication converges without
a reload. Proof screenshots (all captured with Playwright against a
scratch dashboard build, none retouched):

- docs/ux/signals-adjudicated.png — /explore ▸ signals showing
  `running 0 · blank 0 · dead 3 · dead-blank 6` (live-adjudicated;
  scratch :5225 serving this HEAD).
- docs/ux/loading-runbooks.png — /runbooks mid-fetch with the
  `loading...` skeleton visible (Playwright route-delayed /api/runbooks
  by 4 s; asserted `list == "loading..."` before capture).
- docs/ux/explore-sessions.png — /explore overview sessions table
  (42 sessions, same scratch build).

## Features and tools

One entry point, `bash scripts/ux.sh <verb>` (`help|status|chrome|probe|
findings|recall|cost|review|net`); the contract lives in
`agents/probe.yaml`. Built rea-style: every tool states behavior, emits
evidence, and names its limitations — findings always carry all three.

| Tool | Behavior → evidence |
|---|---|
| `ux.sh status` | Chrome + probe end-to-end → `probe: PASS` + `logs/cdp/probe-latest.json` |
| `probe-diagnose.sh` / `cdp-tab.mjs` | Hypertext Transfer Protocol Secure (HTTPS) + authentication + render evidence over CDP (zero-dependency, no Playwright install) |
| `ux-findings.sh` | `:5099` findings in plain language (means / care / action) |
| `recall-sessions.py` | Keyword recall over sessions with provenance |
| `cost.sh` | Spend headline: sessions, tokens, balance, estimates |
| `dns-guard.sh` / `dns-audit.sh` | Detect → ledger-record → staged remediation (daemon-safe first) |
| `verify-loads.sh` / `verify-caddy-audit.sh` | Served-config proof (fallbacks, MCP entry, bindings, denials sweep) |
| `gate-all.sh` | 15 asserts (lint/hygiene/patterns/self-tests/contract/freshness/certs/secrets/recall/pages) → PASS/FAIL/SKIP |
| `review-diff.sh` | Pre-push semantic review; SKIP (never FAIL) when uninstalled |
| `repo-mcp.mjs` | The four read-only tools as an MCP server (`repo-tools` in `opencode.json`) |
| `enable-lan-cert.sh` / `certs-init.sh` / `certs-trust.sh` | Local Area Network (LAN) Subject Alternative Name (SAN) rotation + Certificate Authority (CA) trust (system/Firefox/Chromium Network Security Services, NSS) |
| Skills | `jev-harness` (workflow), `repo-wizard` (human-only steps + grill), `typed-must-be-scripted`, `ux-verify` |
| Dashboard `:5099` | Panes: dashboard, explore, models, runbooks, manage, docs + cmdk palette |

## Usage guide (step by step, with screenshots)

Video walkthrough (39 s, 13 captioned steps with pan/zoom into each
feature, captured live against the served build with scripted
Playwright): `docs/ux/usage-tour.mp4`. Full-site walkthrough (42 s,
14 captioned steps across every page and all eight explore tabs,
pans down long pages, zooms into panes): `docs/ux/fullsite-tour.mp4`.
Keyboard users: Tab reaches
every control, arrows switch explore tabs, Enter sorts table columns,
`/` focuses search, Escape blurs — step 12 of the video shows the
focus ring in action.

Short interaction clips (real usage, ~8 s each — click a thumbnail
to play):

[![Drill down](docs/ux/thumb-drill.png)](docs/ux/clip-drill.mp4)
[![Brush to filter](docs/ux/thumb-brush.png)](docs/ux/clip-brush.mp4)
[![Ops drill](docs/ux/thumb-ops.png)](docs/ux/clip-ops.mp4)
[![Keyboard first](docs/ux/thumb-kbd.png)](docs/ux/clip-kbd.mp4)
[![CDP probe](docs/ux/thumb-cdp.png)](docs/ux/cdp-probe-tour.mp4)

Session-resume tour (33 s): when the upstream web UI cannot list old
sessions, resume via transcript — `docs/ux/resume-tour.mp4` demonstrates
the empty list, the data proof, the resume pointer, the agent
continuing, and two upstream API defects with repro lines.

CDP probe tour (36 s): the `:4096` → `:5099` chain made visible —
home sessions table (12 recent rows, live counts), the runbooks page
with the `cdp-probe` entry, then `/explore`. Captured with scripted
Playwright against this HEAD (rev banner on screen, no STALE flag):
`docs/ux/cdp-probe-tour.mp4`. Reproduce every frame from the terminal:

```bash
node scripts/cdp-tab.mjs --self-test                             # offline, 10 checks
node scripts/cdp-tab.mjs tabs                                     # live browser tabs
node scripts/cdp-tab.mjs openauth http://127.0.0.1:4096/session  # answer the login dialog
node scripts/cdp-tab.mjs probe                                    # PASS + logs/cdp/probe-latest.json
```

Why `openauth` exists: `:4096` is JavaScript Object Notation (JSON)-API-only
and answers browsers
with `401 + Basic realm` and an empty body, so an opened tab parks on
the login dialog with nothing to display. Answering the challenge
renders the session JSON in the tab (43 sessions); the human-readable
view of the same data stays `:5099`.

### Resume a session (read this — two stores exist)

The host TUI reads your **host-local** session store (2 sessions);
the `:4096` server holds **43 sessions** (counted 2026-10-03). A bare `opencode attach`
fails with `401 Unauthorized` because the server requires the
password and the command sends none — load it from `.env.local`
first (this prints nothing secret):

```bash
cd /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo
set -a; source .env.local; set +a
opencode attach http://localhost:4096 -s ses_f1d27512affeO4Z3ZoeWK9noI6
```

Variants: `--continue` resumes the last session, `--fork` copies
instead of continuing, `-p/-u` pass credentials explicitly (avoid:
they land in shell history). If the web UI shows "Nothing here yet"
or a deep link renders only the title, that is an upstream client
hydration gap, not data loss — verify with
`opencode session list` (local) vs `/api/session` (server), then
resume via transcript: start a new session and point it at
`logs/transcript-ses_f1d27512.md` (see `docs/ux/resume-tour.mp4`).

All shots captured with Playwright against a scratch dashboard build;
see `docs/ux/` for the files. The served revision banner (top right)
tells you whether you are looking at current code.

### 1. Dashboard — costs, sessions, live activity

Open `http://127.0.0.1:5099/`. The stat cards show total cost, session
count and token use; the sessions table (click a row) drills into one
session; live activity streams tool calls as they happen.

![](docs/ux/guide-dashboard.png)

### 2. Explore — overview, charts, signals

`/explore` has seven tabs. The overview table sorts/filters all
sessions by cost and tokens:

![](docs/ux/explore-sessions.png)

The charts tab carries cumulative spend (drag to brush-filter every
view below it), latency-x-cost scatter, token flow, sessions-over-time
and the word cloud:

![](docs/ux/guide-charts.png)

The signals tab adjudicates stalls against the live server — dead
findings are archival, not live stalls:

![](docs/ux/signals-adjudicated.png)

### 3. Runbooks — filter, read, copy

`/runbooks` lists the 19 operational runbooks with host/container
tags. Filter by tag, read the steps inline, copy commands with the
copy button. Async panels show a `loading...` skeleton while fetching,
never a blank shell:

![](docs/ux/guide-runbooks.png)
![](docs/ux/loading-runbooks.png)

### 4. Models — catalog and policy

`/models` shows the model catalog, the cost policy verdict
(ALLOW/ASK/BLOCK) and per-model tool-error ledgers:

![](docs/ux/guide-models.png)

## Session health (stalls / blank turns)
The interactive web view can freeze ("Shell" stuck, blank message pane) while
the agent is not actually stalled; the server's store is still complete.
`scripts/session-health.mjs` reads data/opencode/opencode.db read-only and
reports two low-false-positive signals straight from the row log:

- running_tool — a tool part still state.status="running" past --run-ms
  (default 120s): the sharpest agent-stall fingerprint.
- blank_tail — a recent session whose last part is a tool with no text part
  after it: the "no answer printed" fingerprint.

It deliberately does NOT report long inter-part gaps: measured here they were
~100% overnight user-idle, and a noisy alert is worse than none ("cry wolf").
Served at /api/health and /explore ▸ signals; --live additionally reads
GET /session/status; --self-test runs offline on synthetic fixtures and is
gated in test-hygiene.sh. No model call, no browser.

The UI follows DESIGN.md: one accent (#2ea043), an 8px grid, Material
elevation on cards (rest on --e1, rise to --e2 on hover), 8px radius on
surfaces and 999px pills. The tokens + overrides live in `THEME_CSS` in
scripts/dashboard.mjs and are injected on every page.

## Status, measurements, and decisions (2026-11-06)
    ./scripts/pulse.py                 # truth, scores, attention, next action
    ./scripts/issue-benchmark.py --run # prove security + stalls with numbers
    ./scripts/choice-gate.py           # pending decisions as multiple choice
    xdg-open http://127.0.0.1:5099/graph

`pulse` composes `next-action`, the benchmark, and the choice gate into one
screen (also the **Project pulse** card on `/` and `GET /api/pulse`). The
benchmark records named metrics for security posture, guard/injection counts,
running/blank tools, over-budget sessions, and the tunnel probe in
`observability.issue_bench`; SKIP is never PASS. `choice-gate` makes the
remaining human items explicit (`scripts/choices.json`), auto-runs only safe
local options, and records the selection + ledger row. `/graph` is an
editable 3D force graph of real repo data (tools, runbooks, files, APIs,
stores, metrics, decisions, issues); edits persist in `graph_edit`.
Full map: [`docs/STATUS-AUTOMATION.md`](docs/STATUS-AUTOMATION.md).

## Usability testing (cited, reproducible, always-on)
    ./scripts/usability-suite.py --self-test
    ./scripts/usability-suite.py --static-only
    ./scripts/usability-suite.py --browser --axe    # Playwright + axe-core
    ./scripts/usability-install.sh                 # 30-minute static timer
    xdg-open http://127.0.0.1:5099/usability       # guided human test + evidence

The suite operationalises ISO 9241-11 effectiveness/efficiency, a WCAG 2.2
A/AA automated subset, Core Web Vitals lab proxies, target size, keyboard
navigation, reflow, and reduced motion. Every result row carries its threshold
and citation; SKIP is never PASS. The static layer needs no browser, the
timer keeps it running, and `.github/workflows/usability.yml` runs the browser
layer nightly. The MUI app (`/app/`) now has a **Usability** view and a
Project pulse card; `/usability` is the classic guided runner. Both store a
human session separately from the automated screen. Method, validity threats,
and verified references:
[`docs/USABILITY-TESTING.md`](docs/USABILITY-TESTING.md).

## Closeout before "done"
    ./scripts/closeout-gate.py --check
    ./scripts/web-build-restart.sh          # build + restart from the repo root

RULES #93 makes completion a gate. It blocks on a stale build, stale server,
stale gate, a UI change without a new guided session, untracked scripts, or a
missing citation log. A deferral needs a reason and is recorded. The
`web-build-restart.sh` wrapper exists because `cd web && ./scripts/web-restart.sh`
fails: the second path is relative to `web/`.

## One command for the whole state
    ./scripts/harness.sh [--fast] [--export]

Runs every gate (lint, test-hygiene, test-patterns, test-dashboard), then the
live telemetry (guard actions + tool errors), the cost headline, the learned
rules, the model catalog, the doc budget and the TODO "in flight" list, and
prints a summary. `--fast` skips the slow dashboard gate; `--export` writes a
timestamped report to logs/; `--json` emits only
`{ts,rev,passed,failed,gates[]}` for a wrapper. Robust: a failing gate is
reported and the run continues.

The tooling's machine interfaces are contract-tested:

    ./scripts/test-tooling.sh     # every --json tool emits the keys callers read
    ./scripts/test-hygiene.sh     # runs test-tooling.sh too

test-tooling.sh proves preflight, doc-budget, learn-rules, issue-solutions,
audit-tool-calls, prompt-lint, models and logs emit parseable JSON with the
expected keys; it never calls harness.sh, so it cannot recurse.

The doc corpus that a session reads first (RULES/HANDOFF/README/TODO/DESIGN/
skills) is itself context cost:

    ./scripts/doc-budget.sh          # ~tokens + content hash; unchanged = cached

It records a hash in data/observability/docs.json, so an unchanged corpus means
nothing new to re-learn (the ECC external-skills-catalog context-budget /
content-hash-cache pattern).

Before spending on a session, run the fail-closed spend gate:

    ./scripts/preflight.sh          # exit 1 = do NOT spend until resolved

It checks keys, the last `harness.sh` gate result
(data/observability/last-gate.json), the DeepSeek balance (`MIN_BALANCE`,
default $1.00) and the model, and stops if any are wrong. Best practice for
"avoid API spend while a gate is red": gate on a cheap local signal, fail
closed, and capture `logs.sh` output before any retry so a retry is not blind.

"Laya before Jev" (self-hosted Laya first, hosted Jev on escalation) cuts
Jev/TypeSafe calls — small here (11 jev-review invocations total). It does not
cut DeepSeek: Laya is a Jev-compatible classifier, not a chat model. The big
lever is pinning `deepseek-flash` (v4-pro was 75% of spend).

## Verification status (2026-10-12, rev 338e142)

Sandbox-runnable gates, all green: `lint.sh` 177 pass, `test-hygiene.sh`
39 pass, `test-patterns.sh` 6 pass, `cdp-tab.mjs --self-test` 10/10,
`blacklist-guard-self-test` PASS, `ux-trace.py --self-test` 9/9,
`gate-all.sh` 15 pass / 0 fail / 1 skip (host-only probe/litellm).
Host-side `ux.sh status` (chrome + probe): `probe: PASS` — dash 79,
opencode 54, rendered 12 rows, browser 54/54, drift note by design.
Pages export (`pages-export.sh --shell`): 78 sessions, `site/index.html` +
`data.json` built; deploy stays manual (`workflow_dispatch`).

Second environment (2026-10-12): `.45` moved `belkin2` → Samsung Galaxy
hotspot. `dns-guard.sh` HEALTHY on the new uplink, `.24` stack re-probed
PASS unaffected (isolation proven), tailnet cross-plane 5–17ms 0% loss.
Same `docs/ux` shots below (refreshed 09:20 run).

## How-to guides

```bash
# PASS check (the whole state, one command)
bash scripts/ux.sh status
# Backup (atomic, Write-Ahead Logging (WAL)-safe) + verify
python3 -c "import sqlite3; s=sqlite3.connect('file:data/opencode/opencode.db?mode=ro',uri=True); print(s.execute('SELECT COUNT(*) FROM session').fetchone())"
# Cert rotate + trust (LAN SAN, then relaunch Chrome)
CERT_EXTRA_SANS="IP:192.168.4.24" ./docker/certs-init.sh && ./docker/certs-trust.sh
# DNS recovery (detect/record always; remediate only with --fix)
bash scripts/dns-guard.sh && bash scripts/dns-guard.sh --fix
# Uplink switch survival (.45 belkin2 → Galaxy proven 2026-10-12)
bash /tmp/dns-guard.sh && ping -c3 100.70.43.78
# Pre-push review (SKIP when reviewer absent) + redacted Pages build
bash scripts/ux.sh review && ./scripts/pages-export.sh --shell --yes --limit 500
```

### Hotspot roaming test (.45 → Samsung Galaxy, annotated)

On `.45`, switch the uplink, then prove the overlay outlives the LAN.
Copy `hotspot-test.sh` over first (`.45` has no repo checkout):
`scp owner@192.168.4.24:.../repo/scripts/hotspot-test.sh /tmp/` then
`bash /tmp/hotspot-test.sh`. What to press when:

| When | Press / run | Expect |
|---|---|---|
| Phone | Hotspot ON | `.45` joins new LAN |
| `.45` shell | `bash /tmp/hotspot-test.sh` | §1 DNS ok |
| Same run | (automatic) | §2 overlay `401` + `200`; §3 belkin URL times out (control) |
| Same run | (automatic) | §4 Pages `200`; §5 Chrome version or SKIP |
| `.45` Chrome | Open `https://10.100.0.24:4096/` → **accept** cert if asked → Basic login `opencode` → sessions render | Interactive UI on hotspot |
| Done | Paste the whole output back | Recorded as the next environment row |

Proven 2026-10-12: DNS HEALTHY, `.24` stack PASS unaffected, tailnet
5–17ms lossless, Pages reachable.

Hotspot anomaly under watch: from `.45`-on-Galaxy, Nebula `:5099`
answers `200` but `:4096/session` stalls past 10s with zero bytes while
the same endpoint is instant on-LAN. Small-response-OK vs
large-response-stall fits an MTU/PMTUD blackhole on the phone uplink
(Nebula runs mtu 1300; `/session` ships 54 sessions). Not yet proven —
re-run §2 on a quiet link and, if it persists, `tracepath 10.100.0.24`
from `.45` to find the clamping hop. The deduced-links panel this
motivates ships in the Pages build below.

![probe :4096](docs/ux/probe-4096.png)
![probe :5099](docs/ux/probe-5099.png)

## Choosing a model
    ./scripts/models.sh              # catalog + cost policy verdict
    ./scripts/models.sh --write      # persist data/observability/models.json

Model choice is a policy, not a hard-coded name. models.policy.json sets the
ceiling (max_input_per_m_usd), the allow and deny lists; free models always
pass. The catalog (from `opencode models --verbose`) currently has 7 free Zen
models plus deepseek-flash and v4-pro. The verdict is ALLOW / ASK / BLOCK:
ASK means over policy but cheaper/qualified alternatives exist, so alert the
user rather than silently stop. The interactive chooser is the /models page in
the observer UI (dashboard · explore · models · runbooks · manage · docs · csv); switch
from the TUI with /models or `opencode run -m <id>`.

## Adding a provider (Google Gemini)
Gemini is not a native provider in this opencode build (`opencode models
google` → "Provider not found"), so it is wired exactly like DeepSeek: an
OpenAI-compatible provider block in opencode.json.

1. Create a key at https://aistudio.google.com/apikey.
2. Add `GEMINI_API_KEY=<key>` to .env.local (mode 0600). Compose passes it to
   the web container via `env_file` and to the TUI via the environment list.
3. Restart: `docker compose -f docker/docker-compose.yml restart opencode-web`.
4. `./scripts/models.sh --write && ./scripts/preflight.sh`.
5. Select it: `/models` (TUI) or `opencode run -m gemini/gemini-2.5-flash`.

The block points at https://generativelanguage.googleapis.com/v1beta/openai/.
`gemini-2.5-flash` and `gemini-2.5-flash-lite` are allow-listed in
models.policy.json (Flash input ~$0.30/1M is above the $0.20 ceiling, so it is
explicitly allowed). The same steps are a "connect-gemini" runbook at /runbooks.

## Configuration reference (all tunable settings)

Default model: `opencode.json` field `"model": "deepseek/deepseek-flash"`.
Change it for one run (`opencode run -m <id>`), interactively (`/models`
in the TUI), or permanently (edit the field, restart the server).

`.env.local` keys (mode 0600, never printed; values with shell
metacharacters must be single-quoted or `source` aborts partway):

- `DEEPSEEK_API_KEY` — execution model billing.
- `JEV_API_KEY` — Jev review MCP + guard plugin auth.
- `GEMINI_API_KEY` — optional second provider (placeholder ok if unused).
- `OPENCODE_SERVER_PASSWORD` — Basic auth for :4096 and the dashboard.
- `LITELLM_MASTER_KEY` — LiteLLM proxy admin (generated on setup).

Ports (all loopback-only): `4096` opencode web/API, `5099`
observability dashboard (override with `DASH_PORT`), `4000` LiteLLM
proxy. Test scratch ports default to 5196+ (`TEST_DASH_PORT`).

Performance TTLs (env overrides, defaults in parentheses): cache
freshness windows, not correctness knobs — raise them to trade
staleness for less recompute: `HEALTH_TTL_MS` (15000),
`POLL_TTL_MS` (10000), `CACHE_TTL_MS` (15000), `SIGNALS_TTL_MS`
(30000); per-model ledger is fixed at 60 s. `QUERY_WORKER_PATH`
overrides the aggregation worker entry (fault-injection seam);
`LEDGER_DB` overrides the event-ledger path (test seam).

Budgets: `models.policy.json` gates model choice pre-flight
(deny-list wins); `docker/litellm.config.yaml` `max_budget: 5.0`
covers proxy-routed traffic only, and is unenforced without
`DATABASE_URL` — direct `api.deepseek.com` callers bypass it.

## Working process (project skill + command)
.opencode/skills/jev-harness/SKILL.md is auto-loaded by opencode and codifies
the loop for this repo: search-first (read HANDOFF/RULES/TODO + run preflight),
respect the enforced blacklist, keep the model on policy, gate every change
with harness.sh, learn from the corpus, and keep the docs current. Adapted from
the ECC agent-harness pattern (github.com/affaan-m/ECC); do not stack a full
ECC install on top of it. See HANDOFF.md "ECC skills (audit)".

The recurring "list outstanding issues + implement the doable queue" prompt is
a command, not a paste: run /status (`.opencode/command/status.md`). It lists
issues in both senses, classifies work A local-now / B needs-host / C larger /
D external, implements one doable segment, gates, and records a reason on each
deferral — so a request that is impossible or ballooning is named, not half-done.

Visual exploration lives at /explore (/viz 302-redirects there): a tabbed
database tool (overview · charts · signals · patterns · code · data · ocr) —
ranked search, a sortable sessions table, duplicate grouping, the DB map,
integrations, the A/B panel, patterns + known fixes, signals + guard +
session-health, and the charts. d3 v7.9.0 and d3-sankey v0.12.3 are vendored
under scripts/vendor/ and served at /vendor/*.js (offline, pinned). Full list:
HANDOFF "Navigating the observability UI".

The headless UI test (test-dashboard-ui.mjs) resolves element ids strictly (an
id absent from the served HTML is null, as in a browser) — which caught the
missing `#tabs` id that made the page dead.

Host-only UX tools (Playwright; run as `python3 scripts/…` from the repo root):
`ux-audit.py [url]` (height, panel counts, tab toggle, page errors, screenshot),
`ux-test.py [url]` (assertions; `--check` prerequisites; SKIP not PASS when
absent), `ux-trace.py [url]` (records every click/drag/scroll + hotspots into
`data/observability/ux.db` + `logs/ux/report.md`; `--ocr` reads each shot back
to text; `--self-test` offline). `node scripts/cdp-tab.mjs` (live-browser
CDP: tabs/open/text/eval/shot/openauth/probe; `--self-test` offline).
Runbooks: "ux-test", "ux-trace", "cdp-probe" (host).

## Search from the terminal
    ./scripts/semantic-search.sh <query...>     # ranked, across sessions
    ./scripts/semantic-search.sh --rebuild      # rebuild the on-disk index
    ./scripts/semantic-search.sh --fuzzy <q...> # typo-tolerant ("edti" -> "edit")

Builds a persistent FTS5 index at data/search/opencode-index.db (gitignored)
and prints bm25-ranked hits with snippets. Same index the dashboard serves
from memory; this on-disk copy is the substrate for a future Laya/Jev
semantic reranker. `--fuzzy` (or `fuzzy-search.py`) adds a local `difflib`
rerank over the index so a mistyped token still finds the right material.

## Cost bottlenecks
    ./scripts/cost-bottlenecks.sh [--top N]

Ranks the cost drivers in the database: effective $/1k-input, top sessions
by cost and by input tokens, worst effective $/1k-input, tiny-session
overhead, per-model cost share, a "model mix check" that flags any spend
outside the `deepseek-flash` default, and a prompt cache-hit report
(cache-read vs fresh input; 99.0% overall here). Read-only; host or container.
It also prints a "context budget (latest session)" line (`CONTEXT_BUDGET`,
default 200k input tokens); `opencode.json` sets `compaction` (auto + prune,
`tail_turns: 20`) to bound replayed context.

## Session database & tool-use methods
Everything the agent does — including every tool call — is one SQLite
database at data/opencode/opencode.db. The dashboard and scripts read it
read-only (node:sqlite / --experimental-sqlite); nothing is ever written
back. Tables that matter:

    session    one row per session (title, cost, tokens_*, model, times)
    message    one row per turn (data.role)
    part       one row per message part — the granular event log
    todo       the live plan (content, status, priority, position)

A tool call is a `part` row whose `data` is JSON:

    {"type":"tool","tool":"bash",
     "state":{"status":"running|completed|error",
              "input":{"command":"...","filePath":"..."}}}

so the ordered tool sequence for a session is

    SELECT json_extract(data,'$.tool') FROM part
    WHERE session_id=? AND json_extract(data,'$.type')='tool'
    ORDER BY time_created;

and a corpus-wide n-gram count is a single window query (lead() over
PARTITION BY session_id). ./scripts/test-patterns.sh proves this substrate
read-only (tool parts, distinct tools, bigrams, error chains) and gates the
deferred "patterns view" candidate.

## Next candidates (deferred, not started)
   1. finos/perspective pivot grid    new /explore tab (vendored like d3)
   2. Observable Plot / Vega-Lite     declarative charts (largest refactor)
   3. Patterns view (tool-sequence    /api/patterns + /explore tab, mined
      n-grams)                        from `part` tool sequences

Attack order: 3 → 1 → 2. See HANDOFF.md "Next candidates" for the scope,
and HANDOFF-PROMPT.txt for the verbatim prompt to paste into the next
session.

## Jev functional proof
    ./scripts/test-jev-functional.sh

Invokes the jev-review MCP tool for real and fails (non-zero) unless the
tool fires and returns at least one applicable metric with a score. Runs
from the host. doctor.sh --full (Tier 9) runs it automatically.

## Image tooling
The image includes python3 and sqlite3 (docker/Dockerfile apt install).
The database lives at data/opencode/opencode.db, mounted from
../data/opencode into the container. The base image is pinned by digest
and the opencode installer is pinned to 1.18.32 for reproducible builds.

## Two modes (operator vs. agent)
There are two distinct surfaces and the scripts do not cross over.

    Operator (host terminal)     docker, docker compose, the scripts
                                 under scripts/ that call docker.

    Agent (browser UI, 4096)     edits /workspace, runs opencode run,
                                 calls DeepSeek/Jev. No docker inside.

Do not paste host-script paths into the browser chat; the agent's shell
has no docker. To verify the agent's environment from inside the
container, run:

    ./scripts/verify-from-inside.sh [--full]

To confirm a session streams into the sidebar while it processes:

    ./scripts/test-sidebar-streaming.sh [--insecure]

## Troubleshooting
Scheme mismatch: plain `http://` on a TLS port answers `Client sent an HTTP
  request to an HTTPS server` — always use `https://` (there is no
  same-port redirect by design; the TLS listener owns 4096/5099).
  Drill-down silent on slow links: detail fetches are bounded at 60 parts
  (full transcripts via the txt/md/json download links); right-click has
  no "open link" because rows drill via JS, not anchors.
EACCES on /workspace: host UID mismatch. Script uses --user $(id -u).
HTTP 401 from DeepSeek: verbatim body printed by the script.
HTTP 422 from TypeSafe: request body format issue.
docker build permission denied: add user to docker group.
Smoke test FAIL despite OK response: known opencode exit-code bug.
  Script asserts on text, not exit code, to work around this.
Silent stall during smoke test: process substitution ensures live
  streaming. If this recurs, check that bash is version 4+ (process
  substitution is a bash feature).

## References (links verified 200 on 2026-09-30)

Specs/standards: W3C Accessible Rich Internet Applications (ARIA) Authoring
Practices Guide (APG) tabs
https://www.w3.org/WAI/ARIA/apg/patterns/tabs/ · Web Content Accessibility
Guidelines (WCAG) 2.1
https://www.w3.org/TR/WCAG21/ · RFC 5861 stale-while-revalidate
https://httpwg.org/specs/rfc5861.html · Go singleflight
https://pkg.go.dev/golang.org/x/sync/singleflight · CSP3 script-src
https://www.w3.org/TR/CSP3/ · SQLite WAL https://www.sqlite.org/wal.html ·
JSON1 https://www.sqlite.org/json1.html · window functions
https://www.sqlite.org/windowfunctions.html · FTS5+BM25
https://www.sqlite.org/fts5.html

API/library docs: Observable Plot https://github.com/observablehq/plot ·
d3-brush https://github.com/d3/d3-brush · d3-sankey
https://github.com/d3/d3-sankey · LiteLLM retries
https://docs.litellm.ai/docs/completion/reliable_completions · budgets
https://docs.litellm.ai/docs/proxy/virtual_keys · DeepSeek JSON mode
https://api-docs.deepseek.com/guides/json_mode · Meta structured output
https://ai.developer.meta.com/docs/features/structured-output · Playwright
evaluating https://playwright.dev/docs/evaluating · opencode CLI
https://dev.opencode.ai/docs/cli · opencode MCP
https://opencode.ai/docs/mcp-servers · GitHub Representational State Transfer
(REST) pagination
https://docs.github.com/en/rest/using-the-rest-api · Stripe pagination
https://stripe.com/docs/api/pagination

Books (ISBNs): Raymond, The Art of Unix Programming (AW, 2003, 978-0131429017)
— clarity/pasteability, §1.6.2. Kleppmann, Designing Data-Intensive
Applications (O'Reilly, 2017, 978-1449373320) — derived-data caching, ch. 11.
