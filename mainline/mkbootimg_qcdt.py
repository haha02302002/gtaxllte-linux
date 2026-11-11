#!/usr/bin/env python3
"""Pack an Android boot image with a QCDT dt.img attached (Samsung aboot path).

Usage:
  mkbootimg_qcdt.py --kernel zImage --dt dt.img --output boot.img
                    [--pagesize 2048] [--base 0x00008000]
                    [--cmdline "..."]
"""
import argparse
import struct
import sys

MAGIC = b"ANDROID!"
HEADER = 1632


def pad(data, page):
    rem = len(data) % page
    return data + b"\0" * ((page - rem) % page)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dt", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--pagesize", type=int, default=2048)
    # Addresses copied from this tablet's own factory boot layout as seen in
    # the recovery image it boots: kernel 0x8000, ramdisk 0x2000000,
    # tags 0x1e00000, page 2048. Do not change these without re-reading a
    # boot image the device has actually booted.
    ap.add_argument("--base", default="0x00000000")
    ap.add_argument("--cmdline", default="console=tty0 console=ttyMSM0,115200n8 earlycon panic=10")
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    dt = open(a.dt, "rb").read()
    if dt[:4] != b"QCDT":
        sys.exit("dt.img is not QCDT")

    base = int(a.base, 16)
    hdr = MAGIC + struct.pack(
        "<10I",
        len(kernel), base + 0x8000,     # kernel size / addr
        0, base + 0x02000000,            # ramdisk size / addr (factory value)
        0, base + 0x00f00000,            # second size / addr
        base + 0x1e00000,                # tags addr (factory value)
        a.pagesize,
        len(dt),                         # dt_size (v0 field)
        0)
    hdr += b"msm8226-rubenslt".ljust(16, b"\0")
    hdr += a.cmdline.encode()[:511].ljust(512, b"\0")
    hdr += b"\0" * 32
    hdr += b"\0" * 1024
    hdr = hdr.ljust(HEADER, b"\0")

    img = pad(hdr, a.pagesize) + pad(kernel, a.pagesize) + pad(dt, a.pagesize)

    # Samsung's aboot refuses any boot image whose payload is not followed
    # by this literal 16-byte marker: without it the device drops straight
    # into download mode instead of running the kernel. Both images this
    # tablet boots (lk2nd, and its factory recovery) carry it.
    img += b"SEANDROIDENFORCE"
    open(a.output, "wb").write(img)

    # verify by reading our own header back
    h = img[:48]
    ks, ka, rs, ra, ss, sa, tags, page, dtsz = struct.unpack("<9I", h[8:44])[0:9]
    print(f"wrote {a.output}: {len(img)} bytes")
    print(f"  kernel {ks} @ {hex(ka)}   dt {dtsz} bytes   page {page}")
    print(f"  cmdline: {a.cmdline}")
    expect = (page + (len(kernel) + page - 1)//page*page
              + (len(dt) + page - 1)//page*page + len(b"SEANDROIDENFORCE"))
    print(f"  layout consistent: {expect == len(img)}")


if __name__ == "__main__":
    main()
