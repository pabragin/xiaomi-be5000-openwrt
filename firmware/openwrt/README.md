# OpenWrt images

The images are not in git: download them from the [latest release](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest) (`install.sh` does it). Build: OpenWrt `main` (`r36539+844-98bc30d154`, Linux 6.18.55, mt76 2026-10-08) with [iscle](https://github.com/iscle/openwrt)'s BE5000 series and the fixes from this repository. Tested on the reference router (W25N01KV): `sysupgrade` with kept settings, also from the 40 MiB layout of be5000-openwrt-20261017 with the stock data still behind it, warm and cold reboots. Not tested with this image yet: a web failsafe install from stock (the first boot that formats the settings partition).

| Release file | Use |
|---|---|
| `openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` | Install: upload in the U-Boot web failsafe (`http://192.168.1.1`) or `sysupgrade` from OpenWrt. Raw image of the `firmware` partition: FIT kernel + squashfs |
| `openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin` | RAM-only system for recovery and tests: `tftpboot 0x84000000 …; bootm 0x84000000` in U-Boot. Does not touch flash |
| `SHA256SUMS` | checksums of the release files |
| `be5000-openwrt-source-patches.tar.gz`, `diffconfig` | the patch series and the build config of this build |

What the build changes compared to iscle's, the flash layout, PCIe and the speed tests: [docs/en/technical.md](../../docs/en/technical.md#what-this-build-changes).

- **Requires** the bootloader from [`../bootloader/`](../bootloader/) (replacement flash layout, calibration at `0xA0000`). Not a Xiaomi stock web-upgrade image.
- **Upgrading from an image with JFFS2 settings** (iscle, xinyooo): use `sysupgrade -n`. The old system would append the settings as JFFS2 inside `firmware`, where this image does not look.
- **Defaults:** LAN `192.168.1.1`, DHCP server on, root without password, Wi-Fi disabled.
- **Source and licence:** OpenWrt is GPL-2.0. Sources: the patch series against upstream OpenWrt `main` (the BE5000 series and the fixes from this repository) and the build `diffconfig`, as `be5000-openwrt-source-patches.tar.gz` and `diffconfig` in the [release](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/tag/be5000-openwrt-20261018).
