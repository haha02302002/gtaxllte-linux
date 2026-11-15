#!/bin/bash
# Local (WSL) build for the SM-T360 with layered boot instrumentation.
#
# Three independent channels, because each covers a stage the previous one
# cannot see:
#   1. decompressor bands - MMU off, physical writes: proves the image starts
#      and that decompression + DTB handover completed
#   2. setup_arch bars    - from the moment lowmem is mapped
#   3. start_kernel bars  - through console_init and rest_init
#   4. panic() red flash  - any panic anywhere
set -e
T=${T:-/root/k/linux}
HERE=${HERE:-$(cd "$(dirname "$0")" && pwd)}
OUT=${OUT:-/mnt/c/Users/lol/Downloads/working/rubens-mainline}
DTS=qcom-msm8226-samsung-rubenslte

cd "$T"
echo ">>> installing device tree"
cp "$HERE/dts/$DTS.dts" arch/arm/boot/dts/qcom/
python3 - arch/arm/boot/dts/qcom/Makefile "$DTS" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
s = open(path).read()
if name + ".dtb" not in s:
    anchor = "qcom-msm8226-samsung-s3ve3g.dtb"
    out, done = [], False
    for line in s.splitlines(keepends=True):
        out.append(line)
        if not done and anchor in line:
            indent = line[:len(line) - len(line.lstrip())]
            out.append("%s%s.dtb \\\n" % (indent, name))
            done = True
    if not done:
        sys.exit("anchor not found")
    open(path, "w").write("".join(out))
print("  dtb registered")
PY

echo ">>> installing the progress reporter"
python3 "$HERE/earlyscreen/apply.py" "$T"

echo ">>> adding setup_arch and decompressor markers"
python3 - <<'PY'
import re

# --- bars inside setup_arch, after lowmem is mapped -------------------------
p = 'arch/arm/kernel/setup.c'
s = open(p).read()
if 'brfb(1)' not in s:
    s = s.replace('\trequest_standard_resources(mdesc);\n',
                  '\trequest_standard_resources(mdesc);\n\tbrfb(1);\t/* mapped, resources claimed */\n', 1)
    if 'extern void brfb(int);' not in s:
        s = s.replace('#include <linux/init.h>',
                      '#include <linux/init.h>\nextern void brfb(int);\nextern void brfb_panic(void);', 1)
    open(p, 'w').write(s)
    print("  setup_arch bar installed")
else:
    print("  setup_arch bar already present")

# --- decompressor bands: physical writes, MMU still off --------------------
p = 'arch/arm/boot/compressed/head.S'
s = open(p).read()
if '.Lbrfb_start' not in s:
    # NOT after "start:": the 8 nops there are a legacy a.out patch area and
    # must stay exactly 32 bytes into the image. Insert before the first real
    # instruction instead, and use push/pop so this assembles as ARM or Thumb.
    band = """\t\t/* bring-up paint: MMU is off, so this is a physical write into the
\t\t * splash buffer aboot left the panel scanning out. */
\t\tpush\t{r4, r5, r6}
\t\tldr\tr5, =0x03200000
\t\tldr\tr6, =0x00107bff
\t\tmov\tr4, #4096
.Lbrfb_start:
\t\tstr\tr6, [r5], #4
\t\tsubs\tr4, r4, #1
\t\tbne\t.Lbrfb_start
\t\t/* also stamp the RAM log: this is what survives if the panel is dark */
\t\tldr\tr5, =0x3fe80000
\t\tldr\tr6, =0x50555242\t\t@ "BRUP"
\t\tstr\tr6, [r5]
\t\tmov\tr6, #0x32\t\t@ "2" -> written before any mapping exists
\t\tstrb\tr6, [r5, #4]
\t\tpop\t{r4, r5, r6}

"""
    marker = "\t\tmov\tr7, r1\t\t\t@ save architecture ID\n"
    i = s.index(marker)
    s = s[:i] + band + s[i:]

    band2 = """\t\t/* decompression finished and a DTB was found: say so on the panel */
\t\tpush\t{r0, r1, r4, r5, r6, r7, r8}
\t\tldr\tr5, =0x03300000
\t\tldr\tr6, =0x0000ff80
\t\tmov\tr4, #4096
.Lbrfb_enter:
\t\tstr\tr6, [r5], #4
\t\tsubs\tr4, r4, #1
\t\tbne\t.Lbrfb_enter
\t\tpop\t{r0, r1, r4, r5, r6, r7, r8}

"""
    marker2 = "__enter_kernel:\n"
    i = s.index(marker2) + len(marker2)
    s = s[:i] + band2 + s[i:]
    open(p, 'w').write(s)
    print("  decompressor bands installed")
else:
    print("  decompressor bands already present")
PY

echo ">>> configuring"
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- qcom_defconfig >/dev/null
if [ -f "$HERE/defconfig-fragment.txt" ]; then
	./scripts/kconfig/merge_config.sh -m -O . .config "$HERE/defconfig-fragment.txt" >/dev/null
	make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig >/dev/null
fi

echo ">>> building"
make -j"$(nproc)" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zImage dtbs 2>&1 | tail -25

cp arch/arm/boot/zImage "$OUT/ci-zImage"
cp "arch/arm/boot/dts/qcom/$DTS.dtb" "$OUT/ci-dtb"
cp .config "$OUT/local.config"
echo "  zImage $(stat -c %s "$OUT/ci-zImage") B"
echo "  dtb    $(stat -c %s "$OUT/ci-dtb") B"
echo "BUILD-LOCAL-DONE"
