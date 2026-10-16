# OpenWrt on Xiaomi BE5000 (Airoha AN7563)

[Русский](README.md) · **English**

> [!IMPORTANT]
> **TL;DR.** This repository shows how to install OpenWrt on the Xiaomi BE5000 with only root SSH access, and how to recover the router over UART if the bootloader is broken.
> - **Main trap:** the bootloader from the xinyooo releases and the X-WRT preloader do not know the **Winbond W25N01KV** flash chip. With this chip the router crashes on every cold boot with `PANIC at PC : 0x810017a9`.
> - **This repository has a bootloader that knows it:** [`be5000-bootloader-w25n01kv.bin`](firmware/bootloader/): BL2 with 57 NAND chips, U-Boot with autoboot and web recovery.
> - **Wi-Fi speed:** 1757 Mbit/s download and 1643 Mbit/s upload through the BE5000 (OpenSpeedTest, a 2x2 160 MHz MacBook to a wired PC).
> - **Tested on hardware:** BE5000 (AN7563PT, W25N01KV, 512 MB DDR3): SSH install from Xiaomi stock firmware, UART recovery, web failsafe install, cold boot, our own OpenWrt build with settings in UBI, Wi-Fi calibration built from the router's own Factory data.

## Contents

1. [What works](#1-what-works)
2. [Requirements](#2-requirements)
3. [Install](#3-install) → details: [docs/en/install-ssh.md](docs/en/install-ssh.md)
4. [If the bootloader is broken: UART](#4-if-the-bootloader-is-broken-uart) → details: [docs/en/recovery-uart.md](docs/en/recovery-uart.md)
5. [Files](#5-files)
6. [How it works](#6-how-it-works) → details: [docs/en/technical.md](docs/en/technical.md)
7. [Sources and credits](#7-sources-and-credits)
8. [Feedback](#8-feedback)

## 1. What works

Everything below is tested on a BE5000 running this firmware.

| What | How it works |
|---|---|
| **System** | OpenWrt SNAPSHOT `r36539+835`, **Linux 6.18.55** kernel, mt76 Wi-Fi driver 2026-10-08 |
| **5 GHz Wi-Fi** | 160 MHz, Wi-Fi 6/7. A 2x2 MacBook: **1757 Mbit/s** download, **1643 Mbit/s** upload ([test](firmware/openwrt/README.md#speed)) |
| **2.4 GHz Wi-Fi** | works, 20/40 MHz |
| **Hardware offload** | Wi-Fi ↔ wired traffic goes through the PPE and the NPU; the CPU is ~10% busy at full speed |
| **Roaming** | 802.11r: phones and laptops move seamlessly between the BE5000 and another OpenWrt AP with the same network |
| **Ports** | three 1 Gbit/s ports and one 2.5 Gbit/s port, all in one network |
| **Settings** | survive reboots and power cuts, and are kept across firmware upgrades |
| **Reboot** | warm and cold reboots without hangs; if the system hangs, the watchdog reboots it after ~30 s |
| **Management** | LuCI web UI and SSH at `192.168.1.1`, upgrades with `sysupgrade` |
| **MAC addresses** | from the router's label, taken from its factory calibration |

<img src="images/openspeedtest-be5000.png" alt="OpenSpeedTest through the BE5000: 1757 Mbit/s download, 1643 Mbit/s upload" width="320">

**Limitations:**
- **Wi-Fi is off by default.** After installing, set the country, network name and password.
- **Old WPA2-TKIP-only devices** (some printers, for example) connect unreliably and reconnect every few seconds.
- **Download to a single fast client** tops out at about 1.45–1.75 Gbit/s. The limit is the PCIe link between the CPU and the radio (one lane, 5 GT/s).

> [!WARNING]
> Installing overwrites the factory `bdata` and `Factory` partitions. You can return to the Xiaomi firmware only from the full backup the installer makes in step 1.

## 2. Requirements

- **A router you can reach over SSH** (root and its password). It does not matter what runs on it: Xiaomi stock firmware, xinyooo/iscle OpenWrt or X-WRT.
- **A computer** with macOS or Linux (on Windows use WSL) and **a network cable** to the router.

> [!NOTE]
> Settings are kept in UBI, not JFFS2: on W25N01KV flash JFFS2 corrupts writes, and after a reboot the router comes up with no network ([issue #1](../../issues/1)). Moving from iscle/xinyooo OpenWrt to this image does not keep settings (`sysupgrade -n`).

## 3. Install

**Step 1. One command on the computer.** Connect the computer by cable to a LAN port of the router (not the 2.5G port). Get the repository and run the installer with the router's address:

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
sh install.sh root@192.168.31.1        # 192.168.31.1 is the Xiaomi stock address; usually 192.168.1.1 on OpenWrt
```

The script asks for the router password once and then:
1. checks that the bootloader supports your flash chip (if not, it stops without writing anything);
2. saves a full flash backup to `be5000-backup-<date>` (keep it: without it you cannot go back to Xiaomi firmware);
3. asks for `YES`, moves the Wi-Fi calibration and writes the bootloader;
4. reboots the router.

**Step 2. Firmware in the browser.**
1. Set the computer's address manually: IP `192.168.1.10`, mask `255.255.255.0`. On macOS: System Settings → Network → (adapter) → Details → TCP/IP → Configure IPv4: Manually.
2. Open `http://192.168.1.1`, choose [`firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`](firmware/openwrt/), click **Upload**, then **Proceed**.
3. Wait 5 minutes and do not cut the power. The router reboots into OpenWrt by itself.

**Step 3. Setup.** Switch the computer back to an automatic address (DHCP), open `http://192.168.1.1`, set a password, then the country, Wi-Fi name and Wi-Fi password.

> [!CAUTION]
> If the power is lost while the bootloader is being written, or the router does not show up on the network after step 1, only UART can bring it back (section 4).

Step-by-step install, the manual flash chip check and the `READ-ONLY` case: [docs/en/install-ssh.md](docs/en/install-ssh.md).

## 4. If the bootloader is broken: UART

Symptoms: no network activity, `PANIC at PC : 0x810017a9` in the UART log, or any stop before U-Boot.

![Boot chain](images/boot-chain.en.svg)

1. Connect a USB-UART adapter: GND–GND, TX↔RX, **do not connect VCC**, 115200 8N1.
   ![Wiring](images/uart-wiring.en.svg)
2. Run `python3 scripts/pc/be5000-uart-recover.py /dev/ttyUSB0` (on macOS the port is `/dev/cu.usbserial-…`).
3. Short **GPIO0 to GND**, hold it and power on. For where the pad is, see the [photo](docs/en/recovery-uart.md#where-gpio0-is).
4. The script runs both XMODEM stages and writes the bootloader. Then release GPIO0.

Details, with photos and troubleshooting: [docs/en/recovery-uart.md](docs/en/recovery-uart.md).

## 5. Files

| File | What it is | Where it goes |
|---|---|---|
| [`firmware/bootloader/be5000-bootloader-w25n01kv.bin`](firmware/bootloader/) | 512 KB bootloader: BL2 (57 NAND chips) + BL31 + U-Boot | flash `0x0` (SSH: `be5000-install.sh bootloader`; UART: XMODEM #2) |
| [`firmware/bootloader/be5000-uart-bl2-stage1.bin`](firmware/bootloader/) | the same BL2 in a mini FIP | UART only, XMODEM #1 to the BootROM |
| `calibration.bin` (you make it) | MT7992 EEPROM of your router, 128 KB | flash `0xA0000` |
| [`firmware/openwrt/…-squashfs-sysupgrade.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin) | OpenWrt ([about the build](firmware/openwrt/README.md)): FIT kernel + squashfs | `firmware` partition `0xC0000` (web failsafe or `sysupgrade`) |
| [`firmware/openwrt/…-initramfs-kernel.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin) | OpenWrt in RAM for testing and recovery | TFTP → `bootm`, does not touch flash |
| [`install.sh`](install.sh) | one-command install: check, backup, calibration, bootloader | runs on the computer |
| [`scripts/router/be5000-install.sh`](scripts/router/be5000-install.sh) | check, write calibration and bootloader with read-back verification | runs on the router |
| [`scripts/pc/`](scripts/pc/) | backup, calibration, UART recovery, bootloader check | runs on the computer |

Checksums and origin of the binaries: [firmware/bootloader/README.md](firmware/bootloader/README.md), [firmware/openwrt/README.md](firmware/openwrt/README.md).

## 6. How it works

| Component | What is on the flash |
|---|---|
| Bootloader (0x0–0x80000) | BL2 with W25N01KV support + BL31 + U-Boot 2026.01 (autoboot, web failsafe at `192.168.1.1`) |
| Wi-Fi calibration | factory MT7992 EEPROM moved to block `0xA0000` (`art` partition) |
| Firmware | OpenWrt (our build based on [iscle](https://github.com/iscle/openwrt)) in the `firmware` partition at `0xC0000`, 24 MiB |
| Settings | `ubi` partition at `0x18C0000`, 40 MiB, `rootfs_data` volume (UBIFS) |

![Flash layout](images/flash-layout.en.svg)

- **What is in the bootloader.** BL2 with a list of 57 NAND chips (including W25N01KV), BL31 and xinyooo U-Boot 2026.01 with autoboot and web failsafe.
- **Why UART needs two files.** The BootROM accepts at most `0x1F800` bytes over XMODEM, and only a FIP with a single BL2. Then BL2 itself prompts `Press x to update firmware`, accepts the full 512 KB image and writes it to flash.

Details, with logs and addresses: [docs/en/technical.md](docs/en/technical.md).

## 7. Sources and credits

- [xinyooo](https://github.com/xinyooo/openwrt/releases): AN7563 port, U-Boot with web failsafe, [PR #23960](https://github.com/openwrt/openwrt/pull/23960), [forum thread](https://forum.openwrt.org/t/release-custom-openwrt-u-boot-for-xiaomi-be5000-an7563/250004).
- [100PoR-new](https://github.com/openwrt/openwrt/pull/23960#issuecomment-6173662443): BL2 with W25N01KV (built with [make_airoha_atf](https://github.com/xinyooo/make_airoha_atf)) and the GPIO0 photo.
- [iscle](https://github.com/iscle/openwrt): OpenWrt port for the BE5000, flash layout with calibration in `art`, DSA, PPE, Wi-Fi.
- [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha): BL2 sources used to work out the XMODEM recovery format.
- [Medvedolog, issue #17](https://github.com/Medvedolog/airoha-router-ursusflasher/issues/17): AN7552 BootROM observations.

## 8. Feedback

Report successes and problems in [Issues](../../issues). Include the NAND chip and the output of `be5000-install.sh check`.
