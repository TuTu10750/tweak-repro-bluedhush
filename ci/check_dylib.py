#!/usr/bin/env python3
"""Verify the rebuilt dylib is deployable without a jailbreak.

Checks, on the produced Mach-O:
  * file type is MH_DYLIB and the slice is arm64
  * no @rpath/CydiaSubstrate load command (self-signed / LiveContainer has none)
  * ObjC metadata landed: __objc_classlist entry count matches the recovered class count
  * the hook backbone symbol set is present (MSHookMessageEx provided in-tree)

Exit code 0 only when every mandatory check passes.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
DYLIB_CMDS = {0xC, 0x8000001F, 0x1F, 0x80000018, 0x18B}
CPU_ARM64 = 0x0100000C


def sections(blob):
    magic, cpu, sub, ftype, ncmds, _size, _flags = struct.unpack_from("<IiiIIII", blob, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"not a 64-bit Mach-O (magic=0x{magic:x})")
    out = {}
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", blob, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", blob, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                name = blob[so : so + 16].split(b"\0")[0].decode()
                addr, size, foff = struct.unpack_from("<QQI", blob, so + 32)
                out[name] = (addr, size, foff)
                so += 80
        off += sz
    return cpu, ftype, ncmds, out


def dylib_loads(blob):
    _m, _c, _s, _f, ncmds, _sz, _fl = struct.unpack_from("<IiiIIII", blob, 0)
    off, deps = 32, []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", blob, off)
        if cmd in DYLIB_CMDS:
            noff = struct.unpack_from("<I", blob, off + 8)[0]
            deps.append(blob[off + noff : off + sz].split(b"\0")[0].decode("utf-8", "replace"))
        off += sz
    return deps


def main() -> int:
    path = sys.argv[1]
    expect_classes = int(sys.argv[2]) if len(sys.argv) > 2 else 76
    blob = open(path, "rb").read()

    cpu, ftype, ncmds, sects = sections(blob)
    deps = dylib_loads(blob)
    failures = []

    print(f"file      : {path}")
    print(f"size      : {len(blob):,} bytes")
    print(f"cputype   : {'arm64' if cpu == CPU_ARM64 else hex(cpu)}")
    print(f"filetype  : {ftype} ({'MH_DYLIB' if ftype == 6 else 'NOT A DYLIB'})")
    print(f"ncmds     : {ncmds}")

    if ftype != 6:
        failures.append(f"filetype {ftype} is not MH_DYLIB")
    if cpu != CPU_ARM64:
        failures.append(f"cputype {hex(cpu)} is not arm64")

    print("load deps :")
    for d in deps:
        print(f"  {d}")
    substrate = [d for d in deps if "substrate" in d.lower() or "ellekit" in d.lower()]
    if substrate:
        failures.append(f"still depends on a substrate framework: {substrate}")
    else:
        print("substrate : NONE  (self-signed / LiveContainer safe)")

    target = sects.get("__objc_classlist")
    if not target:
        failures.append("__objc_classlist missing — ObjC metadata did not link")
        found = 0
    else:
        found = target[1] // 8
        mark = "OK" if found == expect_classes else "MISMATCH"
        print(f"classlist : {found} classes (expect {expect_classes}) [{mark}]")
        if found != expect_classes:
            failures.append(f"classlist {found} != {expect_classes}")

    for name in ("__objc_methlist", "__objc_methname", "__objc_ivar", "__objc_selrefs"):
        if name in sects:
            print(f"{name:<12}: 0x{sects[name][1]:x}")
        else:
            failures.append(f"missing section {name}")

    syms = [n for n in (b"MSHookMessageEx",) if n in blob]
    print(f"hook shim : {'MSHookMessageEx present in image' if syms else 'MSHookMessageEx NOT referenced'}")
    if not syms:
        failures.append("MSHookMessageEx not referenced — hook layer did not link in")

    if failures:
        print("\nFAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL CHECKS PASSED — deployable without substrate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
