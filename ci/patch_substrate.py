#!/usr/bin/env python3
"""Repoint a dylib's CydiaSubstrate dependency at the bundled substrate shim.

Why: BluedHush_5.19.dylib declares
    LC_LOAD_DYLIB @rpath/CydiaSubstrate.framework/CydiaSubstrate
CydiaSubstrate only exists on jailbroken devices. A self-signed IPA or a
LiveContainer container has no substrate, so dyld refuses the load and the
tweak never runs.

The dylib only needs one symbol from it (MSHookMessageEx), which the in-tree
shim provides. Rewriting the load-command path is enough — no code patching,
no recompilation, all original behaviour preserved.

The replacement name must fit inside the original command size; the tail is
zero-padded, which Mach-O explicitly permits.

Code signature is invalidated by design; re-sign the whole bundle afterwards
(any self-signing tool does this).
"""

import struct
import sys

LC_LOAD_DYLIB = 0xC
OLD_SUFFIX = b"CydiaSubstrate.framework/CydiaSubstrate"
DEFAULT_NEW = b"@rpath/substrate_shim.dylib"


def patch(path: str, new_name: bytes, out_path: str | None = None) -> int:
    blob = bytearray(open(path, "rb").read())
    magic, _cpu, _sub, ftype, ncmds, _size, _flags = struct.unpack_from("<IiiIIII", blob, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"not a 64-bit Mach-O (magic=0x{magic:x})")
    if ftype != 6:
        raise SystemExit(f"filetype {ftype} is not MH_DYLIB")

    off = 32
    patched = 0
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", blob, off)
        if cmd == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", blob, off + 8)[0]
            start = off + name_off
            end = blob.index(b"\0", start)
            current = bytes(blob[start:end])
            if OLD_SUFFIX in current:
                room = sz - name_off
                if len(new_name) + 1 > room:
                    raise SystemExit(
                        f"replacement {new_name!r} needs {len(new_name) + 1} bytes, "
                        f"only {room} available in the load command"
                    )
                blob[start : start + room] = new_name + b"\0" * (room - len(new_name))
                print(f"  LC_LOAD_DYLIB @0x{off:x}: {current.decode()} -> {new_name.decode()}")
                patched += 1
        off += sz

    if not patched:
        print("  no CydiaSubstrate load command found — nothing to do")
        return 0

    dest = out_path or path
    open(dest, "wb").write(blob)
    print(f"  wrote {dest} ({len(blob):,} bytes)")
    print("  NOTE: code signature is now stale; re-sign the bundle before install")
    return patched


def main() -> int:
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    name = sys.argv[3].encode() if len(sys.argv) > 3 else DEFAULT_NEW
    print(f"patching {src}")
    patch(src, name, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
