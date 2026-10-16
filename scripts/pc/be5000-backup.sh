#!/bin/sh
# Dump every MTD partition of the router to the PC over SSH and verify SHA-256.
#   ./be5000-backup.sh [root@192.168.31.1] [output-dir]
set -eu

HOST=${1:-root@192.168.31.1}
OUT=${2:-be5000-backup-$(date +%Y%m%d-%H%M%S)}
SSH="ssh ${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

mkdir -p "$OUT"
$SSH "$HOST" 'cat /proc/mtd' > "$OUT/proc_mtd.txt"
$SSH "$HOST" 'for i in /sys/class/mtd/mtd*; do [ -r $i/offset ] && echo "$(basename $i) $(cat $i/offset) $(cat $i/size) $(cat $i/name)"; done' > "$OUT/sysfs_mtd.txt" || true
$SSH "$HOST" 'dmesg' > "$OUT/dmesg.txt" || true
cat "$OUT/proc_mtd.txt"

for dev in $(sed 1d "$OUT/proc_mtd.txt" | cut -d: -f1); do
	name=$(grep "^$dev:" "$OUT/proc_mtd.txt" | sed 's/.*"\(.*\)"/\1/')
	echo ">>> $dev ($name)"
	$SSH "$HOST" "cat /dev/$dev" > "$OUT/$dev-$name.bin"
	remote=$($SSH "$HOST" "sha256sum /dev/$dev" | cut -d' ' -f1)
	local=$(sha256 "$OUT/$dev-$name.bin")
	[ "$remote" = "$local" ] || { echo "SHA-256 mismatch for $dev" >&2; exit 1; }
	echo "$local  $dev-$name.bin" >> "$OUT/SHA256SUMS"
done
echo "Backup complete and verified: $OUT"