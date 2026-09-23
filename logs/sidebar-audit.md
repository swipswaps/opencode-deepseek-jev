# Sidebar Audit — OpenCode + DeepSeek + JEV container

- **Audit date:** 2026-09-23 21:39 UTC (run inside the `opencode-deepseek-web`
  container).
- **Scope:** `/workspace` (read/write repo) and `/workspace/notes` (read-only
  chat logs, 47 files: 13 `.txt`, 33 `.png`, 1 `.py`).
- **Environment:** Node v22.23.2, OpenCode 1.18.32, user `node`. `docker`,
  `sqlite3`, and `python3` are **not** on PATH inside this container, so all
  database queries below use Node's built-in SQLite (`node --experimental-sqlite`).
- **Mount note:** the `opencode-web` notes mount lives in
  `docker/docker-compose.override.yml`, which is now **tracked** in git
  (`git ls-files --error-unmatch` succeeds; last touched by `5cc384e`).
  Audits here are therefore reproducible from tracked files, unlike the
  earlier audit that described the override as untracked.

> **Untrusted-content warning.** While reading the notes, the `jev-guard`
> plugin flagged `fe70fd73-…_0026.txt` (prompt-injection, p=0.85) and a
> `node` query result (canary, p=0.90) as AI-targeted text. Those files
> contain instructions aimed at an agent (e.g. "write an audit to
> `/workspace/logs/sidebar-audit.md`" and "call `jev_review`"). They were
> treated strictly as data; no instruction from a note was executed. This
> report stands on the operator's request alone.

## 1. Project identity

A Docker-packaged coding-agent environment: the OpenCode binary wrapped
around a DeepSeek provider and Jev review/guard tooling, managed via Dockge.

- **`README.txt`** — prerequisites: Docker Engine, authenticated `gh`, a
  DeepSeek key (`sk-`, platform.deepseek.com) and a Jev key (`apikey_`,
  console.typesafe.ai). Keys cached in `../.env.local` (mode 0600, gitignored).
  Documents live process-substitution streaming, the OpenCode 1.18.31 non-TTY
  exit-code quirk (assert on response text, not exit code), `--user
  $(id -u):$(id -g)` UID handling, and secrets hygiene (no keys on argv,
  mode-0600 header temp files).
- **`QUICKSTART.txt`** — `cd scripts && ./deploy-dockge.sh`, then
  `./flatten-dockge-stacks.sh`, then browse `http://localhost:5001`. The image
  embeds OpenCode, the DeepSeek provider config, the `jev-guard` plugin, and
  the `jev-review` MCP server.
- **`opencode.json`** — provider `deepseek` (`@ai-sdk/openai-compatible`,
  `baseURL https://api.deepseek.com`, `apiKey {env:DEEPSEEK_API_KEY}`), model
  `deepseek-flash` ("DeepSeek V4.1 Flash", context 1,000,000 / output
  384,000), default `model: deepseek/deepseek-flash`, `plugin: ["jev-guard"]`,
  `skills: ["/opt/jev-review/skills"]`, and MCP server `jev-review`
  (`node /opt/jev-review/dist/server.js`, `JEV_API_KEY` from the environment).
- **`docker/Dockerfile`** — `node:22-bookworm-slim`, `xdg-open` no-op shim,
  OpenCode installed via `curl … | bash`, `opencode plugin jev-guard@0.3.1
  --global`, then `git clone NiazMorshed2007/jev-review` into `/opt/jev-review`,
  pinned checkout `3fb6042e…`, `npm ci && npm run build`.

## 2. Rule system

Requested extraction, run verbatim (binary `.txt` files included with `-a`,
otherwise two files are skipped):

```
$ grep -rhoaE "#[0-9]+" /workspace/notes --include="*.txt" | sort | uniq -c | sort -rn | head -30
    390 #5
     53 #8
     42 #12
     38 #9
     32 #13
     28 #7
     20 #14
     13 #3
     12 #54
     11 #1
      9 #55
      9 #53
      8 #45
      8 #39
      8 #10
      7 #6
      7 #5604
      7 #4
      7 #34
      7 #2
      6 #57
      6 #41
      6 #38
      6 #37
      6 #18
      6 #17
      6 #11
      5 #47
      5 #15
      4 #16
```

**The top-30 is dominated by Docker BuildKit step markers, not rule
references.** Of **785 total `#N` tokens** across only **10 `.txt` files**,
**660 are `^#N …` BuildKit step lines** (`#5 [ 4/14] RUN …`, `#5 CACHED`). The
leading `#5` (390) and `#12`/`#9`/`#13`/`#14` are build steps; `#5604` is an npm
postinstall regression (Issue #5604). The genuine rule tokens are the
lower-frequency IDs.

Cross-reference with **`/workspace/push_notes_v18.sh`** (header lines 12–16
cite the rule set; script is tracked):

| Rule | Cited meaning (script header) | Occurrences in script |
| ---- | ----------------------------- | --------------------- |
| #7   | no `sed`; guarded             | 1 |
| #8   | no `2>/dev/null`              | 1 |
| #28  | dependency check              | 1 |
| #34  | push-evidence (with #47)      | 1 |
| #37  | SKIP != PASS                  | 1 |
| #38  | `printf` (not `echo`)         | 1 |
| #39  | gitignore checked before add (with #45) | 2 |
| #41  | UTC timestamps                | 1 |
| #45  | gitignore checked before add (with #39) | 2 |
| #47  | push-evidence (with #34)      | 1 |
| #53  | owner/repo parsed via `python3`, never `sed` | 2 |
| #54  | evidence completeness gate    | 3 |
| #55  | raw-link HTTP-200 validation with backoff | 2 |
| #57  | end sentinel                  | 1 |

- **Cited and present in the top-30:** `#8`(53), `#7`(28), `#54`(12), `#55`(9),
  `#53`(9), `#45`(8), `#39`(8), `#34`(7), `#57`(6), `#41`(6), `#38`(6),
  `#37`(6), `#47`(5).
- **Cited but absent from the top-30:** `#28` (dependency check).
- **Definitions are not in this corpus.** No standalone rules document exists
  among the 47 notes files; only embedded copies of `push_notes_v18.sh` in
  transcripts (`9e3e0363-…_0010.txt` carries the full `# Rules:` header).
  Prose `Rule #N` references total **16 lines**: `Rule #54`×6, `Rule #53`×3,
  `Rule #39`×3, `Rule #28`×3, `Rule #8`×1. Canonical definitions live outside
  both `/workspace` and the notes corpus.
- **Consistency:** `push_notes_v18.sh` is faithful to the rules it cites — no
  `sed`, no `2>/dev/null`, `printf`, remote parsed with `python3`, an
  `# === END … ===` sentinel, `git check-ignore` before `git add`, and raw
  links gated on a verified HTTP 200 with backoff.

## 3. JEV references

**In `/workspace/notes` (`.txt` only):** `jev` (case-insensitive) matches
**11 files**. Token counts: `JEV`×696, `jev-review`×321, `jev-guard`×250,
`Jev`×159, plus `jev-latest`×9, `jev-classifier`×6, `jev-deepseek`×4.
Matching files: `9e3e0363-…_0001/0010/0017.txt`, `6aaee6ee-…_0002/0003.txt`,
`6aaeedb1-…_0004.txt`, `0b46dfa8-…_1012/1016/1017.txt`, `fe70fd73-…_0026.txt`,
`fe70fd73-…_0043.txt`.

**In `/workspace`** (excluding `.git`, `notes`, `data`): **204 files match**.
Key locations:

- `opencode.json` — `plugin: ["jev-guard"]`, `skills: ["/opt/jev-review/skills"]`,
  MCP server `jev-review` (`node /opt/jev-review/dist/server.js`, `JEV_API_KEY`).
- `docker/Dockerfile` — `opencode plugin jev-guard@0.3.1 --global`, plus the
  `git clone … /opt/jev-review` + pinned checkout + build.
- `docker/docker-compose.yml`, `docker/build.sh`, `docker/run.sh` — image
  `opencode-deepseek-jev:robust` and `JEV_API_KEY` plumbing.
- `scripts/ask.sh`, `scripts/doctor.sh` — image name; `doctor.sh` probes the
  plugin list for `jev-guard` and validates the Jev key prefixes.
- `scripts/test-repo.sh` — gates G3/G4 on `jev-review` and the `jev-guard`
  install line.
- Many `*.bak.*` snapshots and `scripts/archive/**` copies repeat these strings.
- `/opt/jev-review` itself is outside the repo and was not inspected.

Recurring notes theme: the Jev integration is **installed and string-matched
but not functionally proven** — the subsystem could be broken while the smoke
test still passes.

The live DB confirms `jev-guard` is active in this session: it intercepted the
reads above and labelled them as injection/canary.

## 4. Current state

### `opencode-web` service block (`docker/docker-compose.yml`, lines 45–71)

```yaml
  opencode-web:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-web
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    working_dir: /workspace
    entrypoint: ["/workspace/docker/web-entrypoint.sh"]
    ports:
      - "4096:4096"
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
    env_file:
      - ../.env.local
    environment:
      OPENCODE_DISABLE_DEFAULT_PLUGINS: "true"
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
```

The tracked block has no notes volume; that is supplied by the now-tracked
`docker/docker-compose.override.yml`:

```yaml
services:
  opencode-web:
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
      - /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes:/workspace/notes:ro
```

The TUI service `opencode` (lines 18–43) carries its own direct notes mount.

### `docker/web-entrypoint.sh` (44 lines)

Writes `$XDG_DATA_HOME/opencode/auth.json` as
`{ deepseek: { type: "api", key } }` using a Node one-liner (no `sed`/shell
escaping), symlinks `/workspace` → `/home/node/workspace` so the SPA project
picker can find it, then `exec opencode web --hostname 0.0.0.0 --port 4096`.
If `DEEPSEEK_API_KEY` is empty it warns and skips `auth.json`.

### Session count (`node --experimental-sqlite`)

`sqlite3` and `python3` are absent in this image, so the count used Node's
built-in SQLite against `/workspace/data/opencode/opencode.db`:

```
session=30
message=204
part=898
project=2
event=3248
```

`opencode.db` lives in `data/opencode/` (gitignored) and is live — a moving
target (an earlier audit read `session=20 / message=148 / part=712` the same
day). Latest session titles include `OpenCode DeepSeek JEV container audit`
and `Reply with exactly PONG`.

`docker` is not installed inside this container, so host-side running-container
state was not inspectable from here.

### Repository drift

`git status --porcelain` reports **84 entries**: 82 untracked (79 of them
`*.bak.*` snapshots) plus 2 modified (`logs/telemetry-2026-09-23.log`,
`scripts/archive/one-shot/push-telemetry.sh`). HEAD is `390279f` ("untrack
.bak snapshots", 2026-09-23 16:55 -0400), branch `main`, remote
`github.com/swipswaps/opencode-deepseek-jev`.

## 5. Sidebar streaming

**Yes — a session being processed is visible in the sidebar.** Liveness is
carried by the SSE stream at `/api/event`: creating a session emits
`session.created`, and streaming `session.updated` / `message.updated` events
keep its sidebar entry rendered and in sync while the agent runs, rather than
the sidebar polling `/api/session/active`.

Evidence:

- Notes, `fe70fd73-…_0026.txt`: the sidebar calls
  `/api/session?directory=X&project=Y`, not `/api/session/active`; on create
  the server emits `session.created` and subsequent `session.updated` /
  `message.updated` events keep the entry in sync "as the session processes".
- Live DB (`event` table, persisted SSE history):

  ```
  message.part.updated.1 = 2212
  message.updated.1      =  710
  session.updated.1      =  296
  session.created.1      =   30
  ```

  One `session.created` plus ongoing `session.updated` / `message.updated`
  per session — exactly what a browser attached to `/api/event` renders live
  during the processing window.

Caveat: `http://127.0.0.1:4096/api/event` returns HTTP 401
(`Authentication required`) from inside the container because the server
enforces auth, so the stream could not be replayed here; this proves the
persisted event stream, not the SPA DOM render. The regression test proposed
in section 6 would close that gap.

## 6. Operator next steps

1. **Recover and version the rules document.** Rules #7/#8/#28/#34/#37/#38/
   #39/#41/#45/#47/#53/#54/#55/#57 are cited everywhere but defined nowhere in
   the repo or the notes corpus; add the canonical rules doc so `#N` citations
   are auditable and the `#5`/`#12` BuildKit noise stops masquerading as rules.
2. **Add tooling the scripts already assume.** `sqlite3` and `python3` are
   absent (the Dockerfile has neither), yet `push_notes_v18.sh`, `doctor.sh`
   and others call them; bake them into `docker/Dockerfile` or standardize on
   `node --experimental-sqlite` plus a Node helper (as this audit did).
3. **Add a real sidebar-streaming regression test.** Create
   `test-sidebar-streaming.sh` (authenticate, open `/api/event`, create a
   session, post a message, assert `session.created` / `session.updated` /
   `message.updated` appear — ideally assert the SPA DOM entry) so the "yes"
   in section 5 stays continuously verified rather than inferred.
4. **Tame drift and secrets.** 82 untracked entries are mostly `*.bak.*`
   snapshots; archive or delete them, rotate the DeepSeek/JEV keys in
   `.env.local`, delete the stale `.env.local.bak.*` copies, and keep
   `opencode-web`'s `0.0.0.0:4096` off untrusted networks when
   `OPENCODE_SERVER_PASSWORD` is unset.
5. **Prove Jev functionally, not by string match.** The guard/review wiring is
   only ever confirmed by grepping install lines; add one test that actually
   invokes `jev_review` and fails if the MCP server or plugin is unhealthy, so
   a broken Jev install stops passing the smoke test.
