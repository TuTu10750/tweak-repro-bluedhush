// ============================================================================
//  REAUI.xm —— BluedHush REA UI 层（纯代码 UIKit，零 Logos / 零 substrate）
//
//  本文件是 Tweak.xm（Hook 模块）的完全独立 UI 模块：
//    · 只负责：UIWindow(UIWindowLevelAlert) + 悬浮球(pan/tap) + 多级菜单 + UISwitch
//    · 不负责：任何 swizzling；开关状态写入 NSUserDefaults，Hook 侧即时读取
//  原版对应实现（BluedHush_5.19.dylib 反汇编实证）：
//    HushFloatBall      : UIView,  -initWithFrame: 0x67360 / -refreshIcon 0x676f4
//                                  -onTap 0x67778（+[HushSettingsPanel open]） / -onPan: 0x6778c
//    HushSettingsPanel  : UIViewController, -viewDidLoad 0x19e6e4 / -buildModel 0x19f254
//    HushModuleDetailController : UITableViewController, -initWithTitle:sections:footer: 0x199c4c
//    HushConfig         : NSUserDefaults 直读直写（isEnabled: 0xe800 / setEnabled:forKey: 0xed14）
//  菜单数据由 buildModel(0x19F254) 常量流自动还原，见 analysis/menu_final.json。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void REALogBridge(NSString *fmt, ...);
extern BOOL REAFlagBridge(NSString *key);
extern void REAShowHookReportBridge(void);
extern void REAShowHitReportBridge(void);
extern void REAReinstallHooksBridge(void);

static NSString *const kREABallCenterKey = @"rea_ball_center";
static NSString *const kREABallEnabledKey = @"rea_ball_enabled";
static NSString *const kREAFakeLocationKey = @"rea_fake_location";

#pragma mark - 日志与开关（与 Hook 模块同一数据源）

static void REAUILog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    REALogBridge(@"[UI] %@", s);
}

static BOOL REAUIFlag(NSString *key)
{
    if (key.length == 0) return NO;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:key];
    if (v == nil) return YES;
    return [d boolForKey:key];
}

// 总开关 -> 本大类细项 key 列表（实现在 REABuildMenu 之后；这里只能前向声明）
static NSArray<NSString *> *REAUIMasterGroupKeys(NSString *masterKey);

static void REAUISetFlag(NSString *key, BOOL on)
{
    if (key.length == 0) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:key];

    // 「净化总开关」不是装饰：拨一下就把它下面 23 个净化细项一起写下去，
    // 每个细项仍然只认自己的 key，所以总开关关掉后单独再开某一项也照样生效。
    NSArray<NSString *> *kids = REAUIMasterGroupKeys(key);
    for (NSString *k in kids) [d setBool:on forKey:k];

    [d synchronize];
    if (kids.count > 0) {
        REAUILog(@"总开关 %@ -> %d（连带 %lu 项）", key, (int)on, (unsigned long)kids.count);
    } else {
        REAUILog(@"开关 %@ -> %d", key, (int)on);
    }
}

#pragma mark - 数据模型

@interface REAItem : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *actionLabel;
@property (nonatomic, copy) NSString *actionSelector;
@property (nonatomic, assign) BOOL isAction;
@property (nonatomic, assign) BOOL defOn;
+ (instancetype)toggleWithKey:(NSString *)key title:(NSString *)t subtitle:(NSString *)s
                         icon:(NSString *)i defOn:(BOOL)defOn;
+ (instancetype)actionWithTitle:(NSString *)t subtitle:(NSString *)s icon:(NSString *)i
                    actionLabel:(NSString *)label action:(NSString *)action;
@end

@implementation REAItem
+ (instancetype)toggleWithKey:(NSString *)key title:(NSString *)t subtitle:(NSString *)s
                         icon:(NSString *)i defOn:(BOOL)defOn
{
    REAItem *it = [REAItem new];
    it.key = key; it.title = t; it.subtitle = s; it.icon = i;
    it.isAction = NO; it.defOn = defOn;
    return it;
}
+ (instancetype)actionWithTitle:(NSString *)t subtitle:(NSString *)s icon:(NSString *)i
                    actionLabel:(NSString *)label action:(NSString *)action
{
    REAItem *it = [REAItem new];
    it.title = t; it.subtitle = s; it.icon = i;
    it.actionLabel = label; it.actionSelector = action;
    it.isAction = YES;
    return it;
}
@end

@interface REASection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) NSArray<REAItem *> *items;
@end

@implementation REASection
@end

@interface REAModule : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) NSArray<REASection *> *sections;
- (NSInteger)enabledCount;
- (NSInteger)totalCount;
@end

@implementation REAModule
- (NSInteger)enabledCount
{
    NSInteger n = 0;
    for (REASection *s in self.sections) {
        for (REAItem *it in s.items) {
            if (!it.isAction && it.key.length && REAUIFlag(it.key)) n++;
        }
    }
    return n;
}
- (NSInteger)totalCount
{
    NSInteger n = 0;
    for (REASection *s in self.sections) {
        for (REAItem *it in s.items) {
            if (!it.isAction) n++;
        }
    }
    return n;
}
@end

#pragma mark - 菜单数据（由原版 buildModel 常量流还原）

static NSArray<REAModule *> *REABuildMenu(void)
{
    NSMutableArray *mods = [NSMutableArray array];

    {   // ---- 净化中心 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"purify_master" title:@"净化总开关" subtitle:@"只开关本大类的净化细项（23 项；独立项不受控）" icon:@"power" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"purify_splash_ad" title:@"开屏广告与启动图" subtitle:@"启动时跳过开屏广告与加载动画；⚠️ 遇卡顿先关本项" icon:@"forward.end.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_feed_ad" title:@"动态流广告" subtitle:@"去掉动态里的信息流与轮播广告" icon:@"rectangle.stack.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_nearby_ad" title:@"身边列表广告" subtitle:@"去掉身边列表里插入的推广用户" icon:@"person.crop.circle.badge.xmark" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_visitor_ad" title:@"来访页广告" subtitle:@"去掉来访页里的广告位" icon:@"eye.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_banner" title:@"全局横幅" subtitle:@"去掉页面顶部的横幅广告条" icon:@"menubar.rectangle" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_float_layer" title:@"身边页悬浮层" subtitle:@"去掉身边页浮在上层的推广入口" icon:@"rectangle.on.rectangle" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_map_guide" title:@"地图找人·引导弹窗" subtitle:@"进地图找人页不再弹引导卡" icon:@"map.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_mine_ad" title:@"我的页广告" subtitle:@"去掉「我的」页里的横幅与推广卡片" icon:@"person.crop.circle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_svg_ad" title:@"动画广告位" subtitle:@"去掉会动的 SVGA 动画广告" icon:@"sparkles" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"广告位"; sec.icon = @"circle"; sec.subtitle = @"开屏、信息流与列表里插的广告";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"purify_safe_tip" title:@"安全提示条" subtitle:@"去掉聊天页顶部的安全提示横幅" icon:@"exclamationmark.bubble.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_new_nav_tag" title:@"推广红点提示" subtitle:@"去掉「New / 热门」推广红点（不碰未读数）" icon:@"tag.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_blur_label" title:@"模糊标签" subtitle:@"取消昵称等模糊打码（与解锁访客记录任开其一）" icon:@"eye.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_call_header" title:@"会话列表通话入口" subtitle:@"去掉会话列表顶部的通话入口" icon:@"phone.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_session_card" title:@"会话顶部卡片" subtitle:@"去掉语音交友 / 酒馆等入口卡" icon:@"square.on.square" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_sensitive" title:@"敏感内容优化" subtitle:@"去内容遮罩、闪视频直显、点开免确认；需开净化总开关" icon:@"rectangle.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_hide_calling_ui" title:@"隐藏呼唤界面" subtitle:@"去掉通话呼出时的状态浮层" icon:@"phone.down.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_hide_purple_card" title:@"隐藏紫色卡片" subtitle:@"去掉顶部那张紫色推荐卡片" icon:@"rectangle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_welcome_pop" title:@"欢迎奖励弹窗" subtitle:@"进身边页时不再弹「欢迎奖励」网页框" icon:@"gift.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_follow_card" title:@"详情页关注卡片" subtitle:@"去掉他人主页底部的关注引导卡" icon:@"person.badge.plus" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_chat_emoji" title:@"聊天大表情静止" subtitle:@"大表情只显示首帧、不自动播放" icon:@"face.smiling.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_match_emoji_bar" title:@"移除大表情发送栏" subtitle:@"去掉聊天输入框上方的大表情条" icon:@"rectangle.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_sensitive_alert" title:@"敏感照片免提醒" subtitle:@"自己发的照片不再弹「疑似敏感」提醒" icon:@"person.crop.circle.badge.exclamationmark" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_passby_tip" title:@"擦肩而过提示" subtitle:@"去掉消息上方那条「擦肩而过」小标签" icon:@"figure.walk" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_clean_badge" title:@"底栏角标清零" subtitle:@"立即生效 · 清掉底栏红点与数字角标（不影响未读数）" icon:@"app.badge" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"界面元素"; sec.icon = @"circle"; sec.subtitle = @"页面上的横幅、提示条、弹窗与打码";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"purify_live_entry" title:@"直播 / 服务入口" subtitle:@"去掉相册 / 直播 / 健康等入口" icon:@"dot.radiowaves.left.and.right" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_hide_discover_tab" title:@"隐藏发现 Tab" subtitle:@"从底栏移除「发现」页" icon:@"square.grid.2x2.fill" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_hide_live_tab" title:@"隐藏直播 Tab" subtitle:@"从底栏移除「直播」页" icon:@"video.slash.fill" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_hide_live_entry" title:@"隐藏直播内容" subtitle:@"去掉页面内推荐的直播内容" icon:@"play.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_purify_mine_page" title:@"我的页整体净化" subtitle:@"「我的」页只留核心功能" icon:@"person.crop.circle.badge.minus" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"purify_mine_vip" title:@"我的页 VIP 版块" subtitle:@"去掉「我的」页顶部的会员卡片" icon:@"creditcard.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"purify_set_items" title:@"设置页精简" subtitle:@"去掉设置页的认证 / 直播 / 扫一扫等 8 项" icon:@"gearshape.fill" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"入口与 Tab"; sec.icon = @"circle"; sec.subtitle = @"底栏、直播入口与页面精简";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"purify_block_voice" title:@"拦截语音房请求" subtitle:@"切断语音房服务器（voice.blued.cn）" icon:@"waveform" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_block_live_request" title:@"拦截直播请求" subtitle:@"阻止直播拉流与下播请求" icon:@"wifi.slash" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"purify_block_call" title:@"拦截呼叫请求" subtitle:@"点呼叫不再发出请求（会话 / 来访 / 通话三处）" icon:@"phone.arrow.up.right" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_no_data_collect" title:@"拦截事件上报" subtitle:@"拦截行为埋点上报" icon:@"chart.bar.fill" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"网络拦截"; sec.icon = @"circle"; sec.subtitle = @"从网络上掐断语音 / 直播 / 呼叫与上报等请求";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"净化中心"; md.icon = @"sparkles"; md.subtitle = @"广告 / 界面 / 入口 / 网络拦截";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 聊天增强 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_anti_recall" title:@"消息防撤回" subtitle:@"撤回后消息仍留在本地（标注「已拦截」）" icon:@"arrow.uturn.backward.circle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_msg_heal" title:@"消息补拉" subtitle:@"推送不灵时自动补拉积压消息，静默太久自动重连" icon:@"arrow.triangle.2.circlepath" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_screenshot" title:@"去除截屏限制" subtitle:@"聊天页允许截屏，不再提示 / 黑屏" icon:@"camera.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_heart_off" title:@"关闭对话爱心" subtitle:@"关闭「对话爱心进度」（仅 7.50.0 及以上）" icon:@"heart.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_flash_photo" title:@"闪照转照片" subtitle:@"闪照变普通照片，可反复查看" icon:@"photo.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_flash_text" title:@"闪文转普通消息" subtitle:@"限时文本转普通文本，永久可读" icon:@"text.bubble.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_flash_ad_skip" title:@"闪照免广告" subtitle:@"看闪照前不再要求看广告 / 加时" icon:@"play.rectangle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_msg_timestamp" title:@"显示具体时间" subtitle:@"每条消息显示完整时间" icon:@"clock.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"历史闪照转照片" subtitle:@"把已有的闪照 / 闪视频转成普通照片（重进会话可见）" icon:@"arrow.triangle.2.circlepath" actionLabel:@"转换" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"历史闪文转普通消息" subtitle:@"把已有的闪文转成普通文本" icon:@"arrow.triangle.2.circlepath.circle" actionLabel:@"转换" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"消息处理"; sec.icon = @"circle"; sec.subtitle = @"补拉、撤回、闪照、截屏与显示";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_read_receipt" title:@"悄悄查看" subtitle:@"对方看不到「已读」（对全部会话生效）" icon:@"eye.slash" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_secret_view_all" title:@"悄悄看全部" subtitle:@"同「悄悄查看」+「无痕访问」；发消息后退出" icon:@"eye.circle.fill" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"已读与痕迹"; sec.icon = @"circle"; sec.subtitle = @"谁看了谁、什么时候看的";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_quick_phrase" title:@"快捷短语" subtitle:@"键盘上方一排常用语，点一下发出" icon:@"keyboard" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_auto_select_photo" title:@"自动选中最近照片" subtitle:@"点开相册自动选中最新一张" icon:@"photo.on.rectangle.angled" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_auto_select_burn" title:@"自动勾选闪照" subtitle:@"相册里自动勾「闪照」并记住选择（先选最新一张）" icon:@"flame.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_scheduled_recall" title:@"后悔药" subtitle:@"长按自己的消息 → 预约到最后时刻才撤回；再点取消" icon:@"pills.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_regret_auto" title:@"后悔药·自动撤回" subtitle:@"发相册照片后自动预约撤回（对方已读 + N 秒）" icon:@"timer" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"已读后延迟秒数" subtitle:@"自动撤回前等对方已读的秒数（默认 10）" icon:@"timer" actionLabel:@"设置" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"发送增强"; sec.icon = @"keyboard"; sec.subtitle = @"发出去之前与之后";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem actionWithTitle:@"备份聊天记录" subtitle:@"把聊天库无损复制一份（可存多份，不动原库）" icon:@"externaldrive.fill" actionLabel:@"备份" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"还原聊天记录" subtitle:@"用最近一次备份覆盖当前记录（完成后需重启 App）" icon:@"arrow.counterclockwise.circle.fill" actionLabel:@"还原" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"管理备份" subtitle:@"查看 / 删除已备份的文件" icon:@"folder.fill" actionLabel:@"查看" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"记录备份"; sec.icon = @"circle"; sec.subtitle = @"聊天库的复制与还原";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"聊天增强"; md.icon = @"bubble.left.and.bubble.right.fill"; md.subtitle = @"消息 / 已读 / 发送 / 备份";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 隐私与特权 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_spoof_lite" title:@"显示对方属性" subtitle:@"强制显示对方属性与情报；⚠️ 会放开被藏内容" icon:@"doc.text.magnifyingglass" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_nearby_signature" title:@"身边列表显示个性签名" subtitle:@"身边列表第三行显示个性签名" icon:@"text.quote" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_version_spoof" title:@"伪装客户端版本" subtitle:@"让服务器按新版下发完整资料（属性 / 个性签名）" icon:@"rectangle.2.swap" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_nearby_album" title:@"身边列表显示隐私相册" subtitle:@"身边列表显示对方隐私相册缩略图；上锁的不显示" icon:@"photo.on.rectangle.angled" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_privacy_unlock" title:@"距离时间保密解锁" subtitle:@"距离 / 最近在线设「保密」时直接显示真实值" icon:@"lock.open.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_watermark" title:@"聊天页资料行" subtitle:@"聊天页标题旁显示属性与年龄 / 身高等" icon:@"text.append" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_album_strip" title:@"聊天页相册+备注" subtitle:@"聊天页标题下显示对方相册（可看大图）与备注（可改）" icon:@"photo.on.rectangle" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_album_count_badge_visible" title:@"相册数量标记" subtitle:@"昵称旁标出隐私相册张数：?? 上锁 / ?? 可见" icon:@"lock.rectangle.stack" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"资料透视"; sec.icon = @"circle"; sec.subtitle = @"看别人的属性与资料情报";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_album_grant" title:@"相册授权快捷菜单" subtitle:@"长按聊天键盘表情按钮，一键开关「我的隐私相册」授权" icon:@"person.badge.key.fill" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"我的隐私"; sec.icon = @"circle"; sec.subtitle = @"管理我给对方的授权";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_private_photo" title:@"解锁隐私相册" subtitle:@"绕过权限校验，直接查看对方隐私相册" icon:@"folder.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_watermark" title:@"去水印存图" subtitle:@"保存时去水印、解除保存限制" icon:@"square.and.arrow.down.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_local_vip" title:@"本地 VIP" subtitle:@"本地解锁高级筛选等会员功能" icon:@"crown.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_blacklist_unlock" title:@"拉黑访问解锁" subtitle:@"被对方拉黑后，仍能查看他的主页" icon:@"person.crop.circle.badge.xmark" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_fair_exchange" title:@"公平换照解锁" subtitle:@"换照与认证次数不再受限，不再弹付费窗（仅本地）" icon:@"arrow.left.arrow.right" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_license_bypass" title:@"跳过 License" subtitle:@"播放器 / UGC 授权校验一律通过" icon:@"checkmark.shield.fill" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_visitor_unlock" title:@"解锁查看所有访客记录" subtitle:@"非会员也能看全部来访：卡片不模糊、自动加载全部" icon:@"lock.open.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_nearby_mark" title:@"卡片样式（一屏一人）" subtitle:@"身边页改为一屏一人卡片；关掉恢复原生列表" icon:@"rectangle.stack.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"编辑默认评价词" subtitle:@"改卡片底部四个评价按钮的默认词；留空恢复默认" icon:@"square.and.pencil" actionLabel:@"编辑" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"限制解放"; sec.icon = @"circle"; sec.subtitle = @"绕过相册 / 会员 / 拉黑等限制";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_deleted_mark" title:@"注销用户标记" subtitle:@"被删 / 注销的人标红「消失过」（需开「别想玩消失」）" icon:@"minus.circle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_risk_user_block" title:@"风险用户标记" subtitle:@"主页 ⚠️ 标记风险 / 诈骗，列表标红" icon:@"exclamationmark.triangle.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_past_entangle" title:@"聊天状态标记" subtitle:@"昵称旁显示聊天状态（聊过 / 冇理睬…）" icon:@"chart.pie.fill" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_card_intel" title:@"卡片资料情报" subtitle:@"卡片上显示对方情报小字（黑名单 · 隐身等）" icon:@"doc.text.magnifyingglass" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_vanished" title:@"别想玩消失" subtitle:@"检测谁删了你 / 注销了；顶部「已注销」入口看名单" icon:@"person.crop.circle.badge.xmark" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"查看风险用户名单" subtitle:@"被你标记的用户（左滑可取消）" icon:@"exclamationmark.triangle.fill" actionLabel:@"打开" action:@"reaActionRiskList"]];
            [its addObject:[REAItem actionWithTitle:@"查看已注销用户" subtitle:@"已注销用户的名单" icon:@"person.crop.circle.badge.xmark" actionLabel:@"打开" action:@"reaActionDeletedList"]];
            REASection *sec = [REASection new];
            sec.title = @"账号标记"; sec.icon = @"circle"; sec.subtitle = @"标出有情况的人，名单入口也在本段";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"隐私与特权"; md.icon = @"lock.shield.fill"; md.subtitle = @"看别人的 / 解限制 / 标记名单";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 定位与追踪 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_virtual_location" title:@"虚拟定位" subtitle:@"首页「交友」右侧入口显隐；点＝开关，长按＝地图选点" icon:@"location.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_ip_location" title:@"IP 定位" subtitle:@"按 IP 归属地反查坐标并自动写入" icon:@"globe" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_real_location_mask" title:@"真实位置混淆" subtitle:@"给真实坐标加随机偏移" icon:@"shuffle" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_altitude" title:@"海拔一并伪造" subtitle:@"立即生效 · 虚拟定位时同时改写 altitude（配合虚拟坐标使用）" icon:@"arrow.up.and.down.circle" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"虚拟定位"; sec.icon = @"circle"; sec.subtitle = @"让 App 以为你在别处";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_track" title:@"位置追踪" subtitle:@"进他人主页后台预计算，点按钮看结果；与物理追踪互斥" icon:@"scope" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_physical_track" title:@"物理追踪" subtitle:@"点「物理追踪」按钮才开始解算；与位置追踪互斥" icon:@"figure.walk" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"追踪"; sec.icon = @"scope"; sec.subtitle = @"算别人的位置（两种模式互斥）";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_map_avatar_clear" title:@"地图找人头像清晰" subtitle:@"地图找人头像显示高清版，不再模糊" icon:@"person.crop.circle.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"地图找人头像缓存清理" subtitle:@"清掉已缓存的高清头像（会重新拉取）" icon:@"trash.fill" actionLabel:@"清理" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"地图"; sec.icon = @"circle"; sec.subtitle = @"地图上的头像与缓存";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"定位与追踪"; md.icon = @"location.fill"; md.subtitle = @"虚拟定位 / 追踪 / 地图";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 自动化与筛选 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_auto_visit" title:@"寻找目标" subtitle:@"只显示入口，不会自己访问；点「开始」才批量访问" icon:@"arrow.triangle.2.circlepath" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"寻找目标设置" subtitle:@"访问人数 / 跳过条件 / 静默运行" icon:@"magnifyingglass.circle" actionLabel:@"设置" action:@"reaActionDefault"]];
            [its addObject:[REAItem toggleWithKey:@"switch_skip_list" title:@"跳过名单" subtitle:@"主页点 ?? 加名单；自动访问跳过他们" icon:@"hand.raised.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"跳过名单管理" subtitle:@"查看 / 移除 / 导入导出跳过名单" icon:@"list.bullet" actionLabel:@"管理" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"跳过显示方式" subtitle:@"名单里的人划线还是隐藏" icon:@"slider.horizontal.3" actionLabel:@"切换" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"批量访问"; sec.icon = @"circle"; sec.subtitle = @"按条件批量看主页与跳过名单";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_fanpai" title:@"翻牌子" subtitle:@"按签名 / 备注 / 距离过滤身边列表" icon:@"line.horizontal.3.decrease.circle.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"筛选规则设置" subtitle:@"签名档 / 屏蔽词 / 距离区间等规则" icon:@"signature" actionLabel:@"设置" action:@"reaActionDefault"]];
            [its addObject:[REAItem toggleWithKey:@"switch_online_distance_sort" title:@"在线列表按距离排序" subtitle:@"「在线」列表按距离由近到远排" icon:@"arrow.up.arrow.down" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"列表筛选"; sec.icon = @"circle"; sec.subtitle = @"身边列表的过滤与排序";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_spy_detect" title:@"抓特务" subtitle:@"打开后每次进来访页自动累计频次" icon:@"magnifyingglass" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"可疑名单" subtitle:@"list.bullet.rectangle" icon:@"查看" actionLabel:@"访客分析" action:@"reaActionSuspiciousList"]];
            REASection *sec = [REASection new];
            sec.title = @"访客分析"; sec.icon = @"magnifyingglass"; sec.subtitle = @"谁在盯着你";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"自动化与筛选"; md.icon = @"gearshape.2.fill"; md.subtitle = @"批量访问 / 列表筛选 / 访客分析";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 视奸与访问 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_stalk" title:@"视奸模式" subtitle:@"在意的人加入名单，一键访问并记录变化" icon:@"binoculars.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_avatar_long_press" title:@"资料页头像长按" subtitle:@"资料页长按头像：加名单 / 切无痕 / 看历史" icon:@"hand.tap.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"昵称颜色" subtitle:@"视奸名单名字染成绿 / 蓝 / 黄" icon:@"paintpalette.fill" actionLabel:@"选择" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"视奸列表" subtitle:@"名单 · 一键访问 · 变化记录与历史" icon:@"eye.fill" actionLabel:@"打开" action:@"reaActionStalkList"]];
            [its addObject:[REAItem actionWithTitle:@"导出视奸数据" subtitle:@"名单 / 快照 / 变化导出为 JSON" icon:@"square.and.arrow.up" actionLabel:@"导出" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"导入视奸数据" subtitle:@"从备份文件合并进现有数据" icon:@"square.and.arrow.down" actionLabel:@"导入" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"视奸"; sec.icon = @"circle"; sec.subtitle = @"名单 · 一键访问 · 变化与历史";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_visit_clear" title:@"非会员也能删访问记录" subtitle:@"删记录被会员拦住时插件代你冲销；长按删除键＝只拉黑" icon:@"trash.slash.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_viewed_strike" title:@"看过划线" subtitle:@"我访问过的人名字加删除线" icon:@"strikethrough" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"访问记录"; sec.icon = @"circle"; sec.subtitle = @"来访列表里的记录管理";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"视奸与访问"; md.icon = @"binoculars.fill"; md.subtitle = @"视奸名单 / 访问记录";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 照片与相册 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_album" title:@"普通照片入库" subtitle:@"聊天的普通照片也进相册与展览馆" icon:@"photo.on.rectangle" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_gallery" title:@"展览馆入口" subtitle:@"开着时聊天页顶部显示「展览馆」入口" icon:@"rectangle.grid.2x2.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_chat_gallery_ball" title:@"聊天页照片墙球" subtitle:@"聊天页右上角 ?? 悬浮球，看本会话照片" icon:@"rectangle.stack.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"归并未归属照片" subtitle:@"把没记清会话的照片按时间归入对应会话" icon:@"arrow.triangle.2.circlepath" actionLabel:@"执行" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"导出相册（迁移用）" subtitle:@"把展览馆照片打包成 zip；到「管理相册备份」长按分享" icon:@"square.and.arrow.up" actionLabel:@"导出" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"导入相册（迁移用）" subtitle:@"选相册备份 zip 合并进展览馆（同名跳过，不覆盖）" icon:@"square.and.arrow.down.on.square" actionLabel:@"导入" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"管理相册备份" subtitle:@"管理相册备份：导入 / 分享 / 删除（不碰相册照片）" icon:@"externaldrive" actionLabel:@"管理" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"保存与归档"; sec.icon = @"circle"; sec.subtitle = @"哪些照片进相册、怎么整理与迁移";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_legacy_auto_import" title:@"自动导入 Eric 大佬插件的闪照" subtitle:@"启动时自动把旧插件闪照复制进展览馆（需重启）" icon:@"square.and.arrow.down" defOn:NO]];
            [its addObject:[REAItem actionWithTitle:@"导入 Eric 大佬插件的闪照" subtitle:@"把旧插件目录里的闪照复制进展览馆（同名比内容）" icon:@"square.and.arrow.down" actionLabel:@"导入" action:@"reaActionDefault"]];
            [its addObject:[REAItem actionWithTitle:@"清理 Eric 大佬插件的闪照" subtitle:@"删除旧目录里已导入本版的文件（不可恢复）" icon:@"trash" actionLabel:@"清理" action:@"reaActionDefault"]];
            REASection *sec = [REASection new];
            sec.title = @"Eric 大佬插件数据"; sec.icon = @"circle"; sec.subtitle = @"Eric 大佬插件（BluedHook）保存的闪照";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_auto_pick_photo" title:@"发布时核对已选张数" subtitle:@"选照片时在日志里核对张数（诊断用）" icon:@"checkmark.circle.fill" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"发布"; sec.icon = @"circle"; sec.subtitle = @"发照片时的自动操作";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"照片与相册"; md.icon = @"photo.on.rectangle"; md.subtitle = @"保存归档 / Eric 大佬插件数据 / 迁移";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 入口与手势 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"float_ball" title:@"悬浮球入口" subtitle:@"屏幕上挂一个悬浮按钮，点它打开本面板" icon:@"circle.fill" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"现在用的是「%@」；矢量绘制，选完立即生效" subtitle:@"悬浮球样式" icon:@"square.grid.2x2" actionLabel:@"选择" action:@"reaActionDefault"]];
            [its addObject:[REAItem toggleWithKey:@"switch_avatar_long_press_area" title:@"长按底栏「身边」" subtitle:@"长按弹出功能菜单；关掉后长按无反应" icon:@"hand.point.up.left.fill" defOn:NO]];
            [its addObject:[REAItem actionWithTitle:@"长按动作" subtitle:@"弹菜单 / 直接开模块菜单 / 直接开视奸列表" icon:@"hand.tap.fill" actionLabel:@"选择" action:@"reaActionDefault"]];
            [its addObject:[REAItem toggleWithKey:@"switch_blacklist_jump" title:@"长按「我的」跳黑名单" subtitle:@"长按底栏「我的」→ 打开黑名单" icon:@"person.crop.circle.badge.xmark" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"入口与手势"; sec.icon = @"circle"; sec.subtitle = @"插件入口与底栏长按";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"入口与手势"; md.icon = @"cursorarrow.click"; md.subtitle = @"悬浮球 / 底栏长按";
        md.sections = secs;
        [mods addObject:md];
    }

    {   // ---- 风控与设备 ----
        NSMutableArray *secs = [NSMutableArray array];
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_device_fake" title:@"伪装设备指纹" subtitle:@"设备指纹固定为另一个随机值（与下一项二选一）" icon:@"person.crop.rectangle" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_device_empty" title:@"设备码返回空值" subtitle:@"风控取指纹时返回空值（与上一项二选一）" icon:@"delete.left.fill" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_block_device_upload" title:@"拦截设备指纹上传" subtitle:@"阻止把设备指纹上传给服务器" icon:@"nosign" defOn:NO]];
            [its addObject:[REAItem toggleWithKey:@"switch_device_intercept" title:@"拦截设备指纹上报出口" subtitle:@"直接阻断风控 SDK 的上报出口（比上一项更彻底）" icon:@"arrow.up.doc.fill" defOn:NO]];
            REASection *sec = [REASection new];
            sec.title = @"设备指纹"; sec.icon = @"circle"; sec.subtitle = @"设备码怎么给、要不要传上去";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_bypass_jailbreak" title:@"越狱检测绕过" subtitle:@"让 App 认为设备没有越狱" icon:@"shield.lefthalf.fill" defOn:YES]];
            [its addObject:[REAItem toggleWithKey:@"switch_risk_login_bypass" title:@"风险设备登录" subtitle:@"越狱设备重新登录不再被拦下（登录包标记为安全）" icon:@"shield.lefthalf.filled" defOn:YES]];
            [its addObject:[REAItem actionWithTitle:@"设备检测" subtitle:@"看 App 眼里的这台设备（越狱 / 注入判定等）" icon:@"waveform.path.ecg" actionLabel:@"检测" action:@"reaActionDeviceCheck"]];
            REASection *sec = [REASection new];
            sec.title = @"检测绕过"; sec.icon = @"circle"; sec.subtitle = @"别让 App 认出这台设备有问题";
            sec.items = its;
            [secs addObject:sec];
        }
        {
            NSMutableArray *its = [NSMutableArray array];
            [its addObject:[REAItem toggleWithKey:@"switch_bugly_off" title:@"关闭崩溃上报（诊断）" subtitle:@"关掉 Bugly，崩溃改落系统报告（查完关回）" icon:@"ladybug.fill" defOn:NO]];
            [its addObject:[REAItem actionWithTitle:@"查看运行日志" subtitle:@"面板与 Hook 的最近记录（含等级统计）" icon:@"doc.text" actionLabel:@"查看" action:@"reaActionShowLog"]];
            [its addObject:[REAItem toggleWithKey:@"rea_show_report" title:@"启动后弹出 Hook 报告" subtitle:@"立即生效 · 启动 2s 后弹一次「装上几条 / MISS 几条」" icon:@"doc.text.magnifyingglass" defOn:YES]];
            REASection *sec = [REASection new];
            sec.title = @"诊断"; sec.icon = @"text.alignleft"; sec.subtitle = @"出问题时要看的东西";
            sec.items = its;
            [secs addObject:sec];
        }
        REAModule *md = [REAModule new];
        md.title = @"风控与设备"; md.icon = @"shield.lefthalf.fill"; md.subtitle = @"设备指纹 / 检测绕过 / 诊断";
        md.sections = secs;
        [mods addObject:md];
    }
    return mods;
}

#pragma mark - 总开关分组

// 从菜单数据里现算，不写死列表：以后加减净化细项，总开关自动跟上。
//
// v13.0-P0：**排除 purify_splash_ad**。总开关是"一把梭"，而开屏那一层的实现方式
// （拦 `getSplashAdForColdLaunch`，一个 void 的"发起拉取"入口）会切断启动回调链，
// 表现就是卡启动图。总开关不能顺手把 App 弄挂 —— 这一项必须单独拨，且拨之前要读提示。
static NSArray<NSString *> *REAUIMasterGroupKeys(NSString *masterKey)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![masterKey isEqualToString:@"purify_master"]) return out;
    for (REAModule *m in REABuildMenu()) {
        for (REASection *sec in m.sections) {
            for (REAItem *it in sec.items) {
                if (it.isAction || it.key.length == 0) continue;
                if ([it.key isEqualToString:masterKey]) continue;
                if ([it.key isEqualToString:@"purify_splash_ad"]) continue;   /* 见上 */
                if (![it.key hasPrefix:@"purify_"]) continue;
                [out addObject:it.key];
            }
        }
    }
    return out;
}

#pragma mark - 小工具

static UIImage *REASymbol(NSString *name, UIColor *tint)
{
    if (name.length == 0) return nil;
    UIImage *img = nil;
    if (@available(iOS 13.0, *)) {
        img = [UIImage systemImageNamed:name];
    }
    if (img == nil) {
        if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:@"circle"];
    }
    return tint ? [img imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysTemplate] : img;
}

/* v13.0-P0：定义在文件后部（那里才能引用 REAWindow 做排除）。 */
static NSArray<UIWindow *> *REAAllWindows(void);
static UIWindow *REAAnyWindow(void);
static NSString *REAWindowSnapshot(void);

static UIViewController *REATopViewController(void)
{
    /* v13.0-P0：宿主窗口未必是 key（真机 isKeyWindow 长期为假），顶层 VC 必须从
       "任一可见宿主窗口"取，不能从 keyWindow 取，否则永远拿到 nil 或自己的覆盖窗口。 */
    UIViewController *top = REAAnyWindow().rootViewController;
    while (top) {
        UIViewController *p = top.presentedViewController;
        if (p && !p.isBeingDismissed) { top = p; continue; }
        if ([top isKindOfClass:[UINavigationController class]])
            top = ((UINavigationController *)top).visibleViewController;
        else if ([top isKindOfClass:[UITabBarController class]])
            top = ((UITabBarController *)top).selectedViewController;
        else break;
    }
    return top;
}

/* 统一弹窗落点（实现见文件末尾）。
   面板现在挂在「覆盖窗口」里（UIWindowLevelNormal + 1，见 start 里的注释）。
   覆盖窗口比宿主内容高一层；不穿透的区域被它接住，穿透的区域仍归宿主。
   所有弹窗必须走这一个入口：面板开着就弹在面板所在窗口，否则弹在宿主顶层。 */
extern void REAPresentFromBest(UIViewController *vc);
extern void REAOverlayPanelClose(void);
extern BOOL REAOverlayPanelVisible(void);

static void REAToast(NSString *text)
{
    if (text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"[REA-Test]"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        REAPresentFromBest(ac);
    });
}

#pragma mark - 开关单元格

@interface REASwitchCell : UITableViewCell
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
@property (nonatomic, strong) REAItem *item;
- (void)configureWithItem:(REAItem *)item;
@end

@implementation REASwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        _sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        [_sw addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _sw;
        self.textLabel.numberOfLines = 1;
        self.detailTextLabel.numberOfLines = 3;
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)configureWithItem:(REAItem *)item
{
    self.item = item;
    self.textLabel.text = item.title;
    self.detailTextLabel.text = item.subtitle;
    if (@available(iOS 13.0, *)) {
        self.imageView.image = REASymbol(item.icon, [UIColor systemBlueColor]);
    }
    BOOL on = item.key.length ? REAUIFlag(item.key) : item.defOn;
    [self.sw setOn:on animated:NO];
}

- (void)switchChanged
{
    BOOL on = self.sw.isOn;
    if (self.item.key.length) REAUISetFlag(self.item.key, on);
    if (self.onToggle) self.onToggle(on);
}

@end

#pragma mark - 动作单元格

@interface REAActionCell : UITableViewCell
- (void)configureWithItem:(REAItem *)item;
@end

@implementation REAActionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        self.textLabel.numberOfLines = 1;
        self.detailTextLabel.numberOfLines = 3;
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)configureWithItem:(REAItem *)item
{
    self.textLabel.text = item.title;
    self.detailTextLabel.text = item.subtitle;
    if (@available(iOS 13.0, *)) {
        self.imageView.image = REASymbol(item.icon, [UIColor systemTealColor]);
    }
}

@end

#pragma mark - 动作实现（全部真实可用，不省略）

static void reaActionDefault(REAItem *item)
{
    REAToast([NSString stringWithFormat:@"「%@」在本复刻版里没有独立实现。", item.title ?: @"该动作"]);
}

extern void REAShowLocationPicker(void);

static void reaActionSetLocation(REAItem *item)
{
    /* v13.2：不再用三个输入框凑合，改成参考实现同款的地图拾取窗口
       （HushLocationPickerController 的能力：长按取点 / 准星拾取 / 历史 / 地图类型）。 */
    REAShowLocationPicker();
    return;
}

static void reaActionSetLocationLegacy(REAItem *item)
{
    NSDictionary *cur = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kREAFakeLocationKey];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设置虚拟坐标"
                                                              message:@"纬度 / 经度 / 海拔"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"纬度 39.9042";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = cur[@"lat"] ? [cur[@"lat"] stringValue] : @"";
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"经度 116.4074";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = cur[@"lng"] ? [cur[@"lng"] stringValue] : @"";
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"海拔 50";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.text = cur[@"alt"] ? [cur[@"alt"] stringValue] : @"";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        double lat = [ac.textFields[0].text doubleValue];
        double lng = [ac.textFields[1].text doubleValue];
        double alt = [ac.textFields[2].text doubleValue];
        NSDictionary *loc = @{ @"lat": @(lat), @"lng": @(lng), @"alt": @(alt) };
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:loc forKey:kREAFakeLocationKey];
        [d setBool:YES forKey:@"switch_virtual_location"];
        [d synchronize];
        REAUILog(@"虚拟坐标写入 %.6f,%.6f alt=%.1f", lat, lng, alt);
        REAToast([NSString stringWithFormat:@"已保存：%.6f, %.6f（海拔 %.1f）", lat, lng, alt]);
    }]];
    REAPresentFromBest(ac);
}

static void reaActionClearLocation(REAItem *item)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kREAFakeLocationKey];
    [d setBool:NO forKey:@"switch_virtual_location"];
    [d synchronize];
    REAToast(@"虚拟定位已清除（回到真实坐标）");
}

static void reaActionShowHookReport(REAItem *item) { REAShowHookReportBridge(); }
static void reaActionShowHitReport(REAItem *item)  { REAShowHitReportBridge(); }
static void reaActionReinstall(REAItem *item)      { REAReinstallHooksBridge(); REAToast(@"已触发重新安装（见日志）"); }

static void reaActionResetAll(REAItem *item)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [d dictionaryRepresentation];
    NSUInteger n = 0;
    for (NSString *k in all) {
        if ([k hasPrefix:@"switch_"] || [k hasPrefix:@"purify_"] ||
            [k hasPrefix:@"regret_"] || [k hasPrefix:@"rea_"]) {
            if ([k isEqualToString:kREABallCenterKey]) continue;
            if ([k isEqualToString:kREABallEnabledKey]) continue;
            [d removeObjectForKey:k];
            n++;
        }
    }
    [d synchronize];
    REAToast([NSString stringWithFormat:@"已重置 %lu 个开关（悬浮球设置保留）", (unsigned long)n]);
}

static void reaActionShowLog(REAItem *item)
{
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [path stringByAppendingPathComponent:@"BluedHushREA.log"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text.length == 0) text = @"（日志为空或尚未写入）";
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSInteger total = (NSInteger)lines.count;
    NSInteger from = MAX(0, total - 40);
    NSString *tail = [[lines subarrayWithRange:NSMakeRange((NSUInteger)from, (NSUInteger)(total - from))]
                      componentsJoinedByString:@"\n"];
    UIViewController *host = REATopViewController();
    if (host == nil) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"运行日志（尾部 40 行）"
                                                              message:tail
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    REAPresentFromBest(ac);
}

static void reaActionDeviceCheck(REAItem *item)
{
    NSString *msg = [NSString stringWithFormat:@"越狱：%@\n注入：%@\n设备：%@",
                     [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"是(检测到 /var/jb)" : @"否",
                     @"是（本插件正在运行）",
                     [[UIDevice currentDevice] name]];
    UIViewController *host = REATopViewController();
    if (host == nil) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设备检测"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    REAPresentFromBest(ac);
}

static void reaActionListPlaceholder(NSString *title)
{
    REAToast([NSString stringWithFormat:@"%@：本复刻版未实现列表页（Hook 侧数据仍会记录）。", title]);
}

static void reaActionRiskList(REAItem *item)       { reaActionListPlaceholder(@"风险用户名单"); }
static void reaActionDeletedList(REAItem *item)    { reaActionListPlaceholder(@"已注销用户"); }
static void reaActionSuspiciousList(REAItem *item) { reaActionListPlaceholder(@"可疑名单"); }
static void reaActionStalkList(REAItem *item)      { reaActionListPlaceholder(@"视奸列表"); }

static void REAInvokeAction(REAItem *item)
{
    NSString *sel = item.actionSelector ?: @"reaActionDefault";
    /* 用显式字符串分派，避免 performSelector 的函数指针类型陷阱 */
    if ([sel isEqualToString:@"reaActionSetLocation"])        { reaActionSetLocation(item); return; }
    if ([sel isEqualToString:@"reaActionClearLocation"])      { reaActionClearLocation(item); return; }
    if ([sel isEqualToString:@"reaActionShowHookReport"])     { reaActionShowHookReport(item); return; }
    if ([sel isEqualToString:@"reaActionShowHitReport"])      { reaActionShowHitReport(item); return; }
    if ([sel isEqualToString:@"reaActionReinstall"])          { reaActionReinstall(item); return; }
    if ([sel isEqualToString:@"reaActionResetAll"])           { reaActionResetAll(item); return; }
    if ([sel isEqualToString:@"reaActionShowLog"])            { reaActionShowLog(item); return; }
    if ([sel isEqualToString:@"reaActionDeviceCheck"])        { reaActionDeviceCheck(item); return; }
    if ([sel isEqualToString:@"reaActionRiskList"])           { reaActionRiskList(item); return; }
    if ([sel isEqualToString:@"reaActionDeletedList"])        { reaActionDeletedList(item); return; }
    if ([sel isEqualToString:@"reaActionSuspiciousList"])     { reaActionSuspiciousList(item); return; }
    if ([sel isEqualToString:@"reaActionStalkList"])          { reaActionStalkList(item); return; }
    reaActionDefault(item);
}

#pragma mark - 模块详情页（对应原版 HushModuleDetailController）

@interface READetailController : UITableViewController
@property (nonatomic, strong) REAModule *module;
- (instancetype)initWithModule:(REAModule *)module;
@end

@implementation READetailController

- (instancetype)initWithModule:(REAModule *)module
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _module = module;
        self.title = module.title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    REAUILog(@"模块详情页打开：%@（%lu 个分区）",
             self.module.title, (unsigned long)self.module.sections.count);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(closeSelf)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重装 Hook"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(reinstall)];
}

- (void)closeSelf
{
    /* 面板挂在覆盖窗口里（不是 modal presented），关闭走覆盖窗口自己的拆卸逻辑 */
    REAOverlayPanelClose();
}

- (void)reinstall
{
    REAReinstallHooksBridge();
    REAToast(@"已触发重新安装 Hook（见日志）");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return (NSInteger)self.module.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.module.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    REASection *s = self.module.sections[(NSUInteger)section];
    return s.title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    REASection *s = self.module.sections[(NSUInteger)section];
    if (s.subtitle.length == 0) return nil;
    NSInteger on = 0, total = 0;
    for (REAItem *it in s.items) {
        if (it.isAction) continue;
        total++;
        if (it.key.length && REAUIFlag(it.key)) on++;
    }
    return [NSString stringWithFormat:@"已开 %ld/%ld · %@", (long)on, (long)total, s.subtitle];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    REASection *s = self.module.sections[(NSUInteger)indexPath.section];
    REAItem *item = s.items[(NSUInteger)indexPath.row];
    if (item.isAction) {
        static NSString *aid = @"rea-action";
        REAActionCell *cell = [tableView dequeueReusableCellWithIdentifier:aid];
        if (cell == nil) cell = [[REAActionCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                     reuseIdentifier:aid];
        [cell configureWithItem:item];
        return cell;
    }
    static NSString *sid = @"rea-switch";
    REASwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
    if (cell == nil) cell = [[REASwitchCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:sid];
    [cell configureWithItem:item];
    __weak typeof(self) weakSelf = self;
    cell.onToggle = ^(BOOL on) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        NSIndexSet *idx = [NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.section];
        [self2.tableView reloadSections:idx withRowAnimation:UITableViewRowAnimationNone];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    REASection *s = self.module.sections[(NSUInteger)indexPath.section];
    REAItem *item = s.items[(NSUInteger)indexPath.row];
    if (!item.isAction) return;
    REAInvokeAction(item);
}

@end

#pragma mark - 模块列表（对应原版 HushSettingsPanel）

@interface REAModuleListController : UITableViewController
@property (nonatomic, strong) NSArray<REAModule *> *modules;
@end

@implementation REAModuleListController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.modules = REABuildMenu();
    self.title = @"小蓝助手";
    REAUILog(@"面板打开：%lu 个模块", (unsigned long)self.modules.count);
    self.navigationController.navigationBar.translucent = NO;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(closeSelf)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全部关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(turnAllOff)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)closeSelf
{
    /* 面板挂在覆盖窗口里（不是 modal presented），关闭走覆盖窗口自己的拆卸逻辑 */
    REAOverlayPanelClose();
}

- (void)turnAllOff
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSUInteger n = 0;
    for (REAModule *m in self.modules) {
        for (REASection *s in m.sections) {
            for (REAItem *it in s.items) {
                if (it.isAction || it.key.length == 0) continue;
                [d setBool:NO forKey:it.key];
                n++;
            }
        }
    }
    [d synchronize];
    [self.tableView reloadData];
    REAToast([NSString stringWithFormat:@"已关闭 %lu 个开关", (unsigned long)n]);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.modules.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"[REA-Test] 复刻版 · 点任意分类进入开关列表 · 开关即时写入 NSUserDefaults 并立即对 Hook 生效";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *mid = @"rea-module";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:mid];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                     reuseIdentifier:mid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    REAModule *m = self.modules[(NSUInteger)indexPath.row];
    cell.textLabel.text = m.title;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"已开 %ld/%ld · %@",
                                 (long)[m enabledCount], (long)[m totalCount], m.subtitle];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    if (@available(iOS 13.0, *)) {
        cell.imageView.image = REASymbol(m.icon, [UIColor systemBlueColor]);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    REAModule *m = self.modules[(NSUInteger)indexPath.row];
    READetailController *vc = [[READetailController alloc] initWithModule:m];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 悬浮球（对应原版 HushFloatBall）

@interface REAFloatBall : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation REAFloatBall

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 6.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        CGFloat inset = frame.size.width * 0.22;
        _iconView = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, inset, inset)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];
        [self refreshIcon];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                        action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.6;
        [self addGestureRecognizer:lp];
        REAUILog(@"悬浮球创建 frame=%@", NSStringFromCGRect(frame));
    }
    return self;
}

- (void)refreshIcon
{
    UIImage *img = nil;
    if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:@"bolt.horizontal.circle.fill"];
    if (img == nil) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(28, 28), NO, 0);
        [[UIColor whiteColor] set];
        [@"蓝" drawInRect:CGRectMake(4, 2, 22, 22)
                 withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:17],
                                  NSForegroundColorAttributeName: [UIColor whiteColor]}];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    self.iconView.image = [img imageWithTintColor:[UIColor whiteColor]
                                    renderingMode:UIImageRenderingModeAlwaysTemplate];
    self.iconView.tintColor = [UIColor whiteColor];
}

- (void)handleTap:(UITapGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateEnded) return;
    REAUILog(@"悬浮球被点击");
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)g
{
    UIWindow *win = self.window;
    if (win == nil) return;
    CGPoint t = [g translationInView:win];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    CGFloat half = self.bounds.size.width / 2.0;
    c.x = MAX(half + 4.0, MIN(c.x, win.bounds.size.width - half - 4.0));
    c.y = MAX(half + 4.0, MIN(c.y, win.bounds.size.height - half - 4.0));
    self.center = c;
    [g setTranslation:CGPointZero inView:win];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        /* 贴边吸附 */
        CGFloat leftX = half + 4.0;
        CGFloat rightX = win.bounds.size.width - half - 4.0;
        CGFloat targetX = (c.x - leftX < rightX - c.x) ? leftX : rightX;
        [UIView animateWithDuration:0.22 animations:^{
            self.center = CGPointMake(targetX, self.center.y);
        } completion:^(BOOL finished) {
            [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(self.center)
                                                      forKey:kREABallCenterKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    REAUILog(@"悬浮球长按 -> 快捷菜单");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"REAFloatBallLongPress" object:nil];
}

@end

#pragma mark - 覆盖窗口（UIWindowLevelNormal + 1；球以外区域默认穿透，面板打开时整窗接管）

@interface REAWindow : UIWindow
@property (nonatomic, strong) REAFloatBall *ball;
/* 面板是否开在本窗口内。为 YES 时 hitTest 不再穿透 —— 这是"面板点不动"的根因修复：
   面板以前是 present 到宿主窗口上的，而本窗口层级更高、对非球区域返回 nil，
   于是面板整页收不到触摸。现在面板直接挂在本窗口，扣到面板就整窗响应。 */
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong) UIView *panelMask;
@property (nonatomic, strong) UIViewController *panelHostVC;
@end

#pragma mark - 窗口探测（v13.0-P0）

/* 真机实测（BluedHushREA.log，v12）：`[UI] 找不到 keyWindow，UI 延后` 触发 229 次，
   单次会话连续 40 次 / 20 秒后彻底放弃 —— 悬浮球与面板从未挂上过。
   根因：把 `isKeyWindow` 当成了"有窗口"的判据。重签 / 套壳 / 多场景下宿主主窗口
   存在且可见，但 isKeyWindow 长期为假（或被广告 SDK 的窗口占着）。 */
static NSArray<UIWindow *> *REAAllWindows(void)
{
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w) [out addObject:w];
            }
        }
    }
    if (out.count == 0) {
        NSArray<UIWindow *> *legacy = [UIApplication sharedApplication].windows;
        if (legacy.count) [out addObjectsFromArray:legacy];
    }
    return out;
}

/* 只要"存在可见的宿主窗口"就足以承载覆盖层；isKeyWindow 只用来挑最上层那个。 */
static UIWindow *REAAnyWindow(void)
{
    UIWindow *fallback = nil;
    for (UIWindow *w in REAAllWindows()) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if ([w isKindOfClass:[REAWindow class]]) continue;   /* 自己的覆盖窗口不算宿主 */
        if (w.hidden) continue;
        if (w.alpha <= 0.01) continue;
        if (w.bounds.size.width <= 0 || w.bounds.size.height <= 0) continue;
        if (w.isKeyWindow) return w;
        if (fallback == nil) fallback = w;
    }
    return fallback;
}

/* 一行现场快照：窗口数 / 每个窗口的类名、层级、可见性、key 状态。
   放弃挂载时必须打这一行 —— "放弃"两个字对定位毫无价值。 */
static NSString *REAWindowSnapshot(void)
{
    NSMutableString *s = [NSMutableString string];
    NSUInteger i = 0;
    for (UIWindow *w in REAAllWindows()) {
        [s appendFormat:@"%@%@(lvl=%.0f,hid=%d,alpha=%.2f,key=%d)",
         (i ? @" | " : @""), NSStringFromClass([w class]),
         w.windowLevel, (int)w.hidden, w.alpha, (int)w.isKeyWindow];
        i++;
    }
    if (i == 0) [s appendString:@"<none>"];
    return s;
}

@implementation REAWindow

- (BOOL)canBecomeKeyWindow
{
    /* 面板里有文本框（虚拟定位、日志等 Alert）时需要键盘，非 key 窗口拿不到键盘。
       这里允许成为 key，但全程不调用 makeKeyAndVisible，所以不会抢宿主的 key 状态。 */
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (self.panelVisible) {
        /* 面板打开：整窗正常命中（遮罩 / 面板 / 球 都按 UIKit 常规规则） */
        return [super hitTest:point withEvent:event];
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil) return nil;
    if (self.ball != nil && (hit == self.ball || [hit isDescendantOfView:self.ball])) return hit;
    /* 非球区域：返回 nil ⇒ 触摸继续下发给宿主窗口，宿主照常工作 */
    return nil;
}

@end

#pragma mark - UI 控制器单例

@interface REAUI : NSObject
@property (nonatomic, strong) REAWindow *window;
@property (nonatomic, strong) REAFloatBall *ball;
@property (nonatomic, assign) BOOL started;
+ (instancetype)shared;
- (void)start;
- (void)openPanel;
- (void)closePanel;
- (BOOL)panelVisible;
- (void)showQuickMenu;
@end

@implementation REAUI

+ (instancetype)shared
{
    static REAUI *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [REAUI new]; });
    return s;
}

- (void)start
{
    if (self.started) { REAUILog(@"UI 已启动，跳过重复安装"); return; }
    self.started = YES;

    UIWindow *kw = REAAnyWindow();
    if (kw == nil) { REAUILog(@"宿主窗口尚未可见（%@），UI 延后", REAWindowSnapshot()); self.started = NO; return; }

    REAWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        win = [[REAWindow alloc] initWithWindowScene:kw.windowScene];
    } else {
        win = [[REAWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    win.frame = [UIScreen mainScreen].bounds;
    /* v13.0-P0：层级从 Alert+1 降到 Normal+1。
       Alert+1 会盖住宿主自己的弹窗（报告 / 权限 / 广告收尾），且一旦本窗口成为 key，
       宿主"主窗口是否 key"的判定就会被改写 —— 这正是启动流程卡住的放大器。
       悬浮球只需要在普通内容之上、系统弹窗与 Alert 之下。 */
    win.windowLevel = UIWindowLevelNormal + 1;
    win.backgroundColor = [UIColor clearColor];
    win.rootViewController = [[UIViewController alloc] init];
    win.hidden = NO;
    self.window = win;
    /* 把 key 还给宿主：挂完覆盖窗口可能出现 key 漂移，主动还原一次。 */
    if (kw.isKeyWindow == NO) { [kw makeKeyWindow]; }
    REAUILog(@"window attached level=%.0f hostKey=%d snap=%@",
             win.windowLevel, (int)kw.isKeyWindow, REAWindowSnapshot());

    if (!REAUIFlag(kREABallEnabledKey)) {
        REAUILog(@"悬浮球开关关闭（%@=0）", kREABallEnabledKey);
        [self refreshBallFrame];
        return;
    }

    CGFloat size = 52.0;
    CGPoint saved = CGPointFromString([[NSUserDefaults standardUserDefaults]
                                       objectForKey:kREABallCenterKey] ?: NSStringFromCGPoint(CGPointZero));
    if (CGPointEqualToPoint(saved, CGPointZero)) {
        saved = CGPointMake(win.bounds.size.width - size, win.bounds.size.height * 0.62);
    }
    saved.x = MAX(size / 2 + 4, MIN(saved.x, win.bounds.size.width - size / 2 - 4));
    saved.y = MAX(size / 2 + 4, MIN(saved.y, win.bounds.size.height - size / 2 - 4));

    REAFloatBall *ball = [[REAFloatBall alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    ball.center = saved;
    ball.userInteractionEnabled = YES;
    __weak typeof(self) weakSelf = self;
    ball.onTap = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        [self2 openPanel];
    };
    win.rootViewController.view.userInteractionEnabled = YES;
    [win.rootViewController.view addSubview:ball];
    self.ball = ball;
    /* v11 关键修复：必须把球回填到窗口，否则 -[REAWindow hitTest:withEvent:]
       里 self.ball 恒为 nil → 所有触摸都被判成"球之外的区域"丢弃 → 拖不动也点不动。 */
    win.ball = ball;

    [[NSNotificationCenter defaultCenter] addObserverForName:@"REAFloatBallLongPress"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) self3 = weakSelf;
        [self3 showQuickMenu];
    }];

    REAUILog(@"悬浮球已挂载 (%.0f, %.0f)", ball.center.x, ball.center.y);
}

- (void)refreshBallFrame
{
    if (self.ball) self.ball.hidden = !REAUIFlag(kREABallEnabledKey);
}

- (void)openPanel
{
    REAWindow *win = self.window;
    if (win == nil) { REAUILog(@"openPanel: 覆盖窗口尚未建立"); return; }
    if (win.panelVisible) { REAUILog(@"openPanel: 面板已开"); return; }
    UIViewController *root = win.rootViewController;
    if (root == nil) { REAUILog(@"openPanel: 覆盖窗口没有 rootViewController"); return; }

    /* 面板挂进「覆盖窗口」自己 —— 不再 present 到宿主窗口。
       这样命中链路只有一条：触摸 → REAWindow.hitTest(panelVisible=YES) → 面板视图，
       不会出现"看得见、点不动"。 */
    REAModuleListController *list = [[REAModuleListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.view.backgroundColor = [UIColor systemBackgroundColor];
    if (@available(iOS 13.0, *)) {
        nav.view.layer.cornerRadius = 16.0;
        nav.view.layer.cornerCurve = kCACornerCurveContinuous;
    } else {
        nav.view.layer.cornerRadius = 16.0;
    }
    nav.view.layer.masksToBounds = YES;

    CGRect bounds = win.bounds;
    CGFloat topInset = 0.0;
    if (@available(iOS 11.0, *)) topInset = win.safeAreaInsets.top;
    CGFloat panelTop = MAX(topInset + 8.0, bounds.size.height * 0.06);
    nav.view.frame = CGRectMake(0, panelTop, bounds.size.width, bounds.size.height - panelTop);
    nav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *mask = [[UIView alloc] initWithFrame:bounds];
    mask.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.36];
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mask.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleMaskTap:)];
    [mask addGestureRecognizer:tap];

    [root addChildViewController:nav];
    [root.view addSubview:mask];
    [root.view addSubview:nav.view];
    [nav didMoveToParentViewController:root];
    [root.view bringSubviewToFront:self.ball];   /* 球永远在最上面 */

    win.panelMask = mask;
    win.panelHostVC = nav;
    win.panelVisible = YES;
    REAUILog(@"面板已挂进覆盖窗口（%.0fx%.0f）", nav.view.frame.size.width, nav.view.frame.size.height);
}

- (void)handleMaskTap:(UITapGestureRecognizer *)g
{
    [self closePanel];
}

- (void)closePanel
{
    REAWindow *win = self.window;
    if (win == nil) return;
    UIViewController *nav = win.panelHostVC;
    UIView *mask = win.panelMask;
    win.panelVisible = NO;
    win.panelHostVC = nil;
    win.panelMask = nil;
    [nav willMoveToParentViewController:nil];
    [nav.view removeFromSuperview];
    [nav removeFromParentViewController];
    [mask removeFromSuperview];
    REAUILog(@"面板已关闭");
}

- (BOOL)panelVisible
{
    return self.window != nil ? self.window.panelVisible : NO;
}

- (void)showQuickMenu
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"小蓝助手"
                                                              message:@"快捷入口"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"打开完整面板" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [[REAUI shared] openPanel]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看 Hook 报告" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { REAShowHookReportBridge(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看触发统计" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { REAShowHitReportBridge(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮球" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kREABallEnabledKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[REAUI shared] refreshBallFrame];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController && self.ball) {
        ac.popoverPresentationController.sourceView = self.ball;
        ac.popoverPresentationController.sourceRect = self.ball.bounds;
    }
    REAPresentFromBest(ac);
}

@end

#pragma mark - 对外接口

void REAUIStart(void)
{
    /* v13.0-P0：极早期入口，ctor / +load 阶段调用一次。
       实测教训：不要为了等 keyWindow 连试 40 次（20 秒）。宿主窗口"存在且可见"就够了，
       isKeyWindow 在重签 / 多场景 / 广告窗口期间长期为假。这里上限收到 6 次（3 秒），
       失败时把窗口现场一行打出来，方便直接判"宿主还没建窗口"还是"建了但不可见"。
       重试只在主队列，且不会触发任何宿主类 +initialize（只用 class_copyMethodList 一类只 realize 的 API）。 */
    static NSInteger attempts = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        REAUI *ui = [REAUI shared];
        if (ui.started) return;
        [ui start];
        attempts++;
        if (!ui.started && attempts < 6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                REAUIStart();
            });
        } else if (attempts >= 6 && !ui.started) {
            REAUILog(@"UI 挂载失败（重试 %ld 次 / %.1fs），snap=%@",
                     (long)attempts, attempts * 0.5, REAWindowSnapshot());
        }
    });
}

void REAPromptLocation(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        reaActionSetLocation(nil);
    });
}

/* 供宿主"设置"页入口 / 悬浮球调用（Tweak.xm 的 REAOpenPanelBridge 转发到这里）。 */
void REAOpenPanel(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[REAUI shared] openPanel];
    });
}

BOOL REAOverlayPanelVisible(void)
{
    return [REAUI shared].panelVisible;
}

void REAOverlayPanelClose(void)
{
    if ([NSThread isMainThread]) {
        [[REAUI shared] closePanel];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[REAUI shared] closePanel];
        });
    }
}

void REAPresentFromBest(UIViewController *vc)
{
    if (vc == nil) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            REAPresentFromBest(vc);
        });
        return;
    }
    REAUI *ui = [REAUI shared];
    REAWindow *win = ui.window;
    UIViewController *presenter = nil;
    if (win != nil && win.panelVisible && win.panelHostVC != nil) {
        presenter = win.panelHostVC;
        if ([presenter isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = [(UINavigationController *)presenter topViewController];
            if (top != nil) presenter = top;
        }
    }
    if (presenter == nil) presenter = REATopViewController();
    if (presenter == nil) {
        REAUILog(@"弹窗放弃：没有可用的 presenter");
        return;
    }
    while (presenter.presentedViewController != nil) presenter = presenter.presentedViewController;
    [presenter presentViewController:vc animated:YES completion:nil];
}
