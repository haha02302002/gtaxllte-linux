#!/usr/bin/env python3
"""Wire the early on-panel progress reporter into a kernel tree.

The reporter has to run before any console, driver or initramfs exists - that
is the whole point, because mainline currently dies before all three. A patch
file would break on every kernel bump, so the calls are inserted at stable
anchor strings instead.

Anchors verified against qcom-msm8226-6.16.y:
  init/main.c          setup_arch(), early_security_init(), mm_core_init(),
                       sched_init(), time_init(), console_init(), rest_init()
  kernel/panic.c       the "Kernel panic - not syncing" pr_emerg()
The first paint happens after setup_arch() returns, because that is when
paging_init() has mapped lowmem and 0x03200000 becomes writable.
"""
import os
import shutil
import sys


def insert_after(path, anchor, addition, expect=1):
    with open(path, encoding='utf-8', newline='') as f:
        src = f.read()
    if addition.strip() and addition.strip() in src:
        print("  already present in %s" % os.path.basename(path))
        return True
    if src.count(anchor) != expect:
        print("  !! anchor %r found %d times in %s (wanted %d)"
              % (anchor.strip(), src.count(anchor), os.path.basename(path),
                 expect))
        return False
    src = src.replace(anchor, anchor + addition, expect)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(src)
    print("  hooked %s at %r" % (os.path.basename(path), anchor.strip()))
    return True


def add_decls(path):
    """Declare the reporter in a translation unit that calls it."""
    with open(path, encoding='utf-8', newline='') as f:
        lines = f.readlines()
    # must look for the declaration itself: the inserted *call* also contains
    # the name, and matching that skipped the prototype and broke -Werror
    if any('extern void brfb_panic' in ln for ln in lines):
        return True
    for i, ln in enumerate(lines):
        if ln.startswith('#include'):
            lines.insert(i + 1,
                         'extern void brfb(int);\nextern void brfb_panic(void);\n')
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.writelines(lines)
            print("  declared in %s" % os.path.basename(path))
            return True
    print("  !! no #include found in %s" % path)
    return False


STEPS = [
    ("\tsetup_arch(&command_line);\n", "\tbrfb(1);\t/* lowmem mapped, first paint */\n"),
    ("\tearly_security_init();\n",     "\tbrfb(2);\n"),
    ("\tmm_core_init();\n",            "\tbrfb(3);\n"),
    ("\tsched_init();\n",              "\tbrfb(4);\n"),
    ("\ttime_init();\n",               "\tbrfb(5);\n"),
    ("\tconsole_init();\n",            "\tbrfb(6);\n"),
    ("\trest_init();\n",               "\tbrfb(7);\n"),
]


def main():
    tree = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))

    shutil.copy(os.path.join(here, "bringup_fb.c"),
                os.path.join(tree, "init", "bringup_fb.c"))

    mk = os.path.join(tree, "init", "Makefile")
    with open(mk, encoding='utf-8', newline='') as f:
        s = f.read()
    if 'bringup_fb.o' not in s:
        with open(mk, 'w', encoding='utf-8', newline='') as f:
            f.write("obj-y += bringup_fb.o\n" + s)
    print("  init/Makefile builds bringup_fb.o")

    main_c = os.path.join(tree, "init", "main.c")
    ok = True
    for anchor, addition in STEPS:
        ok &= insert_after(main_c, anchor, addition)
    panic_c = os.path.join(tree, "kernel", "panic.c")
    ok &= insert_after(panic_c,
                       '\tpr_emerg("Kernel panic - not syncing: %s\\n", buf);\n',
                       "\tbrfb_panic();\n")
    ok &= add_decls(main_c)
    ok &= add_decls(panic_c)
    if not ok:
        raise SystemExit("earlyscreen: anchor mismatch, refusing to build blind")
    print("  early screen reporter installed")


if __name__ == "__main__":
    main()
