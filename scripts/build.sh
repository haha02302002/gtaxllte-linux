#!/usr/bin/env bash
# Build a bootable Linux kernel + initramfs + boot.img for the
# Samsung Galaxy Tab A 10.1 (2016) SM-T585 / gtaxllte (Exynos 7870).
#
# Required environment:
#   CROSS_COMPILE  e.g. /opt/aarch64-tc/bin/aarch64-linux-gnu-
#   KERNEL_DIR     path to a checked-out android_kernel_samsung_exynos7870 (branch 12 = 3.18.140)
# Optional:
#   OUT            output directory (default: ./out)
#   DEFCONFIG      default: lineage-gtaxllte_defconfig
#   EMBED_INITRAMFS  1 (default) to also embed the initramfs inside the kernel,
#                    so booting does not depend on the bootloader passing a ramdisk
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
DEFCONFIG="${DEFCONFIG:-lineage-gtaxllte_defconfig}"
KERNEL_DIR="${KERNEL_DIR:?set KERNEL_DIR to the kernel source checkout}"
ARCH=arm64
: "${CROSS_COMPILE:?set CROSS_COMPILE to the aarch64 toolchain prefix}"

# Values taken from the tablet's own recovery partition (see README).
KERNEL_ADDR=0x10008000
RAMDISK_ADDR=0x11000000
TAGS_ADDR=0x10000100
PAGE_SIZE=2048
BOOT_PARTITION_BYTES=33554432
CMDLINE="console=tty0 console=ttySAC2,115200 panic=0 rdinit=/init"

mkdir -p "$OUT"

# ---------------------------------------------------------------- initramfs
# Staged BEFORE the kernel build so it can be embedded into the Image.
echo "==> staging initramfs"
ROOT="$OUT/initramfs-root"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,dev,dev/pts,tmp,run,mnt,root,usr/bin,usr/sbin}
install -m 0755 "$HERE/initramfs/init"    "$ROOT/init"
# The busybox pulled from TWRP is dynamically linked against Android's linker,
# which does not exist in a bare initramfs, so every exec would fail with
# "No working init found". Use the static build when it is available.
if [ -f "$HERE/initramfs/busybox-static" ]; then
    BB="$HERE/initramfs/busybox-static"
else
    BB="$HERE/initramfs/busybox"
fi
echo "==> busybox: $BB"
install -m 0755 "$BB" "$ROOT/bin/busybox"

# Refuse to ship a dynamically linked busybox. In a bare initramfs its
# interpreter (/sbin/linker64 for TWRP's build) does not exist, every exec
# fails, and the kernel panics with "No working init found".
python3 - "$BB" <<'CHECK'
import struct, sys
d = open(sys.argv[1], "rb").read()
if d[:4] != b"ELF":
    sys.exit("ERROR: %s is not an ELF binary" % sys.argv[1])
phoff = struct.unpack("<Q", d[32:40])[0]
phentsize, phnum = struct.unpack("<HH", d[54:58])
ptypes = [struct.unpack("<I", d[phoff+i*phentsize:phoff+i*phentsize+4])[0] for i in range(phnum)]
if 3 in ptypes:
    sys.exit("ERROR: %s is dynamically linked (PT_INTERP); use a static build" % sys.argv[1])
print("busybox is static (no PT_INTERP): OK")
CHECK




# ---------------------------------------------------------------- distro payload
# An Alpine minirootfs is baked into the initramfs as the /distro tree. init
# copies it into a tmpfs and switch_root()s into it, but only when no on-disk
# rootfs (microSD or rootfs.img) is found, so it costs ~4 MB of the BOOT
# partition and nothing else. It is extracted here so booting needs no tar.
if [ "${EMBED_DISTRO:-0}" = "1" ]; then
    ALPINE_BRANCH="${ALPINE_BRANCH:-v3.20}"
    ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
    echo "==> fetching Alpine ${ALPINE_BRANCH} aarch64 minirootfs"
    ALPINE_FILE=$(curl -fsSL "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/aarch64/" 2>/dev/null | grep -oE 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' | sort -uV | tail -1)
    TMP_TGZ="$OUT/alpine.tar.gz"
    rm -rf "$ROOT/distro"
    if [ -n "$ALPINE_FILE" ] && curl -fsSL -o "$TMP_TGZ" "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/aarch64/$ALPINE_FILE" && gzip -t "$TMP_TGZ"; then
        echo "    $ALPINE_FILE ($(stat -c%s "$TMP_TGZ") bytes), extracting"
        mkdir -p "$ROOT/distro"
        tar -xzf "$TMP_TGZ" -C "$ROOT/distro"
        if [ -e "$ROOT/distro/sbin/init" ] || [ -L "$ROOT/distro/sbin/init" ]; then
            echo "    extracted $(find "$ROOT/distro" | wc -l) entries"
        else
            echo "WARNING: extracted Alpine has no /sbin/init; dropping it"
            rm -rf "$ROOT/distro"
        fi
    else
        echo "WARNING: could not fetch Alpine; init will fall back to the shell"
        rm -rf "$ROOT/distro"
    fi
    rm -f "$TMP_TGZ"
fi

python3 "$HERE/tools/build_initramfs.py" "$ROOT" "$OUT/ramdisk.gz"

# ---------------------------------------------------------------- kernel
cd "$KERNEL_DIR"
echo "==> kernel source: $(grep -m1 '^VERSION' Makefile).$(grep -m1 '^PATCHLEVEL' Makefile).$(grep -m1 '^SUBLEVEL' Makefile)"
echo "==> defconfig: $DEFCONFIG"
make ARCH=$ARCH CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"

echo "==> merging console/VT fragment"
scripts/kconfig/merge_config.sh -m .config "$HERE/configs/linux-console.fragment"

# --------------------------------------------------------- USB hw-param stubs
# Samsung's USB "hw param" helpers are called from unrelated drivers
# (sec_vib.c, bts-exynos7870.c, usb/notify/usb_notify_sysfs.c) but implemented
# in parts of the full Android USB stack that this kernel does not build:
# set_ncm_ready() comes from u_ncm.c (needs CONFIG_USB_F_NCM) and the
# microusb_get_usb*_count() counters from an out-of-tree microusb driver. They
# only feed diagnostic counters, so no-op definitions are correct here and stop
# the vmlinux link from failing on every driver that happens to call them.
echo "==> adding USB hw-param stubs"
STUB_DIR="$KERNEL_DIR/drivers/usb/gadget"
cat > "$STUB_DIR/gtaxl_usb_stub.c" <<'STUBSRC'
/*
 * No-op definitions for Samsung USB "hw param" helper symbols. See build.sh.
 * Do not enable CONFIG_USB_F_NCM together with this file: u_ncm.c defines
 * set_ncm_ready() as well and the link would fail on a duplicate symbol.
 */
#include <linux/types.h>

void set_ncm_ready(bool ready)
{
}

int microusb_get_usb310_count(void)
{
	return 0;
}

int microusb_get_usb210_count(void)
{
	return 0;
}
STUBSRC
grep -q 'gtaxl_usb_stub.o' "$STUB_DIR/Makefile" ||     echo 'obj-y += gtaxl_usb_stub.o' >> "$STUB_DIR/Makefile"


if [ "${EMBED_INITRAMFS:-1}" = "1" ]; then
    echo "==> embedding initramfs from $ROOT"
    scripts/config --set-str CONFIG_INITRAMFS_SOURCE "$ROOT"
fi

make ARCH=$ARCH CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
cp .config "$OUT/config.effective"

# Fail loudly if the console options did not survive kconfig.
for sym in CONFIG_VT_CONSOLE CONFIG_FRAMEBUFFER_CONSOLE; do
    grep -q "^$sym=y" "$OUT/config.effective" || {
        echo "ERROR: $sym is not enabled - the kernel would boot with no visible console"; exit 1; }
done
if [ "${EMBED_INITRAMFS:-1}" = "1" ]; then
    grep -q "^CONFIG_INITRAMFS_SOURCE=\"$ROOT\"" "$OUT/config.effective" || {
        echo "ERROR: initramfs embedding requested but CONFIG_INITRAMFS_SOURCE was not set"; exit 1; }
fi

echo "==> compiling Image"
make ARCH=$ARCH CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" Image
cp arch/arm64/boot/Image "$OUT/Image"

# ---------------------------------------------------------------- boot.img
echo "==> packing boot.img"
python3 "$HERE/tools/mkbootimg.py" \
    --kernel "$OUT/Image" \
    --dtb "$HERE/dumps/dt.img" \
    --out "$OUT/boot.img" \
    --kernel-addr "$KERNEL_ADDR" \
    --ramdisk-addr "$RAMDISK_ADDR" \
    --tags-addr "$TAGS_ADDR" \
    --page-size "$PAGE_SIZE" \
    --header-version 0 \
    --cmdline "$CMDLINE"

SIZE=$(stat -c%s "$OUT/boot.img")
{
    echo "device: SM-T585 / gtaxllte (Exynos 7870)"
    echo "kernel: $(grep -m1 '^VERSION' Makefile).$(grep -m1 '^PATCHLEVEL' Makefile).$(grep -m1 '^SUBLEVEL' Makefile)"
    echo "defconfig: $DEFCONFIG"
    echo "cmdline: $CMDLINE"
    echo "initramfs embedded: ${EMBED_INITRAMFS:-1}"
    echo "boot.img: $SIZE bytes (partition limit $BOOT_PARTITION_BYTES)"
    echo "md5: $(md5sum "$OUT/boot.img" | cut -d' ' -f1)"
} | tee "$OUT/build-info.txt"

if [ "$SIZE" -gt "$BOOT_PARTITION_BYTES" ]; then
    echo "ERROR: boot.img exceeds the 32 MB BOOT partition"; exit 1
fi

echo "==> done: $OUT/boot.img"
