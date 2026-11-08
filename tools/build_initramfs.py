#!/usr/bin/env python3
"""Build a gzipped cpio (newc) initramfs from a directory, no external tools needed.

Usage: python build_initramfs.py <rootdir> <out.cpio.gz>
"""
import gzip
import os
import stat
import sys


def newc_entry(name, data, mode, ino, nlink=1, devmajor=0, devminor=0,
               rdevmajor=0, rdevminor=0):
    name_b = name.encode() + b"\0"
    hdr = b"070701"
    fields = [
        ino, mode, 0, 0, nlink, 0,
        len(data), 0, 0, devmajor, devminor,
        rdevmajor, rdevminor, len(name_b), 0,
    ]
    hdr += b"".join(b"%08X" % f for f in fields)
    out = hdr + name_b
    out += b"\0" * ((4 - (len(out) % 4)) % 4)
    out += data
    out += b"\0" * ((4 - (len(data) % 4)) % 4)
    return out


def collect(root):
    """Return [(name, abspath_or_None, mode)] in a stable order."""
    root = os.path.abspath(root)
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            entries.append((rel.replace(os.sep, "/"), None, stat.S_IFDIR | 0o755))
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            name = os.path.relpath(full, root).replace(os.sep, "/")
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                entries.append((name, full, stat.S_IFLNK | 0o777))
            else:
                entries.append((name, full, stat.S_IFREG | (st.st_mode & 0o7777)))
    return entries


def build(root, out):
    entries = collect(root)
    buf = bytearray()
    seq = 1
    for name, full, mode in entries:
        if stat.S_ISDIR(mode):
            buf += newc_entry(name + "/", b"", mode, seq, nlink=2)
        elif stat.S_ISLNK(mode):
            buf += newc_entry(name, os.readlink(full).encode(), mode, seq)
        elif stat.S_ISREG(mode):
            with open(full, "rb") as fh:
                buf += newc_entry(name, fh.read(), mode, seq)
        else:
            continue
        seq += 1

    buf += newc_entry("TRAILER!!!", b"", 0, seq + 1, nlink=1)
    buf += b"\0" * ((512 - (len(buf) % 512)) % 512)

    with gzip.GzipFile(out, "wb", compresslevel=9, mtime=0) as g:
        g.write(bytes(buf))

    print("initramfs %s: %d entries, %d bytes cpio, %d bytes gz"
          % (out, len(entries), len(buf), os.path.getsize(out)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    build(sys.argv[1], sys.argv[2])
