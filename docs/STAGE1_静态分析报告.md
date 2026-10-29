# 阶段一 · 预处理与静态分析报告

目标样本：`BluedHush_5.19.dylib`（2,555,072 字节）  
宿主 IPA：`Blued X-上小蓝遇见有趣的人_7.50.3_decrypted_…ipa`（272,841,247 字节）  
宿主 Bundle：`com.danlan.xiaolan` / Blued 7.50.3 / MinimumOSVersion 13

---

## 1. IPA 解包结果（CONFIRMED）

- 用 Python `zipfile` 解包（本机 `C:\Windows\7z.exe` 已损坏，弃用）。
- `Payload/Blued.app/Blued` 主二进制 = **161,699,808 字节（154.2 MB）**，单薄片 `arm64`。
- **该 IPA 本身已是「打过插件」的版本**：主二进制里存在 6 条 `LC_LOAD_WEAK_DYLIB`，指向
  `@executable_path/Frameworks/` 下的注入件：

| 注入件 | 说明 |
|---|---|
| `BluedHush_5.18.dylib` | 本插件上一版（2.6 MB）|
| `BluedHook_v0_2_5.dylib` | 另一款插件 |
| `BluedEnhancer.2.8.9_Finala_arm64e.dylib` | 另一款插件（arm64e）|
| `FakeTools.dylib` | 16.6 MB |
| `FakeGPS.dylib` | 定位伪造 |
| `SmallBoard…dylib` | 名称含乱码 |

> 结论：这不是 App Store 原包，而是已重签 + 注入的二次打包件。用户提供的 **5.19 比包内 5.18 新**，本报告全部以 5.19 为分析对象。

## 2. dylib Mach-O 结构（CONFIRMED）

| 项 | 值 |
|---|---|
| 类型 | 单薄片 `MH_DYLIB`，`cputype=0x0100000C (arm64)`，`cpusub=0`（**无 arm64e 片**）|
| 指令集说明 | arm64 片在 arm64e 设备上可由系统以兼容模式加载 |
| LC_ID_DYLIB | `@rpath/BluedHush.dylib` |
| minos / sdk | **iOS 14.0** / SDK 16.4 |
| flags | `0x100085`（NOUNDEFS \| DYLDLINK \| TWOLEVEL \| NO_REEXPORTED_DYLIBS\|…）|
| 加载命令 | 38 条；含 `LC_DYLD_CHAINED_FIXUPS` + `LC_DYLD_EXPORTS_TRIE` + `LC_FUNCTION_STARTS` + `LC_DATA_IN_CODE` |
| 段布局 | `__TEXT` 0x0(size 0x200000) / `__DATA_CONST` 0x200000 / `__DATA` 0x234000 / `__LINKEDIT` 0x25C000 |
| 符号表 | **未 strip**：1054 个符号（630 个 `N_SECT` 函数 + 424 个未定义外部引用）|
| 字符串 | `__cstring` 5,041 条可见字符串；`__ustring` 有中文 UI 文案 |

### 依赖框架（LC_LOAD_DYLIB，21 条）
系统：`libobjc.A` / `Foundation` / `CoreFoundation` / `UIKit` / `CoreLocation` / `CoreGraphics` / `Photos` / `AVFoundation` / `QuickLook` / `Security` / `libsqlite3` / `libz.1` / `libSystem.B` / `QuartzCore` / `ImageIO` / `CoreMedia` / `MapKit`（弱链接 `UniformTypeIdentifiers`）  
越狱生态：**`@rpath/CydiaSubstrate.framework/CydiaSubstrate`**（Hook 基座）

rpath 全部为 **rootless（无根越狱）** 路径：
`/var/jb/Library/Frameworks`、`/var/jb/usr/lib`、`@loader_path/.jbroot/Library/Frameworks`、`@loader_path/.jbroot/usr/lib`

> 结论：该插件按 **Dopamine/palera1n 的 rootless 结构**编译，`TARGET = iphone:clang:latest:14.0`、`ARCHS = arm64`，链接 Substrate。

## 3. ObjC 结构（CONFIRMED，100% 解析）

指针采用 `LC_DYLD_CHAINED_FIXUPS`（`DYLD_CHAINED_PTR_64_OFFSET`）编码，已实现完整解码器
（`_work/macho.py`，`imports=423 fixups=28382 classes=76 funcs=3532 stubs=224`）。

- `__objc_classlist`：**76 个类**，全部带 `class_ro_t`、方法列表、属性、ivar。
- `__objc_methlist` 为 **relative method list**（entsize=12，`nameOff` 相对条目自身指向 selref 槽）。
- 合计 **1015 个方法**（完整清单见 `_work/analysis/classes.txt`）。

类清单（按职能分组）：

| 组 | 类 |
|---|---|
| 配置/许可/日志 | `HushConfig`(29 方法) `HushLicense` `HushLicenseSessionDelegate` `HushLogger` `HushPatch` |
| 悬浮球/入口 | `HushFloatBall` `HushEntryButtonTarget` `HushTabLongPressSettings` `HushTabLPTap` `HushWindowHelper` |
| 设置面板 | `HushSettingsPanel`(51) `HushModuleDetailController` `HushSwitchCell` `HushSwitchItem` `HushActionItem` `HushModuleSection` `HushModuleEntry` `HushIconPicker` `HushIconChoice` `HushAuthorFooterView` |
| 相册/隐私相册 | `HushGalController`(57) `HushGalCell` `HushGalHeaderView` `HushGalSection` `HushGalPreviewVC/PageVC/Source` `HushGalTap` `HushGalZipPickBridge` `HushGalBackupCell/VC` `HushPrivacyAlbumGrantTap` `HushPrivacyNavController` |
| 附近/九宫格 | `HushNMCardView` `HushNMDeckPage` `HushNMDeckController` `HushNMPhotoViewer` `HushNMWeakTableBox` `HushNAStripView` `HushNAViewer` |
| 位置/足迹 | `HushVLocPlainLocation` `HushLocationPickerController`(48/31 ivar) `HushLocationHistoryController` `HushLocGestureTarget` `HushTrackMarkerView` `HushTrackMapCardVC` |
| 访客/盯人(Stalk) | `HushStalkListController` `HushStalkDetailController` `HushStalkTargetCell` `HushStalkAvatarView` `HushStalkTapProxy` `HushStalkMaintCell` `HushVisitClearLP` |
| 风险用户 | `HushRiskListController` `HushRiskCell` `HushRiskTap` `HushRiskReportController` `HushSpyListController` `HushSpyCell` |
| 群发/翻牌 | `HushNTFormController` `HushNTFanPaiController`(72) `HushNTFindTargetController` `HushNTSkipListController` `HushNTEntryTap` `HushNTCheckTap` |
| 聊天辅助 | `HushQuickPhraseUI` `HushQPBarView` `HushRecallTapDelegate` `HushRecallTapTarget` `HushVanishedController` `HushVanCell` `HushVanTap` `HushHostStyle` `HushaState` `HushaPhotoViewer` `HushAUTCapsule` |
| 其它 | `HushScreenshot?`(无) `HushRiskMark…`（见 classes.txt）|

- 超类：`UIView / UIViewController / UITableViewCell / UINavigationController / UICollectionViewCell|ReusableView / UILabel / UIGestureRecognizer / MKAnnotationView / NSObject`；`HushNTFanPaiController`、`HushNTFindTargetController` 继承自家 `HushNTFormController`。

## 4. 静态初始化器（≈ `%ctor`）（CONFIRMED）

- 无 `__mod_init_func`；使用 **`__TEXT,__init_offsets`**（`LC_FUNCTION_STARTS` 同族的 `S_INIT_FUNC_OFFSETS`），
  地址 `0x1A7D04`，0x70 字节 = **28 个 uint32 偏移**：
  `0x18f8c, 0x34c28, 0x434c0, 0x66fa0, 0x679ac, 0x6f854, 0x8cea4, 0xa354c, 0xbccd4, 0xca3c0, 0xe69a0, 0xf0234, 0xf93e4, 0x105c80, 0x11127c, 0x124f18, 0x12b328, 0x12b778, 0x12dbd4, 0x132c24, 0x137b1c, 0x13e4a0, 0x15173c, 0x15b6c0, 0x15e158, 0x16f388, 0x18097c, 0x18dc54`
- 其中 **`0x434C0` 是主 Hook 安装器**（巨型函数，`0x434c0`→`0x6b***` 量级），包含全部 `MSHookMessageEx` 调用。

## 5. Hook 面统计（CONFIRMED）

| 指标 | 数量 |
|---|---|
| `_MSHookMessageEx` 调用点 | **557** |
| 已解出 类+selector+IMP | **447**（其余为子集分析未完全回溯，`__bss` 槽已解）|
| `_class_replaceMethod` | 1 |
| `_method_setImplementation` | 2 |
| `_class_addMethod` | 9 |
| 被 Hook 的宿主类（去重） | **约 90 个** |

大客户类 Top：`BDMessageViewController` 29、`DLDeviceFingerprint` 27、`GJIMMessageModel` 13、`BDPersonPrivacyAlbumCollectView` 11、`BDIndexPageCoversManager` 11、`BDGlobalConfig` 9、`BDNearbyListPublicUserInfoView` 9、`BluedTabBar` 9、`BDHomeViewController` 8、`BDProfile` 8、`BDPhotoBrowserController` 8、`RecentlyVisitorViewController` 8、`BDSessionViewController` 8、`BDNearbyMapSearchController` 7、`BDAvatarSurroundingModel` 7、`BDSessionListHeader1` 7。

## 6. 配置键空间（CONFIRMED）

68 个 `HushKey*` 常量（`__DATA_CONST,__const` 0x200C38–0x200E28，均为指向 CFString 的指针），
其持久化键名（完整表见 `_work/analysis/keys.txt`）例如：

`float_ball` `ball_icon` `switch_lite` `purify_master` `qq_home` `switch_chat_button_style`
`switch_stalk` `switch_avatar_long_press` `switch_avatar_long_press_area` `stalk_name_color` `longpress_nearby`
`switch_visit_clear` `switch_viewed_strike` `runtime_stalk_targets` `runtime_stalk_snapshots` `runtime_stalk_changes`
`switch_nearby_page_bg` `switch_nearby_signature` `switch_msg_page_bg`
`switch_anti_recall` `switch_msg_heal` `switch_flash_photo` `switch_flash_text`
`switch_auto_select_photo` `switch_auto_select_burn` `auto_select_burn_last_checked`
`switch_album_grant` `switch_blacklist_jump` `switch_flash_thumb` `switch_flash_ad_skip`
`switch_unlimited_burn` `switch_nearby_chat` `switch_nearby_album` `switch_nearby_mark`
`switch_card_intel` `nearby_mark_label_1..4` `switch_nearby_sort` `online_sort` `switch_screenshot`
`switch_read_receipt` `switch_secret_view_all` `switch_deleted_mark` `switch_msg_timestamp`
`switch_chat_watermark` `switch_chat_heart_off` `switch_chat_album_strip` `switch_risk_user_block`
`switch_spoof_lite` `switch_map_avatar_clear` `switch_blacklist_unlock` `switch_fair_exchange`
`switch_privacy_unlock` `switch_risk_login_bypass` `switch_image_save_menu` `switch_watermark`
`switch_local_vip` `switch_virtual_location` `switch_location_sim` `switch_private_photo`（另含 `switch_license_bypass`、`runtime_auth_token` 等）

配置 API 为 `HushConfig` 单例：
`+shared` `-isEnabled:` `-isEnabled:default:` `-setEnabled:forKey:` `-stringForKey:` `-setString:forKey:`
`-registerDefaults` `-prewarmFlagCache` `-hush_clearFlagCache` `-snapshot` `-resetToDefaults`
`-hasCustomLocation` `-customLat` `-customLng` `-setCustomLat:lng:` `-customAltitude` `-setCustomAltitude:`
`-authToken` `-userAgent` `-backupDir` `-defaults` `-flagCache` `-prefsSnapshot`

## 7. 阶段一结论

1. `BluedHush_5.19.dylib` 是一个 **Substrate 型（非 Logos 源码直编）** 的大型功能插件：无 `%ctor`/Logos 符号，
   而是 28 个静态初始化器 + 巨型安装器 `0x434C0` 通过 **`MSHookMessageEx`** 逐条挂 557 个 Hook。
2. 功能面覆盖：撤回对抗、阅后即焚/闪照、隐私相册解锁、截图检测绕过、本地 VIP、反越狱/反模拟器/反调试、
   设备指纹伪造、虚拟定位与足迹、附近的人增强、访客与已读、广告跳过、水印控制、黑名单解锁、群发翻牌、设置面板 UI 等。
3. 全部关键符号未 strip（`_Hush*` C 函数 630 个），逆向成本可控；`HushConfig` 的开关体系清晰可复现。
4. 该插件自带激活/授权体系（`HushLicense` / `HushActivationIsActive` / `switch_license_bypass` / `runtime_auth_token`），
   **但 Hook 安装本身不检查激活**（仅 7 处调用激活检查，全在 UI 层）。

产物：`_work/macho.py`（可复用的 Mach-O/ObjC/ChainedFixups 解析库）、`_work/analysis/` 下
`classes.txt`(76 类/1015 方法)、`symbols.txt`(1054)、`imports.txt`(423)、`keys.txt`(68)、
`hooks_full.txt`(557 条 Hook)、`keyrefs.txt`(68 键的引用点)。
