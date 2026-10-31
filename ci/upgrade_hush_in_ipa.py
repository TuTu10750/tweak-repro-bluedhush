#!/usr/bin/env python3
"""Swap an already-injected tweak dylib inside an IPA for a newer build.

The target IPA was prepared by a signing tool: the main binary already carries
LC_LOAD_DYLIB entries and the dylibs already sit in Frameworks/. Instead of
appending new load commands (which the header slack may not fit, and which would
leave the old version loading too), replace in place:

  * overwrite Frameworks/<old> with the new build
  * rename it to <new> — the load-command path is rewritten only when the new
    name is the same length, so no header surgery is needed

That keeps ncmds / sizeofcmds / every section offset untouched. The code
signature still has to be redone by the signing tool afterwards.
"""

import os
import shutil
import sys
import tempfile
import zipfile

LC_LOAD_DYLIB = 0xC
DYLIB_CMDS = {0xC, 0x8000001F, 0x1F, 0x80000018}


def find_load_dylib_cmd(blob, needle: bytes):
    magic, _c, _s, ftype, ncmds, _sc, _f = None, None, None, None, None, None, None
    import struct

    magic, _c, _s, ftype, ncmds, _sc, _f = struct.unpack_from("<IiiIIII", blob, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"not a 64-bit Mach-O (magic=0x{magic:x})")
    off = 32
    hits = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", blob, off)
        if cmd in DYLIB_CMDS:
            name_off = struct.unpack_from("<I", blob, off + 8)[0]
            start = off + name_off
            end = blob.index(b"\0", start)
            if needle in bytes(blob[start:end]):
                hits.append((start, end, bytes(blob[start:end])))
                print(f"  matched cmd=0x{cmd:x} at 0x{off:x}")
        off += sz
    return hits


def main(argv) -> int:
    if len(argv) < 4:
        print("usage: upgrade_hush_in_ipa.py <in.ipa> <out.ipa> <old-name> <new-dylib> [new-name]")
        return 2
    src, dst, old_name, new_dylib = argv[0], argv[1], argv[2], argv[3]
    new_name = argv[4] if len(argv) > 4 else old_name
    if len(new_name) != len(old_name):
        print(f"refusing: name length {len(new_name)} != {len(old_name)} "
              f"(load-command rewrite is in-place only)")
        return 2

    work = tempfile.mkdtemp(prefix="ipaup_")
    try:
        print(f"extracting {src}")
        with zipfile.ZipFile(src) as z:
            z.extractall(work)

        payload = os.path.join(work, "Payload")
        app = os.path.join(payload, [d for d in os.listdir(payload) if d.endswith(".app")][0])
        binary = os.path.join(app, os.path.splitext(os.path.basename(app))[0])
        frameworks = os.path.join(app, "Frameworks")

        old_path = os.path.join(frameworks, old_name)
        new_path = os.path.join(frameworks, new_name)
        if not os.path.exists(old_path):
            raise SystemExit(f"missing {old_path}")
        print(f"replacing Frameworks/{old_name} -> {new_name} ({os.path.getsize(new_dylib):,} B)")
        shutil.copy2(new_dylib, new_path)
        if new_name != old_name:
            os.remove(old_path)

        blob = bytearray(open(binary, "rb").read())
        needle = old_name.encode()
        hits = find_load_dylib_cmd(blob, needle)
        if not hits:
            raise SystemExit(f"main binary has no LC_LOAD_DYLIB containing {old_name}")
        for start, end, current in hits:
            name_off = start - (start - end)  # unused, kept for clarity
            print(f"  LC_LOAD_DYLIB: {current.decode()} -> {current.decode().replace(old_name, new_name)}")
            blob[start:end] = current.replace(needle, new_name.encode())
        open(binary, "wb").write(blob)
        print(f"  binary load command rewritten ({len(hits)} hit(s)), size unchanged: {len(blob):,}")

        print(f"packing {dst}")
        if os.path.exists(dst):
            os.remove(dst)
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for root, _dirs, files in os.walk(work):
                for f in files:
                    full = os.path.join(root, f)
                    arc = os.path.relpath(full, work).replace(os.sep, "/")
                    info = zipfile.ZipInfo(arc)
                    info.external_attr = (os.stat(full).st_mode & 0xFFFF) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    with open(full, "rb") as fh:
                        z.writestr(info, fh.read(), compresslevel=6)
        print(f"done: {dst} ({os.path.getsize(dst):,} bytes)")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
