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

static void HushVLocReloadPoint(void) {
    sPointRead = YES;
    HushConfig *cfg = [HushConfig shared];
    double lat = 0.0, lng = 0.0;
    BOOL okLat = HushVLocParseCoord([cfg stringForKey:@"runtime_custom_lat"], &lat);
    BOOL okLng = HushVLocParseCoord([cfg stringForKey:@"runtime_custom_lng"], &lng);
    if (!okLat || !okLng) {
        if (sHasPoint) {
            [HushLogger logLevel:3 format:@"[Hush][VLoc] 虚拟点已清空（配置里 lat/lng 不再可解析）→ 回到宿主真实坐标"];
        }
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
            @"[Hush][VLoc] 虚拟点=%.6f,%.6f（switch_virtual_location=%d）",
            lat, lng, [cfg isEnabled:@"switch_virtual_location"] ? 1 : 0]];
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
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(sLat, sLng)
                                         altitude:0.0
                               horizontalAccuracy:5.0
                                 verticalAccuracy:5.0
                                        timestamp:[NSDate date]];
}

static BOOL HushVLocActive(void) {
    return [[HushConfig shared] isEnabled:@"switch_virtual_location"]
        && HushVirtualLocationHasPoint();
}

// reference log: [VLocCL] 主动投递假位置（startUpdatingLocation）
static void HushVLocDeliverTo(id target, id manager) {
    if (!target) return;
    SEL s = sel_registerName("locationManager:didUpdateLocations:");
    if (![target respondsToSelector:s]) return;
    CLLocation *fake = HushVLocFakeLocation();
    [(id)target performSelector:s withObject:manager withObject:@[fake]];
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
    HushVLocDeliverTo([self valueForKey:@"delegate"], self);
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

// Best-effort in-memory reset. The host's location singleton is not named in the
// log, so every candidate is probed and only the ones that actually answer KVC
// are touched; each write is logged so the report can say what was real.
static NSUInteger HushVLocResetMemoryCaches(void) {
    unsigned int total = 0;
    NSUInteger touched = 0;
    Class *classes = objc_copyClassList(&total);
    if (!classes) return 0;

    NSArray<NSString *> *selectors = @[@"sharedInstance", @"defaultManager",
                                       @"sharedManager", @"shared", @"manager"];
    NSArray<NSString *> *coordKeys = @[@"latitude", @"longitude", @"location",
                                       @"currentLocation", @"currentLocationCoordinate"];

    for (unsigned int i = 0; i < total; i++) {
        Class c = classes[i];
        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (![name containsString:@"Location"] && ![name containsString:@"Locate"]) continue;

        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if (!sel || ![c respondsToSelector:sel]) continue;
            id inst = nil;
            @try {
                IMP imp = [c methodForSelector:sel];
                id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
                inst = fn(c, sel);
            } @catch (__unused NSException *e) {
                inst = nil;
            }
            if (!inst) continue;

            BOOL did = NO;
            for (NSString *k in coordKeys) {
                @try {
                    if ([inst valueForKey:k] != nil) {
                        [inst setValue:nil forKey:k];
                        did = YES;
                    }
                } @catch (__unused NSException *e) {
                }
            }
            @try {
                if ([inst valueForKey:@"isChoosedLocation"] != nil) {
                    [inst setValue:@NO forKey:@"isChoosedLocation"];
                    did = YES;
                }
            } @catch (__unused NSException *e) {
            }
            if (did) {
                touched++;
                [HushLogger logLevel:3 format:[NSString stringWithFormat:
                    @"[Hush][VLoc] ② 已复位 %@（%@ 单例坐标缓存置空）", name, selName]];
            }
            break;   // one accessor per class is enough
        }
    }
    free(classes);
    return touched;
}

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

    // ② in-memory cache
    NSUInteger touched = HushVLocResetMemoryCaches();
    if (touched == 0) {
        [HushLogger logLevel:2 format:
            @"[Hush][VLoc] ② 未找到可复位的定位单例（宿主编译期未暴露 shared 入口）→ 真实坐标需下一次 GPS 回调覆盖"];
    }

    // ②b restart the real GPS. CLLocationManager is the only public way to ask
    // for a fresh fix; the original logged "re-start 4 / re-request 4".
    // Done on the main queue: startUpdatingLocation must not race the delegate
    // wrappers installed above.
    dispatch_async(dispatch_get_main_queue(), ^{
        Class clm = objc_getClass("CLLocationManager");
        if (!clm) return;
        SEL sharedSel = NSSelectorFromString(@"new");
        id mgr = nil;
        @try {
            id (*fn)(id, SEL) = (id (*)(id, SEL))[clm methodForSelector:sharedSel];
            mgr = fn(clm, sharedSel);
        } @catch (__unused NSException *e) {
            mgr = nil;
        }
        if (!mgr) return;
        SEL start = NSSelectorFromString(@"startUpdatingLocation");
        SEL stop  = NSSelectorFromString(@"stopUpdatingLocation");
        @try {
            if ([mgr respondsToSelector:stop]) {
                void (*f)(id, SEL) = (void (*)(id, SEL))[mgr methodForSelector:stop];
                f(mgr, stop);
            }
            if ([mgr respondsToSelector:start]) {
                void (*f)(id, SEL) = (void (*)(id, SEL))[mgr methodForSelector:start];
                f(mgr, start);
            }
            [HushLogger logLevel:3 format:@"[Hush][VLoc] ②b 投递口收尾：真 GPS 已重启（stop+start）"];
        } @catch (__unused NSException *e) {
            [HushLogger logLevel:2 format:@"[Hush][VLoc] ②b GPS 重启失败（异常），真实坐标等下一条系统回调"];
        }
    });

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
