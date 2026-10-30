#!/usr/bin/env python3
# ============================================================================
# ci/gates.py —— 单一真源的三道门禁（macOS 与 Linux 共用，纯 Python3、零依赖）
#
# 为什么要有它：.github/workflows/build.yml 原来把三道闸写在 run 里，
# 而 build-linux.yml 只有一句 `file "$DYLIB" || true`（永不失败），
# 等于存在一条完全不经门禁、却同样产出 dylib 的通道。
# 现在两个工作流都只调这个脚本，闸门口径不可能再分叉。
#
# 用法：
#   python3 ci/gates.py --dylib dist/BluedHushREA.dylib \
#                       --archs arm64,arm64e --tag REA-Test
#
# 退出码：0 = 全过；1 = 有闸门不通过（GitHub Actions 会打 ::error::）
# ============================================================================

import argparse
import os
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE

LC_SEGMENT = 0x1
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_ARM64 = CPU_ARCH_ABI64 | 12
CPU_TYPE_X86_64 = CPU_ARCH_ABI64 | 7

DYLIB_LOAD_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
                   LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}

# 禁止出现的依赖 / install_name 片段
BAD_TOKENS = ["CydiaSubstrate"]
BAD_PREFIXES = ["/Library/MobileSubstrate/", "/Library/Frameworks/", "/usr/lib/libsubstrate"]

FAILS = []


def fail(gate, msg):
    FAILS.append((gate, msg))
    if os.environ.get("GITHUB_ACTIONS"):
        print("::error title=%s::%s" % (gate, msg))
    print("FAIL [%s] %s" % (gate, msg))


def ok(msg):
    print("OK   %s" % msg)


def arch_name(cputype, cpusubtype):
    sub = cpusubtype & 0x00FFFFFF
    if cputype == CPU_TYPE_ARM64:
        if sub == 2:
            return "arm64e"
        if sub in (0, 1):
            return "arm64"
        return "arm64-sub%d" % sub
    if cputype == CPU_TYPE_X86_64:
        return "x86_64"
    return "cpu-0x%x-%d" % (cputype, cpusubtype)


def parse_slice(data, base, size):
    """解析单个 Mach-O slice，返回 dict。"""
    out = {"deps": [], "install_name": None, "cstrings": b"", "syms": [],
           "cputype": None, "cpusubtype": None}
    magic = struct.unpack_from("<I", data, base)[0]
    if magic == MH_MAGIC_64:
        # magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
        hdr = struct.unpack_from("<IiiIIIII", data, base)
        cputype, cpusubtype, _ft, ncmds, sizeofcmds, _flg, _res = hdr[1:]
        off = base + 32
    elif magic == MH_MAGIC:
        hdr = struct.unpack_from("<IiiIIII", data, base)
        cputype, cpusubtype, _ft, ncmds, sizeofcmds, _flg = hdr[1:]
        off = base + 28
    else:
        raise ValueError("slice 0x%x 不是 Mach-O（magic=0x%08x）" % (base, magic))

    out["cputype"] = cputype
    out["cpusubtype"] = cpusubtype

    symtab = None
    sections = []          # (segname, sectname, offset, size)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd in DYLIB_LOAD_CMDS or cmd == LC_ID_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            start = off + name_off
            end = data.index(b"\x00", start)
            name = data[start:end].decode("utf-8", "replace")
            if cmd == LC_ID_DYLIB:
                out["install_name"] = name
            else:
                out["deps"].append(name)
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        elif cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].split(b"\x00")[0].decode("ascii", "replace")
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            soff = off + 72
            for _s in range(nsects):
                sectname = data[soff:soff + 16].split(b"\x00")[0].decode("ascii", "replace")
                ssegname = data[soff + 16:soff + 32].split(b"\x00")[0].decode("ascii", "replace")
                size_ = struct.unpack_from("<Q", data, soff + 40)[0]
                offset_ = struct.unpack_from("<I", data, soff + 48)[0]
                sections.append((ssegname or segname, sectname, offset_, size_))
                soff += 80
        elif cmd == LC_SEGMENT:
            segname = data[off + 8:off + 24].split(b"\x00")[0].decode("ascii", "replace")
            nsects = struct.unpack_from("<I", data, off + 48)[0]
            soff = off + 56
            for _s in range(nsects):
                sectname = data[soff:soff + 16].split(b"\x00")[0].decode("ascii", "replace")
                ssegname = data[soff + 16:soff + 32].split(b"\x00")[0].decode("ascii", "replace")
                size_ = struct.unpack_from("<I", data, soff + 36)[0]
                offset_ = struct.unpack_from("<I", data, soff + 40)[0]
                sections.append((ssegname or segname, sectname, offset_, size_))
                soff += 68
        off += cmdsize

    # 注意：FAT 文件里 load command 中的 offset 都是相对 slice 起点的
    for segname, sectname, soff_, ssize in sections:
        if sectname == "__cstring" and segname == "__TEXT":
            a = base + soff_
            out["cstrings"] += data[a:a + ssize]

    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        symoff += base
        stroff += base
        strtab = data[stroff:stroff + strsize]
        is64 = (magic == MH_MAGIC_64)
        ent = 16 if is64 else 12
        for i in range(nsyms):
            e = symoff + i * ent
            if e + ent > len(data):
                break
            n_strx, n_type = struct.unpack_from("<IB", data, e)
            if (n_type & 0x0E) == 0:          # N_UNDF = 未定义的外部符号
                end = strtab.find(b"\x00", n_strx)
                if end > n_strx:
                    out["syms"].append(strtab[n_strx:end].decode("utf-8", "replace"))
    return out


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 8:
        raise ValueError("文件过小")
    magic_be = struct.unpack_from(">I", data, 0)[0]
    slices = []
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        step = 32 if magic_be == FAT_MAGIC_64 else 20
        off = 8
        for _ in range(nfat):
            if magic_be == FAT_MAGIC_64:
                cputype, cpusubtype, offset, size = struct.unpack_from(">IIQQ", data, off)
            else:
                cputype, cpusubtype, offset, size = struct.unpack_from(">IIII", data, off)
            info = parse_slice(data, offset, size)
            info["slice_offset"] = offset
            slices.append(info)
            off += step
    else:
        info = parse_slice(data, 0, len(data))
        info["slice_offset"] = 0
        slices.append(info)
    return data, slices


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--archs", default="arm64,arm64e")
    ap.add_argument("--tag", default="REA-Test",
                    help="必需字符串，逗号分隔表示全部都要有")
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    label = ("[%s] " % args.label) if args.label else ""

    if not os.path.isfile(args.dylib):
        fail("exists", "%s缺少文件：%s" % (label, args.dylib))
        return 1
    size = os.path.getsize(args.dylib)
    if size < 4096:
        fail("exists", "%s文件过小（%d B），疑似空产物" % (label, size))
        return 1
    ok("%sfile %s (%d bytes)" % (label, args.dylib, size))

    try:
        data, slices = parse(args.dylib)
    except Exception as e:
        fail("format", "%s无法解析为 Mach-O：%s" % (label, e))
        return 1

    # ---------- 闸门 1a：架构 ----------
    got = [arch_name(s["cputype"], s["cpusubtype"]) for s in slices]
    ok("%sarchs = %s" % (label, ",".join(got)))
    want = [a.strip() for a in args.archs.split(",") if a.strip()]
    for w in want:
        if w not in got:
            fail("arch", "%s缺少架构 %s（实际 %s）" % (label, w, ",".join(got)))

    # ---------- 闸门 1b：依赖与 install_name ----------
    all_deps = []
    for s in slices:
        all_deps.extend(s["deps"])
        iname = s["install_name"]
        if iname:
            ok("%sinstall_name = %s" % (label, iname))
            for p in BAD_PREFIXES:
                if iname.startswith(p):
                    fail("deps", "%sinstall_name 是 rootful 绝对路径：%s" % (label, iname))
    ok("%sotool -L (前 12) = %s" % (label, ", ".join(all_deps[:12])))
    for d in all_deps:
        for t in BAD_TOKENS:
            if t.lower() in d.lower():
                fail("deps", "%s链接了 %s（非越狱/LiveContainer 无法解析）" % (label, d))
        for p in BAD_PREFIXES:
            if d.startswith(p):
                fail("deps", "%s依赖 rootful 绝对路径：%s" % (label, d))

    # ---------- 闸门 2a：无 MSHook / Logos 符号 ----------
    undef = set()
    for s in slices:
        undef.update(s["syms"])
    bad = [u for u in undef if "mshook" in u.lower() or "logos" in u.lower()]
    for b in bad:
        fail("symbols", "%s仍有 substrate/Logos 符号：%s" % (label, b))
    if not bad:
        ok("%s无 MSHook* / Logos 未定义符号（扫描 %d 个未定义符号）" % (label, len(undef)))

    # ---------- 闸门 2b：必须带探测 tag ----------
    blob = b"".join(s["cstrings"] for s in slices)
    for tag in [t.strip() for t in (args.tag or "").split(",") if t.strip()]:
        if tag.encode() in blob:
            ok("%s必需字符串存在：%s" % (label, tag))
        else:
            fail("tag", "%s__TEXT,__cstring 里找不到 %s —— 说明源码没编进去或产物不对"
                 % (label, tag))

    print("")
    if FAILS:
        print("%s门禁未通过：%d 项" % (label, len(FAILS)))
        return 1
    print("%s门禁全过（格式/架构/依赖/符号/标记）" % label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
