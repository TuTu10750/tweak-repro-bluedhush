#!/usr/bin/env python3
"""Neutralise the licence gate in an original BluedHush dylib.

Why this exists
---------------
The original tweak ships a 17-key licence gate.  Three functions implement it:

    0x1be2c  _HushActivationIsActive            -> reads *(0x299000 + 0xf08), a
                                                   single byte written once by a
                                                   dispatch_once block at 0x2396f8
    0x1bda4  _HushKeyNeedsActivation(NSString*) -> [_HushActivationGatedKeys()
                                                   containsObject:key]
    0x1c14c  _HushActivationInterceptToggle     -> refuses setEnabled: when the
                                                   key is gated and inactive

A stock install therefore keeps the 17 gated keys off:

    [License] 授权状态：未激活（受限键 17 项）
    [BOOT]    激活状态：未激活（受限 17 项：定位与追踪 + 限制解放）
    [License] 受限功能未激活，拦下开关：switch_virtual_location

Patching the *entry* of _HushActivationIsActive to `mov w0, #1 ; ret` makes every
downstream check see an activated install, so the original can be used to
capture a reference log of the 17 features actually running.  Nothing else in
the image is touched: the dispatch_once block, the gated key list and the
toggle interceptor stay exactly as shipped.

This is a *reference-log* tool, not a deliverable.  The patched dylib must never
be shipped or presented as reverse-engineering output.

Usage
-----
    python tools/patch_activation.py SRC.dylib DST.dylib
    python tools/patch_activation.py SRC.dylib DST.dylib --dry-run

Verification is built in: the script disassembles the eight bytes before and
after, and refuses to write if the original bytes do not match the expected
`adrp x8, #0x296000` prologue.  A different build of the tweak will have a
different offset and must be located again.
"""
from __future__ import annotations

import argparse
import hashlib
import sys

try:
    from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
except ImportError:  # pragma: no cover - capstone is only needed for disassembly
    Cs = None

# Offset of _HushActivationIsActive inside BluedHush_5.19.4_1031-0011.dylib.
# Both known copies of that build (2,826,832 B and 2,992,960 B) share it, but a
# future build will not; re-locate with the bytes below rather than trusting it.
ENTRY_OFFSET = 0x1BE2C

# adrp x8, #0x296000  /  ldr x8, [x8, #0x810]  /  cmn x8, #1  /  b.ne
EXPECTED = bytes.fromhex("c81300f0080944f91f0500b1")
# mov w0, #1  /  ret
PATCH = bytes.fromhex("20008052c0035fd6")


def disasm(blob: bytes, base: int) -> list[str]:
    if Cs is None:
        return ["(capstone not installed, skipping disassembly)"]
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    return [
        f"  {i.address:#08x}  {i.mnemonic:<8} {i.op_str}"
        for i in md.disasm(blob, base)
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src", help="original dylib")
    ap.add_argument("dst", help="patched dylib to write")
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=ENTRY_OFFSET,
                    help=f"entry offset (default {ENTRY_OFFSET:#x})")
    ap.add_argument("--dry-run", action="store_true", help="verify only, write nothing")
    args = ap.parse_args()

    blob = open(args.src, "rb").read()
    off = args.offset
    head = blob[off:off + len(EXPECTED)]

    print(f"src      {args.src}")
    print(f"         size={len(blob)} sha256={hashlib.sha256(blob).hexdigest()}")
    print(f"offset   {off:#x}")
    print(f"before   {head.hex()}")

    if head != EXPECTED:
        print("\nREFUSING: the bytes at this offset are not the _HushActivationIsActive"
              "\nprologue.  Locate the function again (search for the adrp/ldr/cmn/b.ne"
              "\nshape above) and pass --offset.", file=sys.stderr)
        print("\ndisassembly at offset:")
        print("\n".join(disasm(blob[off:off + 0x20], off)), file=sys.stderr)
        return 2

    print("disassembly before:")
    print("\n".join(disasm(blob[off:off + 0x20], off)))

    patched = bytearray(blob)
    patched[off:off + len(PATCH)] = PATCH
    pb = bytes(patched)

    print("\ndisassembly after:")
    print("\n".join(disasm(pb[off:off + 0x20], off)))

    changed = [hex(i) for i in range(off, off + len(PATCH)) if blob[i] != pb[i]]
    print(f"\nchanged  {changed}")
    print(f"dst      size={len(pb)} sha256={hashlib.sha256(pb).hexdigest()}")

    if args.dry_run:
        print("\ndry run: nothing written")
        return 0

    open(args.dst, "wb").write(pb)
    print(f"\nwrote    {args.dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
