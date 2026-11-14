#!/usr/bin/env python3
"""Wire the early on-panel progress reporter into a kernel tree.

The reporter has to run before any console, driver or initramfs exists - that
is the whole point, because mainline currently dies before all three. A patch
file would break on every kernel bump, so the calls are inserted at stable
anchor strings instead.
"""
import os
import shutil
import sys


def insert_after(path, anchor, addition, expect=1):
    with open(path, encoding='utf-8', newline='') as f:
        src = f.read()
    if addition.strip() in src:
        print("  already present in %s" % os.path.basename(path))
        return True
    if src.count(anchor) != expect:
        print("  !! anchor %r found %d times in %s (wanted %d)"
              % (anchor.strip(), src.count(anchor), path, expect))
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
    if any('brfb_panic' in ln for ln in lines):
        return True
    for i, ln in enumerate(lines):
        if ln.startswith('#include'):
            lines.insert(i + 1, 'extern void brfb(int);\nextern void brfb_panic(void);\n')
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.writelines(lines)
            print("  declared in %s" % os.path.basename(path))
            return True
    print("  !! no #include found in %s" % path)
    return False


def main():
    tree = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))

    shutil.copy(os.path.join(here, "bringup_fb.c"),
                os.path.join(tree, "init", "bringup_fb.c"))

    mk = os.path.join(tree, "init", "Makefile")
    with open(mk, encoding='utf-8', newline='') as f:
        s = f.read()
    if 'bringup_fb.o' not in s:
        s = "obj-y += bringup_fb.o\n" + s
        with open(mk, 'w', encoding='utf-8', newline='') as f:
            f.write(s)
    print("  init/Makefile builds bringup_fb.o")

    main_c = os.path.join(tree, "init", "main.c")

    ok = True
    # setup_arch() -> paging_init() is the first moment 0x03200000 is mapped.
    arch = os.path.join(tree, "arch", "arm", "kernel", "setup.c")
    ok &= insert_after(arch, "\tpaging_init();\n", "\tbrfb(0);\t/* mapping ready */\n")
    ok &= insert_after(arch, "\tearly_paging_init();\n", "")
    ok &= insert_after(main_c, "\tsetup_arch(&command_line);\n", "\tbrfb(1);\n")
    ok &= insert_after(main_c, "\tearly_security_init();\n", "\tbrfb(2);\n")
    ok &= insert_after(main_c, "\tmm_init();\n", "\tbrfb(3);\n")
    ok &= insert_after(main_c, "\tsched_init();\n", "\tbrfb(4);\n")
    ok &= insert_after(main_c, "\ttime_init();\n", "\tbrfb(5);\n")
    ok &= insert_after(main_c, "\tconsole_init();\n", "\tbrfb(6);\n")
    ok &= insert_after(main_c, "\trest_init();\n", "\tbrfb(7);\n")

    panic_c = os.path.join(tree, "kernel", "panic.c")
    ok &= add_decls(arch)
    ok &= add_decls(main_c)
    ok &= add_decls(panic_c)
    ok &= insert_after(panic_c, "\tpr_emerg(\"Kernel panic - not syncing: %s\\n\", buf);\n",
                       "\tbrfb_panic();\n")
    if not ok:
        raise SystemExit("earlyscreen: anchor mismatch, refusing to build blind")
    print("  early screen reporter installed")


if __name__ == "__main__":
    main()
