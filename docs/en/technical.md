# How it works

[← README](../../README.md)

> [!IMPORTANT]
> **TL;DR.** The AN7563 boots through the chain BootROM → BL2 → BL31 → U-Boot. BL2 reads NAND itself using a built-in chip table: no chip, `panic()`. For recovery, both BootROM and BL2 support XMODEM, but each accepts its own format.

## Contents

1. [Hardware](#hardware)
2. [Flash layout](#flash-layout)
3. [Bootloader](#bootloader)
4. [Why PANIC](#why-panic)
5. [XMODEM recovery](#xmodem-recovery)
6. [Wi-Fi calibration](#wi-fi-calibration)
7. [OpenWrt image](#openwrt-image)
8. [What this build changes](#what-this-build-changes)
9. [PCIe](#pcie)
10. [Speed](#speed)
11. [Supported NAND chips](#supported-nand-chips)

## Hardware

| Component | Value |
|---|---|
| SoC | Airoha AN7563PT (BL2 log shows `AN7552DRAMC V0.4`), 2× Cortex-A7 |
| DRAM | 512 MB DDR3 (Winbond W634GU6…), 1866 MT/s |
| NAND | 128 MB SPI-NAND, varies between batches: Winbond **W25N01KV**, ESMT and others |
| Wi-Fi | MediaTek MT7992: 2.4 GHz 2x2, 5 GHz 3x3 160 MHz (`iw phy`: EHT max NSS 3), EEPROM in flash |
| Ethernet | built-in MT7530 switch (3× 1 Gbit) + EN8811H (2.5 Gbit) |
| UART | 115200 8N1, 3.3 V |

## Flash layout

![Flash layout](../../images/flash-layout.svg)

| Offset | Xiaomi stock firmware | After install | Size |
|---|---|---|---|
| `0x000000` | Bootloader | u-boot (RO) | `0x60000` |
| `0x060000` | ↑ | u-boot-env: U-Boot environment in the last 16 KiB (`0x7C000`) | `0x20000` |
| `0x080000` | u-boot-env | art: block 1, also the read-only **stock-env** partition (stock U-Boot environment with the MAC addresses) | `0x20000` |
| `0x0A0000` | ↑ (empty) | art: block 2 = **calibration** | `0x20000` |
| `0x0C0000` | ↑ | firmware: kernel (FIT) | `0x3C0000` |
| `0x100000` | bdata (`ethaddr=…`) | ↑ | |
| `0x180000` | **Factory** (EEPROM `92 79` + MAC) | firmware: rootfs | |
| `0x580000` | crash, `0x5C0000` crash_log | ↑ | |
| `0x600000` | kernel (stock) | ↑ | |
| `0xC00000` | ubi (stock) | ↑ | |
| `0x18C0000` | ↑ | ubi-data: `rootfs_data` (settings) | `0x5D20000` |
| `0x2A00000` | tclinux_slave (backup firmware) | ↑ | |
| `0x4E00000` | overlay (stock settings, UBI) | ↑ | |
| `0x6E00000` | art (stock, empty) | ↑ | |
| `0x75E0000` | ↑ | end of ubi-data = end of the logical area | |

Logical addresses are mapped through Airoha BMT: `BMT v1 at block 1023`, `BBT v1 at block 943`, 943 usable blocks.

## Bootloader

The first `0x80000` bytes: 0x800 zero bytes, then a TF-A FIP (`0xAA640001`, serial `0x12345678`):

| Part | UUID (first bytes) | What it does |
|---|---|---|
| BL2 | `5ff9ec0b` | small decompressor + LZMA: DRAM, SPI-NAND table, FIP loading |
| BL31 | `47d4086d` | secure monitor |
| BL33 | `d6d0eea7` | U-Boot (LZMA) |

BootROM loads BL2 from NAND itself. Then BL2 reads the FIP from offset `0x800` with its own driver and checks the header at `FIP_BASE`.

## Why PANIC

BL2 sources: [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha), `plat/ecnt/en7523/ecnt_bl2_setup.c`:

```c
if (flash_read(fip_offset, PLAT_ECNT_FIP_MAX_SIZE, (uint8_t *) PLAT_ECNT_FIP_BASE) == FLASH_READ_STATUS_CORRECT) { }
else { panic(); }
...
while (plat_check_header((uint8_t *) PLAT_ECNT_FIP_BASE) == 0) { panic(); }
```

If the NAND chip is not in the BL2 table, `flash_read` fails, and every cold boot ends with `PANIC at PC : 0x810017a9`.

| BL2 | Chips | W25N01KV |
|---|---|---|
| xinyooo v2026.05-r1…v2026.06-r1 (`8d363ec4…`), X-WRT 26.10 preloader | 56 | no |
| build r35200+4 from 2026-07-02, this repository | 57 | **yes** |

> [!NOTE]
> After a warm reboot from Linux, a "bad" BL2 sometimes gets to U-Boot. Test the bootloader only with a cold boot: power from the wall socket.

## XMODEM recovery

| Stage | Receiver | Prompt | Format | Limit |
|---|---|---|---|---|
| 1 | BootROM (GPIO0 = GND, `HWCONF is f`) | `Press x` | FIP with a single BL2 entry at offset `0x60` | ≤ `0x1F800` bytes, waits ~30 s |
| 2 | BL2 from stage 1 | `Press x to update firmware` | full 512 KB image: 0x800 zero bytes + FIP | length exactly `0x80000` → BL2 writes it to flash at 0 |

Both stages use XMODEM-CRC with 128-byte blocks.

| What was sent | Result |
|---|---|
| full 512 KB image to stage 1 | `CAN` at block 1009 (`0x1F800`) |
| bare BL2 to stage 1 | accepted, silence |
| FIP without the 0x800 zero bytes to stage 2 | `PANIC`: BL2 places the file at `FIP_BASE - 0x800`, so the header ends up in the wrong place |

## Wi-Fi calibration

- **On stock:** the MT7992 EEPROM is at the start of the Factory partition (`0x180000`), 7680 bytes (`0x1E00`), starts with `92 79`, then the base MAC. The rest of the partition is `FF`.
- **On the new flash layout:** OpenWrt reads the EEPROM from the second block of `art` (`0xA0000`) through NVMEM. In this build the partition is writable, so the block can be written from OpenWrt; the iscle/xinyooo images mark it read-only.
- **How it is moved:** `be5000-install.sh calibration` takes the first `0x1E00` bytes of Factory and pads them with `FF` to 128 KB (`make_calibration` in the script).

Without calibration, `dmesg` shows `mt7996e … eeprom load fail, use default bin`: the driver uses the MediaTek default EEPROM. Wi-Fi works, but its MAC `00:0c:43:26:60:10` is the same on every unit, so on first boot each radio gets a random `macaddr_base` in `/etc/config/wireless`.

## OpenWrt image

`squashfs-sysupgrade.bin` is not a tar but a ready image of the `firmware` partition:

| Offset | What |
|---|---|
| `0x000000` | FIT (`d00dfeed`): kernel + DTB |
| `0x3C0000` | squashfs (`hsqs`) |
| after squashfs | `deadc0de`, then sysupgrade metadata |

U-Boot reads the first `fitsize = 0x500000` bytes of the partition and runs `bootm`. The web failsafe writes the uploaded file to the `firmware` partition as is.

Settings are not in `firmware` but in a separate `ubi-data` partition (`0x18C0000` to the end of the logical area, 93 MiB, about 79 MiB in `/overlay` after UBI headers, the UBI bad block reserve, UBIFS metadata and journal, see the README; shorter on a chip with factory bad blocks), volume `rootfs_data` (UBIFS). `sysupgrade` unloads the Wi-Fi driver (which stops the NPU before the reboot), writes the FIT into `firmware`, recreates `rootfs_data` over all free blocks and saves the kept settings there. The kernel does not attach the partition (it would attach one named `ubi` or `data`). Preinit first reads the UBI header of every 16th block: when they all belong to one UBI image of ours, it attaches right away. Otherwise it reads every block and formats the partition when it holds no UBI of ours, another UBI image (for example the Xiaomi data on a router fresh from stock) or too many blocks without a UBI header; then it attaches. So the kernel never sees the stock data. Up to the 2026-10-17 image the partition was `ubi`, 40 MiB, and the stock data still lay behind it; only the 2026-10-18 image moves that layout, so upgrade from 20261016 or 20261017 through it. JFFS2 does not work on W25N01KV: it programs page 0 of a block twice (cleanmarker in OOB, then data), and the chip's on-die ECC corrupts such a page ([issue #1](https://github.com/pabragin/xiaomi-be5000-openwrt/issues/1)).

## What this build changes

Compared to iscle's builds:

- **Settings in UBI** instead of JFFS2 (see above).
- **PCIe at 5 GT/s:** the AN7563 root ports train at 2.5 GT/s and stay there; the kernel retrains both links to 5 GT/s, as the Xiaomi stock kernel does (`mt7512_pcie_rc0/rc1_retrain`). At 2.5 GT/s x1 the Wi-Fi TX DMA capped downloads at about 1 Gbit/s.
- **Longer TXOP on 5 GHz:** OpenWrt gives the best-effort queue of a 5 GHz radio a 2 ms TXOP (`tx_queue_data2_burst=2.0`), and the MT7992 firmware sizes its A-MPDUs to fit, about 46 frames. The image sets 16 ms on first boot (unless a burst is already configured): download 1770 → 1945 Mbit/s with 8 HTTP streams, 1897 Mbit/s in OpenSpeedTest. Loaded latency rises from ~7 to ~16–19 ms.
- **Wi-Fi 7 on WPA3:** OpenWrt offers SAE-EXT-KEY with GCMP-256 to Wi-Fi 7 clients, and the NPU fast path took only CCMP, so every uplink frame of such a client went to Linux (~165 Mbit/s). The NPU firmware and the driver now offload CCMP-256, GCMP and GCMP-256 as well: 1560–1760 Mbit/s upload. MLO stations are matched by their MLD address, so MLO clients are offloaded too.
- **NPU switch:** `luci-app-an7552-npu` (**Network → NPU acceleration**) reloads `mt7996e` with `npu_enable=0` or `1`. Frames addressed to the router itself are copied by the NPU into Linux memory through uncached memory, about 48 thousand cycles per frame, which caps them at ~150 Mbit/s; without the NPU the plain mt76 path takes them at up to ~900 Mbit/s, while Wi-Fi ↔ wired forwarding drops from ~1.9 to ~1.1 Gbit/s. AmneziaWG on the router: 18–175 / 11–22 Mbit/s with the NPU, 251 / 236 Mbit/s without it.
- **Upload on both NPU cores:** core 1 parsed every received frame (~5400 cycles) and capped Wi-Fi → Ethernet at ~120k frames/s. Core 0 now reads the RX descriptor, checks security and PN and parses the frame, then hands a 32-byte record to core 1 through a queue in shared SRAM; core 1 queues to the PPE or delivers to Linux. Under upload core 1 is busy about 40% of the time instead of 84%, core 0 about 74%.
- **Reboot:** the Wi-Fi chip, QDMA and NPU are stopped on shutdown, so a warm reboot does not loop.
- **Watchdog:** the hardware watchdog works (`airoha,en7523-wdt`).
- **NPU:** fixes for encrypted A-MSDU and a faster receive path in the NPU firmware: header words read once, replay-counter cache, one pass over TX completions, a buffer pool for downloads, one loop per core with the hot path out of line and the code laid out per core (14.4 KB). Upload 1778 Mbit/s in OpenSpeedTest.
- **Thermal:** the AN7563 temperature sensors (diode and BJT, calibrated from eFuse) as `cpu-thermal` and `soc-thermal`; above 105 °C on `cpu-thermal` the CPU frequency is lowered. 63–69 °C under load.
- **Full wpad:** `wpad-mbedtls` instead of `wpad-basic-mbedtls`.
- **Sysupgrade:** the Wi-Fi driver is unloaded before the image is written, and the image size is checked against the 24 MiB `firmware` partition. The reboot after a sysupgrade still hangs about 1 in 3 (no LED; a power cycle brings the router back with the image and the settings written). The netconsole log shows the whole upgrade and `reboot -f`; the hang comes after the PSCI system reset, before the watchdog runs. A reset through the watchdog right at the end of stage 2 came back every time (5 of 5), a watchdog restart handler in the kernel did not help.
- **Writable `art`:** the calibration partition is not marked read-only, so `be5000-install.sh calibration` can write the block from OpenWrt, installed or in RAM. Nothing writes there on its own; the script refuses to erase a block that holds data.
- **Factory MAC addresses:** the first block of `art` holds the stock U-Boot environment (64 KiB with a CRC) and is also mapped as the read-only `stock-env` partition, listed after the others so that the partition numbers stay (the bootloader passes `root=/dev/mtdblock5`). The kernel parses it with the NVMEM `u-boot,env` layout (`env-size` 64 KiB, as the CRC covers only that much) and gives `eth0` with the three 1G ports `ethaddr` and the 2.5G port `ethaddr_wan`, the address on the label, at every boot, whatever the network config says. The layout converts only `ethaddr` upstream, so a two-line patch runs the generic `mac-base` parser on the other cells. Without the environment the ports get random addresses from the kernel, and `board.d` keeps a random pair in the config for the bridge and `wan`.
- **Kernel modules:** downloads.openwrt.org has no `airoha/an7563` target, so the build makes every kernel module (`CONFIG_ALL_KMODS`) and publishes them, signed with the build key, on the GitHub Pages of this repository, one directory per kernel version and vermagic hash (`kmods/6.18.55-<hash>/`). The same directory carries the packages of the VPN image that downloads.openwrt.org does not have (AmneziaWG, zapret, the Amnezia Xray, the NPU switch). On first boot the image points the target feed of `/etc/apk/repositories.d/distfeeds.list` at the directory of its own kernel.
- **Wi-Fi MAC without calibration:** if `art` has no calibration, the driver uses the MediaTek default EEPROM with the same MAC on every unit. On first boot each radio then gets a random `macaddr_base`, kept in `/etc/config/wireless`.

## PCIe

The MT7992 radio is attached over two PCIe links: `0000:01:00.0` (main) and `0001:01:00.0` (second interface). The AN7563 root ports have one lane each and up to 5 GT/s; the radio supports 8 GT/s.

- **Problem:** after power-up the links train at 2.5 GT/s and never move up. For downloads the radio reads every packet from the router's memory over PCIe, so at 2.5 GT/s x1 downloads were capped at about 1 Gbit/s.
- **Fix:** the kernel retrains both links to 5 GT/s right after link up. The Xiaomi stock kernel does the same (`mt7512_pcie_rc0_retrain`, `mt7512_pcie_rc1_retrain`).
- **Check:** `cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed` → `5.0 GT/s PCIe`; `dmesg` shows `link retrained to 5.0 GT/s PCIe` for both ports.

| PCIe | Download (2x2 160 MHz client) |
|---|---|
| 2.5 GT/s x1 | ~1.05 Gbit/s |
| 5 GT/s x1 | 1350–1570 Mbit/s with 8 HTTP streams at OpenWrt's 2 ms TXOP; ~1945 Mbit/s and 1897 Mbit/s in OpenSpeedTest with the 16 ms TXOP of this image |

## Speed

OpenSpeedTest from a MacBook (2x2, 160 MHz, about −40 dBm) to a PC on the wired LAN, through the BE5000:

![OpenSpeedTest: 1897 Mbit/s download, 1778 Mbit/s upload](../../images/openspeedtest-be5000-npu-on.png)

| Test | Download | Upload |
|---|---|---|
| OpenSpeedTest in the browser | 1897 Mbit/s | 1778 Mbit/s |
| 8 parallel HTTP keep-alive streams | ~1945 Mbit/s | 1640–1680 Mbit/s |

## Supported NAND chips

BL2 in `be5000-bootloader-w25n01kv.bin` knows 57 chips. The list lives in the router script (`BL2_CHIPS` in `scripts/router/be5000-install.sh`) and can be read from any bootloader image:

```sh
python3 scripts/pc/be5000-check-bootloader.py firmware/bootloader/be5000-bootloader-w25n01kv.bin
```

To check any other image: `python3 scripts/pc/be5000-check-bootloader.py file.bin --chip <your chip>`.
