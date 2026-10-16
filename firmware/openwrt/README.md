# OpenWrt images

Build of OpenWrt `main` (`r36539+835-98bc30d154`, Linux 6.18.55) with [iscle](https://github.com/iscle/openwrt)'s BE5000 series and the fixes from this repository. Installed and tested on the reference router (W25N01KV): web failsafe install, first boot, warm and cold reboots, `sysupgrade` with kept settings.

| File | Size | Use |
|---|---|---|
| `openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` | 11272464 | Install: upload in the U-Boot web failsafe (`http://192.168.1.1`) or `sysupgrade` from OpenWrt. Raw image of the `firmware` partition: FIT kernel + squashfs |
| `openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin` | 10913816 | RAM-only system for recovery and tests: `tftpboot 0x84000000 …; bootm 0x84000000` in U-Boot. Does not touch flash |

Checksums: [`SHA256SUMS`](SHA256SUMS).

## Speed

OpenSpeedTest from a MacBook (2x2, 160 MHz, about −40 dBm) to a PC on the wired LAN, through the BE5000:

![OpenSpeedTest: 1757 Mbit/s download, 1643 Mbit/s upload](../../images/openspeedtest-be5000.png)

| Test | Download | Upload |
|---|---|---|
| OpenSpeedTest in the browser | 1757 Mbit/s | 1643 Mbit/s |
| 8 parallel HTTP streams, 5 minutes | 1348 Mbit/s | 1384 Mbit/s |

## Flash layout

| Partition | Offset, size | Contents |
|---|---|---|
| `firmware` | `0xC0000`, 24 MiB | raw FIT (kernel + squashfs), the bootloader boots it as is |
| `ubi` | `0x18C0000`, 40 MiB | UBI with the `rootfs_data` volume (UBIFS): settings and installed packages |

- **Settings in UBI:** JFFS2 programs page 0 of an erase block twice (cleanmarker in OOB, then data), and the on-die ECC of W25N01KV corrupts such pages ([issue #1](https://github.com/pabragin/xiaomi-be5000-openwrt/issues/1)). UBI programs each page once.
- **First boot:** the `rootfs_data` volume is created in the empty `ubi` partition.
- **sysupgrade:** writes the FIT, recreates `rootfs_data` and saves the kept settings there.

## Differences from iscle's builds

- **Settings in UBI** instead of JFFS2 (see above).
- **PCIe at 5 GT/s:** the AN7563 root ports train at 2.5 GT/s and stay there; the kernel retrains both links to 5 GT/s, as the Xiaomi stock kernel does (`mt7512_pcie_rc0/rc1_retrain`). At 2.5 GT/s x1 the Wi-Fi TX DMA capped downloads at about 1 Gbit/s; with 5 GT/s a 2x2 160 MHz client downloads ~1.45 Gbit/s.
- **Upload on both NPU cores:** core 1 parsed every received frame (~5400 cycles) and capped Wi-Fi → Ethernet at ~120k frames/s. Core 0 now reads the RX descriptor, checks security and PN and parses the frame, then hands a 32-byte record to core 1 through a queue in shared SRAM; core 1 queues to the PPE or delivers to Linux. Core 1 load under upload drops from 84% to 31%. A boot probe falls back to single-core mode if the cores do not share the queue memory.
- **Reboot:** the Wi-Fi chip, QDMA and NPU are stopped on shutdown, so a warm reboot does not loop.
- **Watchdog:** the hardware watchdog works (`airoha,en7523-wdt`).
- **NPU:** fixes for encrypted A-MSDU and a faster receive path in the NPU firmware.
- **Wi-Fi MAC without calibration:** if `art` has no calibration, the driver uses the MediaTek default EEPROM with the same MAC on every unit. On first boot each radio then gets a random `macaddr_base`, kept in `/etc/config/wireless`.

## Notes

- **Requires** the bootloader from [`../bootloader/`](../bootloader/) (replacement flash layout, calibration at `0xA0000`). Not a Xiaomi stock web-upgrade image.
- **Upgrading from an image with JFFS2 settings** (iscle, xinyooo): use `sysupgrade -n`. The old system would append the settings as JFFS2 inside `firmware`, where this image does not look.
- **Defaults:** LAN `192.168.1.1`, DHCP server on, root without password, Wi-Fi disabled.
- **Source and licence:** OpenWrt is GPL-2.0. The patch series on top of OpenWrt `27f0f3ebd1` and the build config (`diffconfig`) are attached to the [release](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/tag/be5000-openwrt-20261016).
