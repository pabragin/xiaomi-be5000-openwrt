#!/usr/bin/env python3
"""Build the 128 KiB calibration block for the BE5000 replacement layout.

Input: this router's own backup - a 4 MiB stock Factory dump, a full flash
dump starting at offset 0 (stock or replacement layout), a 128 KiB
calibration block or a 7680-byte EEPROM. Output: calibration.bin
(MT7992 EEPROM + 0xFF padding) to be written at flash offset 0xA0000.
Never use another unit's data: it carries per-device calibration and MACs.
"""
import hashlib
import sys

EEPROM = 0x1E00
BLOCK = 0x20000
FACTORY = 0x400000
FACTORY_OFF = 0x180000
CAL_OFF = 0xA0000


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <Factory.bin | full-dump.bin | eeprom.bin> calibration.bin")
    data = open(sys.argv[1], "rb").read()
    if len(data) >= FACTORY_OFF + FACTORY and data[FACTORY_OFF:FACTORY_OFF + 2] == b"\x92\x79":
        data = data[FACTORY_OFF:FACTORY_OFF + FACTORY]
    elif len(data) >= CAL_OFF + BLOCK and data[CAL_OFF:CAL_OFF + 2] == b"\x92\x79":
        data = data[CAL_OFF:CAL_OFF + BLOCK]
    if len(data) not in (EEPROM, BLOCK, FACTORY):
        sys.exit("error: expected a 4 MiB Factory dump, a full flash dump, a 128 KiB calibration block or a 7680-byte EEPROM")
    eeprom = data[:EEPROM]
    if eeprom[:2] != b"\x92\x79":
        sys.exit("error: no MT7992 EEPROM signature (92 79)")
    mac = eeprom[4:10]
    if mac[0] & 1 or mac in (b"\0" * 6, b"\xff" * 6):
        sys.exit("error: invalid base MAC in EEPROM")
    if any(b != 0xFF for b in data[EEPROM:]):
        sys.exit("error: unexpected data after the EEPROM - refusing to drop it")
    block = eeprom + b"\xff" * (BLOCK - EEPROM)
    with open(sys.argv[2], "xb") as f:
        f.write(block)
    print(f"calibration block written: {sys.argv[2]}")
    print(f"  Wi-Fi base MAC {mac.hex(':')}, SHA-256 {hashlib.sha256(block).hexdigest()}")


if __name__ == "__main__":
    main()