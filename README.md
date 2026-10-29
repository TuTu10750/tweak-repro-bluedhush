# BluedHushREA

`BluedHush_5.19.dylib` 的**行为复现件**：由静态逆向（`LC_DYLD_CHAINED_FIXUPS` + relative method list +
capstone 全量反汇编）还原出的 Hook 面与开关体系，用 Theos / Logos 重写，GitHub Actions 云端编译。

- 宿主：`com.danlan.xiaolan`（Blued 7.50.3）
- 目标：`iphone:clang:latest:14.0`，`ARCHS = arm64 arm64e`
- 注入点：`%ctor`（Theos 自动生成），关键 Hook 输出 `NSLog(@"[REA-Test] 注入成功")`

## 逆向依据（原插件实测数据）

| 指标 | 数值 |
|---|---|
| Mach-O | MH_DYLIB, arm64, minos 14.0, `@rpath/BluedHush.dylib`, rootless rpath |
| 符号 | 1054（未 strip） |
| ObjC | 76 类 / 1015 方法（relative method list） |
| `_MSHookMessageEx` | 557 处（已解 447 条 类+selector+IMP） |
| 宿主类 | ~90 个 |
| 开关键 | 68 个（`[[HushConfig shared] isEnabled:@"switch_xxx"]`） |
| 静态初始化器 | 28 个（`__TEXT,__init_offsets`），主安装器 `0x434C0` |

## 复现范围

| 功能域 | 开关键 | 复现状态 |
|---|---|---|
| 撤回对抗（recallType→0 / isSuperRecallTip→NO）| `switch_anti_recall` | ✅ 完整复刻 |
| 截图提示三连压平 | `switch_screenshot` | ✅ 完整复刻 |
| 隐私相册解锁 | `switch_private_photo` | ✅ 核心 Hook |
| 本地 VIP | `switch_local_vip` | ✅ 核心 Hook |
| 阅后即焚/闪文提示 | `switch_flash_photo` / `switch_flash_text` | ◐ 入口 Hook |
| 存图/水印限制 | `switch_watermark` | ✅ |
| 反越狱/反模拟器/反调试（12 连打）| — | ✅ 全部返回安全值 |
| 虚拟定位 / 海拔伪造 | `switch_virtual_location` / `switch_altitude` | ✅ |
| 访客/会话列表/TabBar | — | ◐ 部分 |

> 未复刻的 400+ Hook 详见 `docs/hooks_full.txt`（类名 / selector / IMP / 关联开关），可逐条补齐。

## 配置

所有开关默认 **开**。想关掉某个功能：

```bash
# SSH 到设备后
defaults write com.danlan.xiaolan switch_anti_recall -bool NO
# 或直接改 /var/mobile/Library/Preferences/com.danlan.xiaolan.plist
```

虚拟定位坐标：

```bash
defaults write com.danlan.xiaolan rea_fake_location -dict lat 39.9042 lng 116.4074 alt 50
```

## 构建

### 云端（推荐）

推送到 GitHub 后自动跑 `.github/workflows/build.yml`（macos-14 + Theos + iPhoneOS SDK），
产物见 Actions 的 `BluedHushREA-dylib` artifact。

```bash
gh run list
gh run download <run-id> -n BluedHushREA-dylib -D ./out
```

### 本地（macOS + Theos）

```bash
export THEOS=$HOME/theos
make package FINALPACKAGE=1
# 产物: .theos/obj/BluedHushREA.dylib
```

## 真机注入

两种方式：

1. **deb 安装**（越狱机）：`dpkg -i packages/*.deb` → `killall -9 Blued`
2. **手工注入**（非越狱/TrollStore 场景）：
   ```bash
   optool install -c load -p @executable_path/Frameworks/BluedHushREA.dylib -t Payload/Blued.app/Blued
   cp BluedHushREA.dylib Payload/Blued.app/Frameworks/
   ldid -S Payload/Blued.app/Blued
   ```
   > 注意：本插件依赖 Substrate/ellekit 才能完成 `%hook` 的运行时替换。

## 验证

启动 Blued 后，Console 过滤 `REA-Test`：

```
[REA-Test] 注入成功
[REA-Test] BluedHushREA loaded, pid=1234
[REA-Test] hooked-classes alive 14/14: GJIMMessageModel,... 
```

## 目录

```
Tweak.xm                  # Logos 源码（Hook 复刻）
Makefile                  # ARCHS = arm64 arm64e
control                   # deb 元信息
BluedHushREA.plist        # Filter: com.danlan.xiaolan
.github/workflows/build.yml
docs/STAGE1_静态分析报告.md
docs/STAGE2_核心逻辑逆向报告.md
docs/hooks_full.txt       # 557 条 Hook 全表（逆向原始数据）
docs/keys.txt             # 68 个开关键
```
