# Linux on the Samsung Galaxy Tab A 10.1 (2016) SM-T585 `gtaxllte`

A bootable Linux 3.18.140 kernel for the Exynos 7870 `gtaxllte`, built in GitHub
Actions, flashed from TWRP over adb, with a distro loader that can boot Alpine
from storage and falls back to a busybox shell on a USB serial console.

Repo: https://github.com/haha02302002/gtaxllte-linux (`main`, public)

---

## 1. Boot chain and image geometry

Everything here comes from the tablet's own recovery image, so the Samsung
bootloader accepts the result:

| Parameter | Value | Source |
|---|---|---|
| Page size | 2048 | TWRP boot header |
| Kernel load addr | `0x10008000` | TWRP boot header |
| Ramdisk addr | `0x11000000` | TWRP boot header |
| Tags addr | `0x10000100` | TWRP boot header |
| Header version | 0 | TWRP boot header |
| DTB | `dumps/dt.img`, 356,402 B, DTBH table with 3 DTBs | trimmed from TWRP recovery |
| External ramdisk | **none** (`ramdisk_size 0`) | see §3 |
| BOOT partition | `/dev/block/mmcblk0p9`, 33,554,432 B | device |
| RECOVERY partition | `/dev/block/mmcblk0p10` (TWRP) | device |
| USERDATA partition | `/dev/block/mmcblk0p23`, vfat, 10.8 G | device |

The initramfs is embedded *inside* the kernel Image via
`CONFIG_INITRAMFS_SOURCE`, so the boot image carries no ramdisk section at all.

Kernel command line (in the boot image header and `CONFIG_CMDLINE`):

```
console=tty0 console=ttySAC2,115200 panic=0 rdinit=/init
```

`panic=0` matters: the bootloader passes `sec_watchdog.sec_pet=5` and the kernel
is built with `CONFIG_PANIC_TIMEOUT=5`, which otherwise reboots 5 s after a panic
and hides the message.

---

## 2. Kernel source and build

| Item | Value |
|---|---|
| Source | `followmsi/android_kernel_samsung_exynos7870`, branch `12` = Linux **3.18.140** |
| Defconfig | `lineage-gtaxllte_defconfig` |
| Toolchain | GCC 8.3.0 aarch64 (`gcc-arm-8.3-2019.03`) |
| Runner | `ubuntu-22.04`, ~9 min per build |
| Config fragment | `configs/linux-console.fragment` |
| Build script | `scripts/build.sh` |

Outputs: `out/boot.img`, `out/Image`, `out/config.effective`,
`out/build-info.txt`. CI publishes artifacts `gtaxllte-linux-boot` and
`alpine-rootfs`.

### Kernel config changes (`configs/linux-console.fragment`)

The stock Android/TWRP config has no virtual terminal, so a Linux kernel built
from it boots with **no console at all**. Added:

```
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_DUMMY_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FONT_8x16=y
CONFIG_LOGO=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_CMDLINE="console=tty0 console=ttySAC2,115200 panic=0 rdinit=/init"
CONFIG_CMDLINE_EXTEND=y
```

USB peripheral mode (the only way to type into the shell, since a VT console
cannot read the touchscreen and there is no on-screen keyboard):

```
CONFIG_USB_GADGET=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_F_ACM=y
CONFIG_USB_U_SERIAL=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_SERIAL=y
```

Two things had to be turned **off** to make that link and bind:

```
# CONFIG_USB_G_ANDROID is not set
# CONFIG_SEC_VIB is not set
```

- `USB_G_ANDROID`: Samsung's legacy `android.c` composite probes the single UDC
  at boot and holds it, so the configfs gadget created by init could never bind
  and `/dev/ttyGS0` never appeared.
- `SEC_VIB`: the vibrator driver calls `set_ncm_ready()` and
  `microusb_get_usb*_count()`, which only exist in the full Android USB stack
  (see §4).

---

## 3. Initramfs and the loader (`initramfs/init`)

The kernel embeds a gzipped cpio built by `tools/build_initramfs.py` from
`initramfs/` plus the static busybox.

**Static busybox is mandatory.** TWRP's busybox is dynamically linked against
Android's `/sbin/linker64`, which does not exist in an initramfs, so every exec
fails and the kernel panics with `No working init found`. `scripts/build.sh`
fails the build if the busybox has a `PT_INTERP` program header.

`init` runs as **PID 1** and must never exit (otherwise: `Attempted to kill
init` → watchdog reboot). What it does, in order:

1. installs applet symlinks at runtime (`busybox --install -s /bin`) — build-time
   symlinks in the cpio were unreliable
2. mounts `proc`, `sysfs`, `devtmpfs`, `devpts`, tmpfs on `/run` and `/tmp`
3. builds a **CDC-ACM USB serial gadget** through configfs
   (VID `0x1d6b`, PID `0x0104`) → `/dev/ttyGS0`, with a `gser` fallback if the
   ACM function is not available
4. finds a root filesystem, in this order:
   1. `root=/dev/...` from the kernel command line
   2. microSD: `/dev/mmcblk1p1`, then `p2` (ext4 / f2fs / vfat)
   3. `rootfs.img` on userdata, via `losetup /dev/loop0` (fallback:
      `mount -o loop`); tries `/media/rootfs.img`,
      `/media/media/rootfs.img`, `/media/media/0/rootfs.img`,
      `/media/0/rootfs.img`, `/media/linux/rootfs.img`,
      `/media/rootfs/rootfs.img`, and then the globs `/media/*/rootfs.img`
      and `/media/*/*/rootfs.img`, because the layout differs between TWRP
      builds (`/sdcard` is `/data/media` here, `/data/media/0` on most
      phones)
   4. embedded `/distro` tree, if the build embedded one (opt-in, see §7)
   5. otherwise: the busybox shell on `ttyGS0`
5. `mount -o move` for `dev`/`proc`/`sys`, then `exec switch_root /newroot
   /sbin/init`. A candidate is only accepted if it contains `/sbin/init` or
   `/etc/os-release`, so a random data card is not mistaken for a root.

**The console is deliberately not muted during boot.** If the kernel wedges in a
driver, its messages simply stop, and that is the only diagnosis available when
userspace has no way to report. `dmesg -n 2` is applied only when falling back to
the shell, which is when the sm5703 fuelgauge starts flooding:

```
sec_bat_cisd_check: Fail to sm5703-fuelgauge get (47=>-61)
Fail to get psy (sm5703-charger)
```

**Job control.** The shell was launched with `setsid`, which left it with no
controlling terminal (`sh: can't access tty: job control turned off`). It now
uses `setsid -c` with the tty already on stdin, so `TIOCSCTTY` targets the right
device; verified with `echo $-` → `smi` (the `m` is monitor mode).

---

## 4. Build-script workarounds (`scripts/build.sh`)

**USB hw-param stubs.** Enabling `CONFIG_USB_CONFIGFS` made `vmlinux` fail to
link: `sec_vib.c`, `bts-exynos7870.c` and `usb/notify/usb_notify_sysfs.c` call
`set_ncm_ready()` and `microusb_get_usb*_count()`. Those live in `u_ncm.c`
(needs `CONFIG_USB_F_NCM`) and in an out-of-tree microusb driver that is not even
in this tree. They only feed diagnostic counters, so the build generates
`drivers/usb/gadget/gtaxl_usb_stub.c` with no-op definitions and appends it to
that directory's Makefile. Do **not** enable `CONFIG_USB_F_NCM` alongside it:
that would define `set_ncm_ready()` twice and fail on a duplicate symbol.

**Distro payload is opt-in.** With `EMBED_DISTRO=1` the Alpine minirootfs is
extracted into the initramfs as `/distro`. It is off by default because of the
kernel wedge described in §7.

---

## 5. Tooling (`tools/`)

Dependency-free Python, all three verified by round-trip tests:

- `mkbootimg.py` — packs `Image` + `dumps/dt.img` into a v0 boot image
- `unpackbootimg.py` — parses/verifies a boot image (kernel, ramdisk, cmdline, dt)
- `build_initramfs.py` — writes a gzipped `newc` cpio (symlinks get their target
  NUL stripped, which was a real bug: a stray NUL in a symlink target broke the
  initramfs)

`scripts/flash-boot.sh` flashes, verifies (`--check`) or restores the original
Android boot image (`--restore`, from `dumps/boot_stock.img`).

---

## 6. Flashing and using it

Flash from TWRP (adb works there; the Linux kernel has no adbd):

```sh
adb push out/boot.img /tmp/boot.img
adb shell "dd if=/tmp/boot.img of=/dev/block/mmcblk0p9 bs=1M; sync; rm -f /tmp/boot.img"
adb shell "dd if=/dev/block/mmcblk0p9 bs=1024 count=$(( $(stat -c%s out/boot.img) / 1024 + 1 )) | md5sum"
adb reboot
```

**Typing into it.** The tablet enumerates as a USB CDC-ACM device (VID `0x1d6b`,
PID `0x0104`) — "USB Serial Device (COMx)" in Device Manager. Connect at
115200 8N1:

```sh
python -m serial.tools.miniterm COM6 115200
# or: putty -serial COM6 -sercfg 115200,8,n,1,N
```

There is no GUI and no on-screen keyboard; the framebuffer console is a
read-only status screen.

---

## 7. Running Alpine Linux

Alpine is the realistic choice on a 3.18 kernel: musl + OpenRC, no systemd.
(Debian 12+, Ubuntu, Fedora and Arch require much newer kernels.)

**Install** (from TWRP), using the CI artifact `alpine-rootfs`:

```sh
adb push rootfs.img.gz /sdcard/
adb shell "cd /sdcard && gzip -d -f rootfs.img.gz && ls -l rootfs.img"
adb reboot
```

On this tablet TWRP's `/sdcard` is `/data/media` (there is no per-user `0/`
directory like on most phones), so the pushed file shows up as
`/media/media/rootfs.img` once the loader mounts userdata at `/media`. The
loader checks that path, `/media/rootfs.img`, and a couple of globs, so putting
it at `/sdcard/rootfs.img` is enough. The image is 2 GiB
ext4 labelled `alpine`; on first boot the loader prints `[3/4]`, finds the image,
loop-mounts it and reports `switching to … (loop)`. The USB gadget console then
autologins as root — no login prompt, no password.

Verified boot (the tablet's own console output):

```
Welcome to Alpine Linux 3.20
Kernel 3.18.140-followmsi+ on an aarch64 (/dev/ttyGS0)

id                      -> uid=0(root) gid=0(root)
head -2 /etc/os-release -> NAME="Alpine Linux" / ID=alpine
uname -a                -> Linux gtaxllte 3.18.140-followmsi+ #1 SMP PREEMPT aarch64
cat /etc/shadow | head  -> root:::0:::::
apk --version           -> apk-tools 2.14.4, compiled for aarch64
/sys/class/graphics/fb0 -> 1200,1920 @ 32bpp
df -h /                 -> 2 GiB ext4 on /dev/loop0, persistent
```

The `root` password is cleared in the image because the minirootfs ships it
locked (`root:*::0:::::`), which answers every attempt with `Login incorrect` on
a console that has no keyboard. Give it a password with `passwd` once inside.

Everything installed with `apk add` persists, because it is a real ext4 image on
userdata.

### Desktop: XFCE on the framebuffer with touch input

The tablet has no usable network (`qcacld` probes but has no firmware, so there
is no `wlan0`), which means the desktop can never be installed from inside it.
The CI image build unpacks the aarch64 packages into the rootfs from an x86
`alpine:3.20` container instead:

```sh
docker run --rm -v /tmp/rootfs:/rootfs alpine:3.20 sh -c '
  apk --root /rootfs --arch aarch64 --no-scripts add \
      --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
      --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/community \
      xorg-server xf86-video-fbdev xf86-input-evdev xfce4 xfce4-terminal \
      xfce4-screenshooter xfce4-panel twm xterm matchbox-keyboard \
      font-dejavu font-noto dbus polkit'
```

`apk --arch aarch64` only extracts, so it runs fine on x86; `--no-scripts` is
required because the container cannot execute aarch64 maintainer scripts, and it
is harmless here since services come from the generated busybox inittab rather
than from OpenRC. Two names must exist in v3.20 — `xvkbd` and `ttf-dejavu` do
not, and one unknown name makes apk reject the whole request.

`tty1::respawn:/usr/local/bin/start-gui` (source: `scripts/start-gui.sh`, which
the image build installs) brings the GUI up:

| Step | Detail |
|---|---|
| Display | Xorg `fbdev` on `/dev/fb0`, 1200x1920x24, `-keeptty -nolisten tcp` |
| Pointer | `evdev` on the `sec_touchscreen` node, resolved by reading `/sys/class/input/event*/device/name` (the numbers move between boots) |
| Session bus | `dbus-daemon --session --fork --print-address`; `xfce4-session` refuses to start without one |
| Keyboard | `matchbox-keyboard` on screen, since the tablet has no physical keyboard |
| Session | `startxfce4`, falling back to `xterm` + `twm` if XFCE is missing |
| Log | `/var/log/desktop.log` (tty1 output is invisible without a screen) |

The USB console stays a root shell on `ttyGS0`, so `ps`, `dmesg` and
`/var/log/Xorg.0.log` remain reachable while the desktop is up. `reboot` from
inside Alpine powers the tablet off rather than restarting it (same PMIC issue as
the loader shell) — press Power, or reboot from TWRP with `adb reboot`.

### Alpine's minirootfs is a chroot image, not a bootable system

The official `alpine-minirootfs-3.20.10-aarch64.tar.gz` has 518 entries, **no
`/sbin/openrc` and no `/etc/init.d`**, yet its `/etc/inittab` runs
`/sbin/openrc sysinit`. Hand that to `switch_root` and init starts with every
sysinit action failing, which is why the image build now writes a busybox-only
inittab (mount -a, hostname, getty on `ttyGS0` and `tty1`) and a complete fstab:
that boots to a login prompt without openrc. Install the rest from inside the
running system with `apk add alpine-base` once networking works.

Diagnosis path, for the record: with `rootfs.img` present the tablet showed no
USB device at all, which is what a panic does under `oops=panic` (the gadget
disappears with it). Hiding the image restored the serial shell, and from that
shell `losetup`, the ext4 mount and `chroot` into the image all worked — so the
kernel and the image were fine and only the handoff was broken.

### Known issue: do not embed the rootfs in the kernel

Baking the minirootfs into the initramfs (4 MB larger Image) makes the kernel
freeze at ~2.7 s, **before userspace runs**: no gadget, no init output, only the
last kernel message on screen (`fimc is ressource dump dump end`). Proven by
A/B testing the same kernel with and without the payload — without it the gadget
comes up at ~21 s and the shell works. The bootloader passes `oops=panic`, so a
fault during boot can halt with no message when it happens under the console
lock. Leading hypothesis is that the larger embedded initramfs runs into a region
the Samsung bootloader/kernel treats as reserved; it is not fully proven.

### Distro notes

- `CONFIG_OVERLAY_FS`, `CONFIG_SQUASHFS` and `CONFIG_MODULES` are **not** enabled
  (monolithic kernel: every driver must be built in).
- `CONFIG_VIDEO_EXYNOS_FIMC_IS2` is the camera driver's real switch. Disabling
  its version symbol (`CONFIG_FIMC_IS_V3_11_0`) breaks the build
  (`fimc-is-hw-dvfs.h: No such file or directory`), so the camera stack stays on.
- Wi-Fi is compiled in (`qcacld-2.0`, `CFG80211`) but untested; the USB serial
  console is the supported way in today.

---

## 8. Getting Android back

The tablet's Android install is currently not bootable because BOOT holds this
kernel. Restore it with:

```sh
./scripts/flash-boot.sh --restore
```

(this writes `dumps/boot_stock.img` back to `mmcblk0p9`)

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No USB device at all, screen frozen | A kernel panic: the bootloader passes `oops=panic`, and a panic tears down the USB gadget, so the CDC-ACM device simply vanishes | Read `/media/boot.log` (the loader logs each step, plus `dmesg` up to `switch_root`) from TWRP or Android |
| Windows lists the COM port but `SerialPort.Open()` fails with "device attached to the system is not functioning" | Stale USB-serial handle after the gadget re-enumerated | Unplug and replug the USB cable; the COM number may change |
| Tablet powers off instead of rebooting when `reboot` is run from the loader shell | The reset does not survive on this PMIC/bootloader combination | Press Power to boot it again |
| Concentrated fuel-gauge spam (`sec_bat_cisd_check: Fail to sm5703-fuelgauge get`) | No charger power-supply partner in a bare Linux userspace | Cosmetic; the loader drops the console loglevel to crit for the shell only |
| `FMCS IS RESOURCE DUMP DUMP END` is the last line on screen | The framebuffer console stops updating there in every boot, including working ones | Not a failure sign — ignore it and watch the USB serial console instead |
| `(EE) evdev: touch: Unable to open evdev device "/dev/input/name"` | The event node was taken from `basename` of the sysfs *file* (`.../event1/device/name` → `name`) | Fixed in `scripts/start-gui.sh`: take the basename of the event *directory* |
| GUI starts, dies, and tty1 never comes back | busybox init disables a respawning action after 5 fast restarts, and `xfce4-session` exits immediately without a session bus | `start-gui.sh` starts `dbus-daemon --session` first and sleeps 5 s before X |
| `(EE) AIGLX error: dlopen of .../swrast_dri.so failed` | No Mesa DRI driver in the image and fbdev is not DRI2 capable | Cosmetic: the desktop is unaccelerated |
| `reboot` from the Alpine shell powers the tablet off | Reset does not survive this PMIC/bootloader combination | Press Power, or reboot from TWRP (`adb reboot`) |

Drop `/media/NOSWITCH` on userdata to make the loader stop with the distro mounted
at `/newroot` and hand over the serial shell instead of switching; from there
`touch /media/GO` lets PID 1 perform the real `switch_root` while you watch.
