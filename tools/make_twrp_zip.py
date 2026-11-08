#!/usr/bin/env python3
"""Pack boot.img + rootfs.img.gz into a flashable TWRP zip for the SM-T585.

The installer is a /sbin/sh script (META-INF/com/google/android/update-binary),
not edify: everything it does is raw block writing and stream decompression,
which edify cannot express.

    python3 tools/make_twrp_zip.py \
        --boot out/boot.img --rootfs out/rootfs.img.gz \
        --out out/gtaxllte-linux-twrp.zip

Zip layout:
    META-INF/com/google/android/update-binary
    META-INF/com/google/android/updater-script
    boot.img          (stored, already small)
    rootfs.img.gz     (stored: it is gzip already, do not compress twice)
    manifest.txt      (md5 + sizes the installer verifies)
"""
import argparse
import gzip
import hashlib
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DEFAULT_TWRP = os.path.join(ROOT, "twrp")
BOOT_PARTITION_BYTES = 33554432
ROOTFS_BYTES = 2147483648


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(4 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", required=True)
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--twrp", default=DEFAULT_TWRP)
    args = ap.parse_args()

    for p in (args.boot, args.rootfs):
        if not os.path.isfile(p):
            sys.exit("ERROR: missing %s" % p)

    boot_size = os.path.getsize(args.boot)
    if boot_size > BOOT_PARTITION_BYTES:
        sys.exit("ERROR: boot.img is %d bytes, the BOOT partition holds %d"
                 % (boot_size, BOOT_PARTITION_BYTES))

    boot_md5 = md5_file(args.boot)
    rootfs_md5 = md5_file(args.rootfs)
    rootfs_size = os.path.getsize(args.rootfs)

    # md5 of the image's first 4 KiB, i.e. the ext4 superblock. The installer
    # compares it after writing, because this recovery's od cannot print hex.
    with gzip.open(args.rootfs, "rb") as f:
        sb_head = f.read(4096)
    if len(sb_head) < 4096 or sb_head[1080:1082] != b"\x53\xef":
        sys.exit("ERROR: %s does not start with an ext4 superblock" % args.rootfs)
    sb_md5 = hashlib.md5(sb_head).hexdigest()

    manifest = "\n".join([
        "device=gtaxllte",
        "boot_md5=%s" % boot_md5,
        "boot_bytes=%d" % boot_size,
        "rootfs_md5=%s" % rootfs_md5,
        "rootfs_sb_md5=%s" % sb_md5,
        "rootfs_gz_bytes=%d" % rootfs_size,
        "rootfs_bytes=%d" % ROOTFS_BYTES,
        "",
    ])

    update_binary = os.path.join(args.twrp, "META-INF", "com", "google", "android", "update-binary")
    updater_script = os.path.join(args.twrp, "META-INF", "com", "google", "android", "updater-script")
    for p in (update_binary, updater_script):
        if not os.path.isfile(p):
            sys.exit("ERROR: missing %s" % p)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    tmp = args.out + ".part"
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as z:
        def add(name, path, method):
            with open(path, "rb") as f:
                data = f.read()
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = method
            info.external_attr = (0o100755 if name.endswith("update-binary") else 0o100644) << 16
            z.writestr(info, data, compresslevel=6 if method == zipfile.ZIP_DEFLATED else None)

        add("META-INF/com/google/android/update-binary", update_binary, zipfile.ZIP_DEFLATED)
        add("META-INF/com/google/android/updater-script", updater_script, zipfile.ZIP_DEFLATED)
        info = zipfile.ZipInfo("manifest.txt", date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        z.writestr(info, manifest.encode(), compresslevel=6)
        add("boot.img", args.boot, zipfile.ZIP_STORED)
        add("rootfs.img.gz", args.rootfs, zipfile.ZIP_STORED)

    os.replace(tmp, args.out)
    print("built %s" % args.out)
    print("  boot.img      %10d bytes  md5 %s" % (boot_size, boot_md5))
    print("  rootfs.img.gz %10d bytes  md5 %s" % (rootfs_size, rootfs_md5))
    print("  zip           %10d bytes" % os.path.getsize(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
