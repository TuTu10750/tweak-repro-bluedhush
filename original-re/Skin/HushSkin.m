//
//  HushSkin.m — 原版 BluedHush 的「皮肤层」
//
//  设计红线（务必遵守）：
//   1. 不定义任何与宿主/原版同名的类，不 hook 任何逻辑方法
//      —— 只碰显示层：UILabel -setText:、以及玻璃控件的 layoutSubviews。
//   2. 原版 dylib 的字节一个都不改：本 dylib 在 ctor 里 dlopen 原版，
//      让它的类先注册，再装皮肤 hook。
//   3. 任何异常一律吞掉并回落到原实现，绝不让皮肤把宿主带崩。
//   4. 文案映射走外部 JSON（Documents/bluedbackups/skin_texts.json），
//      改文案不用重新出包；文件不在就用内置默认值并写一份出来。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

// ---------------------------------------------------------------------------
// 日志：极简。stderr 给 Xcode/syslog，文件给用户导出。
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
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SkinLogPath()];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:SkinLogPath() contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:SkinLogPath()];
    }
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

static NSDictionary *gSkinCfg;          // 当前生效配置
static NSArray<NSDictionary *> *gRules; // 文案规则
static UIColor *gColA, *gColB, *gColC;  // 青 / 蓝 / 紫
static CGFloat gAlpha = 0.26;

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
        @"palette": @{ @"a": @"#00E5FF", @"b": @"#2F6BFF", @"c": @"#8A2BE2", @"alpha": @0.26 },
        // 只按「出现即隐藏」的保守规则处理页脚三行；其余文案等你逐条给。
        @"rules": @[
            @{ @"match": @"contains", @"text": @"开关改动即时写入", @"replace": @"", @"hide": @YES },
            @{ @"match": @"contains", @"text": @"· 版本 ",          @"replace": @"", @"hide": @YES },
            @{ @"match": @"contains", @"text": @"项（开关",         @"replace": @"", @"hide": @YES },
        ],
    };
}

static void SkinLoadConfig(void) {
    NSDictionary *cfg = nil;
    NSString *path = SkinJSONPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        cfg = SkinDefaultConfig();
        @try {
            NSData *d = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:NULL];
            [d writeToFile:path atomically:YES];
            SkinLog(@"已生成默认配置 %@", path);
        } @catch (__unused NSException *e) {}
    } else {
        @try {
            NSData *d = [NSData dataWithContentsOfFile:path];
            id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) cfg = obj;
        } @catch (__unused NSException *e) { cfg = nil; }
    }
    if (!cfg) cfg = SkinDefaultConfig();

    gSkinCfg = cfg;
    NSDictionary *p = [cfg[@"palette"] isKindOfClass:[NSDictionary class]] ? cfg[@"palette"] : @{};
    gColA = SkinHex(p[@"a"], [UIColor colorWithRed:0.00 green:0.90 blue:1.00 alpha:1]);
    gColB = SkinHex(p[@"b"], [UIColor colorWithRed:0.18 green:0.42 blue:1.00 alpha:1]);
    gColC = SkinHex(p[@"c"], [UIColor colorWithRed:0.54 green:0.17 blue:0.89 alpha:1]);
    if ([p[@"alpha"] isKindOfClass:[NSNumber class]]) {
        CGFloat a = [p[@"alpha"] doubleValue];
        gAlpha = (a > 0.05 && a < 1.0) ? a : 0.26;
    }
    NSArray *rs = [cfg[@"rules"] isKindOfClass:[NSArray class]] ? cfg[@"rules"] : @[];
    NSMutableArray *ok = [NSMutableArray array];
    for (id r in rs) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        if (![r[@"text"] isKindOfClass:[NSString class]] || [r[@"text"] length] == 0) continue;
        [ok addObject:r];
    }
    gRules = ok;
    SkinLog(@"配置生效：规则 %lu 条，配色 %@ / %@ / %@ alpha=%.2f",
            (unsigned long)gRules.count, p[@"a"] ?: @"默认", p[@"b"] ?: @"默认", p[@"c"] ?: @"默认", gAlpha);
}

// 返回替换后的文本；*hide 表示这一行要整条藏掉。
static NSString *SkinMapText(NSString *text, BOOL *hide) {
    if (hide) *hide = NO;
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || gRules.count == 0) return text;
    for (NSDictionary *r in gRules) {
        NSString *needle = r[@"text"];
        NSString *mode = r[@"match"] ?: @"contains";
        BOOL hit = NO;
        @try {
            if ([mode isEqualToString:@"exact"]) {
                hit = [text isEqualToString:needle];
            } else if ([mode isEqualToString:@"prefix"]) {
                hit = [text hasPrefix:needle];
            } else if ([mode isEqualToString:@"suffix"]) {
                hit = [text hasSuffix:needle];
            } else {
                hit = [text rangeOfString:needle].location != NSNotFound;
            }
        } @catch (__unused NSException *e) { hit = NO; }
        if (!hit) continue;
        if ([r[@"hide"] boolValue]) { if (hide) *hide = YES; return @""; }
        id rep = r[@"replace"];
        return [rep isKindOfClass:[NSString class]] ? rep : @"";
    }
    return text;
}

// ---------------------------------------------------------------------------
// swizzle：只换显示方法，且都能回落到原 IMP
// ---------------------------------------------------------------------------
static IMP SkinOwnImp(Class c, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    IMP found = NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = method_getImplementation(list[i]); break; }
    }
    if (list) free(list);
    return found;
}

static IMP SkinReplace(Class c, SEL sel, IMP repl) {
    if (!c) return NULL;
    Method own = NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) if (method_getName(list[i]) == sel) { own = list[i]; break; }
    if (list) free(list);
    if (own) return method_setImplementation(own, repl);
    // 只在「本类没有、父类有」时补；不加凭空方法，避免脏 method list
    Method inh = class_getInstanceMethod(c, sel);
    if (inh) {
        IMP old = method_getImplementation(inh);
        class_addMethod(c, sel, repl, method_getTypeEncoding(inh));
        return old;
    }
    return NULL;
}

// ---- UILabel -setText: ----
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

// ---- 玻璃控件外观 ----
static const NSInteger kSkinGradientTag = 0x534B31; // 'SK1'

static void SkinStyleGlass(UIView *v) {
    if (!v || v.tag == kSkinGradientTag) return;
    Class cls = [v class];
    NSString *cn = NSStringFromClass(cls) ?: @"";
    BOOL isGlass = [cn rangeOfString:@"Glass"].location != NSNotFound
                || [cn rangeOfString:@"Capsule"].location != NSNotFound
                || [cn rangeOfString:@"PillButton"].location != NSNotFound;
    if (!isGlass) return;

    v.layer.cornerRadius = (cn.length && [cn rangeOfString:@"Pill"].location != NSNotFound) ? v.bounds.size.height / 2.0 : 18.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.6;
    v.layer.borderColor = [gColA colorWithAlphaComponent:0.55].CGColor;
    v.layer.masksToBounds = NO;

    if (![v viewWithTag:kSkinGradientTag]) {
        CAGradientLayer *g = [CAGradientLayer layer];
        g.name = @"hushSkinGradient";
        g.colors = @[ (__bridge id)[gColA colorWithAlphaComponent:gAlpha].CGColor,
                      (__bridge id)[gColB colorWithAlphaComponent:gAlpha].CGColor,
                      (__bridge id)[gColC colorWithAlphaComponent:gAlpha].CGColor ];
        g.startPoint = CGPointMake(0.0, 0.0);
        g.endPoint = CGPointMake(1.0, 1.0);
        g.cornerRadius = v.layer.cornerRadius;
        g.cornerCurve = kCACornerCurveContinuous;
        g.frame = v.bounds;
        // 用一个不可交互的宿主视图承载渐变，tag 用来避免重复叠加
        UIView *host = [[UIView alloc] initWithFrame:v.bounds];
        host.tag = kSkinGradientTag;
        host.userInteractionEnabled = NO;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        host.layer.cornerRadius = v.layer.cornerRadius;
        host.layer.cornerCurve = kCACornerCurveContinuous;
        host.layer.masksToBounds = YES;
        [host.layer addSublayer:g];
        [v insertSubview:host atIndex:0];
    } else {
        UIView *host = [v viewWithTag:kSkinGradientTag];
        host.frame = v.bounds;
        for (CALayer *l in host.layer.sublayers) {
            if ([l isKindOfClass:[CAGradientLayer class]]) {
                l.frame = host.bounds;
                ((CAGradientLayer *)l).cornerRadius = v.layer.cornerRadius;
            }
        }
    }
}

static void SkinWalk(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return;
    @try {
        SkinStyleGlass(root);
        if ([root isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)root;
            if (!lb.hidden) lb.textColor = [UIColor colorWithWhite:0.97 alpha:1.0];
        }
        for (UIView *sub in root.subviews) SkinWalk(sub, depth + 1);
    } @catch (__unused NSException *e) {}
}

// ---- HushSettingsPanel ----
static void (*o_panelDidLoad)(id, SEL);
static void r_panelDidLoad(id self, SEL _cmd) {
    if (o_panelDidLoad) o_panelDidLoad(self, _cmd);
    @try {
        SkinLoadConfig();
        UIView *v = [self valueForKey:@"view"];
        if (!v) return;
        // 面板底色：三层渐变压在最底
        if (![v viewWithTag:kSkinGradientTag + 1]) {
            CAGradientLayer *bg = [CAGradientLayer layer];
            bg.colors = @[ (__bridge id)[gColC colorWithAlphaComponent:gAlpha * 0.85].CGColor,
                           (__bridge id)[gColB colorWithAlphaComponent:gAlpha * 0.7].CGColor,
                           (__bridge id)[gColA colorWithAlphaComponent:gAlpha * 0.8].CGColor ];
            bg.startPoint = CGPointMake(0.1, 0.0);
            bg.endPoint = CGPointMake(0.9, 1.0);
            bg.frame = v.bounds;
            UIView *host = [[UIView alloc] initWithFrame:v.bounds];
            host.tag = kSkinGradientTag + 1;
            host.userInteractionEnabled = NO;
            host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [host.layer addSublayer:bg];
            [v insertSubview:host atIndex:0];
            SkinLog(@"面板底色已应用（青蓝紫）");
        }
        SkinWalk(v, 0);
    } @catch (__unused NSException *e) { SkinLog(@"面板皮肤异常，已忽略"); }
}

static void (*o_panelWillAppear)(id, SEL, BOOL);
static void r_panelWillAppear(id self, SEL _cmd, BOOL animated) {
    if (o_panelWillAppear) o_panelWillAppear(self, _cmd, animated);
    @try { SkinLoadConfig(); UIView *v = [self valueForKey:@"view"]; if (v) SkinWalk(v, 0); } @catch (__unused NSException *e) {}
}

// ---- 玻璃/开关 cell 重绘时补一次外观 ----
static void (*o_glassLayout)(id, SEL);
static void r_glassLayout(id self, SEL _cmd) {
    if (o_glassLayout) o_glassLayout(self, _cmd);
    @try { SkinWalk((UIView *)self, 0); } @catch (__unused NSException *e) {}
}

// ---- 页脚：把空出来的那几行高度让回去 ----
static void (*o_footerLayout)(id, SEL);
static void r_footerLayout(id self, SEL _cmd) {
    if (o_footerLayout) o_footerLayout(self, _cmd);
    @try {
        UIView *v = (UIView *)self;
        BOOL anyVisible = NO;
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UILabel class]] && !s.hidden && ((UILabel *)s).text.length > 0) { anyVisible = YES; break; }
        }
        // 只在「确实已经全空」时压高度，且高度已是 0 就不再动，
        // 否则每次 layoutSubviews 都改 frame 会反过来触发重排。
        if (!anyVisible && v.superview && v.frame.size.height > 0.5) {
            CGRect f = v.frame; f.size.height = 0.0; v.frame = f;
        }
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
    Class panel = NSClassFromString(@"HushSettingsPanel");
    Class glass = NSClassFromString(@"HushGlassView");
    Class cell  = NSClassFromString(@"HushSwitchCell");
    Class foot  = NSClassFromString(@"HushAuthorFooterView");

    if (panel) {
        o_panelDidLoad = (void (*)(id, SEL))SkinReplace(panel, @selector(viewDidLoad), (IMP)&r_panelDidLoad);
        o_panelWillAppear = (void (*)(id, SEL, BOOL))SkinReplace(panel, @selector(viewWillAppear:), (IMP)&r_panelWillAppear);
    }
    if (glass) o_glassLayout = (void (*)(id, SEL))SkinReplace(glass, @selector(layoutSubviews), (IMP)&r_glassLayout);
    if (cell)  SkinReplace(cell, @selector(layoutSubviews), (IMP)&r_glassLayout);
    if (foot)  o_footerLayout = (void (*)(id, SEL))SkinReplace(foot, @selector(layoutSubviews), (IMP)&r_footerLayout);

    o_setText = (void (*)(id, SEL, NSString *))SkinReplace([UILabel class], @selector(setText:), (IMP)&r_setText);

    SkinLog(@"hook 结果：panel=%d glass=%d cell=%d footer=%d label=%d",
            panel != nil, glass != nil, cell != nil, foot != nil, o_setText != nil);
}

// 原版 dylib 由我们随包携带（改名 OriginalHush.dylib），在 ctor 里先 dlopen，
// 让它的类注册完，再挂皮肤 hook。
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

        // 类注册可能稍晚（原版在它自己的 ctor 里做），重试最多 40 次 × 0.25s
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
                    SkinLoadConfig();   // 回前台热加载：改完 JSON 切回来就生效
                }];
            });
        });
    }
}
