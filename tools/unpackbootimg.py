#!/usr/bin/env python3
"""Dependency-free Android/Samsung boot image unpacker (header v0/v1/v2).

Usage: python unpackbootimg.py <boot.img> <outdir>
Writes: kernel, ramdisk, second, dtb (if present), header.json
"""
import json
import os
import struct
import sys


def pages(n, ps):
    return (n + ps - 1) // ps * ps if n else 0


def unpack(path, outdir):
    d = open(path, "rb").read()
    if d[:8] != b"ANDROID!":
        raise SystemExit("not an Android boot image: %s" % d[:16])
    (magic, kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, page_size, header_version,
     os_version, name, cmdline, img_id, extra_cmdline) = struct.unpack(
        "<8s10I16s512s32s1024s", d[:1632])

    hdr = {
        "file": os.path.basename(path),
        "file_size": len(d),
        "kernel_size": kernel_size,
        "kernel_addr": hex(kernel_addr),
        "ramdisk_size": ramdisk_size,
        "ramdisk_addr": hex(ramdisk_addr),
        "second_size": second_size,
        "tags_addr": hex(tags_addr),
        "page_size": page_size,
        "header_version": header_version,
        "os_version": hex(os_version),
        "name": name.rstrip(b"\0").decode("latin1"),
        "cmdline": cmdline.rstrip(b"\0").decode("latin1"),
        "extra_cmdline": extra_cmdline.rstrip(b"\0").decode("latin1"),
        "id": img_id.hex(),
    }

    header_total = 1632
    if header_version >= 1:
        dtbo_size = struct.unpack("<I", d[1632:1636])[0]
        dtbo_offset = struct.unpack("<Q", d[1636:1644])[0]
        hdr["recovery_dtbo_size"] = dtbo_size
        hdr["recovery_dtbo_offset"] = hex(dtbo_offset)
        hdr["header_size"] = struct.unpack("<I", d[1644:1648])[0]
        header_total = 1648
    if header_version >= 2:
        hdr["dtb_size"] = struct.unpack("<I", d[1648:1652])[0]
        hdr["dtb_addr"] = hex(struct.unpack("<Q", d[1652:1660])[0])
        header_total = 1660

    off = pages(header_total, page_size)
    os.makedirs(outdir, exist_ok=True)

    def take(size, fname):
        nonlocal off
        if not size:
            return
        blob = d[off:off + size]
        open(os.path.join(outdir, fname), "wb").write(blob)
        off += pages(size, page_size)

    take(kernel_size, "kernel")
    take(ramdisk_size, "ramdisk.gz")
    take(second_size, "second")
    if header_version >= 1 and hdr.get("recovery_dtbo_size"):
        take(hdr["recovery_dtbo_size"], "recovery_dtbo")
    if header_version >= 2 and hdr.get("dtb_size"):
        take(hdr["dtb_size"], "dtb")

    # Samsung/exynos images often append a QCDT/FDT blob after the header blocks.
    rest = d[off:off + 64]
    hdr["next_block_head"] = rest[:16].hex()
    tail = d[off:]
    first_fdt = tail.find(b"\xd0\x0d\xfe\xed")
    hdr["trailing_fdt_offset"] = off + first_fdt if first_fdt >= 0 else -1
    if first_fdt >= 0:
        open(os.path.join(outdir, "trailing.fdt"), "wb").write(tail[first_fdt:])

    open(os.path.join(outdir, "header.json"), "w").write(json.dumps(hdr, indent=2))
    print(json.dumps(hdr, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    unpack(sys.argv[1], sys.argv[2])
