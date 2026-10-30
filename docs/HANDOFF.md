# HANDOFF — Blued「小蓝助手」Runtime Tweak 项目状态交接书

> **文档用途**：多 Agent 协同工程流的**唯一事实源**。任何 Agent 接手前先读完本文，再动代码。
> **生成时间**：2026-10-30（v12 构建通过后）
> **基线提交**：`1ff9319`（`v12: fix dead panel (same-window hosting) + settings entry + purify center wired to 52 real anchors`）
> **本文件状态**：已保存到工作区，**尚未 git commit**（接管方确认后自行提交）

---

## 0. 一句话现状

UI 层（悬浮球 + 9 分类菜单 + 二级开关页）已经能拖、能点、能关；底层 36 条核心 Hook 全部对齐（`ok=36 miss=0`）；净化中心的 26 个开关已挂真实锚点（52 条选择子 + 47 条视图规则 + 1 条网络 host 规则）；**但真机验证暴露两个 P0 级回归：开屏净化导致卡启动图、设置页注入导致卡死/闪退。这两条必须先修，修完才继续铺剩余 65 个开关。**

当前状态一句话：**"能打开、能操作，但两处会卡死 App"**。

---

## 1. 仓库信息

### 1.1 仓库地址

| 项 | 值 |
|---|---|
| GitHub 完整地址 | `https://github.com/TuTu10750/tweak-repro-bluedhush` |
| 当前使用分支 | `master`（唯一活跃分支，CI 触发分支为 `main, master`） |
| 本地工作副本 | `D:\DeepSeek\hush\tweak-repro` |
| Git 账号 / 权限 | `TuTu10750`（`gh auth status` 已登录，token 具备 `repo` + `workflow` scope） |
| 远端 | `origin` → 上述地址（HTTPS + keyring） |

### 1.2 最近提交历史

| commit | 说明 |
|---|---|
| `1ff9319` | **v12（当前基线）**：面板同窗口承载修复 + 设置页入口 + 净化中心 52 锚点 |
| `a1d2414` | v11：修悬浮球触摸（`win.ball` 未赋值）+ 宿主设置入口初版 |
| `5a6848c` | v10：按原版 19 张截图还原界面（9 模块 / 27 分区 / 105 开关）+ Hook/UI 解耦 |
| `3280e81` | v9：复刻原版交互层（悬浮球 + 分类菜单 + 开关持久化） |
| `0afe5f6` | v8 |
| `5b93456` | v7 |
| `4687f35` | v6 |
| `d838fe4` | v5（确立 v5 铁律：只用 `class_copyMethodList` 系 API） |

### 1.3 CI（GitHub Actions）

| 文件 | 运行器 | 作用 |
|---|---|---|
| `.github/workflows/build.yml` | `macos-14` | **主构建**：brew 装 `ldid/xz`，拉 Theos + iPhoneOS SDK，`make FINALPACKAGE=1`，跑三道门禁，上传 dylib + build.log |
| `.github/workflows/build-linux.yml` | linux | 辅助/历史用途，不是产物来源 |

三道门禁（任何一条挂掉即失败，**不可绕过**）：

1. `Gate - arch + no substrate + no rootful path`：产物必须同时含 `arm64`/`arm64e`，且不得出现 substrate/Cydia 路径。
2. `Gate - no Logos / substrate symbols`：不得出现 `%hook` 生成物与 substrate 符号表依赖。
3. `Stage dist (dylib + plist + notes)`：产物与 plist、安装说明打包。

### 1.4 最新产物（可直接真机安装）

| 项 | 路径 / 值 |
|---|---|
| fat dylib（真机用这个） | `D:\DeepSeek\hush\dist\v12\BluedHushREA.dylib` |
| 大小 | 475,056 B |
| 架构 | `arm64` + `arm64e`（各 225,816 B 单架构切片） |
| plist | `D:\DeepSeek\hush\dist\v12\BluedHushREA.plist` |
| 安装说明 | `D:\DeepSeek\hush\dist\v12\INSTALL.txt` |
| CI 运行页 | https://github.com/TuTu10750/tweak-repro-bluedhush/actions/runs/41003782787 |
| 构建日志 | `D:\DeepSeek\hush\_work\artifacts-v12\build-log\build.log` |

> 构建日志里唯一的告警是 `ld: warning: -multiply_defined is obsolete`（Theos 时代遗留），**不影响产物**。

### 1.5 Makefile 关键配置（改之前先看这里）

```
TARGET            := iphone:clang:latest:14.0
ARCHS             := arm64 arm64e
BluedHushREA_FILES := Tweak.xm REAUI.xm          # 只有这两个源文件
FRAMEWORKS        := Foundation UIKit CoreLocation
BluedHushREA_CFLAGS := -fobjc-arc -Wno-objc-method-access -Wno-unused-parameter -Wno-deprecated-declarations
```

### 1.6 构建 / 取产物命令

```powershell
# 触发构建（推 master 即自动跑）
cd D:\DeepSeek\hush\tweak-repro
git add -A; git commit -m "v13: ..."; git push origin master

# 看运行状态
gh run list --limit 3
gh run view <run-id> --json status,conclusion

# 拉产物
gh run download <run-id> -D D:\DeepSeek\hush\_work\artifacts-v13

# 本地无法编译 ObjC（Windows），一切以 CI 为准；不许"我觉得能编过"就交付
```

---

## 2. 工程结构与核心机制

### 2.1 文件地图（只有两个源文件）

| 文件 | 行数（v12） | 职责 |
|---|---|---|
| `Tweak.xm` | ~1,720 | **Hook 引擎**：`REASwap` 注册表、36 条核心 Hook、设置页入口（4 条 hook）、净化引擎（52 锚点 + 视图兜底 + host 拦截） |
| `REAUI.xm` | ~1,490 | **UI 层**：9 模块菜单树、开关单元格、二级页、悬浮球、覆盖窗口 `REAWindow`、面板承载、Alert 桥 |

### 2.2 Hook 引擎（`Tweak.xm`）

| 符号 | 行号 | 语义 |
|---|---|---|
| `REALog(NSString *fmt, ...)` | 195 | 统一日志（前缀 `[REA-Test]`），真机日志可见 |
| `gREAOrig` / `gREALock` | 229 / 231 | 原 IMP 注册表（`NSMutableDictionary` + 锁） |
| `REAKey(Class, const char*)` | 250 | 注册表键；metaclass 加 `M:` 前缀 |
| `REAOwnedMethod(Class, SEL)` | 258 | **只在本类自有方法表里找**（`class_copyMethodList`） |
| `REASwap(Class, const char*, IMP)` | 301 | 换实现；查不到自有方法就 `gREAMiss++` 并返回 `NULL`（**绝不回落父类**） |
| `REAHOOK` / `REAHOOKM` | 334 / 343 | 安装宏（实例 / 类方法） |
| `REAFlag(NSString *key)` | 399 | 读开关：`objectForKey == nil` → **返回 YES**（默认全开） |
| `REAOwnerClass(Class, SEL)` | 1031 | 沿 `class_getSuperclass` 用 `class_copyMethodList` 找**真正持有实现**的类；不触发 `+initialize` |
| `REAInstallHooks()` | 891 | 安装总表；末尾 `REASweepAntiTamper()` → `REAInstallSettingsEntry()` → `REAInstallPurify()` |

### 2.3 v5 铁律（**违反必炸，历史事故**）

**全文件禁止出现**（对宿主类）：

- `class_getInstanceMethod` / `class_getClassMethod` / `class_addMethod`
- `objc_msgSend` 到宿主类

原因：这些 API 会触发宿主 `+initialize`，历史上导致**首次启动闪退**，崩溃报告栈帧为：

```
#9  class_getInstanceMethod
#3  CALLING_SOME_+initialize_METHOD
```

**允许使用**：`class_copyMethodList`、`class_getSuperclass`、`method_getName`、`method_getImplementation`、`method_setImplementation`、`class_respondsToSelector`、`objc_getClass`、`sel_registerName`。

**推论（非常重要）**：`REASwap` 只改**本类自有实现**。如果选择子实际实现在父类，直接对子类 swap 会 `miss`。所以要么用 `REAOwnerClass` 求 owner 再 swap，要么接受 `miss` 并在日志里显式记录。

### 2.4 UI 层（`REAUI.xm`）

| 组件 | 行号 | 要点 |
|---|---|---|
| `REAItem` / `REASection` / `REAModule` | 60 / 95 / 105 | 菜单数据模型；`REAModule -enabledCount/-totalCount` 驱动「已开 x/y」 |
| `REABuildMenu()` | 153 | 9 模块 / 27 分区 / 107 项（105 唯一 key）的静态菜单树 |
| `REAUIMasterGroupKeys()` | 51 声明 / 557 实现 | 总开关 → 子项 key 列表（从菜单数据现算，不写死） |
| `REASymbol` / `REAKeyWindow` / `REATopViewController` / `REAToast` | 542 / 555 / 571 / 586 | 工具函数 |
| `REASwitchCell` | 608 | `UISwitch` + `onToggle` block；`selectionStyle = None` |
| `READetailController` | 867 | 二级开关页（`insetGrouped`）；`Done` → `REAOverlayPanelClose()` |
| `REAModuleListController` | 980 | 一级分类页；`Close` → `REAOverlayPanelClose()`；`全部关闭` |
| `REAFloatBall` | 1075 | 悬浮球；`Tap` → 开面板，`Pan` → 贴边吸附（存 `kREABallCenterKey`），`LongPress` → 通知 |
| `REAWindow` | 1189 | 覆盖窗口（`UIWindowLevelAlert + 1`），`hitTest:` 见 2.5 |
| `REAUI` | 1227 | 单例；`start` 建窗、`openPanel`/`closePanel` 承载面板 |
| `REAOpenPanel()` / `REAOverlayPanelClose()` / `REAPresentFromBest()` | 1438 / 1450 / 1461 | 跨文件桥 |

### 2.5 覆盖窗口与面板承载（**Bug 1 的修复原理，别改回去**）

```
REAWindow.hitTest:withEvent:
    if (self.panelVisible) return [super hitTest:point withEvent:event];   // 面板打开 → 全量响应
    hit = [super hitTest:...];
    if (hit == nil) return nil;
    if (self.ball != nil && (hit == self.ball || [hit isDescendantOfView:self.ball])) return hit;
    return nil;                                                            // 平时 → 只认球，其余穿透
```

面板**不是** `presentViewController:` 出来的，而是：

```
[root addChildViewController:nav];
[root.view addSubview:panelMask];      // 黑 0.36 + 点击关闭手势
[root.view addSubview:nav.view];       // 圆角 16，panelTop = max(safeAreaTop+8, h*6%)
[nav didMoveToParentViewController:root];
[root.view bringSubviewToFront:self.ball];
win.panelVisible = YES;
```

**为什么必须这样**：`presentViewController:` 会把面板挂到**宿主普通窗口**（level 0），而覆盖窗口在 `UIWindowLevelAlert + 1` 且 `hitTest` 对非球区域返回 `nil` → 面板看得见、摸不着（这就是 v11 那张"面板死了"的截图）。

### 2.6 设置页入口（**Bug 2 的实现，也是当前 P0 崩点**）

注入位置：宿主「我的 → 设置」页 `BDSettingViewController`，插在**第 0 组末尾**（`row == 宿主该组原行数`），宿主既有行下标全部不动。

| 选择子 | 包装函数 | 行为 |
|---|---|---|
| `tableView:numberOfRowsInSection:` | `rea_settingsRows` | section 0 返回 `orig + 1` |
| `tableView:cellForRowAtIndexPath:` | `rea_settingsCell` | 自建行返回 `@"插件设置"` cell（`rea-settings-entry`，蓝色 `bolt.horizontal.circle.fill`）；并把非自建行交给 `PShouldTrimSettingCell()` 做「设置页精简」 |
| `tableView:heightForRowAtIndexPath:` | `rea_settingsHeight` | 自建行 56.0；`PIsTrimmedRow(ip)` 为真返回 0 |
| `tableView:didSelectRowAtIndexPath:` | `rea_settingsSelect` | 自建行 → `deselect` + 日志 + `REAOpenPanel()` |

**关键护栏** `REAIsOurEntryRow(self, tv, ip)`：

```
gREASettingsEntryOn && p_settingRows != NULL && REAIsSettingVC(self)
  && ip.section == kREASettingsEntrySection(kREASettingsEntrySection = 0)
  && ip.row == REASettingBaseRows(self, tv)
```

作用：**rows hook 装不上时，宿主根本没多出那一行，绝不抢走宿主第 0 行。**

备用通道：`BDPrivacySettingViewController` 的导航栏右上角「助手」按钮（幂等，由 `REAAddSettingsNavButton` 保证）。

### 2.7 净化引擎（数据表 + trampoline，**不要改成逐条手写**）

| 层 | 作用 |
|---|---|
| `PInstall kPInstall[]` | 52 行安装表：`{类名, 选择子, trampoline kind, 开关 key}` |
| `gPRowClass[] / gPRowOld[]` | **行表**：安装时记录"真正被改写的类"与该类原 IMP |
| `PRowFor(self, sel)` | 由 `object_getClass(self)` **由内向外**沿 `class_getSuperclass` 匹配 `(类, 选择子)` → 返回行号；带单条 memo（热路径 2 次指针比较） |
| `PKeyFor(self, sel)` | 行号 → key |
| `POld(self, sel)` | 行号 → 原 IMP（**不查 `gREAOrig`**，见下方"踩过的坑"） |
| trampoline 家族 | `PK_V0/VB/VQ/VD/V1O/V2O/V3O/V3OB/VSPLASH_A/VSPLASH_B/B0/B1O/B2O/O0/O1O/O2O/D0/I0/Q0/ARR1O/DTASK1/DTASK2/SETURL` |
| `kPViewRules[]` | 47 条 `{key, 类名子串}`，由 `UIView -didMoveToSuperview` 统一兜底隐藏 |
| `kPHostRules[]` | `{ "purify_block_voice", "voice.blued.cn" }`，由 `NSURLSession dataTaskWithRequest:*` / `NSMutableURLRequest -setURL:` 切断 |
| `PShouldTrimSettingCell` / `PIsTrimmedRow` | `purify_set_items`：设置页按标题收起行（认证/实名/直播/扫一扫/青少年/账号安全/隐私设置/帮助与反馈/关于/清除缓存） |

**签名分型**：全部来自宿主真实 `typeEncoding`（`_work/analysis/host_index.json`），流程是 `re.sub(r'\d','',enc)` → 按第一个 `:` 切 return/args → `@?` 合成一个 token → 映射到 kind；遇到 `{`/`^`/`"` 一律判 unsupported 并排除该锚点。**绝不允许"猜签名"。**

### 2.8 开关数据流

```
面板 UISwitch → REAUISetFlag(key, on)
                 ├─ setBool:forKey:（NSUserDefaults）
                 └─ key == "purify_master" → REAUIMasterGroupKeys() 批量写 26 个子 key
Hook 运行时 → REAFlag(key)（每次现读，点一下立即生效；nil → YES）
```

---

## 3. 当前进度

### 3.1 已完成（可交付）

| 项 | 状态 | 证据 |
|---|---|---|
| 悬浮球出现 / 可拖动 / 可点击出菜单 | ✅ | 用户真机确认（v11→v12） |
| 9 分类菜单页渲染 | ✅ | 用户截图（m00001） |
| 菜单页可交互 | ✅ 代码已修（同窗口承载），**待真机复验** | `REAUI.xm:1189-1260` |
| 核心 36 条 Hook 对齐 | ✅ | 日志 `pass[ctor] ok=36 miss=0` |
| 13 个核心开关接入生效 | ✅ | `REAFlag(@"…")` 实际消费点 |
| 净化中心 26 个开关接真实锚点 | ✅ 代码已进 `1ff9319`，构建通过 | `kPInstall` 52 行 / `kPViewRules` 47 条 |
| 设置页「插件设置」Cell | ✅ 代码已进，**真机卡死/闪退 → 见 3.3** | `Tweak.xm:1711` |
| 开屏去广告 | ✅ 代码已进，**真机卡启动图 → 见 3.2** | `kPInstall` 前 19 行 |

### 3.2 【P0】Bug A：开屏去广告 → 卡启动图

**现象**：开启「开屏广告与启动图」（`purify_splash_ad`）后，冷启动停在启动图/白屏，进不了首页；关掉该项则正常。

**涉及锚点（19 条，全在 `purify_splash_ad`）**

```
AppDelegateModel                    isNeedShowSplashAd                                     PK_B0
AppDelegateModel                    showSplashAd:                                          PK_VB
AppDelegateModel                    getSplashAdForColdLaunch                               PK_V0
AppDelegateModel                    p_getSplashAdvertisementForColdLaunch                   PK_V0
BDGDTSplashAdManager                showGDTSplash                                          PK_V0
BDKSSplashAdManager                 showKSSplash                                           PK_V0
BDADX_Blued_Splash_Image_ViewController  presentBluedSplashImageViewController              PK_V0
BDIndexPageCoversManager            showSplashAd:currentWinAdModel:isColdLaunch:finished:   PK_VSPLASH_A
BDIndexPageCoversManager            showSplashAd_Adx:currentWinAdModel:isColdLaunch:finished: PK_VSPLASH_A
BDIndexPageCoversManager            showSplashAd_Normal:isColdLaunch:finished:              PK_VSPLASH_B
BDIndexPageCoversManager            p_showGDTSplash:isColdLaunch:finished:                  PK_VSPLASH_B
BDIndexPageCoversManager            p_showKSSplash:isColdLaunch:finished:                   PK_VSPLASH_B
BDIndexPageCoversManager            p_showPangleSplash:isColdLaunch:finished:               PK_VSPLASH_B
BDIndexPageCoversManager            p_showBluedImageSplash:currentWinAdModel:isColdLaunch:finished: PK_VSPLASH_A
BDIndexPageCoversManager            p_showBluedVideoSplash:currentWinAdModel:isColdLaunch:finished: PK_VSPLASH_A
BDADXBaseSplashAdManager            assembleSplashContainerView:needRemoveHandler:          PK_O2O
ABUSplashAd                         showInWindow:                                          PK_B1O
ABUSplashAd                         showInWindowWithBlock:                                 PK_B1O
BDSplashVideoAdViewController       presentInViewController:                               PK_V1O
```

**四个根因假设（按概率排序）**

| # | 假设 | 机制 | 判定方法 |
|---|---|---|---|
| H1 | `finished` 同步调用太早 | `PK_VSPLASH_A/B` 在**宿主还没 return**时就调 `finished(YES)`，宿主后续用它推进状态机的代码被跳过 → 容器视图永远盖在根视图上 | 打点：在 `finished` 前后各打一行日志 + `dispatch_after(3s)` 检查 keyWindow 的 top view 类名 |
| H2 | `assembleSplashContainerView:needRemoveHandler:` 返回 nil | 上层持 nil 容器但仍在等 `needRemoveHandler` 回调来移除 → 永不移除 | 改为 `return orig(...)` 只记录不拦截，观察是否恢复 |
| H3 | 视图级兜底命中启动占位 | `kPViewRules` 里 `purify_splash_ad` 的 `SplashImage/SplashVideo/SplashContainer/ADXSplash` 把**加载占位视图**一起 `hidden=YES; frame.height=0.5` | 临时清空 `purify_splash_ad` 的 5 条 view rule 复测 |
| H4 | `isNeedShowSplashAd` 返回 NO 但上游仍等回调 | 某些分支用「广告是否展示完成」作为进首页的闸门 | 只关 `isNeedShowSplashAd` 一条复测 |

**建议修法（三档 + 看门狗，别再"一刀切返回"）**

1. **拆分语义**：把 `purify_splash_ad` 拆成「跳过广告素材」与「跳过状态机」两档，默认只做前者。
2. **不要自己调 `finished`**：改为 **拦截展示层**（`presentInViewController:` / `showInWindow:` 返回、`assembleSplashContainerView:` 返回空视图），让宿主自己走完 `finished` 流程。
3. **看门狗兜底**：拦截后起 `dispatch_after`，若 `T+3.0s` 仍检测到 splash 容器在 keyWindow 顶层，则**主动调用原方法**（fail-open）。核心原则：**宁可看到广告，也不能卡死启动。**
4. **视图兜底收窄**：`purify_splash_ad` 的 5 条 `Splash*` 规则改成"仅在 `window != nil && 已过 T+2s` 后生效"，或干脆从 view rules 移除，只保留 `ADXSplash`。

### 3.3 【P0】Bug B：设置页注入 → 卡死 / 闪退

**现象**：进「我的 → 设置」页时卡死或直接闪退（用户真机报告）。

**涉及代码**

```
Tweak.xm:1711  REAInstallSettingsEntry()
Tweak.xm       rea_settingsRows / rea_settingsCell / rea_settingsHeight / rea_settingsSelect
Tweak.xm       REAIsOurEntryRow / REASettingBaseRows / REASettingsEntryCell
Tweak.xm:1031  REAOwnerClass()
Tweak.xm       rea_settingsCell 内  @try { PShouldTrimSettingCell(cell, ip); }
```

**五个根因假设**

| # | 假设 | 机制 | 判定方法 |
|---|---|---|---|
| H1 | **二次 swizzle → 无限递归** | 若 `REAInstallSettingsEntry()` 被执行两次（重试/重复 ctor），`p_settingRows` 会被写成**我们自己的 wrapper** → wrapper 调 `p_settingRows` 即自调用 → 栈溢出闪退 | 日志里 `rowsOwner=...` 是否出现两次；给 `gREASettingsEntryOn` 加 `static BOOL installed` 幂等哨兵 |
| H2 | **owner 解析到父类** | `REAOwnerClass(BDSettingViewController, "tableView:numberOfRowsInSection:")` 可能返回 `BDBaseTableViewController` 之类 → hook 装到父类 → **所有子类表格页**（含首页、会话列表）全部走我们的 rows/cell/height，行数对不上 → UIKit 抛异常/死循环 | 日志打印 `rowsOwner` 类名；若 `!= "BDSettingViewController"` 立即放弃该 hook，退化为导航栏按钮方案 |
| H3 | **height 里做重活** | `PIsTrimmedRow(ip)` 在 height 回调里被每行调用，若内部建 cell/取 label/访问 defaults，滚动时高频触发 → 主线程卡死 | 把判定结果**缓存进 `NSMutableSet<NSString*> trimmedIndexPaths`**，在 cell 阶段或 `viewDidLoad` 之后一次性算好 |
| H4 | **行数与高度不一致** | rows 加了 1 行、height 对某些行返回 0、`purify_set_items` 又隐藏了行 → `reloadData` 抖动时 UIKit 报 `attempt to insert/delete row` | 先关 `purify_set_items` 联动复测（即 `PShouldTrimSettingCell` 直接 return） |
| H5 | **空指针调用** | `REAIsOurEntryRow` 里调 `REASettingBaseRows` → `p_settingRows` 为 NULL 时直接崩 | 现有 guard 是 `p_settingRows != NULL`；确认 `&&` 短路顺序正确（**先判 NULL 再调用**） |

**建议修法（按顺序做，每步都能单独回滚）**

1. **加 kill switch**：新增 `rea_settings_entry_enabled`（默认 `YES`），`REAInstallSettingsEntry()` 开头 `if (!REAFlag(@"rea_settings_entry_enabled")) return;`，出问题让用户在面板里一键关闭。
2. **幂等哨兵**：`static BOOL gREAEntryInstalled = NO; if (gREAEntryInstalled) return; gREAEntryInstalled = YES;`（防 H1）。
3. **owner 校验**：解析出 owner 后 `if (owner != objc_getClass("BDSettingViewController")) { REALog(@"[SettingsEntry] owner=%s 不是设置页本体，改用导航栏按钮"); goto fallback; }`（防 H2）。
4. **全包 `@try/@catch`**：四个 wrapper 各自 `@try { … } @catch (NSException *e) { REALog(...); }`，异常时 **fail-open 调原实现**。
5. **先只加行、不删行**：把 `PShouldTrimSettingCell` 调用临时注释掉（保留函数），确认入口不崩后再单独开 `purify_set_items`（防 H4）。
6. **延迟安装**：`REAInstallSettingsEntry()` 从 `REAInstallHooks()` 直接调用，改为 `dispatch_after(2s, main)` 后再装，避开启动期 UI 竞争。

> 结论口径：**入口是"加分项"，不是"必须项"。如果 4 条 hook 有任何一条在真机上装不稳，一律退回导航栏按钮方案**（`BDPrivacySettingViewController` 右上角「助手」），并把这个决定写进日志。

### 3.4 其他技术债（不阻塞，但要记着）

- `REAUI.xm` 里 `reaActionSetLocation` / `reaActionShowLog` / `reaActionDeviceCheck` / `showQuickMenu` 四处保留了 `UIViewController *host = REATopViewController(); if (host == nil) return;` 仅作前置判空，变量已不再用于 present → 会产生 `unused variable` 类告警（当前 `CFLAGS` 已屏蔽）。
- `purify_master` 没有自己的运行时 hook（语义就是"批量写子 key"），静态扫描会把它算成"未接线"，**属预期**，别当成 bug。
- `kPViewRules` 47 条按**类名子串**匹配，存在误伤风险（例如 `Banner` 会命中 `BannerCell` 之外的类）；若用户反馈"某正常视图消失"，优先怀疑这里。

---

## 4. 待办事项

### 4.1 净化组（26 个开关）：锚点清单

**开关清单（26 个，`purify_master` 为批量写入口，不含运行时 hook）**

```
purify_master      purify_splash_ad   purify_feed_ad      purify_nearby_ad    purify_visitor_ad
purify_banner      purify_float_layer purify_map_guide    purify_mine_ad      purify_svg_ad
purify_safe_tip    purify_new_nav_tag purify_blur_label   purify_call_header  purify_session_card
purify_sensitive   purify_welcome_pop purify_follow_card  purify_chat_emoji   purify_match_emoji_bar
purify_sensitive_alert  purify_passby_tip  purify_live_entry  purify_mine_vip  purify_set_items
purify_block_voice  purify_block_call
```

**A. 52 条选择子锚点（`kPInstall`，已全部装上）**

| 类 | 选择子 | trampoline | 归属 key |
|---|---|---|---|
| `AppDelegateModel` | `isNeedShowSplashAd` | `PK_B0` | purify_splash_ad |
| `AppDelegateModel` | `showSplashAd:` | `PK_VB` | purify_splash_ad |
| `AppDelegateModel` | `getSplashAdForColdLaunch` | `PK_V0` | purify_splash_ad |
| `AppDelegateModel` | `p_getSplashAdvertisementForColdLaunch` | `PK_V0` | purify_splash_ad |
| `BDGDTSplashAdManager` | `showGDTSplash` | `PK_V0` | purify_splash_ad |
| `BDKSSplashAdManager` | `showKSSplash` | `PK_V0` | purify_splash_ad |
| `BDADX_Blued_Splash_Image_ViewController` | `presentBluedSplashImageViewController` | `PK_V0` | purify_splash_ad |
| `BDIndexPageCoversManager` | `showSplashAd:currentWinAdModel:isColdLaunch:finished:` | `PK_VSPLASH_A` | purify_splash_ad |
| `BDIndexPageCoversManager` | `showSplashAd_Adx:currentWinAdModel:isColdLaunch:finished:` | `PK_VSPLASH_A` | purify_splash_ad |
| `BDIndexPageCoversManager` | `showSplashAd_Normal:isColdLaunch:finished:` | `PK_VSPLASH_B` | purify_splash_ad |
| `BDIndexPageCoversManager` | `p_showGDTSplash:isColdLaunch:finished:` | `PK_VSPLASH_B` | purify_splash_ad |
| `BDIndexPageCoversManager` | `p_showKSSplash:isColdLaunch:finished:` | `PK_VSPLASH_B` | purify_splash_ad |
| `BDIndexPageCoversManager` | `p_showPangleSplash:isColdLaunch:finished:` | `PK_VSPLASH_B` | purify_splash_ad |
| `BDIndexPageCoversManager` | `p_showBluedImageSplash:currentWinAdModel:isColdLaunch:finished:` | `PK_VSPLASH_A` | purify_splash_ad |
| `BDIndexPageCoversManager` | `p_showBluedVideoSplash:currentWinAdModel:isColdLaunch:finished:` | `PK_VSPLASH_A` | purify_splash_ad |
| `BDADXBaseSplashAdManager` | `assembleSplashContainerView:needRemoveHandler:` | `PK_O2O` | purify_splash_ad |
| `ABUSplashAd` | `showInWindow:` | `PK_B1O` | purify_splash_ad |
| `ABUSplashAd` | `showInWindowWithBlock:` | `PK_B1O` | purify_splash_ad |
| `BDSplashVideoAdViewController` | `presentInViewController:` | `PK_V1O` | purify_splash_ad |
| `ABUDrawAdView` | `loadAdData` | `PK_V0` | purify_feed_ad |
| `ABUNativeAdView` | `loadAdData` | `PK_V0` | purify_feed_ad |
| `ABUNativeAdView` | `play` | `PK_V0` | purify_feed_ad |
| `BDKSTemplateExpressFeedAdBaseTableViewCell` | `startLoadWithAdModel:originModel:containVC:isNeedRefresh:` | `PK_V3OB` | purify_feed_ad |
| `BDKSSelfExpressNativeAdBaseTableViewCell` | `startLoadWithAdModel:originModel:containVC:isNeedRefresh:` | `PK_V3OB` | purify_feed_ad |
| `BDNearbyDataAdapter` | `setAdmsArray:` | `PK_ARR1O` | purify_nearby_ad |
| `BDNearbyDataAdapter` | `setOriginUserAdsArray:` | `PK_ARR1O` | purify_nearby_ad |
| `BDNearbyBannerCell` | `configerBanner:` | `PK_V1O` | purify_nearby_ad |
| `BDGlobalBannerView` | `showNsnofyView` | `PK_V0` | purify_banner |
| `BDGlobalBannerMatchView` | `setBannerModel:messageModel:` | `PK_V2O` | purify_banner |
| `ABUBannerAd` | `loadAdData` | `PK_V0` | purify_banner |
| `BDIndexPageCoversManager` | `p_showFloatingLayerAds:image:finished:` | `PK_V3O` | purify_float_layer |
| `BDIndexPageCoversManager` | `showFloatingLayerAfterNearbyPageShown` | `PK_B0` | purify_float_layer |
| `BDNearbyFloatingLayerModel` | `images` | `PK_O0` | purify_float_layer |
| `BDMineBannerCell` | `configerBanner:` | `PK_V1O` | purify_mine_ad |
| `BDChatSafeTipCell` | `setupData` | `PK_V0` | purify_safe_tip |
| `BDMessageSafetyTipView` | `getSafetyTipViewHeight` | `PK_D0` | purify_safe_tip |
| `BDBlurredLabel` | `setBlurRadius:` | `PK_VD` | purify_blur_label |
| `BDMapBlurBaseView` | `applyBlurRadius:` | `PK_VD` | purify_blur_label |
| `BDPrivacyAlbumCell` | `showMaskViewOrNot:` | `PK_VB` | purify_sensitive |
| `BDMessageViewController` | `showChatRiskTip` | `PK_V0` | purify_sensitive_alert |
| `BDSessionViewController` | `p_ifShowRiskAlert` | `PK_V0` | purify_sensitive_alert |
| `PrivateChatViewController` | `showRiskUserTips:` | `PK_V1O` | purify_sensitive_alert |
| `PrivateChatViewController` | `riskTipsRequest` | `PK_V0` | purify_sensitive_alert |
| `BDCallWorkFlowManager` | `callStateRequest` | `PK_O0` | purify_block_call |
| `BDCallWorkFlowManager` | `callOpenRequest` | `PK_O0` | purify_block_call |
| `BDCallWorkFlowManager` | `callRequesting` | `PK_B0` | purify_block_call |
| `BDVisitorTopView` | `isShowCall` | `PK_B0` | purify_block_call |
| `BDNearbyCallListView` | `showCallAlert` | `PK_V0` | purify_block_call |
| `BDTavernChatingViewController` | `joinVoiceRoom` | `PK_V0` | purify_block_voice |
| `BDTavernChatingViewController` | `p_showVoiceMatchPopoverView` | `PK_V0` | purify_block_voice |
| `BDTavernChatingViewController` | `p_startVoiceForwardIfNeeded` | `PK_V0` | purify_block_voice |
| `UserVisitorData` | `is_ads` | `PK_I0` | purify_visitor_ad |

**B. 47 条视图级兜底规则（`kPViewRules`，命中即 `hidden=YES; alpha=0; height=0.5`）**

| key | 类名子串 |
|---|---|
| `purify_splash_ad` | `SplashAd` / `SplashImage` / `SplashVideo` / `SplashContainer` / `ADXSplash` |
| `purify_banner` | `Banner` / `Nsnofy` |
| `purify_svg_ad` | `SVGA` / `SvgFloat` |
| `purify_float_layer` | `FloatingLayer` / `FloatLayer` / `FloatAd` |
| `purify_mine_vip` | `MineVipOperate` / `MineVipCard` |
| `purify_live_entry` | `LiveServiceCollection` / `LiveEntryView` / `LiveEntryCell` |
| `purify_map_guide` | `MapGuide` / `GuideCard` / `GuideView` |
| `purify_welcome_pop` | `WelcomeReward` / `WelcomePop` / `RewardPopView` |
| `purify_follow_card` | `FollowCard` / `FollowGuide` / `FollowTipView` |
| `purify_call_header` | `CallHeader` / `CallEntry` / `VoiceCallEntry` |
| `purify_session_card` | `SessionCard` / `SessionTopCard` / `SessionHeaderCard` |
| `purify_new_nav_tag` | `NewTag` / `RedDot` / `RedPoint` / `HotTag` / `PromoteTag` |
| `purify_passby_tip` | `Passby` / `PassBy` / `MetByChance` |
| `purify_chat_emoji` | `BigEmoji` / `EmojiAnimation` |
| `purify_match_emoji_bar` | `MatchEmoji` / `EmojiBar` / `ExpressionBar` |
| `purify_sensitive` | `PrivacyAlbumMask` / `SensitiveMask` |

**C. 1 条网络级 host 规则（`kPHostRules`）**

| key | host 后缀 | 拦截点 |
|---|---|---|
| `purify_block_voice` | `voice.blued.cn` | `NSURLSession -dataTaskWithRequest:completionHandler:` / `-dataTaskWithRequest:` / `NSMutableURLRequest -setURL:` → 命中换 `http://127.0.0.1:9/blocked-by-hush` |

**D. 仍未接线的净化系开关（6 个，属本组遗留）**

| key | 语义 | 下一步 |
|---|---|---|
| `switch_hide_calling_ui` | 去掉通话呼出状态浮层 | 需挖 `BDCall*` 浮层类（`BDCallChatUsersController` / `BDCallExposurePop` 一带） |
| `switch_hide_purple_card` | 去掉顶部紫色推荐卡 | 待挖类名（按 view rules 试 `PurpleCard`/`RecommendCard`） |
| `switch_hide_live_entry` | 去掉页面内直播推荐 | `purify_live_entry` 的 view rules 已覆盖一部分，需补数据源级 |
| `switch_purify_mine_page` | 「我的」页整体净化 | 需 `BDMineViewController` 的 `collectionView:numberOfItemsInSection:` 级裁剪 |
| `switch_block_live_request` | 阻止直播拉流/下播请求 | 需 host 级规则（`live.blued.cn` 等）+ 拉流 SDK 入口 |
| `switch_no_data_collect` | 拦截埋点上报 | 需 host 级规则（`bddata`/`track`/`statistics` 域名族）+ `BDDataCollectManager` 入口 |

### 4.2 聊天增强（8 组 / 覆盖 15 个开关，其中 11 个待接）

| # | 组 | 开关 key（状态） | 已证实锚点（原版逆向 + 宿主编码） | 实现要点 / 风险 |
|---|---|---|---|---|
| 1 | 消息处理·防撤回/补拉 | `switch_anti_recall` ✅ / `switch_msg_heal` ❌ | anti_recall：`GJIMMessageModel -recallType`（原版 0x46F94，开关开→返 0）、`-isSuperRecallTip`（0x47084→NO）<br>msg_heal 候选：`BDSessionViewController -syncMessageFetching`(v16) `-syncMessageFetched`(v16)、`BDMessageViewController -p_checkSyncLastMessageIfNeed`(v16) | 补拉是**自造功能**（原版无 key 门控）：需在 `syncMessageFetched` 超时未回调时触发重连；**必须加节流**，否则会打爆 IM 长连接 |
| 2 | 去除截屏限制 | `switch_screenshot` ✅ | 原版三连：`p_screenshotTip`(0x4B2E0→0)、`p_screenshotWarning`(0x4B1FC→nil)、`checkSendScreenshotTip`(0x4B3C4→nil) | 已接，注意 iOS 26 起 `UIScreen.isCaptured` 需一并改 |
| 3 | 关闭对话爱心 | `switch_chat_heart_off` ❌ | `BDPrivateChatSetingController -judgeToShowHeartNewView`(B16→NO)、`-toSetHeartNewRead`(v16→skip)、`BDMessageViewController -p_updateHeartStatus:`(v24→skip)、`-isMatchBothHeart`(B16→NO) | 只在 7.50.0+ 存在；低版本类不在则 miss（正常）。**别拦 `-(void)setHeartView:`**，会连带把设置页开关搞失效 |
| 4 | 闪照/闪文转普通 | `switch_flash_photo` ✅ / `switch_flash_text` ✅ | 原版 `GJIMMessageModel` 相关（`FlashPhoto` 18 条 hook、`FlashText` 3 条） | 已接；注意闪照私密性，转换后要跟 `switch_private_photo` 的权限判定顺序对齐 |
| 5 | 闪照免广告 | `switch_flash_ad_skip` ❌ | `initBluexTipView`(v16) / `bluedxTipDoneAction`(v16) / `destoryChatAddTimeAction`(v16)（原版 orig 槽 `0x257480/0x257488/0x257490`） | 这三条是"看完广告才给看闪照"的状态机；**只能拦展示，不能拦 `destory`**，否则闪照永远打不开 |
| 6 | 显示具体时间 | `switch_msg_timestamp` ❌ | `BDChatBasicCell -setupData`(v16)、`GJIMMessageModel -isShowTime`(B16→YES) | `isShowTime` 返 YES 只是"要求显示"，真正渲染要 `setupData` 里补 frame；建议只做 `isShowTime`，避免布局崩 |
| 7 | 已读与痕迹 | `switch_read_receipt` ❌ / `switch_secret_view_all` ❌ | read_receipt：`UserSetting -is_global_view_secretly`(B16) + `UserInformation` + `BDVIPPrivilegeConfigModel`<br>secret_view_all：再加 `UserSetting -is_traceless_access`(B16)、`UserSettingModel`、`BDVIPPrivilegeConfigModel -is_view_secretly`(B16) | 两条共用同一批锚点，**必须做 key 优先级**：`secret_view_all` 开时忽略 `read_receipt` 的单开；否则互相覆盖 |
| 8 | 发送增强（自造功能，原版无 key 门控） | `switch_quick_phrase` ❌ / `switch_auto_select_photo` ❌ / `switch_auto_select_burn` ❌ / `switch_scheduled_recall` ❌ / `switch_regret_auto` ❌ | 候选：<br>快捷短语 → `BDMessageViewController` 键盘/输入条一带（`inputBar`/`keyboard` 347 条待筛）<br>自动选照片 → 相册选择器（`album`/`PhotoPicker` 1750 条待筛，优先 `TZImagePicker`/`PHPicker` 包装类）<br>自动勾闪照 → 同上 + `GJIMMessageModel` flash 标记（`burn`/`flash` 1708 条待筛）<br>预约撤回 → `BDMessageViewController -recallAction:`(v24) `-p_canRecallMessageWith:`(B20@0:8I16) `-p_continueRevokeAction:`(v20@0:8B16)、`BDLongPressMenuView -recallAction`(v16)、`AppGlobalVariable -is_recall`(B16) | **这 5 个必须真写交互层**（不能只挂个开关）：<br>· 快捷短语：自绘横向 `UIStackView` 挂在输入条上方<br>· 自动选照片：在 picker `viewDidAppear` 后自动勾第一张<br>· 自动勾闪照：同上，切到「闪照」tab 再勾<br>· 预约撤回：`NSTimer` + 本地队列，重进 App 用 `NSUserDefaults` 续约<br>· 自动撤回：发送成功回调里起 `dispatch_after(对方已读+N秒)`<br>**风险**：预约撤回依赖 `recallAction:`，若被服务器拒绝要有兜底日志 |

### 4.3 其余模块（55 个待接开关，按模块分组）

| 模块 | 待接 key |
|---|---|
| 净化中心（6） | `switch_hide_calling_ui` `switch_hide_purple_card` `switch_hide_live_entry` `switch_purify_mine_page` `switch_block_live_request` `switch_no_data_collect` |
| 隐私与特权（19） | `switch_spoof_lite` `switch_nearby_signature` `switch_version_spoof` `switch_nearby_album` `switch_privacy_unlock` `switch_chat_watermark` `switch_chat_album_strip` `switch_album_count_badge_visible` `switch_album_grant` `switch_blacklist_unlock` `switch_fair_exchange` `switch_license_bypass` `switch_visitor_unlock` `switch_nearby_mark` `switch_deleted_mark` `switch_risk_user_block` `switch_past_entangle` `switch_card_intel` `switch_vanished` |
| 定位与追踪（5） | `switch_ip_location` `switch_real_location_mask` `switch_track` `switch_physical_track` `switch_map_avatar_clear` |
| 自动化与筛选（5） | `switch_auto_visit` `switch_skip_list` `switch_fanpai` `switch_online_distance_sort` `switch_spy_detect` |
| 视奸与访问（4） | `switch_stalk` `switch_avatar_long_press` `switch_visit_clear` `switch_viewed_strike` |
| 照片与相册（5） | `switch_chat_album` `switch_chat_gallery` `switch_chat_gallery_ball` `switch_legacy_auto_import` `switch_auto_pick_photo` |
| 入口与手势（3） | `float_ball` `switch_avatar_long_press_area` `switch_blacklist_jump` |
| 风控与设备（7） | `switch_device_fake` `switch_device_empty` `switch_block_device_upload` `switch_device_intercept` `switch_bypass_jailbreak` `switch_risk_login_bypass` `switch_bugly_off` |

> 统计口径：UI 105 个唯一 key + 1 个动作项；已接 39（13 核心 + 26 净化）+ 1 语义型（`purify_master`）；**待接 65**。
> 原版 dylib 里对 `DLDeviceFingerprint` 有 **27 处**指纹伪造、12 个反越狱/反调试方法（`BDMessageViewController`）——风控组可直接复用这些锚点，不要重新挖。

---

## 5. 环境约束（硬约束，不可协商）

| 约束 | 说明 |
|---|---|
| **非越狱** | 自签 + **LiveContainer** 环境加载，**没有** Cydia/Sileo 依赖 |
| **纯 Runtime** | 只用 `method_setImplementation` / `class_copyMethodList` 系 API，**禁止 Logos 宏**（`%hook` / `%ctor` / `%orig`）、**禁止 substrate/libhooker/libsubstitute 依赖** |
| **无 rootful 路径** | dylib 内不得出现 `/Library/MobileSubstrate`、`/usr/lib/libsubstrate` 等字符串（CI 门禁会拦） |
| 架构 | `arm64` + `arm64e`（fat binary，CI 合并） |
| 部署目标 | iOS 14.0+（`TARGET := iphone:clang:latest:14.0`） |
| 内存管理 | **ARC 开启**（`-fobjc-arc`）；block 与 `id` 之间转型必须显式（`(void (^)(BOOL))finished`） |
| 宿主版本 | Blued `7.50.3`（解密 IPA：`D:\DeepSeek\hush\Blued X-…_7.50.3_decrypted….ipa`） |
| 原版参照 | `BluedHush_5.19.dylib`（2.5 MB，arm64，无 Logos `%ctor`，28 个 `__init_offsets`，主安装器 `0x434C0`，`MSHookMessageEx` × 557） |
| 编译环境 | **Windows 本地无法编译 ObjC**；一切以 GitHub Actions（`macos-14` + Theos）为准 |

---

## 6. 工具链与既有脚本（`D:\DeepSeek\hush\_work`）

### 6.1 分析数据（**这些是资产，别删**）

| 文件 | 内容 |
|---|---|
| `analysis/host_index.json` | **14,839 个宿主类 → {选择子: typeEncoding}**（仅自有方法，不含继承）。所有锚点签名的唯一权威来源 |
| `analysis/hooks_full.json` | 原版 dylib 的 **554 条 Hook**（`cls / sel / imp / orig / guard / keys[]`） |
| `analysis/keys.json` | 原版 68 个配置键（`_HushKeyXxx` → `purify_master` 等） |
| `analysis/classes.json` / `classes.txt` | 原版类清单 |
| `analysis/menu_final.json` / `model_spec.txt` | 从原版常量流还原的菜单模型（36 KB） |
| `analysis/key_audit.json` | UI key 盘点结果（107 项 / 105 唯一） |
| `anchor_table.json` / `anchor_table.md` | 52 行锚点表（本文 4.1-A 的来源） |
| `chat_anchors.txt` | 聊天相关候选锚点 5,500+ 条（heart/heal/recall/phrase/picker/burn/keyboard/timestamp） |
| `heal_anchors.txt` | IM 同步类候选锚点 135 条 |

### 6.2 脚本（全部是 `.py`，直接 `python xxx.py` 跑）

| 脚本 | 用途 |
|---|---|
| `macho.py` | 原版 dylib 解析器（`read_vm / rd32 / rd64 / cstr / slot / deref / sym_of / disasm / load_classes / find_class`；全局 `segs / secs / CLASSES / IMPORTS`） |
| `hosta.py` | 宿主二进制解析器（`Bin.use / class_dump / classes / cstr / rd64 / ro_of / sel_at / method_list`） |
| `inject_probe.py` | `python inject_probe.py 0x11b8e8 150` → 反汇编并标注 `SEL/CLASS/CFSTR` |
| `refs.py` / `ustr.py` | 中文串定位（**必须在 `__TEXT,__ustring`（UTF-16LE）里找，`__cstring` 里没有中文**） |
| `owner_resolve.py` | `resolve(cls, sel)` → 真正持有实现的类名 + typeEncoding |
| `key_wire_audit.py` | UI key ↔ Tweak.xm 接线审计（当前输出 39 wired / 66 dead） |
| `gen_purify.py` → `purify_block.m` | 净化引擎生成器（改锚点后重新生成，再跑 `replace_purify.py`） |
| `replace_purify.py` | 把 `purify_block.m` 整块替换进 `Tweak.xm`（幂等：按 `#pragma mark - 净化引擎（v12）` 定位） |
| `merge_purify.py` | 首版合并脚本（**只用于首次拼接**，已用过；后续统一用 `replace_purify.py`） |
| `patch_settings_entry.py` | 写入设置页入口 v12 实现 |
| `patch_master.py` | 总开关批量写子 key |
| `synth_check.py` | 大括号/圆括号/方括号平衡检查（模拟编译前置校验） |
| `mine_chat.py` / `mine_heal.py` / `mine_anchors.py` / `ad_cand.py` / `ad_adapters.py` | 各类锚点挖掘（输出到 `chat_anchors.txt` / `heal_anchors.txt` / `m_splash.txt` / `ad_candidates.txt` / `ad_adapters.txt`） |
| `key_hooks2.py` | `python key_hooks2.py ReadReceipt SecretViewAll` → 原版某 key 挂了哪些 hook |

### 6.3 踩过的坑（**别重复踩**）

1. **PowerShell 里禁止 `python -c "…"`**：含 `r'…'` / `@"…"` 会被 PS 引号解析撕碎（报 `表达式或语句中包含意外的标记`）。**所有 Python 一律写成 .py 文件再执行。**
2. **`hosta.py class_dump(addr)` 的 `methods` 元素是 tuple**，判断必须 `isinstance(m, (list, tuple))`；写 `isinstance(m, list)` 会让所有类 methods 变 0 条。
3. **静态 super 链不可靠**：同一进程内反复 `class_dump` 会给出不一致的 `super`（一次 `0x108f3fcb0`、一次 `0`）。**不要在 Python 里预判继承链**，运行时用 `REAOwnerClass`。
4. **`POld` 不能用 `gREAOrig[REAKey(object_getClass(self), sel)]`**：`REASwap` 的键是"传入的类名 + 选择子"，而 trampoline 里的 `self` 可能是子类实例（hook `UIView -didMoveToSuperview` 会收到 `UILabel`）。必须用**行表** `gPRowClass/gPRowOld` + `PRowFor()` 由内向外匹配。
5. **同名选择子必须按类消歧**：`loadAdData` 同时挂 `ABUDrawAdView`/`ABUNativeAdView`，`configerBanner:` 同时挂 `BDNearbyBannerCell`/`BDMineBannerCell`；早期版本只按选择子名匹配 → key 拿错。
6. **中文串只在 `__ustring`**：`__cstring` 里 UTF-8 搜 "设置" = 0 命中，UTF-16 搜 = 16 命中。
7. **原版 `[SettingsEntry]` 日志串零引用**：CFString `0x225ed8` 在 `__text` 里 `adrp+add` / const 槽 / literal 三种扫法全 0 → **原版注入点不可静态定位**，别在这上面继续耗时间。
8. **`@catch (...)` 在纯 ObjC 下不可靠** → 统一写 `@catch (NSException *e)`。
9. **ARC 下 `id` → block 必须显式转型**：`void (^blk)(BOOL) = (void (^)(BOOL))finished;`。

---

## 7. 日志与真机验证

### 7.1 真机日志关键行

| 日志 | 含义 |
|---|---|
| `pass[ctor] ok=36 miss=0` | 核心 Hook 全装上 |
| `[Purify] 锚点安装：ok=N miss=M（共 52 条，含视图净化器）` | 净化引擎安装结果（**N 应接近 52**） |
| `[Purify] 拦截 <sel>（key=xxx）` | 命中拦截 |
| `[Purify] 视图净化：<类名> → key=xxx` | 视图兜底命中（**若命中正常视图，说明 `kPViewRules` 误伤**） |
| `[Purify] 切断请求 <host><path>（key=purify_block_voice）` | 网络级拦截命中 |
| `rowsOwner=… cellOwner=… selectOwner=… heightOwner=…` | 设置页入口四条 hook 的 owner（**出现 `BDBaseTableViewController` 类说明踩了 H2**） |
| `[SettingsEntry] 点击「插件设置」→ 打开面板` | 入口可点 |
| `[UI] 总开关 purify_master -> 1（连带 26 项）` | 总开关批量生效 |
| `[SettingsEntry] 点击「%@」（%@），打开插件面板` | **原版**文案，本版本不出现（仅供对照） |

日志位置（真机）：`D:\DeepSeek\hush\BluedHushREA.log`（GBK 编码，可读但会乱码，用 `Get-Content -Encoding Default` 或转码后看）。

### 7.2 真机验收清单（每次发版必跑）

1. 冷启动 → 进首页（**验证 Bug A 是否复现**）
2. 悬浮球可拖动、贴边吸附、单击出菜单
3. 菜单 → 任意分类 → 二级页可滚动、可拨开关、`Done` 可关、点遮罩可关
4. 我的 → 设置 → **第 0 组最后一行「插件设置」存在且可点**（**验证 Bug B**）
5. 拨「净化总开关」→ 26 个子开关跟随变化
6. 拨「开屏广告与启动图」→ 杀进程重启 → 能进首页
7. 日志里 `[Purify] 锚点安装 ok` 数量是否 ≥ 45
8. 崩溃时抓 `.ips`（重点看是否 `CALLING_SOME_+initialize_METHOD` 或栈溢出）

---

## 8. 红线

1. **禁止 `// 逻辑省略` / 假实现 / 只挂 UI 不接底层**。每个开关必须有真实锚点或真实交互层，并在日志里可观测。
2. **禁止用 `class_getInstanceMethod` / `class_addMethod` / `objc_msgSend` 打宿主类**（会触发 `+initialize` 闪退，见 2.3）。
3. **构建必须过 CI 三道门禁**；本地不编译，不许口头承诺"能编过"。
4. **交付必须给可安装产物路径 + CI 运行页**，否则视为未交付。
5. **任何"让 App 起不来/卡死"的改动，优先级高于任何新功能**；修不好就 fail-open（退回不拦截）。
6. 交接信息以本文为准；改动本文所述机制（2.5 / 2.6 / 2.7）必须同步更新本文。

---

## 9. 下一步路线（多 Agent 分工建议）

| 阶段 | 目标 | 负责角色 | 完成判据 |
|---|---|---|---|
| **S0（阻塞）** | 修 Bug A（卡启动图）+ Bug B（设置页卡死/闪退） | 1 个 Agent 串行做（两处都涉及启动期/主线程，**不要并行**改同一文件） | 真机冷启动进首页 + 设置页可进可点，连续 10 次不崩 |
| **S1** | 净化中心收尾：6 个遗留 key（4.1-D） | 1 Agent | 6 个 key 全部有真实锚点 + 日志可观测 |
| **S2** | 聊天增强 8 组（4.2，11 个 key） | 可 2 Agent 并行（一组做 hook 类 1-7，一组做交互类第 8 组），**产出必须分文件/分函数块，避免冲突** | 15 个 key 全部真实可用 |
| **S3** | 隐私与特权 19 个 | 2 Agent（资料透视 8 / 限制解放 11） | 同上 |
| **S4** | 风控与设备 7 个（直接复用原版 27 处指纹 + 12 个反越狱锚点） | 1 Agent | 同上 |
| **S5** | 定位/自动化/视奸/照片/手势 22 个 | 3 Agent 按模块切 | 同上 |

**并行安全规则**

- `Tweak.xm` 与 `REAUI.xm` 是**单文件大文件**，并行 Agent **不得同时编辑同一文件**；建议按"生成器 + 块替换"的方式（同 `gen_purify.py` / `replace_purify.py` 模式），每批生成独立块再串行合并。
- 每批合并后**立即 `synth_check.py` + push 跑 CI**，绿了再做下一批。
- 每批必须自带 kill switch（`REAFlag(@"rea_xxx_enabled")`），出问题能在面板里一键关掉。

---

## 附录 A：行号索引（v12 基线）

### `Tweak.xm`

| 行号 | 符号 |
|---|---|
| 195 | `REALog` |
| 229 / 231 | `gREAOrig` / `gREALock` |
| 238 | `REARegistryInit` |
| 250 | `REAKey` |
| 258 | `REAOwnedMethod` |
| 301 | `REASwap` |
| 334 / 343 | `REAHOOK` / `REAHOOKM` |
| 399 | `REAFlag` |
| 881 | `REAInstallSettingsEntry` 前向声明 |
| 884 | `REAInstallPurify` / `PShouldTrimSettingCell` / `PIsTrimmedRow` 前向声明 |
| 891 | `REAInstallHooks` |
| 982 | `extern void REAOpenPanel(void)` |
| 1031 | `REAOwnerClass` |
| 1040 | `REASettingBaseRows` |
| 1047 | `REASettingsEntryCell` |
| 1065 | `rea_settingsRows` |
| 1076 | `REAIsOurEntryRow` |
| 1085 | `rea_settingsCell` |
| 1094 | `rea_settingsHeight` |
| 1103 | `rea_settingsSelect` |
| 1116 | `REAAddSettingsNavButton` |
| 1138 | `rea_settingsWillAppear` |
| 1170 起 | 净化引擎块（`kPInstall` / `PRowFor` / trampoline / `kPViewRules` / host 拦截） |
| 1680 | `REAInstallPurify` 定义 |
| 1711 | `REAInstallSettingsEntry` 定义 |

### `REAUI.xm`

| 行号 | 符号 |
|---|---|
| 41 / 50 | `REAUIFlag` / `REAUISetFlag`（含总开关联动） |
| 51 声明 / 557 实现 | `REAUIMasterGroupKeys` |
| 153 | `REABuildMenu` |
| 542 | `REASymbol` |
| 555 | `REAKeyWindow` |
| 571 | `REATopViewController` |
| 586 | `REAToast` |
| 608 | `REASwitchCell` |
| 867 | `READetailController` |
| 980 | `REAModuleListController` |
| 1075 / 1080 | `REAFloatBall` 接口 / 实现 |
| 1189 | `REAWindow` |
| 1198 | `REAWindow -hitTest:withEvent:` |
| 1227 | `REAUI` |
| 1304 | `REAUI -openPanel` |
| 1438 | `REAOpenPanel()` |
| 1450 | `REAOverlayPanelClose()` |
| 1461 | `REAPresentFromBest()` |

---

## 附录 B：术语表

| 术语 | 含义 |
|---|---|
| **REASwap** | 本项目自研 swizzle：只替换**本类自有实现**，查不到就记 `miss`（绝不回落父类） |
| **36 条核心 Hook** | v5 起对齐的宿主关键方法集合，日志 `ok=36 miss=0` |
| **锚点（anchor）** | 一条"类 + 选择子 + 签名 + 归属开关"的绑定，是净化/功能的落地点 |
| **trampoline** | 按签名分型的通用转发函数（`PK_*`），把"拦截决策"与"逐条实现"解耦 |
| **行表（gPRowClass / gPRowOld）** | 记录"真正被改写的类 + 该类原 IMP"，解决父子类同名选择子取错原实现的问题 |
| **fail-open** | 出问题时不拦截、直接调原实现，保证功能可用（对本项目＝"宁可看广告也别卡死") |
| **LiveContainer** | 免越狱运行未签名 App 的容器环境，本项目运行前提 |
| **`__ustring`** | Mach-O 的 UTF-16LE 字符串段，原版中文文案全在这里 |
| **guard（原版）** | 原版每条 hook 的开关判定点，本项目的 `REAFlag` 与其等价 |
