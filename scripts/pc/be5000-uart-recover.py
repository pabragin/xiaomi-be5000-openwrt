#!/usr/bin/env python3
"""Unbrick a Xiaomi BE5000 (Airoha AN7563) over UART, no flash programmer.

Two XMODEM stages, both driven automatically:
  1. BootROM "Press x"                    -> stage-1 BL2 (mini FIP, runs from SRAM)
  2. BL2 "Press x to update firmware"     -> 512 KiB bootloader image; BL2 writes it
                                             to flash offset 0 and starts U-Boot
Run the script first, then short GPIO0 to GND and power the router on.

  python3 be5000-uart-recover.py /dev/ttyUSB0
  python3 be5000-uart-recover.py /dev/cu.usbserial-0001 --stop-autoboot

macOS and Linux (termios). On Windows use WSL with usbipd or a Linux live USB.
"""
import argparse
import os
import select
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.join(HERE, "..", "..", "firmware", "bootloader")


def say(*msg):
    print(time.strftime("%H:%M:%S"), *msg, flush=True)


class Port:
    def __init__(self, dev, log):
        self.fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[4] = a[5] = termios.B115200
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        self.log = open(log, "ab", buffering=0)

    def read1(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return b""
        d = os.read(self.fd, 1)
        self.log.write(d)
        return d

    def write(self, data):
        os.write(self.fd, data)

    def wait_for(self, pattern, timeout):
        buf, t = b"", time.time()
        while time.time() - t < timeout:
            buf = (buf + self.read1(1))[-120:]
            if buf.endswith(pattern):
                return True
        return False


def crc16(data):
    c = 0
    for x in data:
        c ^= x << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) if c & 0x8000 else (c << 1)
        c &= 0xFFFF
    return c


def xmodem_send(port, path):
    data = open(path, "rb").read()
    port.write(b"x")
    buf, t = b"", time.time()
    while time.time() - t < 20:  # receiver announces CRC mode with 'C'
        buf = (buf + port.read1(1))[-2:]
        if buf == b"CC":
            break
    else:
        sys.exit("no XMODEM 'C' from the router")
    blocks = (len(data) + 127) // 128
    for i in range(blocks):
        blk = data[i * 128:(i + 1) * 128].ljust(128, b"\x1a")
        num = (i + 1) & 0xFF
        pkt = bytes([1, num, 255 - num]) + blk + crc16(blk).to_bytes(2, "big")
        for _ in range(10):
            port.write(pkt)
            r = port.read1(5)
            while r == b"C":
                r = port.read1(5)
            if r == b"\x06":
                break
            if r == b"\x18":
                sys.exit(f"router cancelled the transfer at block {i + 1} (CAN)")
        else:
            sys.exit(f"no ACK for block {i + 1}")
        if (i + 1) % 512 == 0 or i + 1 == blocks:
            say(f"  {os.path.basename(path)}: block {i + 1}/{blocks}")
    for _ in range(10):
        port.write(b"\x04")
        if port.read1(3) == b"\x06":
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="serial device, e.g. /dev/ttyUSB0 or /dev/cu.usbserial-0001")
    ap.add_argument("--stage1", default=os.path.join(FW, "be5000-uart-bl2-stage1.bin"))
    ap.add_argument("--image", default=os.path.join(FW, "be5000-bootloader-w25n01kv.bin"))
    ap.add_argument("--stop-autoboot", action="store_true", help="interrupt U-Boot autoboot and stay at the prompt")
    ap.add_argument("--log", default="be5000-uart.log")
    args = ap.parse_args()

    image = open(args.image, "rb").read()
    if len(image) != 0x80000 or image[0x800:0x804] != bytes.fromhex("010064aa"):
        sys.exit("image must be a 524288-byte bootloader with a FIP header at 0x800")

    port = Port(args.port, args.log)
    say("Waiting for BootROM. Short GPIO0 to GND and power the router on now.")
    if not port.wait_for(b"Press x\r\n", 900):
        sys.exit("no 'Press x' from BootROM (check TX/RX/GND and the GPIO0 short)")
    say("BootROM recovery prompt found - sending stage-1 BL2")
    xmodem_send(port, args.stage1)
    if not port.wait_for(b"Press x to update firmware\r\n", 60):
        sys.exit("BL2 did not ask for firmware - see the log")
    say("BL2 is running - sending the bootloader image (about 70 s)")
    xmodem_send(port, args.image)
    say("Bootloader sent; BL2 writes it to flash and starts U-Boot")

    buf, t = b"", time.time()
    while time.time() - t < 180:
        r, _, _ = select.select([port.fd], [], [], 0.2)
        if not r:
            continue
        d = os.read(port.fd, 4096)
        port.log.write(d)
        sys.stdout.write(d.decode("latin1"))
        buf = (buf + d)[-400:]
        if args.stop_autoboot and b"autoboot" in buf:
            for _ in range(5):
                port.write(b"\x03\r")
                time.sleep(0.05)
        if buf.rstrip().endswith(b"U-Boot>") or b"Failsafe Web UI" in buf or b"Starting kernel" in buf:
            break
    print()
    say("Done. Remove the GPIO0 short now, otherwise the next boot enters BootROM recovery again.")


if __name__ == "__main__":
    main()