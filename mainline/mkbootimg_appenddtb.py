#!/usr/bin/env python3
"""Pack a boot image with the exact geometry of an image this tablet boots.

Reference: lk2nd-msm8226.img, which this very aboot loads and runs.
  kernel   @ 0x8000        (zImage, dtb appended inside the blob)
  ramdisk  @ 0x1000000, size 1
  tags     @ 0x100
  page     2048
  dt_size  0               <-- no QCDT blob at all

The kernel finds its device tree through CONFIG_ARM_APPENDED_DTB, the same way
lk2nd does. Nothing here is invented: every field is copied from that image.
"""
import argparse
import struct

MAGIC = b"ANDROID!"
HEADER = 1632


def pad(d, p):
    r = len(d) % p
    return d + b"\0" * ((p - r) % p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True, help="zImage with dtb appended")
    ap.add_argument("--out", required=True)
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--cmdline",
                    default="console=tty0 console=ttyMSM0,115200n8 earlycon panic=10")
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    page = a.pagesize

    hdr = MAGIC + struct.pack(
        "<10I",
        len(kernel), 0x00008000,   # kernel size / addr
        1, 0x01000000,             # ramdisk size (1, as in lk2nd) / addr
        0, 0x00f00000,             # second size / addr
        0x100,                     # tags addr
        page,
        0,                         # dt_size: no QCDT, dtb is appended
        0)
    hdr += b"msm8226-rubenslt".ljust(16, b"\0")
    hdr += a.cmdline.encode()[:511].ljust(512, b"\0")
    hdr = hdr.ljust(HEADER, b"\0")

    img = pad(hdr, page) + pad(kernel, page) + pad(b"\0", page)
    # Samsung's aboot refuses any boot image whose payload is not followed
    # by this literal 16-byte marker: without it the device drops into
    # download mode instead of running the kernel. Both images this tablet
    # boots (lk2nd and its factory recovery) end with it.
    img += b"SEANDROIDENFORCE"
    open(a.out, "wb").write(img)

    d = open(a.out, "rb").read()
    ks, ka, rs, ra, ss, sa, tags, pg, dtsz = struct.unpack("<9I", d[8:44])
    print(f"wrote {a.out}: {len(d)} bytes")
    print(f"  kernel {ks} @ 0x{ka:x}  ramdisk size {rs} @ 0x{ra:x}  "
          f"tags 0x{tags:x}  page {pg}  dt_size {dtsz}")
    assert (ka, ra, tags, pg, dtsz, rs) == (0x8000, 0x1000000, 0x100, 2048, 0, 1)
    print("  header is geometrically identical to the image this device boots")


if __name__ == "__main__":
    main()
