// ============================================================================
// BluedHushREA —— UI 交互层（v9）
//
// 逆向依据（全部来自原版 BluedHush_5.19.dylib 的 __objc_classlist / __objc_methlist）：
//   HushFloatBall : UIView        { iconView: UIImageView }
//        - initWithFrame: / refreshIcon / onTap / onPan:
//        → 悬浮球是**纯代码 UIView**，靠 tap + pan 手势（不是 UIWindow 里的按钮，也没有 xib）
//   HushWindowHelper : NSObject   （0 方法：仅承载 helper/常量，窗口逻辑在别处）
//   HushSettingsPanel : UIViewController
//        { table: UITableView, modules: NSArray, searchCtl: UISearchController,
//          searchIndex/searchResults, hushTopSearchBar, hushFooterInsetX, pendingScrollTop }
//        - buildModel / openModule: / showLog / hushCloseModal / hushFooterText
//        - tableView:numberOfSectionsInTableView: / …cellForRowAtIndexPath: / didSelectRow…
//        → 设置主界面是**纯代码 UIViewController + UITableView + UISearchController**，
//          多级菜单由 `modules` 数组驱动（module → section → item 三层），底部是作者 footer
//   HushModuleEntry : NSObject  { title, icon, subtitle, footer, sections, items }
//   HushModuleSection : NSObject{ title, icon, subtitle, items }
//   HushSwitchItem : NSObject   { key, title, subtitle, icon, effect }
//   HushActionItem : NSObject   { title, subtitle, icon, actionLabel, handler }
//   HushSwitchCell : UITableViewCell { sw: UISwitch, onToggle: block }
//        - configureTitle:subtitle:icon:effect:on: / switchChanged
//   HushModuleDetailController : UITableViewController
//        - initWithTitle:sections:footer: / hushAccessoryWithText:style:
//   HushAuthorFooterView : UITableViewHeaderFooterView - configureText:inset:tint:
//   HushEntryButtonTarget : NSObject { cell(weak) } - hushDown / hushUp / hushCancel（点按高亮）
//   HushConfig : NSObject { defaults: NSUserDefaults, flagCache, prefsSnapshot }
//        - isEnabled: / isEnabled:default: / setEnabled:forKey: / registerDefaults
//        - stringForKey: / setString:forKey: / customLat / customLng / customAltitude
//        → **持久化就是 NSUserDefaults**（key 就是 "switch_xxx" 字符串，与 Hook 里读的完全同一批键）
//
// 资源：原版二进制里 .bundle=0、.xib=0、.nib=0、Assets.car=0、imageNamed=0，
//       只出现 `systemImageNamed:`（2 次）→ **图标全用 SF Symbols，无任何资源包**。
//       所以不需要往 Actions 里加 bundle 打包步骤，产物依旧只有一个 .dylib + plist。
//
// 本文件职责：复刻"悬浮球 + 分类菜单 + 开关持久化"这一层，纯代码、零 Logos、零 substrate。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - Tweak.xm 暴露的调试入口

extern BOOL REAFlagBridge(NSString *key);
extern void REAShowHookReportBridge(void);
extern void REAShowHitReportBridge(void);
extern void REAReinstallHooksBridge(void);
extern void REALogBridge(NSString *fmt, ...);

#pragma mark - 键常量

static NSString *const kREABallCenterKey = @"rea_ball_center";
static NSString *const kREABallEnabledKey = @"rea_ball_enabled";
static NSString *const kREAPanelStyleKey  = @"rea_panel_style";

#pragma mark - 配置读写（等价 HushConfig，直接落在 NSUserDefaults）

static BOOL REAUIFlag(NSString *key, BOOL def) {
    if (!key.length) return def;
    @try {
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        if (v == nil) return def;
        return [v boolValue];
    } @catch (NSException *e) {
        return def;
    }
}

static void REAUISetFlag(NSString *key, BOOL on) {
    if (!key.length) return;
    @try {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
    } @catch (NSException *e) { }
}

#pragma mark - 数据模型（对应 HushSwitchItem / HushActionItem / HushModuleSection / HushModuleEntry）

@interface REAItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *icon;     // SF Symbol 名
@end

@implementation REAItem
@end

@interface REAToggle : REAItem
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) BOOL defOn;
@end

@implementation REAToggle
@end

@interface REAAction : REAItem
@property (nonatomic, copy) void (^handler)(void);
@property (nonatomic, copy) NSString *actionLabel;
@end

@implementation REAAction
@end

@interface REASection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, strong) NSArray<REAItem *> *items;
@end

@implementation REASection
@end

@interface REAModule : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, strong) NSArray<REASection *> *sections;
@end

@implementation REAModule
@end

#pragma mark - 前向声明

// 悬浮球需要回调单例；面板需要菜单模型工厂；定位输入框由 action 触发。
// 三者都在本文件后半段实现，这里先声明，避免"隐式声明"在 -Werror 下炸掉。
@class REAOverlayWindow, REAFloatBallView;

@interface REAUILoad : NSObject
@property (nonatomic, strong) REAOverlayWindow *window;
@property (nonatomic, strong) REAFloatBallView *ball;
@property (nonatomic, assign) BOOL started;
+ (instancetype)shared;
- (void)start;
- (void)saveBallCenter:(CGPoint)c;
- (CGPoint)ballCenter;
- (void)openPanel;
- (void)showQuickMenu;
@end

static NSArray<REAModule *> *REABuildModules(void);
void REAPromptLocation(void);

#pragma mark - 小工具

static UIImage *REASymbol(NSString *name, UIColor *tint) {
    if (!name.length) return nil;
    UIImage *img = nil;
    @try {
        if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
            img = [UIImage systemImageNamed:name];
        }
    } @catch (NSException *e) { }
    if (img && tint) img = [img imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    return img;
}

static UIWindow *REAKeyWindow(void) {
    UIWindow *fallback = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) return w;
                    if (!fallback && w.windowLevel == UIWindowLevelNormal) fallback = w;
                }
            }
            if (fallback) return fallback;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                        if (w.windowLevel == UIWindowLevelNormal) return w;
                    }
                }
            }
        }
        if (@available(iOS 13.0, *)) { } else {
            return [UIApplication sharedApplication].keyWindow;
        }
    } @catch (NSException *e) { }
    return [UIApplication sharedApplication].keyWindow;
}

static UIViewController *REATopViewController(void) {
    UIViewController *vc = REAKeyWindow().rootViewController;
    @try {
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            vc = ((UINavigationController *)vc).visibleViewController ?: vc;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            vc = ((UITabBarController *)vc).selectedViewController ?: vc;
        }
    } @catch (NSException *e) { }
    return vc;
}

static void REAToast(NSString *text) {
    @autoreleasepool {
        UIWindow *kw = REAKeyWindow();
        if (!kw) return;
        UILabel *lb = [[UILabel alloc] init];
        lb.text = text;
        lb.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        lb.textColor = [UIColor whiteColor];
        lb.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.numberOfLines = 0;
        lb.layer.cornerRadius = 12;
        lb.layer.masksToBounds = YES;
        CGSize max = CGSizeMake(kw.bounds.size.width - 60, 220);
        CGRect rc = [text boundingRectWithSize:max
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{ NSFontAttributeName: lb.font }
                                       context:nil];
        CGSize sz = CGSizeMake(rc.size.width + 32, rc.size.height + 24);
        lb.frame = CGRectMake((kw.bounds.size.width - sz.width) / 2,
                              kw.bounds.size.height - sz.height - 100, sz.width, sz.height);
        lb.alpha = 0;
        [kw addSubview:lb];
        [UIView animateWithDuration:0.18 animations:^{ lb.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.35 delay:2.2 options:0 animations:^{ lb.alpha = 0; } completion:^(BOOL f2) {
                [lb removeFromSuperview];
            }];
        }];
    }
}

#pragma mark - 开关单元格（对应 HushSwitchCell）

@interface REASwitchCell : UITableViewCell
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
- (void)configureTitle:(NSString *)title
              subtitle:(NSString *)subtitle
                  icon:(NSString *)icon
                    on:(BOOL)on
              disabled:(BOOL)disabled;
@end

@implementation REASwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        self.sw = [[UISwitch alloc] init];
        self.accessoryView = self.sw;
        [self.sw addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
        self.textLabel.numberOfLines = 0;
        self.detailTextLabel.numberOfLines = 0;
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)configureTitle:(NSString *)title
              subtitle:(NSString *)subtitle
                  icon:(NSString *)icon
                    on:(BOOL)on
              disabled:(BOOL)disabled {
    self.textLabel.text = title ?: @"";
    self.detailTextLabel.text = subtitle ?: @"";
    if (@available(iOS 14.0, *)) {
        if (icon.length) self.imageView.image = REASymbol(icon, [UIColor systemBlueColor]);
    }
    [self.sw setOn:on animated:NO];
    self.sw.enabled = !disabled;
    self.contentView.alpha = disabled ? 0.55 : 1.0;
}

- (void)switchChanged {
    if (self.onToggle) self.onToggle(self.sw.isOn);
}

@end

#pragma mark - 详情页（对应 HushModuleDetailController）

@interface READetailController : UITableViewController
@property (nonatomic, strong) REAModule *module;
@end

@implementation READetailController

- (instancetype)initWithModule:(REAModule *)module {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.module = module;
        self.title = module.title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self
                                                     action:@selector(close)];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.module.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.module.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.module.sections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.module.sections[(NSUInteger)section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    REAItem *item = self.module.sections[(NSUInteger)indexPath.section].items[(NSUInteger)indexPath.row];

    if ([item isKindOfClass:[REAToggle class]]) {
        REAToggle *t = (REAToggle *)item;
        static NSString *cid = @"rea-switch";
        REASwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
        if (!cell) cell = [[REASwitchCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        BOOL on = REAUIFlag(t.key, t.defOn);
        [cell configureTitle:t.title subtitle:t.subtitle icon:t.icon on:on disabled:NO];
        __weak typeof(self) weakSelf = self;
        cell.onToggle = ^(BOOL now) {
            REAUISetFlag(t.key, now);
            REALogBridge(@"[UI] %@ -> %d", t.key, (int)now);
            [weakSelf.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
        };
        return cell;
    }

    static NSString *aid = @"rea-action";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:aid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:aid];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.subtitle;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (@available(iOS 14.0, *)) {
        if (item.icon.length) cell.imageView.image = REASymbol(item.icon, [UIColor systemTealColor]);
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    REAItem *item = self.module.sections[(NSUInteger)indexPath.section].items[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[REAAction class]] && ((REAAction *)item).handler) {
        ((REAAction *)item).handler();
    }
}

@end

#pragma mark - 主面板（对应 HushSettingsPanel：UITableView + 多级模块）

@interface REAPanelController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<REAModule *> *modules;
@end

@implementation REAPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"小蓝助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 60;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self
                                                     action:@selector(close)];
    self.modules = REABuildModules();
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.modules.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"功能分类（与 App 内的开关同名，改完立即生效，无需重启）";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"悬浮球：拖动可移动位置；单击打开此面板；长按弹出快捷菜单。\n所有开关保存在 NSUserDefaults（key 与 Hook 读取的一致）。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"rea-module";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    REAModule *m = self.modules[(NSUInteger)indexPath.row];
    cell.textLabel.text = m.title;
    cell.detailTextLabel.text = m.subtitle;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (@available(iOS 14.0, *)) {
        if (m.icon.length) cell.imageView.image = REASymbol(m.icon, [UIColor systemBlueColor]);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    REAModule *m = self.modules[(NSUInteger)indexPath.row];
    READetailController *vc = [[READetailController alloc] initWithModule:m];
    vc.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 悬浮球（对应 HushFloatBall：UIView + pan/tap 手势 + UIImageView）

@interface REAFloatBallView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@property (nonatomic, assign) CGPoint dragStart;
@end

@implementation REAFloatBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.alpha = 0.92;

        self.iconView = [[UIImageView alloc] initWithFrame:self.bounds];
        self.iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.iconView.contentMode = UIViewContentModeCenter;
        self.iconView.userInteractionEnabled = NO;
        [self addSubview:self.iconView];
        [self refreshIcon];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.55;
        [self addGestureRecognizer:lp];
    }
    return self;
}

// 等价原版 -refreshIcon：优先 SF Symbol，取不到就画一个文字占位，绝不依赖资源包
- (void)refreshIcon {
    UIImage *img = nil;
    @try {
        if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
            img = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
            if (!img) img = [UIImage systemImageNamed:@"gearshape.fill"];
        }
    } @catch (NSException *e) { }
    if (img) {
        self.iconView.image = [img imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        return;
    }
    UILabel *lb = (UILabel *)[self viewWithTag:0x524541];
    if (!lb) {
        lb = [[UILabel alloc] initWithFrame:self.bounds];
        lb.tag = 0x524541;
        lb.text = @"蓝";
        lb.font = [UIFont boldSystemFontOfSize:18];
        lb.textColor = [UIColor whiteColor];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.userInteractionEnabled = NO;
        [self addSubview:lb];
    }
}

- (void)handleTap {
    if (self.onTap) self.onTap();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *sup = self.superview;
    if (!sup) return;
    CGPoint p = [g translationInView:sup];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStart = self.center;
        [UIView animateWithDuration:0.12 animations:^{ self.transform = CGAffineTransformMakeScale(1.08, 1.08); }];
    }
    self.center = CGPointMake(self.dragStart.x + p.x, self.dragStart.y + p.y);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.12 animations:^{ self.transform = CGAffineTransformIdentity; }];
        // 贴边吸附（左右最近边），并把位置持久化
        CGRect b = sup.bounds;
        CGFloat half = self.bounds.size.width / 2;
        CGFloat x = (self.center.x < b.size.width / 2) ? half + 6 : b.size.width - half - 6;
        CGFloat y = MIN(MAX(self.center.y, half + 40), b.size.height - half - 40);
        [UIView animateWithDuration:0.22 animations:^{ self.center = CGPointMake(x, y); } completion:^(BOOL f) {
            [[REAUILoad shared] saveBallCenter:self.center];
        }];
    }
}

@end

#pragma mark - 悬浮球所在窗口（触摸穿透）

@interface REAOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *ball;
@end

@implementation REAOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 球以外的地方一律穿透，保证不影响 App 自身交互
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) {
        if (self.ball && CGRectContainsPoint(self.ball.frame, point)) return self.ball;
        return nil;
    }
    return v;
}

@end

#pragma mark - 单例装配（接口见文件头部前向声明）

@implementation REAUILoad

+ (instancetype)shared {
    static REAUILoad *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[REAUILoad alloc] init]; });
    return s;
}

- (CGPoint)ballCenter {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kREABallCenterKey];
    if ([v isKindOfClass:[NSString class]]) {
        CGPoint p = CGPointFromString((NSString *)v);
        if (p.x > 0 && p.y > 0) return p;
    }
    CGSize s = [UIScreen mainScreen].bounds.size;
    return CGPointMake(s.width - 34, s.height * 0.42);
}

- (void)saveBallCenter:(CGPoint)c {
    @try {
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(c) forKey:kREABallCenterKey];
    } @catch (NSException *e) { }
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.started) return;
        if (!REAUIFlag(kREABallEnabledKey, YES)) return;
        UIWindow *kw = REAKeyWindow();
        if (!kw) { REALogBridge(@"[UI] no key window, retry later"); return; }

        CGRect screen = [UIScreen mainScreen].bounds;
        if (@available(iOS 13.0, *)) {
            self.window = [[REAOverlayWindow alloc] initWithWindowScene:kw.windowScene];
        } else {
            self.window = [[REAOverlayWindow alloc] initWithFrame:screen];
        }
        self.window.frame = screen;
        self.window.windowLevel = UIWindowLevelAlert + 1;
        self.window.backgroundColor = [UIColor clearColor];
        self.window.rootViewController = [[UIViewController alloc] init];
        self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
        self.window.hidden = NO;

        CGFloat d = 52;
        CGPoint c = [self ballCenter];
        self.ball = [[REAFloatBallView alloc] initWithFrame:CGRectMake(c.x - d / 2, c.y - d / 2, d, d)];
        __weak typeof(self) weakSelf = self;
        self.ball.onTap = ^{ [weakSelf openPanel]; };
        self.ball.onLongPress = ^{ [weakSelf showQuickMenu]; };
        [self.window.rootViewController.view addSubview:self.ball];
        ((REAOverlayWindow *)self.window).ball = self.ball;
        self.started = YES;
        REALogBridge(@"[UI] float ball ready at %@", NSStringFromCGPoint(c));
    });
}

- (void)openPanel {
    // 优先用 App 自己的顶层 VC 来 present：在非 keyWindow 上呈现容易触发
    // "whose view is not in the window hierarchy" 的警告，宿主 VC 一定在层级里。
    UIViewController *host = REATopViewController();
    if (!host) host = self.window.rootViewController;
    if (!host) return;
    if (host.presentedViewController) return;
    REAPanelController *panel = [[REAPanelController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:nav animated:YES completion:nil];
    REALogBridge(@"[UI] panel opened");
}

- (void)showQuickMenu {
    UIViewController *top = REATopViewController();
    if (!top) top = self.window.rootViewController;
    if (!top || top.presentedViewController) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"小蓝助手"
                                                              message:@"快捷操作"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"打开设置面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self openPanel];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看 Hook 报告" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        REAShowHookReportBridge();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看触发统计" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        REAShowHitReportBridge();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新安装 Hook" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        REAReinstallHooksBridge();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮球" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        REAUISetFlag(kREABallEnabledKey, NO);
        self.ball.hidden = YES;
        REAToast(@"悬浮球已隐藏，重新启动 App 生效");
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.ball ?: top.view;
    if (self.ball) ac.popoverPresentationController.sourceRect = self.ball.bounds;
    [top presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 菜单模型（对应 HushSettingsPanel -buildModel）

static REAToggle *REAToggleMake(NSString *key, NSString *title, NSString *subtitle, NSString *icon, BOOL def) {
    REAToggle *t = [[REAToggle alloc] init];
    t.key = key;
    t.title = title;
    t.subtitle = subtitle;
    t.icon = icon;
    t.defOn = def;
    return t;
}

static REAAction *REAActionMake(NSString *title, NSString *subtitle, NSString *icon, NSString *label, void (^h)(void)) {
    REAAction *a = [[REAAction alloc] init];
    a.title = title;
    a.subtitle = subtitle;
    a.icon = icon;
    a.handler = h;
    a.actionLabel = label;
    return a;
}

static REASection *REASectionMake(NSString *title, NSString *footer, NSArray<REAItem *> *items) {
    REASection *s = [[REASection alloc] init];
    s.title = title;
    s.footer = footer;
    s.items = items;
    return s;
}

static REAModule *REAModuleMake(NSString *title, NSString *subtitle, NSString *icon, NSArray<REASection *> *sections) {
    REAModule *m = [[REAModule alloc] init];
    m.title = title;
    m.subtitle = subtitle;
    m.icon = icon;
    m.sections = sections;
    return m;
}

static NSArray<REAModule *> *REABuildModules(void) {
    NSMutableArray<REAModule *> *mods = [NSMutableArray array];

    // ① 消息防护
    [mods addObject:REAModuleMake(@"消息防护", @"防撤回 / 阅后即焚 / 闪照", @"shield.lefthalf.filled", @[
        REASectionMake(@"防撤回", @"撤回类型被强制为 0，消息不再消失；副作用是双方都看不到「已撤回」提示。", @[
            REAToggleMake(@"switch_anti_recall", @"防撤回", @"拦截 recallType / isSuperRecallTip", @"arrow.uturn.left.circle", YES),
        ]),
        REASectionMake(@"闪照与阅后即焚", @"只影响本地展示，不改变服务器状态。", @[
            REAToggleMake(@"switch_flash_photo", @"闪照可保存", @"阅后即焚的照片保留在本机", @"photo.fill", YES),
            REAToggleMake(@"switch_flash_text", @"闪字保留", @"text.bubble", @"text.bubble.fill", YES),
        ]),
    ])];

    // ② 隐私
    [mods addObject:REAModuleMake(@"隐私与相册", @"私密相册 / 截图提示 / 水印", @"lock.shield", @[
        REASectionMake(@"相册", @"解锁私密相册入口（服务端校验仍在，仅放行本地 UI）。", @[
            REAToggleMake(@"switch_private_photo", @"私密相册解锁", @"access_private_photos → YES", @"photo.on.rectangle.angled", YES),
        ]),
        REASectionMake(@"截图与水印", @"", @[
            REAToggleMake(@"switch_screenshot", @"截图不提示", @"不向对方发截图提醒", @"camera.viewfinder", YES),
            REAToggleMake(@"switch_watermark", @"去水印", @"隐藏聊天/相册水印", @"drop.triangle", YES),
        ]),
    ])];

    // ③ 会员与界面
    [mods addObject:REAModuleMake(@"会员与界面", @"本地 VIP / 角标 / 键盘", @"crown", @[
        REASectionMake(@"会员", @"仅本地字段伪装，不改变服务器鉴权。", @[
            REAToggleMake(@"switch_local_vip", @"本地 VIP", @"is_vip / vip_status 改写", @"crown.fill", YES),
        ]),
        REASectionMake(@"界面", @"", @[
            REAToggleMake(@"switch_clean_badge", @"角标净化", @"清掉未读角标（tabbar）", @"app.badge", NO),
        ]),
    ])];

    // ④ 定位
    [mods addObject:REAModuleMake(@"定位", @"虚拟定位 / 高度", @"location", @[
        REASectionMake(@"虚拟定位", @"写入 rea_fake_location（lat/lng/alt），CLLocation 层替换坐标。", @[
            REAToggleMake(@"switch_virtual_location", @"启用虚拟定位", @"坐标取「设置坐标」里的值", @"location.fill", YES),
            REAToggleMake(@"switch_altitude", @"模拟海拔", @"", @"mountain.2", YES),
            REAActionMake(@"设置坐标", @"默认 39.9042, 116.4074, 50m", @"mappin.and.ellipse", @"设置", ^{
                REAPromptLocation();
            }),
            REAActionMake(@"清除虚拟定位", @"恢复真实坐标", @"location.slash", @"清除", ^{
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"rea_fake_location"];
                REAToast(@"已清除虚拟定位");
            }),
        ]),
    ])];

    // ⑤ 调试
    [mods addObject:REAModuleMake(@"调试", @"报告 / 日志 / 重装", @"ladybug", @[
        REASectionMake(@"诊断", @"", @[
            REAToggleMake(@"rea_show_report", @"启动后弹报告", @"关闭后不再自动弹窗，可在此页手动查看", @"bell", YES),
            REAActionMake(@"查看 Hook 报告", @"装上多少条 / MISS 明细", @"list.bullet.rectangle", @"查看", ^{
                REAShowHookReportBridge();
            }),
            REAActionMake(@"查看触发统计", @"每个功能域被调用次数", @"chart.bar", @"查看", ^{
                REAShowHitReportBridge();
            }),
            REAActionMake(@"重新安装 Hook", @"类晚注册时手动补装", @"arrow.clockwise", @"执行", ^{
                REAReinstallHooksBridge();
                REAToast(@"已重新安装");
            }),
            REAActionMake(@"重置全部开关", @"所有 switch_* 恢复默认开启", @"trash", @"重置", ^{
                NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
                for (NSString *k in d.allKeys) {
                    if ([k hasPrefix:@"switch_"] || [k hasPrefix:@"rea_"]) {
                        if ([k isEqualToString:kREABallCenterKey] || [k isEqualToString:kREABallEnabledKey]) continue;
                        [[NSUserDefaults standardUserDefaults] removeObjectForKey:k];
                    }
                }
                REAToast(@"已重置，返回上一页刷新");
            }),
        ]),
    ])];

    return mods;
}

// 输入 lat/lng/alt 的 Alert（等价原版自定义定位输入）
void REAPromptLocation(void) {
    UIViewController *top = REATopViewController();
    if (!top) { REAToast(@"当前没有可用界面"); return; }
    if (top.presentedViewController) top = top.presentedViewController;

    NSDictionary *cur = [[NSUserDefaults standardUserDefaults] objectForKey:@"rea_fake_location"];
    NSString *lat = cur[@"lat"] ? [NSString stringWithFormat:@"%@", cur[@"lat"]] : @"39.9042";
    NSString *lng = cur[@"lng"] ? [NSString stringWithFormat:@"%@", cur[@"lng"]] : @"116.4074";
    NSString *alt = cur[@"alt"] ? [NSString stringWithFormat:@"%@", cur[@"alt"]] : @"50";

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设置虚拟坐标"
                                                               message:@"纬度 / 经度 / 海拔（米）"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"纬度 lat"; tf.text = lat; tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"经度 lng"; tf.text = lng; tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"海拔 alt"; tf.text = alt; tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        double la = [ac.textFields[0].text doubleValue];
        double ln = [ac.textFields[1].text doubleValue];
        double al = [ac.textFields[2].text doubleValue];
        [[NSUserDefaults standardUserDefaults] setObject:@{ @"lat": @(la), @"lng": @(ln), @"alt": @(al) }
                                                  forKey:@"rea_fake_location"];
        REAToast([NSString stringWithFormat:@"已保存 %.6f, %.6f, %.1fm", la, ln, al]);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 对外入口

void REAUIStart(void) {
    [[REAUILoad shared] start];
}
