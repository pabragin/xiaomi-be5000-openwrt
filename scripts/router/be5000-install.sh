#!/bin/sh
# Xiaomi BE5000 (Airoha AN7563): layout probe, calibration and bootloader writer.
# Runs ON THE ROUTER (busybox ash) with root. Works with any starting layout:
# stock Xiaomi, xinyooo/iscle OpenWrt ("replacement" layout) or X-WRT.
#
#   sh be5000-install.sh check
#   sh be5000-install.sh nand
#   sh be5000-install.sh calibration /tmp/calibration.bin
#   sh be5000-install.sh bootloader  /tmp/be5000-bootloader-w25n01kv.bin
#
# Nothing is written by "check". Every write is verified by reading it back.

set -u

CAL_OFF=$((0xA0000))      # absolute flash offset of the calibration block
CAL_SIZE=$((0x20000))     # one 128 KiB erase block
BL_DATA_END=$((0x4F852))  # last non-zero byte of the bootloader image + 1

# SPI-NAND chips known to the BL2 inside be5000-bootloader-w25n01kv.bin
BL2_CHIPS="ATO25D1GA BWET08U BWJX08U EM73C044SNB EM73C044SND EM73C044SNF EM73C044VCA
EM73C044VCD EM73D044SNA EM73D044SNC EM73D044SND EM73D044SNF EM73D044VCA EM73D044VCB
EM73D044VCD EM73D044VCG EM73D044VCH EM73E044SNA EM73E044VCA EM73E044VCB EM73F044SNA
F50L1G F50L1G41LB F50L2G41LB FM25G01B FM25G02 FM25G02B FM25S01 FS35ND01GD1F1
FS35ND02GD1F1 FS35ND02GS2F1 GD5F1GQ4UB GD5F2GQ4UB GD5F2GQ4UE9IS GD5F4GQ4UB HYF2GQ4UAACAE
MT29F1G01 MT29F2G01 MT29F4G01 MXIC35LF1G MXIC35LF1G24AD MXIC35LF2G MXIC35LF2G14AC
MXIC35LF2GE4AD PSU1GS20BN S35ML02G3 TC58CVG0S3H TC58CVG1S3H TC58CVG2S0H W25M02G W25N01G
W25N01KV W25N02K W25N04K XT26G01A XT26G02A XT26G02B"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

hex2() { # N bytes of a file at an optional offset, as lowercase hex
	dd if="$1" bs=1 skip="${3:-0}" count="$2" 2>/dev/null > /tmp/.be5000_hex
	if command -v hexdump >/dev/null; then hexdump -v -e '1/1 "%02x"' /tmp/.be5000_hex
	elif command -v od >/dev/null; then od -An -tx1 /tmp/.be5000_hex | tr -d ' \n'
	else xxd -p /tmp/.be5000_hex | tr -d '\n'
	fi
	rm -f /tmp/.be5000_hex
}

hash_of() { # md5 of a file or of N bytes at offset of a file
	if [ $# -eq 1 ]; then md5sum "$1" | cut -d' ' -f1
	else dd if="$1" bs=4096 skip=$(($2 / 4096)) count=$(($3 / 4096)) 2>/dev/null | md5sum | cut -d' ' -f1
	fi
}

# Print "index name offset size flags" for every MTD partition.
# Offsets come from sysfs when available, otherwise they are accumulated in
# /proc/mtd order (fixed partitions on this board are contiguous from 0).
mtd_table() {
	acc=0; maxend=0
	sed 1d /proc/mtd | while read -r dev size erase name; do
		i=${dev#mtd}; i=${i%:}
		name=$(echo "$name" | tr -d '"')
		sz=$((0x$size))
		if [ -r /sys/class/mtd/mtd$i/offset ]; then off=$(cat /sys/class/mtd/mtd$i/offset); else off=$acc; fi
		flags=$(cat /sys/class/mtd/mtd$i/flags 2>/dev/null || echo 0)
		# Sub-partitions (kernel/rootfs inside "firmware") report offsets relative
		# to their parent, so they start before the end of what we have seen.
		if [ "$off" -lt "$maxend" ]; then nested=1; else nested=0; maxend=$((off + sz)); fi
		echo "$i $name $off $sz $flags $nested"
		acc=$((off + sz))
	done
}

# Partition that contains [abs, abs+len): prints "index name offset size flags"
mtd_covering() {
	mtd_table | while read -r i n o s f nested; do
		[ "$nested" = 1 ] && continue
		if [ "$1" -ge "$o" ] && [ $(($1 + $2)) -le $((o + s)) ]; then echo "$i $n $o $s $f"; break; fi
	done
}

writable() { [ $(( $1 & 0x400 )) -ne 0 ]; }   # MTD_WRITEABLE

is_erased() { # file offset len -> true if all 0xFF
	ff=$(dd if=/dev/zero bs=4096 count=$(($3 / 4096)) 2>/dev/null | tr '\000' '\377' | md5sum | cut -d' ' -f1)
	[ "$(hash_of "$1" "$2" "$3")" = "$ff" ]
}

nand_chip() {
	dmesg 2>/dev/null | grep -iE 'spi.?nand|SPI NAND|nand.*(id|found)|W25N|GD5F|F35SQA|F50L|EM73|MX35|XT26' | head -n 8
}

# Identify the SPI-NAND chip with tools every firmware has: the kernel log
# (manufacturer, sometimes the JEDEC ID) and the MTD geometry in sysfs.
# W25N01KV and W25N01GV are both "Winbond, 128 MiB, 2 KiB pages"; only the
# OOB size (96 vs 64 bytes) or the device ID (AE21 vs AA21) tells them apart.
cmd_nand() {
	log=$(nand_chip)
	m=/sys/class/mtd/mtd0
	oob=$(cat $m/oobsize 2>/dev/null); page=$(cat $m/writesize 2>/dev/null); blk=$(cat $m/erasesize 2>/dev/null)
	info "Kernel log:"; [ -n "$log" ] && echo "$log" | sed 's/^/  /' || echo "  (nothing about NAND)"
	info "MTD geometry: page=${page:-?} oob=${oob:-?} erase=${blk:-?}"
	vendor=unknown
	echo "$log" | grep -qi winbond && vendor=Winbond
	echo "$log" | grep -qiE 'ESMT|Elite' && vendor=ESMT
	echo "$log" | grep -qiE 'GigaDevice' && vendor=GigaDevice
	echo "$log" | grep -qiE 'Macronix|MXIC' && vendor=Macronix
	ids=$(echo "$log" | tr 'A-F' 'a-f' | grep -oE '(0x)?ef[ :,x0]*a[ae][ :,x0]*21' | head -n 1)
	chip=unknown
	case "$ids" in *ae*21) chip=W25N01KV ;; *aa*21) chip=W25N01GV ;; esac
	if [ "$chip" = unknown ] && [ "$vendor" = Winbond ] && [ "$page" = 2048 ]; then
		[ "$oob" = 96 ] && chip=W25N01KV
		[ "$oob" = 64 ] && chip=W25N01GV
	fi
	# A model name printed by the kernel wins over the geometry guess
	named=$(echo "$log" | grep -oE 'W25N0[0-9A-Z]+|W25M0[0-9A-Z]+|GD5F[0-9A-Z]+|EM73[0-9A-Z]+|F50L[0-9A-Z]+|MX35LF[0-9A-Z]+|XT26G[0-9A-Z]+|FM25[0-9A-Z]+|TC58[0-9A-Z]+|MT29F[0-9A-Z]+' | head -n 1)
	[ -n "$named" ] && chip=$named
	info "Result: vendor=$vendor chip=$chip"
	NAND_VERDICT=unknown
	if [ "$chip" != unknown ]; then
		key=$chip; [ "$chip" = W25N01GV ] && key=W25N01G
		key=$(echo "$key" | sed 's/^MX35LF/MXIC35LF/')
		NAND_VERDICT=no
		for c in $BL2_CHIPS; do case "$key" in "$c"|"$c"*) NAND_VERDICT=yes ;; esac; done
	fi
	case "$NAND_VERDICT" in
		yes) echo "  SUPPORTED: the BL2 of be5000-bootloader-w25n01kv.bin knows $chip";;
		no)  echo "  NOT SUPPORTED: $chip is not in the BL2 table - flashing would brick the router";;
		*)   echo "  NOT IDENTIFIED: read the marking on the flash chip and compare it with docs/en/technical.md (supported NAND chips)";;
	esac
	[ "$chip" = W25N01KV ] && echo "  Note: xinyooo v2026.05/06 bootloaders and the X-WRT preloader do NOT know W25N01KV"
}

cmd_check() {
	info "MTD partitions (index name offset size flags; flag 0x400 = writable)"
	mtd_table | while read -r i n o s f nested; do
		printf '  mtd%-2s %-14s off=0x%08x size=0x%08x %s%s\n' "$i" "$n" "$o" "$s" "$(writable "$f" && echo rw || echo RO)" "$([ "$nested" = 1 ] && echo ' (inside firmware)')"
	done
	cmd_nand

	layout=unknown
	if mtd_table | grep -qiE '^[0-9]+ factory 1572864 '; then layout=stock
	elif mtd_table | grep -qE '^[0-9]+ art 524288 262144 '; then layout=replacement
	fi
	info "Detected flash layout: $layout"

	set -- $(mtd_covering 0 $BL_DATA_END)
	[ $# -eq 5 ] && echo "  bootloader partition: mtd$1 '$2' size=0x$(printf %x "$4") $(writable "$5" && echo rw || echo READ-ONLY)" \
		|| echo "  bootloader partition: not found"
	set -- $(mtd_covering $CAL_OFF $CAL_SIZE)
	if [ $# -eq 5 ]; then
		dd if=/dev/mtd$1 of=/tmp/.be5000_cal_part bs=4096 2>/dev/null
		rel=$((CAL_OFF - $3))
		state="has data"
		is_erased /tmp/.be5000_cal_part $rel $CAL_SIZE && state="erased (ready)"
		head=$(hex2 /tmp/.be5000_cal_part 2 $rel)
		[ "$head" = "9279" ] && state="already contains MT7992 calibration"
		echo "  calibration block 0xA0000: mtd$1 '$2' +0x$(printf %x $rel), $state, $(writable "$5" && echo rw || echo READ-ONLY)"
		rm -f /tmp/.be5000_cal_part
	fi
	if [ "$layout" = stock ]; then
		set -- $(mtd_covering $((0x180000)) 2)
		head=$(hex2 /dev/mtd$1 2)
		echo "  Factory EEPROM header: $head (expected 9279 = MT7992)"
	fi
}

write_verify() { # mtd_index image_file
	mtd write "$2" "/dev/mtd$1" || die "mtd write failed - do NOT reboot, re-run or restore from /tmp backup"
	sz=$(wc -c < "$2")
	dd if=/dev/mtd$1 of=/tmp/.be5000_rb bs=4096 count=$((sz / 4096)) 2>/dev/null
	[ "$(hash_of "$2")" = "$(hash_of /tmp/.be5000_rb)" ] || { rm -f /tmp/.be5000_rb; die "read-back mismatch on mtd$1"; }
	rm -f /tmp/.be5000_rb
	info "mtd$1 written and verified ($(hash_of "$2"))"
}

cmd_calibration() {
	f=${1:-}; [ -f "$f" ] || die "usage: $0 calibration /tmp/calibration.bin"
	[ "$(wc -c < "$f")" -eq $CAL_SIZE ] || die "calibration file must be exactly 131072 bytes"
	[ "$(hex2 "$f" 2)" = "9279" ] || die "file is not an MT7992 EEPROM block"
	set -- $(mtd_covering $CAL_OFF $CAL_SIZE)
	[ $# -eq 5 ] || die "no MTD partition covers 0xA0000"
	idx=$1; off=$3; size=$4; flags=$5; rel=$((CAL_OFF - off))
	writable "$flags" || die "mtd$idx '$2' is read-only in this kernel; use the U-Boot method (docs)"
	part=/tmp/.be5000_part
	dd if=/dev/mtd$idx of=$part bs=4096 2>/dev/null
	if [ "$(hash_of $part $rel $CAL_SIZE)" = "$(hash_of "$f")" ]; then info "calibration already in place"; rm -f $part; return 0; fi
	is_erased $part $rel $CAL_SIZE || { rm -f $part; die "block 0xA0000 is not empty - stop and inspect it, never erase unknown data"; }
	cp $part /tmp/be5000-mtd$idx-before-calibration.bin
	{
		dd if=$part bs=4096 count=$((rel / 4096)) 2>/dev/null
		cat "$f"
		dd if=$part bs=4096 skip=$(((rel + CAL_SIZE) / 4096)) 2>/dev/null
	} > $part.new
	[ "$(wc -c < $part.new)" -eq "$size" ] || die "internal size error"
	info "writing calibration into mtd$idx '$2' at +0x$(printf %x $rel) (whole partition rewritten, other blocks unchanged)"
	write_verify $idx $part.new
	rm -f $part $part.new
}

cmd_bootloader() {
	f=${1:-}; [ -f "$f" ] || die "usage: $0 bootloader /tmp/be5000-bootloader-w25n01kv.bin"
	[ "$(wc -c < "$f")" -eq 524288 ] || die "bootloader image must be 524288 bytes"
	[ "$(hex2 "$f" 4 2048)" = "010064aa" ] || die "no FIP header at 0x800"
	set -- $(mtd_covering 0 $BL_DATA_END)
	[ $# -eq 5 ] || die "no MTD partition starts at 0"
	idx=$1; size=$4
	writable "$5" || die "mtd$idx '$2' is read-only in this kernel; bootloader cannot be written from here"
	cmd_nand
	case "$NAND_VERDICT" in
		yes) ;;
		no) die "this NAND chip is not supported by the bootloader - not writing" ;;
		*) [ "${BE5000_NAND_OK:-}" = 1 ] || die "NAND chip not identified. Check the chip marking against the list, then re-run with BE5000_NAND_OK=1" ;;
	esac
	img=/tmp/.be5000_bl
	# The replacement layout has a 0x7C000 "u-boot" partition; the image tail is zero padding.
	dd if="$f" of=$img bs=4096 count=$(( (size < 524288 ? size : 524288) / 4096 )) 2>/dev/null
	[ "$(hash_of "$f" 0 $((0x50000)))" = "$(hash_of $img 0 $((0x50000)))" ] || die "partition too small for image data"
	dd if=/dev/mtd$idx of=/tmp/be5000-mtd$idx-old-bootloader.bin bs=4096 2>/dev/null
	info "old bootloader saved to /tmp/be5000-mtd$idx-old-bootloader.bin - copy it to your PC now"
	info "writing bootloader into mtd$idx '$2' ($(wc -c < $img) bytes)"
	write_verify $idx $img
	rm -f $img
	info "done. Reboot: U-Boot will not find OpenWrt yet and will start the web failsafe on http://192.168.1.1"
}

case "${1:-}" in
	check) cmd_check ;;
	nand) cmd_nand ;;
	calibration) cmd_calibration "${2:-}" ;;
	bootloader) cmd_bootloader "${2:-}" ;;
	*) echo "usage: $0 check | nand | calibration FILE | bootloader FILE"; exit 1 ;;
esac
