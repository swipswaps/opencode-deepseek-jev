# Upstream opencode issues (ready to paste to GitHub)

Environment: opencode 1.18.33 (server) + 1.18.32 (pinned installer),
`opencode web --hostname 0.0.0.0 --port 4096` behind Basic auth,
Linux, session with 715 messages / 2799 parts. All calls below carry
valid Basic credentials (small requests return fast).

## Issue 1: `GET /session/:id/message` ignores `offset` — pagination is dead

Every page returns the first 50 rows regardless of offset:

```bash
curl -H "Authorization: Basic ..." \
  'http://127.0.0.1:4096/session/ses_f1d27512affeO4Z3ZoeWK9noI6/message?limit=50&offset=0' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['info']['id'])"
# msg_0ea3111e3001
curl -H "Authorization: Basic ..." \
  'http://127.0.0.1:4096/session/ses_f1d27512affeO4Z3ZoeWK9noI6/message?limit=50&offset=800' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['info']['id'])"
# msg_0ea3111e3001   <- identical: offset has no effect
```

Expected (GitHub/Stripe convention): honor offset (or document cursor
pagination), so a full transcript is retrievable in bounded pages.
GitHub paginates with per_page caps + Link cursors:
https://docs.github.com/en/rest/using-the-rest-api;
Stripe uses cursor + hard limit with fail-fast errors:
https://stripe.com/docs/api/pagination. Either shape beats silent
misbehavior. CLI attach path (the working resume route) is documented at
https://dev.opencode.ai/docs/cli (`opencode attach [url]`, `-s/--session`).

## Issue 2: unbounded `GET /session/:id/message` never returns

```bash
curl -m 120 -H "Authorization: Basic ..." \
  'http://127.0.0.1:4096/session/ses_f1d27512affeO4Z3ZoeWK9noI6/message'
# ...times out; server stays healthy for small requests
```

Small pages (`limit=50`) return in ~0.2 s, so this is serialization
cost on the unbounded query, not a dead server. Expected: cap `limit`
server-side and fail fast (400/413) instead of hanging, per the same
convention as Issue 1. Together the two defects leave **no REST path
to a complete transcript** (workaround used here: direct sqlite read).

## Issue 3 (UX): empty states never name their cause

Reproducible against the same server, all with HTTP 200 and valid
payloads behind them:

- Web root shows "Nothing here yet" while `/api/session` returns 44
  sessions (2 projects via `/project`).
- Deep link `/server/<b64>/session/<id>` renders the title shell but
  never fetches messages (zero message API calls, zero errors).
- Session search calls `/api/session?limit=5000` (200, 44 rows) yet
  renders "No sessions found".
- "New session" (+) button and Ctrl+T do nothing with no project
  context selected, without saying so.

Suggested rule (standard empty-state practice): every empty state
should state what is empty, why, and the one next action — e.g.
"44 sessions loaded, 0 match this filter" instead of "No sessions
found". Happy to split into separate issues on request.

## Root causes (monitored 2026-10-01, opencode 1.18.32 server + UI)

Monitored the live instance (browser network trace + served-bundle
analysis + direct endpoint probes). The UI is client/server-skewed
*within the same shipped version*:

1. **Search box calls a nonexistent route.** The search path calls
   `experimental.session.list({roots, search, limit})`, but the
   server implements no `/api/experimental/*` route — it returns
   200 with the SPA shell HTML, JSON parsing throws, the catch
   swallows it, and the UI prints "No sessions found". Meanwhile
   plain `/api/session?search=Explore` returns 200 with 1 match and
   `/api/session?directory=/workspace` returns 30 rows. Variants
   probed (`/experimental/...`, `/api/experimental/.../search`,
   `/api/session/search`): shell, shell, HTTP 400.
2. **Sidebar lists are project-scoped to state that never hydrates
   on hard load.** Rendering reads `projectSessions()` /
   `workspaceSessions()`, but with no selected project and an empty
   workspace registry both yield nothing — while the data sits one
   fetch away.
3. **Deep-link session view reads messages from a client store**
   (`session.get(id)` + `data.message[id]`) fed by a subscription
   that never starts on hard load: exactly one API call fires
   (`GET /session/:id`, 200) and zero message fetches follow.
4. **Unbounded message dump hangs; `offset` is ignored** (Issues 1-2
   above) — so even a working client could not page a 715-message
   session over REST.

Net: data plane healthy (44 sessions, 715 msgs on the target),
control/API plane healthy (200s, sub-second paginated reads),
presentation plane broken in four independent, all-silent ways.
Nothing below the UI layer needs fixing; everything below it
already works (see transcript-resume flow).
