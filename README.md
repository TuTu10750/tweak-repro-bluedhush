# BluedHushREA

`BluedHush_5.19.dylib` 的**行为复现件**：由静态逆向（`LC_DYLD_CHAINED_FIXUPS` + relative method list +
capstone 全量反汇编）还原出的 Hook 面与开关体系，用 Theos / Logos 重写，GitHub Actions 云端编译。

- 宿主：`com.danlan.xiaolan`（Blued 7.50.3）
- 目标：`iphone:clang:latest:14.0`，`ARCHS = arm64 arm64e`
- 注入点：`%ctor`（Theos 自动生成），关键 Hook 输出 `NSLog(@"[REA-Test] 注入成功")`

> **v5 重要变更（2026-10-30 真机首启闪退修复）**
> 原 v4 在 `+load` 阶段调用 `class_getInstanceMethod` 做全类扫描与继承兜底，而该 API 会
> **触发目标类的 `+initialize`**。Blued 的 `+initialize` 依赖尚未构造的全局对象
> （崩溃现场 `ldr x8,[x20]` 得到 0，再 `ldr x8,[x8,#0x20]` → SIGSEGV at `0x20`，
> 帧序 `load_images → BluedHushREA.dylib+0x40b4/+0x4fd0 → class_getInstanceMethod →
> CALLING_SOME_+initialize_METHOD`）。v5 起：
> 1. `+load` / 构造函数里**只做 `NSLog` + 调度**，零 Runtime 探测；
> 2. 全文件禁用 `class_getInstanceMethod` / `class_getClassMethod`，只用不触发
>    `+initialize` 的 `class_copyMethodList` / `method_setImplementation` / `class_addMethod`；
> 3. Hook 安装推迟到 App 启动完成后：main queue **+2s** 首轮，后台队列 **+4/+8/+15/+25s** 补装；
> 4. `setHidden:` / `setAlpha:` 两个继承方法的 hook 已删除（它们必须走 `class_getInstanceMethod`
>    取类型编码，代价大于收益）。

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

## v9：交互层复刻（悬浮球 + 分类菜单 + 开关持久化）

原版的 UI 不是资源包，而是**纯代码 UIKit**。这一点在 `BluedHush_5.19.dylib` 里可以硬证：

| 证据 | 结果 |
|---|---|
| `.bundle` / `.xib` / `.nib` / `Assets.car` / `imageNamed` | **各 0 次** |
| `systemImageNamed` | 2 次 → 图标全部是 **SF Symbols** |
| `HushFloatBall : UIView` | `iconView: UIImageView` + `-initWithFrame:` / `-refreshIcon` / `-onTap` / `-onPan:` |
| `HushSettingsPanel : UIViewController` | `table` / `modules` / `searchCtl` / `hushTopSearchBar` + `-buildModel` / `-openModule:` / `-showLog` / `-hushCloseModal` + 全套 `UITableViewDataSource` |
| `HushModuleEntry / HushModuleSection / HushSwitchItem / HushActionItem` | 三层菜单模型（module → section → item），开关项带 `key`，动作项带 `handler` |
| `HushSwitchCell : UITableViewCell` | `sw: UISwitch` + `onToggle:` block，`-configureTitle:subtitle:icon:effect:on:` |
| `HushModuleDetailController : UITableViewController` | `-initWithTitle:sections:footer:` |
| `HushConfig` | `defaults: NSUserDefaults` + `-isEnabled:` / `-isEnabled:default:` / `-setEnabled:forKey:` / `-registerDefaults` / `-resetToDefaults` |

所以本工程按同样的分层重写（`REAUI.xm`，零 Logos、零 substrate）：

| 原版 | 本工程 |
|---|---|
| `HushFloatBall` | `REAFloatBallView`（UIView + pan/tap/长按，贴边吸附，位置存 `rea_ball_center`） |
| `HushWindowHelper` | `REAOverlayWindow`（`UIWindowLevelAlert+1`，`hitTest:` 穿透，不影响 App 交互） |
| `HushSettingsPanel` | `REAPanelController`（UITableView 列出五个分类） |
| `HushModuleDetailController` | `READetailController`（每个分类的开关页） |
| `HushSwitchCell` | `REASwitchCell`（UISwitch + block 回调） |
| `HushConfig` | `REAUIFlag()` / `REAUISetFlag()`（直接读 `NSUserDefaults`，**改完立即生效**） |

入口路径（复刻原版的操作面）：

- **单击悬浮球** → 设置面板
- **拖动** → 移动，松手贴边，位置持久化
- **长按** → 快捷菜单：Hook 报告 / 触发统计 / 重装 Hook / 隐藏悬浮球

分类与开关（key 与 Hook 读取的完全同名）：

| 分类 | 开关 |
|---|---|
| 消息防护 | `switch_anti_recall`、`switch_flash_photo`、`switch_flash_text` |
| 隐私与相册 | `switch_private_photo`、`switch_screenshot`、`switch_watermark` |
| 会员与界面 | `switch_local_vip`、`switch_clean_badge` |
| 定位 | `switch_virtual_location`、`switch_altitude` + 「设置坐标」（写 `rea_fake_location`） |
| 调试 | `rea_show_report` + 查看报告 / 触发统计 / 重装 / 重置 |

## 验证

启动 Blued 后，Console 过滤 `REA-Test`：

```
[REA-Test] 注入成功
[REA-Test] Runtime 注入成功!
[REA-Test] pass ctor hooked 36
```

启动 1.5 秒后屏幕右侧出现悬浮球；单击打开面板，改开关后日志会打印 `[UI] switch_xxx -> 0`。

## 目录

```
Tweak.xm                  # Hook 引擎（Runtime 换实现，零 Logos）
REAUI.xm                  # 交互层（悬浮球 / 分类菜单 / 开关面板）
Makefile                  # ARCHS = arm64 arm64e，FILES = Tweak.xm REAUI.xm
control                   # deb 元信息
BluedHushREA.plist        # Filter: com.danlan.xiaolan
.github/workflows/build.yml
docs/STAGE1_静态分析报告.md
docs/STAGE2_核心逻辑逆向报告.md
docs/hooks_full.txt       # 557 条 Hook 全表（逆向原始数据）
docs/keys.txt             # 68 个开关键
```
