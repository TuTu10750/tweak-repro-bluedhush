#!/usr/bin/env python3
"""Inject a tweak dylib into a decrypted IPA without a Mac.

Self-signing tools (ESign / Sideloadly / TrollStore helpers) can inject a dylib
themselves, but LiveContainer runs an IPA as-is and has no injection step, so the
binary must already carry the load command.

What this does:
  1. copy each dylib into Payload/<App>.app/Frameworks/
  2. append one LC_LOAD_DYLIB per dylib inside the existing Mach-O header slack
     (the gap between sizeofcmds and the first __TEXT section is real, unused
     space — nothing gets moved, no offsets are rewritten)
  3. re-zip the bundle

Only the header bytes change, so the app's code and data stay byte-identical.
The code signature is invalidated on purpose; the signing tool re-signs the
whole bundle afterwards.

If the header slack is too small the script stops and says so rather than
silently producing a broken binary.
"""

import os
import shutil
import struct
import sys
import tempfile
import zipfile

LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 2


def load_commands(blob: bytes):
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags = struct.unpack_from("<IiiIIII", blob, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a 64-bit Mach-O (magic=0x{magic:x})")
    if ftype != MH_EXECUTE:
        raise SystemExit(f"filetype {ftype} is not MH_EXECUTE")
    entries, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", blob, off)
        entries.append((cmd, sz, off))
        off += sz
    return (cpu, ncmds, sizeofcmds), entries


def header_slack(blob: bytes):
    meta, entries = load_commands(blob)
    _cpu, ncmds, sizeofcmds = meta
    first_section = None
    for cmd, sz, off in entries:
        if cmd == 0x19:  # LC_SEGMENT_64
            name = blob[off + 8 : off + 24].split(b"\0")[0].decode()
            if name != "__TEXT":
                continue
            nsects = struct.unpack_from("<I", blob, off + 64)[0]
            so = off + 72
            for _ in range(nsects):
                foff = struct.unpack_from("<I", blob, so + 48)[0]  # section_64.offset
                if foff:
                    first_section = foff if first_section is None else min(first_section, foff)
                so += 80
    if first_section is None:
        raise SystemExit("could not locate the first __TEXT section")
    return 32 + sizeofcmds, first_section, meta, entries


def make_load_dylib(path: bytes) -> bytes:
    name = path + b"\0"
    pad = (-(24 + len(name))) % 8
    cmdsize = 24 + len(name) + pad
    body = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    return body + name + b"\0" * pad


def inject(binary: bytes, dylib_paths):
    header_end, first_section, (cpu, ncmds, sizeofcmds), entries = header_slack(binary)
    new_cmds = b"".join(make_load_dylib(p.encode()) for p in dylib_paths)
    slack = first_section - header_end
    if len(new_cmds) > slack:
        raise SystemExit(
            f"header slack is {slack} bytes but {len(new_cmds)} are needed. "
            f"Shrink the dylib name(s) or use a tool that rebuilds load commands."
        )

    blob = bytearray(binary)
    blob[header_end : header_end + len(new_cmds)] = new_cmds
    struct.pack_into("<II", blob, 16, ncmds + len(dylib_paths), sizeofcmds + len(new_cmds))
    print(f"  header slack {slack} B, used {len(new_cmds)} B, left {slack - len(new_cmds)} B")
    for p in dylib_paths:
        print(f"  + LC_LOAD_DYLIB {p}")
    return bytes(blob)


def main(argv) -> int:
    if len(argv) < 3:
        print("usage: inject_ipa.py <in.ipa> <out.ipa> <dylib>[@rpath-name] [more...]")
        return 2
    src, dst, specs = argv[0], argv[1], argv[2:]

    pairs = []
    for spec in specs:
        if "@" in spec and spec.rsplit("@", 1)[1].startswith("rpath/"):
            local, rpath = spec.rsplit("@", 1)
            pairs.append((local, rpath))
        else:
            pairs.append((spec, "rpath/" + os.path.basename(spec)))

    work = tempfile.mkdtemp(prefix="ipainject_")
    try:
        print(f"extracting {src}")
        with zipfile.ZipFile(src) as z:
            z.extractall(work)

        payload = os.path.join(work, "Payload")
        apps = [d for d in os.listdir(payload) if d.endswith(".app")]
        if len(apps) != 1:
            raise SystemExit(f"expected exactly one .app in Payload, found {apps}")
        app = os.path.join(payload, apps[0])
        binary = os.path.join(app, os.path.splitext(apps[0])[0])
        if not os.path.exists(binary):
            cands = [f for f in os.listdir(app) if os.access(os.path.join(app, f), os.X_OK) and "." not in f]
            if not cands:
                raise SystemExit("could not find the main executable")
            binary = os.path.join(app, cands[0])
        print(f"app     : {apps[0]}")
        print(f"binary  : {os.path.basename(binary)}")

        frameworks = os.path.join(app, "Frameworks")
        os.makedirs(frameworks, exist_ok=True)
        targets = []
        for local, rpath in pairs:
            base = os.path.basename(local)
            shutil.copy2(local, os.path.join(frameworks, base))
            targets.append("@rpath/" + base)
            print(f"  copied {base} ({os.path.getsize(local):,} B) -> Frameworks/")

        data = open(binary, "rb").read()
        patched = inject(data, targets)
        open(binary, "wb").write(patched)
        print(f"  binary patched: {len(data):,} -> {len(patched):,} bytes")

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
