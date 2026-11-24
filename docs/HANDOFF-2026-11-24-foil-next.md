# Handoff — foil.cfd autonomous continuation (2026-11-24)

Purpose: a fresh session finishes the **foil.cfd host closure** without
re-deriving the history. Read this file, then the two prior foil handoffs:
[`HANDOFF-2026-11-22-foil-cfd.md`](HANDOFF-2026-11-22-foil-cfd.md) and
[`HANDOFF-2026-11-23-foil-tailnet.md`](HANDOFF-2026-11-23-foil-tailnet.md).
Do not fork or continue the source session.

Status: JEF (this repository) is pushed and level with `origin/main`. foil.cfd is
live as a static site; its backend is host-only and healthy; the same-origin app
is built and serving on the tailnet IP; the follow-up is uncommitted in the foil
checkout. Tailscale Serve is blocked because HTTPS Certificates are disabled for
the tailnet (a console setting, not a code defect), so the verified path is the
tailnet-IP fallback over WireGuard.
The remaining acceptance tests are: enable Serve and re-run for HTTPS, run the
live tailnet e2e, gate and push the foil follow-up, then narrow the Access
Control List (ACL).

## Hard boundary: where you can act

- The container **cannot read** `/home/owner`, has **no Docker socket**, and
  has **no Secure Shell (SSH) client**. It also has **no GitHub credential**, so
  it cannot push.
- `/workspace` is a bind mount of the host repository
  `/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo`. Commits
  made in the container are already in the host tree.
- The foil checkout is **host-only**:
  `/home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site`.
- The host-ops skill (same files as the container copy at
  `/home/node/.config/opencode/skills/agent-host-ops`) is the execution layer:
  `$HOME/.config/opencode/skills/agent-host-ops`.

So the autonomous contract is: do every container-side check yourself, then
either (a) run the host block if the operator has given you host execution, or
(b) print exactly one host block and stop. Never invent a host result.

## Evidence snapshot (2026-11-24)

| Layer | State | Evidence |
|---|---|---|
| foil.cfd public site | static, live | GitHub Pages; last recorded green CI run `45164015498` (build, e2e, deploy) |
| backend | healthy at the last host check (2026-11-23) | `solver_available=true`; `scripts/test_cfd_tools.sh` 16 pass / 0 fail; `/api/health` 200; `/api/jobs/default/surface.vtp` 200 |
| Private Network Access (PNA) | fixed | `OPTIONS /api/health` returns `Access-Control-Allow-Private-Network: true` |
| stale chunks | fixed | `vite:preloadError` plus `unhandledrejection` reload once, cache-busted |
| exposure | loopback plus Tailscale IPv4 | `127.0.0.1:8002` and `100.119.125.16:8002`; Funnel capability revoked |
| Tailscale Serve | blocked: HTTPS Certificates disabled | CLI node link returned `404 node not found`; enable HTTPS in the admin console DNS page |
| tailnet-IP fallback | verified 2026-11-24 from two devices | `/api/health` 200 with `solver_available=true` on `http://100.119.125.16:8002` from `ws24` and from client `100.70.43.78`; app served on `http://100.119.125.16:4174/` |
| ACL | allow-all | `grants` still permits tailnet-to-tailnet on any port |
| CI e2e | not a hard gate | branch protection allows admin bypass; pushes printed "Bypassed rule violations" |
| foil follow-up | uncommitted | `src/hooks/useBackendProbe.ts`, `src/hydro-main.tsx`, `src/sections/HydroLab.tsx`, `tests/e2e/tailnet.spec.ts` |

The container-side JEF gates that were green at handoff: `lint` 453 pass / 0
fail; `test-hygiene` 119 pass / 0 fail / 3 skip; `test-patterns` 6 pass / 0
fail; `guard-health --check` PASS; doc budget within 35000 tier-1 tokens.
`check-placeholders` remains red on historical assistant text; do not advance
its cursor. The uppercase `PASS` and `FAIL` strings below are literal verdict
labels printed by the scripts, not acronyms.

## Decision rule

Finish the unblocked host acceptance test that closes an open claim before
adding surface. The losing option is to start a new foil feature now: three
acceptance tests (Serve, live tailnet e2e, follow-up push) would remain
unproven, and a new failure would be ambiguous between the old and new layers.

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

## Step 1 — push JEF (host, one command)

The JEF commit is already in the host tree. Run this on `ws24`
(192.168.4.24), not on the client `100.70.43.78`: the client has no copy of the
skill and fails with `No such file or directory`.

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

## Step 2 — close the foil tailnet exposure (host)

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

Human step for TLS (verified against the Tailscale HTTPS documentation):

1. Open the DNS page of the Tailscale admin console:
   `https://console.tailscale.com/admin/dns`
2. Enable MagicDNS if it is not already on.
3. Under **HTTPS Certificates**, select **Enable HTTPS** and acknowledge that
   machine names and the tailnet DNS name are published in the Certificate
   Transparency ledger.
4. On the host run `sudo tailscale up` (or restart `tailscaled`), then re-run
   the apply script.

TLS acceptance: `tailscale serve status` shows the 443 mapping and
`https://ws24.taile17668.ts.net/api/health` returns 200. Until then the
tailnet-IP fallback is the verified path, and the Step 3 e2e can run now against
`http://100.119.125.16:4174/`.

The `https://rolldown.rs/reference/InputOptions.checks#bundlertimings` URL in
the build output is the bundler's chunk-size hint, not an action item.

## Step 3 — live tailnet e2e (host)

Run in the foil checkout after step 2. The spec fails closed: with
`TAILNET_APP_URL` unset it reports two skips, which is not a pass.

```bash
cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
TSIP="$(tailscale ip -4 | awk 'NR==1{print $1}')"
TAILNET_APP_URL="http://$TSIP:4174/" npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome
```

Accept: **2 passed, 0 skipped**, "Backend online" with no Connect click, and
`/api/health` answered on the page origin. A skip is a failure for this step.

## Step 4 — gate and push the foil follow-up (host)

The follow-up is already written but uncommitted:

- `src/hooks/useBackendProbe.ts` (private and tailnet pages probe the page origin
  first; the loopback permission gate applies to public pages only)
- `src/hydro-main.tsx` (small entry that renders the existing `HydroApp`)
- `src/sections/HydroLab.tsx` (deterministic particle helper reused)
- `tests/e2e/tailnet.spec.ts` (opt-in, gated by `TAILNET_APP_URL`)

Gate it in the checkout:

```bash
cd /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site
npm run lint
npm run typecheck
npm run build
```

Accept: all three exit 0; `oxlint` reports no errors. Then commit on pass and
push:

```bash
git -C /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site add src/hooks/useBackendProbe.ts src/hydro-main.tsx src/sections/HydroLab.tsx tests/e2e/tailnet.spec.ts
git -C /home/owner/Documents/6af8cd4d-b390-83ea-80a1-abdf7f0df839/foil-cfd-site commit -m "frontend: same-origin tailnet auto-connect + gated tailnet e2e"
bash "$HOME/.config/opencode/skills/agent-host-ops/push-all.sh"
```

Accept: `PASS: foil pushed`; the CI run for the new commit has `build`, `e2e`,
and `deploy` green:

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

1. **ACL narrowing.** In the Tailscale admin console, replace the allow-all
   `grants` entry with tag and port scope for `ws24` and the client. This is
   admin-console work, not reachable from either repo. Do not lock yourself out:
   keep one verified device session open while applying.
2. **e2e as a hard gate.** Either remove the admin bypass on `main` or require
   changes to land through a pull request. This is a repository policy decision,
   not a code defect.
3. **Placeholder cursor.** Review the four historical part IDs from the JEF scan
   and either accept them or baseline them explicitly. Never run `--advance` to
   make a red gate green.

## Do not

- Do not run the container copy of the host-ops skill against the foil path; the
  foil repo is host-only.
- Do not commit or push foil with a failing `npm run build`, and do not report a
  skipped tailnet spec as a pass.
- Do not expose the backend publicly: Funnel stays revoked; Serve is
  tailnet-only.
- Do not emit ellipses or angle-bracket tokens in any command you offer. Resolve
  the Tailscale DNS Name or Tailscale IPv4 address inline.
- Do not advance the placeholder cursor or weaken a gate to get a green line.
