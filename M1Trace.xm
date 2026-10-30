// ============================================================================
// M1Trace.xm —— M-1 取证版（v13.0-m1）观测骨架
//
// 目的：只观测、不修复。给「卡启动图 / 设置页闪退」拿到一手证据。
//
// 这个编译单元【不做】的事（故意不做，为了不引入任何新变量）：
//   · 不安装任何净化锚点（不调 method_setImplementation 到宿主业务方法）
//   · 不写 purify_* / switch_* 任何开关的值（唯一例外：purify_splash_mode=0，见下）
//   · 不注册悬浮球、不建窗口、不加设置页入口、不带任何 UI
//   · 不调用 class_getInstanceMethod / class_getClassMethod / class_addMethod /
//     objc_msgSend（v5 铁律：会触发宿主 +initialize → 启动期闪退）
//
// 这个编译单元【做】的事：
//   1. BOOT/ENV 横幅：dylib 构建时间、bundle id、版本、机型、iOS、是否 LiveContainer
//   2. 双落盘：Documents/REA-M1.log（文件） + NSLog（Windows 端可用 pymodledevice3/爱思实时抓）
//   3. 崩溃现场：常驻 crash fd + 环形缓冲 + 信号处理 + 未捕获异常 chained handler
//   4. 主线程阻塞采样：后台心跳 + CFRunLoopObserver，>200ms 记 STALL
//   5. 屏幕状态时间线：每 0.25s 采 topVC / 是否还挂着 Splash 类视图
//   6. 锚点清点（ANCHOR）：19 条 splash 锚点 + 4 条设置页锚点在**真机**上的
//      实际 owner 类与 typeEncoding —— 这是审核 B1 的直接证据
//   7. 视图生命周期旁路：UIView -didMoveToSuperview（含「被移除」）与
//      UIViewController -viewDidAppear: 的调用时间线
//   8. 写 purify_splash_mode=0（仅当不存在），让净化引擎保持全关
//
// 纪律：+load / ctor 里只 NSLog + 调度，任何 Runtime 探测都推迟到 main+0.2s 之后。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
// 局域网日志上传：用裸 TCP，不走 NSURLSession，因此不受宿主 App 的 ATS（App Transport
// Security 禁止明文 HTTP）约束 —— 非越狱机器上这是唯一稳定的实时读日志通道。
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#define M1_TAG      @"[REA-Test]"
#define M1_LINE     512
#define M1_RING     160
#define M1_MARK     "M1-TRACE-v1"
#define M1_LOG_PORT     8765    // 日志输入 TCP 端口（与 tools/m1log_server.py 一致）
#define M1_DISCOVER_PORT 8766   // UDP 广播发现端口

// ============================================================================
#pragma mark - 时间与落盘
// ============================================================================

static double   gM1T0        = 0.0;
static int      gM1Fd        = -1;      // 主日志 fd（Documents/REA-M1.log）
static int      gM1CrashFd   = -1;      // 崩溃现场 fd（Documents/REA-M1-crash.log）
static volatile int gM1On    = 1;       // rea_m1_off 的运行时快照
static volatile int gM1RingIdx = 0;
static char     gM1Ring[M1_RING][M1_LINE];
static char     gM1Docs[512] = {0};

// 上传通道（默认关闭；由 defaults key rea_m1_upload = "192.168.1.7:8765" 开启）
static void M1OutboxAppend(const char *line);
static void M1UploadDiscover(void);
static void M1UploadStartTimer(void);

static double M1Abs(void) {
    static mach_timebase_info_data_t tb;
    static int once = 0;
    if (!once) { mach_timebase_info(&tb); once = 1; }
    double ns = (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom;
    return ns / 1e9;
}

static double M1T(void) {
    if (gM1T0 <= 0.0) gM1T0 = M1Abs();
    return M1Abs() - gM1T0;
}

static void M1WriteAll(int fd, const char *s, size_t n) {
    if (fd < 0 || s == NULL || n == 0) return;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, s + off, n - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
}

// 信号安全路径：只做 ring 快照 + write，不碰 ObjC
static void M1DumpRingTo(int fd, const char *why) {
    char hdr[128];
    int n = snprintf(hdr, sizeof(hdr), "==== M1 RING DUMP (%s) total=%d ====\n", why, (int)gM1RingIdx);
    if (n > 0) M1WriteAll(fd, hdr, (size_t)n);
    int total = gM1RingIdx;
    int start = (total > M1_RING) ? (total - M1_RING) : 0;
    for (int k = start; k < total; k++) {
        const char *s = gM1Ring[k % M1_RING];
        if (s[0]) M1WriteAll(fd, s, strlen(s));
    }
}

static void M1Emit(const char *body) {
    char line[M1_LINE];
    int n = snprintf(line, sizeof(line), "t=%.3f %s\n", M1T(), body);
    if (n <= 0) return;
    if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;

    int slot = gM1RingIdx % M1_RING;
    memcpy(gM1Ring[slot], line, (size_t)n + 1);
    gM1RingIdx = gM1RingIdx + 1;

    M1WriteAll(gM1Fd, line, (size_t)n);
    M1OutboxAppend(line);
}


// 主线程/任意线程都可调；内部无锁，最坏情况丢一行环形快照，不影响正确性
static void M1Log(const char *fmt, ...) {
    if (!gM1On) return;
    char body[M1_LINE];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    M1Emit(body);
    NSLog(@"%@ %s", M1_TAG, body);
}

static void M1OpenSink(void) {
    if (gM1Fd >= 0) return;
    @autoreleasepool {
        NSString *docs = nil;
        @try {
            docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        } @catch (NSException *e) { docs = nil; }
        if (docs.length == 0) docs = NSTemporaryDirectory();
        if (docs.length == 0) return;

        snprintf(gM1Docs, sizeof(gM1Docs), "%s", docs.UTF8String ?: "");

        NSString *p1 = [docs stringByAppendingPathComponent:@"REA-M1.log"];
        gM1Fd = open(p1.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);

        NSString *p2 = [docs stringByAppendingPathComponent:@"REA-M1-crash.log"];
        gM1CrashFd = open(p2.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (gM1CrashFd < 0) gM1CrashFd = gM1Fd;
    }
}

// ============================================================================
#pragma mark - 崩溃现场
// ============================================================================

static void M1SignalHandler(int sig) {
    M1DumpRingTo(gM1CrashFd, "SIGNAL");
    char b[96];
    int n = snprintf(b, sizeof(b), "==== SIGNAL %d → SIG_DFL + re-raise ====\n", sig);
    if (n > 0) M1WriteAll(gM1CrashFd, b, (size_t)n);
    signal(sig, SIG_DFL);
    raise(sig);
}

static NSUncaughtExceptionHandler *gM1PrevHandler = NULL;

static void M1ExceptionHandler(NSException *e) {
    @try {
        NSString *s = [NSString stringWithFormat:@"==== EXCEPTION %@: %@\n%@\n",
                       e.name, e.reason, e.callStackSymbols];
        M1WriteAll(gM1CrashFd, s.UTF8String, strlen(s.UTF8String));
    } @catch (NSException *ignored) { }
    M1DumpRingTo(gM1CrashFd, "EXCEPTION");
    if (gM1PrevHandler) gM1PrevHandler(e);   // 链式：不吞宿主的 handler
}

static void M1InstallCrashHooks(void) {
    @try {
        gM1PrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&M1ExceptionHandler);
        signal(SIGSEGV, M1SignalHandler);
        signal(SIGBUS,  M1SignalHandler);
        signal(SIGABRT, M1SignalHandler);
        signal(SIGILL,  M1SignalHandler);
        signal(SIGFPE,  M1SignalHandler);
        signal(SIGTRAP, M1SignalHandler);
    } @catch (NSException *e) { }
}

// ============================================================================
#pragma mark - 环境横幅（审核要的「能不能复现」的前置条件）
// ============================================================================

static char gM1Machine[64] = {0};

static void M1ReadMachine(void) {
    size_t sz = sizeof(gM1Machine);
    if (sysctlbyname("hw.machine", gM1Machine, &sz, NULL, 0) != 0) {
        snprintf(gM1Machine, sizeof(gM1Machine), "?");
    }
}

static int M1InLiveContainer(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "LiveContainer")) return 1;
    }
    const char *exe = NSBundle.mainBundle.executablePath.UTF8String;
    if (exe && strstr(exe, "LiveContainer")) return 1;
    return 0;
}

static void M1BootBanner(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        NSString *bid   = mb.bundleIdentifier ?: @"?";
        NSString *ver   = [mb objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        NSString *build = [mb objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
        NSString *exe   = mb.executablePath ?: @"?";
        NSString *ios   = UIDevice.currentDevice.systemVersion ?: @"?";

        M1Log("[M1] BOOT marker=%s compiled=%s %s pid=%d", M1_MARK, __DATE__, __TIME__, (int)getpid());
        M1Log("[M1] ENV bid=%s ver=%s build=%s machine=%s ios=%s livecontainer=%d",
              bid.UTF8String, ver.UTF8String, build.UTF8String, gM1Machine, ios.UTF8String,
              M1InLiveContainer() ? 1 : 0);
        M1Log("[M1] ENV executable=%s", exe.UTF8String);
        M1Log("[M1] ENV docs=%s", gM1Docs);

        // 文档目录里已存在的旧日志（采集成败可从这里看）
        @try {
            NSString *docs = [NSString stringWithUTF8String:gM1Docs];
            NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
            NSMutableString *acc = [NSMutableString string];
            for (NSString *nm in names) {
                if ([nm hasSuffix:@".log"] || [nm hasSuffix:@".ips"] || [nm hasSuffix:@".txt"]) {
                    [acc appendFormat:@"%@,", nm];
                }
            }
            M1Log("[M1] ENV doclogs=%s", acc.length ? acc.UTF8String : "(none)");
        } @catch (NSException *e) { }
    }
}

// ============================================================================
#pragma mark - 主线程阻塞采样（卡 vs 崩 的分界线）
// ============================================================================

static uint64_t gM1LastWake = 0;

static void M1RunLoopObserverCB(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    uint64_t now = mach_absolute_time();
    if (activity == kCFRunLoopAfterWaiting) {
        gM1LastWake = now;
        return;
    }
    if (activity == kCFRunLoopBeforeSources) {
        if (gM1LastWake != 0) {
            static mach_timebase_info_data_t tb;
            static int once = 0;
            if (!once) { mach_timebase_info(&tb); once = 1; }
            double ms = (double)(now - gM1LastWake) * (double)tb.numer / (double)tb.denom / 1e6;
            if (ms >= 200.0) M1Log("[M1] STALL %.0fms (runloop beforeSources)", ms);
        }
        gM1LastWake = now;
    }
}

static void M1InstallRunLoopObserver(void) {
    CFRunLoopObserverRef o = CFRunLoopObserverCreate(kCFAllocatorDefault,
        kCFRunLoopBeforeSources | kCFRunLoopAfterWaiting, true, 0, M1RunLoopObserverCB, NULL);
    if (o) CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
}

// 后台心跳：每 0.5s 往主线程投一次，量「主线程多久才能处理它」
static void M1InstallHeartbeat(void) {
    dispatch_queue_t q = dispatch_queue_create("rea.m1.heartbeat", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!t) return;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        double posted = M1Abs();
        dispatch_async(dispatch_get_main_queue(), ^{
            double lat = (M1Abs() - posted) * 1000.0;
            if (lat >= 200.0) M1Log("[M1] STALL %.0fms (main queue latency)", lat);
        });
    });
    dispatch_resume(t);
}

// ============================================================================
#pragma mark - 屏幕状态时间线
// ============================================================================

static NSString *M1TopVCClass(void) {
    UIViewController *vc = nil;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow) { vc = w.rootViewController; break; }
        }
        if (!vc) {
            for (UIWindow *w in app.windows) { if (w.rootViewController) { vc = w.rootViewController; break; } }
        }
        int guard = 0;
        while (vc.presentedViewController && guard++ < 16) vc = vc.presentedViewController;
        // 继续往导航/标签的子控制器走一层，拿到真正可见的那个
        int guard2 = 0;
        while (guard2++ < 8) {
            UIViewController *next = nil;
            if ([vc isKindOfClass:[UINavigationController class]]) {
                next = ((UINavigationController *)vc).topViewController;
            } else if ([vc isKindOfClass:[UITabBarController class]]) {
                next = ((UITabBarController *)vc).selectedViewController;
            }
            if (!next || next == vc) break;
            vc = next;
        }
    } @catch (NSException *e) { }
    return vc ? NSStringFromClass(object_getClass(vc)) : @"(nil)";
}

// 广度优先统计窗口树上「像广告/开屏」的视图：命中即记类名
static void M1ScanAdViews(int *outTotal, int *outAd, NSMutableString *outNames) {
    *outTotal = 0; *outAd = 0;
    UIWindow *key = nil;
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow) { key = w; break; } }
        if (!key) return;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:key];
        int guard = 0;
        while (queue.count > 0 && guard++ < 400) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            (*outTotal)++;
            NSString *cn = NSStringFromClass(object_getClass(v));
            if (cn.length && ([cn rangeOfString:@"Splash"].location != NSNotFound ||
                              [cn hasPrefix:@"ABU"] || [cn hasPrefix:@"ADX"] ||
                              [cn rangeOfString:@"GDT"].location != NSNotFound ||
                              [cn rangeOfString:@"_KS"].location != NSNotFound)) {
                (*outAd)++;
                if (outNames.length < 200) [outNames appendFormat:@"%@,", cn];
            }
            for (UIView *s in v.subviews) { if (queue.count < 400) [queue addObject:s]; }
        }
    } @catch (NSException *e) { }
}

static void M1InstallScreenSampler(void) {
    dispatch_queue_t q = dispatch_queue_create("rea.m1.screen", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!t) return;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 30 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        // 只在主线程读 UIKit
        dispatch_async(dispatch_get_main_queue(), ^{
            static NSString *lastVC = nil;
            static int tick = 0;
            static int adSeen = 0;
            tick++;
            double t = M1T();
            if (t > 120.0) return;                     // 两分钟后停止采样，避免日志膨胀

            NSString *vc = M1TopVCClass();
            BOOL changed = (!lastVC || ![vc isEqualToString:lastVC]);
            lastVC = vc;

            int total = 0, ad = 0;
            NSMutableString *names = [NSMutableString string];
            M1ScanAdViews(&total, &ad, names);
            if (ad > 0) adSeen++;

            if (changed) {
                M1Log("[M1] SCREEN vc=%s adviews=%d nodes=%d ads=[%s]", vc.UTF8String, ad, total,
                      names.length ? names.UTF8String : "");
            } else if (tick % 4 == 0) {
                M1Log("[M1] SCREEN . vc=%s adviews=%d nodes=%d", vc.UTF8String, ad, total);
            }
            // 明确的「卡住」候选：Splash 类视图连续 8 次采样（约 2s）还在
            if (ad >= 1 && adSeen >= 8 && adSeen % 8 == 0) {
                M1Log("[M1] STUCK-CANDIDATE adviews=%d held~%ds ads=[%s]",
                      ad, adSeen / 4, names.length ? names.UTF8String : "");
            }
        });
    });
    dispatch_resume(t);
}

// ============================================================================
#pragma mark - 锚点清点（这是审核 B1 的直接证据）
// ============================================================================

typedef struct {
    const char *cls;
    const char *sel;
    const char *tag;    // 属于哪一族（L0/L1/L2/L3/L4 或 SET）
} M1Anchor;

static const M1Anchor kM1Anchors[] = {
    { "AppDelegateModel",                          "isNeedShowSplashAd",                                    "L0" },
    { "AppDelegateModel",                          "showSplashAd:",                                         "L1" },
    { "AppDelegateModel",                          "getSplashAdForColdLaunch",                              "L1" },
    { "AppDelegateModel",                          "p_getSplashAdvertisementForColdLaunch",                 "L1" },
    { "BDGDTSplashAdManager",                      "showGDTSplash",                                         "L4" },
    { "BDKSSplashAdManager",                       "showKSSplash",                                          "L4" },
    { "BDADX_Blued_Splash_Image_ViewController",   "presentBluedSplashImageViewController",                 "L4" },
    { "BDIndexPageCoversManager",                  "showSplashAd:currentWinAdModel:isColdLaunch:finished:", "L2" },
    { "BDIndexPageCoversManager",                  "showSplashAd_Adx:currentWinAdModel:isColdLaunch:finished:", "L2" },
    { "BDIndexPageCoversManager",                  "showSplashAd_Normal:isColdLaunch:finished:",            "L2" },
    { "BDIndexPageCoversManager",                  "p_showGDTSplash:isColdLaunch:finished:",                "L2" },
    { "BDIndexPageCoversManager",                  "p_showKSSplash:isColdLaunch:finished:",                 "L2" },
    { "BDIndexPageCoversManager",                  "p_showPangleSplash:isColdLaunch:finished:",             "L2" },
    { "BDIndexPageCoversManager",                  "p_showBluedImageSplash:currentWinAdModel:isColdLaunch:finished:", "L2" },
    { "BDIndexPageCoversManager",                  "p_showBluedVideoSplash:currentWinAdModel:isColdLaunch:finished:", "L2" },
    { "BDADXBaseSplashAdManager",                  "assembleSplashContainerView:needRemoveHandler:",        "L4" },
    { "ABUSplashAd",                               "showInWindow:",                                         "L3" },
    { "ABUSplashAd",                               "showInWindowWithBlock:",                                "L3" },
    { "BDSplashVideoAdViewController",             "presentInViewController:",                              "L3" },
};

// 设置页四钩（P0-B 的 owner 实证）
static const M1Anchor kM1SettingHooks[] = {
    { "BDSettingViewController", "tableView:numberOfRowsInSection:", "SET" },
    { "BDSettingViewController", "tableView:cellForRowAtIndexPath:", "SET" },
    { "BDSettingViewController", "tableView:didSelectRowAtIndexPath:", "SET" },
    { "BDSettingViewController", "tableView:heightForRowAtIndexPath:", "SET" },
};

// 沿着 superclass 找真正实现该选择子的类（只用 class_copyMethodList，不触发 +initialize）
static Class M1OwnerClass(Class cls, SEL sel, Method *outMethod) {
    Class cur = cls;
    int depth = 0;
    while (cur != Nil && depth++ < 32) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(cur, &n);
        if (ms) {
            for (unsigned int i = 0; i < n; i++) {
                if (method_getName(ms[i]) == sel) {
                    if (outMethod) *outMethod = ms[i];
                    free(ms);
                    return cur;
                }
            }
            free(ms);
        }
        cur = class_getSuperclass(cur);
    }
    if (outMethod) *outMethod = NULL;
    return Nil;
}

static void M1InventoryOne(const M1Anchor *a, int *ok, int *miss) {
    Class cls = objc_getClass(a->cls);
    if (cls == Nil) {
        M1Log("[M1] ANCHOR miss class=%s sel=%s tag=%s why=class-not-exist",
              a->cls, a->sel, a->tag);
        (*miss)++;
        return;
    }
    SEL sel = sel_registerName(a->sel);
    Method m = NULL;
    Class owner = M1OwnerClass(cls, sel, &m);
    if (owner == Nil || m == NULL) {
        M1Log("[M1] ANCHOR miss class=%s sel=%s tag=%s why=sel-not-found(+supers)",
              a->cls, a->sel, a->tag);
        (*miss)++;
        return;
    }
    const char *types = method_getTypeEncoding(m);
    M1Log("[M1] ANCHOR ok class=%s sel=%s tag=%s owner=%s types=%s",
          a->cls, a->sel, a->tag, class_getName(owner), types ? types : "?");
    (*ok)++;
}

static void M1Inventory(void) {
    int ok = 0, miss = 0;
    size_t n = sizeof(kM1Anchors) / sizeof(kM1Anchors[0]);
    M1Log("[M1] ANCHOR begin splash=%zu", n);
    for (size_t i = 0; i < n; i++) {
        @autoreleasepool { M1InventoryOne(&kM1Anchors[i], &ok, &miss); }
    }
    M1Log("[M1] ANCHOR splash ok=%d miss=%d total=%zu", ok, miss, n);

    int sok = 0, smiss = 0;
    size_t sn = sizeof(kM1SettingHooks) / sizeof(kM1SettingHooks[0]);
    for (size_t i = 0; i < sn; i++) {
        @autoreleasepool { M1InventoryOne(&kM1SettingHooks[i], &sok, &smiss); }
    }
    M1Log("[M1] ANCHOR settings ok=%d miss=%d total=%zu (owner 是否全等见上面逐行 owner=)",
          sok, smiss, sn);

    // 关键类是否在同版本里还在（版本漂移的第一诊断点）
    const char *probe[] = { "BDIndexPageCoversManager", "ABUSplashAd", "ABUSplashAdView",
                            "BDADXBaseSplashAdManager", "BDSplashVideoAdViewController",
                            "BDSettingViewController", "BDPrivacySettingViewController" };
    for (size_t i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
        M1Log("[M1] CLASS %s %s", probe[i], objc_getClass(probe[i]) ? "present" : "absent");
    }
}

// ============================================================================
#pragma mark - 视图生命周期旁路（只观测，void 返回，安全换实现）
// ============================================================================

typedef void (*M1Imp_VDMS)(id, SEL);
typedef void (*M1Imp_VDA)(id, SEL, BOOL);

static M1Imp_VDMS gM1OrigVDMS = NULL;
static M1Imp_VDA  gM1OrigVDA  = NULL;
static int        gM1ViewLog  = 0;      // 只记「像广告」的视图，避免刷屏

static int M1NameLooksLikeAd(const char *cn) {
    if (!cn) return 0;
    if (strstr(cn, "Splash")) return 1;
    if (strstr(cn, "ABU")) return 1;
    if (strstr(cn, "ADX")) return 1;
    if (strstr(cn, "GDT")) return 1;
    if (strstr(cn, "Pangle")) return 1;
    return 0;
}

static void M1ViewDidMoveToSuperview(id self, SEL _cmd) {
    @autoreleasepool {
        if (gM1On && gM1ViewLog) {
            @try {
                const char *cn = object_getClassName(self);
                if (M1NameLooksLikeAd(cn)) {
                    UIView *v = (UIView *)self;
                    UIView *sp = v.superview;
                    const char *spn = sp ? object_getClassName(sp) : "(nil)";
                    M1Log("%s cls=%s super=%s w=%.0f h=%.0f hidden=%d alpha=%.2f",
                          sp ? "[M1] VIEW+" : "[M1] VIEW-",
                          cn, spn, v.frame.size.width, v.frame.size.height,
                          v.hidden ? 1 : 0, v.alpha);
                }
            } @catch (NSException *e) { }
        }
    }
    if (gM1OrigVDMS) gM1OrigVDMS(self, _cmd);
}

static void M1ViewDidAppear(id self, SEL _cmd, BOOL animated) {
    @autoreleasepool {
        if (gM1On) {
            @try {
                M1Log("[M1] VC appear cls=%s", object_getClassName(self));
            } @catch (NSException *e) { }
        }
    }
    if (gM1OrigVDA) gM1OrigVDA(self, _cmd, animated);
}

static void M1InstallViewHooks(void) {
    gM1ViewLog = 1;
    @try {
        // UIView -didMoveToSuperview（无参数、void 返回）
        Class uiv = objc_getClass("UIView");
        if (uiv) {
            SEL s = sel_registerName("didMoveToSuperview");
            Method m = NULL;
            Class owner = M1OwnerClass(uiv, s, &m);
            if (owner && m) {
                gM1OrigVDMS = (M1Imp_VDMS)method_getImplementation(m);
                method_setImplementation(m, (IMP)M1ViewDidMoveToSuperview);
                M1Log("[M1] HOOK ok UIView -didMoveToSuperview owner=%s", class_getName(owner));
            } else {
                M1Log("[M1] HOOK miss UIView -didMoveToSuperview");
            }
        }
        // UIViewController -viewDidAppear:
        Class uivc = objc_getClass("UIViewController");
        if (uivc) {
            SEL s = sel_registerName("viewDidAppear:");
            Method m = NULL;
            Class owner = M1OwnerClass(uivc, s, &m);
            if (owner && m) {
                gM1OrigVDA = (M1Imp_VDA)method_getImplementation(m);
                method_setImplementation(m, (IMP)M1ViewDidAppear);
                M1Log("[M1] HOOK ok UIViewController -viewDidAppear: owner=%s", class_getName(owner));
            } else {
                M1Log("[M1] HOOK miss UIViewController -viewDidAppear:");
            }
        }
    } @catch (NSException *e) {
        M1Log("[M1] HOOK exception %s", e.reason.UTF8String);
    }
}

// ============================================================================
#pragma mark - 首帧与前后台时间线
// ============================================================================

static void M1NoteAppActive(void) { M1Log("[M1] EVENT didBecomeActive t=%.3f", M1T()); }
static void M1NoteWinKey(void)    { M1Log("[M1] EVENT windowBecomeKey t=%.3f", M1T()); }
static void M1NoteWinVisible(void){ M1Log("[M1] EVENT windowBecomeVisible t=%.3f", M1T()); }
static void M1NoteBackground(void) {
    M1Log("[M1] EVENT didEnterBackground t=%.3f", M1T());
    M1DumpRingTo(gM1CrashFd, "BACKGROUND");
}

static void M1InstallAppObservers(void) {
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { M1NoteAppActive(); }];
        [nc addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { M1NoteWinKey(); }];
        [nc addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { M1NoteWinVisible(); }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { M1NoteBackground(); }];
        M1Log("[M1] HOOK ok NSNotification observers x4");
    } @catch (NSException *e) {
        M1Log("[M1] HOOK exception observers %s", e.reason.UTF8String);
    }
}

// ============================================================================
#pragma mark - 开关：purify_splash_mode 归零（唯一会写的 key）
// ============================================================================

static void M1PinSplashModeOff(void) {
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        id cur = [d objectForKey:@"purify_splash_mode"];
        if (cur == nil) {
            [d setInteger:0 forKey:@"purify_splash_mode"];
            [d synchronize];
            M1Log("[M1] DEFAULTS purify_splash_mode → 0 (首次写入，净化引擎保持全关)");
        } else {
            M1Log("[M1] DEFAULTS purify_splash_mode=%ld (已存在，不改)", (long)[d integerForKey:@"purify_splash_mode"]);
        }
        [d setObject:@"M1-TRACE-v1" forKey:@"rea_m1_build"];
        BOOL off = [d boolForKey:@"rea_m1_off"];
        gM1On = off ? 0 : 1;
        M1Log("[M1] DEFAULTS rea_m1_off=%d → 观测%s", off ? 1 : 0, off ? "关闭" : "开启");
        [d synchronize];
    } @catch (NSException *e) { }
}

// ============================================================================
#pragma mark - 局域网日志上传（非越狱环境唯一稳定的实时通道）
// ============================================================================
// 为什么不用 NSURLSession / NSLog over syslog：
//   · 非越狱机器上 Windows 抓 NSLog 需要 idevicesyslog + 开发者镜像，iOS 17+ 经常抓不到；
//     而 App 沙盒里的日志文件在不越狱、宿主 Info.plist 又没开 UIFileSharingEnabled 时
//     无法从 iTunes/爱思助手直接拖出来。
//   · NSURLSession 发明文 http:// 到裸 IP 会被宿主 App 的 ATS（Info.plist 的
//     NSAppTransportSecurity）拒绝，而我们不能改宿主 Info.plist。
//   → 所以走裸 BSD socket（ATS 只管 NSURLSession/NSURLConnection，不管 socket）。
//   · 每次 flush 新建连接、写完即关，不做复用：M-1 只要可靠，不要优雅。
//   · flush 全程在后台队列，失败只计数不阻塞主线程；outbox 上限 600 行。

static NSString       *gM1UpHost    = nil;
static int             gM1UpPort    = 0;
static NSMutableArray *gM1Outbox    = nil;
static NSLock         *gM1OutboxLock = nil;
static volatile int    gM1UpSent    = 0;
static volatile int    gM1UpFails   = 0;
static volatile int    gM1UpDrops   = 0;

static void M1OutboxAppend(const char *line) {
    if (gM1Outbox == nil || gM1UpHost == nil || line == NULL || line[0] == 0) return;
    if (!gM1On) return;
    NSString *s = [NSString stringWithUTF8String:line];
    if (s == nil) return;
    [gM1OutboxLock lock];
    [gM1Outbox addObject:s];
    if ([gM1Outbox count] > 600) {
        [gM1Outbox removeObjectsInRange:NSMakeRange(0, 200)];
        gM1UpDrops = gM1UpDrops + 200;
    }
    [gM1OutboxLock unlock];
}

static void M1UploadFlush(void) {
    if (gM1Outbox == nil || gM1UpHost == nil || gM1UpPort <= 0) return;

    NSMutableString *batch = [NSMutableString string];
    [gM1OutboxLock lock];
    for (NSString *l in gM1Outbox) { [batch appendString:l]; [batch appendString:@"\n"]; }
    [gM1Outbox removeAllObjects];
    [gM1OutboxLock unlock];

    if (batch.length == 0) return;

    NSString *host = gM1UpHost;
    int port = gM1UpPort;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            const char *hostC = host.UTF8String;
            if (hostC == NULL) { gM1UpFails = gM1UpFails + 1; return; }

            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { gM1UpFails = gM1UpFails + 1; return; }

            struct timeval tv;
            tv.tv_sec = 2; tv.tv_usec = 0;
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port   = htons((uint16_t)port);

            BOOL connected = NO;
            if (inet_pton(AF_INET, hostC, &addr.sin_addr) == 1) {
                connected = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
            } else {
                // 允许写主机名（mDNS 名也行）
                struct addrinfo hints, *res = NULL;
                memset(&hints, 0, sizeof(hints));
                hints.ai_family = AF_INET;
                hints.ai_socktype = SOCK_STREAM;
                if (getaddrinfo(hostC, NULL, &hints, &res) == 0 && res != NULL) {
                    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
                    addr.sin_addr = sin->sin_addr;
                    connected = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
                    freeaddrinfo(res);
                }
            }

            if (!connected) { close(fd); gM1UpFails = gM1UpFails + 1; return; }

            const char *p = batch.UTF8String;
            size_t left = (p == NULL) ? 0 : strlen(p);
            BOOL okwrite = YES;
            while (left > 0) {
                ssize_t n = write(fd, p, left);
                if (n <= 0) { okwrite = NO; break; }
                p += n; left -= (size_t)n;
            }
            close(fd);
            if (okwrite) gM1UpSent = gM1UpSent + 1;
            else         gM1UpFails = gM1UpFails + 1;
        }
    });
}

static void M1UploadStartTimer(void) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (timer == NULL) return;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                              (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        M1UploadFlush();
        static int tick = 0;
        tick = tick + 1;
        if (tick % 15 == 0) {
            M1Log("[M1] UPLOAD stats sent=%d fails=%d drops=%d pending=%lu",
                  gM1UpSent, gM1UpFails, gM1UpDrops, (unsigned long)[gM1Outbox count]);
        }
    });
    dispatch_resume(timer);
}

// 零配置发现：向局域网广播 M1-DISCOVER，电脑端脚本回 "M1-HERE <port>"，
// 于是用户在手机上什么都不用设，跑起脚本就能收日志。
static void M1UploadDiscover(void) {
    @autoreleasepool {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) { M1Log("[M1] UPLOAD discover socket fail"); return; }

        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
        struct timeval tv;
        tv.tv_sec = 1; tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        struct sockaddr_in dst;
        memset(&dst, 0, sizeof(dst));
        dst.sin_family      = AF_INET;
        dst.sin_port        = htons(M1_DISCOVER_PORT);
        dst.sin_addr.s_addr = htonl(INADDR_BROADCAST);

        NSString *found = nil;
        int foundPort = 0;
        for (int attempt = 0; attempt < 3 && found == nil; attempt++) {
            const char *msg = "M1-DISCOVER";
            sendto(fd, msg, strlen(msg), 0, (struct sockaddr *)&dst, sizeof(dst));

            char buf[128];
            memset(buf, 0, sizeof(buf));
            struct sockaddr_in from;
            socklen_t flen = sizeof(from);
            ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &flen);
            if (n > 0) {
                buf[n] = 0;
                char ip[64];
                memset(ip, 0, sizeof(ip));
                if (inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip)) != NULL) {
                    int p = 0;
                    if (sscanf(buf, "M1-HERE %d", &p) == 1 && p > 0) foundPort = p;
                    found = [NSString stringWithUTF8String:ip];
                    M1Log("[M1] UPLOAD discover hit from=%s port=%d payload=%s", ip, foundPort, buf);
                }
            }
        }
        close(fd);

        if (found == nil) {
            M1Log("[M1] UPLOAD discover fail —— 三种可能："
                  "① 电脑端 tools/m1log_server.py 没在跑 "
                  "② 手机和电脑不在同一 Wi-Fi "
                  "③ iOS 本地网络权限被拒（设置→隐私与安全性→本地网络，把本 App 打开）");
            return;
        }
        gM1UpHost = found;
        gM1UpPort = (foundPort > 0) ? foundPort : M1_LOG_PORT;
        gM1Outbox = [NSMutableArray array];
        gM1OutboxLock = [NSLock new];
        M1Log("[M1] UPLOAD on(discovered) target=%s:%d", gM1UpHost.UTF8String, gM1UpPort);
        M1UploadStartTimer();
    }
}

static void M1InstallUploader(void) {
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *target = [d stringForKey:@"rea_m1_upload"];   // 形如 "192.168.1.7:8765"
        if (target.length == 0) {
            // 零配置路线：UDP 广播找电脑端的 tools/m1log_server.py
            M1Log("[M1] UPLOAD 未设置 rea_m1_upload，改走 UDP 广播自动发现（8766）");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                M1UploadDiscover();
            });
            return;
        }
        NSArray *parts = [target componentsSeparatedByString:@":"];
        if (parts.count < 2) { M1Log("[M1] UPLOAD off（rea_m1_upload 格式应为 host:port，实际=%s）", target.UTF8String); return; }
        gM1UpHost = [parts objectAtIndex:0];
        gM1UpPort = [[parts objectAtIndex:1] intValue];
        if (gM1UpHost.length == 0 || gM1UpPort <= 0) {
            gM1UpHost = nil; gM1UpPort = 0;
            M1Log("[M1] UPLOAD off（host/port 解析失败：%s）", target.UTF8String);
            return;
        }
        gM1Outbox = [NSMutableArray array];
        gM1OutboxLock = [NSLock new];
        M1Log("[M1] UPLOAD on target=%s:%d（每 2s 批量推送，失败只计数）", gM1UpHost.UTF8String, gM1UpPort);
        M1UploadStartTimer();
    } @catch (NSException *e) {
        M1Log("[M1] UPLOAD install exception %s", e.reason.UTF8String);
    }
}

// ============================================================================
#pragma mark - 入口
// ============================================================================

__attribute__((constructor))
static void M1Ctor(void) {
    // v5 铁律：ctor 只许 NSLog + 调度
    gM1T0 = M1Abs();
    NSLog(@"%@ [M1] ctor entry (main=%d)", M1_TAG, (int)[NSThread isMainThread]);

    // +0.05s：开文件、装崩溃钩子（此时不做任何宿主类探测）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        M1OpenSink();
        M1ReadMachine();
        M1InstallCrashHooks();
        M1PinSplashModeOff();
        M1Log("[M1] phase=early t=%.3f", M1T());
        M1InstallRunLoopObserver();
        M1InstallHeartbeat();
        M1InstallScreenSampler();
    });

    // +0.30s：装两个视图旁路（换成 void 返回的方法，安全）+ 打出锚点清点
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        M1Log("[M1] phase=install t=%.3f", M1T());
        M1InstallViewHooks();
        M1InstallAppObservers();
        M1InstallUploader();
    });

    // +0.80s：环境横幅（要读 UIDevice / 文件系统，晚一点更稳）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        M1BootBanner();
    });

    // +3.0s：锚点清点（一次性，最贵的一步）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        double t0 = M1T();
        M1Inventory();
        M1Log("[M1] ANCHOR done cost=%.0fms t=%.3f", (M1T() - t0) * 1000.0, M1T());
    });
}
