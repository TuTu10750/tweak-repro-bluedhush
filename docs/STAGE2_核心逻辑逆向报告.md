# 阶段二 · 核心逻辑逆向报告

对象：`BluedHush_5.19.dylib`（arm64 / MH_DYLIB / minos 14.0）  
方法：`_work/macho.py` 解码 chained fixups → capstone 全量反汇编 `__TEXT,__text`（0x4000, 429,217 条指令）→
对 557 个 `_MSHookMessageEx` 调用点做「函数级正向抽象解释」重建 x0..x3 实参。

标注约定：**【C】** = CONFIRMED（汇编/数据实证）；**【I】** = INFERRED（由调用形态与命名推断，未逐条动态验证）。

---

## 1. `%ctor` 入口定位【C】

该 dylib **没有 Logos 生成的 `%ctor`**，也 **没有 `__mod_init_func` 节**。静态初始化走
`__TEXT,__init_offsets`（`LC_FUNCTION_STARTS` 的 `S_INIT_FUNC_OFFSETS` 变体，`0x1A7D04`，28×uint32）：

```
0x18f8c 0x34c28 0x434c0 0x66fa0 0x679ac 0x6f854 0x8cea4 0xa354c
0xbccd4 0xca3c0 0xe69a0 0xf0234 0xf93e4 0x105c80 0x11127c 0x124f18
0x12b328 0x12b778 0x12dbd4 0x132c24 0x137b1c 0x13e4a0 0x15173c 0x15b6c0
0x15e158 0x16f388 0x18097c 0x18dc54
```

- `0x434C0` = **主 Hook 安装器**（其中 300+ 个 `MSHookMessageEx` 调用点）。
- 其余 27 个 init 各自安装少量 Hook / 注册通知 / 建默认值（例如 `0x12124?` 段为相册、`0xE69A0` 附近为附近的人）。

主安装器开头的真实形态【C】：

```asm
0434e8  adrp x8, #0x200000 ; ldr x8, [x8, #0x48]   ; __stack_chk_guard
0434f8  bl   #0x1a77e8                             ; objc_autoreleasePoolPush
043508  ldr  x28, [x8, #0x3c0]                     ; selref: shared
04351c  bl   #0x1a753c                             ; objc_retainAutoreleasedReturnValue
043520  adrp x0, #0x20c000 ; add x0, x0, #0x398    ; CFSTR "GJIMSessionService"
043528  bl   #0x2fc20                              ; class_exists()
04352c  cbz  w0, #0x4364c                          ; 不存在 → 跳过整段
043530  ... #0x2107b8 "GJIMMessageService" / #0x2107d8 "GJIMMessageModel"
043550  adrp x0, #0x1a9000 ; add x0, x0, #0xcde    ; "GJIMSessionService"
043558  bl   _objc_getClass
04355c  ldr  x1, [x8, #0x5a8]                      ; selref: p_handlePushPackage:
043564  adr  x2, #0x455e8                          ; 新 IMP
04356c  adrp x3, #0x257000 ; add x3, x3, #0x280    ; &orig 槽（__bss，8 字节步进）
043574  bl   _MSHookMessageEx
```

> 关键结论【C】：**每条 Hook 的安装守卫是“目标类是否存在”**，不是功能开关。
> `0x2fc20` 已被完整还原为 `BOOL class_exists(NSString *name) { return objc_getClass(name.UTF8String) != NULL; }`
> （`-UTF8String` 见 selref `0x2363c0→'shared'`、`0x2363c8→'isEnabled:'`、`0x236410→'componentsJoinedByString:'`，
> 以及 `0x235c28→'UTF8String'`）。

## 2. Hook 安装器骨架【C】

```
adrp x8,__objc_selrefs ; ldr x1,[x8,#off]     ; selector
adr  x2,<hook_impl>                            ; 替换实现
adrp x3,__bss          ; add x3,x3,#slot        ; 保存原 IMP（8 字节对齐、顺序递增）
bl   _MSHookMessageEx
```

- 57 个 `__bss` 槽（`0x257280` 起）连续排布，`orig` 通过 `ldr x8,[0x257000+slot]; blr x8` 调用。
- 557 处 `MSHookMessageEx`，**447 处已解出 (<类>, <selector>, <新 IMP>, <orig 槽>)**；剩余为回溯窗口边界失败的少量条目（清单见
  `_work/analysis/hooks_full.txt`，每行都带类名/selector/IMP/关联开关）。

## 3. 功能开关（HushConfig）逻辑【C】

### 3.1 开关读取的固定指令序列
每个被守卫的 Hook 函数开头都是同一模板：

```asm
adrp x8,#0x242000 ; ldr x0,[x8,#0x108]   ; __objc_classrefs → HushConfig
ldr  x1,[x8,#0x3c0]                      ; selref 'shared'
bl   _objc_msgSend
bl   _objc_retainAutoreleasedReturnValue
adrp x8,#0x200000 ; ldr x2,[x8,#0xCD0]   ; 实参 = &_HushKeyAntiRecall（CFString "switch_anti_recall"）
ldr  x1,[x8,#0x3c8]                      ; selref 'isEnabled:'
bl   _objc_msgSend                       ; → w22 = BOOL
```

即 **`[[HushConfig shared] isEnabled:@"switch_anti_recall"]`**【C】。
68 个开关键与其引用点已全量落库（`analysis/keys.txt` + `analysis/keyrefs.txt`）。

### 3.2 反撤回：`-[GJIMMessageModel recallType]`（IMP 0x46F94）【C】

```asm
046fd8  ldr  x2,[x8,#0xcd0]        ; "switch_anti_recall"
046ff4  ldr  x8,[x8,#0x288]        ; orig IMP 槽（_MSHookMessageEx 保存的原始实现）
047004  blr  x8                    ; r = [orig recallType]
047008  mov  x19, x0               ; r
04700c  cbz  w22, 0x4706c          ; if (!flag) return r
047010  cbz  w19, 0x4706c          ; if (!r)     return r
047020  ldr  x1,[x8,#0x3d0]        ; 'isEnabledForLevel:' (HushLogger)
047024  mov  w2, #3
047028  bl   _objc_msgSend         ; 日志分支
047044  adrp x3,#0x212000 ; add x3,x3,#0xb18   ; CFSTR "["
047050  bl   _objc_msgSend         ; 'logLevel:format:'
...
047068  mov  w19, #0               ; ★ 强制返回 0
04706c  mov  x0, x19 ; ret
```

**行为【C】**：`recallType` 在开关开启且原值非 0 时被强制改为 **0**（= 该消息不算撤回），并打一条 level 3 日志。
**语义【I】**：`recallType==0` 使客户端不渲染“已撤回/超级撤回”提示，达到防撤回效果。

### 3.3 反撤回旁路：`-[GJIMMessageModel isSuperRecallTip]`（IMP 0x47084）【C】

```asm
0470c0  ldr  x2,[x8,#0xcd0]        ; "switch_anti_recall"
0470e0  tbz  w22, #0, 0x470f8      ; flag==0 → 走 orig
0470e4  mov  w0, #0                ; ★ 直接 return NO
```
**行为【C】**：开关开启时 `isSuperRecallTip` 恒返回 `NO`。

### 3.4 截图检测绕过【C】

`-[BDMessageViewController p_screenshotTip]`（0x4B2E0）、`p_screenshotWarning`（0x4B1FC）、
`checkSendScreenshotTip`（0x4B3C4）三处同一模板（键 `0x200D80` = `switch_screenshot`）：

```asm
04b1a8  ldr  x2,[x8,#0xd80]        ; "switch_screenshot"
04b1c4  tbz  w22, #0, 0x4b1dc      ; flag==0 → 调 orig
04b1c8  mov  w0, #0                ; ★ 返回 0/Nil
04b1d8  ret
```

**行为【C】**：开关开启后，截图提示/警告/发送截图提示全部返回空值，即**不发提示**。

### 3.5 本地 VIP：`-[BDGlobalConfig is_vip]`（IMP 0xFBC64）【C/I】

```asm
0fbc78  ldr  x8,[x8,#0x3c0] ; blr x8      ; orig is_vip
0fbc90  ldr  x0,[x8,#0xdd0]               ; HushConfig
0fbcb4  ldr  x2,[x8,#0xe18]               ; 键 "…local_vip"（0x200E18）
0fbcc0  bl   _objc_msgSend                ; [shared isEnabled:key]
```
**行为【C】**：读取 `switch_local_vip`；后续按开关改写返回值（同族 `vip_status/vip_type/vip_expire_days` 见
`0xFBBE0/0xFBB58/0xFBD58`）。**语义【I】**：把 VIP 判定改为本地伪造，绕过服务端权益校验。

### 3.6 反越狱 / 反模拟器 / 反调试【C】

`BDMessageViewController` 上有 12 个「检测类」方法被 Hook（同一批 IMP 0x12BFC8–0x12C9EC）：

`amIJailBroken` `amIRunInEmulator` `checkDYLD` `checkFork` `checkForkWithCompletion:`
`checkExistenceOfSuspiciousFiles` `checkSuspiciousFilesCanBeOpened` `checkRestrictedDirectoriesWriteable`
`checkSymbolicLinks` `checkURLSchemes` `emulatorCheckCompile` `emulatorCheckRuntime` `performChecks`

其 IMP 开头均为 `[orig ...]` → `[HushConfig shared]` → `isEnabled:` 模板，
**语义【I】**：这些 Hook 把越狱/模拟器/调试检测统一压成“安全”（返回空/NO/清空检测结果），
配合 `DLDeviceFingerprint`(27 Hook) 的指纹伪造一起过风控。

## 4. Hook 目标全表（按功能域归类）

完整 557 条见 `_work/analysis/hooks_full.txt`（列：目标类 / selector / 新 IMP / 关联开关 / class_exists 守卫）。
下表为“域 → 关键 Hook”（全部【C】：类名、selector、IMP 三项均由 fixups+反汇编实证）。

### 4.1 消息撤回对抗（16 处关联 `switch_anti_recall`）
| 目标类 | selector |
|---|---|
| GJIMMessageModel | `recallType` `isSuperRecallTip` `setRecallType:` `setIsSuperRecallTip` `setDestroyUrl:` |
| GJIMSessionService | `p_handlePushPackage:` `addMessage:` `addMessages:` `updateMessage:` `p_fetchSyncMessagesWithType:syncLocalId:` `gji_updateMessage:` `gji_updateMessageReadedFromMaxMessage` `gji_insertForMessages:` `gji_insertForMessages:complete:` |
| GJIMMessageService | `deleteMessage:` |
| GJIMEngine | `p_handleAMessageWithData:` `handleingGRPCPrivatePackage:` |
| GJIMDBService / GtkDbStore | 6 + 4 处（消息落库/查询旁路）|

### 4.2 阅后即焚 / 闪照 / 闪文（`switch_flash_photo` 18、`switch_flash_text` 3、`switch_auto_select_*`）
`NewKeyBoardPhotoView resetLoadData/actionDes:`、`NewKeyBoard p_showKeyboardStateRecentPhoto`、
`BDAutoDestoryImageViewController`(5)、`BDDestoryChatCell`(4)、`BDMessageRecentSendPhotoModel`(2)、
`BDVideoFileManager`(3)、`BDMessageViewController setMessages:/p_showDestoryTip:`、
`BDGlobalConfig is_open_pic_ban_save`；
配套数据：`hush_flash_converted.plist`、`hush_auto_burn_mem_v2`、`hush_scheduled_recall.plist`、`hush_recall_intercepted.plist`（【C】字符串常量）。

### 4.3 隐私相册解锁（`switch_private_photo` 45 处引用，最重）
`BDPersonPrivacyAlbumCollectView`(11：`access_private_photos` `setAccess_private_photos:` `privacy_photos_has_locked`
`setPrivacy_photos_has_locked:` `convertToSwiftStatus:obj:` `setHidden:` `setAlpha:` `setFrame:` `didMoveToSuperview` `layoutSubviews`)、
`BDHomePrivacyAlbumModel`(6)、`UserAlbum`(3)、`BDPhotoBrowserController`(8)、`BDPhotoBrowserBasicCell`(2)、
`BDHomePageAlbumCell`(5)、`BDHomeAlbumCell`(3)、`HushPrivacyAlbumGrantTap`；
本地库：`hush_album_pics_v2.json` / `hush.album.kv` / `hush_album_declared_` / `hush_album_actual_` / `hush_album_locked_`（【C】）。

### 4.4 截图/水印/存图（`switch_screenshot` 11、`switch_watermark` 6、`switch_image_save_menu`）
`BDMessageViewController p_screenshotTip/p_screenshotWarning/checkSendScreenshotTip`、
`BDGlobalConfig is_open_pic_ban_save`、`SDWebImageManager`(2)、`NSURLCache`(2)、`NSMutableURLRequest`(2)、
`NSFileManager`(4)。

### 4.5 本地 VIP / 权益（`switch_local_vip` 11）
`BDGlobalConfig is_vip/vip_status/vip_type/vip_expire_days`、`BDVIPPrivilegeConfigModel`(5)、
`BDShadowPrivilegeController`(3)、`purify_mine_vip`。

### 4.6 虚拟定位 / 足迹 / 轨迹（`switch_virtual_location` 9、`switch_location_sim` 13、`switch_altitude`）
`CLLocationManager`(5)、`CLLocation`(3)、`BDLocationService`(4)、`MKMapView`/`BDAvatarAnnotationView`(2)、
`BDNearbyMapSearchController`(7)、`HushVLocPlainLocation`（自家）、`hush_track_*`。

### 4.7 附近的人增强（`switch_nearby_*`、`switch_nearby_sort`、`switch_card_intel`）
`BDNearbyListPublicUserInfoView`(9)、`BDNearbyFloatingLayerView/Model`(5+5)、`BDNearbyTopFixView`(3)、
`BDNearbyDataAdapter`(3)、`BDNearbyGridView`(2)、`BDNearbyRecommendCell`(2)、`BDAvatarSurroundingModel`(7)、
`BDIndexPageCoversManager`(11，含 6 个开屏广告方法 → `switch_flash_ad_skip`)。

### 4.8 访客 / 已读 / 隐身（`switch_visit_clear`、`switch_secret_view_all` 6、`switch_read_receipt` 3）
`RecentlyVisitorViewController`(8)、`BDUserVisitorCell`(3)、`BDSessionListHeader1`(7)、`BDProfile`(8)、
`UserInformation`(4)、`UserSetting`(2)。

### 4.9 反检测 / 指纹伪造
`DLDeviceFingerprint`(27)、`SmAntiFraud`(2)、`BDFingerprintManager`(6)、`BDMessageViewController` 12 个检测方法、
`GXWatchdog checkConnectOrHeart`、`NetworkWatchdog`（心跳/网络指纹）。

### 4.10 UI 与设置（自家 UI + 宿主 TabBar）
`BluedTabBar`(9)、`UITabBarController`(6)、`AppDelegateModel`(6)、`SceneDelegate`(2)、`UIViewController`(2)、
`HushSettingsPanel`(51) 等 76 个自家类提供面板与入口。

## 5. 激活 / 授权体系【C】

- `HushLicense` / `HushLicenseSessionDelegate` / `HushPatch` 类；C 函数
  `_HushShowActivationUIWithCompletion`(0x4000) `_HushShowActivationUI`(0x47CC) `_HushActivationIsActive`(0x13140)
  `_HushActivationStatusLine`(0x13560)。
- 仅 7 处调用 `_HushActivationIsActive`（`0x402C 0x443C 0x47D4 0x19A888 0x1A38CC 0x1A5D34 0x1A63B4`），
  **全部位于 UI/设置层**；Hook 安装不校验激活。
- 键：`switch_license_bypass`、`runtime_auth_token`、`HushActivationDidChange`、`hush.localstore`、
  `hush_local_store_v1.json`、`com.bluedhush.log`。
- **结论【C】**：复现件无需实现激活，全部 Hook 可无条件挂载。

## 6. 逆向结论汇总

| 项 | 结论 | 证据级别 |
|---|---|---|
| 入口 | 无 Logos `%ctor`；28 个 `__init_offsets`，主安装器 `0x434C0` | 【C】|
| Hook 机制 | `MSHookMessageEx` × 557，`orig` 存 `__bss 0x257280+` | 【C】|
| 安装守卫 | `class_exists(NSString*)`（0x2FC20），非功能开关 | 【C】|
| 功能开关 | `[[HushConfig shared] isEnabled:@"switch_xxx"]`，68 键 | 【C】|
| 开关生效点 | 各 Hook 实现内部，模板：`flag → 短路/改写返回值 → 日志` | 【C】|
| 具体返回值 | 反撤回→`recallType=0`、`isSuperRecallTip=NO`；截图→返回 0/Nil；VIP→本地判定 | 【C】行为 /【I】业务语义 |
| 反检测 | 12 个越狱/模拟器/调试检测方法被压平 + 27 处设备指纹伪造 | 【C】目标 /【I】语义 |
| 激活 | 与 Hook 解耦，可完全省略 | 【C】|

> 阶段三将据此产出 Theos 复现工程：以 `MSHookMessageEx/Logos` 挂回同一批类与 selector，
> 复刻 `switch_*` 开关体系（默认全开），并在关键 Hook 处输出 `NSLog(@"[REA-Test] 注入成功")`。
