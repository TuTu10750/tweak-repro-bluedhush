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
//    We hook the six classes the reference log names, on `didUpdateLocations:`.
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

#define HUSH_VLOC_MAX 8

typedef struct {
    __unsafe_unretained Class cls;
    __unsafe_unretained NSString *name;
    IMP prev;
} hush_vloc_slot;

static hush_vloc_slot sSlots[HUSH_VLOC_MAX];
static int sSlotCount = 0;

static IMP HushVLocPrevFor(id self) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < sSlotCount; i++) {
            if (sSlots[i].cls == k) return sSlots[i].prev;
        }
    }
    return NULL;
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
    }
    return Nil;
}

#pragma mark - the one hook body

static void hush_vloc_didUpdate(id self, SEL _cmd, NSArray *locations) {
    IMP prev = HushVLocPrevFor(self);
    if (!prev) return;
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))prev;

    if (![[HushConfig shared] isEnabled:@"switch_virtual_location"] || !HushVirtualLocationHasPoint()) {
        orig(self, _cmd, locations);
        return;
    }

    HushHit(NSStringFromClass(object_getClass(self)).UTF8String, "didUpdateLocations:");

    CLLocation *fake = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(sLat, sLng)
                                                     altitude:0.0
                                           horizontalAccuracy:5.0
                                             verticalAccuracy:5.0
                                                    timestamp:[NSDate date]];
    // Replace whatever the provider reported, but keep the callback shape: some
    // callers index [0] unconditionally and would crash on an empty array.
    NSUInteger n = locations.count ? locations.count : 1;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [out addObject:fake];

    orig(self, _cmd, out);
}

#pragma mark - public entry

void HushVirtualLocationInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    HushVLocReloadPoint();

    // Straight from the reference log's [VLocCL] 已包装 delegate … lines.
    NSArray<NSString *> *names = @[
        @"SmGpsDelegate",
        @"BMKLocationManager",
        @"BaiduMobAdLocationManager",
        @"BUSDKLocation",
        @"KSAdLocationManager",
        @"GTCGbdLService",
    ];

    SEL sel = @selector(didUpdateLocations:);
    NSMutableArray *hooked = [NSMutableArray array];
    NSMutableArray *missing = [NSMutableArray array];

    for (NSString *name in names) {
        if (sSlotCount >= HUSH_VLOC_MAX) break;
        Class c = HushVLocResolveClass(name);
        if (!c) { [missing addObject:name]; continue; }

        unsigned int cnt = 0;
        Method own = NULL;
        Method *list = class_copyMethodList(c, &cnt);
        if (list) {
            for (unsigned int i = 0; i < cnt; i++) {
                if (method_getName(list[i]) == sel) { own = list[i]; break; }
            }
            free(list);
        }

        IMP prev = NULL;
        const char *types = NULL;
        if (own) {
            // Owns it: only method_setImplementation returns the real old IMP.
            types = method_getTypeEncoding(own);
            prev = method_setImplementation(own, (IMP)&hush_vloc_didUpdate);
        } else {
            Method inh = class_getInstanceMethod(c, sel);
            types = inh ? method_getTypeEncoding(inh) : "v24@0:8@16";
            // Inherited or absent: add an override here and remember the parent
            // IMP as the thing to call. The parent's Method is never touched.
            IMP parent = inh ? method_getImplementation(inh) : NULL;
            if (class_addMethod(c, sel, (IMP)&hush_vloc_didUpdate, types)) {
                prev = parent;
            } else {
                IMP old = class_replaceMethod(c, sel, (IMP)&hush_vloc_didUpdate, types);
                prev = (old && old != (IMP)&hush_vloc_didUpdate) ? old : NULL;
            }
        }
        if (!prev) { [missing addObject:name]; continue; }

        sSlots[sSlotCount].cls = c;
        sSlots[sSlotCount].name = name;
        sSlots[sSlotCount].prev = prev;
        sSlotCount++;
        [hooked addObject:name];
    }

    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][VLocCL] 已包装 delegate %lu/%lu 个：%@%@",
        (unsigned long)hooked.count, (unsigned long)names.count,
        [hooked componentsJoinedByString:@","],
        missing.count ? [NSString stringWithFormat:@"（未找到：%@）", [missing componentsJoinedByString:@","]] : @""]];
}
