# Bluetooth coexistence and the b43 beacon-loss hypothesis — 2026-11-10

## Abstract

The BCM4331 client (`fedora`, `10.100.0.1`) runs the reverse-engineered `b43`
driver in **2.4 GHz only** mode and exhibits intermittent
`CTRL-EVENT-BEACON-LOSS`. Bluetooth is not used on either `fedora` or `ws24`,
yet **both Bluetooth radios were still powered** (`hci0`, `Soft blocked: no`)
while `bluetooth.service` was disabled/masked. Because `b43 btcoex=1` and
`iwlwifi bt_coex_active=Y` still coordinate with a live Bluetooth radio, the
primary hypothesis is that Bluetooth coexistence is one trigger of the beacon
loss. This document states the hypothesis, the evidence, the intervention, the
measurement plan, the rollback, and the falsification rule. It is deliberately
reversible: every change has a one-command undo.

## 1. Observations (what is established)

| Observation | Evidence |
|---|---|
| Client radio is BCM4331 | `lspci -nn` → `02:00.0 … [14e4:4331]`; `b43-phy0: Broadcom 4331` |
| Client is 2.4 GHz-only | `b43-phy0 warning: 5 GHz band is unsupported on this PHY`; `iw` ch11, 20 MHz, no HT |
| Old proprietary firmware | `b43-phy0: Loading firmware version 666.2 (2011-02-23)` |
| Beacon loss is intermittent | current boot 0; earlier 6 h windows showed 32–358 `BEACON-LOSS`; `iw station dump` `beacon loss: 0` at the sampled instant |
| Client signal is strong | `signal: -35…-39 dBm`, `beacon signal avg: -34 dBm` |
| Server is stable | `ws24` iwlwifi, 5 GHz ch44, 0 beacon loss |
| Bluetooth is not used | user state; `bluetooth.service` inactive/disabled (`ws24`) and masked (`fedora`) |
| **Bluetooth radio is still powered** | `rfkill list bluetooth` → `Soft blocked: no`, `Hard blocked: no` on both |
| b43 coexistence is on | `/sys/module/b43/parameters/btcoex=1`; `qos=0`; `nohwcrypt=1` |
| `wl` is not viable | loads `wlp2s0` but never associates; kernel warns unmaintained/incompatible with security mitigations; guard rolled back |
| `144caec` is the same router | BSSIDs `24:F3:E3:52:1A:03/04` (2.4 ch11 + 5 ch44) vs `belkin2` `…1A:06/07` — a second SSID on the same Belkin AP, not a host |

## 2. Hypotheses

- **H1 (primary): Bluetooth coexistence.** `b43` shares the BCM4331 radio/
  antenna with Bluetooth. With `btcoex=1` and a powered BT radio, the driver
  may leave the channel / miss beacons during coexistence arbitration.
- **H2: the Belkin 2.4 GHz radio.** Both `belkin2` and `144caec` 2.4 are on the
  same router radio (ch11); the 5 GHz radios are stable on the server.
- **H3: b43 firmware/driver.** Firmware 666.2 (2011) is old; b43 is
  reverse-engineered; beacon-loss recovery may be incomplete.
- **H4: external 2.4 GHz interference.** Neighbouring APs (`14ef1c9` ch6,
  `SpectrumSetup-00` ch1) are on other channels; `144caec` is the same AP, so
  it is not an independent interferer.

H1 is the cheapest to falsify and the only one fully under our control without
new hardware. H2/H3 remain the fallback explanations if H1 fails.

## 3. Intervention (IV)

Each component targets one mechanism; all are reversible.

1. **Power off the Bluetooth radio** on both machines
   (`rfkill block bluetooth`) and keep it off with
   `bluetooth-off.service` (`ExecStart=rfkill block bluetooth`,
   `WantedBy=multi-user.target`). Why: the service being off does not power the
   radio; `btcoex` still sees `hci0`.
2. **`options b43 btcoex=0`** in `/etc/modprobe.d/99-b43-tune.conf`. Why:
   removes the coexistence algorithm itself, independent of radio state.
3. **Pin `belkin2` to the 2.4 GHz BSSID** (`802-11-wireless.bssid=24:F3:E3:52:1A:06`)
   and `band bg`. Why: removes roaming/scanning churn between the four BSSIDs
   (including the 5 GHz ones the client cannot use).
4. **Powersave off** (`802-11-wireless.powersave=2`). Why: already off, kept
   for consistency.

The live reload path snapshots the previous `btcoex` value and restores it if
Wi-Fi does not return within `B43TUNE_UP_SEC` (40 s).

## 4. Design and execution

- Scripts: `scripts/bluetooth-off.sh` (radio + persistence),
  `scripts/b43-tune.sh` (driver/connection), both self-tested and gated in
  `test-hygiene.sh`.
- Execution is **detached** (`setsid nohup`) because the b43 reload drops Wi-Fi
  for a few seconds; the script must survive the SSH/agent disconnect.
- A/B context: `scripts/wifi-ab-benchmark.sh` measured Bluetooth on/off on the
  client before the intervention. A 20 s screen was **inconclusive** (beacon
  loss 0 in all phases; ping loss drifted 5→10→15 % with no BT correlation).
  The intervention is therefore a **long-window** test, not a claim from the
  short A/B.

### Applied status

| Machine | Bluetooth radio | b43 | Connection |
|---|---|---|---|
| `fedora` `.1` | **blocked** (`Soft blocked: yes`), unit installed | `btcoex=0` | pinned `belkin2` `…1A:06`, band `bg`, powersave off, connected |
| `ws24` `.24` | service inactive/disabled; **radio still powered** | iwlwifi `bt_coex_active=Y` | stable 5 GHz; needs one `sudo rfkill block bluetooth` (no passwordless sudo) |

## 5. Measured split (2026-11-10 21:00)

`beacon-watch.sh --hours 24 --intervention ~/.local/state/b43-tune.applied`:

| Window | Count |
|---|---|
| Total 24 h | **185** |
| Before intervention (pre) | **184** |
| After intervention (post) | **1** |
| Last pre event | 16:04:47 |
| First post event | 20:54:42 |
| Current boot (from 17:08:25) | 0 |
| Intervention | 18:20:14 |

Per-hour pre-intervention counts: 07:00 = 28, 10:00 = 61, 12:00 = 23,
13:00 = 7, 15:00 = 1, 16:00 = 1.

**Interpretation:** 184 events are pre-intervention and **1** is
post-intervention (20:54:42). The pre baseline was clustered (59 in one hour,
61 in another), so the raw 24 h total is not a rate; the post window is ~2.5 h
with one event (~0.4/h), versus ~9/h across the pre window. That is a large
reduction but **not elimination**, and the sample is still short. This is
consistent with H1 but **not proof**. Continue the 24–48 h measurement with
`beacon-watch.sh` (same applied timestamp). If the post rate stays near zero,
H1 is supported; if it returns to the clustered pre rate, reject H1 and test
H2 (different 2.4 GHz AP), then H3/hardware.

## 5. Measurement plan (estimands)

- **Primary:** count of `CTRL-EVENT-BEACON-LOSS` in `wpa_supplicant` per 24 h
  (`journalctl -u wpa_supplicant -b -g BEACON-LOSS`), compared with the prior
  24 h baseline (32 in the sampled 6 h window, 358 in the worst 24 h window).
- **Secondary:** `iw dev … station dump` `beacon loss`, `tx failed`,
  `rx drop misc`, association uptime, ping loss/avg to `192.168.4.24`.
- **Window:** at least 24 h, ideally 48 h, because the event is intermittent.
- **Decision rule:** if `BEACON-LOSS` remains materially above baseline with BT
  radio off + `btcoex=0` for 24–48 h, **reject H1**; then test H2 by moving the
  client to a different 2.4 GHz AP (`14ef1c9`/`SpectrumSetup-00`/phone hotspot).
  If H2 is rejected too, H3 (b43 firmware/driver) stands, and the durable path
  is a USB Wi-Fi adapter with an in-kernel driver or USB/Thunderbolt Ethernet.

## 6. Threats to validity

- **Intermittency / sample size:** a 20 s or 1 h window can miss the event.
- **AP-side drift:** the Belkin 2.4 radio or neighbours can change; the A2
  control phase in the benchmark exists for this reason.
- **Confounding by the reload:** the b43 reload itself resets counters; measure
  after association stabilises.
- **Radio state:** `rfkill` soft block can be overridden by a reboot unless the
  `bluetooth-off.service` unit is enabled (it is).
- **Different hardware:** results for BCM4331/b43 do not generalise to `wl` or
  other adapters.

## 7. Rollback (one command each)

```bash
# client .1
sudo /tmp/bluetooth-off.sh --rollback          # unblock BT radio + remove unit
sudo /tmp/b43-tune.sh --rollback               # remove btcoex=0 + clear BSSID pin + reload
# server .24 (with your password)
sudo bash scripts/bluetooth-off.sh --rollback
```

## 8. References (local evidence)

- `scripts/hardware-profiles.json` — `14e4:4331` profile (`known_bad_wl=yes`).
- `scripts/wifi-link-forensics.sh --json` — hardware/firmware/btcoex/qos/nohwcrypt/BT state + beacon counts.
- `scripts/wifi-ab-benchmark.sh` — BT on/off A/B/A.
- `scripts/bluetooth-off.sh`, `scripts/b43-tune.sh` — this intervention.
- `scripts/hotspot-reconnect.sh` — `wall` opt-in, keep-open notifications,
  `--offer-durable`, `--notify-remote`.
- `docs/OUTSTANDING-ISSUES-2026-11-10.md` — NET-8/9/10/11 history.

*All changes are reversible. If b43+BT-off does not reduce beacon loss over
24–48 h, stop tuning and move to a supported USB Wi-Fi/Ethernet adapter.*

## 9. Follow-up 2026-11-11 11:22 EST — H1 rejected

Rolling 24 h window (`ssh owner@10.100.0.1 'bash /tmp/beacon-watch.sh --hours 24
--intervention ~/.local/state/b43-tune.applied --json --write'`):

| window | count |
|---|---|
| total | **227** |
| pre (before 18:20:14) | **32** |
| post (17 h) | **195** |

The post window was not quiet: 20:00=1, 21:00=4, 23:00=7, 04:00=1, 06:00=10,
07:00=2, 09:00=30, **10:00=127**, 11:00=13 (partial). Post ≈ 11.5/h, at or
above the clustered pre rate; the 10:00 spike is a clear regression. **H1
(Bluetooth off + `btcoex=0` + BSSID pin) is rejected.** Next: **H2** — test a
different 2.4 GHz AP (`14ef1c9` ch6, `SpectrumSetup-00` ch1, phone hotspot);
if H2 fails, **H3/hardware** (USB Wi-Fi or Ethernet). Do not retry `wl`.

The 18:20-local 24 h-post gate is still due; this 17 h-post sample is already
decisive.
