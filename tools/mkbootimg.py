#!/usr/bin/env python3
"""Dependency-free Android/Samsung boot image packer (header v0/v1).

Usage:
  python mkbootimg.py --kernel kernel --ramdisk ramdisk.gz --out boot.img \
      --kernel-addr 0x10008000 --ramdisk-addr 0x11000000 --tags-addr 0x10000100 \
      --page-size 2048 --header-version 1 --cmdline "console=ttySAC2" [--dtb dt.img]
"""
import argparse
import hashlib
import os
import struct


def pages(n, ps):
    return (n + ps - 1) // ps * ps if n else 0


def pad(b, ps):
    r = pages(len(b), ps)
    return b + b"\0" * (r - len(b))


def build(kernel, ramdisk, second, dtb, args):
    ps = args.page_size
    k = open(kernel, "rb").read() if kernel else b""
    r = open(ramdisk, "rb").read() if ramdisk else b""
    s = open(second, "rb").read() if second else b""
    dt = open(dtb, "rb").read() if dtb else b""

    sha = hashlib.sha1(k + r + s + struct.pack("<I", len(k)) + struct.pack("<I", len(r)))
    img_id = (sha.digest() + b"\0" * 32)[:32]

    cmdline = (args.cmdline or "").encode()
    extra = (args.extra_cmdline or "").encode()

    hdr = struct.pack(
        "<8s10I16s512s32s1024s",
        b"ANDROID!",
        len(k), args.kernel_addr,
        len(r), args.ramdisk_addr,
        len(s), args.second_addr,
        args.tags_addr,
        ps, args.header_version, args.os_version,
        args.name.encode()[:16],
        cmdline[:512],
        img_id,
        extra[:1024],
    )

    if args.header_version >= 1:
        hdr += struct.pack("<I", 0)          # recovery_dtbo_size
        hdr += struct.pack("<Q", 0)          # recovery_dtbo_offset
        hdr += struct.pack("<I", 1648)       # header_size
        body = pad(hdr, ps) + pad(k, ps) + pad(r, ps) + pad(s, ps)
    else:
        body = pad(hdr, ps) + pad(k, ps) + pad(r, ps) + pad(s, ps)

    if dt:
        body += pad(dt, ps)

    open(args.out, "wb").write(body)
    print("wrote %s (%d bytes): kernel=%d ramdisk=%d dtb=%d page=%d hdr=%d"
          % (args.out, len(body), len(k), len(r), len(dt), ps, args.header_version))


def auto_int(x):
    return int(x, 0)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--kernel", default="")
    p.add_argument("--ramdisk", default="")
    p.add_argument("--second", default="")
    p.add_argument("--dtb", default="")
    p.add_argument("--out", required=True)
    p.add_argument("--kernel-addr", type=auto_int, default=0x10008000)
    p.add_argument("--ramdisk-addr", type=auto_int, default=0x11000000)
    p.add_argument("--second-addr", type=auto_int, default=0x10f00000)
    p.add_argument("--tags-addr", type=auto_int, default=0x10000100)
    p.add_argument("--page-size", type=int, default=2048)
    p.add_argument("--header-version", type=int, default=1)
    p.add_argument("--os-version", type=auto_int, default=0)
    p.add_argument("--name", default="")
    p.add_argument("--cmdline", default="")
    p.add_argument("--extra-cmdline", default="")
    build(p.parse_args().kernel, p.parse_args().ramdisk, p.parse_args().second,
          p.parse_args().dtb, p.parse_args())
