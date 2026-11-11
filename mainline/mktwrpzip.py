#!/usr/bin/env python3
"""Wrap a boot image into a TWRP-flashable zip for SM-T365 (rubenslte).

The zip writes the image to the whole `boot` partition (offset 0), so it
replaces lk2nd with a QCDT image that Samsung aboot loads directly.

Usage:
  mktwrpzip.py --image boot.img --out rubenslte-mainline-twrp.zip [--device rubenslte]
"""
import argparse
import hashlib
import zipfile

UPDATE_BINARY = r"""#!/sbin/sh
# TWRP installer: writes the mainline QCDT boot image to the boot partition.
set -u
ZIP="${3:-}"
LOG=/tmp/rubenslte-mainline.log
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }
fail() { say "!! $*"; say "!! log: $LOG"; exit 1; }

say "=========================================="
say " mainline Linux for SM-T365 (rubenslte)"
say " kernel via Samsung aboot (no lk2nd)"
say "=========================================="

[ -n "$ZIP" ] && [ -f "$ZIP" ] || fail "installer cannot find the zip"
command -v unzip >/dev/null 2>&1 || fail "no unzip in this recovery"

cd /tmp || fail "no /tmp"
rm -rf rmainline
mkdir -p rmainline || fail "cannot create work dir"
cd rmainline || fail "cannot enter work dir"

unzip -o -q "$ZIP" boot.img manifest.txt || fail "cannot extract payload"
[ -f boot.img ] || fail "boot.img missing from zip"

EXPECT=$(grep '^boot_md5=' manifest.txt 2>/dev/null | cut -d= -f2)
[ -n "$EXPECT" ] || fail "manifest has no boot_md5"
GOT=$(md5sum boot.img | cut -d' ' -f1)
[ "$EXPECT" = "$GOT" ] || fail "payload md5 mismatch ($GOT != $EXPECT)"
say "payload verified: $GOT"

DEV=/dev/block/bootdevice/by-name/boot
[ -e "$DEV" ] || DEV=/dev/block/mmcblk0p14
[ -e "$DEV" ] || fail "boot partition not found"

# busybox stat has no -c and /sys sizes are in 512-byte sectors
BYTES=$(wc -c < boot.img | tr -d ' ')
[ -n "$BYTES" ] && [ "$BYTES" -gt 0 ] || fail "cannot size boot.img"
BASEN=$(basename "$(readlink -f "$DEV")")
CAP=""
[ -r "/sys/class/block/$BASEN/size" ] && CAP=$(( $(cat "/sys/class/block/$BASEN/size") * 512 ))
if [ -n "$CAP" ]; then
    [ "$BYTES" -le "$CAP" ] || fail "image ($BYTES) larger than partition ($CAP)"
    say "image $BYTES bytes, partition $CAP bytes"
fi

say "writing $BYTES bytes to $DEV"
dd if=boot.img of="$DEV" bs=4096 conv=fsync 2>>"$LOG" || fail "dd failed"
sync

BACK=$(dd if="$DEV" bs="$BYTES" count=1 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$BACK" = "$GOT" ] || fail "readback mismatch ($BACK)"
say "readback verified: $BACK"
# Match the factory layout: the payload is followed by zeros.
if [ -n "$CAP" ]; then
    SK=$(( (BYTES + 4095) / 4096 ))
    CN=$(( CAP / 4096 - SK ))
    [ "$CN" -gt 0 ] && dd if=/dev/zero of="$DEV" bs=4096 seek=$SK count=$CN 2>/dev/null
fi
say "done - reboot to start mainline Linux"
exit 0
"""

UPDATER_SCRIPT = """# Installed by META-INF/com/google/android/update-binary (a /sbin/sh script).
# Writing a block device is not expressible in edify; TWRP only needs this to exist.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="rubenslte")
    a = ap.parse_args()

    img = open(a.image, "rb").read()
    digest = hashlib.md5(img).hexdigest()
    manifest = (
        f"device={a.device}\n"
        f"payload=boot.img\n"
        f"boot_bytes={len(img)}\n"
        f"boot_md5={digest}\n"
        "replaces=lk2nd\n"
        "writes=/dev/block/bootdevice/by-name/boot (offset 0, whole partition)\n"
    )

    with zipfile.ZipFile(a.out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("META-INF/com/google/android/update-binary", UPDATE_BINARY)
        z.writestr("META-INF/com/google/android/updater-script", UPDATER_SCRIPT)
        z.writestr("manifest.txt", manifest)
        z.writestr("boot.img", img, compress_type=zipfile.ZIP_STORED)

    print(f"wrote {a.out}")
    print(f"  boot.img {len(img)} bytes  md5 {digest}")
    print(f"  manifest:\n{manifest}")


if __name__ == "__main__":
    main()
