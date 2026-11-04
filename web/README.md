# MUI observability app (`/app/`)

This is the React 19 + Material UI 9.5 + Vite 8 version of the `:5099`
observability dashboard. It is a separate, buildable app; the original
no-build dashboard remains at `/`.

## Build and serve

```bash
cd web
npm ci
npm run build
```

The Node dashboard (`scripts/dashboard.mjs`) serves `web/dist` at `/app/` and
hashes assets under `/app/assets/*`. If `web/dist` is missing, `/app/` returns
a 503 with the build command. `dist/` and `node_modules/` are gitignored.

Local development:

```bash
cd web
npm run dev -- --host 0.0.0.0
# http://127.0.0.1:5174/app/
```

Vite proxies `/api`, `/manifest.webmanifest`, and the icons to
`https://127.0.0.1:5099` (self-signed cert accepted for local dev).

## What it shows

- **Overview** — total cost, input/output/reasoning/cache tokens, health
  findings, recent sessions.
- **Activity timeline** — the same `/api/activity` rows as the legacy page:
  newest first, filters (All/Tools/Text/Reasoning/Errors/Steps), search,
  last-30/all, expand/collapse, copy, duration, and a start-dot/relative-bar
  timeline on desktop.
- **Sessions** — `/api/sessions?limit=200`, search, cost/tokens/model/update,
  desktop table and mobile cards, links into the OpenCode session URL.
- **Todos** — `/api/todos` with status chips.

Live data uses one `EventSource` on `/api/stream` (snapshot → delta) with an
initial REST fallback. `/api/health` and `/api/sessions` are fetched separately
on a 60 s interval.

## Layout / Android

- MUI permanent `Drawer` at `md+`; MUI `BottomNavigation` below `md`.
- AppBar, drawer, bottom nav, and body respect safe-area insets.
- Activity rows stack under 900 px; the time lane and relative bar are hidden
  on mobile while time/type/duration/detail/copy remain.
- The app has its own `/app-manifest.webmanifest` (`start_url=/app/`,
  `scope=/app/`) and uses the shared `/sw.js` service worker (scope `/`), so
  Chrome can install it; verify with `Page.getInstallabilityErrors`.
- Hash routes (`#overview`, `#activity`, `#sessions`, `#todos`) preserve the
  view through Android back/refresh; the desktop drawer also links to the
  classic `/` view.
- Current verification: zero page/console errors; 390 px width = viewport;
  installability `[]`.

## Tests / evidence

- `npm run build` (Vite build is the source-level gate).
- Playwright (host browser) exercised Overview, Activity, Sessions (123 rows),
  Todos (5), desktop 1280×900 and mobile 390×844.
- Screenshots:
  - `docs/ux/status-mui-desktop.png`
  - `docs/ux/status-mui-activity-desktop.png`
  - `docs/ux/status-mui-mobile.png`
  - `docs/ux/status-mui-activity.png`

## Libraries / notes

- MUI 9.5, React 19.3, Emotion 11.14, Vite 8.3.
- No MUI X dependency yet. Add `@mui/x-charts` for burn-down/trend charts.
- The bundle is ~550 kB minified / ~171 kB gzip; code-split if it grows.
- The app is read-only and uses the server's existing API/CSP. Do not put
  secrets in this app; it is served from the same local origin.
