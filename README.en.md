# OpenWrt on Xiaomi BE5000 (Airoha AN7563)

[Русский](README.md) · **English**

> [!IMPORTANT]
> **TL;DR.** This repository shows how to install OpenWrt on the Xiaomi BE5000 with only root SSH access, and how to recover the router over UART if the bootloader is broken.
> - **Main trap:** the bootloader from the xinyooo releases and the X-WRT preloader do not know the **Winbond W25N01KV** flash chip. With this chip the router crashes on every cold boot with `PANIC at PC : 0x810017a9`.
> - **This repository has a bootloader that knows it:** [`be5000-bootloader-w25n01kv.bin`](firmware/bootloader/), 57 NAND chips, U-Boot with autoboot and web recovery.
> - **Tested on hardware:** one BE5000 (AN7563PT, W25N01KV, 512 MB DDR3), cold boot, OpenWrt `be5000-upstream-ppe-20260925`, its own Wi-Fi calibration.

## Contents

1. [What you get](#1-what-you-get)
2. [Requirements](#2-requirements)
3. [Install over SSH](#3-install-over-ssh) → details: [docs/en/install-ssh.md](docs/en/install-ssh.md)
4. [If the bootloader is broken: UART](#4-if-the-bootloader-is-broken-uart) → details: [docs/en/recovery-uart.md](docs/en/recovery-uart.md)
5. [Files](#5-files)
6. [How it works](#6-how-it-works) → details: [docs/en/technical.md](docs/en/technical.md)
7. [Sources and credits](#7-sources-and-credits)
8. [Open questions](#8-open-questions)

## 1. What you get

| Component | State after install |
|---|---|
| Bootloader (0x0–0x80000) | BL2 with W25N01KV support + BL31 + U-Boot 2026.01 (autoboot, web failsafe at `192.168.1.1`) |
| Wi-Fi calibration | factory MT7992 EEPROM moved to block `0xA0000` (`art` partition) |
| Firmware | OpenWrt by [iscle](https://github.com/iscle/openwrt/releases) in the `firmware` partition at `0xC0000` |
| Ports | `lan1`–`lan3` (1 Gbit, DSA) and `eth1` (2.5 Gbit), all in `br-lan` |
| Wi-Fi | 2.4 + 5 GHz, off by default |

![Flash layout](images/flash-layout.svg)

> [!WARNING]
> The new flash layout overwrites the factory `bdata` and `Factory` partitions. You can return to the Xiaomi firmware only from the full backup you make in step 2.

## 2. Requirements

- **Root over SSH** on the router. It does not matter what runs now: Xiaomi stock firmware, OpenWrt xinyooo/iscle or X-WRT. You do not need to know which U-Boot is installed; the script detects the flash layout itself.
- **PC** with `ssh`, `scp`, `python3` (macOS or Linux; on Windows use WSL).
- **Network cable** from the PC to a LAN port of the router.
- **Just in case:** a 3.3 V USB-UART adapter. If a write is interrupted, the router cannot be recovered without it.

## 3. Install over SSH

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
R=root@192.168.31.1          # current router address (Xiaomi stock is usually 192.168.31.1)
```

1. **Check.** No writes, only a report: flash layout, whether partitions are writable, and **whether the bootloader supports your NAND chip** (must be `SUPPORTED`).
   ```sh
   scp -O scripts/router/be5000-install.sh $R:/tmp/
   ssh $R sh /tmp/be5000-install.sh check     # everything at once
   ssh $R sh /tmp/be5000-install.sh nand      # NAND chip only
   ```
   How to identify the chip by hand: [docs/en/install-ssh.md](docs/en/install-ssh.md#does-the-bootloader-support-your-nand-chip).
2. **Full backup to the PC** (all partitions, SHA-256 check). Keep it safe.
   ```sh
   sh scripts/pc/be5000-backup.sh $R
   ```
3. **Wi-Fi calibration** from your own backup. Needed only if `check` did not print `already contains MT7992 calibration`.
   ```sh
   python3 scripts/pc/be5000-calibration.py be5000-backup-*/mtd*-Factory.bin calibration.bin
   scp -O calibration.bin $R:/tmp/ && ssh $R sh /tmp/be5000-install.sh calibration /tmp/calibration.bin
   ```
4. **Bootloader.**
   ```sh
   scp -O firmware/bootloader/be5000-bootloader-w25n01kv.bin $R:/tmp/
   ssh $R sh /tmp/be5000-install.sh bootloader /tmp/be5000-bootloader-w25n01kv.bin
   ```
5. **Firmware via web failsafe.** Reboot the router. U-Boot does not find OpenWrt and opens the recovery page. Set the PC address to `192.168.1.10/24`, open `http://192.168.1.1`, upload [`openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin) and click **Proceed**.
6. **First login:** `ssh root@192.168.1.1`, then `passwd`, then set up Wi-Fi (country, network, password).

> [!CAUTION]
> If `check` shows the bootloader or calibration partition as `READ-ONLY`, it cannot be written from this system. Options are in [docs/en/install-ssh.md](docs/en/install-ssh.md#if-a-partition-is-read-only). The most reliable one is UART.

## 4. If the bootloader is broken: UART

Symptoms: no network activity, `PANIC at PC : 0x810017a9` in the UART log, or any stop before U-Boot.

![Boot chain](images/boot-chain.svg)

1. Connect USB-UART: GND–GND, TX↔RX, **do not connect VCC**, 115200 8N1.
   ![Wiring](images/uart-wiring.svg)
2. Run `python3 scripts/pc/be5000-uart-recover.py /dev/ttyUSB0`.
3. Short **GPIO0 to GND**, hold it and power on. Where the pad is: see the [photo](docs/en/recovery-uart.md#where-gpio0-is).
4. The script runs both XMODEM stages and writes the bootloader. Then release GPIO0.

Details, with photos and an error table: [docs/en/recovery-uart.md](docs/en/recovery-uart.md).

## 5. Files

| File | What it is | Where it goes |
|---|---|---|
| [`firmware/bootloader/be5000-bootloader-w25n01kv.bin`](firmware/bootloader/) | 512 KB bootloader: BL2 (57 NAND chips) + BL31 + U-Boot | flash `0x0` (SSH: `be5000-install.sh bootloader`; UART: XMODEM #2) |
| [`firmware/bootloader/be5000-uart-bl2-stage1.bin`](firmware/bootloader/) | the same BL2 in a mini FIP | UART only, XMODEM #1 to BootROM |
| `calibration.bin` (you make it) | MT7992 EEPROM of your router, 128 KB | flash `0xA0000` |
| [`firmware/openwrt/…-squashfs-sysupgrade.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin) | OpenWrt ([iscle](https://github.com/iscle/openwrt/releases/tag/be5000-upstream-ppe-20260925)): FIT kernel + squashfs | `firmware` partition `0xC0000` (web failsafe or `sysupgrade`) |
| [`firmware/openwrt/…-initramfs-kernel.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin) | OpenWrt in RAM for testing and recovery | TFTP → `bootm`, does not touch flash |
| [`scripts/router/be5000-install.sh`](scripts/router/be5000-install.sh) | check, write calibration and bootloader with read-back verification | runs on the router |
| [`scripts/pc/`](scripts/pc/) | backup, calibration, UART recovery, bootloader check | runs on the PC |

Checksums and origin of the binaries: [firmware/bootloader/README.md](firmware/bootloader/README.md), [firmware/openwrt/README.md](firmware/openwrt/README.md).

## 6. How it works

- **Why it bricks.** BL2 reads the next stage from NAND using its own chip table. The BL2 from xinyooo v2026.05–v2026.06 (and the X-WRT preloader) has 56 chips, without W25N01KV. With that chip BL2 cannot read the FIP and calls `panic()`. After a warm reboot from Linux it sometimes boots, so test only with a cold boot.
- **What is in the bootloader.** BL2 with a list of 57 NAND chips (including W25N01KV), BL31 and xinyooo U-Boot 2026.01 with autoboot and web failsafe.
- **Why UART needs two files.** BootROM accepts at most `0x1F800` bytes over XMODEM, and only a FIP with a single BL2. Then BL2 itself prompts `Press x to update firmware`, accepts the full 512 KB image and writes it to flash.

Details, with logs and addresses: [docs/en/technical.md](docs/en/technical.md).

## 7. Sources and credits

- [xinyooo](https://github.com/xinyooo/openwrt/releases): AN7563 port, U-Boot with web failsafe, [PR #23960](https://github.com/openwrt/openwrt/pull/23960), [forum thread](https://forum.openwrt.org/t/release-custom-openwrt-u-boot-for-xiaomi-be5000-an7563/250004).
- [100PoR-new](https://github.com/openwrt/openwrt/pull/23960#issuecomment-6173662443): BL2 with W25N01KV (built with [make_airoha_atf](https://github.com/xinyooo/make_airoha_atf)) and the GPIO0 photo.
- [iscle](https://github.com/iscle/openwrt): OpenWrt builds, flash layout with calibration in `art`, DSA, PPE, Wi-Fi.
- [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha): BL2 sources used to work out the XMODEM recovery format.
- [Medvedolog, issue #17](https://github.com/Medvedolog/airoha-router-ursusflasher/issues/17): AN7552 BootROM observations.

## 8. Open questions

- [ ] Writing the bootloader from Xiaomi stock firmware is not tested on hardware: it is unknown whether the partition is writable there. The script checks this before writing.
- [ ] BL2 and BL31 are Airoha binaries without an open license; [publication request](https://github.com/openwrt/openwrt/pull/24257#issuecomment-5040866776).
- [ ] OpenWrt has no official BE5000 support yet: [PR #23960](https://github.com/openwrt/openwrt/pull/23960) is open.

Report successes and problems in [Issues](../../issues). Include the NAND chip and the output of `be5000-install.sh check`.
