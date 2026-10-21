# Bootloader

| File | Size | SHA-256 |
|---|---|---|
| `be5000-bootloader-w25n01kv.bin` | 524288 | `33820b3fe5f03478183f2d7c81e09f48668a1eb37e6fc4f3efc16187f983745d` |
| `be5000-uart-bl2-stage1.bin` | 110202 | `e815120eda4207e604cdde83945e583cc1bbace3522a3fa0503d54155dae82dd` |

## be5000-bootloader-w25n01kv.bin

Written to flash offset `0x0`. 0x800 bytes of zeros, then a TF-A FIP (`0xAA640001`), and the U-Boot environment at `0x7C000`:

| Part | FIP offset | Size | Origin |
|---|---|---|---|
| BL2 | `0x400` | `0x1AE1A` | Airoha BL2 with a 57-chip SPI-NAND table incl. **W25N01KV** (U-Boot r35200+4 build, 2026-07-02, [PR #23960](https://github.com/openwrt/openwrt/pull/23960)) |
| BL31 | `0x1B400` | `0xA232` | Airoha TF-A BL31 (identical in all known BE5000 builds) |
| BL33 | `0x25800` | `0x29853` | U-Boot `2026.01-OpenWrt-r34326-146052ab24` from [xinyooo v2026.05-r1](https://github.com/xinyooo/openwrt/releases/tag/v2026.05-r1): `bootcmd`, web failsafe on `192.168.1.1`, TFTP |

### U-Boot environment (`0x7C000`, 16 KiB)

The image carries the environment of the `u-boot-env` partition: the built-in U-Boot defaults plus a Reset button check. **Hold Reset while powering on** and U-Boot starts the web failsafe on `http://192.168.1.1` instead of OpenWrt (set the PC to `192.168.1.10/24`, U-Boot has no DHCP).

```
bootcmd=run check_reset; run uboot_boot || run bootcmd_failsafe
check_reset=itest.b *0x1fbf0204 -lt 0x20 && run reset_failsafe; …   (GPIO 5, low while pressed)
reset_failsafe=echo "Reset button held"; run bootcmd_failsafe
uboot_boot=mtd read firmware ${loadaddr} 0x0 ${fitsize} && bootm ${loadaddr}
bootcmd_failsafe=echo "*** Failsafe Web UI: http://${ipaddr}/ ***"; httpd
loadaddr=0x81800000  fitsize=0x500000  ipaddr=192.168.1.1  serverip=192.168.1.10
```

- **How the check works:** this U-Boot has no `button` or `gpio` command, so `check_reset` reads byte 0 of the GPIO data register (GPIO 0–7) and tests bit 5 as four `itest` ranges. If the check fails, the normal boot runs.
- **Who gets it:** an install from the Xiaomi firmware and the UART recovery write the whole 512 KiB, environment included. A router already on OpenWrt gets it at the first boot of an image of this build: `13_xiaomi-be5000-uboot-env` writes it into the `u-boot-env` block (`0x60000`, 128 KiB) if that block is empty, and leaves a block with any data alone.
- **Rebuild:** `python3 scripts/pc/be5000-uboot-env.py firmware/bootloader/be5000-bootloader-w25n01kv.bin` writes the environment into the image; `be5000-check-bootloader.py` shows the stored `bootcmd` and its CRC.
- **Without the environment** (empty or bad CRC) U-Boot uses its built-in default: `bootcmd=run uboot_boot || run bootcmd_failsafe`, so the failsafe starts only when OpenWrt does not load.

## be5000-uart-bl2-stage1.bin

The same BL2 wrapped in a one-entry FIP (BL2 at `0x60`). Only for BootROM XMODEM recovery (stage 1); never write it to flash.

## Check any other bootloader before flashing

```sh
python3 scripts/pc/be5000-check-bootloader.py some-bl2-bl31-uboot.bin --chip W25N01KV
```

Known bad for W25N01KV: xinyooo v2026.05-r1 / v2026.05-r2 / v2026.06-r1 `bl2-bl31-uboot.bin` (`8d363ec4…`) and `preloader.bin` (`dc7a08fd…`), X-WRT `26.10` `preloader.bin` (same BL2).

BL2/BL31 are Airoha binaries without a published licence; U-Boot is GPL-2.0.
