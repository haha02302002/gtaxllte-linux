# Mainline Linux port — Samsung Galaxy Tab Active 8.0 (SM-T365 / `rubenslte`)

This directory is a **new port**, unrelated to the `gtaxllte` (SM-T585, Exynos 7870)
work in this repository. Different SoC, different boot chain, different everything.

## The device, as read off the hardware itself

Collected with `adb` from TWRP; raw dump in `../hw-SM-T365-rubenslte.txt`.

| item | value |
|---|---|
| model / device | SM-T365 / `rubenslte` (`samsung.hardware=SM-T360`, board rev 3) |
| SoC | Qualcomm **APQ8026** (`msm8226`), 4x Cortex-A7 @1.2 GHz, ARMv7 32-bit |
| RAM | 1,446,552 kB total |
| GPU | Adreno 305 |
| PMIC | PM8226 (+ PM8841/PM8941 rails) |
| storage | 15,388,672 KiB eMMC, `mmcblk0`, Samsung by-name layout (`boot`, `recovery`, `system`, `userdata`, …) |
| display | `qcom,mdss_dsi_sdc_wxga_video_lte`, 800x1280, MDSS/DSI |
| backlight | **LP8556** on i2c-gpio (SDA gpio20, SCL gpio21), address `0x2c` |
| touch | **Synaptics RMI4** on BLSP1 QUP5 (`i2c@f9927000`), addr `0x20`, IRQ gpio17, enables gpio31 + gpio114, project `RUBENS`, abs 1599x2559 |
| charger / gauge | `max77804k`, `sec-fuelgauge`; MUIC SM5502-class |
| audio | WCD9xxx (WCD9306 family) |
| WiFi/BT | integrated **WCNSS** (pronto), no external chip |
| bootloader | `T360XXS1BRI2` (aboot), kernel it ships: 3.4.0 |

## Why the existing zips can never work here

Every `gtaxllte-linux-twrp.zip` in `../` writes an Exynos 7870 kernel to `mmcblk0p9`
and an ext4 rootfs to `mmcblk0p19`. On this tablet `p9` is 1 MiB and `p19` is 1 KiB.
The installer's payload can never match, and the kernel would not run on ARMv7/Cortex-A7
even if it landed.

## Upstream status (msm8226)

Platform support is real and maintained (`msm8226-mainline/linux`, branch
`qcom-msm8226-6.16.y`, shipped as `linux-postmarketos-qcom-msm8226` 6.16.x).

| block | upstream state |
|---|---|
| clocks, pinctrl, RPM regulators | works (5.15–6.3) |
| SD/eMMC (`sdhci-msm`) | works (5.16) |
| SMP / CPUfreq | works (6.9 / 6.12) |
| I2C, UART, SPMI | works |
| GPU (Adreno 305, `msm`) | works (6.8) |
| DSI / display controller | works (6.6) — **but needs a panel driver this panel lacks** |
| simple-framebuffer | works (already reserved by aboot at `0x03200000`, 8 MiB) |
| Synaptics RMI4 | driver exists (`rmi4-i2c`, F12) |
| LP8556 backlight | driver exists (`backlight-lp855x`) |
| WCNSS WiFi/BT | **WIP** upstream; firmware + `wcn36xx` needed |
| analog audio (WCD9306) | **no mainline driver** |
| charger / fuel gauge | **no mainline driver** for max77804k + sec-fuelgauge |

Nearest existing ports: `samsung-milletwifi` (Tab 4 8.0, same APQ8026, same 800x1280
panel size, LP8556 backlight, same touch GPIOs) and `samsung-matisse*`. Rubens is
not upstream, so this is a new DTS built from the millet template plus values taken
from Samsung's downstream `msm8926-sec-rubenslteeur-r03.dtsi`.

## Phased plan

**Phase 1 — boot to a framebuffer (the milestone that matters).**
lk2nd + mainline kernel + `qcom-msm8226-samsung-rubenslte.dts`, display through
`simple-framebuffer`, touch through RMI4, eMMC + SD, volume/power keys. No WiFi,
no audio, no battery reporting. This is a usable, verifiable target.

**Phase 2 — proper display.** Port the panel (`sdc_wxga_video`) to a DRM panel driver
and switch from simple-framebuffer to MDSS/DSI. Timings must come from
`dsi_panel_sdc_wxga_video_rubenslte.dtsi` in the downstream tree (kept in
`upstream/`), not guessed.

**Phase 3 — WiFi/BT.** WCNSS remoteproc + `wcn36xx`, firmware from the Android
`/vendor/firmware` partition (this tablet has one; pull it while TWRP is available).

**Phase 4 — power.** max77804k charger + fuel gauge drivers. Until then the tablet
reports nothing about its battery and will not charge meaningfully under Linux.

## Building

No compiler, `make`, `dtc`, WSL or Docker exists on this Windows host — kernels are
built in CI, exactly like the `gtaxllte` images were.

* `build-kernel.sh` — cross-builds `zImage` + `qcom-msm8226-samsung-rubenslte.dtb`
  and packages an Android boot image. Works on any Linux box or in the workflow.
* `../.github/workflows/mainline-msm8226.yml` — GitHub Actions job that runs it and
  uploads the artifacts.
* `defconfig-fragment.txt` — the options the port needs on top of `qcom_defconfig`.

## Booting it

Samsung's aboot on this device only accepts a QCDT boot image and matches on Samsung's
own `qcom,msm-id` magic, which is useless for a custom kernel. The supported route is
**lk2nd** (`lk2nd-msm8226.img`, from `msm8916-mainline/lk2nd` releases):

1. From TWRP: `adb shell dd if=/sdcard/lk2nd-msm8226.img of=/dev/block/bootdevice/by-name/boot`
   (this replaces the `boot` partition; `recovery`/TWRP is untouched, so it is recoverable).
2. Reboot holding **Volume Down** → lk2nd's fastboot appears.
3. `fastboot boot boot.img` to test without committing, then
   `fastboot flash boot boot.img` once it works.

lk2nd also fixes the DT matching problem and supplies MAC addresses, so no
`qcom,msm-id` / `qcom,board-id` is needed in the DTS.

## Honest expectations

Phase 1 is achievable and is the only claim this directory makes. A booting kernel
with a working touchscreen and framebuffer is a day or two of iteration **with the
device in hand**; WiFi, audio and battery charging are open-ended driver work, and
audio in particular has no upstream driver at all for this codec.
