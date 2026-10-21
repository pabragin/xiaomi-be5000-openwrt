#!/usr/bin/env python3
"""Build the U-Boot environment of the Xiaomi BE5000 bootloader and put it into
the bootloader image at 0x7C000 (the u-boot-env partition, 16 KiB).

The environment is the built-in default of the xinyooo U-Boot plus a check of
the Reset button (GPIO 5, low while pressed): held at power-on, it starts the
web failsafe on http://192.168.1.1 instead of OpenWrt.

This U-Boot has no `button` or `gpio` command, so the check reads byte 0 of the
GPIO data register (GPIO 0-7) with `itest` and tests bit 5 as four ranges. If
the check fails for any reason, the normal boot runs.

usage: be5000-uboot-env.py BOOTLOADER.bin        # rewrite the image in place
       be5000-uboot-env.py --env-only ENV.bin    # only the 16 KiB environment
"""
import struct
import sys
import zlib

ENV_OFS = 0x7C000
ENV_SIZE = 0x4000
GPIO_DATA = "*0x1fbf0204"


def reset_check():
    checks = []
    for lo, hi in ((0x00, 0x20), (0x40, 0x60), (0x80, 0xA0), (0xC0, 0xE0)):
        c = f"itest.b {GPIO_DATA} -lt {hi:#x}"
        if lo:
            c = f"itest.b {GPIO_DATA} -ge {lo:#x} && " + c
        checks.append(c + " && run reset_failsafe")
    return "; ".join(checks)


ENV = [
    "loadaddr=0x81800000",
    "ipaddr=192.168.1.1",
    "serverip=192.168.1.10",
    "bootargs=console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x1fbf0000 root=/dev/mtdblock5 ro rootwait",
    "fitsize=0x500000",
    "uboot_boot=mtd read firmware ${loadaddr} 0x0 ${fitsize} && bootm ${loadaddr}",
    'bootcmd_failsafe=echo "*** Failsafe Web UI: http://${ipaddr}/ ***"; httpd',
    'reset_failsafe=echo "Reset button held"; run bootcmd_failsafe',
    "check_reset=" + reset_check(),
    "bootcmd=run check_reset; run uboot_boot || run bootcmd_failsafe",
]


def env_image():
    data = b"\0".join(e.encode() for e in ENV) + b"\0\0"
    assert len(data) <= ENV_SIZE - 4
    data = data.ljust(ENV_SIZE - 4, b"\0")
    return struct.pack("<I", zlib.crc32(data)) + data


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--env-only":
        open(sys.argv[2], "wb").write(env_image())
        return
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    img = bytearray(open(path, "rb").read())
    if len(img) != 0x80000 or img[0x800:0x804] != bytes.fromhex("010064aa"):
        sys.exit("not a 512 KiB BE5000 bootloader image")
    region = img[ENV_OFS:ENV_OFS + ENV_SIZE]
    if any(region) and region != env_image():
        sys.exit("0x7C000 already holds a different environment")
    img[ENV_OFS:ENV_OFS + ENV_SIZE] = env_image()
    open(path, "wb").write(img)
    print(f"environment written at {ENV_OFS:#x}, crc {struct.unpack('<I', env_image()[:4])[0]:08x}")


if __name__ == "__main__":
    main()
