#!/usr/bin/env python3
#
# xr-tap.py LISTEN_PORT BRIDGE_PORT LOG — forward one external-radio (XR) TCP connection at a time and
# log every frame: direction, type, length and, for TX_REQUEST, payload byte 0 (0x21 = a position).
# The XR header is magic "XR", version, type, length (big-endian), seq (lib/external_radio_protocol).
import socket, sys, threading
NAMES = {1:"HELLO",2:"HELLO_ACK",3:"AUTH_CHALLENGE",4:"AUTH_RESPONSE",5:"AUTH_RESULT",6:"CONFIGURE",7:"CONFIG_RESULT",
         8:"RX_PACKET",9:"TX_REQUEST",10:"TX_RESULT",11:"PING",12:"PONG",13:"ERROR"}
lport, bport, logp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
log = open(logp, "a", buffering=1)
def pump(src, dst, tag):
    buf = b""
    while True:
        try:
            d = src.recv(4096)
        except OSError:          # the other direction closed both sockets
            return
        if not d:
            for s in (src, dst):
                try: s.close()
                except OSError: pass
            return
        try:
            dst.sendall(d)
        except OSError:
            return
        buf += d
        while len(buf) >= 8:
            if buf[0:2] != b"XR":
                log.write(f"{tag} BADMAGIC\n"); buf = b""; break
            n = int.from_bytes(buf[4:6], "big")
            if len(buf) < 8 + n: break
            extra = (" payload0=0x%02x" % buf[8]) if buf[3] == 9 and n > 0 else ""
            log.write(f"{tag} {NAMES.get(buf[3], hex(buf[3]))} len={n}{extra}\n"); buf = buf[8 + n:]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", lport)); srv.listen(1)
while True:
    c, _ = srv.accept(); b = socket.create_connection(("127.0.0.1", bport))
    threading.Thread(target=pump, args=(c, b, "node>bridge"), daemon=True).start()
    threading.Thread(target=pump, args=(b, c, "bridge>node"), daemon=True).start()
