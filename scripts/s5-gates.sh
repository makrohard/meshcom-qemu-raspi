#!/usr/bin/env bash
#
# s5-gates.sh OUTDIR — PROTOTYPE gate run, all in the foreground: the bridge (fake backend), the GPS
# relay (fixture), the node; probe web, net console and the XR link; stop everything.
#   BRIDGE=<meshcom-loraham-bridge binary>  QEMU_BIN=<qemu-system-xtensa>  [XRPW=<password file>]
#   [REPO=<runner checkout>, default this one]  [G4=1: also --reboot, then restart and probe again]
set -u
R=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}; cd "$R"
Q=${QEMU_BIN:?QEMU_BIN=<qemu-system-xtensa>}
O=${1:?OUTDIR}; mkdir -p "$O"
"${BRIDGE:?BRIDGE=<meshcom-loraham-bridge binary>}" --bind 127.0.0.1 --port 7000 --ping-interval-ms 30000 --pong-timeout-ms 90000 ${XRPW:+--password-file "$XRPW"} > "$O/bridge.log" 2>&1 & BP=$!
scripts/run.sh --env qemu-headless-extradio-gpsd --qemu "$Q" > "$O/run.log" 2>&1 & RP=$!
for i in $(seq 1 30); do [ -S .run/gps-uart1.sock ] && break; sleep 1; done
python3 -I scripts/gps-relay.py --mode fixture --fixture fixtures/gps/short_track.nmea --uart .run/gps-uart1.sock --rate "${GPS_RATE:-1}" --loop > "$O/relay.log" 2>&1 & GP=$!
t0=$(date +%s)
for i in $(seq 1 120); do grep -aq 'CLIENT STARTED' .run/uart-latest.log 2>/dev/null && break; sleep 1; done
echo "client-started after $(( $(date +%s)-t0 ))s"
sleep 25
for p in / /info /setup; do
  curl -s -m 20 -o "$O/page$(echo $p | tr / _).html" -D "$O/hdr$(echo $p | tr / _).txt" -w "web $p code=%{http_code} bytes=%{size_download}\n" "http://127.0.0.1:18083$p" || echo "web $p curl-fail"
done
python3 -I - <<'PY' > "$O/console.txt" 2>&1
import socket
s=socket.create_connection(("127.0.0.1",12323),timeout=10); s.settimeout(5)
try: d=s.recv(256)
except Exception as e: d=repr(e).encode()
print("console accepted; first bytes:", len(d), d[:60])
PY
cat "$O/console.txt"
console_cmd() { python3 -I - "$@" <<'PY'
import socket,sys,time
s=socket.create_connection(("127.0.0.1",12323),timeout=10); s.settimeout(3)
try: s.recv(256)
except Exception: pass
s.sendall((sys.argv[1]+"\r\n").encode()); time.sleep(4)
try: d=s.recv(8192)
except Exception as e: d=repr(e).encode()
if len(sys.argv)>2:
    import re
    print("reply-extract:", " | ".join(re.findall(sys.argv[2], d.decode(errors="replace"))))
else: print("reply:", d[:120])
PY
}
xrbytes() { ss -tin '( sport = :7000 )' | grep -oE 'bytes_(sent|received):[0-9]+' | paste -sd' '; }
sleep 10; echo "xr before: $(xrbytes)"; echo "sendpos:"; console_cmd "--sendpos"; sleep 20; echo "xr after:  $(xrbytes)"
echo "page tail: $(tail -c 9 "$O/page_.html" | tr -d '\n')"
echo "info:"; console_cmd "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)'
curl -s -m 60 -o "$O/spectrum.html" -w "spectrum code=%{http_code} bytes=%{size_download} secs=%{time_total}\n" "http://127.0.0.1:18083/?page=spectrum" || echo "spectrum curl-fail rc=$?"
curl -s -m 20 -o /dev/null -w "web after spectrum code=%{http_code}\n" http://127.0.0.1:18083/ || echo "web after spectrum curl-fail"
kill -0 $RP 2>/dev/null && echo "after sendpos: qemu alive" || { wait $RP; echo "after sendpos: run.sh/QEMU ended rc=$?"; }
if [ "${G4:-0}" = 1 ]; then
  echo "reboot:"; console_cmd "--reboot"
  for i in $(seq 1 60); do kill -0 $RP 2>/dev/null || break; sleep 1; done
  if kill -0 $RP 2>/dev/null; then echo "G4: QEMU still running 60 s after --reboot"; else wait $RP; echo "G4: run.sh/QEMU ended by itself rc=$? after ${i}s"; fi
  cp -f "$(readlink -f .run/uart-latest.log)" "$O/uart-before-restart.log"
  scripts/run.sh --env qemu-headless-extradio-gpsd --qemu "$Q" > "$O/run2.log" 2>&1 & RP=$!
  for i in $(seq 1 120); do grep -aq 'CLIENT STARTED' .run/uart-latest.log 2>/dev/null && break; sleep 1; done
  sleep 15
  curl -s -m 20 -o /dev/null -w "restart web code=%{http_code} bytes=%{size_download}\n" http://127.0.0.1:18083/
  grep -aE 'RESET_REASON|\[NET\] Ethernet mode|ethmode' .run/uart-latest.log | cut -c1-120
fi
ss -tnp 2>/dev/null | grep -E ':7000\b' | grep -c ESTAB | sed 's/^/bridge estab sockets: /'
sleep 5
cp -f "$(readlink -f .run/uart-latest.log)" "$O/uart.log"
scripts/stop.sh > /dev/null 2>&1; kill $GP $BP 2>/dev/null; wait $RP $GP $BP 2>/dev/null
echo "stopped; qemu left: $(pgrep -c '[q]emu-system-xtensa')"
