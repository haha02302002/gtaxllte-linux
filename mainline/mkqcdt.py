#!/usr/bin/env python3
"""Build a QCDT v2 dt.img that Samsung aboot on this tablet accepts.

Layout verified against the dt.img inside the lk2nd image this device really
booted, parsed per Qualcomm's LocateDeviceTree.h:

  header: magic "QCDT", version=2, num_entries        (3 x u32)
  record: platform_id, variant_id, board_hw_subtype, soc_rev,
          offset, size                                (6 x u32 = 24 bytes)
  offsets are absolute from the start of the blob.

The factory table in this tablet's own recovery image (dumped in TWRP) has
exactly three entries: platform 0xc708ff01, variants 2/3/4, soc_rev 0x20000.

Usage:
  mkqcdt.py --dtb rubenslte.dtb --out rubenslte-dt.img
"""
import argparse
import struct
import sys

MAGIC = b"QCDT"
VERSION = 2
RECORD_SIZE = 24


def align(n, a):
    return (n + a - 1) // a * a


def build(dtb, ids):
    data_start = align(12 + RECORD_SIZE * len(ids), 2048)

    table = bytearray()
    table += MAGIC
    table += struct.pack("<II", VERSION, len(ids))

    payload = bytearray()
    cursor = data_start
    for platform_id, variant_id, subtype, soc_rev in ids:
        table += struct.pack("<6I", platform_id, variant_id, subtype,
                             soc_rev, cursor, len(dtb))
        payload += dtb
        pad = align(len(dtb), 2048) - len(dtb)  # factory pads each dtb to a page
        payload += b"\0" * pad
        cursor += len(dtb) + pad

    return bytes(table).ljust(data_start, b"\0") + bytes(payload)


def parse(blob):
    """Return the records, raising if the blob is not self-consistent."""
    if blob[:4] != MAGIC:
        raise ValueError("not a QCDT blob")
    version, count = struct.unpack("<II", blob[4:12])
    if version != 2:
        raise ValueError(f"wrong version {version}")
    records = []
    for i in range(count):
        rec = struct.unpack("<6I", blob[12 + i * RECORD_SIZE:
                                       12 + (i + 1) * RECORD_SIZE])
        platform_id, variant_id, subtype, soc_rev, offset, size = rec
        if blob[offset:offset + 4] != b"\xd0\x0d\xfe\xed":
            raise ValueError(f"record {i} does not point at a DTB")
        if size < 1000 or size > 4 * 1024 * 1024:
            raise ValueError(f"record {i} has an implausible size {size}")
        records.append(rec)
    return version, records


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--platform-ids", default="0xc708ff01")
    ap.add_argument("--variants", default="2,3,4")
    ap.add_argument("--soc-rev", default="0x20000")
    args = ap.parse_args()

    dtb = open(args.dtb, "rb").read()
    if dtb[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("input is not a dtb")

    pids = [int(x, 0) for x in args.platform_ids.split(",")]
    variants = [int(x, 0) for x in args.variants.split(",")]
    soc_rev = int(args.soc_rev, 0)

    ids = [(p, v, 0, soc_rev) for p in pids for v in variants]
    blob = build(dtb, ids)

    # self-check before writing: the blob must parse under the same rules
    version, records = parse(blob)
    open(args.out, "wb").write(blob)

    print(f"wrote {args.out}: {len(blob)} bytes, {len(records)} entries, "
          f"version {version}, dtb {len(dtb)} bytes")
    for p in pids:
        print(f"  platform 0x{p:08x}  variants {variants[0]}..{variants[-1]}  "
              f"soc_rev 0x{soc_rev:x}")


if __name__ == "__main__":
    main()
