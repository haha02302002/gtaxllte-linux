#!/usr/bin/env bash
# Cross-build the mainline msm8226 kernel for the Samsung SM-T365 (rubenslte).
#
# Runs on Linux (a real box, WSL, or the GitHub Actions job in
# .github/workflows/mainline-msm8226.yml). It cannot run on the Windows host,
# which has no make/gcc/dtc.
#
# Output in $OUT:
#   zImage                 - the ARM kernel
#   rubenslte.dtb          - the device tree compiled from ../dts/
#   zImage-dtb             - kernel with the DTB appended (lk2nd / appended-DT)
#   boot.img               - Android boot image, when mkbootimg is available
#
# NOTE on QCDT: Samsung aboot expects a QCDT dt.img, which the stock bootloader
# matches with Samsung's own qcom,msm-id magic. That is why this port goes
# through lk2nd, which does not need QCDT matching. Do not hand a plain
# boot.img to stock aboot and expect it to boot.

set -euo pipefail

REPO="${REPO:-https://github.com/msm8226-mainline/linux}"
BRANCH="${BRANCH:-qcom-msm8226-6.16.y}"
WORK="${WORK:-$PWD/work/linux-msm8226}"
OUT="${OUT:-$PWD/work/out-mainline}"
CROSS="${CROSS:-arm-linux-gnueabihf-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
DTS_NAME="qcom-msm8226-samsung-rubenslte"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$OUT" "$(dirname "$WORK")"

if [ ! -d "$WORK/.git" ]; then
	echo ">>> cloning $REPO ($BRANCH)"
	git clone --depth 1 --branch "$BRANCH" "$REPO" "$WORK"
else
	echo ">>> reusing existing tree $WORK"
fi

echo ">>> installing device tree"
cp "$here/dts/$DTS_NAME.dts" "$WORK/arch/arm/boot/dts/qcom/"

# Register the dtb in the qcom Makefile once.
if ! grep -q "$DTS_NAME.dtb" "$WORK/arch/arm/boot/dts/qcom/Makefile"; then
	python3 - "$WORK/arch/arm/boot/dts/qcom/Makefile" "$DTS_NAME" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
anchor = "qcom-msm8226-samsung-s3ve3g.dtb"
out, done = [], False
for line in lines:
    out.append(line)
    if not done and anchor in line:
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}{name}.dtb \\\n")
        done = True
if not done:
    sys.exit(f"anchor {anchor} not found in {path}")
open(path, "w").write("".join(out))
print(f"registered {name}.dtb")
PY
fi

cd "$WORK"

echo ">>> configuring"
make ARCH=arm CROSS_COMPILE="$CROSS" qcom_defconfig
if [ -f "$here/defconfig-fragment.txt" ]; then
	./scripts/kconfig/merge_config.sh -m -O . .config "$here/defconfig-fragment.txt"
	make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
fi

echo ">>> building"
make -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS" zImage dtbs

cp arch/arm/boot/zImage "$OUT/zImage"
cp "arch/arm/boot/dts/qcom/$DTS_NAME.dtb" "$OUT/rubenslte.dtb"
cat "$OUT/zImage" "$OUT/rubenslte.dtb" > "$OUT/zImage-dtb"

# Pack with the bundled python packer: the CI image has no mkbootimg, and an
# empty boot.img on the release is worse than none.
if [ -f "$here/mkbootimg.py" ]; then
	echo ">>> packaging boot.img"
	python3 "$here/mkbootimg.py" --kernel "$OUT/zImage-dtb" --output "$OUT/boot.img" \
		--pagesize 2048 --base 0x00008000
elif command -v mkbootimg >/dev/null 2>&1; then
	echo ">>> packaging boot.img (mkbootimg)"
	: > "$OUT/ramdisk-empty"
	mkbootimg --kernel "$OUT/zImage-dtb" --ramdisk "$OUT/ramdisk-empty" \
		--pagesize 2048 --base 0x00008000 -o "$OUT/boot.img"
else
	echo ">>> no packer available - zImage/zImage-dtb/dtb are still usable"
fi

echo ">>> done"
ls -l "$OUT"
