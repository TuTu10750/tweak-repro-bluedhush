#!/usr/bin/env python3
"""Apple-ld -> lld(darwin) argument translator.

Theos drives the classic Apple ld64 CLI (-arch / -iphoneos_version_min / -m llvm).
ld64.lld speaks the modern driver (-platform_version ios X Y) and rejects the
legacy spellings, so translate them here and hand off to lld's darwin flavor.
"""
import os
import sys

DARWIN_ALIASES = {
    "-iphoneos_version_min": "ios",
    "-ios_version_min": "ios",
    "-macosx_version_min": "macos",
    "-tvos_version_min": "tvos",
    "-watchos_version_min": "watchos",
}


def main() -> int:
    argv = sys.argv[1:]
    out: list[str] = []
    arch = None
    platform = None
    version = None
    i = 0
    while i < len(argv):
        tok = argv[i]
        # Apple ld accepts "-m llvm"; lld's driver does not and it eats the next arg.
        if tok == "-m":
            i += 2
            continue
        if tok in DARWIN_ALIASES:
            platform, version = DARWIN_ALIASES[tok], argv[i + 1]
            i += 2
            continue
        if tok == "-arch" and i + 1 < len(argv):
            arch = argv[i + 1]
            out += [tok, argv[i + 1]]
            i += 2
            continue
        out.append(tok)
        i += 1

    if platform and version and "-platform_version" not in out:
        out += ["-platform_version", platform, version, version]
    if arch and arch not in ("arm64", "arm64e", "arm64_32", "x86_64", "armv7", "armv7s"):
        sys.stderr.write(f"ld64wrap: unsupported arch {arch!r}\n")
    # arm64e is ABI-compatible with arm64 for linking purposes.
    out = ["arm64" if t == "arm64e" else t for t in out]

    for exe in ("/usr/bin/lld", "lld", "/usr/bin/ld64.lld"):
        path = exe if exe.startswith("/") else None
        if path and not os.path.exists(path):
            continue
        try:
            os.execv(path or "/usr/bin/lld", [path or "lld", "-flavor", "darwin"] + out)
        except OSError:
            continue
    sys.stderr.write("ld64wrap: no darwin linker available\n")
    return 127


if __name__ == "__main__":
    sys.exit(main())
