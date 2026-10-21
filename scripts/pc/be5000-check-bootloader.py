#!/usr/bin/env python3
"""Inspect an AN7563 bl2-bl31-uboot image or a preloader before flashing it.

Prints the FIP contents, the U-Boot version and the SPI-NAND chips that the
BL2 can boot from. A BL2 that does not list your chip panics on every cold
boot ("PANIC at PC : 0x810017a9").

  python3 be5000-check-bootloader.py image.bin [--chip W25N01KV]
"""
import argparse
import lzma
import re
import struct
import sys
import zlib

NAMES = {
    "5ff9ec0b": "BL2",
    "47d4086d": "BL31",
    "d6d0eea7": "BL33 (U-Boot)",
}


def fip_entries(d):
    base = 0x800 if d[:4] == b"\0\0\0\0" else 0
    if d[base:base + 4] != bytes.fromhex("010064aa"):
        sys.exit("no FIP header at 0x0 or 0x800")
    o, out = base + 16, []
    while d[o:o + 16] != b"\0" * 16:
        off, size, _ = struct.unpack("<QQQ", d[o + 16:o + 40])
        out.append((d[o:o + 4].hex(), base + off, size))
        o += 40
    return out


def lzma_parts(blob):
    parts = []
    for i in range(len(blob) - 13):
        if blob[i] == 0x5D and blob[i + 1:i + 5] == b"\x00\x00\x80\x00":
            try:
                r = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(blob[i:], max_length=1 << 22)
            except lzma.LZMAError:
                continue
            if len(r) > 4096:
                parts.append(r)
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--chip", default="W25N01KV")
    a = ap.parse_args()
    d = open(a.image, "rb").read()
    ok = True
    for uuid, off, size in fip_entries(d):
        name = NAMES.get(uuid, uuid)
        blob = d[off:off + size]
        print(f"{name:14} offset 0x{off:05x} size 0x{size:05x}")
        if name == "BL2":
            chips = set()
            for p in lzma_parts(blob):
                chips |= {m.decode() for m in re.findall(rb"_SPI_NAND_DEVICE_ID_([A-Z0-9_]+)", p)}
            print(f"  BL2 SPI-NAND table: {len(chips)} chips")
            print("  " + " ".join(sorted(chips)))
            has = a.chip.upper() in chips
            ok &= has
            print(f"  {a.chip}: {'SUPPORTED' if has else 'MISSING - this BL2 will PANIC on boot with this chip'}")
        if name.startswith("BL33"):
            u = lzma_parts(blob) or [blob]
            v = re.search(rb"U-Boot 20[0-9.]+[^\x00]{0,80}", u[0])
            env = re.search(rb"bootcmd=[^\x00]+", u[0])
            print("  " + (v.group().decode("latin1") if v else "U-Boot version not found"))
            print("  " + (env.group().decode("latin1") if env else "no bootcmd: this U-Boot does not boot by itself"))
    stored = d[0x7C000:0x80000] if len(d) >= 0x80000 else b""
    if stored and any(stored):
        crc_ok = struct.unpack("<I", stored[:4])[0] == zlib.crc32(stored[4:])
        print(f"u-boot-env     offset 0x7c000 size 0x04000 crc {'OK' if crc_ok else 'BAD (U-Boot uses its defaults)'}")
        for kv in stored[4:].split(b"\0\0")[0].split(b"\0"):
            if kv.startswith(b"bootcmd="):
                print("  " + kv.decode("latin1"))
    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
