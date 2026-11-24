# Handoff — proceed with foil.cfd (2026-11-22)

Purpose: a fresh session finishes the **foil.cfd** payload apply → verify → push.
Read this file; do not fork/continue the session that wrote it.

## Where things live

- foil.cfd repo (**HOST-ONLY**): `/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site`
- GitHub: `swipswaps/foil-cfd-site`; site domain `foil.cfd`.
- Host-ops skill (same files as the container's `/home/node/.config/opencode/skills/agent-host-ops`):
  `$HOME/.config/opencode/skills/agent-host-ops`
- Entry point: `host-apply-foil.sh` — dry-run by default, payload colocated, self-locating.
- The container cannot read `/home/owner`, so the agent must hand the **user** host commands.
- Backend: FastAPI on `127.0.0.1:8002` (docker compose + OpenFOAM). Health: `/api/health`.

## What the payload does (audited; from the skill)

- **frontend** (`apply-frontend.sh`): configurable backend origin, solver detection, honest
  hydro pill; runs `npm run lint` + `npm run build`, commits only on pass.
- **backend** (`apply-backend.sh`): registers `/api/jobs/default/surface.vtp` before
  `/api/jobs/{job_id}`, analysis fallback + non-finite clamp; rebuilds backend, waits for
  `/api/health` 200, runs `scripts/test_cfd_tools.sh`; commits only on a clean tool test.
- **logos** (`apply-logos.sh`): split `foil` / `.cfd` wordmark SVGs; `npm run build`; commit.
- Each layer backs up to `$FOIL/.repair-backups/<layer>-<ts>/` and prints its commit sha;
  revert with `git -C "$FOIL" revert` and that sha.

## Step 0 — preserve the JEF work (do not lose it)

- `/workspace` (JEF) HEAD `0a58238`, level with origin. Uncommitted:
  - `M scripts/README.txt`
  - `M scripts/chromium-video-ab.sh`
  - `M scripts/tools.json`
  - `?? scripts/chromium-video-ab-run.sh`
- Gates: `lint` 452/0; both A/B self-tests PASS. **Do not commit these unless the user asks.**
- A/B result (for context): `GRAPHIC_DRIVER=default` and `=amd` both hardware-decode H.264
  (`dec_rate` ~90–100M ns/s), so the switch is redundant for decode; both-hardware pacing was
  equal. `--software-control` (forced software vs hardware) was marginal and load-noisy
  (one run INCONCLUSIVE at 0.00533 vs 0.00508, one PASS at 0.00531 vs 0.0). The test clip
  `reversed_final.mp4` does not stutter in either mode. Evidence:
  `logs/phd-audit-20261122-chromium-verify.md`, `logs/ab-run-20261122T20*/`.

## Step 1 — probe + dry-run (run ON THE HOST as `owner`)

```bash
SKILL="$HOME/.config/opencode/skills/agent-host-ops"
FOIL=/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
test -d "$SKILL"
test -d "$FOIL/.git"
command -v docker npm curl python3
bash "$SKILL/lint-all.sh"
FOIL="$FOIL" bash "$SKILL/host-apply-foil.sh" --dry-run
```

The dry-run prints host/user/target/rev, before-probes (`:8002/api/health`,
`.../api/jobs/default/surface.vtp`), the plan, and the foil dirty tree. **Read the dirty tree
first**; reconcile unrelated changes before applying. Confirm the target files exist:

Observed 2026-11-22T16:05Z: skill resolves to
`/home/owner/.config/opencode/skills/agent-host-ops`; foil rev `73a2f66`, clean tree;
`:8002/api/health` 200; `.../api/jobs/default/surface.vtp` returned `000` at the probe's
4 s limit. Re-probe with a 40 s limit to separate a cold PyVista import from the route-order
404 the backend payload fixes:
`curl -sS --max-time 40 -o /dev/null -w 'http=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8002/api/jobs/default/surface.vtp`

Progress 2026-11-22T16:10Z: backend applied → commit `4eee8fb` (revert with
`git -C "$FOIL" revert 4eee8fb`); tool test `PASS=15 FAIL=0`; `/api/health` and
`/api/jobs/default/surface.vtp` both 200. Health reports `solver_available=False`, so the
OpenFOAM RANS burst is not active — decide separately whether that is in scope (the payload
fixes route order + analysis, not the solver install). Remaining: frontend + logos, then push.

```bash
ls -1 "$FOIL/src/hooks/useBackendProbe.ts" "$FOIL/src/hydro-main.tsx" "$FOIL/package.json" "$FOIL/backend/main.py"
```

## Step 2 — apply (host; reversible)

Stage-only review first (no commits), then commit per layer on pass:

```bash
NO_COMMIT=1 bash "$SKILL/apply-backend.sh" "$FOIL"
NO_COMMIT=1 bash "$SKILL/apply-frontend.sh" "$FOIL"
NO_COMMIT=1 bash "$SKILL/apply-logos.sh" "$FOIL"
```

If the staged diffs look right, run the entry point (dry-run is the default; `--apply` commits):

```bash
FOIL="$FOIL" bash "$SKILL/host-apply-foil.sh" --apply --only backend
FOIL="$FOIL" bash "$SKILL/host-apply-foil.sh" --apply --only frontend,logos
```

Acceptance per layer:
- **backend**: `/api/health` 200; `/api/jobs/default/surface.vtp` contains `VTKFile`;
  `/api/solve` → job → `/analysis` with `n_points > 0`; job `surface.vtp` parses.
- **frontend**: `npm run lint` and `npm run build` both pass.
- **logos**: SVGs parse (`xml.etree`) and `npm run build` passes.

## Step 3 — push (host)

```bash
bash "$SKILL/push-all.sh" --dry-run
bash "$SKILL/push-all.sh"
```

Auth order: `gh` credential helper, else `$HOME/.config/opencode/github-token`, else `GH_TOKEN`.
`push-all.sh` pushes foil then jef and refuses a dirty repo with ahead/behind drift.

## CI failure + fix (2026-11-22T21:29Z)

Pushed `1eb2b54` (`4eee8fb` backend + `1eb2b54` frontend). The `e2e` job failed at
“Run advanced e2e”, so `deploy` was skipped and the live site is still `73a2f66`.

Root cause found by diffing `73a2f66:backend/main.py` against the applied file: the backend
payload was a **pre-retention snapshot**. Its only effect was deleting the `job_retention`
wiring (`from job_retention ...`, `_prune_jobs()`, the startup and per-solve calls — ~26–33
lines). The advanced spec’s “job retention keeps backend/jobs bounded” test then fails.
The `73a2f66` file already had the working `jobs/default/surface.vtp` route, so the payload
added nothing there.

Fix applied to the shared payload:
`~/.config/opencode/skills/agent-host-ops/payload/backend/main.py` is now byte-identical to
`73a2f66:backend/main.py` (retention restored; `py_compile` OK; backup
`main.py.bak.20261122T212940Z`). The repo still needs the revert + rebuild:

```bash
git -C "$FOIL" revert --no-edit 4eee8fb
( cd "$FOIL" && docker compose up -d --build backend )
bash "$SKILL/push-all.sh" --dry-run
bash "$SKILL/push-all.sh"
gh run watch -R swipswaps/foil-cfd-site
```

If the new run still fails, read the failing assertion with:

```bash
gh run view -R swipswaps/foil-cfd-site --log-failed
```

Result 2026-11-22T21:37Z: run `45072768816` for `79a2d33` → **e2e, build, deploy all success**.
`https://foil.cfd` returns 200 (→ `swipswaps.github.io/foil-cfd-site/`, title `FOIL.CFD`) and
serves `main-B757vLu9.js`, `useBackendProbe-9etiEwV6.js`, `hydro-DBueSIUM.js`; the logo has
`foil` / `.cfd`. This closes the apply → verify → push.

Remaining:
- `solver_available=False`: the image has no OpenFOAM solver, so the 3D RANS burst is not
  active (browser/analytic path only). Decide whether to add the solver later.
- JEF `/workspace` chrome A/B changes are still uncommitted (not pushed; `push-all.sh` left
  them alone). Commit only on request.
- Branch protection requires the `e2e` check but admin bypass is allowed: both pushes printed
  “Bypassed rule violations”. To make `e2e` a hard gate, remove admin bypass or push via PR.



- `apply-frontend.sh` stages a fixed list (`src/components/Sidebar.tsx`, `package.json`,
  `playwright.config.ts`, `tests/e2e`, `.gitignore`). If any path is absent, `git add` aborts
  and nothing is committed; check the list before applying.
- `apply-backend.sh` needs the compose `backend` service and docker; it rebuilds and waits for
  `/api/health` 200 before testing.
- All three layers commit on pass. Use `NO_COMMIT=1` to stage and review first.

## Do not

- Do **not** `--fork`/`--continue` the source session, and do **not** paste raw terminal
  transcripts (the guard's injection classifier flags copied shell output).
- No `…`, `...`, `~`, or `<placeholder>` in any command you offer; probe paths first.
- Do not commit the JEF (chromium) changes unless the user explicitly asks.
- Do not run the container copy of the skill against the foil path; the foil repo is host-only.

## Static-mode root cause + fix (2026-11-22T22:10Z)

Chrome 142+ Local Network Access (LNA) gates public HTTPS → loopback fetches behind the
`loopback-network` permission. The old hook auto-probed on load and aborted at 2.5 s, so the
prompt was dismissed or the request cancelled and the badge stayed "Static mode — no localhost
backend". Fix: no auto-probe on public origins; explicit "Connect local backend"; add
`targetAddressSpace` to backend fetches; 30 s consent timeout; permission-denied reason.
Artifact: `~/.config/opencode/skills/agent-host-ops/host-fix-lna.sh` (payload
`payload/lna/lna.patch.gz.b64`). Dry-run first, then `--apply` (add `--commit` in the same run
to commit). Verified: lint/typecheck/build pass; Playwright Chromium 159 shows loopback
auto-online, public HTTPS 0 auto requests then online after a `loopback-network` grant + Connect;
repo static, advanced-sidebar, and ux specs pass. Solver still off: `Dockerfile.openfoam` omits
`job_retention.py` (import crash), uses a pip flag apt's pip 22 rejects, and the bundled case
lacks `controlDict`/`fvSchemes`/`fvSolution`; those are a separate host change.

## Solver enablement (2026-11-22T22:57Z)

Artifact: `~/.config/opencode/skills/agent-host-ops/host-enable-solver.sh` (payload
`payload/solver/solver.patch.gz.b64`). Dry-run first, then `--apply` (add `--commit` in the
same run). `--files-only` applies the patch and runs the Python checks without docker.
The patch: copies `job_retention.py` into the OpenFOAM image, drops the unsupported pip flag,
adds GL libs, adds `0/{U,p,k,epsilon,nut}`, `constant/{transportProperties,turbulenceProperties}`,
and `system/{controlDict,fvSchemes,fvSolution}`; treats a non-zero solver rc as failed and
always writes `case.foam`; reads the latest time and converts cell to point fields; extends the
tool-test poll to 300 s and asserts `analysis.source == "openfoam"`. The script builds
`docker-compose.openfoam.yml`, waits for `solver_available=true`, runs a real solve, asserts
`source=openfoam` plus `velocity_magnitude_max>0`, checks the job VTP, runs
`scripts/test_cfd_tools.sh`, and commits only on pass. The bundled case remains a 2D channel
(`backend/cases/naca0012/README.txt`), not an airfoil.

First host run: the image built and the container started, but `/api/health` never came up. The base image's `/openfoam/run` entrypoint does `cd "${HOME}"`, overriding `WORKDIR /app`, so `python3 -m uvicorn main:app` cannot import `main` (the process exits and compose restarts it). Fix: `CMD ["/usr/bin/python3", "-m", "uvicorn", "main:app", "--app-dir", "/app", ...]`. The canonical solver payload now includes it. For the already-patched host tree use:

    bash "$HOME/.config/opencode/skills/agent-host-ops/host-enable-solver.sh" --resume --dry-run
    bash "$HOME/.config/opencode/skills/agent-host-ops/host-enable-solver.sh" --resume --apply --commit

`--resume` prints `docker compose -f docker-compose.openfoam.yml ps -a` and the container logs as evidence, applies only the entrypoint hunk (payload `payload/solver/entrypoint.patch`), then rebuilds/starts/solves/tests and commits on pass.

## Solver ENABLED (2026-11-23) — apply → verify → push DONE

Commit `4b9500e` on `main` (`b687a18..4b9500e`), pushed; CI run `45132593508`.
`scripts/test_cfd_tools.sh` PASS=16 FAIL=0: blockMesh → simpleFoam → analysis
(source=openfoam, n_points>0) → job surface.vtp all pass; `/api/health` reports
`solver_available=true`, `blockMesh_available=true`.

Three root causes fixed after the "healthy but no solve" state (each proven by
the job logs, not assumed):

1. **Base-image entrypoint.** `opencfd/openfoam-default:2312` sets
   `ENTRYPOINT ["/openfoam/run"]`; the wrapper dies before uvicorn starts
   (`/openfoam/run: 2: /usr/bin/python3: Syntax error: end of file unexpected`),
   so `--app-dir` alone could never help. Fix: `ENTRYPOINT []` + `CMD ["/bin/bash",
   "-c", "if [ -f /openfoam/profile.rc ]; then . /openfoam/profile.rc ''; fi;
   exec /usr/bin/python3 -m uvicorn main:app --app-dir /app ..."]`.
   Tool: `host-fix-solver-entrypoint.sh`; live telemetry `watch-solver-health.sh`;
   failed-solve forensics `diag-solver-job.sh`.
2. **`system/blockMeshDict` was v1012 syntax.** `convertToMeters`→`scale`, and a
   stray `;` after the `blocks` `hex ... simpleGrading (...)` entry (the list
   parser expects the next block word; found `;`). Tool: `fix-solver-case.sh`.
3. **`system/fvSchemes/divSchemes`** lacked
   `div((nuEff*dev2(T(grad(U))))) Gauss linear;` (the kEpsilon stress term).

Canonical fresh-tree order on the host: `host-enable-solver.sh --files-only`
(applies solver.patch + python checks) then `fix-solver-case.sh --apply --commit`
(fixes 2+3, then delegates 1 + rebuild + health-wait + real solve + commit).

Still open: branch protection allows admin bypass (push logged "Bypassed rule
violations"), so `e2e` is not a hard gate; live `foil.cfd` is static
(browser/analytic path) — the OpenFOAM backend runs on the host, not via Pages.

## Deploy resilience (2026-11-23)

Live `#cfd` failed for one client with "Failed to fetch dynamically imported
module … CfdLab-BZRZQDxp.js". Diffing the deploy: the live `main-CztZC7z7.js`
imports `CfdLab-cDofOWad.js` (200), so the deploy is healthy; `BZRZQDxp` is a
prior build's hash. Pages serves `index.html` with `cache-control: max-age=600`,
so a client holding an old `index`/`main` lazy-imports a chunk the redeploy
removed. Playwright proved it: aborting the current `CfdLab` chunk reproduces
"App failed to load"; a clean context renders the lab.

Fix commit `a83ad37` (pushed; CI run `45149072899` success): an inline
`vite:preloadError` + `unhandledrejection` handler in `index.html` reloads once,
cache-busted (`?v=<ts>`), loop-guarded by `sessionStorage`. Tool:
`fix-site-stale-chunk.sh`. Verified post-deploy from the sandbox: Playwright
aborts the chunk once → handler navigates to `?v=…` → `recovered=true`
(title `FOIL.CFD`, lab rendered).

## Component e2e + README + deps (2026-11-23)

Follow-on upgrade pass ("upgrade" in both senses: quality and versions). No open
issues or Dependabot PRs were outstanding; `npm audit` = 0 vulnerabilities;
`npm outdated` = oxlint 1.93 -> 1.94 only.

New tests `tests/e2e/foil-offline.spec.ts` (commit `3a161d5`) and
`tests/e2e/foil-components.spec.ts` cover every surface: NavBar, BackendBadge,
Hero, ProjectShowcase, ReadmeSection, Sidebar/DevicePanel, the CFD lab chrome
(CfdLab/CpPolarChart/CfdVtkViewer), the hydro workbench, and a REAL online solve.
Validated from the sandbox with `@playwright/test` + headless Chromium:
- offline (live Pages build, loopback backend aborted): 6 pass, 1 skip;
- online (repo built, forwarded to the real host backend at
  `192.168.4.24:8002`): 7/7 pass, including solve -> job completed -> chart.

Host scripts (dry-run first; `--apply --commit`): `add-component-e2e.sh`,
`write-foil-readme.sh`, `upgrade-foil-deps.sh`, all linted. Run order:
add-component-e2e -> write-foil-readme -> upgrade-foil-deps -> push-all. The
component spec is wired into BOTH CI e2e steps (advanced = online, static =
offline). Note: the app also probes `DEV_BACKENDS` (127.0.0.1:8000/8002), which is
how CI's advanced step reaches its docker backend; `VITE_BACKEND_URL` is for
non-loopback dev.

Shipped `b8beedb` (commits `24dae25` components, `47cada8` README, `b8beedb`
deps). CI run `45157041374`: build (audit/lint/typecheck/build), e2e (advanced +
static, both incl. `foil-components.spec.ts`), and deploy all green. Only
remaining outstanding item: 6 pre-existing oxlint WARNINGS in `src/hydro-main.tsx`
(`only-export-components` x3, `purity`/Math.random x3) — warnings, 0 errors; do
not block CI. Remediation (not done): extract the components to their own files
and hoist the particle cloud into `useMemo` with a seeded PRNG.

### Overlap + Retry fix (2026-11-23)

The backend badge was `position: fixed; top:64px; right:16px` and floated over
the CFD-lab header: measured **16,195 px^2** overlap at `#cfd` (the hero is
`position:relative` with an absolute tablist, so a fixed pill sits on top). Fix
commit `a9b0d32`: `.backend-badge-wrapper` is now in normal flow (flex row at the
top of `main`) so it reserves space; measured live overlap is now **0**. Added
two Playwright regressions to `foil-components.spec.ts` — badge-vs-tabs/lab-head
collision (fails 16195 on the old build, passes on the new) and Retry
offline->online when a loopback `/api/health` answers. CI run `45164015498`
(build/e2e/deploy) success; live CSS `main-DB0EL5JM.css`; both regressions pass
against the production URL. Note: in-flow means the pill scrolls away at the
`#cfd` anchor — the lab header still shows "OpenFOAM ready"/"Solver unavailable",
and Retry on the public site additionally needs browser Local Network Access.

### Local-network "Connect" root cause (2026-11-23)

Incognito + granting "local network access" still showed "Static mode", so it was
NOT cache. The real backend's PNA preflight was the cause: `OPTIONS /api/health`
with `Origin: https://swipswaps.github.io` and
`Access-Control-Request-Private-Network: true` returned `access-control-allow-origin`
and methods but **no `access-control-allow-private-network`**. Chrome's Local
Network Access blocks the fetch without it, even after Allow. Fix script
`fix-backend-pna.sh`: adds a `BaseHTTPMiddleware` that sets
`Access-Control-Allow-Private-Network: true` (outermost, so it decorates the CORS
preflight response), rebuilds the backend, verifies the header via `curl`, and
adds a CI step asserting it. No frontend change needed (it already sends
`targetAddressSpace`).
