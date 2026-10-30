/* ============================================================================
   REAPanelSpec.h —— 面板结构表（**唯一数据源**，渲染层不得自己写字面量）

   来源（三份证据交叉）：
     [UI]  用户提供的 13 张原版截图：分组标题、开关名、副标题、footer 统计文案
     [KEY] 原版 dylib 里的配置 key 字面量（123 个 switch_/purify_）+ 真机
           Library/Preferences/com.danlan.xiaolan.plist 里 102 个实际键
     [FS]  Documents/hush_*.json 的落盘键（相册/展览馆/关系/来访）

   约定：
     - `key == NULL` → 该行在原版二进制里找不到对应字面量（截图有、key 未确证）。
       这种行**不许**编一个新 key 混进去：渲染层照样画，但打
       `[Panel] 未映射：<标题>` 日志，并在 docs/PANEL-AUDIT.md 里列为待定。
     - `action != NULL` → 动作行（右侧蓝字 + 箭头），key 必须为 NULL。
     - `sec` 的 `footer` 用原版文案；`counted == 0` 的段不显示「已开 x/y」。
   ============================================================================ */

typedef NS_ENUM(NSInteger, REARowKind) {
    REARowSwitch = 0,   // 左侧图标 + 标题 + 副标题 + UISwitch
    REARowAction = 1,   // 左侧图标 + 标题 + 副标题 + 右侧蓝字动作名 + chevron
};

typedef struct REARowSpec {
    const char *icon;     // SF Symbol 名（原版用的就是 SF Symbols 风格）
    const char *title;    // 主标题
    const char *subtitle; // 副标题（原版逐字）
    const char *key;      // defaults key；NULL = 未映射
    const char *action;   // 动作名（执行/导出/导入/…）；NULL = 开关行
    int         danger;   // 副标题里的 ⚠️ 提示
} REARowSpec;

typedef struct REASectionSpec {
    const char *header;   // 段标题（可为 NULL）
    const char *footer;   // 段尾统计文案（可为 NULL）
    int         counted;  // 1 = 计入「已开 x/y」
    const REARowSpec *rows;
    int         rowCount;
} REASectionSpec;

typedef struct REAModuleSpec {
    const char *icon;
    const char *title;
    const char *subtitle; // 「广告 / 界面 / 入口 / 网络拦截」
    const REASectionSpec *sections;
    int         sectionCount;
} REAModuleSpec;

/* ---------- 净化中心 ---------- */
static const REARowSpec kRowsPurifyAds[] = {
    {"power",           "净化总开关",        "立即生效 · 只开关本大类的净化细项（23 项；独立项不受控）", "purify_master",      NULL, 0},
    {"forward.end",     "开屏广告与启动图",  "立即生效 · 启动时跳过开屏广告与加载动画；⚠️ 遇卡顿先关本项", "purify_splash_ad",   NULL, 1},
    {"newspaper",       "动态流广告",        "立即生效 · 去掉动态里的信息流与轮播广告", "purify_feed_ad",     NULL, 0},
    {"person.crop.circle.badge.xmark", "身边列表广告", "立即生效 · 去掉身边列表里插入的推广用户", "purify_nearby_ad", NULL, 0},
    {"eye",             "来访页广告",        "立即生效 · 去掉来访页里的广告位", "purify_visitor_ad",  NULL, 0},
    {"rectangle",       "全局横幅",          "立即生效 · 去掉页面顶部的横幅广告条", "purify_banner",    NULL, 0},
    {"square.on.square","身边页悬浮层",      "立即生效 · 去掉身边页浮在上层的推广入口", "purify_float_layer", NULL, 0},
    {"map",             "地图找人 · 引导弹窗","立即生效 · 进地图找人页不再弹引导卡", "purify_map_guide",   NULL, 0},
    {"person.circle",   "我的页广告",        "立即生效 · 去掉「我的」页里的横幅与推广卡片", "purify_mine_ad", NULL, 0},
    {"sparkles",        "动画广告位",        "立即生效 · 去掉会动的 SVGA 动画广告", "purify_svg_ad",    NULL, 0},
};
static const REARowSpec kRowsPurifyUI[] = {
    {"exclamationmark.bubble", "安全提示条",  "立即生效 · 去掉聊天页顶部的安全提示横幅", "purify_safe_tip", NULL, 0},
    {"tag",             "推广红点提示",      "立即生效 · 去掉「New / 热门」推广红点（不碰未读数）", "purify_new_nav_tag", NULL, 0},
    {"eye.slash",       "模糊标签",          "立即生效 · 取消昵称等模糊打码（与解锁访客记录任开其一）", "purify_blur_label", NULL, 0},
    {"phone",           "会话列表通话入口",  "立即生效 · 去掉会话列表顶部的通话入口", "purify_call_header", NULL, 0},
    {"square.on.square", "会话顶部卡片",     "立即生效 · 去掉语音交友 / 酒馆等入口卡", "purify_session_card", NULL, 0},
    {"eye.slash.fill",  "敏感内容优化",      "立即生效 · 去内容遮罩、闪视频直显、点开免确认；需开净化总开关", "purify_sensitive", NULL, 0},
    {"phone.fill",      "隐藏呼唤界面",      "立即生效 · 去掉通话呼出时的状态浮层", "switch_hide_calling_ui", NULL, 0},
    {"rectangle.fill",  "隐藏紫色卡片",      "立即生效 · 去掉顶部那张紫色推荐卡片", "switch_hide_purple_card", NULL, 0},
    {"gift",            "欢迎奖励弹窗",      "立即生效 · 进身边页时不再弹「欢迎奖励」网页框", "purify_welcome_pop", NULL, 0},
    {"person.badge.plus","详情页关注卡片",   "立即生效 · 去掉他人主页底部的关注引导卡", "purify_follow_card", NULL, 0},
    {"face.smiling",    "聊天大表情静止",    "立即生效 · 大表情只显示首帧、不自动播放", "purify_chat_emoji", NULL, 0},
    {"tray.and.arrow.down","移除大表情发送栏","立即生效 · 去掉聊天输入框上方的大表情条", "purify_match_emoji_bar", NULL, 0},
    {"photo.badge.exclamationmark", "敏感照片免提醒", "立即生效 · 自己发的照片不再弹「疑似敏感」提醒", "purify_sensitive_alert", NULL, 0},
    {"figure.walk",     "擦肩而过提示",      "立即生效 · 去掉消息上方那条「擦肩而过」小标签", "purify_passby_tip", NULL, 0},
};
static const REARowSpec kRowsPurifyEntry[] = {
    {"antenna.radiowaves.left.and.right", "直播 / 服务入口", "立即生效 · 去掉相册 / 直播 / 健康等入口", "purify_live_entry", NULL, 0},
    {"square.grid.2x2.fill", "隐藏发现 Tab", "需重启 App · 从底栏移除「发现」页", "switch_hide_discover_tab", NULL, 0},
    {"video.slash",     "隐藏直播 Tab",      "需重启 App · 从底栏移除「直播」页", "switch_hide_live_tab", NULL, 0},
    {"paperplane",      "隐藏直播内容",      "立即生效 · 去掉页面内推荐的直播内容", "switch_hide_live_content", NULL, 0},
    {"person.crop.circle", "我的页整体净化", "立即生效 · 「我的」页只留核心功能", "switch_purify_mine_page", NULL, 0},
    {"creditcard",      "我的页 VIP 版块",  "立即生效 · 去掉「我的」页顶部的会员卡片", "purify_mine_vip", NULL, 0},
    {"gearshape",       "设置页精简",        "立即生效 · 去掉设置页的认证 / 直播 / 扫一扫等 8 项", "purify_set_items", NULL, 0},
};
static const REARowSpec kRowsPurifyNet[] = {
    {"waveform",        "拦截语音房请求",    "立即生效 · 切断语音房服务器（voice.blued.cn）", "purify_block_voice", NULL, 0},
    {"wifi.slash",      "拦截直播请求",      "立即生效 · 阻止直播拉流与下播请求", "switch_block_live_request", NULL, 0},
    {"phone.arrow.up.right", "拦截呼叫请求","立即生效 · 点呼叫不再发出请求（会话 / 来访 / 通话三处）", "purify_block_call", NULL, 0},
    {"chart.bar.fill",  "拦截事件上报",      "需重启 App · 拦截行为埋点上报", "switch_no_data_collect", NULL, 0},
};
static const REASectionSpec kSecPurify[] = {
    {"广告位", "已开 %d/%d · 开屏、信息流与列表里插的广告", 1, kRowsPurifyAds, 10},
    {"界面元素", "已开 %d/%d · 页面上的横幅、提示条、弹窗与打码", 1, kRowsPurifyUI, 14},
    {"入口与 TAB", "已开 %d/%d · 底栏、直播入口与页面精简", 1, kRowsPurifyEntry, 7},
    {"网络拦截", "已开 %d/%d · 从网络上掐断语音 / 直播 / 呼叫与上报等请求", 1, kRowsPurifyNet, 4},
};

/* ---------- 聊天增强 ---------- */
static const REARowSpec kRowsChatMsg[] = {
    {"arrow.uturn.backward.circle", "消息防撤回", "立即生效 · 撤回后消息仍留在本地（标注「已拦截」）", "switch_anti_recall", NULL, 0},
    {"arrow.triangle.2.circlepath", "消息补拉",   "立即生效 · 推送不灵时自动补拉积压消息，静默太久自动重连", "switch_msg_heal", NULL, 0},
    {"camera",          "去除截屏限制",      "立即生效 · 聊天页允许截屏，不再提示 / 黑屏", "switch_screenshot", NULL, 0},
    {"heart.slash",     "关闭对话爱心",      "立即生效 · 关闭「对话爱心进度」(仅 7.50.0 及以上)", "switch_chat_heart_off", NULL, 0},
    {"photo",           "闪照转照片",        "立即生效 · 闪照变普通照片，可反复查看", "switch_flash_photo", NULL, 0},
    {"message",         "闪文转普通消息",    "立即生效 · 限时文本转普通文本，永久可读", "switch_flash_text", NULL, 0},
    {"play.rectangle",  "闪照免广告",        "立即生效 · 看闪照前不再要求看广告 / 加时", "switch_flash_ad_skip", NULL, 0},
    {"clock",           "显示具体时间",      "需重进页面 · 每条消息显示完整时间", "switch_msg_timestamp", NULL, 0},
    {"arrow.triangle.2.circlepath", "历史闪照转照片", "把已有的闪照 / 闪视频转成普通照片（重进会话可见）", NULL, "转换", 0},
    {"arrow.2.circlepath", "历史闪文转普通消息", "把已有的闪文转成普通文本", NULL, "转换", 0},
};
static const REARowSpec kRowsChatRead[] = {
    {"eye.slash",       "悄悄查看",          "立即生效 · 对方看不到「已读」(对全部会话生效)", "switch_read_receipt", NULL, 0},
    {"eye",             "悄悄看全部",        "立即生效 · 同「悄悄查看」+「无痕访问」；发消息后退出", "switch_secret_view_all", NULL, 0},
};
static const REARowSpec kRowsChatSend[] = {
    {"keyboard",        "快捷短语",          "立即生效 · 键盘上方一排常用语，点一下发出", "switch_quick_phrase", NULL, 0},
    {"photo.stack",     "自动选中最近照片",  "立即生效 · 点开相册自动选中最新一张", "switch_auto_select_photo", NULL, 0},
    {"flame",           "自动勾选闪照",      "立即生效 · 相册里自动勾「闪照」并记住选择（先选最新一张）", "switch_auto_select_burn", NULL, 0},
    {"wand.and.stars",  "后悔药",            "立即生效 · 长按自己的消息 → 预约到最后时刻才撤回；再点取消", "switch_scheduled_recall", NULL, 0},
    {"arrow.clockwise", "后悔药 · 自动撤回", "立即生效 · 发相册照片后自动预约撤回（对方已读 + N 秒）", "switch_regret_auto", NULL, 0},
    {"timer",           "已读后延迟秒数",    "自动撤回前等对方已读的秒数（默认 10）", NULL, "设置", 0},
};
static const REARowSpec kRowsChatBackup[] = {
    {"externaldrive",   "备份聊天记录",      "把聊天库无损复制一份（可存多份，不动原库）", NULL, "备份", 0},
    {"arrow.counterclockwise", "还原聊天记录", "用最近一次备份覆盖当前记录（完成后需重启 App）", NULL, "还原", 0},
    {"folder",          "管理备份",          "查看 / 删除已备份的文件", NULL, "查看", 0},
};
static const REASectionSpec kSecChat[] = {
    {"消息处理", "已开 %d/%d · 补拉、撤回、闪照、截屏与显示", 1, kRowsChatMsg, 10},
    {"已读与痕迹", "已开 %d/%d · 谁看了谁、什么时候看的", 1, kRowsChatRead, 2},
    {"发送增强", "已开 %d/%d · 发出去之前与之后", 1, kRowsChatSend, 6},
    {"记录备份", "3 个操作 · 聊天库的复制与还原", 0, kRowsChatBackup, 3},
};

/* ---------- 隐私与特权 ---------- */
static const REARowSpec kRowsPrivInfo[] = {
    {"doc.text.magnifyingglass", "显示对方属性", "立即生效 · 强制显示对方属性与情报；⚠️ 会放开被藏内容", "switch_profile_intel", NULL, 1},
    {"text.bubble",     "身边列表显示个性签名", "立即生效 · 身边列表第三行显示个性签名", "switch_nearby_signature", NULL, 0},
    {"arrow.left.arrow.right", "伪装客户端版本", "立即生效 · 让服务器按新版下发完整资料（属性 / 个性签名）(仅标准版适用)", "switch_version_spoof", NULL, 0},
    {"photo.on.rectangle", "身边列表显示隐私相册", "立即生效 · 身边列表显示对方隐私相册缩略图；上锁的不显示", "switch_nearby_album", NULL, 0},
    {"lock.open",       "距离时间保密解锁",  "立即生效 · 距离 / 最近在线设「保密」时直接显示真实值", "switch_privacy_unlock", NULL, 0},
    {"text.alignleft",  "聊天页资料行",      "立即生效 · 聊天页标题旁显示属性与年龄 / 身高等", "switch_card_intel", NULL, 0},
    {"photo.stack",     "聊天页相册 + 备注", "立即生效 · 聊天页标题下显示对方相册（可看大图）与备注（可改）", "switch_chat_album", NULL, 0},
    {"lock.rectangle.stack", "相册数量标记", "立即生效 · 昵称旁标出隐私相册张数：🔒 上锁 / 📷 可见", "switch_album_count_badge_visible", NULL, 0},
};
static const REARowSpec kRowsPrivMine[] = {
    {"person.badge.key", "相册授权快捷菜单", "立即生效 · 长按聊天键盘表情按钮，一键开关「我的隐私相册」授权", "switch_album_grant", NULL, 0},
};
static const REARowSpec kRowsPrivFree[] = {
    {"folder.badge.plus", "解锁隐私相册",    "立即生效 · 绕过权限校验，直接查看对方隐私相册", "switch_private_photo", NULL, 0},
    {"arrow.down.circle", "去水印存图",      "立即生效 · 保存时去水印、解除保存限制", "switch_watermark", NULL, 0},
    {"crown",           "本地 VIP",          "立即生效 · 本地解锁高级筛选等会员功能", "switch_local_vip", NULL, 0},
    {"person.crop.circle.badge.xmark", "拉黑访问解锁", "立即生效 · 被对方拉黑后，仍能查看他的主页", "switch_blacklist_unlock", NULL, 0},
    {"arrow.left.arrow.right", "公平换照解锁", "立即生效 · 换照与认证次数不再受限，不再弹付费窗（仅本地）", "switch_fair_exchange", NULL, 0},
    {"checkmark.shield", "跳过 License",     "立即生效 · 播放器 / UGC 授权校验一律通过", "switch_license_bypass", NULL, 0},
    {"lock.open",       "解锁查看所有访客记录", "立即生效 · 非会员也能看全部来访：卡片不模糊、自动加载全部", "switch_visitor_unlock", NULL, 0},
};
static const REARowSpec kRowsPrivMark[] = {
    {"minus.circle",    "注销用户标记",      "立即生效 · 被删 / 注销的人标红「消失过」(需开「别想玩消失」)", "switch_deleted_mark", NULL, 0},
    {"exclamationmark.triangle", "风险用户标记", "立即生效 · 主页 ⚠️ 标记风险 / 诈骗，列表标红", "switch_risk_user_block", NULL, 0},
    {"chart.pie",       "聊天状态标记",      "立即生效 · 昵称旁显示聊天状态（聊过 / 冇理睬…）", "switch_past_entangle", NULL, 0},
    {"doc.text.magnifyingglass", "卡片资料情报", "立即生效 · 卡片上显示对方情报小字（黑名单 · 隐身等）", "switch_card_intel_detail", NULL, 0},
    {"person.crop.circle.badge.questionmark", "别想玩消失", "立即生效 · 检测谁删了你 / 注销了；顶部「已注销」入口看名单", "switch_vanished", NULL, 0},
    {"exclamationmark.triangle", "查看风险用户名单", "被你标记的用户（左滑可取消）", NULL, "打开", 0},
    {"person.crop.circle.badge.xmark", "查看已注销用户", "已注销用户的名单", NULL, "打开", 0},
};
static const REASectionSpec kSecPrivacy[] = {
    {"资料透视", "已开 %d/%d · 看别人的属性与资料情报", 1, kRowsPrivInfo, 8},
    {"我的隐私", "已开 %d/%d · 管理我给对方的授权", 1, kRowsPrivMine, 1},
    {"限制释放", "已开 %d/%d · 绕过相册 / 会员 / 拉黑等限制", 1, kRowsPrivFree, 7},
    {"账号标记", "已开 %d/%d · 标出有情况的人，名单入口也在这段", 1, kRowsPrivMark, 7},
};

/* ---------- 定位与追踪 ---------- */
static const REARowSpec kRowsVLoc[] = {
    {"location",        "虚拟定位",          "立即生效 · 首页「交友」右侧入口显隐；点 = 开关，长按 = 地图选点", "switch_virtual_location", NULL, 0},
    {"globe",           "IP 定位",           "需重进页面 · 按 IP 归属地反查坐标并自动写入", "switch_ip_location", NULL, 0},
    {"shuffle",         "真实位置混淆",      "立即生效 · 给真实坐标加随机偏移", "switch_real_location_mask", NULL, 0},
};
static const REARowSpec kRowsTrack[] = {
    {"target",          "位置追踪",          "立即生效 · 进他人主页后台预计算，点按钮看结果；与物理追踪互斥", "switch_track", NULL, 0},
    {"figure.walk",     "物理追踪",          "立即生效 · 点「物理追踪」按钮才开始解算；与位置追踪互斥", "switch_physical_track", NULL, 0},
};
static const REARowSpec kRowsMap[] = {
    {"person.circle",   "地图找人头像清晰",  "立即生效 · 地图找人头像显示高清版，不再模糊", "switch_map_avatar_clear", NULL, 0},
    {"trash",           "地图找人头像缓存清理", "清掉已缓存的高清头像（会重新拉取）", NULL, "清理", 0},
};
static const REASectionSpec kSecLoc[] = {
    {"虚拟定位", "已开 %d/%d · 让 App 以为你在别处", 1, kRowsVLoc, 3},
    {"追踪", "已开 %d/%d · 算别人的位置（两种模式互斥）", 1, kRowsTrack, 2},
    {"地图", "已开 %d/%d · 地图上的头像与缓存", 1, kRowsMap, 2},
};

/* ---------- 自动化与筛选 ---------- */
static const REARowSpec kRowsAutoVisit[] = {
    {"arrow.triangle.2.circlepath", "寻找目标", "立即生效 · 身边列表注入入口，批量访问对方主页", "switch_auto_visit", NULL, 0},
    {"magnifyingglass.circle", "寻找目标设置", "访问人数 / 跳过条件 / 静默运行", NULL, "设置", 0},
    {"hand.raised",     "跳过名单",          "立即生效 · 主页点 ⛔ 加名单；自动访问跳过他们", "switch_skip_list", NULL, 0},
    {"list.bullet",     "跳过名单管理",      "查看 / 移除 / 导入导出跳过名单", NULL, "管理", 0},
    {"line.3.horizontal.decrease", "跳过显示方式", "名单里的人划线还是隐藏", NULL, "切换", 0},
};
static const REARowSpec kRowsFilter[] = {
    {"line.3.horizontal.decrease.circle", "翻牌子", "立即生效 · 按签名 / 备注 / 距离过滤身边列表", "switch_fanpai", NULL, 0},
    {"text.badge.checkmark", "筛选规则设置", "签名档 / 屏蔽词 / 距离区间等规则", NULL, "设置", 0},
    {"arrow.up.arrow.down", "在线列表按距离排序", "立即生效 · 「在线」列表按距离由近到远排", "switch_online_distance_sort", NULL, 0},
};
static const REARowSpec kRowsSpyAnalyze[] = {
    {"magnifyingglass", "抓特务",            "立即生效 · 打开后每次进来访页自动累计频次", "switch_spy_detect", NULL, 0},
    {"list.bullet.rectangle", "可疑名单",    "打开「抓特务」后，每次打开来访页会自动累计；暂未记录到访客", NULL, "查看", 0},
};
static const REASectionSpec kSecAuto[] = {
    {"批量访问", "已开 %d/%d · 按条件批量看主页与跳过名单", 1, kRowsAutoVisit, 5},
    {"列表筛选", "已开 %d/%d · 身边列表的过滤与排序", 1, kRowsFilter, 3},
    {"访客分析", "已开 %d/%d · 谁在盯着你", 1, kRowsSpyAnalyze, 2},
};

/* ---------- 视奸与访问 ---------- */
static const REARowSpec kRowsStalk[] = {
    {"binoculars",      "视奸模式",          "立即生效 · 在意的人加入名单，一键访问并记录变化", "switch_stalk", NULL, 0},
    {"hand.tap",        "资料页头像长按",    "立即生效 · 资料页长按头像：加名单 / 切无痕 / 看历史", "switch_avatar_long_press", NULL, 0},
    {"paintpalette",    "昵称颜色",          "视奸名单名字染成绿 / 蓝 / 黄", NULL, "选择", 0},
    {"eye",             "视奸列表",          "名单 · 一键访问 · 变化记录与历史", NULL, "打开", 0},
    {"square.and.arrow.up", "导出视奸数据",  "名单 / 快照 / 变化导出为 JSON", NULL, "导出", 0},
    {"square.and.arrow.down", "导入视奸数据","从备份文件合并进现有数据", NULL, "导入", 0},
};
static const REARowSpec kRowsVisit[] = {
    {"trash.slash",     "非会员也能删访问记录", "立即生效 · 删记录被会员挡住时插件代你冲销；长按删除键 = 只拉黑", "switch_visit_clear", NULL, 0},
    {"s.circle",        "看过划线",          "立即生效 · 我访问过的人名字加删除线", "switch_viewed_strike", NULL, 0},
};
static const REASectionSpec kSecStalk[] = {
    {"视奸", "已开 %d/%d · 名单 · 一键访问 · 变化与历史", 1, kRowsStalk, 6},
    {"访问记录", "已开 %d/%d · 来访列表里的记录管理", 1, kRowsVisit, 2},
};

/* ---------- 照片与相册 ---------- */
static const REARowSpec kRowsAlbum[] = {
    {"photo.on.rectangle.angled", "普通照片入库", "立即生效 · 聊天的普通照片也进相册与展览馆", "switch_chat_gallery", NULL, 0},
    {"square.grid.2x2", "展览馆入口",        "立即生效 · 开着时聊天页顶部显示「展览馆」入口", "switch_chat_gallery_entry", NULL, 0},
    {"rectangle.stack", "聊天页照片墙球",    "立即生效 · 聊天页右上角 📷 悬浮球，看本会话照片", "switch_chat_gallery_ball", NULL, 0},
    {"arrow.triangle.2.circlepath", "归并未归属照片", "把没记清会话的照片按时间归入对应会话", NULL, "执行", 0},
    {"square.and.arrow.up", "导出相册（迁移用）", "把展览馆照片打包成 zip；到「管理相册备份」长按分享", NULL, "导出", 0},
    {"square.and.arrow.down", "导入相册（迁移用）", "选相册备份 zip 合并进展览馆（同名跳过，不覆盖）", NULL, "导入", 0},
    {"externaldrive",   "管理相册备份",      "管理相册备份：导入 / 分享 / 删除（不碰相册照片）", NULL, "管理", 0},
};
static const REARowSpec kRowsAlbumEric[] = {
    {"square.and.arrow.down", "自动导入 Eric 大佬插件的闪照", "需重启 App · 启动时自动把旧插件闪照复制进展览馆（需重启）", "switch_legacy_auto_import", NULL, 0},
    {"square.and.arrow.down.on.square", "导入 Eric 大佬插件的闪照", "把旧插件目录里的闪照复制进展览馆（同名比内容）", NULL, "导入", 0},
    {"trash",           "清理 Eric 大佬插件的闪照", "删除旧目录里已导入本版的文件（不可恢复）", NULL, "清理", 0},
};
static const REARowSpec kRowsAlbumPost[] = {
    {"checkmark.circle", "发布时核对已选张数", "立即生效 · 选照片时在日志里核对张数（诊断用）", "switch_publish_count_check", NULL, 0},
};
static const REASectionSpec kSecAlbum[] = {
    {"保存与归档", "已开 %d/%d · 哪些照片进相册、怎么整理与迁移", 1, kRowsAlbum, 7},
    {"ERIC 大佬插件数据", "已开 %d/%d · Eric 大佬插件（BluedHook）保存的闪照", 1, kRowsAlbumEric, 3},
    {"发布", "已开 %d/%d · 发照片时的自动操作", 1, kRowsAlbumPost, 1},
};

/* ---------- 入口与手势 ---------- */
static const REARowSpec kRowsEntry[] = {
    {"circle.fill",     "悬浮球入口",        "需切前后台 · 屏幕上挂一个悬浮按钮，点它打开本面板", "float_ball", NULL, 0},
    {"square.grid.2x2", "悬浮球样式",        "现在用的是「气泡闪电」；矢量绘制，选完立即生效", NULL, "选择", 0},
    {"hand.point.left", "长按底栏「身边」",  "立即生效 · 长按弹出功能菜单；关掉后长按无反应", "switch_avatar_long_press_area", NULL, 0},
    {"hand.tap",        "长按动作",          "弹菜单 / 直接开模块菜单 / 直接开视奸列表", NULL, "选择", 0},
    {"person.crop.circle.badge.xmark", "长按「我的」跳黑名单", "立即生效 · 长按底栏「我的」→ 打开黑名单", "switch_blacklist_jump", NULL, 0},
};
static const REASectionSpec kSecEntry[] = {
    {"入口与手势", "已开 %d/%d · 插件入口与底栏长按", 1, kRowsEntry, 5},
};

/* ---------- 风控与设备 ---------- */
static const REARowSpec kRowsDevice[] = {
    {"person.crop.square", "伪装设备指纹",    "立即生效 · 设备指纹固定为另一个随机值（与下一项二选一）", "switch_device_fake", NULL, 0},
    {"xmark.seal",      "设备码返回空值",    "立即生效 · 风控取指纹时返回空值（与上一项二选一）", "switch_device_empty", NULL, 0},
    {"nosign",          "拦截设备指纹上传",  "立即生效 · 阻止把设备指纹上传给服务器", "switch_block_device_upload", NULL, 0},
    {"doc.badge.arrow.up", "拦截设备指纹上报出口", "立即生效 · 直接阻断风控 SDK 的上报出口（比上一项更彻底）", "switch_device_intercept", NULL, 0},
};
static const REARowSpec kRowsBypass[] = {
    {"shield.lefthalf.filled", "越狱检测绕过", "立即生效 · 让 App 认为设备没有越狱", "switch_bypass_jailbreak", NULL, 0},
    {"shield.checkered", "风险设备登录",     "立即生效 · 越狱设备重新登录不再被拦下（登录包标记为安全）", "switch_risk_login_bypass", NULL, 0},
    {"waveform.path.ecg", "设备检测",        "看 App 眼里的这台设备（越狱 / 注入判定等）", NULL, "检测", 0},
};
static const REARowSpec kRowsDiag[] = {
    {"line.3.horizontal.decrease", "日志等级", "当前：信息 (I) ｜ 六档可调，立即生效（关键轨迹不受影响）", "switch_log_level", NULL, 0},
    {"ladybug",         "关闭崩溃上报（诊断）", "需重启 App · 关掉 Bugly，崩溃改落系统报告（查完关回）", "switch_bugly_off", NULL, 0},
    {"doc.text",        "查看运行日志",      "面板与 Hook 的最近记录（含等级统计）", NULL, "查看", 0},
};
static const REASectionSpec kSecRisk[] = {
    {"设备指纹", "已开 %d/%d · 设备码怎么给、要不要传上去", 1, kRowsDevice, 4},
    {"检测绕过", "已开 %d/%d · 别让 App 认出这台设备有问题", 1, kRowsBypass, 3},
    {"诊断", "已开 %d/%d · 出问题时要看的东西", 1, kRowsDiag, 3},
};

/* ---------- 九个模块（顺序与截图一致） ---------- */
static const REAModuleSpec kModules[] = {
    {"sparkles",        "净化中心",   "广告 / 界面 / 入口 / 网络拦截", kSecPurify, 4},
    {"bubble.left.and.bubble.right.fill", "聊天增强", "消息 / 已读 / 发送 / 备份", kSecChat, 4},
    {"lock.shield",     "隐私与特权", "看别人的 / 解限制 / 标记名单", kSecPrivacy, 4},
    {"location.north.fill", "定位与追踪", "虚拟定位 / 追踪 / 地图", kSecLoc, 3},
    {"gearshape.2",     "自动化与筛选", "批量访问 / 列表筛选 / 访客分析", kSecAuto, 3},
    {"binoculars.fill", "视奸与访问", "视奸名单 / 访问记录", kSecStalk, 2},
    {"photo.on.rectangle","照片与相册", "保存归档 / Eric 大佬插件数据 / 迁移", kSecAlbum, 3},
    {"cursorarrow",     "入口与手势", "悬浮球 / 底栏长按", kSecEntry, 1},
    {"shield.lefthalf.filled", "风控与设备", "设备指纹 / 检测绕过 / 诊断", kSecRisk, 3},
};
#define REA_MODULE_COUNT ((int)(sizeof(kModules) / sizeof(kModules[0])))

static inline int REASectionSwitchCount(const REASectionSpec *s) {
    int n = 0;
    for (int i = 0; i < s->rowCount; i++) if (s->rows[i].action == NULL) n++;
    return n;
}
static inline int REAModuleSwitchCount(const REAModuleSpec *m, int *onCount) {
    int total = 0, on = 0;
    for (int s = 0; s < m->sectionCount; s++) {
        const REASectionSpec *sec = &m->sections[s];
        for (int i = 0; i < sec->rowCount; i++) {
            const REARowSpec *r = &sec->rows[i];
            if (r->action != NULL) continue;
            total++;
            if (r->key != NULL) {
                id v = [[NSUserDefaults standardUserDefaults] objectForKey:@(r->key)];
                if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) on++;
            }
        }
    }
    if (onCount) *onCount = on;
    return total;
}
