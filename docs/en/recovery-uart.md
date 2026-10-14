# Bootloader recovery over UART

[← README](../../README.en.md) · [Русский](../ru/recovery-uart.md)

> [!IMPORTANT]
> **TL;DR.** No programmer is needed. The SoC BootROM can receive code over UART if **GPIO0 is shorted to GND** at power-on. The `be5000-uart-recover.py` script sends BL2 and then the bootloader in about 2 minutes, and BL2 writes the bootloader to flash itself.

## Contents

1. [Done when](#done-when)
2. [Requirements](#requirements)
3. [UART wiring](#uart-wiring)
4. [Where GPIO0 is](#where-gpio0-is)
5. [Recovery](#recovery)
6. [After recovery](#after-recovery)
7. [What the log shows](#what-the-log-shows)
8. [Troubleshooting](#troubleshooting)

## Done when

- [ ] The log contains `U-Boot 2026.01-OpenWrt-r34326`.
- [ ] After removing the GPIO0 jumper and a **cold** power-on, the log has no `PANIC` and U-Boot starts on its own.

## Requirements

| What | Comment |
|---|---|
| USB-UART 3.3 V | CP2102, CH340, FT232. **Not 5 V** |
| 3–4 wires, tweezers or a wire for GPIO0 | keep GPIO0 shorted during the whole recovery |
| PC with macOS or Linux, `python3` | on Windows: WSL + `usbipd` or a Linux live USB |
| Screwdriver | to remove the bottom cover; full disassembly is not needed |

## UART wiring

![UART wiring](../../images/uart-wiring.svg)

1. Adapter GND → router GND.
2. Adapter TX → router RX, adapter RX → router TX.
3. **Do not connect VCC.** The router runs from its own power supply.
4. Settings: 115200, 8N1, no flow control.

> [!TIP]
> Link check: run `python3 scripts/pc/be5000-uart-recover.py <port>` and power on the router **without** GPIO0. If text appears in `be5000-uart.log` (`Secure key does not exist`, `AN7552DRAMC`), the wiring is correct. If the log is empty, swap TX and RX.

Where the pins are: three pins at the board edge between the heatsinks; from left to right (LAN ports at the back) they are the router's **RX, GND, TX**. So the adapter TX goes to the left pin (RX) and the adapter RX to the right pin (TX). Photo: [right.com.cn](https://www.right.com.cn).

<img src="../../images/uart-pins.png" alt="UART on the Xiaomi BE5000 board: rx, gnd, tx" width="480">

## Where GPIO0 is

The GPIO0 pad is near the lower left corner of the AN7563 SoC, inside the shield frame. Photo: [100PoR-new](https://github.com/openwrt/openwrt/pull/23960#issuecomment-6173662443).

<img src="../../images/gpio0-location-by-100PoR-new.jpg" alt="GPIO0 on the Xiaomi BE5000 board" width="480">

Short GPIO0 to **GND**, for example to the shield frame next to it. Sign that the jumper works: the log shows `HWCONF is f` instead of `HWCONF is 1f`.

## Recovery

![Boot chain](../../images/boot-chain.svg)

1. Unplug the router from the wall socket.
2. Start the script. It waits up to 15 minutes:
   ```sh
   python3 scripts/pc/be5000-uart-recover.py /dev/ttyUSB0        # Linux
   python3 scripts/pc/be5000-uart-recover.py /dev/cu.usbserial-0001  # macOS
   ```
3. Short GPIO0 to GND and **hold** it.
4. Power on. The script does the rest:
   1. BootROM prints `Press x`, the script sends `x` and `be5000-uart-bl2-stage1.bin` (~10 s).
   2. BL2 starts, initializes memory and prints `Press x to update firmware`.
   3. The script sends `be5000-bootloader-w25n01kv.bin` (~70 s). BL2 writes it to flash at address 0 and starts U-Boot.
5. When the script prints `Done`, release GPIO0.

> [!WARNING]
> Do not cut power during step 4.3. If you did, just repeat from step 1: the SoC BootROM cannot be erased.

## After recovery

U-Boot immediately tries to boot OpenWrt from the `firmware` partition:

| What is in `firmware` | What happens | What to do |
|---|---|---|
| OpenWrt (iscle/xinyooo) | boots as usual | nothing |
| empty or Xiaomi stock firmware | web failsafe comes up at `http://192.168.1.1` | [install step 5](install-ssh.md#step-5-firmware-via-web-failsafe) |

If the flash still has the factory flash layout, move the calibration. Boot initramfs and run steps 2–3 of the [install guide](install-ssh.md) from OpenWrt in RAM:

```text
U-Boot> setenv serverip 192.168.1.10
U-Boot> tftpboot 0x84000000 openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin
U-Boot> bootm 0x84000000
```

The initramfs file is in [`firmware/openwrt/`](../../firmware/openwrt/); put it into the TFTP server root on the PC (`192.168.1.10`).

To get to the U-Boot console, run the script with `--stop-autoboot`.

## What the log shows

<details>
<summary>Broken BL2 (NAND chip not in the table)</summary>

```
HWCONF is 1f
AN7552DRAMC V0.4
dram_type = PCDDR3, data_rate = 1866
DRAM FLOW DONE!!!
[MTK] Start initializing gpio setting from 0x7c004...
[MTK] No GPIO low config found in uboot env!
[MTK] No GPIO high config found in uboot env!
PANIC at PC : 0x810017a9
```
</details>

<details>
<summary>Successful recovery</summary>

```
HWCONF is f
Press x
CC                         <- BootROM receives stage-1 over XMODEM
Secure key does not exist
AN7552DRAMC V0.4
DRAM FLOW DONE!!!
Press x to update firmware
CC                         <- BL2 receives the 512 KB bootloader
U-Boot 2026.01-OpenWrt-r34326-146052ab24 (May 12 2026 - 04:30:19 +0000)
CPU:   Airoha AN7563/AN7552
spi-nand: spi_nand nand@0: Winbond SPI NAND was found.
airoha-bmt: BBT v1 found at block 943 (0 bad blocks)
Hit any key to stop autoboot:  3
```
</details>

## Troubleshooting

| What the log shows | Cause | Fix |
|---|---|---|
| nothing | TX/RX swapped or no common ground | swap TX and RX, check GND |
| garbled characters | wrong baud rate | 115200 8N1 |
| `HWCONF is 1f`, no `Press x` | GPIO0 not shorted at power-on | short it more reliably with a wire and retry |
| `Press x`, then `^X^X^X` and a normal boot | BootROM did not get the file in time (~30 s) | start the script **before** power-on |
| `CAN` at block 1009 | the full 512 KB image was sent to BootROM | the first stage needs `be5000-uart-bl2-stage1.bin` |
| silence after stage-1 | a bare BL2 without a FIP header was sent | use the file from the repository |
| `PANIC at PC : 0x810017a9` right after `Press x to update firmware` | a FIP without the leading 0x800 zero bytes was sent | you need the full `be5000-bootloader-w25n01kv.bin`, 524288 bytes |
| `PANIC` on a normal boot after recovery | the written bootloader has a BL2 that does not know your chip | `python3 scripts/pc/be5000-check-bootloader.py file.bin --chip <chip>` |
