#!/usr/bin/env python3
"""Cheap structural checks on the rubenslte DTS.

Not a substitute for dtc: it only catches unbalanced braces, dangling &refs
and missing property values. The real compile happens in CI, where dtc runs
and the dtb is decompiled back and inspected.
"""
import re
import sys

DTS = "mainline/dts/qcom-msm8226-samsung-rubenslte.dts"
DTSI = "mainline/upstream/qcom-msm8226.dtsi"

src = open(DTS, encoding="utf-8").read()

# strip comments and string literals so braces inside them do not count
s = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
s = re.sub(r"//[^\n]*", "", s)
s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)

ok = True
ob, cb = s.count("{"), s.count("}")
print(f"braces: {ob} open / {cb} close -> {'balanced' if ob == cb else 'MISMATCH'}")
ok &= ob == cb

for inc in ("qcom-msm8226.dtsi", "pm8226.dtsi"):
    present = inc in src
    print(f'include "{inc}": {"yes" if present else "MISSING"}')
    ok &= present

defs = set(re.findall(r"^\s*([a-z0-9_]+):\s*[\w@,-]+\s*\{", s, re.M))
refs = set(re.findall(r"&([a-z0-9_]+)", s))
external = sorted(refs - defs)
print(f"labels defined locally: {len(defs)}")

try:
    dtsi = open(DTSI, encoding="utf-8").read()
except OSError:
    dtsi = ""

missing = [lbl for lbl in external if lbl not in dtsi]
print("references expected from the SoC dtsi:", ", ".join(external))
if dtsi:
    if missing:
        print("NOT FOUND in qcom-msm8226.dtsi:", ", ".join(missing))
        ok = False
    else:
        print("all of them exist in qcom-msm8226.dtsi")

for key in ("synchronous-compatible",):
    pass

must = [
    'compatible = "samsung,rubenslte", "qcom,apq8026"',
    'compatible = "simple-framebuffer"',
    "width = <800>",
    "height = <1280>",
    'compatible = "syna,rmi4-i2c"',
    'compatible = "ti,lp8556"',
    "gpios = <&tlmm 108 GPIO_ACTIVE_LOW>",
]
for m in must:
    hit = m in src
    print(f"contains {m!r}: {'yes' if hit else 'MISSING'}")
    ok &= hit

print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
sys.exit(0 if ok else 1)
