#!/bin/sh
# One-command install from the PC: NAND check, full backup, Wi-Fi calibration,
# bootloader. Asks for the router password once and asks YES before writing.
#   sh install.sh [root@192.168.31.1]
set -eu

R=${1:-root@192.168.31.1}
cd "$(dirname "$0")"
BL=firmware/bootloader/be5000-bootloader-w25n01kv.bin
OUT=be5000-backup-$(date +%Y%m%d-%H%M%S)
CTL=${TMPDIR:-/tmp}/be5000-ssh-$$
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=600"
SSH="ssh $SSH_OPTS"
SCP="scp -O $SSH_OPTS"

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nSTOP: %s\nNo harm done: the router is untouched unless stated otherwise.\n' "$*" >&2; exit 1; }
trap 'ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true' EXIT

step "1/5 Connecting to $R (enter the router password once)"
$SSH "$R" true || fail "could not SSH into $R. Check the address and password: sh install.sh root@ADDRESS"
$SCP scripts/router/be5000-install.sh "$BL" "$R:/tmp/" >/dev/null

step "2/5 Checking the flash chip"
$SSH "$R" sh /tmp/be5000-install.sh nand | tee "/tmp/be5000-nand-$$.txt"
grep -q SUPPORTED: "/tmp/be5000-nand-$$.txt" && ! grep -q 'NOT SUPPORTED' "/tmp/be5000-nand-$$.txt" \
	|| fail "the bootloader does not support your flash chip, or the chip was not detected. Open an issue with the output above"
rm -f "/tmp/be5000-nand-$$.txt"

step "3/5 Backing up the whole flash to $OUT (a few minutes)"
sh scripts/pc/be5000-backup.sh "$R" "$OUT" || fail "backup verification failed, run it again"

echo
echo "Next step writes to flash. Backup: $(pwd)/$OUT - keep it somewhere safe."
printf 'Type YES and press Enter to continue: '
read -r ans
[ "$ans" = YES ] || fail "cancelled"

step "4/5 Wi-Fi calibration"
$SSH "$R" sh /tmp/be5000-install.sh calibration || fail "calibration was not written. The bootloader is untouched, the router works as before"

step "5/5 Bootloader (do not power off!)"
$SSH "$R" sh /tmp/be5000-install.sh bootloader "/tmp/$(basename "$BL")" \
	|| fail "bootloader was not written. Do NOT reboot the router; open an issue with the output above"
$SCP "$R:/tmp/be5000-mtd*-old-bootloader.bin" "$OUT/" >/dev/null 2>&1 || true
$SSH "$R" reboot || true

cat <<EOF

Done, the router is rebooting. Now flash the firmware from a browser:
  1. Connect the PC by cable to a LAN port of the router (not the 2.5G port).
  2. Set a static address on the PC: IP 192.168.1.10, netmask 255.255.255.0.
  3. After a minute, open http://192.168.1.1
  4. Choose the file $(pwd)/firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin,
     click Upload, then Proceed. Wait 5 minutes, do not power off.
  5. Switch the PC back to automatic addressing (DHCP) and open http://192.168.1.1 again.
EOF
