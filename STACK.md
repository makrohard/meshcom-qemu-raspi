# MeshCom QEMU stack — overview & run guide

Run the **real MeshCom firmware** under QEMU and exercise it end-to-end: web UI,
GPS (host gpsd or synthetic fixtures), and — with the LoRaHAM Pi-HAT — real 433 MHz
TX/RX against a physical T-Deck, via the bridge and daemon.

```
                      scripts/gps-relay.py
   u-blox → host gpsd ───────────────────────┐  (UART1 Unix socket, .run/)
                                              ▼
   T-Deck ⇄ 433 MHz ⇄ LoRaHAM daemon ⇄ meshcom-loraham-bridge ⇄ QEMU MeshCom ── web UI :18083
                       (real radio)     (loopback :7000, HMAC)   (extradio-gpsd)   net-console :12323
```

## Repos

| Component | Local path | Repo |
|---|---|---|
| QEMU overlay (this) | `meshcom-qemu-raspi` | https://github.com/makrohard/meshcom-qemu-raspi |
| MeshCom firmware (XR branch) | `MeshCom-Firmware` @ `feature/external-radio-tcp-draft` | https://github.com/makrohard/MeshCom-Firmware/tree/feature/external-radio-tcp-draft · upstream https://github.com/icssw-org/MeshCom-Firmware |
| Bridge | `meshcom-loraham-bridge` | https://github.com/makrohard/meshcom-loraham-bridge |
| LoRaHAM daemon (v111) | `loraham-daemon-hardening/loraham_daemon` | https://github.com/LoRaHAM/LoRaHAM_Daemon (branch `hardening/daemon-tests`, PR #8) |

Paths below assume the repos live under `~/src`. The overlay never modifies
the other repos; it builds the firmware in a disposable `.work/` tree.

## Prerequisites

- **Always:** PlatformIO Core (`pio`), the Espressif `qemu-system-xtensa`, `libslirp0`, `python3`.
- **For real RF only:** the LoRaHAM Pi-HAT (433 MHz), the built bridge (`meshcom-loraham-bridge/build/`), and the built daemon (`loraham_daemon`).
- **For real GPS only:** a u-blox on `/dev/ttyACM0` owned by host gpsd — see [docs/gpsd-host-setup.md](docs/gpsd-host-setup.md). Synthetic fixtures need none of this.

---

## A) Minimal: web UI + GPS, no RF

GPS-only target with a synthetic fix. No daemon, bridge, gpsd, or radio needed.

```bash
cd ~/src/meshcom-qemu-raspi
scripts/setup.sh --src ~/src/MeshCom-Firmware --ref feature/external-radio-tcp-draft
scripts/apply-overlay.sh
scripts/prepare-openeth.sh
scripts/build.sh --env qemu-headless-gpsd

# terminal 1 — feed a synthetic fix (fictional 48°N 12°E) FIRST: GPS init is one-shot,
# so NMEA must be flowing when the node boots; the relay waits for the socket.
python3 scripts/gps-relay.py --mode fixture \
        --fixture fixtures/gps/valid_fix.nmea --uart .run/gps-uart1.sock --rate 5 --loop

# terminal 2 — boot the node (creates .run/gps-uart1.sock)
scripts/run.sh --env qemu-headless-gpsd
```

Open **http://127.0.0.1:18083/** (net-console on `127.0.0.1:12323`). Stop with
`scripts/stop.sh`. The automated fixture suite (`scripts/test-gps.sh --env qemu-headless-gpsd`)
handles the relay/node ordering itself.

---

## B) Full stack: GPS + real 433 MHz RF (daemon + bridge + T-Deck)

Run each block in its own terminal; start them in this order.

```bash
# 1) LoRaHAM daemon v111 — owns the 433 MHz radio; DIRECT TX (MeshCom does its own CSMA)
cd ~/src/loraham-daemon-hardening/loraham_daemon
./loraham_daemon --radio 433 --tx-mode-433 direct -d          # logs: /tmp/lora_daemon.log
```

```bash
# 2) Shared HMAC secret (kept OUT of git) — used by the firmware build AND the bridge
printf '%s' "$(openssl rand -hex 16)" > /tmp/xr_pw
```

```bash
# 3) Build the GPS + external-radio firmware, bound to the bridge endpoint + secret
cd ~/src/meshcom-qemu-raspi
scripts/setup.sh --src ~/src/MeshCom-Firmware --ref feature/external-radio-tcp-draft
scripts/apply-overlay.sh
scripts/prepare-openeth.sh
XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD="$(cat /tmp/xr_pw)" \
  scripts/build.sh --env qemu-headless-extradio-gpsd
```

```bash
# 4) Bridge — loopback only, HMAC, real-radio backend (needs the daemon's sockets)
cd ~/src/meshcom-loraham-bridge
./build/meshcom-loraham-bridge --bind 127.0.0.1 --port 7000 \
        --backend loraham --password-file /tmp/xr_pw
```

```bash
# 5) GPS relay — start it BEFORE the node. The firmware's GPS init is one-shot, so
#    NMEA must already be flowing when the node boots; the relay waits for the UART
#    socket (created by run.sh) with backoff, so launching it first is fine. Pick ONE:
cd ~/src/meshcom-qemu-raspi
#  a) synthetic fix (no receiver):
python3 scripts/gps-relay.py --mode fixture \
        --fixture fixtures/gps/valid_fix.nmea --uart .run/gps-uart1.sock --rate 5 --loop
#  b) real u-blox (after docs/gpsd-host-setup.md assigns the device to gpsd):
# python3 scripts/gps-relay.py --mode gpsd --gpsd 127.0.0.1:2947 --uart .run/gps-uart1.sock
```

```bash
# 6) Boot the node (10.0.2.2 is QEMU's host route to the loopback bridge)
cd ~/src/meshcom-qemu-raspi
scripts/run.sh --env qemu-headless-extradio-gpsd
```

Open **http://127.0.0.1:18083/**. Expected: bridge logs `configured; radio ready`, the
guest gets a GPS fix (`src=[GPS]` in the UI), and messages flow to/from the T-Deck.

**The T-Deck must use the same radio channel** as the node, or they won't interoperate:
`433.175 MHz, BW 250 kHz, SF 11, CR 6, sync 0x2B, ≤20 dBm`.

### Bring the stack down

```bash
cd ~/src/meshcom-qemu-raspi && scripts/stop.sh   # node (+ removes the UART socket)
# stop the relay (Ctrl-C), bridge (Ctrl-C), then the daemon:
pkill -x loraham_daemon
rm -f /tmp/xr_pw                                            # discard the HMAC secret
scripts/clean.sh                                            # remove .work/ and .run/
```

## Changing settings

Change node settings over the **net-console**, not the web GUI. Connect to the
host-forwarded console and use `--` commands:

```bash
nc 127.0.0.1 12323          # or: socat - TCP:127.0.0.1:12323
--help                      # list all commands
--setcall OE1XYZ-7          # callsign (format-checked)
--txpower 14                # TX power in dBm (keep <= 20 for the daemon)
--pos                       # show position; --info shows the current config
```

Settings are stored in flash (NVS) and **survive restarts**; only an explicit
`scripts/build.sh` (which writes a fresh image) resets them to defaults.

> The web UI's **Save** does not round-trip under QEMU: the value usually *is* applied
> and saved server-side, but the page can't show it (the HTTP response is lost under
> emulation). Use the net-console, or reload the page to confirm a change.

## Notes

- **Daemon must run in DIRECT TX mode** (`--tx-mode-433 direct`). MeshCom does its own
  CSMA; the daemon's default MANAGED mode gates/drops the node's packets via CAD/LBT, so
  the T-Deck never hears them. (Runtime fix without restart: `SET TXMODE=DIRECT` to
  `/tmp/loraconf433.sock`.)
- **Start the GPS relay before the node** — the firmware's GPS init is one-shot, so NMEA
  must be flowing when it runs (the relay waits for the UART socket, so launch it first).
- **TX power is 20 dBm** (`overlay/variants/qemu-headless/configuration.h`): the daemon
  caps TX at 20 and rejects a higher CONFIGURE, and the firmware snapshots power once at
  XR connect (a runtime `--txpower` is not re-synced into XR).
- **gpsd stays loopback-only**; the relay only reads `127.0.0.1:2947` or a fixture and
  never touches `/dev/ttyACM0`. Fixtures are synthetic; never commit real coordinates.
- **Spectrum scan is not available under QEMU** — it sweeps RSSI off a local SX126x chip
  the emulated node doesn't have (and the external-radio path can't carry a chip-level
  scan). The web page shows a clear notice instead of erroring; use a physical T-Deck.
- The default `qemu-headless` and `qemu-headless-extradio` targets are unchanged by the
  GPS work; GPS code exists only in the `…-gpsd` targets.
