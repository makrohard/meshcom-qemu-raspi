# Host gpsd setup for the QEMU virtual GPS (manual)

These are **manual** host steps for the production (`--mode gpsd`) GPS path. The overlay
**never** changes host-global configuration automatically — you run these yourself and
can undo them. The QEMU guest never touches the receiver; **gpsd alone owns
`/dev/ttyACM0`**, and `scripts/gps-relay.py` reads NMEA only from local gpsd
(`127.0.0.1:2947`) and writes it into the guest's virtual UART1.

> Privacy: never paste live latitude/longitude/altitude into commits, issues, logs, or
> screenshots. The verification commands below are chosen to show fix **quality** (mode,
> satellites, HDOP) without coordinates.

## Detected environment (this host, read-only inspection)

| Item | Value |
|------|-------|
| OS | Debian GNU/Linux 13 (trixie), `aarch64` (Raspberry Pi) |
| gpsd | 3.25 |
| gpspipe / `gpsd-clients` | **not installed** (the relay does not need it) |
| `gpsd.socket` | active, **loopback only**: `127.0.0.1:2947`, `[::1]:2947`, `/run/gpsd.sock` (0600) |
| `gpsd.service` | `disabled` (socket-activated on first client) |
| `/etc/default/gpsd` | `DEVICES=""`, `GPSD_OPTIONS=""`, `USBAUTO="true"` |
| Receiver | `/dev/ttyACM0`, `crw-rw---- root dialout` |

gpsd is installed and loopback-only already, but **no device is assigned** yet
(`DEVICES=""`). The steps below assign the receiver and verify it, without exposing gpsd
to the network.

## 1. Give gpsd the receiver

The relay speaks gpsd's JSON protocol directly, so **`gpsd-clients`/`gpspipe` are not
required**. Pick one option:

**A. Ephemeral (no reboot persistence) — recommended for a test session**
```bash
sudo gpsdctl add /dev/ttyACM0
```
This hands the device to the running (socket-activated) gpsd. Undo with `gpsdctl remove`.

**B. Persistent (survives reboot)**
Edit `/etc/default/gpsd` and set only:
```
DEVICES="/dev/ttyACM0"
GPSD_OPTIONS=""
USBAUTO="true"
```
Then restart the socket + service:
```bash
sudo systemctl restart gpsd.socket gpsd.service
```

Either way, **do not add `-G`** and **do not** add a `0.0.0.0`/`[::]` listener — gpsd must
stay loopback-only (see §3).

## 2. Confirm the relay's NMEA source works

`scripts/gps-relay.py --mode gpsd` sends `?WATCH={"enable":true,"nmea":true};` to gpsd and
forwards the `$GP…` lines gpsd emits. Confirm those lines flow (Ctrl-C to stop):
```bash
python3 - <<'PY'
import socket
s=socket.create_connection(("127.0.0.1",2947),timeout=5)
s.sendall(b'?WATCH={"enable":true,"nmea":true};\n')
import sys,time; t=time.time()
while time.time()-t<5:
    d=s.recv(4096).decode("ascii","ignore")
    for ln in d.splitlines():
        if ln.startswith("$"):           # NMEA sentence type only — NOT the payload
            print("NMEA:", ln.split(",",1)[0]); sys.stdout.flush()
PY
```
Seeing `NMEA: $GPRMC` / `$GPGGA` lines confirms gpsd emits line-oriented NMEA suitable for
the relay. (This prints only the sentence **type**, never coordinates.)

If gpsd emits binary UBX instead of NMEA, the relay aborts by design — see Troubleshooting.

## 3. Verify gpsd stays loopback-only
```bash
ss -lntH 'sport = :2947'        # expect ONLY 127.0.0.1:2947 and [::1]:2947
grep GPSD_OPTIONS /etc/default/gpsd   # must NOT contain -G
```
If you ever see `0.0.0.0:2947` or `[::]:2947`, gpsd is exposed to the LAN — revert it.

## 4. Verify a fix WITHOUT exposing coordinates
```bash
gpsmon -n            # or: cgps -s
```
Read only the **mode** (no-fix / 2D / 3D), **satellites used**, and **HDOP**. Do **not**
record the latitude/longitude/altitude fields. Quit with `q`.

A quality-only one-liner (mode + sats, no position):
```bash
python3 - <<'PY'
import socket,json,time
s=socket.create_connection(("127.0.0.1",2947),timeout=5)
s.sendall(b'?WATCH={"enable":true,"json":true};\n')
t=time.time()
while time.time()-t<6:
    for ln in s.recv(4096).decode("ascii","ignore").splitlines():
        try: o=json.loads(ln)
        except ValueError: continue
        if o.get("class")=="TPV": print("fix mode:", o.get("mode"))   # 1=no fix,2=2D,3=3D
        if o.get("class")=="SKY": print("sats used:", o.get("uSat"))
PY
```

## 5. Run the relay against gpsd
Start the QEMU GPS target, then start the relay **promptly** (it waits for the socket with
backoff, so you can even launch it right after `run.sh`):
```bash
scripts/run.sh --env qemu-headless-gpsd &     # creates .run/gps-uart1.sock
python3 scripts/gps-relay.py --mode gpsd --gpsd 127.0.0.1:2947 \
        --uart .run/gps-uart1.sock
```
The relay connects to gpsd and to the guest UART1 socket, forwards checksum-valid NMEA,
and reconnects if either restarts. It never logs coordinates.

> Timing note: the firmware's GPS init is one-shot — it marks the GPS "detected" only if
> NMEA is already arriving on UART1 when it runs (early in boot). gpsd streams NMEA
> continuously once a device is attached (even before a fix), so starting the relay
> promptly ensures data is flowing in time. If you start the relay much later and GPS
> stays inactive, restart the guest with the relay already running.

## 6. Undo / disable
```bash
sudo gpsdctl remove /dev/ttyACM0           # if added with option A
# or, if you edited /etc/default/gpsd (option B): restore DEVICES="" then:
sudo systemctl restart gpsd.socket gpsd.service
sudo systemctl stop gpsd.service           # leave gpsd.socket at the system default
sudo lsof /dev/ttyACM0                      # expect empty: device released
```
`gpsd.socket` is the Debian default and can be left enabled; it only opens the device when
a client connects and a device is assigned.

## Troubleshooting

- **No fix (mode stays 1):** cold start / poor sky view / antenna. This is normal and
  exercises the relay's no-fix path — the relay forwards it verbatim and never invents a
  position. Give the receiver a clear view and a few minutes.
- **Binary-only output (UBX), no `$GP…` lines:** the receiver is in binary mode. The relay
  aborts on binary by design (it never relays UBX/garbled data to the guest). Configure the
  receiver/gpsd for NMEA, or use a receiver already emitting NMEA. (`gpsd` usually presents
  NMEA via the `nmea` WATCH regardless of the on-wire protocol; if not, check the device.)
- **Permission denied on `/dev/ttyACM0`:** the device is `root:dialout`. gpsd (run via
  systemd) has access; a normal user querying gpsd over `127.0.0.1:2947` needs **no** device
  permission. If you run gpsd manually, add your user to `dialout` and re-login.
- **Relay can't connect to the UART socket:** ensure `scripts/run.sh --env …-gpsd` is
  running and `.run/gps-uart1.sock` exists (it is created by QEMU as a server socket, mode
  0600). The relay retries with backoff until it appears.
- **gpsd socket questions:** `systemctl status gpsd.socket`; `/run/gpsd.sock` is `0600` and
  loopback TCP is `127.0.0.1:2947` / `[::1]:2947` only.
