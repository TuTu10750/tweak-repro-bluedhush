#!/usr/bin/env python3
"""Neutralise the licence gate in an original BluedHush dylib.

Why v2 (the v1 patch did not work)
----------------------------------
v1 patched only the entry of `_HushActivationIsActive` (0x1be2c):

    0x1be2c  mov w0, #1 ; ret

That is correct code for the function itself, but nothing that matters calls it.
The two places that decide whether a gated switch may be turned on read the
cached byte **inline** instead of going through the function:

    0x1c020  adrp x8, #0x299000
    0x1c024  ldrb w8, [x8, #0xf08]     ; _HushActivationStatusLine
    0x1c028  cbz  w8, #0x1c0ec         ; byte == 0 -> "未激活"

    0x1c198  adrp x8, #0x299000
    0x1c19c  ldrb w8, [x8, #0xf08]     ; _HushActivationInterceptToggle
    0x1c1a0  cbz  w8, #0x1c1d0         ; byte == 0 -> 拦下开关

So the only thing that matters is the byte at `*(0x299000 + 0xf08)`.  It is
written in three places:

    0x1bec4  strb w0,  [x8, #0xf08]    ; boot dispatch_once block: w0 = [[License…] …]
    0x1c9e0  strb w26, [x8, #0xf08]    ; w26 = 1 on a real successful activation
    0x1daec  strb wzr, [x8, #0xf08]    ; clears it again (deactivate / failed re-check)

`_HushActivationIsActive` merely reads that same byte, so patching its entry
changes nothing observable — which is exactly what the v15B reference log
showed (`[License] 授权状态：未激活` still printed, six `拦下开关` after it).

What v2 patches
---------------
    A 0x1be2c  entry of _HushActivationIsActive   -> mov w0,#1 ; ret
      Kept for direct callers and for readability.

    B 0x1bebc  `bl objc_msgSend` in the boot dispatch_once block -> mov w0,#1
      Its result is what the `strb` at 0x1bec4 stores, so the byte becomes 1 at
      every cold launch.  **This is the load-bearing patch.**

    C 0x1c03c  `bl objc_msgSend` in _HushActivationStatusLine -> mov w0,#365
      The status line asks the licence object for a number and then does
      `cmp x0,#1` / `b.lt 未激活`.  Forcing 365 takes the activated branch and
      prints a sane "remaining 365 days" instead of a pointer-shaped number.

    D 0x1daec  `strb wzr, [x8, #0xf08]` -> nop
      Stops the deactivate path from clearing the flag again after boot.

Nothing else is touched: the dispatch_once token, the gated-key list
(`_HushActivationGatedKeys`) and the toggle interceptor keep their shipped
behaviour, they simply see "active".

Writing a fake `hush.license.code` into NSUserDefaults does *not* help: the real
validator recomputes the byte and the path at D clears it again — that is the
"点击提示更换" loop.

This is a *reference-log* tool, not a deliverable.  The patched dylib must never
be shipped or presented as reverse-engineering output.

Usage
-----
    python tools/patch_activation.py SRC.dylib DST.dylib
    python tools/patch_activation.py SRC.dylib DST.dylib --dry-run

Every site is verified against its expected original bytes before anything is
written; a mismatch aborts with a disassembly dump rather than silently
corrupting a different build.
"""
from __future__ import annotations

import argparse
import hashlib
import sys

try:
    from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
except ImportError:  # pragma: no cover
    Cs = None

# Offsets belong to BluedHush_5.19.4_1031-0011.dylib.  Both known copies of that
# build (2,826,832 B and 2,992,960 B) share them; a future build will not, so
# every site is validated by bytes rather than trusted by offset.
SITES = [
    (0x1BE2C,
     bytes.fromhex("c81300f0080944f91f0500b1"),
     bytes.fromhex("20008052c0035fd6"),
     "A  IsActive entry           -> mov w0,#1 ; ret"),
    (0x1BEBC,
     bytes.fromhex("a9ea0694"),   # bl #0x1d6960 (objc_msgSend)
     bytes.fromhex("20008052"),   # mov w0,#1
     "B  boot block msgSend       -> mov w0,#1"),
    (0x1C03C,
     bytes.fromhex("49ea0694"),   # bl #0x1d6960
     bytes.fromhex("a02d8052"),   # mov w0,#365
     "C  status-line msgSend      -> mov w0,#365"),
    (0x1DAEC,
     bytes.fromhex("1f213c39"),   # strb wzr, [x8, #0xf08]
     bytes.fromhex("1f2003d5"),   # nop
     "D  deactivate strb wzr      -> nop"),
]


def disasm(blob: bytes, base: int, n: int = 0x20) -> list[str]:
    if Cs is None:
        return ["(capstone not installed, skipping disassembly)"]
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    return [f"  {i.address:#08x}  {i.mnemonic:<8} {i.op_str}"
            for i in md.disasm(blob[base:base + n], base)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    blob = open(args.src, "rb").read()
    print(f"src      {args.src}")
    print(f"         size={len(blob)}  sha256={hashlib.sha256(blob).hexdigest()}")

    ok = True
    for off, exp, pat, note in SITES:
        head = blob[off:off + len(exp)]
        good = head == exp
        ok = ok and good
        print(f"\n[{'OK ' if good else 'BAD'}] {note}")
        print(f"       {off:#x}  before {head.hex()}  after {pat.hex()}")
        if not good:
            print("       disassembly at offset:")
            print("\n".join(disasm(blob, off)))

    if not ok:
        print("\nREFUSING: a site did not match its expected original bytes."
              "\nRe-locate it on this build instead of trusting the offset.",
              file=sys.stderr)
        return 2

    patched = bytearray(blob)
    for off, _exp, pat, _note in SITES:
        patched[off:off + len(pat)] = pat
    pb = bytes(patched)

    print("\ndisassembly after:")
    for off, _exp, _pat, note in SITES:
        print(f"  {note}")
        print("\n".join(disasm(pb, off)))

    print(f"\ndst      size={len(pb)}  sha256={hashlib.sha256(pb).hexdigest()}")

    if args.dry_run:
        print("\ndry run: nothing written")
        return 0

    open(args.dst, "wb").write(pb)
    print(f"\nwrote    {args.dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
