# Bootloader / Загрузчик

| File | Size | SHA-256 |
|---|---|---|
| `be5000-bootloader-w25n01kv.bin` | 524288 | `7b973870f0a95109b95373c497c35aa7f7180cc74ef7c024130c8d859af98975` |
| `be5000-uart-bl2-stage1.bin` | 110202 | `e815120eda4207e604cdde83945e583cc1bbace3522a3fa0503d54155dae82dd` |

## be5000-bootloader-w25n01kv.bin

Written to flash offset `0x0`. 0x800 bytes of zeros, then a TF-A FIP (`0xAA640001`):

| Part | FIP offset | Size | Origin |
|---|---|---|---|
| BL2 | `0x400` | `0x1AE1A` | Airoha BL2 with a 57-chip SPI-NAND table incl. **W25N01KV** (U-Boot r35200+4 build, 2026-07-02, [PR #23960](https://github.com/openwrt/openwrt/pull/23960)) |
| BL31 | `0x1B400` | `0xA232` | Airoha TF-A BL31 (identical in all known BE5000 builds) |
| BL33 | `0x25800` | `0x29853` | U-Boot `2026.01-OpenWrt-r34326-146052ab24` from [xinyooo v2026.05-r1](https://github.com/xinyooo/openwrt/releases/tag/v2026.05-r1): `bootcmd`, web failsafe on `192.168.1.1`, TFTP |

U-Boot default environment:

```
bootcmd=run uboot_boot || run bootcmd_failsafe
uboot_boot=mtd read firmware ${loadaddr} 0x0 ${fitsize} && bootm ${loadaddr}
bootcmd_failsafe=echo "*** Failsafe Web UI: http://${ipaddr}/ ***"; httpd
loadaddr=0x81800000  fitsize=0x500000  ipaddr=192.168.1.1  serverip=192.168.1.10
```

## be5000-uart-bl2-stage1.bin

The same BL2 wrapped in a one-entry FIP (BL2 at `0x60`). Only for BootROM XMODEM recovery (stage 1); never write it to flash.

## Check any other bootloader before flashing

```sh
python3 scripts/pc/be5000-check-bootloader.py some-bl2-bl31-uboot.bin --chip W25N01KV
```

Known bad for W25N01KV: xinyooo v2026.05-r1 / v2026.05-r2 / v2026.06-r1 `bl2-bl31-uboot.bin` (`8d363ec4…`) and `preloader.bin` (`dc7a08fd…`), X-WRT `26.10` `preloader.bin` (same BL2).

BL2/BL31 are Airoha binaries without a published licence; U-Boot is GPL-2.0.
