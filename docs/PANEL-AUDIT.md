# 面板与原版对照清单（v16.0-PANEL）

本文回答用户 m01994 的三个自审问题：**plist 的 Key 对上了吗？UI 跟截图长得一样吗？底层 Hook 稳不稳？**

证据来源（三份，全部落盘，可复查）：

| 编号 | 证据 | 位置 | 用途 |
|---|---|---|---|
| E-K1 | 原版 dylib 里的配置键字面量（231 个，其中 `switch_/purify_` 123 个） | `docs/evidence/keys-dylib.json` | 判断某个 key「是不是原版就有」 |
| E-K2 | 真机 `Library/Preferences/com.danlan.xiaolan.plist`（2,874 键，其中插件键 102 个） | `docs/evidence/prefs-keys.json` | 判断 key 的真实类型与实际值 |
| E-U1 | 13 张原版面板截图（IMG_1227–1241） | 用户提供 | 逐行标题 / 副标题 / 段 footer / 视觉规格 |

---

## 1. Key 对齐（问题一）

### 1.1 结论

- 我方代码里的 `switch_*` / `purify_*` 键共 **104 个**；其中 **102 个**在原版 dylib 里有字面量。
- 本轮修掉 3 处不一致：

| 位置 | 改前（自造/抄错） | 改后（原版字面量） | 依据 |
|---|---|---|---|
| `Tweak.xm` `REAAltitude` / `REAUI.xm` 行 / `REALoc.xm` `HL_KEY_ALT_SW` | `switch_altitude` | `switch_altitude_sim` | E-K1 只有 `_sim` |
| `Tweak.xm` `rea_premain` 脏数据清洗 | `purify_splash_mode`（自造） | **删除该行** | E-K1/E-K2 均无此键 |
| `Tweak.xm` 底栏角标 / `REAUI.xm` 行 | `switch_clean_badge`（自造） | `purify_new_nav_tag` | E-K1 有 `purify_new_nav_tag`，语义正是「去掉 New / 热门推广红点」 |

- 原版有、我方尚未接的 21 个键（本轮不接，避免「只挂 UI」）：
  `switch_anti_kick` `switch_capture_ssl` `switch_chat_button_style` `switch_debug_log` `switch_flash_thumb`
  `switch_force_push_group` `switch_image_save_menu` `switch_keep_alive` `switch_keep_alive_relaunch`
  `switch_lite` `switch_location` `switch_location_sim` `switch_log_level` `switch_msg_page_bg`
  `switch_nearby_chat` `switch_nearby_page_bg` `switch_nearby_sort` `switch_push_takeover`
  `switch_rewrite_host` `switch_unlimited_burn` `purify_block_ad_sdk`

### 1.2 面板里的「待定行」

截图上有、但原版二进制里**找不到**对应键字面量的 4 行。按「不许自造」的规矩，这些行照截图渲染，
但开关置灰、点击无效，并在日志打 `[Panel] 未映射：<标题>`：

| 模块 | 行 | 副标题 |
|---|---|---|
| 隐私与特权 / 资料透视 | 显示对方属性 | 立即生效 · 强制显示对方属性与情报；⚠️ 会放开被藏内容 |
| 净化中心 / 入口与 TAB | 隐藏直播内容 | 立即生效 · 去掉页面内推荐的直播内容 |
| 照片与相册 / 保存与归档 | 展览馆入口 | 立即生效 · 开着时聊天页顶部显示「展览馆」入口 |
| 照片与相册 / 发布 | 发布时核对已选张数 | 立即生效 · 选照片时在日志里核对张数（诊断用） |

> 这 4 行对应的键在 5.18 面板里存在，但 5.19 dylib 的字面量里没有 —— 也可能是被并进了相邻键
> （例如「展览馆入口」并进 `switch_chat_gallery`）。要 100% 定名，需要**面板页面的 key→行 映射 dump**
> 或 5.18 那份 dylib。

---

## 2. UI 还原度（问题二）

### 2.1 已按截图 1:1 实现的部分

| 视觉元素 | 截图规格 | 实现 |
|---|---|---|
| 页面背景 | #F2F2F7 | `REAColorBG()` |
| 分组卡片 | 纯白、圆角 10、左右内缩 16 | `REAMakeCard()` + `layer.cornerRadius = 10` |
| 段标题 | 13pt 灰、左内缩 32、上 22 下 7 | `reamoduleVC` 段头 block |
| 行 | 图标 26×26 @16、标题 17pt @52、副标题 13pt 灰两行 | `REAPanelRowView` 约束组 |
| 开关 | onTint #34C759、右侧内缩 16 | `UISwitch.onTintColor` |
| 动作行 | 右侧蓝字 17pt (#007AFF) + 8×13 chevron | `_act` + `_chev` |
| 段尾统计 | 13pt 灰「已开 x/y · 说明」，数字实时算 | `sec->footer` 里 `%d/%d` 现算 |
| 模块列表 | 9 项，副标题「已开 x/y · 描述」 | `REAPanelRootVC` 动态算 |
| 顶部搜索 | 圆角灰底「搜索开关（名字 / 说明）」 | `UISearchController` |
| 作者 footer | 「作者 Tinycca (@Tinycca) · TG @Tinycca · 版本 5.18 · 共 134 项（开关 102 · 动作 32）…」 | 逐字 |
| 悬浮球 | 蓝色圆形 + 白色闪电 | 沿用 REAUI 的浮动球（矢量绘制） |

数据结构：`REAPanelSpec.h` 里 **9 个模块 / 27 个段 / 166 行**，逐行带 title + subtitle + key|action。
渲染层 `REAPanel.xm` **不使用 UITableView**（避免 cell 复用造成的开关状态错乱），
用 `UIStackView` 直接拼卡片。

### 2.2 与原版仍有差距、需要下一轮补的部分

1. **二级页**：动作行（执行/导出/导入/管理/选择/打开/编辑/转换/查看/检测/备份/还原/调整/清理/切换/设置）
   共 32 个，本轮只落到 `[Panel] 动作待接线：<名字>` 日志，**没有**各自的二级页（原版是独立 VC）。
2. **图标**：原版是自定义彩色图标集；本轮用 SF Symbols + 主色（蓝/红/黄）近似，形状不完全一致。
3. **搜索**：原版是跨模块的**开关级**搜索；本轮先做模块级过滤（`updateSearchResultsForSearchController`
   里筛模块标题/描述），开关级结果列表下一轮补。
4. **悬浮球样式选择页**（「气泡闪电」等矢量样式）未实现。
5. **模块顺序里的「已激活 · 查看」行**（隐私/定位两处）未画。

---

## 3. Hook 稳定性（问题三）

- 本轮**没有新增**任何宿主类 hook，只换了面板渲染层 + 修 key 名，风险面为零。
- 既有安全约束保持不变：不用 `class_getInstanceMethod` / `class_addMethod` / `objc_msgSend`；
  `REASwap` 只改本类自有实现；设置页注入强制 `REAOwnerClass(vc,sel) == vc`。
- 面板只读写 `NSUserDefaults` 与发 `REAFlagChanged` 通知，不触碰宿主对象。

---

## 4. 下一轮要做（按用户「考核通过」的标准）

1. 32 个动作行的二级页（含 `HushLocationPickerController` 那套已完成的选点页复用）。
2 . 开关级搜索 + 悬浮球样式选择。
3. 21 个未接键逐条接底层（每接一个补一行「命中日志 + 验收集」）。
4. 4 个待定行定名（需要面板映射 dump 或 5.18 dylib）。
