# Handoff — foil.cfd User Experience (UX) pass (2026-11-24)

Purpose: a fresh session improves the foil.cfd user experience without breaking
the solver, Tailscale Transport Layer Security (TLS), static Pages mode, or the
existing end-to-end (e2e) coverage. Execute in this order; prove each item before
the next.

## Verified current state

- foil.cfd `main` is `2d8ac9e`; CI run `45390923942` is green (build, e2e,
  deploy).
- The live tailnet e2e passed **2 passed, 0 skipped, 0 flaky** with
  `--retries=0` in 41.2 seconds.
- Tailscale TLS is verified:
  `https://ws24.taile17668.ts.net:8443/api/health` returns **200**. The current
  Serve mapping is `https://ws24.taile17668.ts.net:8443/` to
  `http://127.0.0.1:8002` (the API only). Tailnet `swipswaps.github`; the
  browser is signed in as GitHub `swipswaps`; HTTPS Certificates are on.
- The same-origin app currently runs at `http://100.119.125.16:4174/` (plain
  Hypertext Transfer Protocol (HTTP) over WireGuard). The public site is static
  at `https://swipswaps.github.io/foil-cfd-site/`.
- The container can read, edit, lint, typecheck, and build the foil tree at
  `/audit/foil-cfd-site` (a bind mount of the host checkout). Playwright,
  Serve, and `git push` run on the host `ws24`.
- Open non-UX items: the Tailscale Access Control List (ACL) is still allow-all;
  future machines should join with an auth key and a `tag:server` tag; this repository's placeholder cursor still needs a human disposition.

## UX audit — evidence first

The audit is source-based (the container cannot run Chromium). Each item names
the current code and the user-visible effect.

| # | Issue | Evidence | User effect |
|---|---|---|---|
| 1 | Two URLs, and the HTTPS root is not the app | Serve `8443` maps `/` to `127.0.0.1:8002`; the FastAPI root returns `{"detail":"Not Found"}`. The app is on `http://100.119.125.16:4174/`; `https` on 4174 returns `ERR_SSL_PROTOCOL_ERROR` | A tailnet user who opens the secure URL gets a 404 or a certificate error, not the app |
| 2 | Primary status copy is developer-facing | `src/components/BackendBadge.tsx:16` shows `Static mode — {reason}`; `src/hooks/useBackendProbe.ts:23-24,119-120` set reasons containing `docker compose up -d`; `src/components/Sidebar.tsx:143-152,189` repeat it | A visitor is told to run Docker in the status badge instead of being told what works now |
| 3 | Solve labels are jargon and ambiguous | `src/components/Sidebar.tsx:123-129`: `Run simpleFoam` or `Generate synthetic preview`; `src/sections/CfdLab.tsx:57`: `OpenFOAM ready` | A user cannot predict what the button does, how long it takes, or whether it is real Computational Fluid Dynamics (CFD) |
| 4 | The bundled case is a 2D channel, but the UI says National Advisory Committee for Aeronautics (NACA) airfoil | the foil documentation (lines 55-57) discloses the 2D channel placeholder; `src/App.tsx:201`, `src/sections/CfdLab.tsx:81`, and the NACA controls imply an airfoil solve | Trust gap: the result is real solver output but not the geometry a user may think they ran |
| 5 | The solve flow has no elapsed time, step, cancel, or retry | `src/App.tsx:147-188` polls `/api/jobs/{id}`; `src/components/Sidebar.tsx:132-136` shows a truncated job ID and a raw status; a poll error only sets `cfdError` | A 30-second solve looks stuck; a failure has no recovery path or reason |
| 6 | The closed sidebar stays in the tab order | `src/components/Sidebar.tsx:56` sets `aria-hidden={!open}` but does not make the subtree inert or remove `tabIndex` | Keyboard and screen-reader users can focus invisible links and controls |
| 7 | The 3D probe has no keyboard path, and the chart has no text equivalent | `tests/e2e/foil-ux.spec.ts:202-273` probes by mouse; `src/sections/CfdLab.tsx:96-102` renders the Cp chart with Plotly | A keyboard-only user cannot inspect the surface or read the chart's conclusion |
| 8 | First load is heavy and gives little progress feedback | `npm run build` emits `CfdVtkViewer` at 1.6 megabytes, `CpPolarChart` at 1.1 megabytes, and `r3f-vendor` at 946 kilobytes; `foil-ux.spec.ts:99-115` allows up to 25 seconds | Mobile and slow networks see a long blank or skeleton period; the largest chunks are not split by route |
| 9 | No first-run guidance for the lab | The only hint is `src/components/Sidebar.tsx:171-173` (`No probe yet · click the 3D surface`); orbit and field controls are unlabelled for a first-time user | Users miss orbit, probe, field, and export, the features that make the lab useful |
| 10 | State is not shareable or persistent | `src/App.tsx:57-74` holds device, tab, model, field, and job state in memory; `#cfd` is the only URL state | Reloading loses the model, field, and job; a user cannot send a reproducible link |
| 11 | Marketing and paid copy overclaim | `src/sections/HydroLab.tsx:217,295,299` promises full 3D Reynolds-Averaged Navier–Stokes (RANS) sweeps and a `Hydro Pro Workstation` at `$49 / mo per seat` with no checkout or entitlement | Users cannot tell what is demo, what is local, and what is purchasable |
| 12 | Status vocabulary is inconsistent | `Backend online`, `OpenFOAM ready`, the hydro page node label with the backend origin, `Static mode`, and `Backend offline` appear in different components | The same backend state looks different in the badge, the lab, and the hydro page |
| 13 | Mobile coverage stops at overflow | `foil-ux.spec.ts:300-320` checks no horizontal overflow and canvas/chart stacking; it does not check 44-pixel tap targets, sidebar body-scroll lock, or focus return | The phone layout fits, but controls and the drawer can still be hard to use |
| 14 | Two build bases are easy to mix | `vite.config.ts:9` uses `/foil-cfd-site/` for GitHub Pages; the same-origin app needs `npx vite build --base=/`; a plain `npm run build` breaks the tailnet app | A routine Pages build silently breaks the secure app with 404 asset paths |

## Prioritized plan

Decision rule: fix trust and the primary path first. A user must be able to open
one secure URL and understand what is live before we polish secondary surfaces.
The losing option is to start new visual features while the secure root still
returns a 404 and the primary badge still says `docker compose`.

### Priority 0 (P0) — one secure origin and honest status (do first)

1. **Serve the app and API on the same HTTPS origin.** Keep `8443` and the JEF (this repository) Caddy
   on `443` untouched. The app proxy must be on `127.0.0.1:4174`; Serve cannot
   proxy to the tailnet IP.

   On `ws24`:
   ```bash
   tailscale serve --https=8443 off
   nohup python3 "$HOME/.config/opencode/skills/agent-host-ops/serve-same-origin.py" \
     --dist /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site/dist \
     --listen 127.0.0.1:4174 --api http://127.0.0.1:8002 \
     > /tmp/foil-app.log 2>&1 &
   tailscale serve --bg --https=8443 --set-path=/ http://127.0.0.1:4174
   tailscale serve status
   ```

   The `/` mount preserves the request path, and the app proxy forwards `/api`
   to `127.0.0.1:8002`. Do not mount `/api` directly: Serve strips the mount
   path, so `/api/health` would arrive at the backend as `/health`.

   Acceptance:
   - `curl -sS -o /dev/null -w '%{http_code}\n' https://ws24.taile17668.ts.net:8443/`
     returns `200`.
   - `curl -sS -o /dev/null -w '%{http_code}\n' https://ws24.taile17668.ts.net:8443/api/health`
     returns `200`.
   - The page at `https://ws24.taile17668.ts.net:8443/` shows "Backend online"
     with no Connect click.
   - Re-run the tailnet e2e against the HTTPS origin:
     ```bash
     cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
     TAILNET_APP_URL="https://ws24.taile17668.ts.net:8443/" \
       npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome --retries=0
     ```
     Accept 2 passed, 0 skipped, 0 flaky.

   If `tailscale serve --https=8443 off` refuses, run `tailscale serve reset`
   (the only mapping is this handoff's) and add the `/` mount again. Keep the
   app proxy running with `--bg` semantics (`nohup` or a systemd unit).

2. **Rewrite the primary statuses for users, not operators.**
   - `src/components/BackendBadge.tsx`: `Live solver ready` (online, solver
     available), `Live solver connected · preview mode` (online, no solver),
     `Static demo · sample wing` (offline), and `Checking local solver` while
     probing.
   - Move the `docker compose` command into a secondary `Self-host the solver`
     disclosure or the project documentation, never the primary badge.
   - `src/sections/CfdLab.tsx`: replace `OpenFOAM ready` with `Solver ready`.
   - `src/sections/HydroLab.tsx`: replace `Local OpenFOAM/Visualization Toolkit (VTK) Node Online (127.0.0.1:8002)` with `Live solver connected`.
   - Keep a small technical details row (backend origin, solver version) behind
     a disclosure for operators.

   Acceptance: a Playwright assertion that the primary badge and the solver
   controls contain none of `docker compose`, `127.0.0.1`, or `OpenFOAM`; the
   static page still explains how to self-host in a secondary location.

### Priority 1 (P1) — make the core task predictable and accessible

3. **Make the solve action honest and reversible.**
   - Button copy: `Run live solve` (solver) or `Preview field` (no solver), with
     a one-line note: "Bundled 2D channel case · simpleFoam · about 30 seconds".
   - Show elapsed seconds and a three-step state: meshing, solving,
     post-processing. Keep the job ID copyable.
   - Add cancel (best-effort) and retry; on failure show the reason and the job
     ID, and keep the action enabled.
   - Fix the poll: on a network error, keep a bounded retry with a visible
     "connection lost" state instead of stopping silently.
   - Label the case honestly as a bundled 2D channel, not a NACA airfoil solve.

   Acceptance: a mocked-failure Playwright test reaches a visible retry; a live
   solve shows elapsed time and terminal state; no `NACA` claim for the bundled
   channel result.

4. **Fix closed-sidebar focus and mobile controls.**
   - When closed, make the sidebar subtree inert (`inert` attribute or
     `hidden`), not only `aria-hidden`; return focus to the opener on close.
   - Add a body scroll lock while the mobile drawer is open.
   - Ensure 44-pixel tap targets for the burger, close, tabs, solve, and probe
     actions.

   Acceptance: keyboard Tab never enters a closed sidebar; Escape closes and
   restores focus; a 375-pixel viewport has no sub-44-pixel primary control.

5. **Give the lab a keyboard and text path.**
   - Add a keyboard-accessible probe: a station slider or a probe table with
     p, |U|, and T values.
   - Add a text summary under the Cp chart (for example: "Peak suction at x/c
     0.32; Cn 0.77; separated region after x/c 0.8"), with the Plotly chart as a
     visual enhancement.
   - Run an accessibility scan (axe) and fix serious issues (labels, contrast,
     focus rings, reduced motion).

   Acceptance: a keyboard-only Playwright test reads a probe and the chart
   summary; axe reports no serious or critical issues on the overview and lab.

6. **Add first-run guidance and loading progress.**
   - A dismissible three-step coach mark: orbit, click to probe, change field.
   - A visible loading line for the 3D viewer ("Loading 3D viewer · 60%") and a
     timeout message that offers Reload.
   - Persist the dismissal per browser.

   Acceptance: first visit shows the guide; it can be dismissed; the loading
   state is visible before the canvas and disappears after.

### Priority 2 (P2) — performance, sharing, and copy

7. **Split the heavy chunks and measure.** Defer Plotly and the VTK viewer until
   the lab is in view, split the chart from the viewer, and set a budget. The
   current Vite warning is a UX cost, not just a build warning.
   Acceptance: the lab route's initial JavaScript budget is recorded; the largest
   chunk is under the agreed budget; a throttled Playwright run meets the
   first-render target.

8. **Persist and share state.** Put the selected NACA code or uploaded model,
   field, flow settings, and job ID in the URL or local storage; add a Copy link
   action. Acceptance: reload restores the state; a copied URL opens the same
   view.

9. **Audit marketing claims and the Pro call to action.** State clearly that the
   bundled case is a 2D channel, that the solver runs on the host, and that the
   public Pages site is a static demo. Remove or gate the `$49 / mo` card until
   there is a real entitlement and checkout.
   Acceptance: copy review with no unqualified "RANS sweep" or "NACA solve"
   claim; the Pro card is absent or links to a real flow.

10. **Unify the status component.** Use one `SolverStatus` component and one
    vocabulary across the badge, lab, hydro page, and sidebar; expose technical
    details behind a disclosure.
    Acceptance: a single status component is used in all three places; a
    snapshot test covers the four states.

## Constraints and traps

- The same-origin app must be built with `npx vite build --base=/`; `npm run
  build` writes the GitHub Pages base and breaks the HTTPS app. The secure
  script already builds `--base=/`.
- `tailscale serve` needs the operator set (`sudo tailscale set --operator=owner`)
  or root. The mapping must target `http://127.0.0.1:...`; the tailnet IP is not
  a valid Serve target.
- Do not touch JEF Caddy on `443`. Use `8443`.
- Keep the static/offline path and the public Pages build working; the offline
  specs must stay green.
- The tailnet e2e is opt-in with `TAILNET_APP_URL`; use `--retries=0` so a
  first-paint race cannot hide behind a retry.
- The container can edit and build at `/audit/foil-cfd-site`, but Playwright and
  Serve need the host. Run `npm run lint`, `npm run typecheck`, and the relevant
  e2e specs before every commit.
- Do not claim the bundled 2D channel is a NACA airfoil. Do not put
  `docker compose` in the primary status.
- No placeholders or ellipses in copy-paste commands; expand acronyms on first
  mention.

## Verification commands

Container (edit and build):
```bash
cd /audit/foil-cfd-site
npm run lint
npm run typecheck
npx vite build --base=/
```

Host (secure origin):
```bash
tailscale serve status
curl -sS -o /dev/null -w 'app=%{http_code}\n' https://ws24.taile17668.ts.net:8443/
curl -sS -o /dev/null -w 'api=%{http_code}\n' https://ws24.taile17668.ts.net:8443/api/health
```

Host (e2e):
```bash
cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
TAILNET_APP_URL="https://ws24.taile17668.ts.net:8443/" \
  npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome --retries=0
```

## Start here

1. Read this file and `docs/HANDOFF-2026-11-24-foil-next.md`.
2. Apply P0 item 1 and prove the one HTTPS origin with the two curl checks and
   the tailnet e2e.
3. Then P0 item 2 (status copy) with its Playwright assertion.
4. Continue to P1 only after the P0 proof is committed and pushed.
5. Push from `ws24` with
   `bash "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"`.
