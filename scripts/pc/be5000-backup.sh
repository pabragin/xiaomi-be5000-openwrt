#!/bin/sh
# Dump every MTD partition of the router to the PC over SSH and verify SHA-256.
# Each partition is read once: the router hashes the same bytes it sends, so a
# partition that changes while the router runs (overlay) still verifies. A block
# the router cannot read (a bad block) does not stop the backup: that partition is
# read again block by block, the bad block is saved as 0xFF (erased flash) and
# listed in bad-blocks.txt.
#   ./be5000-backup.sh [root@192.168.31.1] [output-dir]
set -eu

HOST=${1:-root@192.168.31.1}
OUT=${2:-be5000-backup-$(date +%Y%m%d-%H%M%S)}
SSH="ssh ${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"
HELPER=/tmp/.be5000_dump.sh

sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

mkdir -p "$OUT"
# One connection: the helper goes to the router; /proc/mtd, sysfs and dmesg come back.
# The helper (busybox sh) prints partition $1 ($2 bytes per block, $3 bytes in all) on
# stdout and "sha256 <hex>" of the same bytes on stderr. With $4=blocks it reads block
# by block: a block that cannot be read comes out as 0xFF and is reported as "bad <n>".
$SSH "$HOST" "cat > $HELPER && sh $HELPER info" <<'EOT' | awk -v o="$OUT" 'BEGIN{f="proc_mtd"} /^=== be5000 /{f=$3; next} {print > (o "/" f ".txt")}'
if [ "$1" = info ]; then
	cat /proc/mtd; echo "=== be5000 sysfs_mtd"
	for i in /sys/class/mtd/mtd*; do [ -r $i/offset ] && echo "$(basename $i) $(cat $i/offset) $(cat $i/size) $(cat $i/name)"; done
	echo "=== be5000 dmesg"; dmesg
	exit 0
fi
dev=$1; bs=$2; size=$3; mode=${4:-cat}
f=/tmp/.be5000_fifo; s=/tmp/.be5000_sum; blk=/tmp/.be5000_blk; ff=/tmp/.be5000_ff
rm -f $f; mkfifo $f || exit 1
sha256sum < $f > $s &
if [ $mode = cat ]; then
	cat $dev | tee $f
else
	dd if=/dev/zero bs=$bs count=1 2>/dev/null | tr "\000" "\377" > $ff
	i=0; off=0
	while [ $off -lt $size ]; do
		want=$((size - off)); [ $want -gt $bs ] && want=$bs
		if dd if=$dev of=$blk bs=$bs skip=$i count=1 2>/dev/null && [ "$(wc -c < $blk | tr -d " ")" = $want ]; then
			cat $blk
		else
			echo "bad $i" >&2
			dd if=$ff bs=$want count=1 2>/dev/null
		fi
		i=$((i + 1)); off=$((off + bs))
	done | tee $f
fi
wait
echo "sha256 $(cut -d" " -f1 $s)" >&2
rm -f $f $s $blk $ff
EOT
[ -s "$OUT/proc_mtd.txt" ] || { echo "could not read /proc/mtd from $HOST: no SSH connection?" >&2; exit 1; }
# dmesg is saved again at the end: a read error is logged only when the partition is read
trap '$SSH "$HOST" "dmesg; rm -f $HELPER" > "$OUT/dmesg.txt.new" 2>/dev/null && mv "$OUT/dmesg.txt.new" "$OUT/dmesg.txt" || rm -f "$OUT/dmesg.txt.new"' EXIT
cat "$OUT/proc_mtd.txt"
rm -f "$OUT/bad-blocks.txt"
MSG=$OUT/.router-messages   # stderr of the last partition read

for dev in $(sed 1d "$OUT/proc_mtd.txt" | cut -d: -f1); do
	line=$(grep "^$dev:" "$OUT/proc_mtd.txt")   # mtd3: 04000000 00020000 "firmware"
	name=$(echo "$line" | sed 's/.*"\(.*\)"/\1/')
	size=$((0x$(echo "$line" | awk '{print $2}')))
	bs=$((0x$(echo "$line" | awk '{print $3}')))
	file=$OUT/$dev-$name.bin
	echo ">>> $dev ($name)"
	$SSH "$HOST" "sh $HELPER /dev/$dev $bs $size" > "$file" 2> "$MSG" || true
	grep -v -e '^sha256 ' -e '^bad ' "$MSG" || true   # what the router printed, e.g. a read error
	if [ "$(wc -c < "$file" | tr -d ' ')" != "$size" ]; then
		$SSH "$HOST" true 2>/dev/null || { echo "lost the SSH connection to $HOST" >&2; exit 1; }
		echo "$dev: the router could not read it whole (see above), reading it block by block"
		$SSH "$HOST" "sh $HELPER /dev/$dev $bs $size blocks" > "$file" 2> "$MSG" || true
		grep -v -e '^sha256 ' -e '^bad ' "$MSG" || true
		off=$(awk -v d="$dev" '$1 == d {print $2}' "$OUT/sysfs_mtd.txt")
		grep '^bad ' "$MSG" | cut -d' ' -f2 | while read -r b; do
			case $off in
				[0-9]*) printf '%s (%s): block %s, offset 0x%X in the partition, 0x%X in the flash\n' "$dev" "$name" "$b" $((b * bs)) $((off + b * bs)) ;;
				*) printf '%s (%s): block %s, offset 0x%X in the partition\n' "$dev" "$name" "$b" $((b * bs)) ;;
			esac
		done | tee -a "$OUT/bad-blocks.txt"
	fi
	remote=$(grep '^sha256 ' "$MSG" | cut -d' ' -f2)
	have=$(sha256 "$file")
	[ -n "$remote" ] && [ "$remote" = "$have" ] || { echo "SHA-256 mismatch for $dev: the copy on the PC differs from what the router sent (connection lost or data damaged), run again" >&2; exit 1; }
	echo "$have  $dev-$name.bin" >> "$OUT/SHA256SUMS"
done
rm -f "$MSG"
[ -s "$OUT/bad-blocks.txt" ] || rm -f "$OUT/bad-blocks.txt"
echo "Backup complete and verified: $OUT"
if [ -f "$OUT/bad-blocks.txt" ]; then
	echo "WARNING: $(wc -l < "$OUT/bad-blocks.txt" | tr -d ' ') block(s) could not be read and are saved as 0xFF, see $OUT/bad-blocks.txt"
fi
