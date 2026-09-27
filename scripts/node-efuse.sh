#!/usr/bin/env bash
#
# node-efuse.sh EFUSE — make sure the node has its own efuse image, so it has its own MAC and node ID.
#
# MeshCom derives its node ID (_GW_ID) from the ESP32 factory MAC in efuse block 0 (MAC bytes 2..5), and every
# message id carries its low 22 bits. Espressif's QEMU reads the efuse from a file only when one is attached (run.sh
# does that); without one the MAC and the ID are 0 on every node, so all nodes number their messages in one range
# and receivers drop repeats. This script creates the file once:
#   * EFUSE absent  -> 124 bytes, all zero (no flash encryption, no secure boot, as QEMU has it without a file)
#                      except a random, locally administered, unicast MAC and its CRC8 in block 0 (ESP-IDF efuse
#                      table: MAC_FACTORY bytes 0..5 at bits 72,64,56,48,40,32; CRC at bit 80; CRC8 = espefuse's
#                      calc_crc, reflected polynomial 0x8C, init 0). The 22-bit id prefix is never 0 (the old range).
#   * EFUSE present -> checked and used as it is (the node keeps its ID); never rewritten. A file that is not
#                      124 bytes, whose MAC CRC is wrong, whose id prefix is 0 or that is not readable and writable
#                      (QEMU writes efuse burns into it) is an error: fix it, or move it away to get a new ID.
# run.sh names it after the node image (<node image>.efuse): deleting the node's state gives the node a new ID.
set -eu
umask 077

EFUSE="${1:?usage: node-efuse.sh EFUSE}"
SIZE=124

crc8() {
	local c=0 b _
	for b in "$@"; do
		c=$(( c ^ b ))
		for _ in 1 2 3 4 5 6 7 8; do
			if (( c & 1 )); then c=$(( (c >> 1) ^ 0x8C )); else c=$(( c >> 1 )); fi
		done
	done
	echo "$c"
}
# The low 22 bits of _GW_ID = mac[2]<<24 | mac[3]<<16 | mac[4]<<8 | mac[5] (the firmware's getMacAddr()).
prefix() { echo $(( ((${1} & 0x3F) << 16) | (${2} << 8) | ${3} )); }   # mac[3] mac[4] mac[5]

if [ -e "$EFUSE" ]; then
	have="$(stat -c %s "$EFUSE")"
	[ "$have" = "$SIZE" ] || { echo "ERROR: $EFUSE is $have bytes, expected $SIZE; move it away to get a new node ID" >&2; exit 1; }
	# bytes 4..10: mac[5] mac[4] mac[3] mac[2] mac[1] mac[0] crc
	read -r -a b <<< "$(od -An -tu1 -j4 -N7 "$EFUSE")"
	[ "$(crc8 "${b[5]}" "${b[4]}" "${b[3]}" "${b[2]}" "${b[1]}" "${b[0]}")" = "${b[6]}" ] \
		|| { echo "ERROR: $EFUSE has a wrong MAC CRC; move it away to get a new node ID" >&2; exit 1; }
	[ "$(prefix "${b[2]}" "${b[1]}" "${b[0]}")" != 0 ] \
		|| { echo "ERROR: $EFUSE gives node id prefix 0; move it away to get a new node ID" >&2; exit 1; }
	# QEMU opens the efuse for writing (esp32_efuse_realize: "block device is not writeable").
	[ -r "$EFUSE" ] && [ -w "$EFUSE" ] \
		|| { echo "ERROR: $EFUSE must be readable and writable; fix its permissions or move it away to get a new node ID" >&2; exit 1; }
	echo "[run] node efuse: kept ($EFUSE)"
	exit 0
fi

# NODE_EFUSE_MAC=aa:bb:cc:dd:ee:ff fixes the MAC (tests only; taken as given, but a zero prefix is still refused).
if [ -n "${NODE_EFUSE_MAC:-}" ]; then
	IFS=: read -r -a hex <<< "$NODE_EFUSE_MAC"; mac=()
	for h in "${hex[@]}"; do mac+=( $(( 16#$h )) ); done
	[ "${#mac[@]}" = 6 ] || { echo "ERROR: NODE_EFUSE_MAC needs 6 bytes" >&2; exit 2; }
	[ "$(prefix "${mac[3]}" "${mac[4]}" "${mac[5]}")" != 0 ] || { echo "ERROR: NODE_EFUSE_MAC gives node id prefix 0" >&2; exit 2; }
else
	# 6 random bytes; byte 0: clear the multicast bit (0x01), set the locally-administered bit (0x02).
	# Drawn again while the 22-bit id prefix is 0 (probability 2^-22 per draw).
	while :; do
		read -r -a mac <<< "$(od -An -tu1 -N6 /dev/urandom)"
		[ "$(prefix "${mac[3]}" "${mac[4]}" "${mac[5]}")" != 0 ] && break
	done
	mac[0]=$(( (mac[0] & 0xFC) | 0x02 ))
fi
crc="$(crc8 "${mac[@]}")"

# Block 0 word 1 (bytes 4..7, little endian) = mac[5] mac[4] mac[3] mac[2]; word 2 (bytes 8..11) = mac[1] mac[0] crc 0.
bytes=(0 0 0 0 "${mac[5]}" "${mac[4]}" "${mac[3]}" "${mac[2]}" "${mac[1]}" "${mac[0]}" "$crc")
mkdir -p "$(dirname "$EFUSE")"
tmp="$(mktemp "$EFUSE.XXXXXX")"
{
	for b in "${bytes[@]}"; do printf '%b' "\\x$(printf %02x "$b")"; done
	head -c $(( SIZE - ${#bytes[@]} )) /dev/zero
} > "$tmp"
[ "$(stat -c %s "$tmp")" = "$SIZE" ] || { rm -f "$tmp"; echo "ERROR: could not write $EFUSE" >&2; exit 1; }
sync -- "$tmp"; mv -f "$tmp" "$EFUSE"; sync -- "$(dirname "$EFUSE")"
printf '[run] node efuse: created (%s), MAC %02x:%02x:%02x:%02x:%02x:%02x, node ID %02X%02X%02X%02X\n' "$EFUSE" \
	"${mac[@]}" "${mac[2]}" "${mac[3]}" "${mac[4]}" "${mac[5]}"
