#!/usr/bin/env python3
"""Build the bring-up initramfs: /init + a static ARM busybox, as cpio.gz (newc).

Written by hand instead of shelling out to cpio/gzip so it produces identical
output on the Windows host and in CI.

Usage: mkinitramfs.py --busybox bb-arm --output initramfs.cpio.gz
"""
import argparse
import gzip
import os

NUL = b"\x00"


def align4(data):
    return data + NUL * ((4 - len(data) % 4) % 4)


def entry(name, data, mode, ino, is_dir=False, is_link=False, linkname=b""):
    if is_dir:
        ftype = 0o040000
    elif is_link:
        ftype = 0o120000
    else:
        ftype = 0o100000
    body = linkname if is_link else data
    fields = [ino, mode | ftype, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name) + 1, 0]
    hdr = b"070701" + b"".join(b"%08X" % f for f in fields) + name.encode() + NUL
    return align4(hdr) + align4(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--busybox", required=True)
    ap.add_argument("--init", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "initramfs", "init"))
    ap.add_argument("--output", required=True)
    a = ap.parse_args()

    init = open(a.init, "rb").read()
    bb = open(a.busybox, "rb").read()

    out = b""
    out += entry("", b"", 0o755, 1, is_dir=True)
    out += entry("init", init, 0o755, 2)
    out += entry("bin", b"", 0o755, 3, is_dir=True)
    out += entry("bin/busybox", bb, 0o755, 4)
    out += entry("bin/sh", b"", 0o777, 5, is_link=True, linkname=b"busybox")
    out += entry("TRAILER!!!", b"", 0, 0)

    with open(a.output, "wb") as f:
        f.write(gzip.compress(out, 9))
    print("  %s: %d B ramdisk, %d B compressed" % (a.output, len(out), os.path.getsize(a.output)))


if __name__ == "__main__":
    main()
