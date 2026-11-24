# Handoff — foil.cfd autonomous continuation (2026-11-24)

Purpose: a fresh session finishes the **foil.cfd host closure** without
re-deriving the history. Read this file, then the two prior foil handoffs:
[`HANDOFF-2026-11-22-foil-cfd.md`](HANDOFF-2026-11-22-foil-cfd.md) and
[`HANDOFF-2026-11-23-foil-tailnet.md`](HANDOFF-2026-11-23-foil-tailnet.md).
Do not fork or continue the source session.

Status: JEF (this repository) and foil are pushed; `2d8ac9e` is the foil follow-up, and this file
is in the JEF docs commit. Verify with `git status -sb` in both trees.
foil.cfd is live as a static site; its backend is host-only and healthy; the
same-origin app is built and serving on the tailnet IP; the follow-up and the
cold-start fix are committed as `2d8ac9e`. The live tailnet e2e passed **2
passed, 0 skipped, 0 flaky** with `--retries=0`, and the `2d8ac9e` CI/deploy is
green (run `45390923942`). The Tailscale identity mismatch is **resolved**: the
console is signed in as GitHub `swipswaps`, the machines page lists
`a663c75b9e9b` (100.70.43.78) and `ws24` (100.119.125.16) as
`swipswaps@github`, and the DNS page shows tailnet `taile17668.ts.net` with
MagicDNS and HTTPS Certificates enabled. Serve is now **configured**:
`https://ws24.taile17668.ts.net:8443` proxies to `127.0.0.1:8002` and is
tailnet-only. Two host-only checks are misleading: the plain curl fails with
`Could not resolve host`, and `--resolve` to the host's own tailnet IP hangs
(hairpin to self). Neither is a Serve failure. Test from the client with
`--resolve` first; if that returns 200, TLS is working and only the host's local
MagicDNS is broken. The host fix needs the existing non-default flags:
`sudo tailscale up --accept-dns --operator=owner`, then restart `tailscaled`.
The app is HTTP at
`http://100.119.125.16:4174/`; https on 4174 is expected to fail. The Google
`ihydrocarbon@gmail.com` account remains a separate tailnet
(`tail427659.ts.net`) and should be invited to `swipswaps.github` if both logins
are wanted. Remaining after this DNS check: the Access Control List (ACL),
future-machine auth keys and tags, and the placeholder cursor. The exact
commands are in Step 2.

Important: the container **can** reach the foil tree. `/audit` is a bind mount of
`/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839`, so
`/audit/foil-cfd-site` is the host working tree. Inspect, edit, and run
`lint`/`typecheck`/`build` there. Only Playwright (Chromium libraries) and
`git push` are host-only.

## Hard boundary: where you can act

- The container has **no Docker socket**, **no Secure Shell (SSH) client**, and
  **no GitHub credential**, so it cannot run the host stack or push.
- `/workspace` is a bind mount of the JEF host repository
  `/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo`.
- `/audit` is a bind mount of
  `/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839`, so the foil
  checkout is available at `/audit/foil-cfd-site` for reads, edits,
  `lint`, `typecheck`, and `build`. Playwright and push still need the host.
- The host-ops skill (same files as the container copy at
  `/home/node/.config/opencode/skills/agent-host-ops`) is the execution layer:
  `$HOME/.config/opencode/skills/agent-host-ops`.

So the autonomous contract is: do every container-side check yourself, then
either (a) run the host block if the operator has given you host execution, or
(b) print exactly one host block and stop. Never invent a host result.

## Evidence snapshot (2026-11-24)

| Layer | State | Evidence |
|---|---|---|
| foil.cfd public site | static, live | GitHub Pages; `2d8ac9e` CI run `45390923942` success (build, e2e, deploy) |
| backend | healthy at the last host check (2026-11-23) | `solver_available=true`; `scripts/test_cfd_tools.sh` 16 pass / 0 fail; `/api/health` 200; `/api/jobs/default/surface.vtp` 200 |
| Private Network Access (PNA) | fixed | `OPTIONS /api/health` returns `Access-Control-Allow-Private-Network: true` |
| stale chunks | fixed | `vite:preloadError` plus `unhandledrejection` reload once, cache-busted |
| exposure | loopback plus Tailscale IPv4 | `127.0.0.1:8002` and `100.119.125.16:8002`; Funnel capability revoked |
| Tailscale Serve | configured on 8443, tailnet-only; client proof pending | `tailscale serve status` shows `https://ws24.taile17668.ts.net:8443` to `127.0.0.1:8002`; host plain curl is DNS-broken and host `--resolve` hairpins, so test from the client |
| tailnet-IP fallback | verified 2026-11-24 from two devices | `/api/health` 200 with `solver_available=true` on `http://100.119.125.16:8002` from `ws24` and from client `100.70.43.78`; app served on `http://100.119.125.16:4174/` |
| ACL | allow-all | `grants` still permits tailnet-to-tailnet on any port |
| CI e2e | green but not a hard gate | run `45390923942` success; the push still printed "Bypassed rule violations" |
| foil follow-up | committed and pushed `2d8ac9e` | `src/hooks/useBackendProbe.ts`, `src/hydro-main.tsx`, `src/sections/HydroLab.tsx`, `tests/e2e/tailnet.spec.ts`, `docker-compose.openfoam.yml` |
| live tailnet e2e | passed 2026-11-24 | 2 passed, 0 skipped, 0 flaky in 41.2s with `--retries=0` |
| same-origin dist | restored with `--base=/` | `dist/index.html` references `/assets`; `npm run build` reverts it to the Pages base |

The container-side JEF gates that were green at handoff: `lint` 453 pass / 0
fail; `test-hygiene` 119 pass / 0 fail / 3 skip; `test-patterns` 6 pass / 0
fail; `guard-health --check` PASS; doc budget within 35000 tier-1 tokens.
`check-placeholders` remains red on historical assistant text; do not advance
its cursor. The uppercase `PASS` and `FAIL` strings below are literal verdict
labels printed by the scripts, not acronyms.

## Tailscale identity discrepancy — evidence and plan

Two Tailscale identities exist, and the devices are in the one the browser is
not signed into:

- The client's `tailscale debug prefs` on 2026-10-12 records
  `UserProfile.LoginName = swipswaps@github`, `DisplayName = #swipswaps`, and
  the GitHub avatar `u/15093666`. That GitHub identity authorized the nodes.
- `tailscale status` on `ws24` and the client shows both owned by
  `swipswaps@`; the current tailnet is `swipswaps.github` with DNS
  `ws24.taile17668.ts.net`.
- The browser is signed in with Google `ihydrocarbon@gmail.com`. Its tailnet is
  `tail427659.ts.net` and its machines page lists only a `fedora` at
  100.95.53.23; it has no `ws24`.
- `swipswaps` is the user's GitHub account: it owns the repos and the DuckDNS
  login is `swipswaps@github`. The Google account is a second Tailscale account,
  not the one the devices use.

Resolved 2026-11-24: the console is signed in as GitHub `swipswaps`; the
machines page shows `a663c75b9e9b` (100.70.43.78) and `ws24` (100.119.125.16),
both `swipswaps@github`; the DNS page shows `taile17668.ts.net`, MagicDNS on,
and HTTPS Certificates on.

Preferred plan (no address or certificate churn):

1. **Done** — signed in at `https://login.tailscale.com/` with **Sign in with
   GitHub** as `swipswaps`.
2. **Done except the Serve re-run** — HTTPS Certificates are enabled in
   `swipswaps.github`; run `sudo tailscale up` and re-run Serve. The
   `100.119.125.16` / `100.70.43.78` addresses, the compose bind, and the JEF
   certificate SANs stay valid.
3. **Pending** — invite `ihydrocarbon@gmail.com` as a user (and admin if
   wanted) of the `swipswaps.github` tailnet, then accept the invitation. Both
   logins then reach the same tailnet.
4. **Pending** — for future approved machines, generate an auth key in that
   tailnet (Settings, Keys) and join with
   `sudo tailscale up --auth-key=... --advertise-tags=tag:server` (tag names
   are local choices; define `tagOwners` in the ACL). Tagged nodes are owned by
   the tailnet, not by one user's login. Alternatively sign in with GitHub
   `swipswaps`.
5. **Pending cleanup** — remove or document the extra `fedora` in the Google
   tailnet. Keep one machine in one tailnet; do not split a host across both.

Fallback (only if the GitHub account is unrecoverable): re-home `ws24` and the
client to `ihydrocarbon@gmail.com` / `tail427659.ts.net` with
`sudo tailscale logout` then `sudo tailscale up` (or an auth key). This assigns
new `100.x` addresses, so update `docker-compose.openfoam.yml`, every doc and
script that hardcodes `100.119.125.16` or `100.70.43.78`, and the JEF Caddy
certificate Subject Alternative Names (SANs) and trust. That is a migration,
not a quick fix; do it only when GitHub access is impossible.

## Decision rule

Finish the remaining open acceptance tests (Serve/TLS and the ACL) before
adding surface. The losing option is to start a new foil feature while Serve
and the ACL are open: a new failure would be ambiguous between the old and new
layers.

## Step 0 — prove the local state (container, read-only)

Run these before touching the host block. Paste the output, not a summary.

```bash
cd /workspace
git status -sb
git log --oneline -1
bash -n "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"
bash -n "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh"
bash "$HOME/.config/opencode/skills/agent-host-ops/path-hygiene.sh"
bash "$HOME/.config/opencode/skills/agent-host-ops/lint-all.sh"
```

If `push-all.sh` reports no token and no `gh`, that is expected in the
container. Do not treat it as a defect; the push runs on the host.

## Step 1 — push JEF (host, one command) — done

Result 2026-11-24: `1f4b2e5..da2731f` pushed for JEF and `04281df..2d8ac9e` for
foil. Re-run this command only to verify or to push new commits. Run it on
`ws24` (192.168.4.24), not on the client `100.70.43.78`: the client has no copy
of the skill and fails with `No such file or directory`.

```bash
bash "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"
```

Accept:

- `PASS: jef pushed`
- `git -C /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo status -sb`
  prints `## main...origin/main` with no ahead count.

If it refuses because foil is dirty with ahead/behind drift, push JEF alone:

```bash
git -C /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo push origin main
```

## Step 2 — close the foil tailnet exposure (host; fallback verified, TLS pending)

Refresh the daemon, then apply the existing script. It is dry-run by default;
`--apply --with-app` makes it effective, including the same-origin app proxy.

```bash
sudo tailscale up
bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --apply --with-app
```

Accept, all three:

1. `tailscale serve status` shows the tailnet-only HTTPS mapping; `tailscale
   funnel status` still shows no public config.
2. The backend answers over the resolved Tailscale DNS Name (TSN):
   ```bash
   TSN="$(tailscale status --json | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))')"
   curl -sS -o /dev/null -w 'http=%{http_code}\n' "https://$TSN/api/health"
   ```
   Expect `http=200`.
3. The same-origin app answers on the Tailscale IPv4 address (TSIP) and port
   4174:
   ```bash
   TSIP="$(tailscale ip -4 | awk 'NR==1{print $1}')"
   curl -sS -o /dev/null -w 'http=%{http_code}\n' "http://$TSIP:4174/"
   ```
   Expect `http=200`.

Rollback: `bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --unserve`
removes the Serve mapping; `sudo tailscale serve reset` is the manual fallback.
Re-bind the container to loopback only if needed. Funnel stays off in every case.

### Host run 2026-11-24T00:00Z

`sudo tailscale up` completed. `secure-tailnet-backend.sh --apply --with-app`
then:

- re-applied the loopback bind and restarted the backend container;
- `tailscale serve` reported `Serve is not enabled on your tailnet` and printed
  a node-specific `login.tailscale.com/f/serve` link. That link returned
  `Error 404 node not found`, so do **not** use it. The durable cause is that
  HTTPS Certificates are disabled for the tailnet; enable them in the admin
  console (see the corrected human step below). The script fell back to the
  tailnet-IP bind;
- health over the tailnet IP returned 200 with `solver_available=true` and
  `blockMesh_available=true`; the same request from the second tailnet device
  `100.70.43.78` also returned 200, so the path is proven across devices;
- built the frontend (vite 8.3.8, 21.79s; the known large-chunk warnings are
  present) and started the same-origin proxy on `http://100.119.125.16:4174/`.

Update 2026-11-24T08:47Z: the device reports
`CurrentTailnet.Name = swipswaps.github` and DNS `ws24.taile17668.ts.net`. The
console page that enabled HTTPS showed `tail427659.ts.net` and
`ihydrocarbon@gmail.com`, and its machines page lists only `fedora`
(100.95.53.23). That is a **different tailnet**, which is why the setting did
not apply and the CLI node link returned 404. The browser is signed into the
wrong account. Do not move the device to the other tailnet: it would change the
address and the ACL scope.

Confirm on the host:

```bash
tailscale status --json | python3 -c 'import sys,json; d=json.load(sys.stdin); s=d.get("Self") or {}; t=d.get("CurrentTailnet") or {}; print("dns", s.get("DNSName")); print("tailnet", t.get("Name"))'
```

Human step for TLS — identity and HTTPS setting are done:

1. **Done** — signed in with **GitHub** as `swipswaps`; the machines page shows
   `a663c75b9e9b` and `ws24` as `swipswaps@github`.
2. **Done** — the DNS page shows tailnet `taile17668.ts.net`, MagicDNS on, and
   HTTPS Certificates on (the button reads "Disable HTTPS").
3. Run on the host:

```bash
sudo tailscale up
bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --apply --with-app
```

Two Serve outcomes matter after HTTPS is enabled:

- `Access denied: serve config denied` means Serve **is** enabled, but `owner`
  is not the tailscaled operator; the script's `tailscale serve` ran without
  root. Fix once with `sudo tailscale set --operator=owner` (or the current
  user), then re-run, or run `sudo tailscale serve` directly. This is a
  permission error, not a tailnet setting. The script's "Serve/HTTPS is off"
  line is a generic fallback and is misleading here.
- `address already in use` on 443 means the JEF Caddy listener owns 443 on
  `100.119.125.16`. Do not stop Caddy; use 8443.

Recommended path (avoids the 443 conflict and the script's service step; the
app was already built and started by the last `--with-app` run):

```bash
sudo tailscale set --operator=owner
tailscale serve --bg --https=8443 http://127.0.0.1:8002
TSN="$(tailscale status --json | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))')"
printf '%s\n' "$TSN"
tailscale serve status
tailscale funnel status
curl -sS -o /dev/null -w 'http=%{http_code}\n' "https://$TSN:8443/api/health"
```

Accept: `tailscale serve status` shows the 8443 mapping, `tailscale funnel
status` shows no public config, and the health request returns 200. The
same-origin app is HTTP: open `http://100.119.125.16:4174/`. Opening `https` on
4174 gives `ERR_SSL_PROTOCOL_ERROR` by design; TLS is on the API via the TSN.

Host self-checks are misleading: the plain curl is DNS-broken, and `--resolve`
to the host's own tailnet IP can hang (hairpin to self). Do not use the host
curl as the acceptance. Test from the client `100.70.43.78`, with `--resolve` to
bypass DNS:

```bash
curl -sS -m 15 --resolve ws24.taile17668.ts.net:8443:100.119.125.16 \
  -o /dev/null -w 'http=%{http_code}\n' \
  https://ws24.taile17668.ts.net:8443/api/health
```

Expect 200; that proves Serve and the certificate. Then test plain resolution on
the client: `getent hosts ws24.taile17668.ts.net` and the same curl without
`--resolve`. If DNS fails, fix MagicDNS on that device. Host fix uses the exact
flags Tailscale demands (the earlier `tailscale up --accept-dns=true` failed
because `--operator` is non-default):

```bash
cat /etc/resolv.conf
systemctl is-active systemd-resolved tailscaled
sudo systemctl enable --now systemd-resolved
sudo tailscale up --accept-dns --operator=owner
sudo systemctl restart tailscaled
getent hosts ws24.taile17668.ts.net
```

Do not use `--accept-dns=false` if tailnet names must resolve. Restarting
`tailscaled` briefly drops the tailnet.

The `https://rolldown.rs/reference/InputOptions.checks#bundlertimings` URL in
the build output is the bundler's chunk-size hint, not an action item.

## Step 3 — live tailnet e2e (host)

Run in the foil checkout after step 2. The spec fails closed: with
`TAILNET_APP_URL` unset it reports two skips, which is not a pass.

The same-origin app must be built with `--base=/`. The repo's `vite.config.ts`
sets `base: '/foil-cfd-site/'` for GitHub Pages, and `npm run build` writes that
base; served from `/` it makes every asset path 404 (the proxy returns
`index.html` with 200, so the app never boots and there is no badge). The secure
script already builds with `--base=/`; a later Pages build overwrites it.

```bash
cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
npx vite build --base=/
TSIP="$(tailscale ip -4 | awk 'NR==1{print $1}')"
TAILNET_APP_URL="http://$TSIP:4174/" npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome --retries=0
```

Accept: **2 passed, 0 skipped**, "Backend online" with no Connect click, and
`/api/health` answered on the page origin. A skip or a retry is a failure for
this step. `--retries=0` is deliberate: the default config retries once and can
report a flake as "1 flaky / 1 passed", which hides a first-paint race.

### Cold-start flake found and fixed (2026-11-24)

The first live run (config `retries: 1`) reported **1 flaky, 1 passed**: the
auto-connect test failed on the first attempt after 58.1s with
`Static mode — backend unreachable`, then passed on the retry in 12.1s. The
trace proves the network was healthy:

- the `/api/health` request returned **200 in 101ms** at 05:41:30.745Z;
- the badge was still "Checking local backend" at 05:41:30.684Z and showed
  "Static mode" at 05:41:36.898Z.

Root cause: the private-page same-origin probe used the 2.5s local deadline. The
first paint blocks the main thread for ~6s while the 3D scene compiles, so the
abort timer fired before the already-arrived fetch microtask ran. The build also
baked `VITE_BACKEND_URL` and returned only that URL, so the same-origin
candidate list was dead code.

Fix in `src/hooks/useBackendProbe.ts`:

- a private/tailnet page tries its own origin **first**, then the build-time
  URL, then loopback; a public page still uses the build-time URL only;
- the same-origin candidate gets a 10s deadline, while loopback candidates keep
  the 2.5s deadline.

A second run with `--retries=0` failed differently: the badge was absent for the
whole 20s. The trace showed the index loading assets from `/foil-cfd-site/assets`
while the proxy serves `/assets`; every JavaScript request got `index.html` with 200 and
the app never booted. Cause: `npm run build` used the Pages base
`/foil-cfd-site/`. Fix: build the same-origin app with `npx vite build --base=/`
before the e2e. This is a different failure from the first-paint race; both
fixes are required.

Rebuild with `--base=/` and rerun Step 3 with `--retries=0`. If it still shows a
retry or no badge, treat the fix as insufficient and diagnose the new trace
before committing.

**Result 2026-11-24 05:22Z: 2 passed, 0 skipped, 0 flaky** (17.3s and 11.4s;
41.2s total) with `--retries=0`. The first-paint race and the build-base trap
are both closed.

## Step 4 — gate and push the foil follow-up (host) — done

Commit `2d8ac9e` is pushed to `origin/main`; `lint` (0 warnings / 0 errors),
`typecheck`, and `build` all passed before the commit. The push printed
"Bypassed rule violations" because the required `e2e` check was still pending;
verify the run separately. The host's `npm run build` restored the Pages base,
so the same-origin dist was rebuilt with `--base=/` afterwards to keep the
tailnet app working.

The follow-up commit contains:

- `src/hooks/useBackendProbe.ts` (private and tailnet pages probe the page origin
  first; the loopback permission gate applies to public pages only; the
  same-origin candidate has a 10s deadline to survive the first-paint block)
- `src/hydro-main.tsx` (small entry that renders the existing `HydroApp`)
- `src/sections/HydroLab.tsx` (deterministic particle helper reused)
- `tests/e2e/tailnet.spec.ts` (opt-in, gated by `TAILNET_APP_URL`)
- `docker-compose.openfoam.yml` (bind `127.0.0.1:8002` and the Tailscale IPv4
  address; the host script applied this, so include it in the same commit)

For reference, the exact sequence was:

```bash
cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
npm run lint
npm run typecheck
npm run build
git add src/hooks/useBackendProbe.ts src/hydro-main.tsx src/sections/HydroLab.tsx tests/e2e/tailnet.spec.ts docker-compose.openfoam.yml
git commit -m "frontend: same-origin tailnet auto-connect; cold-start probe deadline"
bash "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"
```

Accept: all three gates exit 0 (`oxlint` reports 0 warnings / 0 errors), the
commit is on `main`, and `PASS: foil pushed`. `npm run build` is the GitHub Pages
base (`/foil-cfd-site/`) and is correct for CI and deploy, but it overwrites the
same-origin dist. Run the Step 3 tailnet e2e before this build, then rebuild
with `--base=/` (or re-run the secure script) to keep the tailnet app working.
The same-origin dist has been restored this way.

Verified: CI run `45390923942` for `2d8ac9e` has `build`, `e2e`, and `deploy`
green. In CI the tailnet spec reports two skips because `TAILNET_APP_URL` is
unset; that is expected there, not a pass for the live check. Re-run only to
check a new commit:

```bash
gh run list -R swipswaps/foil-cfd-site --limit 1 --json databaseId,headSha,status,conclusion
gh run watch -R swipswaps/foil-cfd-site "$(gh run list -R swipswaps/foil-cfd-site --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Rollback: resolve the commit SHA and revert it, then push again:

```bash
foil=/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
SHA="$(git -C "$foil" rev-parse HEAD)"
git -C "$foil" revert "$SHA"
bash "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"
```

## Step 5 — human-only residuals

1. **Serve/TLS.** Identity and HTTPS Certificates are done (GitHub
   `swipswaps`, tailnet `taile17668.ts.net`). Run
   `sudo tailscale set --operator=owner`, then
   `tailscale serve --bg --https=8443 http://127.0.0.1:8002` (JEF Caddy owns
   443). Accept: `tailscale serve status` shows the 8443 mapping and the health
   request over the resolved Tailscale DNS Name returns 200:
   `TSN="$(tailscale status --json | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))')"`
   `curl -sS -o /dev/null -w 'http=%{http_code}\n' "https://$TSN:8443/api/health"`
   The app is HTTP at `http://100.119.125.16:4174/`; https on 4174 is expected
   to fail.
2. **ACL narrowing.** In the Tailscale admin console, replace the allow-all
   `grants` entry with tag and port scope for `ws24` and the client. This is
   admin-console work, not reachable from either repo. Do not lock yourself out:
   keep one verified device session open while applying.
3. **e2e as a hard gate.** Either remove the admin bypass on `main` or require
   changes to land through a pull request. This is a repository policy decision,
   not a code defect.
4. **Placeholder cursor.** Review the four historical part IDs from the JEF scan
   and either accept them or baseline them explicitly. Never run `--advance` to
   make a red gate green.

## Do not

- Do not run `push-all.sh` or Playwright from the container. `/audit/foil-cfd-site`
  is available for reads, edits, `lint`, `typecheck`, and `build`, but push and a
  real browser need the host.
- Do not commit or push foil with a failing `npm run build`, and do not report a
  skipped tailnet spec as a pass.
- Do not expose the backend publicly: Funnel stays revoked; Serve is
  tailnet-only.
- Do not emit ellipses or angle-bracket tokens in any command you offer. Resolve
  the Tailscale DNS Name or Tailscale IPv4 address inline.
- Do not advance the placeholder cursor or weaken a gate to get a green line.
