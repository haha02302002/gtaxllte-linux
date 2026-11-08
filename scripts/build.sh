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



python3 "$HERE/tools/build_initramfs.py" "$ROOT" "$OUT/ramdisk.gz"

# ---------------------------------------------------------------- kernel
cd "$KERNEL_DIR"
echo "==> kernel source: $(grep -m1 '^VERSION' Makefile).$(grep -m1 '^PATCHLEVEL' Makefile).$(grep -m1 '^SUBLEVEL' Makefile)"
echo "==> defconfig: $DEFCONFIG"
make ARCH=$ARCH CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"

echo "==> merging console/VT fragment"
scripts/kconfig/merge_config.sh -m .config "$HERE/configs/linux-console.fragment"

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
