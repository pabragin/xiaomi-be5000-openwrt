#!/bin/sh
# One-command install from the PC: image download, flash check, full backup,
# Wi-Fi calibration, bootloader. Asks for the router password once and asks
# YES before writing anything.
#   sh install.sh [root@192.168.31.1] [plain|full]
# plain: the plain image; full: with VPN (AmneziaWG, Xray, zapret, DNS over HTTPS).
# Without the second argument the script asks; BE5000_IMAGE=path uses an image you downloaded.
# Needs ssh and curl on the PC. Works with any scp/sftp-less router.
set -eu

R=${1:-root@192.168.31.1}
cd "$(dirname "$0")"
BL=firmware/bootloader/be5000-bootloader-w25n01kv.bin
IMG_PLAIN=openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin
IMG_FULL=openwrt-airoha-an7563-xiaomi_be5000-full-squashfs-sysupgrade.bin
VARIANT=${2:-}
case $VARIANT in ""|plain|full) ;; *) echo "usage: sh install.sh [root@ADDRESS] [plain|full]" >&2; exit 1 ;; esac
REL=https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest/download
OUT=be5000-backup-$(date +%Y%m%d-%H%M%S)
HERE=$(pwd -W 2>/dev/null || pwd)   # Git Bash on Windows: C:/... instead of /c/...
CTL=${TMPDIR:-/tmp}/be5000-ssh-$$
export SSH_OPTS="-o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=600"
SSH="ssh $SSH_OPTS"

for t in ssh curl; do command -v $t >/dev/null 2>&1 || { echo "STOP: $t is not installed on this computer" >&2; exit 1; }; done

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
upload() { $SSH "$R" "cat > /tmp/$(basename "$1")" < "$1"; }   # no scp: works without sftp
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
trap 'ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true' EXIT

step "1/6 OpenWrt image"
# An image downloaded by hand is used as is: put it into firmware/openwrt/ (both the
# plain and the -full- sysupgrade image work) or pass its path in BE5000_IMAGE.
# SHA256SUMS from the release next to it lets the script check it without internet.
mkdir -p firmware/openwrt
SUMS=firmware/openwrt/SHA256SUMS
FRESH=
if curl -fsL -m 30 -o "$SUMS.new" "$REL/SHA256SUMS"; then
	mv "$SUMS.new" "$SUMS"; FRESH=1
else
	rm -f "$SUMS.new"
	[ -f "$SUMS" ] && echo "could not download SHA256SUMS, using $SUMS from disk"
fi
FILE=${BE5000_IMAGE:-}
if [ -z "$FILE" ] && [ -z "$VARIANT" ]; then
	# one image already in firmware/openwrt/: take it; otherwise ask
	n=0
	for f in "firmware/openwrt/$IMG_PLAIN" "firmware/openwrt/$IMG_FULL"; do [ -f "$f" ] && { n=$((n + 1)); one=$f; }; done
	if [ $n = 1 ]; then
		FILE=$one
		case $one in *-full-*) VARIANT=full ;; *) VARIANT=plain ;; esac
	elif [ -t 0 ]; then
		printf 'Which OpenWrt image?\n  1 - plain\n  2 - full: with VPN (AmneziaWG, Xray, zapret, DNS over HTTPS)\nChoose 1 or 2 [1]: '
		read -r ans || ans=
		case $ans in *2*) VARIANT=full ;; *) VARIANT=plain ;; esac
	else
		VARIANT=plain
	fi
fi
[ "$VARIANT" = full ] && IMG=$IMG_FULL || IMG=$IMG_PLAIN
[ -n "$FILE" ] || { [ -f "firmware/openwrt/$IMG" ] && FILE=firmware/openwrt/$IMG; }
[ -z "$FILE" ] || [ -f "$FILE" ] || fail "BE5000_IMAGE=$FILE: no such file"
if [ -n "$FILE" ]; then
	want=
	for sf in "$SUMS" "$(dirname "$FILE")/SHA256SUMS"; do
		[ -z "$want" ] && [ -f "$sf" ] && want=$(grep " $(basename "$FILE")\$" "$sf" | cut -d' ' -f1)
	done
	if [ -z "$want" ]; then
		grep -aq 'xiaomi,be5000' "$FILE" || fail "$FILE is not an OpenWrt image for the Xiaomi BE5000"
		echo "$FILE: image for the BE5000, checksum NOT checked (no SHA256SUMS for it)"
	elif [ "$(sha256 "$FILE")" = "$want" ]; then
		echo "$FILE: checksum OK"
	elif [ -z "${BE5000_IMAGE:-}" ] && [ -n "$FRESH" ]; then
		echo "$FILE: not the latest release, downloading the new image"
		rm -f "$FILE"; FILE=
	else
		fail "$FILE does not match $SUMS: the file is damaged or from another release. Download the image again, or put the SHA256SUMS of its own release next to it"
	fi
fi
if [ -z "$FILE" ]; then
	[ -f "$SUMS" ] || fail "could not download SHA256SUMS from the release. Download $IMG (and SHA256SUMS) from https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest by hand, put them into firmware/openwrt/ and run again"
	want=$(grep " $IMG\$" "$SUMS" | cut -d' ' -f1)
	[ -n "$want" ] || fail "$IMG is not listed in $SUMS; open an issue"
	FILE=firmware/openwrt/$IMG
	curl -fL --progress-bar -o "$FILE.part" "$REL/$IMG" || fail "download failed. Download $IMG from https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest by hand, put it into firmware/openwrt/ and run again"
	[ "$(sha256 "$FILE.part")" = "$want" ] || { rm -f "$FILE.part"; fail "the downloaded image does not match SHA256SUMS; run again"; }
	mv "$FILE.part" "$FILE"
	echo "$FILE: downloaded, checksum OK"
fi
case $FILE in /*|?:*) SHOW=$FILE ;; *) SHOW=$HERE/$FILE ;; esac

step "2/6 Connecting to $R (enter the router password once)"
$SSH "$R" true || fail "could not SSH into $R. Check the address and password: sh install.sh root@ADDRESS. If the router already rebooted after a previous run, continue with the browser step from the README"
upload scripts/router/be5000-install.sh
upload "$BL"

step "3/6 Checking the flash chip and the partitions"
mkdir -p "$OUT"
C=$OUT/be5000-check.txt
$SSH "$R" sh /tmp/be5000-install.sh check > "$C" || { cat "$C"; fail "the check failed on the router, see above"; }
cat "$C"
[ -s "$C" ] || fail "the check printed nothing; run it by hand: ssh $R sh /tmp/be5000-install.sh check"
if grep -q 'NOT SUPPORTED' "$C"; then
	fail "the bootloader does not support your flash chip; writing it would brick the router. Open an issue with $C"
fi
if ! grep -q '^  SUPPORTED:' "$C"; then
	[ "${BE5000_NAND_OK:-}" = 1 ] || fail "the flash chip was not identified. First reboot the router and run again: the kernel log it is read from may have rotated. If it still fails, read the marking on the chip, check it with scripts/pc/be5000-check-bootloader.py (see docs/en/install-ssh.md), then run: BE5000_NAND_OK=1 sh install.sh $R"
fi
if grep -q 'Detected flash layout: unknown' "$C"; then
	fail "unknown flash layout. Open an issue with $C"
fi
if grep -q 'bootloader partition:.*READ-ONLY' "$C"; then
	fail "this system cannot write the bootloader (partition read-only). On OpenWrt xinyooo/iscle you do not need it: install the image with sysupgrade -n (see README). Otherwise see docs/en/install-ssh.md, READ-ONLY"
fi
if grep -q 'bootloader partition: not found' "$C"; then
	fail "no partition starts at flash offset 0, so the bootloader cannot be written from this system. Open an issue with $C"
fi
if grep -q 'calibration block.*READ-ONLY' "$C"; then
	fail "the calibration partition is read-only in this system, see docs/en/install-ssh.md, READ-ONLY"
fi
if grep -q 'calibration block.*has data' "$C"; then
	fail "block 0xA0000 holds unknown data and the script never erases it. Open an issue with $C"
fi

step "4/6 Backing up the whole flash to $OUT (a few minutes)"
sh scripts/pc/be5000-backup.sh "$R" "$OUT" || fail "backup failed. If the output above shows an I/O error on a partition, the flash has a bad block there: open an issue with the output; otherwise run again"

echo
echo "Next step writes to flash. Backup: $HERE/$OUT - keep it somewhere safe."
printf 'Type YES and press Enter to continue: '
read -r ans || ans=
[ "$ans" = YES ] || fail "cancelled, nothing was written"

step "5/6 Wi-Fi calibration"
$SSH "$R" sh /tmp/be5000-install.sh calibration || fail "calibration step failed. If the output above contains 'writing calibration', do NOT reboot or power off the router: run sh install.sh again right away, it writes the block again from the copy saved before the first attempt. Otherwise nothing was written and the router works as before"

step "6/6 Bootloader (do not power off!)"
$SSH "$R" "BE5000_NAND_OK=${BE5000_NAND_OK:-} sh /tmp/be5000-install.sh bootloader /tmp/$(basename "$BL")" \
	|| fail "bootloader step failed. If the output above contains 'writing bootloader', do NOT reboot or power off the router: run sh install.sh again right away, it writes the bootloader again; if that fails too, open an issue with the output. Otherwise nothing was written"
$SSH "$R" 'cat /tmp/be5000-mtd*-old-bootloader.bin' > "$OUT/old-bootloader.bin" 2>/dev/null || true
$SSH "$R" reboot || true

cat <<EOT

Done, the router is rebooting. Now flash the firmware from a browser:
  1. Set a static address on the PC's wired adapter: IP 192.168.1.10, netmask 255.255.255.0.
  2. After a minute, open http://192.168.1.1
  3. Choose the file $SHOW,
     click Upload, then Proceed. Wait 5 minutes, do not power off.
  4. Switch the PC back to automatic addressing (DHCP) and open http://192.168.1.1 again.
EOT
