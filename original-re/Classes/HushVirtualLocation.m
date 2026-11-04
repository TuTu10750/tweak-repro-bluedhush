//
//  HushVirtualLocation.m
//  BluedHushRE
//
//  Implements the interception side of virtual location; see the header for the
//  original's log evidence.  Design notes:
//
//  * The original wraps the delegate the host installs, not CLLocationManager
//    itself.  Hooking the system class would leak into every framework process
//    and also miss providers that hand us their own fix (Baidu/KS ad SDKs).
//    We hook the classes that actually own `locationManager:didUpdateLocations:`
//    (seven of them, plus startUpdatingLocation and CLLocationManager setDelegate).
//    The original log prints `didUpdateLocations` as shorthand; the real selector
//    has the manager prefix — the main binary has zero owners of the shorthand.
//
//  * Every wrapper is a table entry so one body can serve all six: the body
//    looks the receiver's class up in the install table to find its own `prev`.
//    That keeps a superclass call from picking the wrong original.
//
//  * Passthrough unless the switch is on AND both coordinates parse.  A malformed
//    `runtime_custom_lat` must never silently move the user to 0,0.
//

#import "HushVirtualLocation.h"
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushRuntime.h"

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#pragma mark - configured point

static BOOL  sHasPoint = NO;
static double sLat = 0.0;
static double sLng = 0.0;
static BOOL  sPointRead = NO;

// 出厂默认点：上海人民广场一带（GCJ-02）。用户真实位置在深圳，所以只要这里是
// 生效的，界面上的位置一定肉眼可见地跳过去；如果面板里填过 runtime_custom_lat/lng
// 就用填的，填的和默认一样时也照常打日志说明来源。
static const double HUSH_VLOC_DEFAULT_LAT = 31.2666;
static const double HUSH_VLOC_DEFAULT_LNG = 121.5019;

static BOOL HushVLocParseCoord(NSString *s, double *out) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return NO;
    NSScanner *sc = [NSScanner scannerWithString:t];
    double v = 0.0;
    if (![sc scanDouble:&v]) return NO;
    if (!sc.isAtEnd) return NO;
    *out = v;
    return YES;
}

// ---- 坐标系 ---------------------------------------------------------------
// 国内地图（高德 / 腾讯 / 百度展示）给出来的是 GCJ-02；iOS 的 CLLocation 与
// CoreLocation 回调吃的是 WGS-84。两者在深圳差约 500 m、在上海差约 400 m。
// 面板里那个小数点是从地图上抄来的，所以按 GCJ-02 解释，投递前换成 WGS-84，
// 否则会出现「明明写了上海、地图上的点却偏到隔壁街区」的错觉。
// 算法是公开的 WGS84↔GCJ02 偏移公式（国内通用实现），只用加减。
static const double HUSH_GCJ_A  = 6378245.0;
static const double HUSH_GCJ_EE = 0.00669342162296594323;
static const double HUSH_GCJ_PI = 3.14159265358979323846;

static double HushGcjTransformLat(double x, double y) {
    double r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y
             + 0.2 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * HUSH_GCJ_PI) + 20.0 * sin(2.0 * x * HUSH_GCJ_PI)) * 2.0 / 3.0;
    r += (20.0 * sin(y * HUSH_GCJ_PI) + 40.0 * sin(y / 3.0 * HUSH_GCJ_PI)) * 2.0 / 3.0;
    r += (160.0 * sin(y / 12.0 * HUSH_GCJ_PI) + 320.0 * sin(y * HUSH_GCJ_PI / 30.0)) * 2.0 / 3.0;
    return r;
}

static double HushGcjTransformLng(double x, double y) {
    double r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y
             + 0.1 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * HUSH_GCJ_PI) + 20.0 * sin(2.0 * x * HUSH_GCJ_PI)) * 2.0 / 3.0;
    r += (20.0 * sin(x * HUSH_GCJ_PI) + 40.0 * sin(x / 3.0 * HUSH_GCJ_PI)) * 2.0 / 3.0;
    r += (150.0 * sin(x / 12.0 * HUSH_GCJ_PI) + 300.0 * sin(x / 30.0 * HUSH_GCJ_PI)) * 2.0 / 3.0;
    return r;
}

static void HushGcjToWgs(double glat, double glng, double *wlat, double *wlng) {
    double dLat = HushGcjTransformLat(glng - 105.0, glat - 35.0);
    double dLng = HushGcjTransformLng(glng - 105.0, glat - 35.0);
    double radLat = glat / 180.0 * HUSH_GCJ_PI;
    double magic = sin(radLat);
    magic = 1 - HUSH_GCJ_EE * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((HUSH_GCJ_A * (1 - HUSH_GCJ_EE)) / (magic * sqrtMagic) * HUSH_GCJ_PI);
    dLng = (dLng * 180.0) / (HUSH_GCJ_A / sqrtMagic * cos(radLat) * HUSH_GCJ_PI);
    if (wlat) *wlat = glat - dLat;
    if (wlng) *wlng = glng - dLng;
}

static void HushVLocReloadPoint(void) {
    sPointRead = YES;
    HushConfig *cfg = [HushConfig shared];
    double lat = 0.0, lng = 0.0;
    BOOL okLat = HushVLocParseCoord([cfg stringForKey:@"runtime_custom_lat"], &lat);
    BOOL okLng = HushVLocParseCoord([cfg stringForKey:@"runtime_custom_lng"], &lng);

    // 面板没填 → 用出厂默认（上海）。v31 之前这里直接判「没有点」，于是开关打开
    // 也不生效，日志只剩一句「已开启，但 0 个入口挂载」，看起来像 hook 没挂上。
    NSString *src = @"面板配置";
    // 插件不改用户的配置（测试环境选点重合是环境问题，不是插件的 bug），
    // 只在日志里提醒一句：这个点跟深圳测试点重合，肉眼可能看不出变化。
    if (okLat && okLng
        && fabs(lat - 22.547917) < 1e-3 && fabs(lng - 114.124485) < 1e-3) {
        [HushLogger logLevel:2 format:[NSString stringWithFormat:
            @"[Hush][VLoc] ⚠️ 当前虚拟坐标 %.6f,%.6f 与默认测试点（深圳）重合，可能无法直观看出效果，建议在面板中改为北京/上海等异地坐标",
            lat, lng]];
    }
    if (!okLat || !okLng) {
        lat = HUSH_VLOC_DEFAULT_LAT;
        lng = HUSH_VLOC_DEFAULT_LNG;
        src = @"出厂默认（上海人民广场）";
    }
    if (fabs(lat) > 90.0 || fabs(lng) > 180.0) {
        [HushLogger logLevel:2 format:[NSString stringWithFormat:
            @"[Hush][VLoc] 坐标越界（%.6f,%.6f），拒绝使用 → 回到宿主真实坐标", lat, lng]];
        sHasPoint = NO;
        sLat = sLng = 0.0;
        return;
    }

    BOOL changed = (!sHasPoint) || (fabs(lat - sLat) > 1e-9) || (fabs(lng - sLng) > 1e-9);
    sHasPoint = YES;
    sLat = lat;
    sLng = lng;
    if (changed) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][VLoc] 虚拟点=%.6f,%.6f 来源=%@（switch_virtual_location=%d）",
            lat, lng, src, [cfg isEnabled:@"switch_virtual_location"] ? 1 : 0]];
    }
}

BOOL HushVirtualLocationHasPoint(void) {
    if (!sPointRead) HushVLocReloadPoint();
    return sHasPoint;
}

BOOL HushVirtualLocationPoint(double *lat, double *lng) {
    if (!sPointRead) HushVLocReloadPoint();
    if (!sHasPoint) return NO;
    if (lat) *lat = sLat;
    if (lng) *lng = sLng;
    return YES;
}

#pragma mark - install table

// Three families, one body each.  The slot carries its selector so a receiver
// whose class appears twice (BDMessageViewController style subclasses) still
// resolves the original that belongs to that selector.
#define HUSH_VLOC_MAX 16

// 9 delegate owners + 4 startUpdatingLocation owners + CLLocationManager setDelegate
#define HUSH_VLOC_EXPECTED 14

enum {
    HushVLocKindDidUpdate = 0,   // locationManager:didUpdateLocations:
    HushVLocKindStart,           // startUpdatingLocation
    HushVLocKindSetDelegate,     // CLLocationManager -setDelegate:
};

typedef struct {
    __unsafe_unretained Class cls;
    __unsafe_unretained NSString *name;
    SEL sel;
    int kind;
    IMP prev;
} hush_vloc_slot;

static hush_vloc_slot sSlots[HUSH_VLOC_MAX];
static int sSlotCount = 0;

static IMP HushVLocPrevFor(id self, SEL sel) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < sSlotCount; i++) {
            if (sSlots[i].cls == k && sSlots[i].sel == sel) return sSlots[i].prev;
        }
    }
    return NULL;
}

static BOOL HushVLocAlreadyHooked(Class c, SEL sel) {
    for (int i = 0; i < sSlotCount; i++) {
        if (sSlots[i].cls == c && sSlots[i].sel == sel) return YES;
    }
    return NO;
}

// Same three-way resolution HushHooks.m uses: ObjC name, then the Swift-mangled
// "Blued.<Name>" the runtime registers for @objc Swift classes.
static Class HushVLocResolveClass(NSString *name) {
    Class c = objc_getClass(name.UTF8String);
    if (c) return c;
    c = NSClassFromString(name);
    if (c) return c;
    if ([name rangeOfString:@"."].location == NSNotFound) {
        c = NSClassFromString([@"Blued." stringByAppendingString:name]);
        if (c) return c;
    } else {
        NSString *tail = [name componentsSeparatedByString:@"."].lastObject;
        c = objc_getClass(tail.UTF8String);
        if (c) return c;
        c = NSClassFromString(tail);
        if (c) return c;
    }
    return Nil;
}

// The receiver's class already owns this selector, so method_setImplementation
// gives us the real old IMP.  Anything else is "not present here" — and a
// delegate protocol method is never worth a synthetic class_addMethod: the host
// would never call it, so the hook would look installed while doing nothing
// (v28 shipped exactly that bug on six classes).
static IMP HushVLocHookOwn(Class c, SEL sel, IMP repl, int kind, NSString *name) {
    if (HushVLocAlreadyHooked(c, sel)) return (IMP)1;   // already ours, count it

    unsigned int cnt = 0;
    Method own = NULL;
    Method *list = class_copyMethodList(c, &cnt);
    if (list) {
        for (unsigned int i = 0; i < cnt; i++) {
            if (method_getName(list[i]) == sel) { own = list[i]; break; }
        }
        free(list);
    }
    if (!own || sSlotCount >= HUSH_VLOC_MAX) return NULL;

    IMP prev = method_setImplementation(own, repl);
    if (!prev || prev == repl) return NULL;

    sSlots[sSlotCount].cls = c;
    sSlots[sSlotCount].name = name;
    sSlots[sSlotCount].sel = sel;
    sSlots[sSlotCount].kind = kind;
    sSlots[sSlotCount].prev = prev;
    sSlotCount++;
    return prev;
}

#pragma mark - the hook bodies

static CLLocation *HushVLocFakeLocation(void) {
    // 面板坐标按 GCJ-02 解释，交出去的一律 WGS-84。
    double wlat = sLat, wlng = sLng;
    HushGcjToWgs(sLat, sLng, &wlat, &wlng);
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(wlat, wlng)
                                         altitude:0.0
                               horizontalAccuracy:10.0
                                 verticalAccuracy:10.0
                                        timestamp:[NSDate date]];
}

static BOOL HushVLocActive(void) {
    return [[HushConfig shared] isEnabled:@"switch_virtual_location"]
        && HushVirtualLocationHasPoint();
}

// reference log: [VLocCL] 主动投递假位置（startUpdatingLocation）
// v31 崩溃就崩在这条主动投递上，所以先判「这个 manager 到底是不是一个真的
// 位置提供者」，再决定要不要把假回调塞进它的 delegate。
//
// 取证：21:49:09 那次崩溃，日志停在 21:49:03 的 hit t12，会话里一行收尾都没打
// —— 不是在清缓存那段崩的。崩溃栈是三帧 BluedHushRE + 宿主 delegate 处理函数，
// exceptionReason = -[<host object> location]: unrecognized selector。
// 对得上的唯一路径：宿主在主队列刷新身边页 → 调 startUpdatingLocation（被我们
// hook）→ 我们主动投递 didUpdateLocations，manager 参数传的是 self；而 self 可能
// 是 IphoneGPSMan / BMKGeoFenceManager 这类「会 start 但没有 location 属性」的类，
// 宿主 delegate 收到回调后按 CLLocationManager 去取 manager.location → 崩。
static BOOL HushVLocManagerLooksUsable(id manager) {
    if (!manager) return NO;
    if (![manager respondsToSelector:@selector(location)]) return NO;
    if (![manager respondsToSelector:@selector(delegate)]) return NO;
    return YES;
}

static void HushVLocDeliverTo(id target, id manager) {
    if (!target) return;
    if (!HushVLocManagerLooksUsable(manager)) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            [HushLogger logLevel:2 format:[NSString stringWithFormat:
                @"[Hush][VLocCL] 跳过主动投递：%@ 不是标准位置提供者（无 location/delegate）→ 只走被动替换",
                NSStringFromClass([manager class])]];
        }
        return;
    }
    SEL s = sel_registerName("locationManager:didUpdateLocations:");
    if (![target respondsToSelector:s]) return;
    CLLocation *fake = HushVLocFakeLocation();
    // 投递本身必须留痕：v31 之前「没生效」时我们连有没有投递过都不知道，
    // 只能猜 hook 没挂上。现在每一次主动投递都写一行，日志能直接分辨
    // 「没投递」和「投递了但宿主不认」。
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][VLocCL] 主动投递假位置 → %@ %.6f,%.6f",
        NSStringFromClass([target class]), sLat, sLng]];
    @try {
        [(id)target performSelector:s withObject:manager withObject:@[fake]];
    } @catch (__unused NSException *e) {
        [HushLogger logLevel:2 format:[NSString stringWithFormat:
            @"[Hush][VLocCL] 投递异常（%@），本入口跳过", NSStringFromClass([target class])]];
    }
}

// body 1: the delegate callback the host actually implements
static void hush_vloc_didUpdate(id self, SEL _cmd, id manager, NSArray *locations) {
    IMP prev = HushVLocPrevFor(self, _cmd);
    if (!prev || prev == (IMP)1) return;
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))prev;

    if (!HushVLocActive()) { orig(self, _cmd, manager, locations); return; }

    HushHit(NSStringFromClass(object_getClass(self)).UTF8String,
            "locationManager:didUpdateLocations:");

    // Keep the callback shape: some callers index [0] unconditionally and would
    // crash on an empty array.
    NSUInteger n = locations.count ? locations.count : 1;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [out addObject:HushVLocFakeLocation()];
    static unsigned long sReplaced = 0;
    if (sReplaced++ == 0 || sReplaced % 20 == 0) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][VLocCL] 替换系统回调坐标 %lu 次 → %.6f,%.6f（来自 %@）",
            sReplaced, sLat, sLng, NSStringFromClass(object_getClass(self))]];
    }
    orig(self, _cmd, manager, out);
}

// body 2: the provider starts its own updates — answer the question right away
// instead of waiting for the first real fix to come back and be replaced.
static void hush_vloc_start(id self, SEL _cmd) {
    IMP prev = HushVLocPrevFor(self, _cmd);
    if (!prev || prev == (IMP)1) return;
    void (*orig)(id, SEL) = (void (*)(id, SEL))prev;
    orig(self, _cmd);
    if (!HushVLocActive()) return;
    HushHit(NSStringFromClass(object_getClass(self)).UTF8String, "startUpdatingLocation");
    // 用 respondsToSelector + 直接 IMP 取 delegate，绝不走 KVC：
    // KVC 在「宿主没实现该键」的对象上会继续摸 _delegate ivar，路径不可控。
    if (![self respondsToSelector:@selector(delegate)]) return;
    id (*getDel)(id, SEL) = (id (*)(id, SEL))[self methodForSelector:@selector(delegate)];
    HushVLocDeliverTo(getDel(self, @selector(delegate)), self);
}

// body 3: the app attaches its delegate after we already know the point.
static void hush_vloc_setDelegate(id self, SEL _cmd, id delegate) {
    IMP prev = HushVLocPrevFor(self, _cmd);
    if (!prev || prev == (IMP)1) return;
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))prev;
    orig(self, _cmd, delegate);
    if (!HushVLocActive()) return;
    HushHit("CLLocationManager", "setDelegate:");
    HushVLocDeliverTo(delegate, self);
}

static int HushVLocCountKind(int kind) {
    int n = 0;
    for (int i = 0; i < sSlotCount; i++) if (sSlots[i].kind == kind) n++;
    return n;
}

#pragma mark - public entry

// Reference log owners, all v32@0:8@16@24.  The colon-less `didUpdateLocations`
// in the original's log line is its own print shorthand — the real selector here
// is the delegate one, and the main binary has zero owners of the shorthand.
static NSArray<NSString *> *HushVLocDelegateClasses(void) {
    return @[
        @"SmGpsDelegate",
        @"BMKLocationManager",
        @"BaiduMobAdLocationManager",
        @"BUSDKLocation",
        @"KSAdLocationManager",
        @"GTCGbdLService",
        @"BDLocationService",
        @"BDAppleMapViewController",
        @"BMKGeoFenceManager",
    ];
}

static NSArray<NSString *> *HushVLocStartClasses(void) {
    return @[@"BMKLocationManager", @"BMKGeoFenceManager",
             @"BaiduMobAdLocationManager", @"IphoneGPSMan"];
}

// Idempotent by design: every call only fills the gaps, so the retry loop can
// run once a second without re-wrapping what is already ours (v28's
// `static BOOL installed` turned attempt 2..40 into no-ops).
int HushVirtualLocationInstall(void) {
    HushVLocReloadPoint();

    SEL didUpdate = sel_registerName("locationManager:didUpdateLocations:");
    SEL start = sel_registerName("startUpdatingLocation");
    SEL setDelegate = sel_registerName("setDelegate:");

    NSMutableArray *missing = [NSMutableArray array];

    for (NSString *name in HushVLocDelegateClasses()) {
        Class c = HushVLocResolveClass(name);
        if (!c) { [missing addObject:[name stringByAppendingString:@"(无此类)"]]; continue; }
        if (!class_getInstanceMethod(c, didUpdate)) {
            // Never synthesize a delegate method: nobody would call it.
            [missing addObject:[name stringByAppendingString:@"(无此方法)"]]; continue;
        }
        HushVLocHookOwn(c, didUpdate, (IMP)&hush_vloc_didUpdate,
                        HushVLocKindDidUpdate, name);
    }

    for (NSString *name in HushVLocStartClasses()) {
        Class c = HushVLocResolveClass(name);
        if (!c) continue;
        if (!class_getInstanceMethod(c, start)) continue;
        HushVLocHookOwn(c, start, (IMP)&hush_vloc_start, HushVLocKindStart, name);
    }

    Class clm = objc_getClass("CLLocationManager");
    if (clm && class_getInstanceMethod(clm, setDelegate)) {
        HushVLocHookOwn(clm, setDelegate, (IMP)&hush_vloc_setDelegate,
                        HushVLocKindSetDelegate, @"CLLocationManager");
    }

    // Speak only when the number changes: the retry loop calls this every second.
    static int sLastLogged = -1;
    if (sSlotCount != sLastLogged) {
        sLastLogged = sSlotCount;
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][VLocCL] 已包装 %d 个入口（delegate %d / start %d / setDelegate %d）%@",
            sSlotCount,
            HushVLocCountKind(HushVLocKindDidUpdate),
            HushVLocCountKind(HushVLocKindStart),
            HushVLocCountKind(HushVLocKindSetDelegate),
            missing.count ? [NSString stringWithFormat:@"（缺：%@）",
                             [missing componentsJoinedByString:@","]] : @""]];
    }
    return sSlotCount;
}


#pragma mark - teardown (the [VLoc] ①②②b block)

// Host keys the reference log clears on the "生效 → 失效" transition:
//   [VLoc] ① 已清宿主持久化缓存：latitude, longitude, cityInfo_keys, user_city, LastCityName
static NSArray<NSString *> *HushVLocPersistedKeys(void) {
    return @[@"latitude", @"longitude", @"cityInfo_keys", @"user_city", @"LastCityName"];
}

// v31 崩溃的直接原因就在这一块，所以整段删掉，不留「best effort」。
//
// 崩溃取证（Blued-2026-11-04-214911.ips）：
//   exceptionReason = -[<host object> location]: unrecognized selector sent to instance 0x153e5d260
//   lastExceptionBacktrace 里连续三个 BluedHushRE 帧，最内层就是本函数所在的
//   「取 selectors 数组 → 对每个候选类发 +sharedInstance」这段；外层是主队列上的
//   dispatch block（我们的收尾块）。
//
// 机制：我们对着 1000+ 个名字含 Location/Locate 的类挨个发 sharedInstance /
// defaultManager / shared / manager，其中某个类原本宿主根本没实例化过；它的
// 初始化路径里会给一个还没准备好的对象发 `location`，于是抛异常。我们不是把
// 类型塞错了，是我们把宿主没走过的路径硬拉起来走了。
//
// 结论：不再碰宿主任何定位单例。关开关时只做两件安全的事 ——
//   ① 删掉宿主自己持久化的坐标键（下次读取自然回真实坐标）
//   ② 重启 GPS（stop + start），让真实定位覆盖内存里的旧值
// 这两步都不需要向未知对象发消息。

void HushVirtualLocationHandleSwitchChange(BOOL on) {
    // A switch change may also be how the point itself gets edited, so drop the
    // parse cache either way.
    sPointRead = NO;

    if (on) {
        HushVLocReloadPoint();
        // 文案必须跟真实挂载数一致。v28 在 0 个入口挂载时照样打「虚拟定位 生效」，
        // 结果用户关开关后宿主弹「已到达新城市」，看起来像生效过 —— 其实是我们在
        // 收尾里清缓存 + 重启 GPS 造成的。0 挂载就直说没接管。
        if (sSlotCount > 0) {
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][VLoc] 已开启且 %d 个入口已挂载 → 虚拟定位生效（lat=%.6f lng=%.6f）",
                sSlotCount, sLat, sLng]];
        } else {
            [HushLogger logLevel:2 format:[NSString stringWithFormat:
                @"[Hush][VLoc] 已开启，但 0 个入口挂载 → 当前不生效（点位=%.6f,%.6f，等 delegate 出现后自动接管）",
                sLat, sLng]];
        }
        return;
    }

    if (!sHasPoint) {
        [HushLogger logLevel:3 format:@"[Hush][VLoc] 开关关闭，但当前没有生效中的虚拟点（无需收尾）"];
        return;
    }

    // v30：没接管过就别收尾。
    // 收尾会删宿主持久化键、把定位单例坐标置空、stop+start GPS —— 这些动作本身
    // 就会让宿主以为「你换了城市」。sSlotCount == 0 表示一个槽都没挂上，等于我们
    // 从头到尾没改过任何坐标，去做收尾纯属破坏。
    if (sSlotCount == 0) {
        [HushLogger logLevel:3 format:
            @"[Hush][VLoc] 开关关闭，但 0 个入口曾挂载（从未接管坐标）→ 跳过收尾，不动宿主缓存与 GPS"];
        sHasPoint = NO;
        sLat = 0.0; sLng = 0.0;
        return;
    }

    // ① persisted cache
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *cleared = [NSMutableArray array];
    for (NSString *k in HushVLocPersistedKeys()) {
        if ([ud objectForKey:k] != nil) {
            [ud removeObjectForKey:k];
            [cleared addObject:k];
        }
    }
    [ud synchronize];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][VLoc] 观测到「虚拟定位 生效 → 失效」，开始清缓存并刷新真实位置"]];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][VLoc] ① 已清宿主持久化缓存：%@",
        cleared.count ? [cleared componentsJoinedByString:@", "] : @"（无命中键）"]];

    // ② 宿主单例内存复位：整段删除（v31 崩溃根因，见本文件上方取证）。
    // ②b 重启 GPS：也不做。
    // 原版要 stop+start 是因为它把假坐标写进了宿主单例的缓存里，不清就锁死。
    // 我们这一版从头到尾没改过宿主对象（只在回调里替换数组），开关一关
    // HushVLocActive() 立刻返回 NO，下一次系统回调就是真实坐标 —— 没有任何
    // 需要重置的东西。再 new 一个 CLLocationManager 去 start 纯属多余动作，
    // 而「向宿主发多余的消息」正是 v31 崩掉的原因，这里一并去掉。
    [HushLogger logLevel:3 format:
        @"[Hush][VLoc] ② 跳过宿主单例复位与 GPS 重置（未改动任何宿主对象，下一条系统回调即为真实坐标）"];

    sHasPoint = NO;
    sLat = sLng = 0.0;
}

#pragma mark - late install

// %ctor runs before the map/ads SDK bundles are loaded, so objc_getClass is empty
// for all six classes at that moment (v27 logged 0/6). The original wrapped them
// 10.1-15.1 s after launch, i.e. it waited for the SDKs too.
static void HushVLocTryInstall(int attempt) {
    int n = HushVirtualLocationInstall();
    if (n >= HUSH_VLOC_EXPECTED) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][VLocCL] 全部 %d 个入口挂载完成（第 %d 次扫描）", n, attempt]];
        return;
    }
    if (attempt >= 40) {
        [HushLogger logLevel:2 format:[NSString stringWithFormat:
            @"[Hush][VLocCL] 重试 %d 次仍只挂上 %d/%d 个 → 放弃本轮（见上一条「缺」清单）",
            attempt, n, HUSH_VLOC_EXPECTED]];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        HushVLocTryInstall(attempt + 1);
    });
}

void HushVirtualLocationInstallWithRetry(void) {
    // 3 s first: enough for the host to finish launching, early enough to matter.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        HushVLocTryInstall(1);
    });
}
