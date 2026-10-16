#!/bin/sh
# One-command install from the PC: image download, flash check, full backup,
# Wi-Fi calibration, bootloader. Asks for the router password once and asks
# YES before writing anything.
#   sh install.sh [root@192.168.31.1]
# Needs ssh and curl on the PC. Works with any scp/sftp-less router.
set -eu

R=${1:-root@192.168.31.1}
cd "$(dirname "$0")"
BL=firmware/bootloader/be5000-bootloader-w25n01kv.bin
IMG=openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin
REL=https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest/download
OUT=be5000-backup-$(date +%Y%m%d-%H%M%S)
CTL=${TMPDIR:-/tmp}/be5000-ssh-$$
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=600"
SSH="ssh $SSH_OPTS"

for t in ssh curl; do command -v $t >/dev/null 2>&1 || { echo "STOP: $t is not installed on this computer" >&2; exit 1; }; done

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
upload() { $SSH "$R" "cat > /tmp/$(basename "$1")" < "$1"; }   # no scp: works without sftp
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
trap 'ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true' EXIT

step "1/6 OpenWrt image from the latest release"
mkdir -p firmware/openwrt
curl -fsL -o firmware/openwrt/SHA256SUMS "$REL/SHA256SUMS" || fail "could not download SHA256SUMS from the release; check the internet connection and run again"
want=$(grep " $IMG\$" firmware/openwrt/SHA256SUMS | cut -d' ' -f1)
[ -n "$want" ] || fail "$IMG is not listed in the release SHA256SUMS; open an issue"
if [ -f "firmware/openwrt/$IMG" ] && [ "$(sha256 "firmware/openwrt/$IMG")" = "$want" ]; then
	echo "firmware/openwrt/$IMG: already downloaded, checksum OK"
else
	rm -f "firmware/openwrt/$IMG"
	curl -fL --progress-bar -o "firmware/openwrt/$IMG.part" "$REL/$IMG" || fail "download failed; check the internet connection and run again"
	[ "$(sha256 "firmware/openwrt/$IMG.part")" = "$want" ] || { rm -f "firmware/openwrt/$IMG.part"; fail "the downloaded image does not match SHA256SUMS; run again"; }
	mv "firmware/openwrt/$IMG.part" "firmware/openwrt/$IMG"
	echo "firmware/openwrt/$IMG: downloaded, checksum OK"
fi

step "2/6 Connecting to $R (enter the router password once)"
$SSH "$R" true || fail "could not SSH into $R. Check the address and password: sh install.sh root@ADDRESS"
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
	[ "${BE5000_NAND_OK:-}" = 1 ] || fail "the flash chip was not identified. Read the marking on the chip, check it with scripts/pc/be5000-check-bootloader.py (see docs/en/install-ssh.md), then run: BE5000_NAND_OK=1 sh install.sh $R"
fi
if grep -q 'Detected flash layout: unknown' "$C"; then
	fail "unknown flash layout. Open an issue with $C"
fi
if grep -q 'bootloader partition:.*READ-ONLY' "$C"; then
	fail "this system cannot write the bootloader (partition read-only). On OpenWrt xinyooo/iscle you do not need it: install the image with sysupgrade -n (see README). Otherwise see docs/en/install-ssh.md, READ-ONLY"
fi
if grep -q 'calibration block.*has data' "$C"; then
	fail "block 0xA0000 holds unknown data and the script never erases it. Open an issue with $C"
fi

step "4/6 Backing up the whole flash to $OUT (a few minutes)"
sh scripts/pc/be5000-backup.sh "$R" "$OUT" || fail "backup verification failed, run it again"

echo
echo "Next step writes to flash. Backup: $(pwd)/$OUT - keep it somewhere safe."
printf 'Type YES and press Enter to continue: '
read -r ans || ans=
[ "$ans" = YES ] || fail "cancelled, nothing was written"

step "5/6 Wi-Fi calibration"
$SSH "$R" sh /tmp/be5000-install.sh calibration || fail "calibration was not written. The bootloader is untouched, the router works as before"

step "6/6 Bootloader (do not power off!)"
$SSH "$R" "BE5000_NAND_OK=${BE5000_NAND_OK:-} sh /tmp/be5000-install.sh bootloader /tmp/$(basename "$BL")" \
	|| fail "bootloader step failed. If the output above mentions 'mtd write' or 'written', do NOT reboot the router and open an issue; otherwise nothing was written"
$SSH "$R" 'cat /tmp/be5000-mtd*-old-bootloader.bin' > "$OUT/old-bootloader.bin" 2>/dev/null || true
$SSH "$R" reboot || true

cat <<EOT

Done, the router is rebooting. Now flash the firmware from a browser:
  1. Set a static address on the PC's wired adapter: IP 192.168.1.10, netmask 255.255.255.0.
  2. After a minute, open http://192.168.1.1
  3. Choose the file $(pwd)/firmware/openwrt/$IMG,
     click Upload, then Proceed. Wait 5 minutes, do not power off.
  4. Switch the PC back to automatic addressing (DHCP) and open http://192.168.1.1 again.
EOT
