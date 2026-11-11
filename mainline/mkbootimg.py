#!/usr/bin/env python3
"""Minimal Android boot image (v0) packer.

The CI image does not ship mkbootimg, and this device needs a boot image to
feed lk2nd, so packing it here avoids that dependency. Pure stdlib.

Usage:
  mkbootimg.py --kernel zImage-dtb --output boot.img [--pagesize 2048]
               [--base 0x00008000] [--cmdline "console=ttyMSM0,115200n8"]

Writes an image with an empty ramdisk and no second stage; the device tree is
expected to be appended to the kernel (zImage-dtb), which is what lk2nd wants
for msm8226.
"""
import argparse
import hashlib
import struct
import sys

MAGIC = b"ANDROID!"
NAME = b"msm8226-rubenslte"
HEADER_SIZE = 1632


def pad(data, page):
    rem = len(data) % page
    return data + b"\0" * ((page - rem) % page)


def build(kernel, pagesize, base, cmdline, kernel_offset, ramdisk_offset):
    kernel_addr = base + 0x00008000
    ramdisk_addr = base + 0x01000000
    second_addr = base + 0x00f00000
    tags_addr = base + 0x00000100

    name = NAME[:16].ljust(16, b"\0")
    cmd = cmdline.encode()[:511].ljust(512, b"\0")
    extra = b"".ljust(1024, b"\0")
    digest = hashlib.sha1(kernel).digest()
    ids = (digest + b"\0" * 12)[:32]

    header = MAGIC + struct.pack(
        "<10I", len(kernel), kernel_addr, 0, ramdisk_addr, 0, second_addr,
        tags_addr, pagesize, 0, 0)
    header += name + cmd + ids + extra
    header = header.ljust(HEADER_SIZE, b"\0")

    return pad(header, pagesize) + pad(kernel, pagesize)


def verify(img, pagesize):
    assert img[:8] == MAGIC, "bad magic"
    (ksize, kaddr, rsize, raddr, ssize, saddr, tags, page, dt_size,
     osver) = struct.unpack("<10I", img[8:48])
    name = img[48:64].rstrip(b"\0")
    cmdline = img[64:576].rstrip(b"\0")
    print(f"  magic      : {img[:8].decode()}")
    print(f"  kernel     : {ksize} bytes at {hex(kaddr)}")
    print(f"  ramdisk    : {rsize} bytes at {hex(raddr)}")
    print(f"  page size  : {page}")
    print(f"  name       : {name.decode(errors='replace')}")
    print(f"  cmdline    : {cmdline.decode(errors='replace') or '(none)'}")
    expected = page + ((ksize + page - 1) // page) * page
    print(f"  expected   : {expected} bytes (header + padded kernel)")
    return expected == len(img)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--base", default="0x00008000")
    # tty0 (fbcon) is what makes a hung boot visible on the tablet's screen;
    # there is no accessible UART, so ttyMSM0 alone shows nothing.
    ap.add_argument("--cmdline",
                    default="console=tty0 console=ttyMSM0,115200n8 earlycon panic=10")
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    img = build(kernel, a.pagesize, int(a.base, 16), a.cmdline, 0x8000, 0x8000)
    open(a.output, "wb").write(img)

    print(f"wrote {a.output}: {len(img)} bytes")
    ok = verify(img, a.pagesize)
    print("  layout consistent:", ok)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
