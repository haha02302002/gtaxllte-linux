# Linux for Samsung Galaxy Tab A 10.1 (2016) — SM-T585 / `gtaxllte`

Builds a **bootable Linux kernel + initramfs + `boot.img`** for the SM-T585
(Exynos 7870, arm64), compiled in **GitHub Actions** and flashed from **TWRP**
over adb. Nothing here modifies the tablet until you flash.

## State of the device (dumped from this tablet)

| Item | Value |
|---|---|
| SoC / arch | Exynos 7870 (`samsungexynos7870`), arm64-v8a |
| Bootloader | `T585XXS7CUI5`, revision 6 |
| Working recovery | TWRP 3.5.1 (`omni_gtaxllte`), kernel `3.18.138-followmsi` |
| BOOT partition | `/dev/block/mmcblk0p9`, 32 MiB — **currently corrupt** |
| RECOVERY | `/dev/block/mmcblk0p10` (intact, used as the reference format) |
| USERDATA | `/dev/block/mmcblk0p23`, ~10.8 GiB, currently vfat |

Boot image geometry, taken from the known-good recovery image:

```
page size     2048
kernel_addr   0x10008000
ramdisk_addr  0x11000000
tags_addr     0x10000100
dt.img        appended after the ramdisk (Samsung DTBH, 3 board entries)
```

`dumps/dt.img` (356 KB) is that appended dt table, trimmed to the exact end of
its third DTB. It is byte-identical to what the bootloader expects, so the build
reuses it instead of regenerating DTBs.

> **The BOOT partition is already broken.** It held a 4.2 MB kernel with an
> 18-byte ramdisk reading `edk2-msm` — a Qualcomm UEFI image for a different
> device. That is why the tablet only boots to TWRP. `dumps/boot_stock.img` is a
> byte-for-byte backup of that partition (`--restore` writes it back).

## Why a kernel has to be compiled

TWRP's running kernel has `CONFIG_FB=y` and `CONFIG_FB_SIMPLE=y` but **no
`CONFIG_VT`, `CONFIG_VT_CONSOLE` or `CONFIG_FRAMEBUFFER_CONSOLE`** — TWRP draws
the screen from userspace, not through a virtual terminal. A Linux userspace
therefore has no console at all on that kernel. `configs/linux-console.fragment`
turns VT + fbcon back on; `scripts/build.sh` aborts if those symbols do not
survive `kconfig`.

## Build

Kernel: [`followmsi/android_kernel_samsung_exynos7870`](https://github.com/followmsi/android_kernel_samsung_exynos7870)
branch `12` — Linux **3.18.140**, the same tree TWRP is built from.

### In CI (no local toolchain needed)

1. Push this directory to a GitHub repository.
2. Actions → **Build Linux kernel for SM-T585 (gtaxllte)** → *Run workflow*.
3. Download the `gtaxllte-linux-boot` artifact (`boot.img`, `Image`, `ramdisk.gz`,
   `config.effective`, `build-info.txt`).

The workflow pulls ARM GCC 8.3 (`gcc-arm-8.3-2019.03-x86_64-aarch64-linux-gnu`)
and fails the build if `boot.img` exceeds the 32 MiB partition.

### Locally, on any Linux box with an aarch64 GCC

```bash
git clone --depth 1 -b 12 https://github.com/followmsi/android_kernel_samsung_exynos7870.git kernel
CROSS_COMPILE=/opt/aarch64-tc/bin/aarch64-linux-gnu- \
KERNEL_DIR="$PWD/kernel" OUT="$PWD/out" ./scripts/build.sh
```

Produces `out/boot.img`, `out/Image`, `out/ramdisk.gz`, `out/config.effective`.

## Flash (device must be in TWRP, adb connected)

```bash
adb devices                       # expect: <serial>  recovery
./scripts/flash-boot.sh out/boot.img --check   # size + md5, no write
./scripts/flash-boot.sh out/boot.img
adb shell reboot
```

From Windows with the bundled platform-tools, the same steps are:

```bash
ADB="C:/Users/lol/Downloads/platform-tools-latest-windows/platform-tools/adb.exe"
"$ADB" push out/boot.img /tmp/flash_boot.img
"$ADB" shell "dd if=/tmp/flash_boot.img of=/dev/block/mmcblk0p9 bs=1M"
"$ADB" shell sync
"$ADB" shell reboot
```

### If it does not boot

Hold **Power + Vol-Down + Home** to return to TWRP (RECOVERY is untouched by
this build), then restore the original partition:

```bash
./scripts/flash-boot.sh --restore
```

## What the image does

`initramfs/init` (static arm64 busybox pulled from the tablet's own TWRP):

- mounts `proc`, `sysfs`, `devtmpfs`, `devpts`
- prints kernel version, framebuffer and input devices on the framebuffer console
- mounts the eMMC userdata partition read-only at `/mnt` when possible
- drops to a shell on `tty0` — RAM-only, nothing is written to the tablet

## Layout

```
.github/workflows/build-kernel.yml   CI build
configs/linux-console.fragment       VT / fbcon / cmdline overrides
initramfs/init                       bring-up init script
initramfs/busybox                    static arm64 busybox (from TWRP)
scripts/build.sh                     kernel -> initramfs -> boot.img
scripts/flash-boot.sh                adb flash / restore
tools/mkbootimg.py                   boot image packer (header v0/v1)
tools/unpackbootimg.py               boot image unpacker / inspector
tools/build_initramfs.py             cpio(newc)+gzip initramfs builder
dumps/dt.img                         Samsung dtb table (trimmed, from device)
dumps/config.gz                      running TWRP kernel config
dumps/boot_stock.img                 BOOT partition backup (restore this)
dumps/recovery_twrp.img              RECOVERY partition backup
```

## Known limits

- Kernel is Android 3.18 with vendor drivers: display, eMMC, USB, touch are
  expected to work; a mainline 6.x port (`exynos7870-mainline`) is the long-term
  path and needs a gtaxllte board DTS that does not exist yet.
- No Android userspace — this boots to a shell, not a desktop.
- The initramfs is RAM-only, so nothing persists across reboots yet.
