#!/bin/sh
# One-command install from the PC: image download, flash check, full backup,
# Wi-Fi calibration, bootloader. Asks for the router password once and asks
# YES before writing anything.
#   sh install.sh [root@192.168.31.1] [plain|full]
# The OpenWrt image itself is installed from a browser after this script. The script
# gets both images ready: plain and full (with VPN: AmneziaWG, Xray, zapret, DNS over
# HTTPS), or only one with plain|full; BE5000_IMAGE=path uses an image you downloaded.
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
SSH_BASE="-o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TAG=be5000-install-$$
# The password is asked once. macOS/Linux/WSL: all commands share one SSH connection.
# Windows (Git Bash, MSYS, Cygwin) cannot pass descriptors to a shared connection
# ("mux_client_request_session: send fds failed"): a one-time key is put on the router
# after the password and removed at the end.
# BE5000_SSH_KEY=1 uses the one-time key on any system.
case $(uname -s)${BE5000_SSH_KEY:+key} in
	*_NT*|MINGW*|MSYS*|CYGWIN*|*key)   # MINGW64_NT-…, UCRT64_NT-…, CLANG64_NT-…
		KEY=${TMPDIR:-/tmp}/$TAG
		export SSH_OPTS="$SSH_BASE -i $KEY -o IdentitiesOnly=yes" ;;
	*)
		KEY=
		export SSH_OPTS="$SSH_BASE -o ControlMaster=auto -o ControlPath=${TMPDIR:-/tmp}/be5000-ssh-$$ -o ControlPersist=600" ;;
esac
SSH="ssh $SSH_OPTS"

for t in ssh curl; do command -v $t >/dev/null 2>&1 || { echo "STOP: $t is not installed on this computer" >&2; exit 1; }; done

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
upload() { $SSH "$R" "cat > /tmp/$(basename "$1")" < "$1"; }   # no scp: works without sftp
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
drop_key() {   # the one-time key off the router and the PC
	[ -n "$KEY" ] || return 0
	[ -f "$KEY" ] && $SSH "$R" "sed -i '/$TAG/d' /etc/dropbear/authorized_keys /root/.ssh/authorized_keys 2>/dev/null; true" 2>/dev/null
	rm -f "$KEY" "$KEY.pub"
}
trap 'drop_key; [ -n "$KEY" ] || ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true' EXIT

step "1/6 OpenWrt images for the browser step at the end"
# install.sh itself writes only the calibration and the bootloader; the OpenWrt image
# is uploaded from a browser after it. Images downloaded by hand are used as is: put
# them into firmware/openwrt/ (with SHA256SUMS from the same release next to them).
mkdir -p firmware/openwrt
SUMS=firmware/openwrt/SHA256SUMS
FRESH=
if curl -fsL -m 30 -o "$SUMS.new" "$REL/SHA256SUMS"; then
	mv "$SUMS.new" "$SUMS"; FRESH=1
else
	rm -f "$SUMS.new"
	[ -f "$SUMS" ] && echo "could not download SHA256SUMS, using $SUMS from disk"
fi

# check_image FILE: 0 - good, 1 - outdated (deleted, download again); stops on a bad file
check_image() {
	want=
	for sf in "$SUMS" "$(dirname "$1")/SHA256SUMS"; do
		[ -z "$want" ] && [ -f "$sf" ] && want=$(grep " $(basename "$1")\$" "$sf" | cut -d' ' -f1)
	done
	if [ -z "$want" ]; then
		grep -aq 'xiaomi,be5000' "$1" || fail "$1 is not an OpenWrt image for the Xiaomi BE5000"
		echo "$1: image for the BE5000, checksum NOT checked (no SHA256SUMS for it)"
	elif [ "$(sha256 "$1")" = "$want" ]; then
		echo "$1: checksum OK"
	elif [ -z "${BE5000_IMAGE:-}" ] && [ -n "$FRESH" ]; then
		echo "$1: not the latest release, downloading the new image"
		rm -f "$1"; return 1
	else
		fail "$1 does not match SHA256SUMS: the file is damaged or from another release. Download it again, or put the SHA256SUMS of its own release next to it"
	fi
}

# get_image NAME: a checked firmware/openwrt/NAME, from disk or downloaded; 1 if not possible
get_image() {
	f=firmware/openwrt/$1
	[ -f "$f" ] && check_image "$f" && return 0
	[ -f "$SUMS" ] || { echo "$1: could not download SHA256SUMS from the release"; return 1; }
	want=$(grep " $1\$" "$SUMS" | cut -d' ' -f1)
	[ -n "$want" ] || { echo "$1: not listed in $SUMS"; return 1; }
	curl -fL --progress-bar -o "$f.part" "$REL/$1" || { rm -f "$f.part"; echo "$1: download failed"; return 1; }
	[ "$(sha256 "$f.part")" = "$want" ] || { rm -f "$f.part"; echo "$1: the download does not match SHA256SUMS"; return 1; }
	mv "$f.part" "$f"
	echo "$f: downloaded, checksum OK"
}

show() { case $1 in /*|?:*) echo "$1" ;; *) echo "$HERE/$1" ;; esac; }
IMAGES=
if [ -n "${BE5000_IMAGE:-}" ]; then
	[ -f "$BE5000_IMAGE" ] || fail "BE5000_IMAGE=$BE5000_IMAGE: no such file"
	check_image "$BE5000_IMAGE"
	IMAGES="     $(show "$BE5000_IMAGE")"
else
	case $VARIANT in plain) want_list=$IMG_PLAIN ;; full) want_list=$IMG_FULL ;; *) want_list="$IMG_PLAIN $IMG_FULL" ;; esac
	for name in $want_list; do
		get_image "$name" || continue
		[ "$name" = "$IMG_FULL" ] && label="full, with VPN (AmneziaWG, Xray, zapret, DNS over HTTPS)" || label="plain"
		IMAGES="$IMAGES
     $label: $(show "firmware/openwrt/$name")"
	done
	[ -n "$IMAGES" ] || fail "no OpenWrt image is ready. Download $IMG_PLAIN or $IMG_FULL (and SHA256SUMS) from https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest by hand, put them into firmware/openwrt/ and run again"
fi

step "2/6 Connecting to $R (enter the router password once)"
SSH_FAIL="could not SSH into $R. Check the address and the root password (after XMiR-Patcher it is root, not the web interface password): sh install.sh root@ADDRESS. If the router already rebooted after a previous run, continue with the browser step from the README"
use_key() {   # one-time key: password once, then key auth for every command
	command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not installed on this computer"
	KEY=${TMPDIR:-/tmp}/$TAG
	rm -f "$KEY" "$KEY.pub"
	ssh-keygen -q -t ed25519 -N "" -C "$TAG" -f "$KEY" || fail "could not create a one-time SSH key"
	ssh $SSH_BASE "$R" 'mkdir -p /etc/dropbear && k=$(cat) && for f in /etc/dropbear/authorized_keys /root/.ssh/authorized_keys; do [ -d ${f%/*} ] || continue; echo "$k" >> $f; chmod 600 $f; done' < "$KEY.pub" || fail "$SSH_FAIL"
	export SSH_OPTS="$SSH_BASE -i $KEY -o IdentitiesOnly=yes"; SSH="ssh $SSH_OPTS"
	if ! $SSH -o BatchMode=yes "$R" true 2>/dev/null; then
		echo "the router did not accept the one-time key: it will ask for the password at every step"
		rm -f "$KEY" "$KEY.pub"; KEY=
		export SSH_OPTS="$SSH_BASE"; SSH="ssh $SSH_OPTS"
	fi
}
if [ -n "$KEY" ]; then
	use_key
else
	$SSH "$R" true || fail "$SSH_FAIL"
	# the shared connection must work without asking again; if not (some Windows ssh builds), use the key
	if ! $SSH -o BatchMode=yes "$R" true 2>/dev/null; then
		echo "the shared SSH connection does not work here, using a one-time key instead (the password is asked once more)"
		ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true
		use_key
	fi
fi
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
if [ -n "$KEY" ]; then
	$SSH "$R" "sed -i '/$TAG/d' /etc/dropbear/authorized_keys /root/.ssh/authorized_keys 2>/dev/null; reboot" || true
	rm -f "$KEY" "$KEY.pub"
else
	$SSH "$R" reboot || true
fi

cat <<EOT

Done, the router is rebooting. Now flash the firmware from a browser:
  1. Set a static address on the PC's wired adapter: IP 192.168.1.10, netmask 255.255.255.0.
  2. After a minute, open http://192.168.1.1
  3. Choose one of the images:$IMAGES
     click Upload, then Proceed. Wait 5 minutes, do not power off.
  4. Switch the PC back to automatic addressing (DHCP) and open http://192.168.1.1 again.
EOT
