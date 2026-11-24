# Handoff — foil.cfd: solver, exposure, and tailnet (2026-11-23)

Status: solver works on the host; the public site is static; the backend is
tailnet-reachable over the encrypted tailnet, not public. Tailscale Funnel
capability has been revoked. The same-origin auto-connect and the tailnet
end-to-end (e2e) test are implemented; Serve/Transport Layer Security (TLS) and the Access Control List
(ACL) narrowing still need the host or the tailnet admin console.

## How we got here

1. Public static demo (Computational Fluid Dynamics (CFD) lab, charts) on GitHub
   Pages.
2. Local Network Access (LNA) so a public page could reach a loopback backend
   (explicit Connect, `targetAddressSpace`).
3. Solver enablement on the host OpenFOAM image (OpenFOAM is the solver suite):
   - missing `job_retention.py` import and an unsupported pip flag;
   - the base image's `/openfoam/run` entrypoint died before the server started
     -> `ENTRYPOINT []` plus a `bash -c` that sources `/openfoam/profile.rc`;
   - `system/blockMeshDict` was old syntax -> `scale` and no stray `;` in
     `blocks`;
   - `system/fvSchemes` lacked the kEpsilon stress term
     `div((nuEff*dev2(T(grad(U)))))`.
   Result: `/api/health` reports `solver_available=true` and `/api/solve` runs a
   real `simpleFoam` solve (a bundled 2-dimensional channel case, not an airfoil).
4. Stale hashed-chunk self-heal in `index.html` (reload once, cache-busted).
5. Backend Cross-Origin Resource Sharing (CORS): added
   `Access-Control-Allow-Private-Network: true` (Private Network Access (PNA)).
6. User Interface (UI) fix: backend badge moved out of fixed positioning so it no longer overlaps
   the lab header; regressions added.
7. Playwright coverage: static, offline, advanced-online, and per-component
   suites (on- and offline).
8. Exposure hardening: container bound to loopback plus the Tailscale IPv4
   (TSIP); Funnel capability removed; tailnet Serve pending a daemon refresh.

## Where we are now

- Backend (host, container `foil-cfd-site-backend`): bound to `127.0.0.1:8002`
  and `100.119.125.16:8002` (the tailnet address of `ws24`). No Local Area
  Network (LAN) or public bind. Encrypted by WireGuard in transit.
- Tailnet access:
  - Application Programming Interface (API): `http://100.119.125.16:8002/api/health`
    (HTTP; encrypted by WireGuard). Use this from any tailnet device.
  - Same-origin app: `serve-same-origin.py` serves the built app and proxies
    `/api` to `127.0.0.1:8002` on `http://100.119.125.16:4174/` — page and API
    share scheme, host and port, so no CORS, no LNA prompt, no mixed content.
- Tailscale Serve (tailnet-only Hypertext Transfer Protocol Secure (HTTPS) with
  Transport Layer Security (TLS)): not
  configured yet. The Tailscale daemon has not seen the console-side enablement;
  run `sudo tailscale up` (refresh) then `tailscale serve`.
- Tailscale Funnel (public exposure): capability removed from the policy
  (`nodeAttrs` funnel entry deleted); `tailscale funnel status` shows
  `No serve config`. No public exposure.
- The `grants` policy still allows all tailnet-to-tailnet connections
  (`src/dst/ip: ["*"]`); optional least-privilege hardening is open.

## Follow-up changes (2026-11-23, uncommitted)

- Same-origin auto-connect: `src/hooks/useBackendProbe.ts` now classifies the
  page host. Loopback and private/tailnet pages (the `100.64.0.0/10` shared
  address space, private ranges, `*.ts.net`, `*.local`, unique-local and
  link-local addresses) probe immediately and try `window.location.origin`
  first, so a tailnet page reaches its own `/api` proxy instead of the client's
  `127.0.0.1`. The loopback-network permission gate and the "Connect local
  backend" action label now apply only to public pages. A public page such as
  GitHub Pages keeps the explicit Connect flow.
- Tailnet e2e test: `tests/e2e/tailnet.spec.ts` is opt-in through the
  `TAILNET_APP_URL` environment variable. Unset, it reports two skipped tests;
  set, it fails closed unless the page reaches "Backend online" with no Connect
  click and `/api/health` answers on the page origin. An invalid or non-http(s)
  value fails immediately.
- Lint: `src/hydro-main.tsx` is now a small entry that renders the existing
  `HydroApp` from `src/sections/HydroLab.tsx`. The duplicate tree and the
  render-time `Math.random` are gone; `oxlint` is clean.
- Gates run in the container: `npm run lint`, `npm run typecheck`, and
  `npm run build` pass; the tailnet spec reports two skips when the variable is
  unset. The live browser run is host-only: this container lacks Chromium's
  shared libraries (`libnspr4.so`, `libnss3.so`, and others), so Playwright
  cannot launch here.

## Exact usage

Host (only the host runs the backend):
```bash
docker compose -f docker-compose.openfoam.yml up -d --build backend
curl -sS http://127.0.0.1:8002/api/health
```

Any other tailnet device (do NOT run docker compose there):
```bash
TSIP="$(tailscale ip -4 | head -1)"
curl -sS "http://$TSIP:8002/api/health"
printf 'app: http://%s:4174/\n' "$TSIP"   # open this in a browser on the tailnet
```

Expose securely to the tailnet (host):
```bash
bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --apply --with-app
```

TLS via Serve once the daemon is refreshed:
```bash
sudo tailscale up
bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --apply --with-app
```

Verify Funnel is off and the daemon state:
```bash
bash "$HOME/.config/opencode/skills/agent-host-ops/disable-tailscale-funnel.sh"
sudo tailscale serve status
```

## Tests and gates

- Playwright suites: `foil-static.spec.ts` (renders offline),
  `foil-offline.spec.ts` (forced offline + Connect safety),
  `foil-components.spec.ts` (every surface + a real online solve + layout and
  Retry regressions), `foil-advanced.spec.ts` (online), `foil-ux.spec.ts`.
- `tests/e2e/tailnet.spec.ts` (opt-in): same-origin auto-connect and
  `/api/health` on the page origin; gated by `TAILNET_APP_URL`.
- Continuous Integration (CI) runs both an online step (backend up) and an
  offline step (no backend), plus a PNA-header assertion.
- Local gates used: `bash -n`, `path-hygiene.sh`, `py_compile`,
  `check-placeholders.py` (self-test + file), `acronym-lint.py`.

Run the tailnet suite from the host once the same-origin app is listening:

```bash
TSIP="$(tailscale ip -4 | head -1)"
TAILNET_APP_URL="http://$TSIP:4174/" npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome
```

Change the port if `serve-same-origin.py` was started with another `--listen`
port. With `TAILNET_APP_URL` unset the same command reports two skips instead of
a pass, so CI cannot silently drop the check.

## Commits

- `4b9500e` enable simpleFoam (entrypoint bypass + v2312 blockMeshDict)
- `a83ad37` stale-chunk self-heal
- `3a161d5` offline spec
- `24dae25` component coverage (online solve)
- `47cada8` detailed README
- `b8beedb` dependency upgrade
- `a9b0d32` badge overlap fix + overlap/Retry regressions
- `04281df` PNA CORS header (`Access-Control-Allow-Private-Network`)

Follow-up work in this pass is uncommitted in the foil checkout:
`src/hooks/useBackendProbe.ts`, `src/hydro-main.tsx`,
`src/sections/HydroLab.tsx`, and the new `tests/e2e/tailnet.spec.ts`.

## Open items

1. Serve/TLS: run `sudo tailscale up`, then re-run the secure script for HTTPS.
   Host-only; the container has no Tailscale daemon or `docker` socket.
2. **Done** — same-origin auto-connect: private/tailnet pages skip the
   loopback-permission gate and try the page origin first, so no Connect click
   is needed when the backend shares the page origin.
3. **Done** — `tests/e2e/tailnet.spec.ts` gated by `TAILNET_APP_URL`, with the
   live run still to be executed on the host.
4. Least-privilege Access Control List (ACL): narrow the allow-all grant by tag
   and port; tag the host and allow only required users. Admin-console work, not
   reachable from this container.
5. **Done** — `src/hydro-main.tsx` now reuses `HydroApp`; the particle generator
   uses the deterministic `pseudo` helper already in `src/sections/HydroLab.tsx`.
   `oxlint` reports no warnings.

## Glossary

- CFD: Computational Fluid Dynamics.
- RANS: Reynolds-Averaged Navier-Stokes.
- API: Application Programming Interface.
- LNA: Local Network Access.
- PNA: Private Network Access.
- CORS: Cross-Origin Resource Sharing.
- TLS: Transport Layer Security.
- ACL: Access Control List.
- LAN: Local Area Network.
- CI: Continuous Integration.
- TSIP: Tailscale IPv4 address.
- TSN: Tailscale Domain Name System (DNS) Name.
- HTTPS/HTTP: Hypertext Transfer Protocol Secure / Hypertext Transfer Protocol.
- e2e: end-to-end.
