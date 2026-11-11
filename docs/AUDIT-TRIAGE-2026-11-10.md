# Repo audit and triage — 2026-11-10

Scope: `swipswaps/opencode-deepseek-jev` at `e3e8f10`, working tree clean.
This is a triage of **all** outstanding issues in both senses: unresolved work
and the excellent practices worth preserving. Evidence is from the repo's own
tools, run on 2026-11-10/11.

## 1. Audit snapshot

| Check | Result | Notes |
|---|---|---|
| `harness.sh --fast` | **3 passed / 0 failed** | lint 415/0, hygiene 106/0, patterns 6/0; dashboard skipped |
| `test-dashboard.sh` (full) | **161 pass / 0 fail** | run separately; CSP nonce, UI/PWA, full=1 |
| `security-posture.sh --offline` | **22 pass / 1 fail** | the 1 is the `../notes/` secret finding |
| `secret-scan.sh` | **4 findings** | all in `../notes/` (outside the repo); rotate + scrub |
| `doc-budget.sh` | **tier-1 36,145 / 35,000** | over by ~1,145; tier-2 44,756 (not budgeted) |
| `session-health.mjs` | **fixed this pass** | defaulted to `/workspace/...`; now repo-relative; 40 scanned, 2 running, 1 blank |
| `issue-solutions.py` | 8 JEV-key, 7 semantic-guard, 4 ripgrep-JSON, 3 path, 3 read-offset, 2 dismissed | mostly historical/tooling |
| `audit-tool-calls.py` | HITS (historical) | `echo` 3965, `rm -rf` 36, `cat`/`sed` etc.; no new blocks beyond the guard |
| `next-action.sh` | blockers: docs budget; external `proxmox-dual-plane-mesh#5`; task `T-c39910` | |
| `ssh-audit.sh` | SKIP | pip `ssh-audit` not installed |
| Container secret binds | **hidden** | `/workspace/.env.local` and `docker/litellm-db.env` → `/dev/null`; `docker/certs` → `empty-certs` |

## 2. Unresolved issues — triage

### P0 — security now

| ID | Issue | Evidence | Next |
|---|---|---|---|
| **NOTES-SEC-1** | 4 secret values in host notes | `secret-scan`: `../notes/key_issues.txt:89,94,99`, `../notes/6af239f3-…_0155.txt:654` | Rotate DeepSeek/JEV, then `./scripts/scrub-secrets.sh`; re-run `secret-scan.sh` until clean. Operator. |
| **SSH-CVE-1** | OpenSSH not upgraded | host is glibc + PAM + OpenSSH 10.0p2, so **not** the CVE-2026-123158 musl/no-PAM combination, but the CVE is exploited | `sudo dnf upgrade --refresh openssh-server openssh-clients`; verify `ssh -V`, `ldd sshd | grep musl`, `sshd -T | grep usepam`. Operator. |

### P1 — do this week / active measurement

| ID | Issue | Evidence | Next |
|---|---|---|---|
| **B43-1** | Does the BT/`btcoex=0`/BSSID-pin intervention actually stop the beacon loss? | `beacon-watch`: 24 h total **185**, **pre 184, post 1** (post event 20:54:42; intervention 18:20; post window ~2.5 h). Pre was clustered (59–61/h); post ~0.4/h vs ~9/h. Reduced, not eliminated. | Keep monitoring 24–48 h: `beacon-watch --hours 24 --intervention ~/.local/state/b43-tune.applied`. If post returns to the clustered pre rate, reject H1 → test a different 2.4 AP (`14ef1c9` ch6, `SpectrumSetup-00` ch1, phone hotspot); if H2 fails, H3/hardware → USB Wi-Fi/Ethernet. |
| **TUNNEL-1** | Lighthouse link flaps | external `swipswaps/proxmox-dual-plane-mesh#5`; task `T-c39910`; the flaps match the client/lighthouse WiFi loss | The b43/BT fix targets the underlying lighthouse link. Re-run `tunnel-link-probe.sh` after 24 h; post the recover.log/cadence evidence to #5; close `T-993fc4`/`T-c39910` when stable. External + agent. |
| **SESS-1** | 2 stale “running” sessions + 1 blank | `session-health`: `ses_e48c439d` running 274,518 s; `ses_e5980d1f` running 523,096 s; `ses_e7b12c86` blank 1,124,506 s | The DB is opencode-owned and read-only; do not edit. Close/ignore them in the UI, or restart the opencode server at a quiet moment. Operator. |
| **JEV-1** | JEV key rejected (8 historical) | `issue-solutions`; preflight requires `JEV_API_KEY` | Verify the key is current and visible to the MCP process; rotate only if still rejected. Operator. |

### P2 — hardening / cost / code

| ID | Issue | Evidence | Next |
|---|---|---|---|
| **EVAL-1** (`OPS-4` in OUTSTANDING) | `eval` / `bash -c` in `test-tools.sh` / `runbook.sh` | repo-owned inputs today | Replace with `execFile` argument arrays or a command allow-list. |
| **DOCKER-1** (`OPS-5`) | `/var/run/docker.sock` in Dockge helpers | loopback-published, still root-equivalent | Socket proxy or dedicated host; keep it local-admin tooling. |
| **KEY-1** (`OPS-6`) | Existing `authorized_keys` line may lack `restrict` | default is now `RESTRICT=1`, but an old line is skipped | Remove the old line and re-run `authorize-container-key.sh`. |
| **ENV-1** (`OPS-7`) | Provider keys in container env | the app needs a key | Route via LiteLLM virtual keys; keep `.env.local` masked (done). |
| **AGENT-1** (`V6`) | `bash "*": "allow"` behind a fail-open guard | prompt-injection residual; guard is not a sandbox | Narrow to `ask`/denies for destructive patterns; keep untrusted content out of instruction position. |
| **COST-1** | non-flash share 16.2% ($4.10) | `cost-bottlenecks`: `deepseek-v4-pro` 2 calls $2.04 (deny-listed), muse-spark | historical/off-policy; keep the current `opencode-go/deepseek-v4.1-flash`; avoid `v4-pro`. |
| **PIN-1** (`OPS-10`) | floating images/actions | supply-chain | Pin remaining images by digest and Actions by SHA. |
| **SH-1** | `session-health.mjs` default DB path | **fixed this pass** (repo-relative) | add a regression check; keep `--self-test`. |
| **IB-1** | `issue-bridge.py` not executable | **fixed** (mode 755) | run with `--repo/--number`; the next-action already reports #5. |

### P3 — docs/tooling/features

| ID | Issue | Evidence | Next |
|---|---|---|---|
| **DOC-1** (`OPS-9`) | tier-1 docs over by ~1,145 | `doc-budget` | Consolidate `HANDOFF.md`/`RULES.md`/`TODO.md`; move old Done entries to `docs/todo-archive-2026.md`. |
| **TOOL-1** | `docs/plans/TOOL-AUDIT.md` stale | catalog says 108; current tools.json 159; references `rotate-ssh-ca.sh` (absent) | Update to `host-cert-sign.sh`; refresh the census. |
| **SSH-AUDIT-1** | `ssh-audit.sh` skips | pip `ssh-audit` missing | `pip install ssh-audit` or document the requirement. |
| **UPSTREAM-1** | opencode pagination/unbounded GET | `docs/upstream-opencode-issues.md` | external/upstream; keep the local health/dashboard route-around. |
| **FEAT-1..4** | G4 LiteLLM `max_budget`; G5 Laya/embeddings; G6 `doctor.sh --full`; G7 Blockly/n8n | TODO queue | not blocking; schedule when needed. |
| **HIST-1** | historical blacklist hits | `audit-tool-calls`: `echo` 3965, `rm -rf` 36 | the guard now blocks them; no retro-edit of the DB. |
| **TOOL-2** | ripgrep JSON >64 KB; FileSystem.access path; read offset; question dismissed | `issue-solutions` | tooling/user-error class; no product change unless they recur. |
| **GATE-1** | full-harness blind-timeout risk | TODO `OPS-4` (a **different** OPS-4 — ID collision) | Use `gate-watch.sh`; dashboard 161/0 now proves the full gate. Rename to `GATE-1`. |

## 3. Outstanding in the other sense — preserve

- **Evidence before verdicts.** `peer-health`, `beacon-watch`, `session-health`,
  `issue-solutions`, `logs.sh`, and the ledger all produce measurements, not
  guesses.
- **Reversible and self-recovering.** `b43-tune.sh`, `wifi-durable-fix.sh`,
  `bluetooth-off.sh`, `hotspot-reconnect.sh`, `install-global-guard.sh`,
  `host-cert-sign.sh` all have `--rollback`, auto-recovery, and self-tests.
- **Security invariants.** Dashboard Basic auth + per-response CSP nonce +
  opt-in CORS; semantic classifier opt-in with secret redaction; X11 untrusted
  default; `auth.json` 0600; `harvest.py` blocks `file://`/private/metadata;
  the guard loads (resolved symlink), matches evasions, and self-tests.
- **A real delivery gate.** lint 415, hygiene 106, patterns 6, dashboard 161,
  security 22/1; doc budget and secret scan are advisory but visible.
- **Hardware honesty.** `hardware-profiles.json` marks `14e4:4331` as
  `known_bad_wl`, refuses `wl`, and recommends the supported USB path.
- **Docs with thesis, evidence, and rollback.** `docs/BT-COEXISTENCE-2026-11-10.md`
  and `docs/SECURITY-AUDIT-2026-11-10.md` are the model for future audits.

## 4. Contradictions resolved by this triage

- **`SEC-3` is closed.** The running web container has
  `/workspace/.env.local` and `docker/litellm-db.env` → `/dev/null`, and
  `docker/certs` → `empty-certs`. No recreate is pending; the remaining
  security fail is the host `../notes/` secret.
- **`HOTSPOT-1` is done except measurement.** Self-tests, cause proof, popup UX,
  peer-health, and the b43/BT intervention are in place; the open part is
  B43-1 (24–48 h beacon measurement).
- **ID collision:** TODO `OPS-4` = gate observability; OUTSTANDING `OPS-4` =
  `eval`/`bash -c`. Rename the TODO item `GATE-1`.
- **`OPS-2`/CSP are applied on this host.** Dashboard returns 401 without auth
  and 200 with it; the CSP nonce test passes.
- **`docs/plans/TOOL-AUDIT.md`** still names `rotate-ssh-ca.sh`; the live
  signer is `scripts/host-cert-sign.sh` (the CA key stays on the host).

## 5. Top 10 actions (ranked)

1. Rotate the 4 `../notes/` secrets and scrub (**P0**).
2. Patch OpenSSH (**P0/P1**).
3. Let B43-1 run 24–48 h; if post events return, test another 2.4 AP, then a
   USB Wi-Fi/Ethernet adapter.
4. Verify/rotate the JEV key if still rejected.
5. Close/ignore `SESS-1` stale sessions (DB is read-only).
6. Update TODO: close `SEC-3`, finish `HOTSPOT-1` (measurement), rename
   `OPS-4`→`GATE-1`; link this doc.
7. Consolidate tier-1 docs (`DOC-1`).
8. `KEY-1`, `DOCKER-1`, `ENV-1`, `PIN-1` hardening.
9. `EVAL-1`/`AGENT-1` shell authority cleanup.
10. Post the tunnel evidence to `proxmox-dual-plane-mesh#5` when the lighthouse
    is stable; close `T-c39910`/`T-993fc4`.

## 6. Commands used (reproducible)

```bash
./scripts/harness.sh --fast          # 3/0
./scripts/test-dashboard.sh          # 161/0
./scripts/security-posture.sh --offline
./scripts/secret-scan.sh
./scripts/doc-budget.sh
./scripts/issue-solutions.py
./scripts/audit-tool-calls.py
node scripts/session-health.mjs      # fixed default DB path
./scripts/beacon-watch.sh --hours 24 --intervention ~/.local/state/b43-tune.applied
./scripts/next-action.sh
```

*Evidence over assumptions; every change reversible; every alert bounded and
carrying its reason.*
