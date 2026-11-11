#!/usr/bin/env python3
"""Minimal flattened-device-tree reader used to verify what we actually flash.

FDT header: magic, totalsize, off_struct, off_strings (all big endian u32).
Tokens: 1 BEGIN_NODE, 2 END_NODE, 3 PROP, 4 NOP, 9 END.
"""
import struct
import sys


def walk(d):
    if d[:4] != b"\xd0\x0d\xfe\xed":
        raise ValueError("not an fdt")
    totalsize, off_struct, off_strings = struct.unpack(">III", d[4:16])
    if totalsize > len(d):
        raise ValueError("truncated")

    def s(o):
        e = d.index(b"\0", off_strings + o)
        return d[off_strings + o:e].decode()

    o = off_struct
    path = []
    out = []
    while o < totalsize:
        (tok,) = struct.unpack(">I", d[o:o + 4])
        o += 4
        if tok == 1:
            e = d.index(b"\0", o)
            path.append(d[o:e].decode())
            o = (e + 4) & ~3
        elif tok == 2:
            if path:
                path.pop()
            o = (o + 3) & ~3
        elif tok == 3:
            ln, nameoff = struct.unpack(">II", d[o:o + 8])
            o += 8
            val = d[o:o + ln]
            o = (o + ln + 3) & ~3
            out.append((tuple(path), s(nameoff), val))
        elif tok == 4:
            pass
        elif tok == 9:
            break
        else:
            raise ValueError(f"bad token {tok}")
        o = (o + 3) & ~3
    return out


def memory_map(d):
    for path, name, val in walk(d):
        if name == "reg" and path and path[-1].startswith("memory") and len(val) % 4 == 0:
            vals = struct.unpack(">" + "I" * (len(val) // 4), val)
            return tuple(hex(v) for v in vals)
    return None


def qcdt(d):
    if d[:4] != b"QCDT":
        raise ValueError("not a QCDT blob")
    version, count = struct.unpack("<II", d[4:12])
    recs = []
    for i in range(count):
        pid, vid, sub, rev, off, size = struct.unpack(
            "<6I", d[12 + i * 24:12 + (i + 1) * 24])
        recs.append((pid, vid, sub, rev, off, size))
    return version, recs


def check_dtb(path):
    d = open(path, "rb").read()
    mm = memory_map(d)
    print(f"{path}: {len(d)} bytes, memory reg = {mm}")
    if not mm or mm[1] == "0x0":
        raise SystemExit("!! zero-memory dtb")
    return mm


def check_image(path):
    d = open(path, "rb").read()
    ksize, = struct.unpack("<I", d[8:12])
    page, dtsize = struct.unpack("<II", d[36:44])
    off = page + (ksize + page - 1) // page * page
    blob = d[off:off + dtsize]
    version, recs = qcdt(blob)
    maps = set()
    for pid, vid, sub, rev, o, s in recs:
        maps.add(memory_map(blob[o:o + s]))
    print(f"{path}: {len(d)} B  kernel {ksize} @0x8000  "
          f"QCDT v{version} {len(recs)} entries")
    print(f"  distinct dtb memory maps inside the table: {len(maps)}")
    for m in maps:
        print(f"  {m}")
    if len(maps) != 1 or next(iter(maps))[1] == "0x0":
        raise SystemExit("!! table does not carry the fixed dtb")


if __name__ == "__main__":
    mode, target = sys.argv[1], sys.argv[2]
    {"dtb": check_dtb, "image": check_image}[mode](target)
