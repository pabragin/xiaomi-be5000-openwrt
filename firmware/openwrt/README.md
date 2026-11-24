# OpenWrt images

The images are not in git: download them from the [latest release](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest) (`install.sh` does it). Build: OpenWrt `main` of 2026-11-20 (`r36539+2091-98bc30d154`, Linux 6.18.64, mt76 2026-10-28) with [iscle](https://github.com/iscle/openwrt)'s BE5000 series and the fixes from this repository. Tested on the reference router (W25N01KV) with this image: `sysupgrade` with kept settings, wired LAN with internet, the 2.5G WAN port at 2.5 Gbit/s with its own QDMA and TX offloads (upload from the router 700 Mbit/s with one stream, 1.58 Gbit/s with four), Wi-Fi on 5 GHz at 160 MHz with Wi-Fi 6 and Wi-Fi 7 clients, Wi-Fi ↔ wired traffic bridged in hardware with the CPU idle (1846/1648 Mbit/s with a Wi-Fi 7 client at 160 MHz), the NPU firmware (a MacBook uploads 1675 Mbit/s to a wired host; a MediaTek client uploading to two addresses at once loses 0.04–0.64%), an AmneziaWG server on the router. The same kernel and drivers with debug code added went through about 60 warm reboots (`reboot -f`, watchdog, `sysupgrade`). Not tested with this image yet: the web failsafe install, PPPoE, IPv6, MLO, the packages of the VPN image and routing offload under load. Known issue: about one warm reboot in five to ten (`sysupgrade`, `reboot -f`) does not come back, with all LEDs off, until the router is power cycled; it happens before the bootloader and is not found yet.

| Release file | Use |
|---|---|
| `openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` | Install: upload in the U-Boot web failsafe (`http://192.168.1.1`) or `sysupgrade` from OpenWrt. Raw image of the `firmware` partition: FIT kernel + squashfs |
| `openwrt-airoha-an7563-xiaomi_be5000-full-squashfs-sysupgrade.bin` | The same with AmneziaWG 3.1, Xray from the Amnezia fork with luci-app-xray, zapret, https-dns-proxy and pbr, all with LuCI and off until configured, dnsmasq-full instead of dnsmasq (nftset for pbr domain rules), and the Argon LuCI theme ([two images](../../README.md#two-images)) |
| `openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin` | RAM-only system for recovery and tests: `tftpboot 0x84000000 …; bootm 0x84000000` in U-Boot. Does not touch flash |
| `SHA256SUMS` | checksums of the release files |
| `be5000-openwrt-source-patches.tar.gz`, `diffconfig` | the patch series and the build config of this build |

What the build changes compared to iscle's, the flash layout, PCIe and the speed tests: [docs/en/technical.md](../../docs/en/technical.md#what-this-build-changes).

- **Requires** the bootloader from [`../bootloader/`](../bootloader/) (replacement flash layout, calibration at `0xA0000`). Not a Xiaomi stock web-upgrade image.
- **Upgrading from an image with JFFS2 settings** (iscle, xinyooo): use `sysupgrade -n`. The old system would append the settings as JFFS2 inside `firmware`, where this image does not look.
- **Defaults:** LAN `192.168.1.1` on the three 1G ports, WAN (DHCP client) on the 2.5G port, both with the factory MAC addresses, DHCP server on, root without password, Wi-Fi disabled, NPU offload on.
- **Reset at power-on** starts the bootloader web failsafe on `http://192.168.1.1`. At first boot the image writes the U-Boot environment with this check into the `u-boot-env` block if the block is empty ([bootloader](../bootloader/README.md#u-boot-environment-0x7c000-16-kib)).
- **From any be5000-openwrt version before 2026-10-18:** upgrade to be5000-openwrt-20261018 first. Only that release moves the settings from the old 40 MiB partition; newer images format it.
- **Source and licence:** OpenWrt is GPL-2.0. Sources: the patch series against upstream OpenWrt `main` (the BE5000 series and the fixes from this repository) and the build `diffconfig`, as `be5000-openwrt-source-patches.tar.gz` and `diffconfig` in the [release](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/tag/be5000-openwrt-20261124).
