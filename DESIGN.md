# DESIGN.md — observability UI tokens

Bound before any UI change, like the OpenDesign / DeepSeek Harness pattern:
tokens and rules first, then code. One accent, an 8px grid, Material
elevation. Read-only, offline, single accent colour.

## Tokens

| token | value | use |
| ----- | ----- | --- |
| `--bg` | `#0d1117` | page background |
| `--surface` | `#161b22` | cards, charts, panels |
| `--fg` | `#e6edf3` | primary text |
| `--muted` | `#8b949e` | secondary text |
| `--border` | `#30363d` | hairlines |
| `--accent` | `#2ea043` | **one** accent: active nav/tab, primary action, positive signal |
| `--danger` | `#ff7b72` | errors, cost ≥ $0.10 |
| `--radius` | `8px` | cards, inputs, buttons |
| `--pill` | `999px` | tags, badges, nav items |
| `--space` | `8px` | spacing unit (use 8 / 16 / 24) |
| `--e1` | `0 1px 3px rgba(0,0,0,.35)` | resting elevation |
| `--e2` | `0 4px 10px rgba(0,0,0,.45)` | hover elevation |

## Rules

- **8px grid.** Padding and margins are multiples of 8 (8, 16, 24).
- **One accent** (`--accent`). Do not introduce a second accent. Chart series
  keep their categorical palette (blue / purple / green / orange / red) because
  there colour is data encoding, not decoration.
- **Material elevation.** Cards rest on `--e1` and rise to `--e2` on hover;
  the sticky nav is the top layer (`z-index: 30`).
- **Radius 8px** on surfaces, **999px** on pills/tags.
- **Type scale.** h1 18 · h2 13 uppercase muted · body 13 · small 12 · tiny 11.
- **Status colours.** `LIVE` green, `idle` muted, cost-danger red.
- **Stable review hooks.** `data-od-id` on interactive rows/targets so a
  reviewer can point at an element without reading the DOM.

## Where it lives

`scripts/dashboard.mjs` defines `THEME_CSS` and injects it (with `NAV_CSS`)
on every page via `nav()`. Page-specific CSS should not hardcode a colour the
tokens already cover. Token names mirror the OpenDesign `DESIGN.md` shape
(background / foreground / border / accent / radius) so the same brief style
applies here.
