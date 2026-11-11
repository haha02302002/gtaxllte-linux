#!/usr/bin/env python3
"""Read, edit and rewrite a flattened device tree without needing dtc.

Used to inject properties aboot expects (qcom,msm-id) into a kernel-built dtb.
"""
import struct
import sys

MAGIC = 0xd00dfeed
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9


class Node:
    def __init__(self, name=""):
        self.name = name
        self.props = []          # [(name, bytes)]
        self.children = []

    def child(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None

    def get(self, name):
        for n, v in self.props:
            if n == name:
                return v
        return None

    def set(self, name, value):
        for i, (n, _) in enumerate(self.props):
            if n == name:
                self.props[i] = (name, value)
                return
        self.props.append((name, value))


def parse(blob):
    (magic, totalsize, off_struct, off_strings, off_rsv, version,
     last_comp, cpuid, size_strings, size_struct) = struct.unpack(">10I", blob[:40])
    if magic != MAGIC:
        raise ValueError("not a flattened device tree")
    strings = blob[off_strings:off_strings + size_strings]

    def sname(off):
        e = strings.index(b"\0", off)
        return strings[off:e].decode()

    o = off_struct
    root = None
    stack = []
    while o < off_struct + size_struct:
        (tok,) = struct.unpack(">I", blob[o:o + 4])
        o += 4
        if tok == BEGIN_NODE:
            e = blob.index(b"\0", o)
            node = Node(blob[o:e].decode())
            o = (e + 4) & ~3
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            stack.append(node)
        elif tok == END_NODE:
            stack.pop()
        elif tok == PROP:
            ln, noff = struct.unpack(">II", blob[o:o + 8])
            o += 8
            stack[-1].props.append((sname(noff), blob[o:o + ln]))
            o = (o + ln + 3) & ~3
        elif tok == NOP:
            pass
        elif tok == END:
            break
        else:
            raise ValueError(f"bad token {tok}")
    return root


def serialize(root):
    strings = bytearray()
    soff = {}
    body = bytearray()

    def sref(name):
        if name not in soff:
            soff[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return soff[name]

    def emit(node):
        body.extend(struct.pack(">I", BEGIN_NODE))
        body.extend(node.name.encode() + b"\0")
        while len(body) % 4:
            body.append(0)
        for name, val in node.props:
            body.extend(struct.pack(">III", PROP, len(val), sref(name)))
            body.extend(val)
            while len(body) % 4:
                body.append(0)
        for c in node.children:
            emit(c)
        body.extend(struct.pack(">I", END_NODE))

    emit(root)
    body.extend(struct.pack(">I", END))

    rsv = struct.pack(">QQ", 0, 0)
    off_rsv = 40
    off_struct = off_rsv + len(rsv)
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    hdr = struct.pack(">10I", MAGIC, total, off_struct, off_strings, off_rsv,
                      17, 16, 0, len(strings), len(body))
    return bytes(hdr) + rsv + bytes(body) + bytes(strings)


def resolve(root, parts):
    node = root
    for p in parts:
        node = node.child(p)
        if node is None:
            raise SystemExit(f"node {p!r} not found")
    return node


def main():
    args = sys.argv[1:]
    src = args[args.index("--in") + 1]
    dst = args[args.index("--out") + 1]
    root = parse(open(src, "rb").read())
    for i, a in enumerate(args):
        if a == "--set-u32":
            name, vals = args[i + 1].split("=", 1)
            data = b"".join(struct.pack(">I", int(x, 0)) for x in vals.split(","))
            root.set(name, data)
            print("  set /%s = %s" % (name, [hex(int(x, 0)) for x in vals.split(",")]))
        elif a == "--set-node-u32":
            path, vals = args[i + 1].split("=", 1)
            parts = path.split("/")
            node = resolve(root, parts[:-1])
            data = b"".join(struct.pack(">I", int(x, 0)) for x in vals.split(","))
            node.set(parts[-1], data)
            print("  set /%s = %s" % (path, [hex(int(x, 0)) for x in vals.split(",")]))
    out = serialize(root)
    open(dst, "wb").write(out)
    print("wrote %s: %d bytes" % (dst, len(out)))


if __name__ == "__main__":
    main()
