# 原版契约（从真机证据反推，逐条可复核）

> 本文不是设计文档，是**对账单的基准**。每一条都注明来源：
> `[BIN]` = 原版 `BluedHush_5.19.dylib` 二进制（2,719,216 B / sha256 前缀 `67ca70c5c274c2c0`）
> `[LOG]` = 原版真机日志 `hooo` / `hooo(1)` / `hooo.1`（合计 44,000+ 行）
> `[FS]` = 原版沙盒落盘文件（`hush_*.json` / `hush_track_*.plist|txt`）
> 二进制里读不出来的语义，一律标「推断」，不写进契约。

---

## 1. 证据清单

| 证据 | 规模 | 用途 |
|---|---|---|
| `BluedHush_5.19.dylib` | 76 类 / 1,015 方法 / 398 条中文串 | 类名、方法名、Type Encoding、hook 面 |
| `hooo` + `hooo(1)` + `hooo.1` | 1 MB + 1.1 MB + 2.1 MB | 日志契约、行为时序、失败分支 |
| `hush_album_badge_v1.json` | 4,092 键 | 相册角标（锁定/声明/实际/hintAt） |
| `hush_album_pics_v1.json` | 300 条 | 相册图片 URL 与时间戳 |
| `hush_gallery_kv_v1.json` | 4 个字典 / 23,949 条 | 展览馆名称索引 |
| `hush_local_store_v1.json` | 2 个字典 / 5,903 条 | 关系状态、来访时间 |
| `hush_track_headers.plist` | 10 项 | 追踪请求的真实 header |
| `hush_track_template.txt` | 1,086 B | 追踪请求的真实 URL 模板 |
| 抽取结果 | `docs/evidence/orig-log-shapes.json` | 68 个日志前缀 × 去重后的行模板 |

复现命令（Windows / 任意装 python3 的机器）：

```
python tools/extract_log_shapes.py "C:\...\hooo" "C:\...\hooo(1)" "C:\...\hooo.1"
```

---

## 2. 日志契约 `[LOG]`

### 2.1 格式

```
HH:mm:ss.SSS [BLUEDHUSH] [I] <msg>
```

- 时间戳三位毫秒、本地时区；`[BLUEDHUSH]` 是固定 tag；级别位 `[I]`（信息）。
- 落盘文件：`<App沙盒>/Documents/hooo`（**不是** `BluedHushREA.log`）。
- 抬头（每次启动一次）：

```
[BOOT] ========== BluedHush 加载 ==========
[BOOT] version=5.18 arch=arm64 pid=10798 bid=com.danlan.xiaolan author=Tinycca (@Tinycca)
[BOOT] build=Oct  7 2026 11:45:29
[BOOT] 日志等级: 信息（I）
[BOOT] 日志文件: /var/mobile/.../Documents/hooo
[BOOT] 激活状态：已激活 · 永久（受限 14 项：定位与追踪 + 限制解放）
```

### 2.2 68 个前缀（完整清单见 `docs/evidence/orig-log-shapes.json`）

| 前缀 | 行数 | 语义 |
|---|---|---|
| `[BOOT]` | — | 启动抬头、激活状态 |
| `[License]` | — | 授权：`已激活 · 永久（受限键 14 项）`、`服务器复核通过` |
| `[Config]` / `[Prefs]` / `[Migrate]` | — | 配置注册、偏好迁移 |
| `[SettingsEntry]` | 47 | 设置页入口，**tableHeaderView 方案** |
| `[Purify]` | 1,321 | 净化总前缀（含 `[Purify][设置页]`/`[Tab入口]`/`[Tab补全]`/`[Tab角标]`/`[标签净化]`/`[ivar]`） |
| `[Purify][设置页]` | — | `heightForRow 归零命中：section=0 row=0` / `未归零 → %orig` |
| `[Purify][Tab入口]` | 72 | `setViewControllers 共 5 项；titles(5)` + 5 行 `[i] title=… 内层=…` |
| `[Purify][Tab角标]` | 26 | `setEntryBadgeText 值=(null) 索引 4 → 4` |
| `[Purify][Tab补全]` | 76 | `p_changeItemStateAtIndex:…`、`旧宿主遗留视图挂钩 5 项` |
| `[Risk]` / `[RiskEnv]` / `[RiskDevice]` | 56 / 112 / 186 | 越狱检测依赖、21 条风险路径隐藏、风控 URL 阻断 `→ http://0.0.0.0/` |
| `[Watchdog]` | 27 | 主线程阻塞统计 + 高频 hook 面包屑 |
| `[Chat][补拉]` | 18,278 | 推送静默 N 秒 → `SessionService.p_fetchSyncMessages` |
| `[Chat][强推]` | 553 | 25s 起分级：巡链路→强制重连→重建 socket，级间隔 30s、每轮 ≤3 级 |
| `[Chat][防撤回]` | 14 | `定时扫描已启动（每 3 秒增量建快照，不依赖宿主 hook）+ 回前台全量复检已挂` |
| `[Chat][后悔药]` | 126 | 长按菜单注入、删消息/删库/撤回入口、`BDCustomMenuView` reloadData |
| `[Chat][闪文]` / `[Chat][转照片]` / `[Chat][历史闪照]` / `[Chat][自动选图]` / `[Chat][快捷短语]` / `[Chat][聊天相册]` | — | 各自分组装载完成 |
| `[Location]` | 64 | `改写落库坐标 → 22.566183, 114.111104` |
| `[VLocCL]` | 32 | 已包装 4 个 delegate：`SmGpsDelegate` / `BMKLocationManager` / `GTCGbdLService` / `MKCoreLocationProvider` |
| `[VLoc]` | 2 | `观测到「虚拟定位 失效 → 生效」` |
| `[LocPicker]` | 249 | 选点页（48 方法的那个 VC） |
| `[LocStatus]` | 126 | 状态行：`enabled=1 lat=… lng=… → 虚拟定位开 / …` |
| `[PreTrack]` | 620 | 预计算：宿主快照、候选残差、缓存写入 |
| `[Track]` | 454 | 探测与解算（见 §4） |
| `[Gallery]` / `[Gallery][索引]` | 547 | 展览馆：资料页关联、索引重建 |
| `[Album]` / `[AlbumPics]` / `[AlbumTag]` / `[NearbyAlbum]` / `[UserAlbum]` | 48 / 63 / 1 / 269 / 14 | 相册接口、图片缓存、角标、远端相册条 |
| `[Privacy]` / `[Sensitive]` / `[Vanished]` / `[Spy]` / `[Stalk]` / `[VisitClear]` / `[FanPai]` | — | 隐私分组各子模块 |
| `[NT]` | 24 | 列表排序：`sortType=(空) → online` |
| `[Panel]` / `[HostStyle][取样]` / `[FloatBall]` | 126 / 7 / 38 | 面板入栈、宿主样式取样、悬浮球 |
| `[InlineEdit]` / `[MapAvatar]` / `[NearbyMark]` / `[NearbySig]` / `[FindTarget]` / `[TabLP]` / `[ToolsEx]` / `[Diag]` / `[Compat]` / `[Swift]` / `[LS]` / `[Log]` / `[Rel]` / `[Basic]` / `[PATCH]` / `[Backup]` / `[Role]` / `[RiskMark]` | — | 其余分组 |

### 2.3 已确证的关键行为（不是猜的，有原文）

1. **设置页入口 = tableHeaderView，不插行** `[LOG]`
   `[SettingsEntry] 分组装载完成（tableHeaderView 方案，不触碰行数据）`
   `[SettingsEntry] 入口已装入 tableHeaderView：宽 440.0 高 142.0（顶部间距 10 + 行高 54 + 原 header 78）`
   `[SettingsEntry] 宿主样式取样：行高 54.0 / 箭头（24×24，右距 36.0…）`
   → 原版为什么从不卡设置页：它根本不参与 `numberOfRows` / `cellForRow` / `didSelect` 的下标分布。
2. **精简项 = 行高归零**，不是 cell 隐藏 `[LOG]`
   `[Purify][设置页] heightForRow 归零命中：section=0 row=0`
3. **开屏净化拦的是数据源**：`[Purify] ◀ getSplashAdForColdLaunch`、`[Purify] ◀ p_getSplashAdvertisementForColdLaunch`、`[Purify] ◀◀ showCoverWithType:3 isColdLaunch=0` `[LOG]`
4. **风控是恒生效层**：`[RiskEnv] 风控环境加固已启用（隐藏 21 条风险路径，无开关、恒生效）` `[LOG]`
5. **虚拟定位有 4 条 delegate 旁路**，不止 `BDLocationService` `[LOG]`
6. **看门狗带面包屑**：`[Watchdog] ⚠️ 主线程疑似卡住 8225 ms（第 1 次报告）；高频 hook 面包屑：privacy.nearby.distance×5586, main-ack×534, pu.patchTick×266` `[LOG]`

---

## 3. 磁盘契约 `[FS]`

四个 JSON 都在 `Documents/` 下，命名 `hush_<域>_v1.json`。

### 3.1 `hush_album_badge_v1.json` —— 扁平字典，4,092 键

| key 形态 | 条数 | 值 |
|---|---|---|
| `hush_album_locked_<uid>` | 1,433 | int `0` / `1`（我是否已解锁对方相册） |
| `hush_album_locked_<uid>.hintAt` | 1,433 | float，epoch 秒（何时给出过提示） |
| `hush_album_declared_<uid>` | 613 | int，常见 1–12（资料页展示的照片数） |
| `hush_album_actual_<uid>` | 612 | int（接口实收张数） |

### 3.2 `hush_album_pics_v1.json` —— 300 条

```
"<uid>": { "u": [url…], "f": <epoch float>, "t": <epoch float> }
```
`u` 是 URL 数组（`[FS]` 实测多为 `[]`），`f` 首次抓取时间、`t` 最近更新时间。

### 3.3 `hush_gallery_kv_v1.json` —— 4 个字典

| 键 | 条数 | 值 |
|---|---|---|
| `runtime_nt_gallery_show_ids` | 7 | uid → … |
| `runtime_nt_gallery_names` | 11,969 | uid → 昵称 |
| `runtime_nt_gallery_chat_names` | 11,966 | uid → 会话名 |
| `runtime_nt_gallery_user_names` | 7 | 大 uid → 名称 |

### 3.4 `hush_local_store_v1.json` —— 2 个字典

| 键 | 条数 | 值域 |
|---|---|---|
| `runtime_nt_relation_states` | 4,123 | int ∈ {1, 2, 5}（关系标签状态机） |
| `runtime_nt_visit_times` | 1,780 | float，epoch 秒 |

### 3.5 NSUserDefaults

开关名在二进制与日志里可枚举（`switch_*` / `purify_*` / `rea_*`），但**这份沙盒导出里没有 `Preferences/*.plist`**，
因此 defaults 键的默认值仍属「未确证」。下一步要一份 `Library/Preferences/com.danlan.xiaolan.plist` 才能把默认值锁死。

---

## 4. 追踪协议 `[FS]`+`[LOG]`

### 4.1 请求模板（`hush_track_template.txt` 逐字）

```
https://<host>/users?aaid=…&birth_time=…&boot_mark=…&boot_time=…&carrier=0&column=3&conn_type=2
 &extra_info=<base64>&filters={...}&from=list&idfa=&last_show_uids=…&latitude=22.566183
 &limit=60&longitude=114.111104&make=Apple&model=iPhone18,2&req_id=…&scroll_type=0
 &sort_by=online&start=0&update_mark=…&update_time=…&wx=1&wx_sdk=2.0.4
```

- `latitude` / `longitude` 就是探测点，其余参数原样照抄宿主那次请求。
- `filters` 是 JSON：`filter_album_open / condition / age / filter_new_user / instant_status / time_span / weight / filter_register_time / filter_real_switch / geo_reach / height / filter_already_chatted / online`。
- `extra_info` 是加密串，原版**不解密也不重算**，直接复用宿主那次的值 `[LOG]`（`sync=bare`）。

### 4.2 Header（`hush_track_headers.plist` 逐字，10 项）

```
Accept-Encoding: br, gzip, deflate     Accept-Language: zh-CN
Authorization: Basic Og==              Channel: a0001ri/a0001i
Referer: https://argo.blued.cn/users/tags
User-Agent: …iOS/160447_6.44.7_6972_0921…
traceparent: 00-<32hex>-<16hex>-01
ua: Mozilla/5.0 (iPhone…)
x-bcsign-signature: djE6…  (base64 签名)   x-bcsign-timestamp: 1793374639
```

`[Track] 宿主请求头已采集 10 项 @argo.blued.cn（keys: …）` —— 原版是在宿主发出同类请求时**把 header 抄下来**，
随后自己发探测请求时原样带上（签名与时间戳也复用，因此有时间窗）。

### 4.3 解算算法（`[Track]` 日志逐条反推）

```
[Track] ══ 位置追踪（参考公式）开始 uid=<8位> 起点(22.566183,114.111104) token=有
[Track] 探测 stage=east              attempt=1 (22.566183,114.212372) dist=7.7900 km sync=bare
[Track] 探测 stage=north-candidate   attempt=1 (22.631079,114.184018) dist=0.0100 km sync=bare
[Track] 探测 stage=south-candidate   attempt=1 (22.585555,114.114468) dist=0.1400 km sync=bare
[Track] 探测 stage=refine-east       attempt=1 (22.585555,114.115830) dist=0.1500 km sync=bare
[Track] ══ 参考公式解算完成 success=1 residual=0.0100 km 目标(22.631079,114.184018) 探测 2 次 用时 1.4s
[Track] 同步服务端位置 22.566183,114.111104 @argo.blued.cn → code=200
```

要点（全部来自日志原文）：

1. 起点 = 我当前坐标；已知距离 `dist` 取自宿主模型（`BDAvatarSurroundingModel.distance`），省一次探测。
2. 东西向先测一次得到经度方向的一元方程（同一纬度上移动，距离变化单调）。
3. 南北向再测（`north-candidate` / `south-candidate`），两轴合成即为目标点。
4. `refine-*` 是精度校准；`≤0.05 km` 即跳过校准（`[PreTrack] 候选残差 0.02 km 已达标（≤0.05 km）→ 跳过精度校准（省 3 探测 ≈2s）`）。
5. 收尾把虚拟坐标写回服务端（`code=200`），让宿主后续请求里带的是同一个坐标。
6. 缓存：`[PreTrack] 缓存写入 uid=… success=1 residual=0.0100 msg=📍 纬度: … / 📍 经度: … / 🎯 残差: 0.01 km / 相对起点：东 7495 米，北 7224 米`。

---

## 5. 1:1 对照单（v15.0-EVID）

状态口径：**✅ 完全一致** = 日志文案 + 行为 + 注入方式都可对上；**◐ 部分** = 行为在、文案或路径不全；**✗ 未做**。

| # | 模块 | 原版 | 我们 | 状态 |
|---|---|---|---|---|
| 1 | 日志格式 / 文件名 | `HH:mm:ss.SSS [BLUEDHUSH] [I] msg` → `Documents/hooo` | 本版已改 | ✅ |
| 2 | BOOT 抬头 | 5 行（version/arch/pid/bid/author、build、等级、日志路径） | 本版已加 | ✅ |
| 3 | 设置页入口 | tableHeaderView，宽 440 高 142 = 10+54+78 | 本版改为 tableHeaderView，行 54 + 间距 10 | ✅ |
| 4 | 设置页精简 | 行高归零 + `[Purify][设置页]` 日志 | 本版已对齐（且只在本类生效） | ✅ |
| 5 | 风控出口阻断 | 恒生效，`→ http://0.0.0.0/` | 本版已加（fengkongcloud 3 域） | ◐ 只 3 个域，原版 10/10 |
| 6 | 虚拟定位选点 UI | `HushLocationPickerController` 48 方法 | v14.0 已 1:1 重建 | ✅ |
| 7 | 虚拟定位 delegate 旁路 | 4 条（SmGps/BMK/GTC/MKCore） | 只有 `BDLocationService` 6 条 | ◐ |
| 8 | 落库坐标改写 | `[Location] 改写落库坐标` | 有 `p_saveLocationWithLot:lat:` 钩子 | ◐ 无该行日志 |
| 9 | 位置追踪 | §4 全套 | ✗（协议已完全解出，尚未落代码） | ✗ |
| 10 | 状态行 `[LocStatus]` | 导航栏右侧状态行 + 反查地址 | ✗ | ✗ |
| 11 | 相册角标/图片缓存 | 4,092+300 条真实 key | ✗（schema 已锁死，未落代码） | ✗ |
| 12 | 展览馆 | `HushGal*` 12 类 + 4 个名称索引 | ✗ | ✗ |
| 13 | 隐私分组（查访客/视奸/注销/清除记录） | 各 1 个分组 | ✗ | ✗ |
| 14 | 防撤回 | 3 秒增量快照 + 回前台复检 | 有 recallType/setRecallType 等钩子 | ◐ 缺定时快照 |
| 15 | 后悔药 | 长按菜单 `BDCustomMenuView` 注入 | ✗ | ✗ |
| 16 | 聊天强推（补拉/强推） | 18,278 + 553 行日志的完整状态机 | ✗ | ✗ |
| 17 | Tab 手术（入口/角标/补全） | `[Purify][Tab*]` 三组 | ✗ | ✗ |
| 18 | 看门狗 + 面包屑 | 阻塞统计 + 高频 hook 计数 | 有 O1b 采样（v13 引入） | ◐ 无面包屑 |
| 19 | 授权（License） | 在线激活、受限 14 项 | ✗ | ✗ |
| 20 | 设置面板结构 | `HushSettingsPanel`(51) / `HushModuleSection` / `HushSwitchItem` / `HushModuleDetailController` | 自建面板 | ◐ 交互不一致 |

---

## 6. 下一批（按证据可得性排序）

1. **位置追踪 `REATrack.xm`**（§4）：协议、header、URL 模板、收敛判据全部已确证，可直接写。
2. **`[LocStatus]` 状态行**：`[LocStatus] 导航标题候选被拒 2 个（不在活动窗口／超出 160pt 导航带／挂在列表里）` 给出了定位算法，可实现。
3. **相册角标 / 图片缓存**（§3.1 / §3.2）：key 与值域已锁死。
4. **`[VLocCL]` 四条 delegate 旁路**。
5. **看门狗面包屑**：需要一个高频 hook 计数器，改动小。

仍缺的证据（有就能继续，没有就是猜）：`Library/Preferences/com.danlan.xiaolan.plist`（开关默认值）、`HushSettingsPanel` 的菜单层级（二进制里只有方法名，层次关系需要运行截图或界面 dump）。
