//
//  HushSkin.m — 原版 BluedHush 5.19 的「皮肤层」
//
//  红线：
//   1. 零类定义，只 hook 显示方法；不碰原版/宿主的任何逻辑方法。
//   2. 原版 dylib 字节零改动：ctor 里 dlopen OriginalHush.dylib，让它先注册类。
//   3. 每个 hook 都必须拿到「它自己那个类」的旧 IMP —— 两个类共用一个 IMP 变量
//      会让 A 类的方法体跑在 B 类实例上，v15E 就是这么崩的
//      （-[UITableViewCellLayoutManager views]: unrecognized selector）。
//   4. 任何异常吞掉并回落，皮肤不许把宿主带崩。
//   5. 文案与配色走 Documents/bluedbackups/skin_texts.json，热加载。
//
//  关于页脚：原版是自绘（日志里写着「清掉系统自带 textLabel（防与自绘文字重叠）」），
//  所以改 UILabel 抓不到它 —— 直接 hook HushAuthorFooterView 的 drawRect: 画空，
//  并把高度压 0。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
static NSString *SkinLogPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"bluedbackups/logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"skin.log"];
}

static void SkinLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[Skin] %@\n", body];
    fprintf(stderr, "%s", line.UTF8String);
    static NSLock *lk; static dispatch_once_t o;
    dispatch_once(&o, ^{ lk = [NSLock new]; });
    [lk lock];
    if (![[NSFileManager defaultManager] fileExistsAtPath:SkinLogPath()])
        [[NSFileManager defaultManager] createFileAtPath:SkinLogPath() contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SkinLogPath()];
    if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; } @catch (__unused NSException *e) {} }
    [lk unlock];
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------
static NSString *const kSkinJSONName = @"skin_texts.json";

static NSString *SkinJSONPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"bluedbackups"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:kSkinJSONName];
}

static NSArray<NSDictionary *> *gRules;
static UIColor *gColA, *gColB, *gColC;      // 青 / 蓝 / 紫
static CGFloat gAlpha = 0.55;               // 面板渐变透明度
static UIColor *gBase;                      // 面板底色（深，衬得出青蓝紫）
static BOOL gHideFooter = YES;

static UIColor *SkinHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 7) return fallback;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&v]) return fallback;
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

static NSDictionary *SkinDefaultConfig(void) {
    return @{
        @"palette": @{ @"a": @"#00E5FF", @"b": @"#2F6BFF", @"c": @"#8A2BE2",
                       @"alpha": @0.55, @"base": @"#0B1020" },
        @"hide_footer": @YES,
        // 页脚是自绘的，下面这些规则是给「如果哪天改成 UILabel」留的保险。
        @"rules": @[
            @{ @"match": @"contains", @"text": @"@Tinycca",         @"replace": @"", @"hide": @YES },
            @{ @"match": @"prefix",   @"text": @"作者 ",            @"replace": @"", @"hide": @YES },
            @{ @"match": @"prefix",   @"text": @"版本 ",            @"replace": @"", @"hide": @YES },
            @{ @"match": @"contains", @"text": @"项（开关",          @"replace": @"", @"hide": @YES },
            @{ @"match": @"contains", @"text": @"开关改动即时写入",  @"replace": @"", @"hide": @YES },
        ],
    };
}

static void SkinLoadConfig(void) {
    NSMutableDictionary *cfg = nil;
    NSString *path = SkinJSONPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        cfg = [SkinDefaultConfig() mutableCopy];
        @try {
            NSData *d = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:NULL];
            [d writeToFile:path atomically:YES];
            SkinLog(@"已生成默认配置 %@", path);
        } @catch (__unused NSException *e) {}
    } else {
        @try {
            NSData *d = [NSData dataWithContentsOfFile:path];
            id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) cfg = [obj mutableCopy];
        } @catch (__unused NSException *e) { cfg = nil; }
    }
    if (!cfg) cfg = [SkinDefaultConfig() mutableCopy];

    NSDictionary *p = [cfg[@"palette"] isKindOfClass:[NSDictionary class]] ? cfg[@"palette"] : @{};
    gColA = SkinHex(p[@"a"], [UIColor colorWithRed:0.00 green:0.90 blue:1.00 alpha:1]);
    gColB = SkinHex(p[@"b"], [UIColor colorWithRed:0.18 green:0.42 blue:1.00 alpha:1]);
    gColC = SkinHex(p[@"c"], [UIColor colorWithRed:0.54 green:0.17 blue:0.89 alpha:1]);
    gBase = SkinHex(p[@"base"], [UIColor colorWithRed:0.043 green:0.063 blue:0.125 alpha:1]);
    if ([p[@"alpha"] isKindOfClass:[NSNumber class]]) {
        CGFloat a = [p[@"alpha"] doubleValue];
        if (a > 0.05 && a <= 1.0) gAlpha = a;
    }
    if ([cfg[@"hide_footer"] isKindOfClass:[NSNumber class]]) gHideFooter = [cfg[@"hide_footer"] boolValue];

    NSArray *rs = [cfg[@"rules"] isKindOfClass:[NSArray class]] ? cfg[@"rules"] : @[];
    NSMutableArray *ok = [NSMutableArray array];
    for (id r in rs) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        if (![r[@"text"] isKindOfClass:[NSString class]] || [r[@"text"] length] == 0) continue;
        [ok addObject:r];
    }
    gRules = ok;
    SkinLog(@"配置生效：规则 %lu 条，配色 %@ / %@ / %@ alpha=%.2f 底 %@ 页脚%@",
            (unsigned long)gRules.count, p[@"a"] ?: @"默认", p[@"b"] ?: @"默认", p[@"c"] ?: @"默认",
            gAlpha, p[@"base"] ?: @"默认", gHideFooter ? @"隐藏" : @"保留");
}

static NSString *SkinMapText(NSString *text, BOOL *hide) {
    if (hide) *hide = NO;
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || gRules.count == 0) return text;
    for (NSDictionary *r in gRules) {
        NSString *needle = r[@"text"];
        NSString *mode = r[@"match"] ?: @"contains";
        BOOL hit = NO;
        @try {
            if ([mode isEqualToString:@"exact"])       hit = [text isEqualToString:needle];
            else if ([mode isEqualToString:@"prefix"]) hit = [text hasPrefix:needle];
            else if ([mode isEqualToString:@"suffix"]) hit = [text hasSuffix:needle];
            else                                      hit = [text rangeOfString:needle].location != NSNotFound;
        } @catch (__unused NSException *e) { hit = NO; }
        if (!hit) continue;
        if ([r[@"hide"] boolValue]) { if (hide) *hide = YES; return @""; }
        id rep = r[@"replace"];
        return [rep isKindOfClass:[NSString class]] ? rep : @"";
    }
    return text;
}

// ---------------------------------------------------------------------------
// swizzle
// ---------------------------------------------------------------------------
static IMP SkinReplace(Class c, SEL sel, IMP repl) {
    if (!c) return NULL;
    Method own = NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) if (method_getName(list[i]) == sel) { own = list[i]; break; }
    if (list) free(list);
    if (own) return method_setImplementation(own, repl);
    Method inh = class_getInstanceMethod(c, sel);
    if (inh) {
        IMP old = method_getImplementation(inh);
        class_addMethod(c, sel, repl, method_getTypeEncoding(inh));
        return old;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// UILabel -setText:
// ---------------------------------------------------------------------------
static void (*o_setText)(id, SEL, NSString *);
static void r_setText(id self, SEL _cmd, NSString *text) {
    @try {
        BOOL hide = NO;
        NSString *mapped = SkinMapText(text, &hide);
        if (hide) {
            if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).hidden = YES;
            if (o_setText) o_setText(self, _cmd, @"");
            return;
        }
        if (o_setText) o_setText(self, _cmd, mapped);
    } @catch (__unused NSException *e) {
        if (o_setText) o_setText(self, _cmd, text);
    }
}

// ---------------------------------------------------------------------------
// 玻璃 / cell 外观
// ---------------------------------------------------------------------------
static const NSInteger kSkinGradientTag = 0x534B31; // 'SK1'
static const NSInteger kSkinPanelTag = 0x534B32;

static void SkinStyleGlass(UIView *v) {
    if (!v || v.tag == kSkinGradientTag) return;
    NSString *cn = NSStringFromClass([v class]) ?: @"";
    BOOL isGlass = [cn rangeOfString:@"Glass"].location != NSNotFound
                || [cn rangeOfString:@"Capsule"].location != NSNotFound
                || [cn rangeOfString:@"PillButton"].location != NSNotFound;
    if (!isGlass) return;

    v.layer.cornerRadius = ([cn rangeOfString:@"Pill"].location != NSNotFound) ? v.bounds.size.height / 2.0 : 16.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.8;
    v.layer.borderColor = [gColA colorWithAlphaComponent:0.65].CGColor;

    UIView *host = [v viewWithTag:kSkinGradientTag];
    if (!host) {
        host = [[UIView alloc] initWithFrame:v.bounds];
        host.tag = kSkinGradientTag;
        host.userInteractionEnabled = NO;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        host.layer.cornerRadius = v.layer.cornerRadius;
        host.layer.cornerCurve = kCACornerCurveContinuous;
        host.layer.masksToBounds = YES;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.name = @"hushSkinGradient";
        g.colors = @[ (__bridge id)[gColA colorWithAlphaComponent:gAlpha].CGColor,
                      (__bridge id)[gColB colorWithAlphaComponent:gAlpha].CGColor,
                      (__bridge id)[gColC colorWithAlphaComponent:gAlpha].CGColor ];
        g.startPoint = CGPointMake(0.0, 0.0);
        g.endPoint = CGPointMake(1.0, 1.0);
        [host.layer addSublayer:g];
        [v insertSubview:host atIndex:0];
    }
    host.frame = v.bounds;
    host.layer.cornerRadius = v.layer.cornerRadius;
    for (CALayer *l in host.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) {
            l.frame = host.bounds;
            ((CAGradientLayer *)l).cornerRadius = v.layer.cornerRadius;
        }
    }
}

static void SkinStyleCell(UITableViewCell *cell) {
    if (!cell) return;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    if (cell.backgroundView) cell.backgroundView.backgroundColor = [UIColor clearColor];
    UIView *sel = cell.selectedBackgroundView;
    if (sel && !sel.backgroundColor) sel.backgroundColor = [gColB colorWithAlphaComponent:0.18];
    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)sub;
            if (!lb.hidden) lb.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        }
    }
}

static void SkinWalk(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return;
    @try {
        SkinStyleGlass(root);
        if ([root isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)root;
            if (!lb.hidden) lb.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        }
        if ([root isKindOfClass:[UITableView class]]) {
            ((UITableView *)root).backgroundColor = [UIColor clearColor];
        }
        for (UIView *sub in root.subviews) SkinWalk(sub, depth + 1);
    } @catch (__unused NSException *e) {}
}

// ---------------------------------------------------------------------------
// 每个类各自持有旧 IMP —— 绝不共用
// ---------------------------------------------------------------------------
static void (*o_glassLayout)(id, SEL);
static void r_glassLayout(id self, SEL _cmd) {
    if (o_glassLayout) o_glassLayout(self, _cmd);
    @try { SkinWalk((UIView *)self, 0); } @catch (__unused NSException *e) {}
}

static void (*o_switchCellLayout)(id, SEL);
static void r_switchCellLayout(id self, SEL _cmd) {
    if (o_switchCellLayout) o_switchCellLayout(self, _cmd);
    @try {
        if ([self isKindOfClass:[UITableViewCell class]]) SkinStyleCell((UITableViewCell *)self);
        SkinWalk((UIView *)self, 0);
    } @catch (__unused NSException *e) {}
}

static void (*o_detailCellLayout)(id, SEL);
static void r_detailCellLayout(id self, SEL _cmd) {
    if (o_detailCellLayout) o_detailCellLayout(self, _cmd);
    @try {
        if ([self isKindOfClass:[UITableViewCell class]]) SkinStyleCell((UITableViewCell *)self);
    } @catch (__unused NSException *e) {}
}

// 页脚：自绘 → 直接画空
static void (*o_footerDraw)(id, SEL, CGRect);
static void r_footerDraw(id self, SEL _cmd, CGRect rect) {
    if (!gHideFooter) { if (o_footerDraw) o_footerDraw(self, _cmd, rect); return; }
    // 什么都不画
}

static void (*o_footerLayout)(id, SEL);
static void r_footerLayout(id self, SEL _cmd) {
    if (o_footerLayout) o_footerLayout(self, _cmd);
    @try {
        UIView *v = (UIView *)self;
        if (gHideFooter) {
            v.hidden = YES;
            if (v.superview && v.frame.size.height > 0.5) {
                CGRect f = v.frame; f.size.height = 0.0; v.frame = f;
            }
        }
    } @catch (__unused NSException *e) {}
}

// ---------------------------------------------------------------------------
// 面板 / 详情页
// ---------------------------------------------------------------------------
static void SkinApplyPanelBackground(UIView *v) {
    if (!v || [v viewWithTag:kSkinPanelTag]) return;
    v.backgroundColor = gBase;
    UIView *host = [[UIView alloc] initWithFrame:v.bounds];
    host.tag = kSkinPanelTag;
    host.userInteractionEnabled = NO;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[ (__bridge id)[gColC colorWithAlphaComponent:gAlpha].CGColor,
                   (__bridge id)[gColB colorWithAlphaComponent:gAlpha].CGColor,
                   (__bridge id)[gColA colorWithAlphaComponent:gAlpha].CGColor ];
    bg.startPoint = CGPointMake(0.05, 0.0);
    bg.endPoint = CGPointMake(0.95, 1.0);
    bg.frame = v.bounds;
    [host.layer addSublayer:bg];
    [v insertSubview:host atIndex:0];
    SkinLog(@"面板底色已应用（青蓝紫）");
}

static void (*o_panelDidLoad)(id, SEL);
static void r_panelDidLoad(id self, SEL _cmd) {
    if (o_panelDidLoad) o_panelDidLoad(self, _cmd);
    @try {
        SkinLoadConfig();
        UIView *v = [self valueForKey:@"view"];
        if (!v) return;
        SkinApplyPanelBackground(v);
        SkinWalk(v, 0);
    } @catch (__unused NSException *e) { SkinLog(@"面板皮肤异常，已忽略"); }
}

static void (*o_panelWillAppear)(id, SEL, BOOL);
static void r_panelWillAppear(id self, SEL _cmd, BOOL animated) {
    if (o_panelWillAppear) o_panelWillAppear(self, _cmd, animated);
    @try {
        SkinLoadConfig();
        UIView *v = [self valueForKey:@"view"];
        if (v) { SkinApplyPanelBackground(v); SkinWalk(v, 0); }
    } @catch (__unused NSException *e) {}
}

static void (*o_detailDidLoad)(id, SEL);
static void r_detailDidLoad(id self, SEL _cmd) {
    if (o_detailDidLoad) o_detailDidLoad(self, _cmd);
    @try {
        UIView *v = [self valueForKey:@"view"];
        if (!v) return;
        SkinApplyPanelBackground(v);
        SkinWalk(v, 0);
    } @catch (__unused NSException *e) {}
}

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------
static BOOL SkinEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"hush_skin_enabled"];
    return v ? [v boolValue] : YES;
}

static void SkinInstallHooks(void) {
    Class panel  = NSClassFromString(@"HushSettingsPanel");
    Class detail = NSClassFromString(@"HushModuleDetailController");
    Class glass  = NSClassFromString(@"HushGlassView");
    Class cell   = NSClassFromString(@"HushSwitchCell");
    Class dcell  = NSClassFromString(@"HushModuleEntry");
    Class foot   = NSClassFromString(@"HushAuthorFooterView");

    if (panel) {
        o_panelDidLoad    = (void (*)(id, SEL))SkinReplace(panel, @selector(viewDidLoad), (IMP)&r_panelDidLoad);
        o_panelWillAppear = (void (*)(id, SEL, BOOL))SkinReplace(panel, @selector(viewWillAppear:), (IMP)&r_panelWillAppear);
    }
    if (detail) o_detailDidLoad = (void (*)(id, SEL))SkinReplace(detail, @selector(viewDidLoad), (IMP)&r_detailDidLoad);
    if (glass)  o_glassLayout = (void (*)(id, SEL))SkinReplace(glass, @selector(layoutSubviews), (IMP)&r_glassLayout);
    if (cell)   o_switchCellLayout = (void (*)(id, SEL))SkinReplace(cell, @selector(layoutSubviews), (IMP)&r_switchCellLayout);
    if (dcell)  o_detailCellLayout = (void (*)(id, SEL))SkinReplace(dcell, @selector(layoutSubviews), (IMP)&r_detailCellLayout);
    if (foot) {
        o_footerDraw   = (void (*)(id, SEL, CGRect))SkinReplace(foot, @selector(drawRect:), (IMP)&r_footerDraw);
        o_footerLayout = (void (*)(id, SEL))SkinReplace(foot, @selector(layoutSubviews), (IMP)&r_footerLayout);
    }
    o_setText = (void (*)(id, SEL, NSString *))SkinReplace([UILabel class], @selector(setText:), (IMP)&r_setText);

    SkinLog(@"hook 结果：panel=%d detail=%d glass=%d cell=%d entry=%d footer(draw=%d,layout=%d) label=%d",
            panel != nil, detail != nil, glass != nil, cell != nil, dcell != nil,
            o_footerDraw != nil, o_footerLayout != nil, o_setText != nil);
}

static void SkinLoadOriginal(void) {
    const char *cands[] = {
        "@executable_path/Frameworks/OriginalHush.dylib",
        "@loader_path/OriginalHush.dylib",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        if (NSClassFromString(@"HushSettingsPanel")) return;
        void *h = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) SkinLog(@"已加载原版 dylib：%s", cands[i]);
        else    SkinLog(@"加载原版失败 %s：%s", cands[i], dlerror());
    }
}

__attribute__((constructor))
static void HushSkinInit(void) {
    @autoreleasepool {
        if (!SkinEnabled()) { SkinLog(@"hush_skin_enabled=0，皮肤不启用"); return; }
        SkinLoadConfig();
        SkinLoadOriginal();

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            for (int i = 0; i < 40; i++) {
                if (NSClassFromString(@"HushSettingsPanel")) break;
                [NSThread sleepForTimeInterval:0.25];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                SkinInstallHooks();
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                  object:nil queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(__unused NSNotification *n) {
                    SkinLoadConfig();   // 回前台热加载
                }];
            });
        });
    }
}
