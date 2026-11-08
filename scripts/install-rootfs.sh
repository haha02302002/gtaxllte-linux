#!/bin/sh
# Install the Alpine rootfs image on the SM-T585 from TWRP over adb.
#
#   ./scripts/install-rootfs.sh out/rootfs.img.gz
#
# userdata (mmcblk0p23) is vfat and stays untouched; the distro lives in one
# file on it, which the loader loop-mounts. TWRP cannot mount an ext4 image
# itself ("Invalid argument"), so nothing is edited in place: the image is
# pushed, its md5 is checked on the device, and it is unpacked on the tablet.
set -e

ADB=${ADB:-C:/Users/lol/Downloads/platform-tools-latest-windows/platform-tools/adb.exe}
IMG=${1:-out/rootfs.img.gz}
EXPECT=2147483648

[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
command -v md5sum >/dev/null 2>&1 || { echo "no md5sum here"; exit 1; }

LOCAL_MD5=$(md5sum "$IMG" | cut -d' ' -f1)
LOCAL_SIZE=$(stat -c%s "$IMG")
echo "image: $IMG ($LOCAL_SIZE bytes, md5 $LOCAL_MD5)"

"$ADB" wait-for-device
STATE=$("$ADB" shell getprop ro.boot.mode 2>/dev/null | tr -d '\r')
echo "adb state: '${STATE:-unknown}'"

echo "--- pushing (this is ~$((LOCAL_SIZE / 1024 / 1024)) MiB) ---"
"$ADB" push "$IMG" /tmp/rootfs.img.gz || {
    echo "push failed: is the tablet in TWRP and unlocked?"
    exit 1
}

DEV_MD5=$("$ADB" shell md5sum /tmp/rootfs.img.gz 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
[ "$DEV_MD5" = "$LOCAL_MD5" ] || { echo "md5 mismatch: local $LOCAL_MD5 device $DEV_MD5"; exit 1; }
echo "md5 verified on device"

echo "--- unpacking onto userdata ---"
"$ADB" shell "cd /sdcard && gzip -d -f -c /tmp/rootfs.img.gz > rootfs.img"
"$ADB" shell "rm -f /tmp/rootfs.img.gz"

GOT=$("$ADB" shell "wc -c < /sdcard/rootfs.img" 2>/dev/null | tr -d '\r ')
echo "rootfs.img on device: ${GOT:-?} bytes"
[ "$GOT" = "$EXPECT" ] || { echo "unexpected size (wanted $EXPECT)"; exit 1; }

echo "--- rebooting ---"
"$ADB" reboot
echo "done: the tablet boots the new image from /sdcard/rootfs.img"
