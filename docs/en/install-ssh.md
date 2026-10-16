# Installing OpenWrt over SSH

[← README](../../README.md) · [Русский](../ru/install-ssh.md)

> [!IMPORTANT]
> **TL;DR.** Five steps: check → backup → calibration → bootloader → firmware via web failsafe. The script verifies every write by reading it back. No step requires knowing which U-Boot is installed now. [`install.sh`](../../install.sh) runs steps 1–4 in one command; this page lists them one by one.

## Contents

1. [Done when](#done-when)
2. [Step 0. Preparation](#step-0-preparation)
3. [Step 1. Check](#step-1-check)
   - [Does the bootloader support your NAND chip](#does-the-bootloader-support-your-nand-chip)
4. [Step 2. Backup](#step-2-backup)
5. [Step 3. Wi-Fi calibration](#step-3-wi-fi-calibration)
6. [Step 4. Bootloader](#step-4-bootloader)
7. [Step 5. Firmware via web failsafe](#step-5-firmware-via-web-failsafe)
8. [Step 6. First setup](#step-6-first-setup)
9. [If a partition is READ-ONLY](#if-a-partition-is-read-only)
10. [If something goes wrong](#if-something-goes-wrong)

## Done when

- [ ] A backup of all partitions is on the PC, and the `SHA256SUMS` file matches.
- [ ] `be5000-install.sh check` prints `already contains MT7992 calibration`.
- [ ] The router powers on from the wall socket **without UART** and boots OpenWrt.
- [ ] `cat /sys/class/ieee80211/phy0/macaddress` shows the MAC from the router label, not a random one.

## Step 0. Preparation

| What | Why |
|---|---|
| root over SSH | all writes are done from the system installed on the router |
| `ssh`, `scp`, `python3` on the PC | scripts in `scripts/pc/` |
| cable PC ↔ LAN port | web failsafe works only over a cable |
| USB-UART 3.3 V | insurance: if the bootloader write is interrupted, the router can be recovered only over UART |
| [OpenWrt for BE5000](../../firmware/openwrt/) | `firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` in this repository ([about the build](../../firmware/openwrt/README.md)), SHA-256 `2b5ab049…` |

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
R=root@192.168.31.1     # Xiaomi stock firmware; on OpenWrt usually root@192.168.1.1
```

> [!NOTE]
> On a fresh OpenWrt, `scp` needs the `-O` flag: there is no sftp server.

## Step 1. Check

```sh
scp -O scripts/router/be5000-install.sh $R:/tmp/
ssh $R sh /tmp/be5000-install.sh check
```

Example (router already on OpenWrt with the new flash layout):

```
>>> MTD partitions (index name offset size flags; flag 0x400 = writable)
  mtd0  u-boot         off=0x00000000 size=0x0007c000 RO
  mtd1  u-boot-env     off=0x0007c000 size=0x00004000 RO
  mtd2  art            off=0x00080000 size=0x00040000 rw
  mtd3  firmware       off=0x000c0000 size=0x01800000 rw
  mtd4  kernel         off=0x00000000 size=0x003c0000 rw (inside firmware)
  mtd5  rootfs         off=0x003c0000 size=0x01440000 rw (inside firmware)
  mtd6  rootfs_data    off=0x00ac0000 size=0x00d40000 rw (inside firmware)
  mtd7  ubi            off=0x018c0000 size=0x02800000 rw
>>> Kernel log:
  [    1.297809] spi-nand spi0.0: Winbond SPI NAND was found.
  [    1.303181] spi-nand spi0.0: 128 MiB, block size: 128 KiB, page size: 2048, OOB size: 96
  [    3.287615] mtdblock: MTD device 'rootfs' is NAND, please consider using UBI block devices instead.
>>> MTD geometry: page=2048 oob=96 (sysfs) oob=96 (kernel log) erase=131072
>>> Result: vendor=Winbond chip=W25N01KV
  SUPPORTED: the BL2 of be5000-bootloader-w25n01kv.bin knows W25N01KV
  Note: xinyooo v2026.05/06 bootloaders and the X-WRT preloader do NOT know W25N01KV
>>> Detected flash layout: replacement
  bootloader partition: mtd0 'u-boot' size=0x7c000 READ-ONLY
  calibration block 0xA0000: mtd2 'art' +0x20000, already contains MT7992 calibration, rw
```

| Line | What to look at |
|---|---|
| `Detected flash layout` | `stock` is the factory flash layout, `replacement` is the xinyooo/iscle flash layout, `unknown` means stop and open an issue |
| `Result` and `SUPPORTED` | the chip must be in the [BL2 list](technical.md#supported-nand-chips). On `NOT SUPPORTED` stop; on `NOT IDENTIFIED` read the marking on the chip |
| `bootloader partition … READ-ONLY` | step 4 cannot be done from this system, see [READ-ONLY](#if-a-partition-is-read-only) |
| `calibration block … has data` | block `0xA0000` holds unknown data. Stop: the script will not erase it |
| `Factory EEPROM header: 9279` | (stock only) the calibration is in place and can be moved |

### Does the bootloader support your NAND chip

This is the main thing to check **before** writing the bootloader. If BL2 does not know your chip, the router will never boot.

```sh
ssh $R sh /tmp/be5000-install.sh nand
```

```
>>> Kernel log:
  [    1.297809] spi-nand spi0.0: Winbond SPI NAND was found.
  [    1.303181] spi-nand spi0.0: 128 MiB, block size: 128 KiB, page size: 2048, OOB size: 96
  [    3.287615] mtdblock: MTD device 'rootfs' is NAND, please consider using UBI block devices instead.
>>> MTD geometry: page=2048 oob=96 (sysfs) oob=96 (kernel log) erase=131072
>>> Result: vendor=Winbond chip=W25N01KV
  SUPPORTED: the BL2 of be5000-bootloader-w25n01kv.bin knows W25N01KV
  Note: xinyooo v2026.05/06 bootloaders and the X-WRT preloader do NOT know W25N01KV
```

The `bootloader` command runs the same check itself and **does not write** if the chip is not supported. If the chip cannot be identified, it asks you to check the marking and rerun with `BE5000_NAND_OK=1`.

The same by hand, with built-in tools:

```sh
dmesg | grep -iE 'nand|oob|W25N|GD5F|F50L|EM73'   # vendor, OOB size, sometimes model or JEDEC ID
cat /sys/class/mtd/mtd0/oobsize                    # OOB size (can be wrong on stock Xiaomi)
cat /sys/class/mtd/mtd0/writesize                  # page size
```

| Sign | Chip | Our bootloader | xinyooo v2026.05–06 bootloaders, X-WRT preloader |
|---|---|---|---|
| Winbond, page 2048, **OOB 96** or ID `EF AE 21` | W25N01KV | ✅ | ❌ PANIC |
| Winbond, page 2048, **OOB 64** or ID `EF AA 21` | W25N01GV | ✅ | ✅ |
| ESMT, OOB 64 | F50L1G41LB / EM73… | ✅ if the model is in the [list](technical.md#supported-nand-chips) | ✅ if the model is in the list |
| not detected | — | read the marking on the 8-pin chip next to the SoC | — |

> [!NOTE]
> The kernel names W25N01KV and W25N01GV the same way: "Winbond SPI NAND, 128 MiB". You can tell them apart only by OOB (96 vs 64 bytes) or by JEDEC ID.

> [!WARNING]
> The stock Xiaomi kernel reports 64 in `/sys/class/mtd/mtd0/oobsize` even for W25N01KV. The kernel log has the right OOB size. The script takes it from there and does not treat 64 from sysfs alone as proof: the chip stays unidentified, and writing the bootloader then needs a marking check and `BE5000_NAND_OK=1`.

## Step 2. Backup

```sh
sh scripts/pc/be5000-backup.sh $R
```

The script downloads each `/dev/mtdN` to the PC and checks SHA-256 against the router. The `be5000-backup-<date>/` folder will contain `mtdN-<name>.bin`, `proc_mtd.txt`, `dmesg.txt` and `SHA256SUMS`.

> [!WARNING]
> The backup contains your calibration, MAC addresses and serial number. Do not publish it. Without it you cannot return to the Xiaomi firmware.

## Step 3. Wi-Fi calibration

```sh
ssh $R sh /tmp/be5000-install.sh calibration
```

```
>>> calibration built from Factory: Wi-Fi base MAC 50:4f:3b:7a:30:76, md5 …
>>> writing calibration into mtd1 'u-boot-env' at +0x20000 (whole partition rewritten, other blocks unchanged)
>>> mtd1 written and verified (…)
```

What the command does:
1. Finds the stock Factory partition (`0x180000`) and reads it into `/tmp/be5000-Factory.bin`.
2. Checks the `92 79` signature (MT7992) and the base MAC. Stops if the partition has data after the first 7680 EEPROM bytes.
3. Builds a 128 KB block: EEPROM + `FF`.
4. Finds the partition that contains `0xA0000` (`u-boot-env` on stock, `art` on the new flash layout), makes sure the block is empty, rewrites the partition with the changed second block and verifies it by reading it back.

| Case | Command |
|---|---|
| Xiaomi stock firmware, Factory present | `be5000-install.sh calibration` |
| Calibration already at `0xA0000` (OpenWrt xinyooo/iscle) | the same command answers `calibration already in place` |
| Factory already overwritten, you have a backup | `scp -O Factory.bin $R:/tmp/` and `be5000-install.sh calibration /tmp/Factory.bin` (4 MB dump or a ready 128 KB block) |
| OpenWrt in RAM (initramfs) on a stock flash | the command finds the stock `Factory` data inside `firmware` and writes the block to `art`: the partition is writable in this build |

On a PC the same is done by `python3 scripts/pc/be5000-calibration.py Factory.bin calibration.bin`.

## Step 4. Bootloader

```sh
scp -O firmware/bootloader/be5000-bootloader-w25n01kv.bin $R:/tmp/
ssh $R sh /tmp/be5000-install.sh bootloader /tmp/be5000-bootloader-w25n01kv.bin
scp -O $R:/tmp/be5000-mtd0-old-bootloader.bin be5000-backup-*/   # old bootloader to the PC
```

The script checks the FIP header of the image, saves the old bootloader to `/tmp`, writes the new one and verifies it by reading it back.

> [!CAUTION]
> From this point until step 5, **do not cut power** until the script prints `written and verified`. If the write was interrupted, see [UART recovery](recovery-uart.md).

## Step 5. Firmware via web failsafe

1. Reboot the router (`ssh $R reboot` or power off and on).
2. U-Boot tries to boot OpenWrt from the `firmware` partition. It still holds stock data, so the boot fails, and the recovery page comes up in a few seconds.
3. Connect the PC to a LAN port with a cable and set its address by hand: `192.168.1.10`, netmask `255.255.255.0`.
4. Open `http://192.168.1.1`, select [`firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`](../../firmware/openwrt/), click **Upload**.
5. On the confirmation page check the MD5 and the size (`11272464` bytes) and click **Proceed**. U-Boot erases its `firmware` partition (64 MiB, including the `ubi` settings partition) and writes the image. This takes **3–5 minutes**; the page may stop responding. Do not power off. The router then reboots into OpenWrt.
6. On the first boot OpenWrt creates the `rootfs_data` volume for settings in the `ubi` partition. The log shows `- creating rootfs_data UBI volume -` and `mount_root: switching to ubifs overlay`.

> [!TIP]
> **macOS:** if `192.168.1.1` stops opening after the router reboots, macOS has lost the route on that interface. Set the address in "Settings → Network → (adapter) → Details → TCP/IP → Manually", not with `ifconfig alias`.

## Step 6. First setup

```sh
ssh root@192.168.1.1
passwd
cat /sys/class/ieee80211/phy0/macaddress   # MAC from the label, not a random one
```

Wi-Fi is off by default. In LuCI (`http://192.168.1.1`) set the country, network name and password, then enable the radio.

Further updates are installed with the regular OpenWrt `sysupgrade`.

## If a partition is READ-ONLY

| Where | What to do |
|---|---|
| OpenWrt from this repository, installed or in RAM | `art` is writable (tested), so step 3 works. `u-boot` is read-only: the bootloader is written over [UART](recovery-uart.md) |
| OpenWrt iscle/xinyooo | `u-boot` and `art` are read-only there. Option without opening the case: `kmod-mtd-rw` and `insmod mtd-rw i_want_a_brick=1` (not tested). Reliable option: boot the initramfs from this repository over TFTP for the calibration, the bootloader over [UART](recovery-uart.md) |
| Xiaomi stock firmware | the bootloader and calibration partitions are writable on stock (tested), so this case does not occur. If they still show `READ-ONLY`, use [UART](recovery-uart.md), then step 5 of this guide |

## If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| After step 4 the router does not appear on the network, the LED does not change | the bootloader does not start | [UART](recovery-uart.md) |
| `192.168.1.1` does not open, but the router is alive | the PC has no address in `192.168.1.0/24`, or the cable is in the 2.5G port | set the PC to `192.168.1.10/24`, use a gigabit LAN port |
| failsafe says `not a valid firmware image for this board` | wrong file uploaded | you need `squashfs-sysupgrade.bin` for `xiaomi_be5000` |
| Wi-Fi has a random MAC, `dmesg` shows `eeprom load fail` | no calibration at `0xA0000` | repeat step 3: `be5000-install.sh calibration`, with your `Factory.bin` or `calibration.bin` from the backup if the stock data is gone |
