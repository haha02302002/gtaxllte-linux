#!/usr/bin/env python3
"""Fail if a rootfs image carries ext4 features the 3.18 kernel cannot handle.

The SM-T585 kernel is Linux 3.18. With metadata_csum set, the filesystem mounts
once, the kernel rewrites the superblock, and the checksum it writes is not one
this kernel (or e2fsprogs) will accept again: the *next* boot refuses the mount
with "invalid superblock checksum" and the loader falls back to its busybox
shell. That failure looks exactly like a broken Linux install, so the image
build must never produce it.

Usage:
    python3 tools/check_rootfs_sb.py out/rootfs.img
    python3 tools/check_rootfs_sb.py out/rootfs.img.gz   (reads just the header)

Exit status 1 on any unsupported feature.
"""
import gzip
import struct
import sys

# Feature bits that are known to break (or are not understood by) this kernel.
BAD_RO_COMPAT = {
    0x00000400: "metadata_csum",
    0x00000800: "replica",          # removed from ext4 long ago
    0x00002000: "project",
    0x00004000: "verity",
}
BAD_INCOMPAT = {
    0x00002000: "csum_seed",
    0x00010000: "encrypt",
    0x00020000: "casefold",
    0x00004000: "largedir",
    0x00008000: "inline_data",
    0x000100000: "orphan_file",     # e2fsprogs >= 1.47 default
}
BAD_COMPAT = {
    0x00000200: "sparse_super2",
    0x00000400: "fast_commit",
}
REQUIRED_INCOMPAT = {0x00000002: "filetype", 0x00000040: "extents"}


def read_superblock(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as f:
        head = f.read(4096)
    if len(head) < 2048:
        sys.exit("ERROR: %s is too short to hold an ext4 superblock" % path)
    sb = head[1024:2048]
    magic = struct.unpack_from("<H", sb, 0x38)[0]
    if magic != 0xEF53:
        sys.exit("ERROR: %s has no ext4 superblock (magic 0x%04x)" % (path, magic))
    compat, incompat, ro_compat = struct.unpack_from("<III", sb, 0x5C)
    state = struct.unpack_from("<H", sb, 0x3A)[0]
    return compat, incompat, ro_compat, state


def describe(word, table):
    return ", ".join(name for bit, name in sorted(table.items()) if word & bit) or "none"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    compat, incompat, ro_compat, state = read_superblock(path)

    print("rootfs: %s" % path)
    print("  compat    0x%08x (%s)" % (compat, describe(compat, BAD_COMPAT)))
    print("  incompat  0x%08x (%s)" % (incompat, describe(incompat, BAD_INCOMPAT)))
    print("  ro_compat 0x%08x (%s)" % (ro_compat, describe(ro_compat, BAD_RO_COMPAT)))
    print("  state     0x%04x (%s)" % (state, "clean" if state == 1 else "NOT CLEAN"))

    bad = []
    for word, table, label in (
        (compat, BAD_COMPAT, "compat"),
        (incompat, BAD_INCOMPAT, "incompat"),
        (ro_compat, BAD_RO_COMPAT, "ro_compat"),
    ):
        for bit, name in sorted(table.items()):
            if word & bit:
                bad.append("%s:%s" % (label, name))
    for bit, name in REQUIRED_INCOMPAT.items():
        if not incompat & bit:
            bad.append("missing %s" % name)

    if bad:
        print("FAIL: unsupported by the 3.18 kernel: %s" % ", ".join(bad))
        print("      build with -O ^metadata_csum,^csum_seed,^64bit,^orphan_file")
        return 1
    if state != 1:
        print("WARN: filesystem is not marked clean")
    print("OK: mountable by Linux 3.18")
    return 0


if __name__ == "__main__":
    sys.exit(main())
