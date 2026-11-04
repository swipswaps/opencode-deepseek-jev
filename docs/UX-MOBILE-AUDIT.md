# Observability UX / Android / MUI audit — 2026-11-04

Scope: the `:5099` dashboard. "Android support" is interpreted as a responsive,
installable web app in Chrome on Android (not a native APK). A Trusted Web
Activity can wrap the same PWA later if Play Store distribution is needed.

## What was wrong

The old home page rendered the same `/api/activity` rows twice:

- **Live activity** (up to 80 rows, `more/less` expand, copy).
- **Diagnostic timeline** (last 30, time axis, duration visual, copy).

Both came from `x.cmd` / `x.text` / `x.files`; the timeline added time/type/
duration. That duplication made the page longer without adding data.

Measured at 390×844 before the change:

| Signal | Before | After |
| --- | --- | --- |
| Page horizontal overflow | none (inner card scrolled) | none (`390 = 390`) |
| Sticky nav height | 109 px, three rows | 61 px, one scrollable row |
| Activity card top | 7,243 px down | 647 px down |
| Activity representation | two cards | one card |
| Timeline grid width | ~700 px minimum inside a 350 px card | stacks; 344 px client = 344 px scroll |
| Show-all behaviour | 80 in activity, 30 in timeline | one 30/all toggle, 80 available |
| Touch targets (primary) | many 24–36 px | 44 px nav/chips/copy/expand |
| Installability | no manifest/service worker | `Page.getInstallabilityErrors: []` |

The duplicate data was worse on a phone because the timeline used a fixed
six-column grid and the page put activity near the bottom.

## Decision

Use the existing no-build server and vendored d3/Plot, but:

1. Merge Live activity + Diagnostic timeline into **one Activity timeline**.
2. Keep the same API rows; add filters (all/tools/text/reasoning/errors/steps),
   a 30/all toggle, per-row expand/copy, and a visible count.
3. Use newest-first order (log semantics) with the time dot and relative
   duration preserving temporal context.
4. Stack rows at ≤720 px; hide the chart lanes, keep time/type/detail/duration.
5. Move the activity card directly under the top stats.
6. Add a manifest, service worker, icons, `viewport-fit=cover`, safe-area
   padding, and 44 px touch targets; verify Chrome installability.

A follow-up request was to proceed with the full MUI/React version. That is now
implemented as a **separate `/app/` app** (source in `web/`) so the proven
no-build page at `/` remains a fallback. The app reuses the same `/api/*`
contracts and has its own `/app-manifest.webmanifest` with
`start_url=/app/`; the existing service worker is scoped to `/` and covers it.

## Library / template findings

### Material UI (MUI) v9

- Official browser support is the latest stable Chrome (≥117), which covers
  current Android Chrome: <https://mui.com/material-ui/getting-started/supported-platforms/>.
- MUI is a **React** component library; a production migration needs React,
  Emotion, and a bundler (Vite/webpack). The official template's README lists
  `@mui/material`, `@mui/icons-material`, `@emotion/*`, `@mui/x-charts`,
  `@mui/x-date-pickers`, `@mui/x-data-grid`, and `dayjs`:
  <https://github.com/mui/material-ui/tree/master/docs/data/material/getting-started/templates/dashboard>.
- The responsive-drawer pattern is documented; `temporary` below the breakpoint
  and `permanent` above is the canonical approach:
  <https://mui.com/material-ui/react-drawer/#responsive-drawer>. Stack Overflow
  answers converge on `useMediaQuery(theme.breakpoints.down(...))`:
  <https://stackoverflow.com/questions/42749907/material-ui-responsive-drawer>.
- MUI X Charts is the natural chart layer for a future MUI dashboard:
  <https://mui.com/x/react-charts/>.
- Credible free templates to borrow layout from:
  - Official MUI Dashboard (React + MUI X): <https://mui.com/material-ui/getting-started/templates>
  - Devias Kit / Material Kit React (MIT, ~5.6k GitHub stars):
    <https://github.com/devias-io/material-kit-react>
  - Minimal UI Kit (MIT): <https://github.com/minimal-ui-kit/material-kit-react>
  - Mantis / Berry (MUI, responsive): <https://mui.com/store/collections/free-react-dashboard>
- Community caution: MUI on low-end mobile is reported as slower than lighter
  CSS/Tailwind stacks, though tree-shaking/lazy loading mitigates it:
  <https://www.reddit.com/r/reactjs/comments/14ol16s/light_ui_component_library_but_as_good_as_mui_or/>.

**How it was adopted:** as a separate `web/` app rather than a rewrite.
- Stack: React 19.3, MUI 9.5, Emotion 11, Vite 8.3. Vite builds to `web/dist`
  and the Node dashboard serves `/app/` + `/app/assets/*`.
- The app has an Overview (cost/tokens/health/14-day trend/recent sessions),
  an Activity timeline with filters/search/expand/copy and steps hidden by
  default, a responsive Sessions table/cards with sorting, Todos, `/` search
  focus, hash routes, and an Install action from `beforeinstallprompt`.
- Layout: permanent MUI Drawer at `md+`, MUI `BottomNavigation` under `md`;
  the AppBar/drawer/bottom nav respect safe areas.
- The legacy `/` page still exists; `/app/` is linked from the primary nav.
- Trade-off: the MUI bundle is 569.6 kB minified / 175.8 kB gzip, plus a build step.
  That is acceptable for the richer app but not ideal to force on the tiny
  read-only fallback page.

### Material Web (`@material/web`)

Official Material 3 web components with a buildless CDN quick start:
<https://github.com/material-components/material-web>. However the project is
explicitly in **maintenance mode pending new maintainers** (same README), so it
is a poor foundation for a new dashboard. Material 3 tokens can still inform the
CSS.

### Chosen stacks

**`/` legacy:** existing Node server + inline client (no build), d3 for time
formatting, native CSS grid/flex, PWA manifest/service worker/icons, and
`scripts/pwa-icons.mjs` for raster icons.

**`/app/` MUI:** React 19 + MUI 9.5 + Emotion + Vite 8, built to `web/dist`.
It uses the MUI responsive Drawer/bottom navigation patterns, Material tokens,
and an app-specific manifest. No MUI X dependency yet; MUI X Charts is the
next addition if cost/burn-down charts are wanted.

## Android/PWA references

- Install criteria (manifest, icons, display, service worker):
  <https://web.dev/articles/install-criteria>
- App design, standalone display, `viewport-fit=cover`, safe areas:
  <https://web.dev/learn/pwa/app-design>
- Manifest fields/icons/maskable safe zone:
  <https://web.dev/learn/pwa/web-app-manifest>
- Touch targets: ~48 device-independent px recommended, spaced ~8 px:
  <https://web.dev/articles/accessible-tap-targets>

## Verification

Legacy `/`:
- Headless inline-script test: PASS (timeline rows, detail, duration, copy,
  explore d3 stub).
- Mobile Playwright at 390×844: page width `390`, card width `366`, timeline
  `clientWidth = scrollWidth = 344`, activity card at `y=647`.
- Filter/toggle/expand exercised in the browser: tools `22/80`, all toggle
  changes label, 28 expandable rows, first expand opens.
- PWA routes: manifest `200 application/manifest+json`, `sw.js` `200`, icons
  `200 image/png`; service worker registrations `1`; Chrome
  `Page.getInstallabilityErrors` `[]`.
- Screenshots: `docs/ux/status-timeline.png` (combined card),
  `docs/ux/status-mobile.png` (390 px card).

MUI `/app/`:
- `npm run build`: 569.6 kB minified / 175.8 kB gzip; no build errors.
- Desktop and 390 px Playwright: zero page errors, zero console errors.
- Mobile: document width `390 = innerWidth`, activity rows render, Sessions
  (123) and Todos (5) render, bottom navigation is fixed at 64 px + safe area,
  and the filter chips wrap instead of overflowing.
- `/app-manifest.webmanifest` `200 application/manifest+json`; app service
  worker registration `1`; Chrome `Page.getInstallabilityErrors` `[]`.
- Screenshots: `docs/ux/status-mui-desktop.png`,
  `docs/ux/status-mui-activity-desktop.png`,
  `docs/ux/status-mui-mobile.png`, `docs/ux/status-mui-activity.png`.

## MUI app follow-ups

1. Add MUI X Charts (`@mui/x-charts`) for cost burn-down / per-day trends.
2. Hash deep links are implemented (`#overview`, `#activity`, `#sessions`,
   `#todos`), so Android back/refresh preserves the view; move to React Router
   if path routes become necessary.
3. Code-split the MUI bundle if the 550 kB warning becomes a problem.
4. Decide whether to make `/app/` the primary PWA `start_url` after the legacy
   page is retired; both manifests are currently installable separately.
5. Keep the common `/api/*` contracts and the server's read-only posture.
