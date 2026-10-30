# V1 实施计划（Plan）— Blued「小蓝助手」Runtime Tweak

| 项 | 值 |
|---|---|
| 文档版本 | **v1.3**（自我 grill 两轮 + 独立子 Agent 交叉审核后修订；v1.2 的“档 1 默认开”结论已被推翻，见 §3.1.1） |
| 基线 | `1ff9319`（v12），`dist/v12/BluedHushREA.dylib` |
| 事实源 | `HANDOFF.md`（权威但含已证伪的描述）、`tweak-repro/Tweak.xm`、`tweak-repro/REAUI.xm`、`_work/analysis/host_index.json`、`.github/workflows/*.yml` |
| 范围 | P0 两条阻塞缺陷 + 净化组 26 开关收口 + 聊天增强 8 组 15 开关 |
| 明确不做 | 其余 55 个待接开关（S3–S5）、iOS 26 全面适配、菜单改版、性能调优 |
| 交付形态 | 每个里程碑一个可安装 fat dylib + CI 运行页 + 真机日志片段 |

---

## 0. 计划的三条内核

1. **先可观测，再修改。** 当前两个 P0 全部依赖"用户说卡了"这一条信息，交接书里的根因全是假设。V1 的第一批交付物不是修复，而是**观测骨架**（阶段计时、重入护栏、熔断、崩溃现场环形日志、可热关的 kill switch）。没有它，后面每一次真机复验都是猜。
2. **任何改动必须"单层可关 + 自动 fail-open"。** 禁止"在 wrapper 里 `return` 了事"。所有拦截都配一个降级动作（超时/异常 → 调原实现），并且这一层能单独关掉做二分。
3. **一个开关的完成定义 = 锚点四元组 + 日志 + 验收用例 + kill switch。** 四元组指 `{类, 选择子, 真实 typeEncoding, trampoline 分型}`。缺任何一项都不算"已接线"，也不许写进 Handoff 的"已完成"表。

> 三条内核直接对应 `HANDOFF.md` §8 红线 1 / 5 / 及 §2.3 v5 铁律。

---

## 1. 现状校正（写计划前必须承认的四件事）

### 1.1 「净化 26 开关已挂真实锚点」这个说法偏乐观

按 §4.1-A 的锚点表逐条统计：

| 分类 | 数量 | key |
|---|---|---|
| **强实现**（有选择子级锚点，`kPInstall` 命中即拦截） | **13** | `purify_splash_ad` `purify_feed_ad` `purify_nearby_ad` `purify_banner` `purify_float_layer` `purify_mine_ad` `purify_safe_tip` `purify_blur_label` `purify_sensitive` `purify_sensitive_alert` `purify_block_call` `purify_block_voice` `purify_visitor_ad` |
| **弱实现**（只有 `kPViewRules` 类名子串兜底，无数据源级证据） | **12** | `purify_map_guide` `purify_svg_ad` `purify_new_nav_tag` `purify_call_header` `purify_session_card` `purify_welcome_pop` `purify_follow_card` `purify_chat_emoji` `purify_match_emoji_bar` `purify_passby_tip` `purify_live_entry` `purify_mine_vip` |
| **半强**（有 `PShouldTrimSettingCell` / `PIsTrimmedRow` 两个视图层函数，非选择子锚点） | **1** | `purify_set_items` |

`kPInstall` 逐行统计（这一行必须精确，因为所有验收阈值都以它为分母）：

| 项 | 实测 | 交接书原文 | 说明 |
|---|---|---|---|
| `kPInstall` 行数（`P_ROW_COUNT`） | **56** | 52 | `sizeof(kPInstall)/sizeof(kPInstall[0])`（`Tweak.xm:1252`），启动日志实际打印「共 **56** 条」 |
| 其中带业务 key 的锚点 | **52** | — | 13 个 key 分摊，见下 |
| 其中基础设施行（key = `NULL`） | **4** | — | `NSURLSession -dataTaskWithRequest:completionHandler:` / `-dataTaskWithRequest:` / `NSMutableURLRequest -setURL:` / `UIView -didMoveToSuperview` |
| `kPViewRules` 子串规则 | **48** | 47 | `Tweak.xm:1505` 起 |
| UI 侧净化开关 | **27**（含 `purify_master`）→ **26 细项** | 26 | `REAUI.xm:161-216`；`purify_master` 副标题写「23 项」是陈旧文案 |

52 条业务锚点里 **19 条全给了 `purify_splash_ad`**（36.5%），剩下 33 条摊给 12 个 key。所以"26 个开关已接真实锚点"实质是 **13 强 + 12 弱 + 1 半强**（13+12+1=26，与 UI 侧 27−master 一致）。弱实现违反 §8 红线 1 的实质要求（"每个开关必须有真实锚点或真实交互层"），V1 必须把它们升级。这是 P1 的主工作量，不是收尾工作。

> **口径修正的后果**：`[Purify] 锚点安装：ok=N miss=M（共 56 条）` 是唯一的安装期事实。交接书写「共 52 条 / 应接近 52」会让每一次真机验收都拿错分母——`ok` 到 52 其实意味着 4 条基础设施行全 miss。§2 与 §7 的阈值已按 56 改写。

### 1.2 Bug B 的根因假设与代码实际形状不符

交接书 §3.3 的 H1（二次 swizzle 无限递归）在**静态代码层面已被现有 guard 挡住**：`rea_settingsCell` 里有 `if (p_settingCell == NULL) return nil;`，`REAInstallSettingsEntry` 里有 `if (cRows != Nil && p_settingRows == NULL)`——正常单次加载路径下不会把 `p_settingRows` 写成自己的 wrapper。真正的自递归风险只在**同一进程内第二次 `dlopen` 本 dylib**（LiveContainer 重载/重复注入）时成立：静态变量被重置、类上却还挂着上一轮的 wrapper，`REASwap` 取回的 old 就是自己的 wrapper。

而代码里**确实存在**、且比 H1 更可能致死的缺陷是另外几条（详见 §3.2 缺陷台账 **D1–D9**），其中 D1「四个 hook 非原子安装」是结构性的：

```
tweak-repro/Tweak.xm:1723  cRows   = REAOwnerClass(vc, "tableView:numberOfRowsInSection:")
tweak-repro/Tweak.xm:1724  cCell   = REAOwnerClass(vc, "tableView:cellForRowAtIndexPath:")
tweak-repro/Tweak.xm:1725  cSelect = REAOwnerClass(vc, "tableView:didSelectRowAtIndexPath:")
tweak-repro/Tweak.xm:1726  cHeight = REAOwnerClass(vc, "tableView:heightForRowAtIndexPath:")
```

四次独立解析，四个 owner **必然落在不同类**（`host_index.json` 实测：`BDSettingViewController` 自有 108 个方法，`tableView:heightForRowAtIndexPath:` 在自有表（`d32@0:8@16@24`），而 `numberOfRowsInSection:` / `cellForRowAtIndexPath:` / `didSelectRowAtIndexPath:` **都不在**；全库 owner 计数 rows 226 类 / cell 225 / select 176 / height 175）。一旦 `rows` 装上而 `cell` 没装上（或反之），"行数 +1"与"cell 来源"分属两个类 → 宿主用自己的数据数组索引到第 N 行 → 越界或空 cell → 卡死/闪退。这条不修，"加幂等哨兵"完全没用。

> **因此 v1.2 里"四个 owner 必须全等且 == BDSettingViewController"的契约被本版删除：它在真实宿主上永不可能成立，照做只会让 T0 永不安装、静默降级 T1。** 新契约见 §3.2.2。

### 1.3 行为默认值本身就是一个 P0 触发器

`REAFlag` 语义是 `nil → YES`（`tweak-repro/Tweak.xm:399`），即**默认全开**。这意味着：修完 Bug A 推出新包，用户第一次冷启动就直接命中“强拦截档”——如果修复方案本身有瑕疵，症状与现在完全一样，且会被误判为“没修好”。所以 **P0-A 必须连带做一次配置迁移**，否则等于没修。

> **迁移目标值已由 v1.3 改写**：v1.2 写的是“首次启动写入 `purify_splash_mode = 1`（档 1）”，但审核证实**档 1 本身就会丢回调**（见 §3.1.1 L3），所以迁移目标改为 **`purify_splash_mode = 0`（档 0：全关 + 只跑观测）**，之后由真机二分找到安全档位再上调。这条改变整个 P0-A 的交付观感，必须最先告知用户：**v13.0 会重新看到开屏广告，但不会再卡在启动图。**

---

### 1.4 M-1 / 取证前置闸门（**不通过则不得开 M1**）

审核员给出的一条阻断级发现，我复核后采信：**本计划全部根因假设（H1–H4、D1–D9 含 D3b/D3c）目前没有一条一手证据**。

| 声称的证据 | 实测 |
|---|---|
| “v12 真机日志里有 `[Purify] 锚点安装 ok=N`、四行 owner” | 工作区**没有**这种日志。唯一的 `D:\DeepSeek\hush\BluedHushREA.log`（645 行）是旧版本：`pass[main+2s] ok=34 miss=28`、`[Purify]` 命中 **0 次**、`[SettingsEntry]` **0 次**，末行 `2026-10-30 02:43:23` |
| “有崩溃报告可以定位栈” | 工作区 `.ips` 数量 = **0** |
| `host_index.json` 是 v12 宿主导出 | 未验证 |

所以 M-1 只干一件事：**收集三样东西**（一次性，半天）：

1. **v12 产物真机跑一次的完整日志**，必须含：`[REA] hooks ok=? miss=?`、`[Purify] 锚点安装 ok=? miss=?（共 ? 条）`、`[SettingsEntry] rowsOwner=? cellOwner=? selectOwner=? heightOwner=?`、以及卡住前的最后 20 行；
2. **卡启动图那一刻的 `.ips`**（`termination` 字段 + 主线程栈）；设闪退若是 watchdog 杀，`.ips` 里会写 `0x8badf00d`，这本身就足以区分“卡死”与“崩溃”；
3. **复现步骤**：冷启 / 已经历过什么页面 / 是否二次进入设置页 / 是否首次安装。

> 为什么把它卡在 M0 之前：没有 `.ips` 就无法区分“卡”与“崩”，而这两者的根因几乎不重叠（前者=主线程阻塞/看门狗，后者=方法表错乱/越界）。D1–D9（含 D3b/D3c）与 H1–H4 全部是读代码推出来的，可以作为“排查目录”存在，但**不得据此排构建矩阵**——否则会在一个猜错的根因上花掉 4–6 个构建。
>
> 如果真机取不到（比如用户已卸载、LiveContainer 日志已轮转），就用 v13.0（只装观测骨架 + 净化 splash 全关）当取证工具跑一次，直接拿到数据。**这是本计划唯一允许的“先上线再定位”情形**，因为它不改任何行为。

---

## 2. M0 / P0.0：观测骨架（第一批构建，必须先合）

目标：把"卡了/闪了"变成可定位的数字。全部内容都是**新增旁路**（O7 例外，它是纯内部重构、不改语义），不改任何现有拦截逻辑，风险最低。

> **以下“——M0 范围收敛——”与 O4 约束为本段正文，接上。**

> **M0 范围已按审核员建议收敛**：第一批只做 **O1b + O4 + O5 + O6 + O7**（采样、落盘、kill switch、导出、热路径重构）。O1/O2/O3 推到 M1 一起上，因为它们只在“已经能区分启动段”后才有意义，早做等于多一次全量真机验证。
>
> **O4 的实现约束（审核员指出的自伤风险）**：现行 `REALog → REATraceSink`（`Tweak.xm:179`）**每行都 `fopen/fputs/fclose`**，而 `PLogHit`（`:1293`）与 `rea_viewDidMoveToSuperview`（`:1588`）每次命中都写盘——观测层自己会成为新的卡顿源。M0 必须先改成**常驻 `FILE*` + 定时 flush（或固定大小缓冲）**，再叠环形缓冲。这条不改，O1b 的 200ms 阀值会被日志 I/O 自己拖点。

| ID | 组件 | 契约 | 为什么必须有 |
|---|---|---|---|
| O1 | `REAStage(const char *name)` | 记录 `CFAbsoluteTime` 到固定槽位；`REAStageDump()` 在首帧后一次性打印 `ctor→install→purify→settings→firstFrame` 各段耗时 | 判断"卡"发生在启动期哪一段；区分启动卡与进设置页卡 |
| O2 | `REAReentry` 护栏 | 每个 wrapper 入口 `REAEnter(sel)` / `REAExit()`：线程局部递归计数，`depth > 8` 时打日志并**直接调原实现** | 对 LiveContainer 双注入、宿主回调我们、我们回调宿主造成的环，一律兜底（同时把 D2 的后果从"栈溢出闪退"降级为"打一行日志"） |
| O3 | `REAWatchdog(name, sec, block)` | 单例 `dispatch_source` 定时器池；同名看门狗重复注册即覆盖 | P0-A 的 fail-open 与 P0-B 的熔断都靠它 |
| O4 | 环形日志 | 保留最近 64 条 `[REA-Test]`；`NSSetUncaughtExceptionHandler` **链式**保留宿主 handler（只记录不吞） | 闪退时最后一次写盘往往丢，环形缓冲能在下次启动 salvage |
| O5 | Kill switch 注册表 | `rea_kill_<module>` 一组 key，集中在一个**隐藏诊断页**（不进 105 项菜单）：长按悬浮球 3 秒进入 | 真机现场关功能，不用重打包；也是所有二分的操作手柄 |
| O6 | 命中导出 | 长按悬浮球 →「导出诊断」→ 把环形日志 + `kPViewRules` 命中 Top20 写到 `Documents/` | 解决"某正常视图消失"无从定位的问题（§3.4 已知隐患） |
| **O7** | **开关快照 + 行表预计算（D9 的修法，归 M0）** | 安装时把所有 key 的 `NSString` 缓存一次；所有 trampoline 命中只读 `BOOL gPOn[]` 快照数组；快照在「面板写入 / `NSUserDefaultsDidChangeNotification` / 回到前台」三个时机重建；`PRowFor` 改成预计算静态表 + 无锁类指针哈希 | 现在每个热路径调用都在新建 `NSString` 并读 CFPreferences，而 `PK_VIEW` 是全 App 每视图必走；不先在 M0 消掉它，后面所有“卡不卡”的阈值都是在噪声上测的。**它不改任何语义**（仍然“改了开关立刻生效”，因为三个重建时机覆盖了面板写入与回前台） |

**DoD（M0）**：
- **门禁口径必须带轮次，禁止裸写 `ok=36 miss=0`**（审核 B3）：`REAInstallPass` 每轮开头就 `gREAOK = 0; gREAMiss = 0`（`Tweak.xm:1943`），而 `REAInstallHooks` 末尾串了设置页 4 次 + 净化 56 次 `REASwap`（`:1697-1703`），后台队列每进程共 **6 轮**，六轮数值各异。所以 M0 先做的是**把 v12 的真实轮次数字抄成基线**（见 §1.4），然后：`pass[main+2s]` 的 ok = 36（核心 hooks）+ 4（设置页，若 armed）+ 净化成功数；**miss 允许 > 0，但必须输出 miss 名单（类名+选择子）**。一个永远为 0 的 miss 不是稳定，是没测。
- `[Purify] 锚点安装 ok=M miss=N（共 56 条）` 中 **M+N = 56** 且业务行 miss 逐个有类名入 circular log（4 条基础设施行允许 miss）；
- 启动总耗时与 v12 差值 < 30ms（同一设备、同一网络状态、冷启三次取中位数）；
- 诊断页可进可关，kill switch 逐个拨一次行为可观测；
- 冷启动 10 次无新增崩溃（每次前 `kill` 进程 + 清 LiveContainer 缓存目录，否则不是冷启）；
- **O1b 主线程阻塞采样必须先于其他所有指标生效**：`CFRunLoopObserver`（`kCFRunLoopBeforeSources` / `kCFRunLoopAfterWaiting`）打点，> 200ms 记一条入 circular log。M1/M2 的所有"不卡"判据都引用它，而不是靠手感；
- **O7 落地后必须证明“语义未变”**：旧版 `REAFlag` 是每次现读，新版是快照——所以验收里要专门测“面板拨开关后，**不重启**、立即生效”，三个重建时机任一缺失就会在这里暴露。

---

## 3. P0 修复

### 3.1 P0-A：开屏净化 → 卡启动图

#### 3.1.1 把 19 条锚点拆成 6 个可独立验证的层（并按“是否丢回调”分族）

现在的设计把 19 条锚点绑在同一个 key 上，只要其中一条有毒就整体不可用，也无法二分。改造为分层（**层是内部分组，用户侧仍是 1 个开关 + 1 个档位**）。

**分类维已改：不是按“观感破坏度”排序，而是按“是否丢弃宿主传进来的回调/对象”**（审核 B2）。理由：卡启动图的元凶很可能就是“回调被丢掉”——宿主在等一个永远不会来的 `finished` / `completion`，而我们的 wrapper 直接 `return` 了。所以它必须是第一分类维：

| 族 | 含义 | 默认策略 |
|---|---|---|
| **单·纯返回值** | wrapper 只改返回值，**不接收也不丢弃任何回调参数** | 可直接开（仍需真机验状态机） |
| **甲·丢回调** | 签名里有 block / handler / completion / target-action，而拦截分支**不调它** | **默认全关**；开启前必须有“补投 + 一次性 token + 看门狗”三件套 |
| **乙·状态不一致** | UI 树被改得与宿主内部状态不一致（隐藏但未移除） | **默认全关**，只能当诊断工具 |

逐层落位：

| 层 | 锚点 | 语义 | 族 | 默认 |
|---|---|---|---|---|
| **L0 闸门** | `AppDelegateModel -isNeedShowSplashAd` (PK_B0) | 告诉宿主“没有开屏” | 单（无回调参数） | 关（风险在状态机：门可能永不开） |
| **L1 数据源** | `-showSplashAd:` `-getSplashAdForColdLaunch` `-p_getSplashAdvertisementForColdLaunch` | 不给素材（返 nil/空） | 单 | 关（宿主可能在等一个不来的 model） |
| **L2 状态机** | `BDIndexPageCoversManager` 8 条 `show*Splash*finished:` (PK_VSPLASH_A/B) | 拦截并**自己推进 finished** | **甲（丢 finished）** | 关（需三件套） |
| **L3 聚合展示** | `ABUSplashAd -showInWindow:` `-showInWindowWithBlock:` `BDSplashVideoAdViewController -presentInViewController:` | 广告展示层不落地 | **甲（丢 block）** | **关** |
| **L4 素材/容器** | `BDGDTSplashAdManager -showGDTSplash` `BDKSSplashAdManager -showKSSplash` `BDADX_Blued_Splash_Image_ViewController -presentBluedSplashImageViewController` `BDADXBaseSplashAdManager -assembleSplashContainerView:needRemoveHandler:` (PK_O2O) | 不组装容器、不拉 SDK | 单（前3条）/ **甲（PK_O2O 丢 needRemoveHandler）** | 前3条关（待验）、**PK_O2O 恒关** |
| **L5 视图兜底** | `kPViewRules` 中 `purify_splash_ad` 的 5 条（`SplashAd` / `SplashImage` / `SplashVideo` / `SplashContainer` / `ADXSplash`） | 命中即 `hidden=YES` + `alpha=0` + 高 0.5 | **乙** | **audit only** |

**v1.3 默认 = 档 0：L0–L5 全部不生效，L5 只记日志。**

> **这条默认值是 v1.2 最大错误的修正，必须说清楚。** v1.2 把“档 1 = L3 + L4（不含 PK_O2O）”当作安全默认，理由是“L3 宿主完整走完自己的 finished 流程，天然 fail-open”。**这个理由已被代码推翻**：`kPInstall` 里 `ABUSplashAd showInWindowWithBlock:` 映射到的是 `PK_B1O`（`Tweak.xm:1379-1384`），而它的拦截分支是：
>
> ```objc
> const char *k = PKeyFor(self, _cmd);
> if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 NO"); return NO; }   // ← 参数 a（那个 block）从未被调用
> ```
>
> 也就是说 L3 **和 L2 是同一个病**：带回调、不调回调、直接 return。`PK_B2O`（`:1386`）也是同一个模子，`PK_O2O`（`:1407`）则是“返回 nil 而丢掉 `needRemoveHandler`”。把 L3 当默认开，等于把卡启动图的同一个 bug 换一个锚点重新引入一次。
>
> 另一个原因是审核指出的 L5：`rea_viewDidMoveToSuperview`（`:1588`）只 `hidden/alpha/height`，**不 `removeFromSuperview`**；如果容器移除靠“展示完成回调/最短展示计时”，而我们又切了回调链上游，那容器就永远压在 window 上 → 白屏或永远停在启动图。**这也是为什么“不能改成 removeFromSuperview”**：在 `didMoveToSuperview` 里移除会改变宿主正在枚举的视图树，且会让后续 `finished` 回调向一个已脱离 window 的容器做动画——我们没有任何信息能保证它安全。不确定就“不碰”，没有第三条路。
>
> 代价很明确：**v13.0 用户会重新看到开屏广告。** 这是“先让 App 能用”的诚实交付，不是退步；去广告靠 M1 的真机二分找到能安全开启的最大层集合后再收回。

#### 3.1.2 四档语义（用户可见）

| 档 | 组成 | 适用 |
|---|---|---|
| **档 0 · 观测（M1 默认，先发这个）** | L0–L5 全部不生效；L5 audit；O1b/O4/O6/O7 全开 | 所有人。**广告回来了，但不会再卡在启动图** |
| **档 1 · 纯返回值拦截** | L0 + L1（都是无回调参数的族“单”） | 真机验证 B-A3/B-A6 通过后 |
| **档 2 · 展示层拦截** | 档 1 + L4 前3条（不含 `PK_O2O`）+ L3（L3 必须先完成三件套） | 需先证 B-A2 / B-A4 不卡 |
| **档 3 · 强拦截** | 档 2 + L2 + `PK_O2O`（全带三件套 + 看门狗） | 仅诊断页可选 |

配置键：`purify_splash_mode`（0/1/2/3）。**迁移规则（v1.3 再次修正）**：

- 首次启动（`purify_splash_mode` 不存在）**写 `purify_splash_mode = 0`**（v1.2 写的是 1，已废）；
- **绝对不碰 `purify_splash_ad`**——它是用户自己拨过的开关，改它就是覆盖用户意图；
- 读取侧用一张兼容矩阵决定实际生效档位：

| `purify_splash_ad` | `purify_splash_mode` | 实际档 |
|---|---|---|
| `NO`（用户显式关过） | 不存在 | **档 0** ← 尊重用户 |
| `YES` / 未设（默认） | 不存在 | **档 0** ← 迁移后的默认（v13.0） |
| 任意 | 0/1/2/3 | 取 `mode`（显式设置优先） |

- 迁移只做一次，写 `rea_migrated_splash_mode_v2` 标记（**换标记名**：v1.2 若已发过测试包，旧标记会让新默认不生效）；
- **发布说明必须写**：v12 用户升级后开屏净化从“全开”降到“档 0”，这是有意的降级，目的是先让 App 能启动。
- **注意档位只管 splash 组**：其余 25 个净化 key 的行为不受影响，照旧生效——否则用户会感知到“整个助手都变弱了”。

#### 3.1.3 甲族（丢回调）的正确形态（契约，档 2 起才启用）

L2 / L3 / L4-`PK_O2O` 三条共用同一套机制。**不改的就一条：永远不在宿主还没 return 的同一栈内调用宿主传进来的回调。**

**三段状态机（审核 B4 修正：v1.2 的“补投 + 看门狗”两路没有互斥）**：

```
pending ──(0.05s 后补投成功)──► delivered ──(看门狗未触发)──► done
t   │                              │
   └──(看门狗触发)──► origTaken ◄───┘（互斥：已 delivered 就绝不再调 orig）
```

1. 进入 wrapper → `REAEnter` → 查该 `self` 的 assoc 标记 `rea_splash_state`；
2. 已是 `delivered` / `origTaken` → 打 `[Purify] 重复回调拦截` → **直接 return**；
3. `pending` → **`Block_copy` 回调后**置 `delivered` → `dispatch_after(0.05s, main)`，块内 `REAExit` 后 `call(blk)(YES)`，随后 `Block_release`；
   > v1.2 写的是直接把 `id finished` 强转成 block 再 `dispatch_after`——**没有 `Block_copy`**，而 ARC 下栈 block 可能已出栈，延迟 0.05s 后调用是 use-after-free。现行同步调用（`Tweak.xm:1354`）不出问题正是因为它是同步的；**一旦改成异步，`Block_copy` 就是强制项**。
4. 进 `delivered` 的**同一个时刻**注册 `REAWatchdog("splashL2", 3.0)`；进入 `delivered` 时必须**主动注销**该看门狗（否则“已完成”与“已超时”两条路径会同时生效，就是 B4 指的双跑）；
5. 看门狗触发（T+3s `keyWindow` 顶层仍是 splash 容器类）→ 打 `[Purify] splash 看门狗触发，fail-open` → **仅当状态仍为 `pending`** 才调原实现一次，并置 `origTaken`；
6. `PK_B0`（L0）单独：返回 NO 之后，**不要**再去补调已返回的原方法（那样用户会看到"进了首页以后突然弹一个开屏广告"）。改为：看门狗只**打开后续放行闸**——置 `rea_splash_gate_open`，之后 `PK_B0` 遇到该标志直接走原实现；已错过的那一次就让它错过。失败判据也随之改变：从"首帧没出来"变成"首帧后 10s 内仍检测不到主页容器"。

> **看门狗参数全局统一为 3.0s**（v1.2 正文写 3.0s、§10 Q7 里又写“已改 5s/1s”，自相矛盾）。选 3.0s 的理由：开屏广告最短展示通常 3–5s，看门狗必须在用户感知“卡住了”之前就动手，且必须早于系统 watchdog（20s 级）；5s 太晚、1s 会误杀正常慢网络。

> 核心原则复述（红线 5）：**宁可看到广告，也不能卡死启动。** 所有档位共用同一个看门狗组，超时即降级。

#### 3.1.4 二分矩阵（真机 6 分钟定位）

> **⚠️ 下表标题里的"每格一个构建"已被本版推翻，以此段为准。** 7 格×1 构建 = 7 次 push/CI/安装，与 §9 R7「每批 ≤ 2 次 push」及 M1 工期直接矛盾。正确做法：**每格优先用同一构建 + 诊断页切档（O5）完成，不重新打包**。真正的构建只在"需要代码级差异才能分出"时发生——本版只有 1 个这样的格（见下表末行）。即 M1 最少只需 2 次构建：B2 = 分层 + 诊断页 + L5 降 audit；B3 = 迁移与文案。二分矩阵降为"第一次构建就要把 8 个开关都暴露在诊断页"的需求。

| 格 | 开关配置 | 若仍卡 → 结论 |
|---|---|---|
| B-A0 | 全部 L0–L5 关（kill switch 全灭） | 卡因不在净化引擎，回到主线核心 hooks 排查。**这一格就是 v13.0 的出厂态，所以它是必验项** |
| B-A1 | 只开 L5（hard） | L5 视图规则误伤（预计命中） |
| B-A2 | 只开 L3 | 展示层丢 block 破坏流程 |
| B-A3 | 只开 L4（含 `PK_O2O`） | `assembleSplashContainerView` 返回 nil 是元凶 |
| B-A4 | 只开 L4（不含 `PK_O2O`） | 定位到 GDT/KS/ADX 某一条 |
| B-A5 | 只开 L2（新实现，三件套 + 看门狗） | 看门狗没兜住 → 检查容器类名匹配、状态机是否卡在 `pending` |
| B-A6 | 只开 L0 / 只开 L1 | 闸门假设成立（即 H4） |
| B-A7 | 需把 L5 从 hard 改 audit 才能真正区分（v12 里 L5 就是 hard） | 这是唯一需要代码级差异的格 → **1 次新构建** |

**顺序改了**：v1.2 从“只开 L5”开始（因为当时默认 L5 是开的）；v1.3 因为出厂是档 0，矩阵首格变成 B-A0（验证“什么都不开就不卡”），这是判断“到底是不是净化引擎干的”的唯一硬证据，必验。

每格只需冷启动一次（每次先 `kill` 进程 + 清 LiveContainer 缓存）。全部格都过 → 再验证"全开"组合。**任何一格出现"看门狗触发"或 > 200ms 阻塞打点，该格判不通过，不得以"再多试一次就好了"放过。**

#### 3.1.5 DoD（M1）

- **档 0（出厂态）：冷启动进首页连续 10 次 0 失败**，且 O1b 无 > 200ms 阻塞打点。这一条不过，其他都不用谈；
- 档 1 / 2 / 3 各冷启 10 次，**任一格出现看门狗触发或 > 200ms 打点即判不通过**；
- `[Purify] splash 看门狗触发` 出现次数 ≤ 1/10 次（出现即说明有层在拖，需记档）；
- 日志出现 `[Purify] 重复回调拦截` 说明 A2 真实存在，必须保留该护栏；
- **二分结论必须写成表进文档**：哪一层可以开、哪一层不能，而不是“调好了”。

### 3.2 P0-B：设置页注入 → 卡死/闪退

#### 3.2.1 缺陷台账（全部来自阅读 `tweak-repro/Tweak.xm:1031-1160` 与 `:1711-1760`）

| ID | 缺陷 | 机制 | 证据位置 | 修法 |
|---|---|---|---|---|
| **D1** | 四钩**非原子**安装 | 四个 `REAOwnerClass` 独立解析，owner **必然不同类**（见 §1.2）；rows 生效而 cell 未生效（或反向）→ 行数 +1 与 cell 来源不一致 → 宿主数组越界/空 cell | `Tweak.xm:1723-1726`、`:1728-1740` | **全有或全无 + 回滚事务**（不再要求 owner 全等；具体契约见 §3.2.2） |
| **D2** | **多轮安装的写读竞态**（v1.2 写的“重复 dlopen 自递归”已被证伪） | `REASwap` 缓存命中即返回原 IMP（`Tweak.xm:307-309`），重复 pass 幂等，**不存在递归路径**。真实问题是：后台队列每进程跑 **6 轮** `REAInstallPass`，写 `gPRowClass/gPRowOld/gPTrimmedRows/p_setting*`，而主线程 trampoline 同时读，**全程无锁**；`POld` 为 NULL 时 trampoline 不调原实现 → 随机“某方法被吞”。`PRowFor` 的 memo 也无同步（`static Class gMemoCls`） | `Tweak.xm:301-330`、`:1258-1290`、`:1943-1996`、`:2016-2026` | ① 安装期置 `gREAInstalling` 闸：闸开时所有 trampoline **直走原实现**；②或把安装全部挤到主线程串行（推荐，代价小）；③安装完成后再统一发布 `BOOL gPOn[]` 快照（与 O7 同一机制）。**删掉 v1.2 的“判 old == 本 wrapper”修法**——它治不了竞态，改完仍不知真因 |
| **D3** | `height` 回调**无 VC 门控**，且裁剪集合**全局无 VC 维度** | `rea_settingsHeight` 中 `if (PIsTrimmedRow(ip)) return 0.0;` 位于 `REAIsSettingVC(self)` 判断**之外**（`Tweak.xm:1110`）。而 `gPTrimmedRows` 存的是纯 `"%ld-%ld"`（section-row）字符串，在 `PShouldTrimSettingCell` 里**按实际渲染过的行不断写入、永不清空、不带 VC 信息**。合起来的后果：**用户只要看过一次设置页，之后全 App 任何 tableView 的 section 0 第 0–10 行都会被压成 0 高度** | `Tweak.xm:1110`、`:1620-1647` | 三条：① `REAIsSettingVC(self)` 先行短路并作为 `PIsTrimmedRow` 的前置条件；② 裁剪集合改成 `{VC类名 → NSIndexSet}` 或直接改为**不存储**、只在 cell 配置时现场判定；③ `armed == YES` 才允许生效 |
| **D3b** | **`cell` 钩也无 VC 门控**（审核 I1，v1.2 漏了） | `@try { PShouldTrimSettingCell(cell, ip); }`（`Tweak.xm:1100`）在哪个 VC 都跑；而 `PShouldTrimSettingCell` 只判 `POn("purify_set_items")` + 标题 `containsString`。因为 cell 钩必然落在父类上，所以**全 App 任意表格里标题含“认证/实名/直播/扫一扫/关于/清除缓存”等词的 cell 都会被 hidden+alpha0** | `Tweak.xm:1100`、`:1610`、`:1622-1640` | cell 分支同样加 `REAIsSettingVC(self)`；trim 判定降为“仅设置页生效” |
| **D3c** | **读写跨阶段**（审核 I3）：height 先算，trim 集合在 cell 阶段才写入 | 写点唯一在 `PShouldTrimSettingCell`（由 cell 钩调）；读点在 height。首次进入时 height 跑得比 cell 早 → **首帧高度与 cell 状态跨帧不一致**，中途也无 `reloadData` | `:1100` / `:1110` | 把 trim 判定**前移到 `numberOfRows`**（数据侧定行数），height 只查结果。这也顺带解决了“集合什么时候完整”的问题 |
| **D4** | 高度回调**每次调用都读一次宿主行数**（v1.2 的理由写错了，已按审核 I6 改正） | 真正的重活不是“建 label”（`PIsTrimmedRow` 根本不建 cell、不取 label），而是 `rea_settingsHeight` → `REAIsOurEntryRow` → `REASettingBaseRows` → **`p_settingRows`（调宿主自己的 `numberOfRowsInSection:`）**，叠加 `POn("purify_set_items")` 每次的 `NSString` 分配 + CFPreferences 读。设置页 26 行×滚动一遍 = 上千次宿主调用 + 偏好读，全在主线程 | `Tweak.xm:1048`、`:1083`、`:1110` | 见 **D9**（统一修法，不只针对设置页）+ 把 `REASettingBaseRows` 的结果缓存到本次 `reloadData` 周期 |
| **D5** | wrapper 异常边界**不齐**（v1.2 写“三个全裸奔”不准） | `cell` 钩**有** `@try`（`:1100`）；而 `rows`（`:1190` 左右）、`height`（`:1103-1110`）、`select`（`:1115`）**三个均无**。宿主抛异常直接冒泡主线程 → 闪退 | `:1100` vs `:1103`/`:1115` | 三个 wrapper 各包 `@try/@catch(NSException *e)`，catch 内**调原实现**（fail-open），并记日志 |
| **D6** | 无 kill switch（且“有开关”是假的） | `gREASettingsEntryOn` 声明为 `static BOOL = YES`（`Tweak.xm:1021`），**全文零赋值点、也不读 `REAFlag`**。所以“设置页入口可关”只是一句注释 | `Tweak.xm:1021`、`:1083` | 改为**每次现读** `REAFlag("rea_kill_settings_entry")`（读语义；先不改缓存，因为它在交互路径不在热路径）；splash 组同样补一个 `rea_kill_splash` |
| **D7** | 启动期同步注入 | ctor 内同步做 4 次 `class_copyMethodList` + swap，与宿主首帧 UI 竞争 | `:952` | 改为 `dispatch_after(2.0s, main)` 安装（`REAInstallHooks` 只登记） |
| **D8** | 备用按钮**覆盖**宿主 barButtonItem | `REAAddSettingsNavButton` 无条件写 `navigationItem.rightBarButtonItem`，宿主若依赖原按钮（保存/编辑）→ 功能丢失或崩溃 | `Tweak.xm:1140-1155` | 只做 `rightBarButtonItems` **追加**（`arrayByAddingObject:`），且仅在数组里没有"助手"时；异常全部吞掉 |
| **D9** | **热路径开关读取零缓存**（跨模块，不只 P0-B） | 每个 trampoline 入口都走 `POn(key)` → `REAFlag` → 新建 `NSString` + 读 `NSUserDefaults`；而 `PK_VIEW` 被装在 `UIView -didMoveToSuperview` 上，是**全 App 每个视图都走**的路径。同时 `PRowFor` 只用一条全局 memo（`gMemoCls/gMemoSel/gMemoRow`，`Tweak.xm:1265-1287`）且**无任何同步**，memo 不命中就退化为「类链×56」线性扫描。两者叠加 = 全 App 级的主线程税，也是“整个 App 卡但找不到单一卡点”的最佳解释 | `Tweak.xm:1186-1189`、`:399`、`:1265-1287` | ① 每行在**安装时**一次性缓存 `__unsafe_unretained NSString *`（不用每次 `stringWithUTF8String`）；② 改为 C 数组快照：面板写入时/`NSUserDefaultsDidChangeNotification` 时重算 `BOOL gPOn[]`，命中路径**零分配、零 CFPref 读**；③ `PRowFor` 改两级缓存（`CFDictionary<类指针, 行位图>`）或直接改成预计算的 `class → {sel → row}` 静态表，消掉全局可变 memo。**这条必须在 M0 就做**（它不改语义，只降开销），否则后面所有“卡不卡”的验收都基线不准 |

#### 3.2.2 原子安装契约（**v1.3 重写：不再要求四 owner 全等**）

```
armed = 四条各自 REAOwnerClass 都拿到非 Nil 的 owner
      && 四条 swap 全部返回非空且非本 wrapper 的 old

（仅作日志的可行性检查，不作门禁：
   日志四行 Owner 必然不全等——height 在 BDSettingViewController 自有表，
   其余三条在父类。这是宿主结构，不是缺陷。）
```

- `armed == YES` → 四个 wrapper 按设计生效；
- `armed == NO` → 四个 wrapper 立即 `return 原实现`（不发一行多余逻辑），日志写 `[SettingsEntry] 原子安装失败（原因 + 四条 owner + 失败的那一条）→ 降级到 T1`；
- **禁止**"三个生效一个不生效"的中间态；
- **不再要求 owner 同类**：宿主把 height 写在子类、把 rows 写在父类是完全合法的 ObjC 结构。真正的风险不是“owner 不同”，而是“**同一实例上，行数与 cell 来源不一致**”——那个只能靠事务+回滚+熔断兜，不靠类相等断言。

> 这一条是审核 B1，也是本次审核最有价值的一条：v1.2 的契约在真实宿主上**永不可能成立**，照做会让 T0 永不安装、永远静默降级 T1，而验收项永远红。

**但仅仅“检完再装”不够——swap 本身带副作用。** 安装必须写成**带回滚的事务**：

```
1. 先做完全部前置校验（四个 owner 非 Nil、kill switch）→ 任何一条不过就不开始
2. 依次 swap，把 (类, 选择子, oldImp, 缓存key) 压进回滚数组
3. 四条全成功 → armed = YES，发布 gPOn[] 快照
4. 任一条失败 → 按相反顺序 method_setImplementation(类, 选择子, oldImp) 逐个回滚，
   并且**同步做三件清理**：
     a) 从 gREAOrig 里删掉该 key（否则 REASwap 的“已装过”缓存会让下次武装永久 skip，
        见 Tweak.xm:307-309）
     b) p_settingRows/Cell/Select/Height 全部置回 NULL（否则 REAIsOurEntryRow 的 NULL 守卫失真）
     c) gPRowOld/gPRowClass 对应位置复位（否则 POld 还指着已回滚的 IMP）
5. 回滚本身也失败（极罕见）→ 记 [SettingsEntry] 回滚失败（类/选择子/IMP）
   → armed = 0 且**不再重试**，直接定在 T1
```

**回滚后必须能再次武装成功**——这条得写成一个测试用例（故意让第 4 条 swap 失败 → 回滚 → 重读开关 → 再武装必须成功）。理由：v1.2 的回滚方案漏了 `gREAOrig` 缓存，一旦回滚过就真的再也装不上了（审核 B6）。

#### 3.2.3 熔断与降级链

| Tier | 入口形态 | 触发条件 |
|---|---|---|
| T0 | 设置页第 0 组末行「插件设置」 | 原子安装成功 |
| T1 | `BDPrivacySettingViewController` 导航栏「助手」按钮（**追加式：用 `leftBarButtonItem` 或只往 `rightBarButtonItems` 数组里插，不覆盖**） | T0 失败 |
| T2 | 悬浮球单击（v12 已可用） | 恒可用，最终兜底 |

> T1 改追加的理由（审核 I7）：现行 `REAAddSettingsNavButton`（`Tweak.xm:1140-1155`）无条件写 `vc.navigationItem.rightBarButtonItem = ...`，这是**直接覆盖**。宿主隐私设置页若自带右侧按钮（完成/保存），直接丢功能。

熔断：`armed` 生效后注册 `REAWatchdog("settingsEntry", 3.0)`（**与 splash 组同一参数 3.0s**，全文只允许一个值）；宿主 `viewDidAppear` 后仍未触发 → `armed = 0` + 记 `[SettingsEntry] 熔断：3s 未完成首帧` + **不调 `reloadData`**（避免二次伤害，只 disarm）。

**熔断后必须有恢复路径**（审核 I7）：`armed = 0` 只在**本进程**内有效；重启后重新尝试一次武装（不永久黑名单）。理由：一次死锁可能是时序偶发，永久封禁等于把一个偶发问题变成永久功能缺失。若连继 3 次冷启都熔断，才写 `rea_settings_entry_blacklist` 并在诊断页标红。

#### 3.2.4 二分阶梯

> 同 §3.1.4：**默认全部通过同一构建 + `rea_kill_settings_entry` 与一组子开关（`rea_kill_settings_rows/cell/height`）在真机上切**，不重新打包。下表的“构建”列只是说“如果必须分开代码才能分出”——实际上 B-B1..B-B3 需要子开关而非重构建。

| 构建 | 配置 | 目的 |
|---|---|---|
| B-B0 | `rea_kill_settings_entry=1`（全关） | 确认"设置页本身不崩"，排除宿主/其他 36 hook |
| B-B1 | 只装 rows（cell/height/select 装不上就 return 原实现） | 若崩 → 行注入路线整体放弃，直接定 T1 |
| B-B2 | rows + cell + height（select 走原实现） | 若崩 → 定位高度/行数不一致 |
| B-B3 | 全装，`purify_set_items` 强制关（`PShouldTrimSettingCell` 直接 return） | 隔离 trim 联动 |
| B-B4 | 全装 + trim 开 | 闭环 |

#### 3.2.5 DoD（M2）

- 设置页进入 → 停留 60s → 上下滚动 20 次 → 返回 → 再进入，循环 10 轮不崩不卡（O1b 无 > 200ms 打点）；
- `插件设置` 行可点开面板；
- **四行 owner 必须存在但不要求相等**——验收改成“四个值都非空且与 `host_index.json` 记录一致”，不得再写“四 owner 全等”（那条永不可能通过）；
- **回滚负向测试通过**：人为让第 4 条 swap 失败 → 日志出现回滚成功 → 重读开关后再次武装成功；
- 崩溃时 `.ips` 无 `CALLING_SOME_+initialize_METHOD` 栈帧。

---

## 4. P1：净化组 26 开关收口

### 4.1 批次划分

| 批次 | 内容 | 构建数 | 依赖 |
|---|---|---|---|
| **P1.1** | 12 个弱实现 → 数据源级锚点（每次 6 个 key） | 2 | M2 完成 |
| **P1.2** | 6 个 `switch_*` 遗留（§4.1-D） | 3（两两一构建） | P1.1 |
| **P1.3** | `kPViewRules` 治理 v2（分层 severity + 命中审计） | 1 | P1.1 |
| **P1.4** | `purify_set_items` 与设置页解耦（当前与 P0-B 强耦合） | 1 | M2 |

### 4.2 弱实现升级规程（12 个 key 的统一方法论）

对每个弱 key 走同一条四步，**不许跳步、不许猜签名**：

1. **候选生成**：`python _work/mine_anchors.py <语义词>` 从 `analysis/host_index.json`（14,839 类 / 264,012 方法条目）筛出 `{类, 选择子}` 候选；
2. **签名验证**：`python _work/owner_resolve.py <类> <选择子>` 拿到真实 `typeEncoding` 与 owner；`{`/`^`/`"` 开头直接排除（交接书 §2.7 分型规则）；
3. **调用点确认**：`python _work/inject_probe.py <addr> <len>` 反汇编确认该选择子确实在目标视图/数据流上被调用（不接受"类名像"作为证据）；
4. **分型落地**：按返回类型选 `PK_B0 / PK_V0 / PK_V1O / PK_V2O / PK_ARR1O / PK_D0 / PK_VD …`，写进 `kPInstall`（走 `gen_purify.py` 重新生成，**不手改**）。

候选方向（**待第 2 步验证，未验证前不得拷进 `kPInstall`**）：

| key | 候选类/入口 | 首选 anchors 形态 |
|---|---|---|
| `purify_map_guide` | `BDNearbyMapGuideView` / `BDMapGuideManager` | 数据源 `-setGuideModel:` 或 `-showGuide` → PK_V1O / PK_V0 |
| `purify_svg_ad` | `SVGAPlayer -play` / `BDAdSVGView` | PK_V0（拦播放） |
| `purify_new_nav_tag` | `BluedTabBar -setBadgeValue:atItemIndex:`（已在核心 36）/ `BDBadgeManager` | 已有 `rea_setBadge`，只需把 key 门控接上（**这是最短路径，先做**） |
| `purify_call_header` | `BDCallHeaderView` / `BDVoiceCallHeaderView` | PK_V1O |
| `purify_session_card` | `BDSessionCardManager` / `BDSessionTopCardView` | PK_V1O |
| `purify_welcome_pop` | `BDWelcomeRewardManager` / `BDADXWelcomePopManager` | PK_V0 / PK_V1O |
| `purify_follow_card` | `BDFollowGuideManager` / `BDFollowTipView` | PK_V1O |
| `purify_chat_emoji` | `BDChatBigEmojiView` / `GJIMEmojiProcessor` | PK_V1O |
| `purify_match_emoji_bar` | `BDMatchEmojiBar` / `BDEmojiBarView` | PK_V1O |
| `purify_passby_tip` | `BDNearbyPassbyManager` / `BDPassbyTipView` | PK_V0 |
| `purify_live_entry` | `BDLiveEntryManager` / `BDLiveServiceCell` | PK_V0（数据源级，与 view rule 双保险） |
| `purify_mine_vip` | `BDMineVipManager` / `BDMineVipCardView` | PK_V1O |

**若某 key 四步全部失败**：允许保留 view rule 实现，但必须在 Handoff 中标 `weak`，并在面板该项副标题注明"视图级"，同时进 `P1.3` 的命中审计名单。**不许再把 weak 当 done 上报。**

### 4.3 6 个遗留 `switch_*` 的实现路径

| key | 落点 | 形态 | 风险/备注 |
|---|---|---|---|
| `switch_no_data_collect` | `BDDataCollectManager` 入口 + `kPHostRules` 扩 `bddata` / `track` / `statistics` 域名族 | host 规则（复用 `kPHostRules` 机制） | 命中面广，需 **host 白名单**（登录/心跳域名不在列），否则会打断会话。必须先在真机跑 1 天观察日志命中量 |
| `switch_block_live_request` | `live.blued.cn` 族 + 拉流 SDK 入口（`BDLivePlayer*`） | host 规则 + PK_V0 | 同上；拉流失败要有 UI 兜底，避免"黑屏 30s" |
| `switch_hide_calling_ui` | `BDCallChatUsersController` / `BDCallExposurePop` | PK_V1O / PK_V0 | 需先用 §4.2 四步确认 |
| `switch_hide_purple_card` | 按 view rule 试 `PurpleCard`/`RecommendCard` 先定位，再上数据源 | PK_V1O | 前 3 天允许 weak |
| `switch_hide_live_entry` | 与 `purify_live_entry` 合流（同锚点，双 key 门控：任一开即拦） | PK_V0 | 两 key 共用锚点时**必须**同时支持"任一开即生效"，否则用户困惑。**注意：现有引擎一行只能挂一个 key**（`PInstall.key` 单值，`PKeyFor` 返回单指针，`POn` 单字符串），所以这不是“改配置”而是**机制改动**：`key` 字段需要支持 `"a|b"` 分隔串，`POnAny()` 拆开逐个查（命中即返 YES），并把它单独列为一个构建（不与功能改动同 push）。缓存快照（D9）也必须按“或”语义预先折叠成 `BOOL` |
| `switch_purify_mine_page` | `BDMineViewController -collectionView:numberOfItemsInSection:` + `cellForItemAtIndexPath:` | 裁剪型（需成对改，见下） | **高风险**：裁剪数据源必须成对改 `numberOfItems` + `cellForItem`，否则必崩（与 D1 同类缺陷）。默认关，进入前需 B-B 式二分 |

**裁剪型锚点的统一护栏**（`switch_purify_mine_page` 是第一个用例，后续 55 个开关里会复用）：

- 只允许"**过滤型**"（把某些 indexPath 映射到合法替代行）而不允许"**减数型**"（行数减 N 但 cell 逻辑不知道），除非同时 hook `numberOfItems` 与 `cellForItem` 且用同一张 `NSIndexSet`；
- 这张索引表在 `viewWillAppear` 后一次性计算并缓存，`reloadData` 时失效重算。

### 4.4 `kPViewRules` 治理 v2

现状：**48 条**按**类名子串**匹配（交接书写 47，实测 48），`Banner` 会命中 `BannerCell` 之外的类（交接书 §3.4 已自曝）。另有一个本版新增的性能缺陷：`PViewShouldHide`（`Tweak.xm:1559`）对**每个** `didMoveToSuperview` 都先 `@synchronized(gPViewCache)` 再查字典，即使已经隐藏过的视图也会走完整判定（早退 `v.hidden && alpha==0` 在函数末尾）。改法：

1. 每条规则加 `severity`：`hard`（hidden + alpha 0 + 高 0.5）／`soft`（仅 alpha 0，保布局）／`audit`（只记日志不动手）；
2. 初始全部 `hard` 的规则**重新评估**，凡属"卡片/入口"类降为 `soft`（避免高度塌陷导致宿主布局除零/断言）；
3. 每条规则声明 `scope`（仅某 VC / 全局），默认 `全局` 但日志记录 `self.window` 是否为 keyWindow；
4. 命中计数进 O6 的导出，Top20 可直接看出误伤；
5. 连续 3 个构建某规则命中 > 200 次/会话 → 自动降级为 `audit` 并在诊断页标红（防"用户看得见但说不清"的静默故障）；
6. **去掉锁 + 提前早退**：缓存改「类指针（`Class`）→ 规则下标」的固定容量开放寻址表（类指针在单进程生命周期内稳定），无锁、零 NSString 分配；`rea_viewDidMoveToSuperview` 里把 `v.hidden && alpha==0` 的早退提到 `PViewShouldHide` **之前**；规则表改成 `static const` 编译期常量且 `needle` 预先小写（现在每次未命中都 `lowercaseString` 分配一次）；
7. **splash 类一律 `audit`**（与 §3.1.1 一致）：`SplashAd`/`SplashImage`/`SplashVideo`/`SplashContainer`/`ADXSplash` 五条只记日志。理由不是“保守”，而是我们**没有能力**把广告容器从 window 上移除，只能藏它；藏了就是给用户一个白屏。

### 4.6 陈旧计数与文案一次对齐（低成本、但影响审计可信度）

同一组数字在四处不一致，审计时无法判断“谁才是真相”。P1.4 顺手一次改完，并在 CI 里加一条 lint：

| 位置 | 现状 | 应改为 |
|---|---|---|
| `HANDOFF.md` §7.1 日志样例 | 「共 52 条」 | 共 **56** 条（`P_ROW_COUNT`） |
| `Tweak.xm:951` 注释 | 「第一批 39 条锚点」 | 52 条业务锚点 + 4 条基础设施 |
| `REAUI.xm:161` `purify_master` 副标题 | 「23 项」 | **26 项** |
| `HANDOFF.md` §2.x `kPViewRules` | 47 条 | **48** 条 |

> lint 做法：`grep -c` 安装表行数与运行日志的 `共 N 条` 做断言（脚本侧已在 `key_wire_audit.py` 旁，加一个 `count_check.py` 即可）。这类“文档与代码对不上”是上一轮返工的直接原因之一，不能只靠人看。

### 4.5 DoD（P1）

26 个 key 中 ≥ 24 个为**强实现**；剩 ≤ 2 个 weak 必须有 Handoff 标注 + 面板"视图级"副标题 + 命中审计记录；`key_wire_audit.py` 输出 wired 数 ≥ 26（净化组内）；每个 key 在日志里能通过 `REAFlag` 关/开各验一次（**拨后立即生效，不重启**）。

**每 key 可证伪验收集（Q13 落地物）**：`_work/verify_purify.md` 必须逐 key 写成「操作 → 预期日志行 → 反例（关掉后同一操作不应出现该行）」，26 条全部可被第三人照做。审计员抽查任意 5 条，任一条不可复现即本里程碑不通过——不接受"我这边是好的"。

---

## 5. P2：聊天增强 8 组 / 15 开关

### 5.1 分型

| 类 | 组 | key 数 | 特征 |
|---|---|---|---|
| **H 类（hook）** | 1,2,3,5,6,7 | 10 | 有宿主锚点，改返回值/跳过调用即可 |
| **I 类（交互层）** | 8 | 5 | 宿主无门控，必须自己写 UI/定时/选择器 |

已接 4：`switch_anti_recall` `switch_screenshot` `switch_flash_photo` `switch_flash_text`。待接 11。

**实测口径（`grep -c <key> Tweak.xm REAUI.xm`，证据可复现）**：

| 状态 | key | Tweak.xm 命中数 | REAUI.xm 命中数 |
|---|---|---|---|
| 已接（真写入引擎） | `anti_recall` | 10 | 1 |
| 已接 | `screenshot` | 15 | 1 |
| 已接 | `flash_photo` | 5 | 1 |
| 已接 | `flash_text` | 3 | 1 |
| **纯 UI 装饰** | 其余 11 个（`msg_heal` `chat_heart_off` `flash_ad_skip` `msg_timestamp` `read_receipt` `secret_view_all` `quick_phrase` `auto_select_photo` `auto_select_burn` `scheduled_recall` `regret_auto`） | **0** | 1 |

结论：11 个待接 key 在引擎里命中数为 **0**，即用户已经在界面上看得见、拨得动、**但拨了没任何效果**。这直接命中交接书红线“禁只挂 UI 不接底层”，不是“待开发功能”而是“已经在骗用户”。因此把它列为 **M2.5 急修**（排在 P2 之前）：把这 11 个开关在 UI 上置 `enabled = NO` 并标“即将上线”，改动量半天、无需改引擎，先把可信度止血。

### 5.2 逐组实施

| 组 | key | 锚点（已验证） | 形态 | 关键风险与约束 |
|---|---|---|---|---|
| 1 | `switch_anti_recall`✅ / **`switch_msg_heal`** | anti：`GJIMMessageModel -recallType`(B→0)、`-isSuperRecallTip`(B→NO)<br>heal：`BDSessionViewController -syncMessageFetching`(v16)、`-syncMessageFetched`(v16)、`BDMessageViewController -p_checkSyncLastMessageIfNeed`(v16) | anti：PK_I0/PK_B0；heal：状态观测 + 自造触发 | heal 是**自造**：只在 `fetching==YES && fetched==NO` 超 `T=8s` 时触发一次，令牌桶 3 次/10min、指数退避 2/4/8s、上限后停并记 `[Chat] heal 抑制`。**必须**默认关 |
| 2 | `switch_screenshot`✅ | `p_screenshotTip`(→0)、`p_screenshotWarning`(→nil)、`checkSendScreenshotTip`(→nil) | 已接 | 补 iOS 16+ `UIScreen.isCaptured` 分支（原写 "iOS 26" 疑为笔误，按 16 起 KVC 实现） |
| 3 | **`switch_chat_heart_off`** | `BDPrivateChatSetingController -judgeToShowHeartNewView`(B→NO)、`-toSetHeartNewRead`(v16)、`BDMessageViewController -p_updateHeartStatus:`(v24)、`-isMatchBothHeart`(B→NO) | PK_B0 ×2 + PK_V1O/PK_V0 跳过 | 只 7.50+ 存在，类缺失即 miss（正常，日志区分"类不存在"与"方法不存在"）。**禁止**拦 `-setHeartView:` |
| 4 | `switch_flash_photo`✅ `switch_flash_text`✅ | `GJIMMessageModel` flash 族（18+3 条） | 已接 | 与 `switch_private_photo` 顺序对齐：先判权限再转普通，反之会泄露私密内容（**安全语义，写进验收**） |
| 5 | **`switch_flash_ad_skip`** | `-initBluexTipView`(v16)、`-bluedxTipDoneAction`(v16)、`-destoryChatAddTimeAction`(v16) | 前两条 PK_V0 跳过；**`destory` 绝不拦** | 拦 destory = 闪照永久打不开。验收用例必须包含"开此开关后闪照仍可正常打开" |
| 6 | **`switch_msg_timestamp`** | `GJIMMessageModel -isShowTime`(B→YES) | 只做 PK_B0 | 交接书已判定 `setupData` 补 frame 会崩布局 → **V1 不做布局层**，只做"要求显示"；若真机无效则标 `partial` 并在面板注明 |
| 7 | **`switch_read_receipt`** / **`switch_secret_view_all`** | 共用：`UserSetting -is_global_view_secretly`(B)、`UserSetting -is_traceless_access`(B)、`-is_view_secretly`(B)、`UserInformation` / `UserSettingModel` / `BDVIPPrivilegeConfigModel` | PK_B0 组合 | **必须做优先级仲裁**：`secret_view_all` 开 → 忽略 `read_receipt` 单开；实现用单一仲裁函数 `REAChatVisibilityDecision()`，禁止两个 wrapper 各判各的（否则互相覆盖、行为随调用顺序漂移） |
| 8 | **5 个 I 类** | 见 5.3 | 交互层 | 见 5.3 |

### 5.3 I 类（第 8 组）落地设计

新增第三个源文件 **`tweak-repro/REAChat.xm`**，并同步 `Makefile`：

```
BluedHushREA_FILES := Tweak.xm REAUI.xm REAChat.xm
```

理由：`Tweak.xm` 已 2,103 行、`REAUI.xm` 1,487 行（实测，交接书写 1,490）；交互层 + 5 个自造功能约 600–800 行，塞进任一文件都会让并行开发（S3–S5）撞车概率大幅上升。新增文件对 CI 三闸无影响（仍纯 runtime、无 Logos），但需在 P2 首批构建里验证门禁 1/2 仍绿。

| key | 落点 | 交互契约 | 降级/边界 |
|---|---|---|---|
| `switch_quick_phrase` | `BDMessageViewController` 输入条容器（`inputBar` 一带，347 候选待筛） | 自绘横向 `UIStackView` 挂在输入条**上方**（不改宿主约束，用 `addSubview` + 自身高度约束）；点选 → 填进输入框并 `becomeFirstResponder` | 找不到输入条 → 只在长按悬浮球菜单里提供"发短语"，保证功能不消失 |
| `switch_auto_select_photo` | 相册选择器包装类（优先 `TZImagePicker` / `PHPicker` 包装，1,750 候选中筛） | `viewDidAppear` 后自动勾第 1 张，**只勾不发送** | 多选上限/仅单选模式 → 跳过并记日志；绝不代点"发送" |
| `switch_auto_select_burn` | 同上 + `GJIMMessageModel` flash 标记 | 切到「闪照」tab 再勾 | tab 名靠本地化字符串匹配，语言变化即失效 → 失败即放弃勾选（不猜） |
| `switch_scheduled_recall` | `BDMessageViewController -recallAction:`(v24)、`-p_canRecallMessageWith:`(B20)、`-p_continueRevokeAction:`(v20)、`BDLongPressMenuView -recallAction`(v16)、`AppGlobalVariable -is_recall` | 发送时记 `{msgId, 时间戳}` 到本地队列；定时器到点调 recall | **语义必须写清**：仅 App 存活期间（含 `beginBackgroundTask` 约 30s 窗口）执行；被杀则下次启动做一次"补偿扫描"，超窗口直接丢弃并告知。**不承诺**后台准点 |
| `switch_regret_auto` | 同上锚点 | 撤回后 2 分钟内自动重发原内容（保留 `msgId`） | 与 `scheduled_recall` 共用**串行队列**互斥；重发失败 3 次即停 |

**I 类通用护栏**：全部默认关；全部走 `REAEnter/REAExit`；任何 UI 插入点必须能被 kill switch 在**下一次进入会话**时完全移除（注册清理闭包，不允许残留视图）。

### 5.4 冲突矩阵（必须落成代码里的单一仲裁点）

| 冲突对 | 规则 |
|---|---|
| `secret_view_all` ⊃ `read_receipt` | 前者开 → 后者被忽略（日志打 `[Chat] visibility=secret_all 覆盖 read_receipt`） |
| `flash_photo` / `flash_text` × `switch_private_photo` | 先权限判定，再转换；转换后仍受权限约束 |
| `scheduled_recall` × `regret_auto` | 同一消息只能处于一个状态（`scheduled` / `regretted`），串行队列 + 状态机枚举 |
| `msg_heal` × `anti_recall` | 无交集（heal 动同步，anti 动渲染），但 heal 的重连会触发新消息落地 → heal 触发时**暂停 anti 的 60s 内重复提示抑制**，避免刷屏 |

### 5.5 DoD（P2）

15 个 key 全部有真实锚点或真实交互层；每个 key 关/开各验一次，日志可观测；`msg_heal` / `scheduled_recall` 在 72h 真机观察里无"连接打爆"或"消息重复"报告；I 类 5 项在"宿主未找到锚点"时功能不静默消失（要么降级到悬浮球菜单，要么面板标红）。

---

## 6. 工程流水线

### 6.1 每批的标准动作（顺序固定）

```
1. 生成器产出块（gen_*.py → *.m）
2. replace_block.py 幂等替换（按 #pragma mark - <MODULE>（vNN） 定位）
3. python _work/synth_check.py        # 括号/大括号平衡
4. python _work/key_wire_audit.py     # wired 数不得下降
5. git commit + push master
6. gh run watch → 三闸绿
7. gh run download → dist/vNN/
8. 真机验收 + 日志阈值检查（§7）
9. 达标才允许进入下一批
```

> 第 6 步的“三闸绿”有一前提：**跑的是哪个工作流**。见 §6.2b。

### 6.2 并行安全（S3–S5 会用到）
- **文件级锁**：`Tweak.xm` / `REAUI.xm` / `REAChat.xm` 三者同一时刻只允许一个 Agent 写；
- **块级所有权**：每个 Agent 只拥有自己 `#pragma mark` 区间，合并靠生成器而非手工 diff；
- **新增第 4 道 CI 闸**：`Gate - block markers`——校验每个生成块的版本注释与 `key_wire_audit.py` 的 wired 计数被写进构建产物旁的 `wired.txt`，防止“回退式合并”悄悄减少接线。**它必须跑在 `deps.txt`/`nm` 两道闸之后、上传之前，且 fail 时拒绝 `dist/` 入库。**

### 6.2b 双工作流门禁不一致（我自己 grep 出来的、不在交接书里）

仓库里有 **两个** 构建工作流：

| 文件 | 触发 | 三道闸 | 产物名 |
|---|---|---|---|
| `.github/workflows/build.yml`（`runs-on: macos-14`） | push / PR | **有**：`lipo -info` 断言双 arch、`deps.txt` 查 `CydiaSubstrate` 与 `/Library/(MobileSubstrate\|Frameworks)/`、`nm -u \| grep -i MSHook`、`Stage dist` | `BluedHushREA-dylib` |
| `.github/workflows/build-linux.yml`（`runs-on: ubuntu-24.04`，`workflow_dispatch` 手动） | **仅手动** | **一道都没有**。它的 “Verify dylib arch” 步只跑 `file "$DYLIB" || true`（`|| true` = 永不失败），无 substrate 检查、无 MSHook 检查、无 `Stage dist` | `BluedHushREA-dylib-linux` |

风险：交接书说“CI 三道门禁不可绕”，而实际上**存在一条完全不经门禁的产出通道**，macOS 队列排长队时就会有人（包括我自己）用它——它也会绿、也会出 dylib。

修法（归 M0，不归 P0，因为只动 CI 不动 tweak）：
1. 把三道闸抽成 `ci/gates.sh`（幂等、参数化 dylib 路径），两个工作流 **同时** `source` 它；
2. `build-linux.yml` 的校验步去掉 `|| true`，拿不到 dylib 或拿不到 `deps.txt` 就 `exit 1`；
3. 两个工作流的产物统一叫 `BluedHushREA-dylib`，用 run id 区分（名字不一致时很容易把 linux 产物当主产物分发）。

> 这一条是“能让违规产物看起来合法”的那类问题，优先级高于任何新功能。

### 6.3 分支与回滚

- `master` 只进绿；每批打 tag `v13-m1` … `v18-m6`；
- bad build 回滚 = revert 单批 commit（块化保证 revert 不冲突）；
- 每批产物全部保留在 `dist/vNN/`，不覆盖。

---

## 7. 真机验收与日志阈值（每批必跑）

**验收分两类（审核建议 4）**——因为它们的采样次数不同：

- **甲类·只有冷启能验**（splash 闸门 `PK_B0` / `PK_B1O` 只在启动路径被调，热启走不到）：第 1、6 项；每档至少 3 次冷启，共 4 档 = 12 次，每次都必须先 `kill` + 清缓存；
- **乙类·热生效可验**：第 2–5、7–11 项，单项 1 次即可。

| # | 动作 | 通过判据 |
|---|---|---|
| 1 | 冷启动进首页 ×10 | 0 失败；总耗时 ≤ v12 + 30ms。**“冷启”定义必须写死**：每次前 `kill` 进程 + 清 LiveContainer 缓存目录 + 等 3s，否则测的是热启 |
| 2 | 悬浮球拖/吸/点/长按 | 四动作全通；长按进诊断页 |
| 3 | 菜单 → 分类 → 二级页 → 拨开关 → Done/遮罩关闭 | 全通；**拨完立即生效（不重启）**。旧写法“8s 内生效”无意义：`REAFlag`（`Tweak.xm:399`）本就每次现读，根本没有 8s 语义；O7 上快照后要验的是“快照被重建了” |
| 4 | 我的 → 设置 → 「插件设置」→ 面板 | 行存在、可点、面板可关 |
| 5 | 净化总开关联动 26 子项 | 双向同步无遗漏。**判据不是用眼睛看**：每个子项拨一次 → `defaults read` 导出全量 key 快照 → 与预期差集为空；26 子项逐一做一次 |
| 6 | `purify_splash_ad` 四档（0/1/2/3）各跑冷启 ×3 | 四档均能进首页；档 0 是出厂态，**必验** |
| 7 | 聊天：发消息/撤回/闪照/闪文 | 各功能开关开/关行为符合预期 |
| 8 | 返回/前后台切换 20 次 | 无卡顿打点 > 200ms（O1b 采样器口径，不是手感） |
| 9 | 日志阈值 | ① `pass[main+2s]` 的 ok 与基线一致且 miss 名单可解释；② `[Purify] 锚点安装 ok+miss=56`；③ 四个 owner **均非空**（不要求相等，见 §3.2.2）；④ 无 `+initialize` 崩溃帧；⑤ 无 > 200ms 主线程阻塞（O1b） |
| 10 | 崩溃抓取 | `.ips` 存 `_work/crash/`，栈顶 5 帧记入 Handoff |
| 11 | 诊断导出 | 环形日志 + view-rule Top20 可导出可读 |

---

## 8. 里程碑

| 里程碑 | 内容 | 构建 | 工期（含 CI+真机） | 完成判据 |
|---|---|---|---|---|
| **M-1** | §1.4 取证：v12 日志 + `.ips` + 复现步骤 | 0（用现存 v12） | **0.5 天** | §1.4 三项齐 |
| **M0** | 观测骨架 O1b/O4/O5/O6/O7（O1–O3 推 M1） | B1 | **1 天** | §2 DoD |
| **M1** | P0-A 分层 + 四档 + 迁移到档 0 + L5 降 audit | **B2（最小）**，必要时 B3 | **2–3 天** | §3.1.5；二分在诊断页完成，需重建的只有 L5 hard→audit 这一格 |
| **M2** | P0-B 原子安装（带回滚）+ 子开关 + 熔断 + 降级链 | **B4**，必要时 B5 | **2 天** | §3.2.5 |
| **M2.5** | 11 个“拨了无效果”的聊天开关置 `enabled = NO` + “即将上线”文案（§5.1） | 随 B6 一起走 | 0.5 天 | 面板上无任何可拨但无效果的开关 |
| **M3** | P1.1 弱→强（12 key） | B6–B7 | **5–7 天** | §4.5 半数以上达标 |
| **M4** | P1.2 遗留 6 + P1.3 治理 + P1.4 解耦 + **双 key OR 机制** + §4.6 计数对齐 | B8–B10 | **6–8 天** | §4.5 全达标 |
| **M5** | P2 H 类（10 key） | B11–B12 | **5–7 天** | §5.5 |
| **M6** | P2 I 类（5 key，新增 `REAChat.xm`） | B13–B14（含 1 次仅改 Makefile 的验证构建） | **7–10 天** | §5.5 |

> 工期是单人串行估的，已含 CI 排队（macos-14 实测 10–20 min/次）与真机安装（约 5 min/次）。**只给区间不给单点**：每一格的二分都可能退回去重做。

关键路径 M-1→M0→M1→M2 必须串行（同一文件、同一启动期），**不得并行**（沿用 Handoff §9 S0 结论）。M0 之所以不能与 M1 合并：M1 的所有“卡不卡”判据都要读 M0 的采样器与开关快照，反过来做就是先改行为再建尺子。

---

## 9. 风险登记册

| ID | 风险 | 概率 | 影响 | 触发信号 | 缓解 |
|---|---|---|---|---|---|
| R1 | LiveContainer 重复注入导致 wrapper 叠加 | 中 | 闪退 | 进入某页即崩、无规律 | O2 重入护栏 + D2 残留检测 |
| **R8** | **计数/口径漂移**：交接书 52/47、代码注释 39/23、实测 56/48/26 四套数字共存 | **已发生** | 验收拿错分母、审计不可信 | 日志里的数字与文档对不上 | §1.1 口径表 + §4.6 一次对齐 + `count_check.py` lint 入 CI |
| **R9** | **诊断页本身成为新风险**（长按入口误触、诊断页崩溃时无入口可降级） | 中 | 现场无法关功能 | 用户误进诊断页 | 入口需长按 3s + 二次确认；诊断页全程 `@try` + 自身不动任何宿主方法；提供 `defaults write` 文本层兼容路径 |
| **R10** | **回滚事务本身出 bug**（比不回滚更糟：前三条已回滚、第四条后又回滚一次） | 低 | 方法表错乱 | 同一选择子行为随重启变化 | 回滚数组每条带“已回滚”标记 + 幂等；M2 二分矩阵 B-B0 必须包含“造一次故意失败”的注入测试 |
| R2 | 主线程卡死 | 中 | 卡死 | watchdog 打点 > 200ms | 熔断 + 缓存 + 延迟安装 |
| R3 | view rule 误伤正常视图 | 高 | 功能消失 | 导出 Top20 出现非广告类名 | severity 分层 + audit 自动降级 |
| R4 | 裁剪型锚点破坏数据源一致性 | 高 | 崩溃 | `reloadData` 后越界 | §4.3 统一护栏（成对改 + 索引集缓存） |
| R5 | 自造功能（heal/scheduled）被服务端风控识别 | 中 | 账号风险 | 429/断连 | 节流 + 默认关 + 退避 + 上限 |
| **R11** | **双工作流门禁不一致**（见 §6.2b）：`build-linux.yml` 无任何闸门却能产出 dylib | **高（已存在）** | 违规产物看起来合法 | `gh run list` 里出现绿的非 macos-14 构建 | 抽 `ci/gates.sh` 两边共用；去掉 `|| true` |
| **R12** | **根因赌错**：M-1 取证失败 / 日志被轮转 / 用户已卸载 | 中 | 整份 P0 重构 | 拿不到 `.ips` | 允许用 v13.0（档 0、不改行为）当取证工具跑一轮 |
| R6 | 大文件并行改冲突 | 高 | 合并事故 | diff 冲突 | 生成器块 + 文件锁 + 每批立即 CI |
| R7 | CI 队列等待拖慢节奏 | 中 | 排期 | run queued > 10min | 每批 ≤ 2 次 push，二分构建合并跑 |

---

## 10. 自我 grill（挑剔架构师视角）与修订记录

### 10.1 第一轮：对着交接书追问（Q1–Q14）

> 记录形式：提问 → 回答 → 是否触发 v1.0 条款变更。**带 〔修订〕 的条目已落进上文。**

**Q1｜你说"13 强 12 弱"，但交接书写的是"26 个开关已挂真实锚点"。谁对？**
答：按锚点表逐行统计，"强"的判据是**有选择子级锚点在 `kPInstall` 里**。`purify_map_guide` 等在 `kPInstall` 中**零行**，只有 `kPViewRules` 子串。所以是 13/12/1。交接书的表述把"视图兜底"也算成"真实锚点"。 〔修订〕§1.1 + §4.2 + P1 工作量重估。

**Q2｜那 12 个弱 key 会不会其实已经"够用"，升级是浪费？**
答：不一定够用。子串匹配的命中条件是"类名包含该子串"，与"这个视图是广告"之间没有因果关系；`Banner` 已经在自曝误伤。而且弱实现无法被日志证明"生效了"——用户拨开关没反应时，你无法区分"没命中"与"命中但没用"。红线 1 要求"日志里可观测"，弱实现过不了这条。但**允许**分级处理：优先升级误伤风险高的（`map_guide`/`passby_tip`/`live_entry`），低风险的留在 `soft` 档并标 `weak`。 〔修订〕§4.5 DoD 从"26 全强"改为"≥24 强 + ≤2 weak 且显式标注"。

**Q3｜P0-A 你把 L0/L1/L2 全默认关，那用户升级后"开屏净化"是不是等于几乎没效果？**
答：（v1.1 时的答案，已被 v1.3 推翻，保留作记录）当时说“档 1 仍拦 L3+L4+L5，广告不会出现”。**现在看这个答案是错的**：L3 与 L2 同病（丢 block），把 L3 当默认可开等于把卡启动图换锚点重引入。v1.3 改为档 0 出厂。 〔修订〕§3.1.2 四档语义 + §3.1.1 重分族。

**Q4｜`purify_splash_mode` 迁移会不会与用户已有配置打架？**
答：会。`REAFlag` 是 `nil→YES`，老用户已有 `purify_splash_ad = 1`。迁移规则必须是：**只写 `purify_splash_mode`，不动 `purify_splash_ad`**，并在读取侧把"`purify_splash_ad==NO` 且 `mode 未设置`"视为档 0（全关），"`==YES` 且未设置"视为档 1。这样老用户行为可预测、可解释。 〔修订〕§3.1.2 迁移段补"读取侧兼容矩阵"。

**Q5｜P0-B 你列了 8 条缺陷，哪条最可能？如果只修一条呢？**
答：**D1（非原子安装）**。理由是它同时解释"卡死"和"闪退"两种症状，且与交接书自曝的"three of four methods live on the parent class"直接吻合；H1 需要 LiveContainer 真的重载才会发生，概率低得多。只修一条就修 D1。但 D1 修完仍然要 D5（异常边界）与 D6（kill switch），否则真机出问题时你连"关掉它"都做不到。 〔修订〕§3.2.4 二分阶梯把 B-B1（只装 rows）提前，先证否路线本身。

**Q6｜D1 的"四个 owner 必须全等"会不会把本来能工作的场景也否掉？**
答：可能。若宿主把这四个方法拆在两层（`height` 在子类、其余在父类），严格全等会直接判死、退回 T1。这是**故意的**：宁可少一个入口，也不要有中间态。但为了不白丢入口，加一条：owner 不全等时，**先尝试** T1（导航栏按钮），仍不行再 T2。 〔修订〕§3.2.2 末句 + §3.2.3 降级链。

**Q7｜熔断器"3s 未完成首帧就 disarm"会不会误伤慢设备？**
答：会。3s 对冷启动的设置页够，但对低端机首次进入（要拉配置）可能不够。改为：以 `viewWillAppear` 为起点、`viewDidAppear` 为终点计时，**只有超过 5s 或主线程阻塞 > 1s** 才 disarm；正常慢设备只记日志不 disarm。 〔修订〕§3.2.3 熔断条件。

**Q8｜新增 `REAChat.xm` 要改 Makefile，会破坏 CI 三闸吗？**
答：不会。三闸看的是产物架构、substrate 符号、rootful 路径字符串，与文件数量无关。但 `FILES` 变更会让 CI 的编译单元集合变化，必须在 M6 首个构建里单独验证一次（不要和功能改动绑在同一 push）。 〔修订〕§5.3 补"门禁复验"要求 + §6.1 加"Makefile 变更独立构建"。

**Q9｜`msg_heal` 与 `scheduled_recall` 都是自造功能，红线 1 说"禁止假实现"，你怎么保证它们不是"看起来能用"？**
答：给两者定**可证伪的验收**：heal → 人为在飞行模式制造 fetch 超时，观察日志出现 `heal 触发` 且 3s 内出现 `heal 完成`，否则判定失败；scheduled → 发消息后 10s 切后台等待，检查消息在 10s 时确实撤回（前台 + 后台两个用例）。做不到就砍掉功能、不交付半成品。 〔修订〕§5.5 增加"可证伪验收"列。

**Q10｜P1.2 的 `switch_no_data_collect` 用 host 规则拦埋点，会不会顺手把登录也拦掉？**
答：风险高。域名族匹配必须白名单化：只拦 `bddata`/`track`/`statistics` 且 `path` 命中上报特征，**排除** `/login` `/auth` `/im` `/heartbeat`。并且该 key **默认关**，打开后先跑 24h 观察日志命中量再决定是否提为可选默认。 〔修订〕§4.3 该行加白名单与默认关。

**Q11｜你说"先可观测"，但 M0 本身也要进 CI、也要真机验证，是不是又拖一轮？**
答：是，但这一轮是**唯一能省下后面 N 轮猜测**的一轮。M0 不改任何拦截逻辑（纯新增旁路），风险是全部批次里最低的；它带来的重入护栏 O2 还顺带把 R1（最危险的闪退成因）降级了。 〔修订〕无（确认原计划）。

**Q12｜8 个聊天组里第 6 组（显示时间）你只做 `isShowTime`，用户会不会觉得"开了没用"？**
答：会。所以要么把面板该项标 `partial` 并写清"仅请求宿主显示，实际渲染依赖宿主版本"，要么先做原型验证 `setupData` 补 frame 的可行性再定。V1 取前者（不冒险改布局），并在 Handoff 里留 `partial` 标记。 〔修订〕§5.2 第 6 行补 `partial` 标记要求。

**Q13｜校验口径：你怎么证明"26 个开关全部真实可用"而不是又一次自证？**
答：`key_wire_audit.py` 只能证明"key 被引用"。真正的证据是**每 key 一条真机操作脚本**：拨开 → 触发目标场景 → 日志出现该 key 的命中行 → 拨关 → 同一场景命中行消失。把这 26 条写成 `_work/verify_purify.md` 清单，逐条留日志截取。审计员可抽查任意 5 条。 〔修订〕§7 增加"每 key 可复现脚本"要求；§4.5 DoD 引用它。

**Q14｜如果真机复验发现"档 1 也卡"，你的退路是什么？**
答：退路是"净化引擎整体可整组关闭"——`rea_kill_purify` 一把关掉 `REAInstallPurify()` 的全部安装，App 回到 v12 之前的行为（有广告但能用）。这是最后一道保险，必须在 M1 就位，而不是等出事再加。 〔修订〕§3.1.3 末补"整组 kill switch 必须先于分层修复上线"。

---

### 10.2 第二轮 grill（对着真实代码逐行核完后的自我推翻）

第一轮 14 问是"对着交接书想"，第二轮 8 问是**对着 `Tweak.xm` 一行一行看**。结果推翻了第一轮的 3 个结论。

**Q15｜L5 只留 `ADXSplash`，真的比全关安全吗？**
答：不。`ADXSplash` 是广告 SDK 自己的 view，它的**父容器**仍然在 UIWindow 上。`rea_viewDidMoveToSuperview` 只做 `hidden=YES / alpha=0 / height=0.5`，**不移除**；而容器的移除通常由"展示完成回调 / 最短展示计时"驱动——我们已经把回调链上游切了（L3/L4）。隐藏子 view 不会让父容器消失，用户看到的就是白屏或一直停在启动图。**这就是 A5′，它不需要 H1–H4 任何一条成立。** 〔修订〕§3.1.1 L5 默认改为**全关（audit only）**，新默认为 L3+L4（不含 `PK_O2O`）。

**Q16｜那为什么之前不直接 "移除" 它，而是藏它？**
答：因为 `didMoveToSuperview` 里 `removeFromSuperview` 会在宿主枚举子视图/布局的过程中改变视图树，比藏更危险；而且容器上还挂着宿主的强引用与 block，单方面移除会让后续 `finished` 回调向一个已脱离 window 的容器做动画。**我们没有足够信息安全地移除它，所以唯一正确选择是不碰。** 〔修订〕同上（把这条写进 §3.1.1 备注，防后人“优化”回去）。

**Q17｜你说卡启动图的主因是 L5，那 H4（闸门永不开）怎么排除？**
答：不需要先排除。v13.0 出厂是**档 0**，L0（`isNeedShowSplashAd` → NO）**不生效**，所以 H4 不在生效集合里。真正的问题在于：v12 默认是**全开**（`REAFlag` nil→YES），所以现在每个用户都在跑 L0+L2+L3+L5。 〔修订〕§1.3 的迁移因此从“体验优化”升为 **P0 的一部分**，且 §3.1.2 迁移必须带“读取侧兼容矩阵”（Q4）。

**Q18｜D3 你写“全 App 表格行高被动”，证据够吗？**
答：第一版描述不够硬，本轮补到机制级：`gPTrimmedRows` 存的是纯 `"section-row"` 字符串（`Tweak.xm` `PIsTrimmedRow`/`PShouldTrimSettingCell`），**不带 VC 信息、永不清空**，且在 cell 配置时实际写入。所以只要用户看过一次设置页，之后**任何** tableView 的 `section 0` 第 0–10 行都会被压成 0 高度。这不是“可能”，是“看过就中”。 〔修订〕§3.2.1 D3 重写，修法加“集合去全局化”。

**Q19｜D4（高度回调做重活）是交接书 H3，你照抄了？**
答：照抄了一半。`PIsTrimmedRow` 不建 label，但**每行都读一次 `NSUserDefaults`**（`POn` → `REAFlag` → `NSString` 分配 + CFPreferences）。真正的致命点不在设置页，而在 `PK_VIEW` 装在 `UIView -didMoveToSuperview` 上——**全 App 每个视图都走**。所以 D4 不能当“设置页局部问题”修，必须当**全局热路径**修，而且是 M0 就要修。 〔修订〕新增 **D9 + O7**，并把 D4 改为引用 D9。

**Q20｜`armed` 四条全等就够了？**
答：不够。四条全等只防 owner 不一致，防不住“前三条 swap 成功、第四条返回 NULL”。swap 带副作用，所以必须写成**带回滚的事务**，且回滚后四个全局函数指针必须置 NULL（否则 `p_settingRows == NULL` 守卫失真）。 〔修订〕§3.2.2 补回滚流程。

**Q21｜二分矩阵每格一个构建，你自己不觉得贵吗？**
答：贵且自相矛盾（R7 写着“每批 ≤ 2 次 push”，矩阵却要 7 次）。而 O5 的诊断页本来就是为了“现场切开关”而设计的——那就应该矩阵也跑在诊断页上，只有“代码级差异才能区分”的格才重建。 〔修订〕§3.1.4/§3.2.4 改为“同一构建切开关优先”，M1 最小 2 次构建。

**Q22｜你这个计划里还有哪些是“看起来验证了、其实没验证”？**
答：三处：① “连续 10 次不崩”没定义“什么算冷启”（已补：kill + 清缓存）；② “主线程不卡”没有采样器（已补 O1b：`CFRunLoopObserver` + 200ms 阀）；③ “26 个子项双向同步无遗漏”靠人眼数（已补：`defaults read` 导 26 key 快照比对）。没被堵住的“验收”就是抽象口号。 〔修订〕§7 第 1/8/9 项与 §2 DoD。

### 10.3 第三轮：审核员打回来之后（Q23–Q26）

审核给了 **FAIL**，两条阻断直接推翻了我的默认方案。这四问是本轮真正的思想修正。

**Q23｜谁质疑过“四 owner 全等”这个前提？我是怎么把一个不可能成立的约束写进契约的？**
答：没有人质疑，包括我自己两轮 grill——因为我从交接书里读到“height 在子类、其余在父类”，**却没把这句话与我自己刚写的全等契约对一遍**。这是典型的“两条事实都写对了，合起来是错的”。教训：任何把“观察到的属性”写成“必须成立的断言”之前，先问一句“宿主凭什么满足它”。 〔修订〕§3.2.2 删除全等，§3.2.5 与 §7 第 9 项同步改。

**Q24｜我们的崩溃报告在哪？为什么两轮 grill 都没问过这个？**
答：没有崩溃报告，也不存在 v12 日志；唯一那个 `.log` 是旧版本的（`ok=34 miss=28`，`[Purify]` 零命中）。两轮 grill 全在“读代码推机制”，**没有一轮在问“你的证据是什么”**——而这恰恰是架构评审的第一问。 〔修订〕新增 §1.4 M-1 取证闸门 + R12。

**Q25｜为什么我会把“天然 fail-open”当理由，却没去看拦截分支到底丢没丢回调？**
答：因为 `PK_B1O` 这个名字看起来像“返回 BOOL 的简单改判”，而它的第三个参数就是个 block。**命名欺骗了我**。教训：判断一个锚点能否默认开，**只看签名里有几个 block/handler/completion，不看类名与注释**；有就必须进甲族。 〔修订〕§3.1.1 改成按“单/甲/乙”分族，档 0 为默认。

**Q26｜审核提的 6 条阻断里，哪一条我本来有能力自查到？**
答：B4（补投与看门狗不互斥）与 B6（回滚不清 `gREAOrig` 缓存）都能靠“把状态机画出来”自查到。我当时只写了“补投 finished”，没画“如果 finished 先成功、看门狗后触发会怎样”。教训：**凡是引入定时器的方案，必须先把状态图画出来并把所有迁移标注触发者**，否则一定会出现两路同时生效。 〔修订〕§3.1.3 三段状态机 + §3.2.2 回滚三件套。

---

## 11. 独立审核记录

### 11.1 审核方式

子 Agent 独立审核员（上下文与主线程隔离），只读三份文件：`HANDOFF.md`、`PLAN_V1.md`、`tweak-repro/Tweak.xm`（+ `Makefile` / `REAUI.xm` / `host_index.json` 交叉），按 A–G 七维（事实准确性 / 根因成立性 / 可执行性 / 违反硬约束 / 验收可证伪性 / 风险遗漏 / 工程流程）输出结论。要求：**只报可用文件证实的问题，不许臆造行号**。

### 11.2 审核结论（原文摘录）

> **总体结论：FAIL** —— 计划的默认档 1 押在“L3 天然 fail-open”，而 `PK_B1O` 命中后直接 `return NO`、把 block 参数整个丢弃；§3.2.2 的“四 owner 全等且 == BDSettingViewController”又被宿主类表直接证伪。这两条任一成立，P0-A/P0-B 的“修复”都会在真机上变成静默降级或换锚点复发。

我采信该结论。**v1.2 的默认策略作废，v1.3 档 0 为出厂态。**

### 11.3 阻断级问题与处置（6/6 已闭合）

| # | 审核发现 | 我的复核 | 处置位置 |
|---|---|---|---|
| B1 | 四 owner 全等在真实宿主永不可能成立 | **采信**（`host_index.json`：该 VC 自有 108 方法，仅 height 在内） | §3.2.2 删全等、§3.2.5/§7 改判据 |
| B2 | L3 丢 block，与 L2 同病；档 1 不安全 | **采信**（`Tweak.xm:1379-1384` 拦截分支从不调 `a`） | §3.1.1 重分族 + 档 0 默认 |
| B3 | M0 DoD 的 `ok=36 miss=0` 无口径 | **采信**（`:1943` 每轮重置；每进程 6 轮） | §2 DoD 改“轮次 + 基线 + miss 名单” |
| B4 | 补投 finished 与看门狗无互斥；`Block_copy` 缺失 | **采信**（`:1350-1359` 同步投递） | §3.1.3 三段状态机 + `Block_copy` |
| B5 | 根因无一二手证据（无 `.ips`、日志是 v7 时代） | **采信并亲验**（`BluedHushREA.log` 645 行，`[Purify]` 命中 0） | 新增 §1.4 M-1 闸门 + R12 |
| B6 | 回滚与 `REASwap` write-once 缓存冲突；kill switch 无处可写 | **采信**（`:307-309` 缓存早退） | §3.2.2 回滚三件套 + D6 改现读 |

### 11.4 重要问题与处置（8/8 已闭合）

| # | 审核发现 | 处置 |
|---|---|---|
| I1 | `cell` 钩也无 VC 门控 → 全 App 误伤 | 新增 **D3b** |
| I2 | trim 集合全局无 VC 维度（v1.2 已写） | D3 保留 + 修法不变 |
| I3 | height 先算、trim 后写 → 跨帧不一致 | 新增 **D3c**，修法：trim 前移到行数 |
| I4 | 多轮安装写读竞态、memo 无锁 | **D2 重写** + `gREAInstalling` 闸 |
| I5 | D2“自递归”不成立 | 已从台账删除并改写 |
| I6 | D4 理由错（不建 label）、D5 半错（cell 有 `@try`） | D4/D5 按实改写 |
| I7 | 熔断参数矛盾；T1 覆盖宿主按钮；无恢复路径 | §3.2.3 统一 3.0s + `leftBarButtonItem` + 重启重试 |
| I8 | §11 引用 §12 而 §12 无审核表；HANDOFF 数字不符 | 本文 11.x 补齐；§4.6 计数对齐表 |

### 11.5 审核给的“最薄弱三点”与我的应对

1. **四 owner 全等被证伪** → 契约重写（§3.2.2），并把它当成“观察 ≠ 断言”的教训写进 Q23；
2. **默认档押在错前提上** → 档 0 出厂（§3.1.1/§3.1.2），代价是开屏广告回来，写进发布说明；
3. **无 `.ips`、无 v12 日志** → M-1 取证强制前置（§1.4），取证失败则用档 0 包当取证工具。

### 11.6 未闭合项

**0 条阻断、0 条重要。** 仅存两条“需真机数据才能关闭”的假设：

- **H-A**：卡启动图的真因到底在哪一层（待 §3.1.4 矩阵结论）；
- **H-B**：设置页到底是“越界”还是“主线程税”（待 M-1 的 `.ips` 栈）。

两者都已设计成“无论哪个成立都不会把 App 弄挂”，因此不阻塞开工。

## 12. CHANGELOG

| 版本 | 变更 |
|---|---|
| v1.0 | 初稿：三层结构（P0 / 净化 / 聊天）+ M0–M6 里程碑 |
| v1.1 | 自我 grill 14 问后的修订：§1.1 强弱分级更正；§3.1.2 三档 + 迁移兼容矩阵；§3.2.2 原子契约 + 降级顺序；§3.2.3 熔断条件放宽到 5s/1s 阻塞；§4.3 埋点白名单 + 默认关；§4.5 DoD 放宽为 ≥24 强；§5.3 Makefile 变更独立构建；§5.2 第 6 组标 partial；§7 增加每 key 可复现脚本 |
| v1.2 | 第二轮 grill（Q15–Q22）：L5 全降 audit；D3/D4 补机制；D9 新增；原子安装补回滚；二分矩阵改同构建切开关；§4.6 计数对齐；R8–R10 |
| **v1.3** | **独立审核 FAIL → 大修**：① 档 1 默认作废，改 **档 0 出厂**（§3.1.1 按“单/甲/乙”分族，L3 被识别为丢 block）；② 删“四 owner 全等”契约，改四项各自解析 + 回滚三件套（§3.2.2）；③ 新增 §1.4 **M-1 取证闸门**（无 `.ips`、无 v12 日志）；④ M0 DoD 改“轮次口径 + miss 名单”，M0 范围收敛到 O1b/O4/O5/O6/O7；⑤ §3.1.3 三段状态机 + `Block_copy` + 看门狗参数统一 3.0s；⑥ 新增 D3b/D3c，D2/D4/D5/D6 重写；⑦ §6.2b 双工作流门禁不一致 + R11；⑧ §7 验收拆甲/乙两类、§8 加工期列；⑨ §10.3 Q23–Q26；⑩ §11 补齐真实审核表（阻断 6/6、重要 8/8 已闭合） |
