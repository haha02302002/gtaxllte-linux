#!/usr/bin/env bash
# Flash a built boot.img to the SM-T585 BOOT partition from TWRP over adb.
#
#   ./scripts/flash-boot.sh out/boot.img          # flash
#   ./scripts/flash-boot.sh out/boot.img --check  # verify only
#   ./scripts/flash-boot.sh --restore             # restore the original BOOT dump
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-adb}"
BOOT_PART=/dev/block/mmcblk0p9

img=""
if [ "${1:-}" = "--restore" ]; then
    img="$HERE/dumps/boot_stock.img"
    echo "restoring original BOOT partition backup"
else
    img="${1:?usage: flash-boot.sh <boot.img>|--restore [--check]}"
fi

[ -f "$img" ] || { echo "no such image: $img"; exit 1; }

"$ADB" devices | grep -q recovery || { echo "device is not in TWRP (adb state must be 'recovery')"; exit 1; }

size=$(wc -c < "$img")
if [ "$size" -gt 33554432 ]; then echo "image is ${size}B, larger than the 32MB BOOT partition"; exit 1; fi

echo "image:  $img (${size} bytes)"
echo "target: $BOOT_PART"
md5sum "$img"

[ "${2:-}" = "--check" ] && { echo "--check only, not flashing"; exit 0; }

"$ADB" push "$img" /tmp/flash_boot.img
"$ADB" shell "dd if=/tmp/flash_boot.img of=$BOOT_PART bs=1M 2>&1 | tail -2; rm -f /tmp/flash_boot.img"
"$ADB" shell "sync; blockdev --getsize64 $BOOT_PART"

echo
echo "Flashed. Reboot to test:"
echo "  adb shell reboot"
echo "If it does not boot, hold Power+Vol-Down+Home to return to TWRP, then:"
echo "  ./scripts/flash-boot.sh --restore"
