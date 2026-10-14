# OpenWrt images

Copied unchanged from [iscle/openwrt release `be5000-upstream-ppe-20260925`](https://github.com/iscle/openwrt/releases/tag/be5000-upstream-ppe-20260925) (OpenWrt `r36539+20-98bc30d154`, Linux 6.18.52). This is the build installed and tested on the reference router (W25N01KV, cold boot, web failsafe install, 802.11r roaming).

| File | Size | Use |
|---|---|---|
| `openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` | 11272463 | Install: upload in the U-Boot web failsafe (`http://192.168.1.1`) or `sysupgrade` from OpenWrt. Raw image of the `firmware` partition: FIT kernel + squashfs |
| `openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin` | 10745180 | RAM-only system for recovery and tests: `tftpboot 0x84000000 …; bootm 0x84000000` in U-Boot. Does not touch flash |

Checksums: [`SHA256SUMS`](SHA256SUMS) (identical to the release `sha256sums`).

- **Requires** the bootloader from [`../bootloader/`](../bootloader/) (replacement flash layout, calibration at `0xA0000`). Not a Xiaomi stock web-upgrade image.
- **Defaults:** LAN `192.168.1.1`, DHCP server on, root without password, Wi-Fi disabled.
- **Source and licence:** OpenWrt is GPL-2.0; sources, build config and feeds are in the release linked above.
