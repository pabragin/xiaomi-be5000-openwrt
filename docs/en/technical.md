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
| Wi-Fi | MediaTek MT7992 (2.4 + 5 GHz), EEPROM in flash |
| Ethernet | built-in MT7530 switch (3× 1 Gbit) + EN8811H (2.5 Gbit) |
| UART | 115200 8N1, 3.3 V |

## Flash layout

![Flash layout](../../images/flash-layout.svg)

| Offset | Xiaomi stock firmware | After install | Size |
|---|---|---|---|
| `0x000000` | Bootloader | u-boot | `0x7C000` |
| `0x07C000` | ↑ | u-boot-env (RO) | `0x4000` |
| `0x080000` | u-boot-env | art: block 1 | `0x20000` |
| `0x0A0000` | ↑ (empty) | art: block 2 = **calibration** | `0x20000` |
| `0x0C0000` | ↑ | firmware: kernel (FIT) | `0x3C0000` |
| `0x100000` | bdata (`ethaddr=…`) | ↑ | |
| `0x180000` | **Factory** (EEPROM `92 79` + MAC) | firmware: rootfs | |
| `0x600000` | kernel (stock) | ↑ | |
| `0xC00000` | ubi (stock) | ↑ | |
| `0x18C0000` | ↑ | ubi: `rootfs_data` (settings) | `0x2800000` |
| `0x40C0000` | ↑ | end of ubi | |

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

Settings are not in `firmware` but in a separate `ubi` partition (`0x18C0000`, 40 MiB), volume `rootfs_data` (UBIFS). JFFS2 does not work on W25N01KV: it programs page 0 of a block twice (cleanmarker in OOB, then data), and the chip's on-die ECC corrupts such a page ([issue #1](https://github.com/pabragin/xiaomi-be5000-openwrt/issues/1)).

## What this build changes

Compared to iscle's builds:

- **Settings in UBI** instead of JFFS2 (see above).
- **PCIe at 5 GT/s:** the AN7563 root ports train at 2.5 GT/s and stay there; the kernel retrains both links to 5 GT/s, as the Xiaomi stock kernel does (`mt7512_pcie_rc0/rc1_retrain`). At 2.5 GT/s x1 the Wi-Fi TX DMA capped downloads at about 1 Gbit/s; with 5 GT/s a 2x2 160 MHz client downloads ~1.45 Gbit/s.
- **Upload on both NPU cores:** core 1 parsed every received frame (~5400 cycles) and capped Wi-Fi → Ethernet at ~120k frames/s. Core 0 now reads the RX descriptor, checks security and PN and parses the frame, then hands a 32-byte record to core 1 through a queue in shared SRAM; core 1 queues to the PPE or delivers to Linux. Core 1 load under upload drops from 84% to 31%. A boot probe falls back to single-core mode if the cores do not share the queue memory.
- **Reboot:** the Wi-Fi chip, QDMA and NPU are stopped on shutdown, so a warm reboot does not loop.
- **Watchdog:** the hardware watchdog works (`airoha,en7523-wdt`).
- **NPU:** fixes for encrypted A-MSDU and a faster receive path in the NPU firmware.
- **Writable `art`:** the calibration partition is not marked read-only, so `be5000-install.sh calibration` can write the block from OpenWrt, installed or in RAM. Nothing writes there on its own; the script refuses to erase a block that holds data.
- **Wi-Fi MAC without calibration:** if `art` has no calibration, the driver uses the MediaTek default EEPROM with the same MAC on every unit. On first boot each radio then gets a random `macaddr_base`, kept in `/etc/config/wireless`.

## PCIe

The MT7992 radio is attached over two PCIe links: `0000:01:00.0` (main) and `0001:01:00.0` (second interface). The AN7563 root ports have one lane each and up to 5 GT/s; the radio supports 8 GT/s.

- **Problem:** after power-up the links train at 2.5 GT/s and never move up. For downloads the radio reads every packet from the router's memory over PCIe, so at 2.5 GT/s x1 downloads were capped at about 1 Gbit/s.
- **Fix:** the kernel retrains both links to 5 GT/s right after link up. The Xiaomi stock kernel does the same (`mt7512_pcie_rc0_retrain`, `mt7512_pcie_rc1_retrain`).
- **Check:** `cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed` → `5.0 GT/s PCIe`; `dmesg` shows `link retrained to 5.0 GT/s PCIe` for both ports.

| PCIe | Download (2x2 160 MHz client) |
|---|---|
| 2.5 GT/s x1 | ~1.05 Gbit/s |
| 5 GT/s x1 | ~1.45 Gbit/s (8 HTTP streams), 1757 Mbit/s in OpenSpeedTest |

## Speed

OpenSpeedTest from a MacBook (2x2, 160 MHz, about −40 dBm) to a PC on the wired LAN, through the BE5000:

![OpenSpeedTest: 1757 Mbit/s download, 1643 Mbit/s upload](../../images/openspeedtest-be5000.png)

| Test | Download | Upload |
|---|---|---|
| OpenSpeedTest in the browser | 1757 Mbit/s | 1643 Mbit/s |
| 8 parallel HTTP streams, 5 minutes | 1348 Mbit/s | 1384 Mbit/s |

## Supported NAND chips

BL2 in `be5000-bootloader-w25n01kv.bin` knows 57 chips. The list lives in the router script (`BL2_CHIPS` in `scripts/router/be5000-install.sh`) and can be read from any bootloader image:

```sh
python3 scripts/pc/be5000-check-bootloader.py firmware/bootloader/be5000-bootloader-w25n01kv.bin
```

To check any other image: `python3 scripts/pc/be5000-check-bootloader.py file.bin --chip <your chip>`.
