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
