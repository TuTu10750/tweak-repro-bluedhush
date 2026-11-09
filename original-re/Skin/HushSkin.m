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
static NSArray<NSDictionary *> *gColorRules;   // 只上色、不改字的规则（霓虹紫那三条）
static UIColor *gColA, *gColB, *gColC;      // 青 / 蓝 / 紫
static CGFloat gAlpha = 0.30;               // 面板渐变透明度（浅色主题下只当一层薄纱）
static UIColor *gBase;                      // 面板底色
static UIColor *gText;                      // 浅色主题的正文色
static CGFloat gCardAlpha = 0.82;
static CGFloat gCardRadius = 20.0;
static BOOL gLight = YES;                   // 浅色主题（默认）：行是半透明白，正文走深色
static BOOL gHideFooter = YES;
static BOOL gDimBlur = YES;
static BOOL gChatStyle = YES;
static UIColor *gChatBase;
static UIColor *gChatSurface;
static UIColor *gChatAccent;
static CGFloat gChatSurfaceAlpha = 0.80;
static CGFloat gChatRadius = 22.0;

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
        @"style_version": @2,
        // 视频参考是系统原生 Liquid Glass：近白背景、白色半透明表面、
        // 细灰边框、黑色正文，只用系统蓝做强调色。
        @"palette": @{ @"a": @"#0A84FF", @"b": @"#F2F2F7", @"c": @"#FFFFFF",
                       @"alpha": @0.16, @"base": @"#F7F7F5", @"text": @"#111111",
                       @"card_alpha": @0.82, @"card_radius": @20 },
        @"theme": @"light",
        // 聊天页保持宿主原有文字和气泡配色，不再套霓虹紫。
        @"colors": @[],
        @"chat": @{ @"enabled": @YES,
                    @"background": @"#F7F7F5",
                    @"surface": @"#FFFFFF",
                    @"surface_alpha": @0.80,
                    @"accent": @"#0A84FF",
                    @"corner_radius": @22 },
        @"hide_footer": @YES,
        // 保留系统磨砂，不再把 UIVisualEffectView 整层摘掉。
        @"dim_blur": @NO,
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
    // 旧版本写下的 JSON 没有 colors / theme 这些新键 —— 逐个补默认值，
    // 而不是整份丢掉重写，用户改过的颜色不会因为升级而消失。
    NSDictionary *defaults = SkinDefaultConfig();
    NSInteger loadedVersion = [cfg[@"style_version"] isKindOfClass:[NSNumber class]]
                            ? [cfg[@"style_version"] integerValue] : 0;
    NSMutableDictionary *merged = [defaults mutableCopy];
    if (cfg) [merged addEntriesFromDictionary:cfg];
    BOOL migrated = (loadedVersion < [defaults[@"style_version"] integerValue]);
    if (migrated) {
        // 旧版本曾把面板固定成青蓝紫霓虹色。视频参考使用系统原生浅色玻璃，
        // 因此仅迁移视觉配置，不触碰 rules 中的文案和其它功能选项。
        merged[@"style_version"] = defaults[@"style_version"];
        merged[@"palette"] = defaults[@"palette"];
        merged[@"theme"] = defaults[@"theme"];
        merged[@"colors"] = defaults[@"colors"];
        merged[@"chat"] = defaults[@"chat"];
        merged[@"dim_blur"] = defaults[@"dim_blur"];
    }
    cfg = merged;

    NSDictionary *p = [cfg[@"palette"] isKindOfClass:[NSDictionary class]] ? cfg[@"palette"] : @{};
    gColA = SkinHex(p[@"a"], [UIColor colorWithRed:0.00 green:0.90 blue:1.00 alpha:1]);
    gColB = SkinHex(p[@"b"], [UIColor colorWithRed:0.18 green:0.42 blue:1.00 alpha:1]);
    gColC = SkinHex(p[@"c"], [UIColor colorWithRed:0.54 green:0.17 blue:0.89 alpha:1]);
    gBase = SkinHex(p[@"base"], [UIColor colorWithRed:0.957 green:0.969 blue:0.992 alpha:1]);
    gText = SkinHex(p[@"text"], [UIColor colorWithRed:0.106 green:0.122 blue:0.165 alpha:1]);
    if ([p[@"card_alpha"] isKindOfClass:[NSNumber class]]) {
        CGFloat a = [p[@"card_alpha"] doubleValue];
        if (a > 0.05 && a <= 1.0) gCardAlpha = a;
    }
    if ([p[@"card_radius"] isKindOfClass:[NSNumber class]]) {
        CGFloat r = [p[@"card_radius"] doubleValue];
        if (r >= 8.0 && r <= 40.0) gCardRadius = r;
    }
    NSDictionary *chat = [cfg[@"chat"] isKindOfClass:[NSDictionary class]] ? cfg[@"chat"] : @{};
    if ([chat[@"enabled"] isKindOfClass:[NSNumber class]]) gChatStyle = [chat[@"enabled"] boolValue];
    gChatBase = SkinHex(chat[@"background"], gBase);
    gChatSurface = SkinHex(chat[@"surface"], [UIColor whiteColor]);
    gChatAccent = SkinHex(chat[@"accent"], gColA);
    if ([chat[@"surface_alpha"] isKindOfClass:[NSNumber class]]) {
        CGFloat a = [chat[@"surface_alpha"] doubleValue];
        if (a > 0.05 && a <= 1.0) gChatSurfaceAlpha = a;
    }
    if ([chat[@"corner_radius"] isKindOfClass:[NSNumber class]]) {
        CGFloat r = [chat[@"corner_radius"] doubleValue];
        if (r >= 8.0 && r <= 40.0) gChatRadius = r;
    }
    if ([cfg[@"theme"] isKindOfClass:[NSString class]]) gLight = ![cfg[@"theme"] isEqualToString:@"dark"];
    if ([p[@"alpha"] isKindOfClass:[NSNumber class]]) {
        CGFloat a = [p[@"alpha"] doubleValue];
        if (a > 0.05 && a <= 1.0) gAlpha = a;
    }
    if ([cfg[@"hide_footer"] isKindOfClass:[NSNumber class]]) gHideFooter = [cfg[@"hide_footer"] boolValue];
    if ([cfg[@"dim_blur"] isKindOfClass:[NSNumber class]]) gDimBlur = [cfg[@"dim_blur"] boolValue];

    NSArray *rs = [cfg[@"rules"] isKindOfClass:[NSArray class]] ? cfg[@"rules"] : @[];
    NSMutableArray *ok = [NSMutableArray array];
    for (id r in rs) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        if (![r[@"text"] isKindOfClass:[NSString class]] || [r[@"text"] length] == 0) continue;
        [ok addObject:r];
    }
    gRules = ok;

    NSArray *cs = [cfg[@"colors"] isKindOfClass:[NSArray class]] ? cfg[@"colors"] : @[];
    NSMutableArray *colors = [NSMutableArray array];
    for (id r in cs) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        if (![r[@"text"] isKindOfClass:[NSString class]] || [r[@"text"] length] == 0) continue;
        if (![r[@"color"] isKindOfClass:[NSString class]]) continue;
        [colors addObject:r];
    }
    gColorRules = colors;
    if (migrated) {
        @try {
            NSData *d = [NSJSONSerialization dataWithJSONObject:merged options:NSJSONWritingPrettyPrinted error:NULL];
            [d writeToFile:path atomically:YES];
            SkinLog(@"视觉配置已迁移到 v2 原生浅色玻璃");
        } @catch (__unused NSException *e) {}
    }
    SkinLog(@"配置生效：规则 %lu 条，配色 %@ / %@ / %@ alpha=%.2f 底 %@ 页脚%@",
            (unsigned long)gRules.count, p[@"a"] ?: @"默认", p[@"b"] ?: @"默认", p[@"c"] ?: @"默认",
            gAlpha, p[@"base"] ?: @"默认", gHideFooter ? @"隐藏" : @"保留");
    SkinLog(@"主题：%@  磨砂层：%@", gLight ? @"浅色（半透明白行 + 深色正文）" : @"深色",
            gDimBlur ? @"摘除" : @"保留");
}

static BOOL SkinRuleMatches(NSDictionary *r, NSString *text) {
    NSString *needle = r[@"text"];
    NSString *mode = [r[@"match"] isKindOfClass:[NSString class]] ? r[@"match"] : @"contains";
    if ([mode isEqualToString:@"exact"])  return [text isEqualToString:needle];
    if ([mode isEqualToString:@"prefix"]) return [text hasPrefix:needle];
    if ([mode isEqualToString:@"suffix"]) return [text hasSuffix:needle];
    if ([mode isEqualToString:@"regex"]) {
        NSError *err = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:needle
                                                                           options:0 error:&err];
        if (!re || err) return NO;
        return [re numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0;
    }
    return [text rangeOfString:needle].location != NSNotFound;
}

// 命中「只上色」规则就返回霓虹紫（或配置里的任意颜色），没命中返回 nil。
static UIColor *SkinColorForText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || gColorRules.count == 0) return nil;
    for (NSDictionary *r in gColorRules) {
        @try {
            if (SkinRuleMatches(r, text)) return SkinHex(r[@"color"], nil);
        } @catch (__unused NSException *e) {}
    }
    return nil;
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
        if ([self isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)self;
            UIColor *neon = SkinColorForText(mapped);
            if (neon) {
                lb.textColor = neon;
                lb.backgroundColor = [UIColor clearColor];
                if (lb.superview && [NSStringFromClass([lb.superview class]) rangeOfString:@"Bubble"].location != NSNotFound)
                    lb.superview.backgroundColor = [UIColor clearColor];
            }
        }
    } @catch (__unused NSException *e) {
        if (o_setText) o_setText(self, _cmd, text);
    }
}

// ---------------------------------------------------------------------------
// 玻璃 / cell 外观
// ---------------------------------------------------------------------------
static const NSInteger kSkinGradientTag = 0x534B31; // 'SK1'
static const NSInteger kSkinPanelTag = 0x534B32;
static const NSInteger kSkinCardTag = 0x534B33;
static const NSInteger kSkinChatBG = 0x534B34;

static void SkinStyleGlass(UIView *v) {
    if (!v || v.tag == kSkinGradientTag) return;
    NSString *cn = NSStringFromClass([v class]) ?: @"";
    BOOL isGlass = [cn rangeOfString:@"Glass"].location != NSNotFound
                || [cn rangeOfString:@"Capsule"].location != NSNotFound
                || [cn rangeOfString:@"PillButton"].location != NSNotFound;
    if (!isGlass) return;

    v.layer.cornerRadius = ([cn rangeOfString:@"Pill"].location != NSNotFound)
                         ? v.bounds.size.height / 2.0 : gCardRadius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.6;
    v.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.88].CGColor;
    v.backgroundColor = [gColC colorWithAlphaComponent:0.52];

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
        g.colors = @[ (__bridge id)[gColC colorWithAlphaComponent:0.58].CGColor,
                      (__bridge id)[gColB colorWithAlphaComponent:0.34].CGColor,
                      (__bridge id)[gColA colorWithAlphaComponent:gAlpha].CGColor ];
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

// 只改「被我们或深色主题染成近白」的 label —— 深色正文、彩色角标一律不动，
// 否则详情页会出现白字压浅底的情况（v16 真机就是这个症状）。
static void SkinFixLabel(UILabel *lb) {
    if (!lb || lb.hidden) return;
    UIColor *neon = SkinColorForText(lb.text);
    if (neon) {
        lb.textColor = neon;
        lb.backgroundColor = [UIColor clearColor];
        return;
    }
    if (!lb.textColor) return;
    if (!gLight) { lb.textColor = [UIColor colorWithWhite:0.96 alpha:1.0]; return; }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![lb.textColor getRed:&r green:&g blue:&b alpha:&a]) return;
    CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    if (mx > 0.78 && (mx - mn) < 0.12) lb.textColor = gText;
}

static void SkinFixLabelRecursive(UIView *root, NSInteger depth);

static void SkinStyleCell(UITableViewCell *cell) {
    if (!cell) return;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    if (cell.backgroundView) cell.backgroundView.backgroundColor = [UIColor clearColor];
    cell.opaque = NO;
    UIView *sel = cell.selectedBackgroundView;
    if (sel) sel.backgroundColor = [gChatAccent colorWithAlphaComponent:0.12];

    // 在 contentView 内插入独立卡片，不移动宿主 cell 的结构或约束。
    UIView *card = [cell.contentView viewWithTag:kSkinCardTag];
    if (!card) {
        card = [[UIView alloc] initWithFrame:CGRectZero];
        card.tag = kSkinCardTag;
        card.userInteractionEnabled = NO;
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        card.layer.borderWidth = 0.6;
        card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.86].CGColor;
        [cell.contentView insertSubview:card atIndex:0];
    }
    card.frame = CGRectInset(cell.contentView.bounds, 6.0, 4.0);
    card.backgroundColor = [gColC colorWithAlphaComponent:gCardAlpha];
    card.layer.cornerRadius = gCardRadius;
    SkinFixLabelRecursive(cell.contentView, 0);
}

static void SkinFixLabelRecursive(UIView *root, NSInteger depth) {
    if (!root || depth > 5) return;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) SkinFixLabel((UILabel *)sub);
        else SkinFixLabelRecursive(sub, depth + 1);
    }
}

static void SkinWalk(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return;
    @try {
        SkinStyleGlass(root);
        // 面板与详情页的底是一层 UIVisualEffectView（v15E 的崩溃栈里就有一条
        // -[UIVisualEffectView layoutSubviews]）。它压在我们的渐变上面，
        // 不清掉的话青蓝紫会被磨砂糊成一层灰白 —— 所以这里把它的 effect 摘掉，
        // 只留一层极淡的底色。
        if (gDimBlur && [root isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *fx = (UIVisualEffectView *)root;
            if (fx.effect) { fx.effect = nil; SkinLog(@"已摘除磨砂层 %@", NSStringFromClass([fx class])); }
            fx.backgroundColor = gLight ? [UIColor clearColor]
                                        : [gBase colorWithAlphaComponent:0.35];
        }
        if ([root isKindOfClass:[UILabel class]]) SkinFixLabel((UILabel *)root);
        if ([root isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)root;
            tv.backgroundColor = [UIColor clearColor];
            tv.opaque = NO;
            tv.separatorStyle = UITableViewCellSeparatorStyleNone;
            tv.separatorColor = [UIColor clearColor];
        }
        NSString *rcn = NSStringFromClass([root class]) ?: @"";
        if ([rcn rangeOfString:@"HeaderFooterView"].location != NSNotFound) {
            root.backgroundColor = [UIColor clearColor];
            for (UIView *sub in root.subviews) {
                if ([sub isKindOfClass:[UILabel class]]) SkinFixLabel((UILabel *)sub);
            }
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
    bg.colors = @[ (__bridge id)[UIColor whiteColor].CGColor,
                   (__bridge id)[gColB colorWithAlphaComponent:0.72].CGColor,
                   (__bridge id)[gColA colorWithAlphaComponent:gAlpha].CGColor ];
    bg.startPoint = CGPointMake(0.05, 0.0);
    bg.endPoint = CGPointMake(0.95, 1.0);
    bg.frame = v.bounds;
    [host.layer addSublayer:bg];
    [v insertSubview:host atIndex:0];
    SkinLog(@"面板底色已应用（系统浅色玻璃）");
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
// 聊天页宿主布局：只处理背景、导航和输入条，不修改消息模型或功能开关
// ---------------------------------------------------------------------------
static void SkinStyleChatNodes(UIView *root, NSInteger depth) {
    if (!root || depth > 7) return;
    @try {
        UIView *view = root;
        if ([view isKindOfClass:[UITextField class]]) {
            UIView *bar = view.superview;
            if (bar) {
                bar.backgroundColor = [gChatSurface colorWithAlphaComponent:gChatSurfaceAlpha];
                bar.layer.cornerRadius = MIN(gChatRadius, MAX(12.0, CGRectGetHeight(bar.bounds) / 2.0));
                bar.layer.cornerCurve = kCACornerCurveContinuous;
                bar.layer.borderWidth = 0.6;
                bar.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85].CGColor;
            }
        } else {
            NSString *cn = NSStringFromClass([view class]).lowercaseString ?: @"";
            BOOL chrome = [cn rangeOfString:@"input"].location != NSNotFound
                       || [cn rangeOfString:@"toolbar"].location != NSNotFound
                       || [cn rangeOfString:@"bottombar"].location != NSNotFound
                       || [cn rangeOfString:@"composer"].location != NSNotFound
                       || [cn rangeOfString:@"capsule"].location != NSNotFound;
            if (chrome && view.bounds.size.width > 100.0 && view.bounds.size.height >= 32.0 &&
                view.bounds.size.height <= 180.0) {
                view.backgroundColor = [gChatSurface colorWithAlphaComponent:gChatSurfaceAlpha];
                view.layer.cornerRadius = MIN(gChatRadius, MAX(12.0, CGRectGetHeight(view.bounds) / 2.0));
                view.layer.cornerCurve = kCACornerCurveContinuous;
                view.layer.borderWidth = 0.6;
                view.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85].CGColor;
            }
        }
        if ([view isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)view;
            tv.backgroundColor = [UIColor clearColor];
            tv.separatorStyle = UITableViewCellSeparatorStyleNone;
        }
        for (UIView *sub in view.subviews) SkinStyleChatNodes(sub, depth + 1);
    } @catch (__unused NSException *e) {}
}

static void SkinApplyChatStyle(UIViewController *vc) {
    if (!gChatStyle || !vc || !vc.view) return;
    @try {
        UIView *v = vc.view;
        v.backgroundColor = gChatBase;

        UIView *bg = [v viewWithTag:kSkinChatBG];
        if (!bg) {
            bg = [[UIView alloc] initWithFrame:v.bounds];
            bg.tag = kSkinChatBG;
            bg.userInteractionEnabled = NO;
            bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            CAGradientLayer *g = [CAGradientLayer layer];
            g.colors = @[ (__bridge id)[UIColor whiteColor].CGColor,
                          (__bridge id)[gChatBase colorWithAlphaComponent:0.94].CGColor,
                          (__bridge id)[gChatAccent colorWithAlphaComponent:0.035].CGColor ];
            g.startPoint = CGPointMake(0.0, 0.0);
            g.endPoint = CGPointMake(1.0, 1.0);
            g.frame = v.bounds;
            [bg.layer addSublayer:g];
            [v insertSubview:bg atIndex:0];
        } else {
            bg.frame = v.bounds;
        }

        UINavigationController *nav = vc.navigationController;
        if (nav) {
            UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
            [ap configureWithTransparentBackground];
            ap.backgroundColor = [UIColor clearColor];
            ap.shadowColor = [UIColor clearColor];
            ap.titleTextAttributes = @{ NSForegroundColorAttributeName: gText };
            nav.navigationBar.standardAppearance = ap;
            nav.navigationBar.scrollEdgeAppearance = ap;
            nav.navigationBar.compactAppearance = ap;
            nav.navigationBar.tintColor = gText;
        }
        SkinStyleChatNodes(v, 0);
        SkinLog(@"聊天页布局已应用：%@@%.2f radius=%.1f", gChatSurface,
                (double)gChatSurfaceAlpha, (double)gChatRadius);
    } @catch (__unused NSException *e) {
        SkinLog(@"聊天页布局异常，已忽略");
    }
}

static void (*o_chatDidLoad)(id, SEL);
static void r_chatDidLoad(id self, SEL _cmd) {
    if (o_chatDidLoad) o_chatDidLoad(self, _cmd);
    @try {
        if ([self isKindOfClass:[UIViewController class]])
            SkinApplyChatStyle((UIViewController *)self);
    } @catch (__unused NSException *e) {}
}

static void (*o_chatWillAppear)(id, SEL, BOOL);
static void r_chatWillAppear(id self, SEL _cmd, BOOL animated) {
    if (o_chatWillAppear) o_chatWillAppear(self, _cmd, animated);
    @try {
        if ([self isKindOfClass:[UIViewController class]])
            SkinApplyChatStyle((UIViewController *)self);
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
    SkinLog(@"build=v19-liquid-glass-video");
    Class panel  = NSClassFromString(@"HushSettingsPanel");
    Class detail = NSClassFromString(@"HushModuleDetailController");
    Class glass  = NSClassFromString(@"HushGlassView");
    Class cell   = NSClassFromString(@"HushSwitchCell");
    Class dcell  = NSClassFromString(@"HushModuleEntry");
    Class foot   = NSClassFromString(@"HushAuthorFooterView");
    Class chat   = NSClassFromString(@"PrivateChatViewController");

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
    if (chat) {
        o_chatDidLoad = (void (*)(id, SEL))SkinReplace(chat, @selector(viewDidLoad), (IMP)&r_chatDidLoad);
        o_chatWillAppear = (void (*)(id, SEL, BOOL))SkinReplace(chat, @selector(viewWillAppear:), (IMP)&r_chatWillAppear);
    }
    o_setText = (void (*)(id, SEL, NSString *))SkinReplace([UILabel class], @selector(setText:), (IMP)&r_setText);

    SkinLog(@"hook 结果：panel=%d detail=%d glass=%d cell=%d entry=%d footer(draw=%d,layout=%d) chat=%d label=%d",
            panel != nil, detail != nil, glass != nil, cell != nil, dcell != nil,
            o_footerDraw != nil, o_footerLayout != nil, chat != nil, o_setText != nil);
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
