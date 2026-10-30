#!/usr/bin/env python3
# ============================================================================
# tools/patch_infoplist.py —— 给 IPA 的主 App Info.plist 打开「文件共享」
#
# 为什么需要：dylib 只能把日志写进自己的沙盒 Documents，而**能不能看见这个目录
# 由宿主 App 的 Info.plist 决定**，dylib 在运行期没有任何办法打开这个开关
# （SpringBoard 读 plist，不读我们的代码）。所以只能在重签之前改 IPA。
#
# 加上这两个键之后：
#   「文件」App → 我的 iPhone → 你的 App → 里面直接能看到 m1.log
#   也可以接电脑用 iMazing / 爱思 的「应用文件」直接拖出来
#
# 用法：
#   python tools\patch_infoplist.py Blued.ipa Blued-shared.ipa
#   python tools\patch_infoplist.py Blued.ipa --check        # 只看现在的值，不写
#
# ⚠ 改完 plist 签名就失效了，必须用你的证书重新签一遍再装（你本来就要重签）。
# ============================================================================

import argparse
import os
import plistlib
import sys
import zipfile

KEYS = {
    "UIFileSharingEnabled": True,            # iTunes/文件 App 能看到 Documents
    "LSSupportsOpeningDocumentsInPlace": True,  # 允许原地打开，Documents 才会出现在「文件」
}


def find_main_plist(names):
    """主 App 的 Info.plist：Payload/Xxx.app/Info.plist（正好两段深）。"""
    hits = []
    for n in names:
        parts = n.split("/")
        if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") \
                and parts[2] == "Info.plist":
            hits.append(n)
    hits.sort(key=lambda p: len(p))
    return hits[0] if hits else None


def load_plist(zf, name):
    raw = zf.read(name)
    return plistlib.loads(raw), raw


def dump_plist(obj):
    # 原版多数是 binary；binary 体积小、和系统一致，统一输出 binary
    return plistlib.dumps(obj, fmt=plistlib.FMT_BINARY, sort_keys=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--check", action="store_true", help="只看当前值，不产出新 IPA")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        print("找不到文件：%s" % args.ipa)
        return 2

    with zipfile.ZipFile(args.ipa) as zf:
        names = zf.namelist()
        target = find_main_plist(names)
        if target is None:
            print("这个 IPA 里没找到 Payload/*.app/Info.plist，可能不是标准 IPA")
            return 2

        info, raw = load_plist(zf, target)
        bundle = info.get("CFBundleIdentifier", "?")
        print("目标 : %s" % target)
        print("Bundle: %s" % bundle)
        print("现有值:")
        for k in KEYS:
            print("  %-36s = %s" % (k, info.get(k, "(未设置)")))

        need = {k: v for k, v in KEYS.items() if info.get(k) != v}
        if not need:
            print("\n两个键都已就绪，不需要改。")
            if args.check:
                return 0
            return 0

        if args.check:
            print("\n需要补：%s" % ", ".join(need))
            return 0

        if not args.out:
            print("\n需要输出路径：python tools/patch_infoplist.py in.ipa out.ipa")
            return 2
        if os.path.abspath(args.out) == os.path.abspath(args.ipa):
            print("\n输出不能覆盖输入，换个文件名。")
            return 2

        info.update(KEYS)
        new_raw = dump_plist(info)
        print("\n写入 %d 字节新 plist（原 %d 字节）" % (len(new_raw), len(raw)))

        total = len(names)
        with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for i, n in enumerate(names, 1):
                if n == target:
                    out.writestr(n, new_raw)
                else:
                    data = zf.read(n)
                    out.writestr(n, data)
                if i % 500 == 0 or i == total:
                    print("  打包 %d/%d" % (i, total))

    print("\n完成：%s" % args.out)
    print("提醒：签名已失效，用你的证书 + 描述文件重签后再装。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
