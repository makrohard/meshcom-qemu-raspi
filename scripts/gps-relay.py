#!/usr/bin/env python3
#
# gps-relay.py — feed line-oriented NMEA into the QEMU guest's virtual UART1.
#
# The QEMU runner (scripts/run.sh, gpsd profiles) exposes the emulated ESP32 UART1
# as a Unix-domain *server* socket under .run/. This relay is a *client*: it connects
# to that socket and writes NMEA sentences, which the MeshCom firmware reads through
# its normal GPSSerial(1)/TinyGPSPlus byte-by-byte parser. QEMU boots independently
# (server=on,wait=off); the relay may attach/detach/reconnect at any time.
#
# Two EXPLICIT, mutually exclusive source modes (never auto-switching):
#
#   --mode gpsd      PRODUCTION. Connect ONLY to a local gpsd (default 127.0.0.1:2947),
#                    request NMEA via  ?WATCH={"enable":true,"nmea":true};  and forward
#                    gpsd's line-oriented (pseudo-)NMEA. gpsd alone owns the physical
#                    receiver; this relay never touches /dev/ttyACM0. A no-fix condition
#                    is forwarded verbatim — the relay NEVER synthesizes a location,
#                    time, altitude, fix, or satellite count.
#
#   --mode fixture   TEST. Replay a checked-in synthetic NMEA fixture file. No gpsd and
#                    no receiver required. Deterministic; for automated tests only.
#
# Safety / privacy:
#   * Every forwarded line must be printable ASCII and match  $<5..>,...*HH  with a
#     correct XOR checksum. Binary / UBX (0xB5 0x62) or other non-printable input is a
#     FATAL abort (we never relay garbled data to the guest, never ship binary fixtures).
#   * Logs NEVER contain coordinates/time/altitude — only talker+type, checksum verdict,
#     and counters (privacy: live position must not leak into logs).
#   * gpsd host is pinned to loopback; a non-loopback --gpsd is rejected.
#
# This script does not own the UART socket file (QEMU created it) and never removes it.
import argparse
import os
import select
import socket
import sys
import time

NMEA_MAX = 84            # NMEA sentence hard cap incl. CRLF; longer => suspicious
PRINTABLE = set(range(0x20, 0x7F)) | {0x0D, 0x0A, 0x09}


def log(msg):
    # Single channel, line-buffered; transition/summary only, never coordinates.
    sys.stderr.write("[gps-relay] %s\n" % msg)
    sys.stderr.flush()


def fatal(msg, code=2):
    log("FATAL: " + msg)
    sys.exit(code)


def sentence_label(line):
    # "$GPRMC,....*61" -> "GPRMC"  (talker+type only; nothing positional).
    body = line[1:].split("*", 1)[0]
    return body.split(",", 1)[0][:6] if body else "?"


def checksum_ok(line):
    # XOR over chars between '$' and '*'; compare to the 2 hex digits after '*'.
    if not line.startswith("$") or "*" not in line:
        return False
    body, _, cs = line[1:].partition("*")
    cs = cs.strip()
    if len(cs) < 2:
        return False
    try:
        want = int(cs[:2], 16)
    except ValueError:
        return False
    got = 0
    for ch in body:
        got ^= ord(ch)
    return got == want


def looks_like_nmea(line):
    return line.startswith("$") and "*" in line and 5 <= len(line) <= NMEA_MAX


def assert_printable(raw):
    # raw: bytes. Abort hard on binary / UBX so garbage never reaches the guest.
    if raw[:2] == b"\xb5\x62":
        fatal("UBX binary frame detected on the NMEA source (sync 0xB5 0x62).")
    for b in raw:
        if b not in PRINTABLE:
            fatal("non-printable byte 0x%02X on the NMEA source (binary/garbled input)." % b)


class Uart:
    """Client connection to QEMU's UART1 Unix server socket, with reconnect."""

    def __init__(self, path):
        self.path = path
        self.sock = None

    def connect(self):
        # QEMU may not be up yet; back off and retry.
        delay = 0.25
        while True:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.path)
                self.sock = s
                log("connected to UART1 socket %s" % self.path)
                return
            except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
                log("waiting for UART1 socket (%s); retry in %.2fs" % (e.__class__.__name__, delay))
                time.sleep(delay)
                delay = min(delay * 2, 2.0)

    def _drain_inbound(self):
        # The guest writes to UART1 TX (e.g. probe bytes). Discard them so the guest
        # never blocks; we never interpret guest->host traffic.
        if not self.sock:
            return
        try:
            while True:
                r, _, _ = select.select([self.sock], [], [], 0)
                if not r:
                    return
                if not self.sock.recv(4096):
                    return  # peer closed; write() will surface it
        except OSError:
            return

    def write_line(self, line):
        data = (line + "\r\n").encode("ascii", "ignore")
        while True:
            if self.sock is None:
                self.connect()
            self._drain_inbound()
            try:
                self.sock.sendall(data)
                return
            except (BrokenPipeError, ConnectionResetError, OSError) as e:
                log("UART write failed (%s); reconnecting" % e.__class__.__name__)
                try:
                    self.sock.close()
                except OSError:
                    pass
                self.sock = None  # loop reconnects

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def forward(uart, line, mode, stats):
    """Validate then forward one candidate NMEA line. Redacted logging only."""
    label = sentence_label(line)
    if checksum_ok(line):
        uart.write_line(line)
        stats["fwd"] += 1
        return
    # Bad checksum, printable shape.
    stats["badcs"] += 1
    if mode == "fixture":
        # The malformed fixture must reach the firmware to prove parser robustness.
        log("forwarding bad-checksum sentence %s (fixture mode)" % label)
        uart.write_line(line)
        stats["fwd"] += 1
    else:
        # Live source: never forward garbage from a flaky receiver.
        log("dropping bad-checksum sentence %s (gpsd mode)" % label)


def run_fixture(uart, path, rate, loop):
    if not os.path.isfile(path):
        fatal("fixture not found: %s" % path)
    with open(path, "rb") as f:
        raw = f.read()
    assert_printable(raw)
    lines = [ln.strip() for ln in raw.decode("ascii").splitlines() if ln.strip()]
    lines = [ln for ln in lines if not ln.startswith("#")]
    if not lines:
        fatal("fixture has no NMEA lines: %s" % path)
    delay = 1.0 / rate if rate > 0 else 0.0
    stats = {"fwd": 0, "badcs": 0}
    uart.connect()
    log("fixture mode: %d sentences from %s @ %.2f/s (%s)"
        % (len(lines), os.path.basename(path), rate, "loop" if loop else "once"))
    while True:
        for ln in lines:
            if not looks_like_nmea(ln):
                fatal("fixture line is not NMEA-shaped: %s" % sentence_label(ln))
            forward(uart, ln, "fixture", stats)
            if delay:
                time.sleep(delay)
        log("fixture pass complete: forwarded=%d bad_checksum=%d" % (stats["fwd"], stats["badcs"]))
        if not loop:
            return


def run_gpsd(uart, host, port):
    if host not in ("127.0.0.1", "::1", "localhost"):
        fatal("refusing non-loopback gpsd host %r (gpsd must stay loopback-only)." % host)
    uart.connect()
    stats = {"fwd": 0, "badcs": 0}
    backoff = 0.5
    while True:
        try:
            gs = socket.create_connection((host, port), timeout=10)
        except OSError as e:
            log("gpsd connect failed (%s); retry in %.1fs" % (e.__class__.__name__, backoff))
            time.sleep(backoff)
            backoff = min(backoff * 2, 8.0)
            continue
        backoff = 0.5
        log("connected to gpsd %s:%d; requesting NMEA stream" % (host, port))
        gs.sendall(b'?WATCH={"enable":true,"nmea":true};\n')
        buf = b""
        try:
            gs.settimeout(30)
            while True:
                chunk = gs.recv(4096)
                if not chunk:
                    log("gpsd closed the stream; reconnecting")
                    break
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    assert_printable(raw)
                    line = raw.decode("ascii", "ignore").strip()
                    if not line:
                        continue
                    if line[0] == "{":
                        # gpsd JSON control/report. Used only for liveness; never
                        # forwarded, never logged with positional fields.
                        continue
                    if looks_like_nmea(line):
                        forward(uart, line, "gpsd", stats)
        except socket.timeout:
            log("gpsd idle >30s; reconnecting")
        except OSError as e:
            log("gpsd read error (%s); reconnecting" % e.__class__.__name__)
        finally:
            try:
                gs.close()
            except OSError:
                pass
        time.sleep(backoff)


def main():
    p = argparse.ArgumentParser(description="Relay NMEA into QEMU UART1 from gpsd or a fixture.")
    p.add_argument("--mode", choices=("gpsd", "fixture"), required=True,
                   help="REQUIRED explicit source mode (no default; never auto-switches).")
    p.add_argument("--uart", required=True, help="path to QEMU UART1 Unix socket (under .run/).")
    p.add_argument("--fixture", help="fixture file (required for --mode fixture).")
    p.add_argument("--gpsd", default="127.0.0.1:2947", help="gpsd host:port (loopback only).")
    p.add_argument("--rate", type=float, default=1.0, help="fixture sentences per second.")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--once", dest="loop", action="store_false", default=False,
                   help="fixture: replay once then exit (default).")
    g.add_argument("--loop", dest="loop", action="store_true",
                   help="fixture: replay continuously.")
    args = p.parse_args()

    if args.mode == "fixture" and not args.fixture:
        p.error("--mode fixture requires --fixture")
    if args.mode == "gpsd" and args.fixture:
        p.error("--fixture is only valid with --mode fixture")

    uart = Uart(args.uart)
    try:
        if args.mode == "fixture":
            run_fixture(uart, args.fixture, args.rate, args.loop)
        else:
            host, _, port = args.gpsd.partition(":")
            run_gpsd(uart, host, int(port or "2947"))
    except KeyboardInterrupt:
        log("interrupted; closing")
    finally:
        uart.close()


if __name__ == "__main__":
    main()
