// Passive runtime monitor for the original BluedHush 5.19 dylib.
// The monitor sets all feature switches off, except the floating entry and
// debug logging, then dlopens OriginalHush.dylib and records its activity.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <sys/time.h>

#import "HushKeys.h"

static FILE *gMonitorFile = NULL;
static pthread_mutex_t gMonitorLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *gReadCounts = nil;

static NSString *MTrim(id value, NSUInteger limit) {
    if (!value) return @"nil";
    NSString *text = nil;
    @try {
        text = [value isKindOfClass:[NSString class]]
             ? (NSString *)value : [value description];
    } @catch (__unused NSException *e) {
        text = [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
    }
    if (![text isKindOfClass:[NSString class]]) return @"nil";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    if (text.length > limit) text = [[text substringToIndex:limit] stringByAppendingString:@"…"];
    return text;
}

static void MOpenLog(void) {
    if (gMonitorFile) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    NSString *dir = docs.count ? docs.firstObject : NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"HushMonitor.log"];
    gMonitorFile = fopen(path.fileSystemRepresentation, "a");
    if (!gMonitorFile) return;
    fprintf(gMonitorFile, "\n===== HushMonitor session =====\n");
    fflush(gMonitorFile);
}

static void MLog(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm_value;
    localtime_r(&tv.tv_sec, &tm_value);
    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d:%02d:%02d.%03d",
             tm_value.tm_hour, tm_value.tm_min, tm_value.tm_sec,
             (int)(tv.tv_usec / 1000));

    NSString *line = [NSString stringWithFormat:@"[%@][Monitor] %@", 
                      [NSString stringWithUTF8String:stamp], message];
    const char *utf8 = line.UTF8String ?: "";
    pthread_mutex_lock(&gMonitorLock);
    if (gMonitorFile) {
        fprintf(gMonitorFile, "%s\n", utf8);
        fflush(gMonitorFile);
    }
    fprintf(stderr, "%s\n", utf8);
    fflush(stderr);
    pthread_mutex_unlock(&gMonitorLock);
}

static NSString *MTopViewControllerDescription(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *window = nil;
        for (UIWindow *candidate in app.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (!window) window = app.windows.firstObject;
        UIViewController *top = window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        return top ? NSStringFromClass([top class]) : @"nil";
    } @catch (__unused NSException *e) {
        return @"<top unavailable>";
    }
}

static BOOL MFeatureKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key hasPrefix:@"switch_"] ||
           [key hasPrefix:@"purify_"] ||
           [key isEqualToString:@"qq_home"];
}

static void MForceAllFeaturesOff(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUInteger changed = 0;
    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *entry = &kHushDefaults[i];
        if (!entry->key || !entry->isBool) continue;
        NSString *key = [NSString stringWithUTF8String:entry->key];
        if (!MFeatureKey(key)) continue;
        if ([key isEqualToString:@"switch_debug_log"]) continue;
        [defaults setBool:NO forKey:key];
        changed++;
    }
    // Keep the original panel reachable and its diagnostic log enabled.
    [defaults setBool:YES forKey:@"float_ball"];
    [defaults setBool:YES forKey:@"switch_debug_log"];
    [defaults synchronize];
    MLog(@"BOOT defaults forced off: feature_keys=%lu float_ball=1 debug_log=1",
         (unsigned long)changed);
}

static NSString *MFrameworkPath(NSString *name) {
    NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
    NSString *path = [frameworks stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    NSString *bundlePath =
        [[NSBundle mainBundle] pathForResource:name.stringByDeletingPathExtension
                                        ofType:name.pathExtension
                                   inDirectory:@"Frameworks"];
    return bundlePath;
}

static void MLoadOriginal(void) {
    NSString *substrate =
        MFrameworkPath(@"CydiaSubstrate.framework/CydiaSubstrate");
    if (substrate.length) {
        void *handle = dlopen(substrate.fileSystemRepresentation,
                              RTLD_NOW | RTLD_GLOBAL);
        MLog(@"BOOT substrate path=%@ handle=%p error=%s",
             substrate, handle, handle ? "none" : (dlerror() ?: "unknown"));
    } else {
        MLog(@"BOOT substrate not found in Frameworks");
    }

    NSString *original = MFrameworkPath(@"OriginalHush.dylib");
    if (!original.length) {
        MLog(@"BOOT OriginalHush.dylib missing");
        return;
    }
    void *handle = dlopen(original.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    MLog(@"BOOT original path=%@ handle=%p error=%s",
         original, handle, handle ? "none" : (dlerror() ?: "unknown"));
}

static Method MFindOwnMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; methods && i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

static Method MFindMethod(Class cls, SEL selector) {
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        Method found = MFindOwnMethod(cursor, selector);
        if (found) return found;
    }
    return NULL;
}

static BOOL MInstallMethod(Class cls, SEL selector, IMP replacement,
                           IMP *original) {
    if (!cls || !selector || !replacement) return NO;
    Method own = MFindOwnMethod(cls, selector);
    if (!own) {
        Method inherited = MFindMethod(class_getSuperclass(cls), selector);
        if (!inherited) return NO;
        const char *types = method_getTypeEncoding(inherited);
        IMP inheritedIMP = method_getImplementation(inherited);
        if (original) *original = inheritedIMP;
        return class_addMethod(cls, selector, replacement, types);
    }
    IMP previous = method_getImplementation(own);
    if (previous == replacement) return YES;
    method_setImplementation(own, replacement);
    if (original) *original = previous;
    return YES;
}

static BOOL MInstallHook(const char *className, SEL selector, IMP replacement,
                         IMP *original) {
    Class cls = objc_getClass(className);
    return MInstallMethod(cls, selector, replacement, original);
}

static void MInstallClassHook(const char *className, SEL selector, IMP replacement,
                              IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls || !selector || !replacement) return;
    Class meta = object_getClass((id)cls);
    MInstallMethod(meta, selector, replacement, original);
}

// ---------------------------------------------------------------- HushConfig
static BOOL (*o_cfgEnabled)(id, SEL, id);
static BOOL r_cfgEnabled(id self, SEL _cmd, id key) {
    BOOL value = o_cfgEnabled ? o_cfgEnabled(self, _cmd, key) : NO;
    NSString *name = [key isKindOfClass:[NSString class]] ? key : MTrim(key, 80);
    NSInteger count = 0;
    @synchronized (gReadCounts) {
        count = [gReadCounts[name] integerValue] + 1;
        gReadCounts[name] = @(count);
    }
    if (value || count <= 20 || count % 50 == 0) {
        MLog(@"CONFIG_READ key=%@ value=%d nth=%ld top=%@",
             name, value ? 1 : 0, (long)count, MTopViewControllerDescription());
    }
    return value;
}

static BOOL (*o_cfgEnabledDefault)(id, SEL, id, BOOL);
static BOOL r_cfgEnabledDefault(id self, SEL _cmd, id key, BOOL fallback) {
    BOOL value = o_cfgEnabledDefault
               ? o_cfgEnabledDefault(self, _cmd, key, fallback) : fallback;
    if (value) MLog(@"CONFIG_READ_DEFAULT key=%@ value=1 fallback=%d",
                    MTrim(key, 100), fallback ? 1 : 0);
    return value;
}

static void (*o_cfgSetEnabled)(id, SEL, BOOL, id);
static void r_cfgSetEnabled(id self, SEL _cmd, BOOL value, id key) {
    if (o_cfgSetEnabled) o_cfgSetEnabled(self, _cmd, value, key);
    MLog(@"CONFIG_SET key=%@ value=%d top=%@",
         MTrim(key, 120), value ? 1 : 0, MTopViewControllerDescription());
}

static void (*o_cfgSetString)(id, SEL, id, id);
static void r_cfgSetString(id self, SEL _cmd, id value, id key) {
    if (o_cfgSetString) o_cfgSetString(self, _cmd, value, key);
    MLog(@"CONFIG_SET_STRING key=%@ value=%@",
         MTrim(key, 120), MTrim(value, 240));
}

static void (*o_cfgReset)(id, SEL);
static void r_cfgReset(id self, SEL _cmd) {
    MLog(@"CONFIG_RESET default");
    if (o_cfgReset) o_cfgReset(self, _cmd);
}

// ---------------------------------------------------------------- HushLogger
static void (*o_hushLog)(id, SEL, long long, id);
static void r_hushLog(id self, SEL _cmd, long long level, id message) {
    if (o_hushLog) o_hushLog(self, _cmd, level, message);
    NSString *text = MTrim(message, 2000);
    if ([text rangeOfString:@"[Purify]"].location != NSNotFound ||
        [text rangeOfString:@"[Track]"].location != NSNotFound ||
        [text rangeOfString:@"[Privacy]"].location != NSNotFound ||
        [text rangeOfString:@"[Album]"].location != NSNotFound ||
        [text rangeOfString:@"[Chat]"].location != NSNotFound ||
        [text rangeOfString:@"[Flash]"].location != NSNotFound ||
        [text rangeOfString:@"[License]"].location != NSNotFound ||
        level <= 1) {
        MLog(@"ORIGINAL_LOG level=%lld text=%@", level, text);
    }
}

// ---------------------------------------------------------------- original UI/actions
static void (*o_panelOpenModule)(id, SEL, id);
static void r_panelOpenModule(id self, SEL _cmd, id module) {
    MLog(@"ACTION panel_open_module value=%@", MTrim(module, 240));
    if (o_panelOpenModule) o_panelOpenModule(self, _cmd, module);
}

static void (*o_detailSelect)(id, SEL, id, id);
static void r_detailSelect(id self, SEL _cmd, id table, id indexPath) {
    NSInteger section = -1, row = -1;
    @try {
        section = [(NSIndexPath *)indexPath section];
        row = [(NSIndexPath *)indexPath row];
    } @catch (__unused NSException *e) {}
    MLog(@"ACTION detail_select section=%ld row=%ld top=%@",
         (long)section, (long)row, MTopViewControllerDescription());
    if (o_detailSelect) o_detailSelect(self, _cmd, table, indexPath);
}

static void (*o_switchChanged)(id, SEL);
static void r_switchChanged(id self, SEL _cmd) {
    if (o_switchChanged) o_switchChanged(self, _cmd);
    BOOL on = NO;
    NSString *cellText = @"";
    @try {
        UISwitch *sw = [self valueForKey:@"sw"];
        on = sw.isOn;
        if ([self isKindOfClass:[UITableViewCell class]]) {
            UITableViewCell *cell = (UITableViewCell *)self;
            cellText = cell.textLabel.text ?: @"";
        }
    } @catch (__unused NSException *e) {}
    MLog(@"ACTION switch_changed on=%d text=%@", on ? 1 : 0, MTrim(cellText, 160));
}

static void (*o_ballTap)(id, SEL);
static void r_ballTap(id self, SEL _cmd) {
    MLog(@"ACTION float_ball_tap");
    if (o_ballTap) o_ballTap(self, _cmd);
}

static void (*o_photoHiRes)(id, SEL, long long);
static void r_photoHiRes(id self, SEL _cmd, long long index) {
    MLog(@"ACTION photo_hi_res index=%lld", index);
    if (o_photoHiRes) o_photoHiRes(self, _cmd, index);
}

static void (*o_albumGrant)(id, SEL, id);
static void r_albumGrant(id self, SEL _cmd, id sender) {
    MLog(@"ACTION privacy_album_grant");
    if (o_albumGrant) o_albumGrant(self, _cmd, sender);
}

static void (*o_trackLocate)(id, SEL, id);
static void r_trackLocate(id self, SEL _cmd, id sender) {
    MLog(@"ACTION track_locate_here");
    if (o_trackLocate) o_trackLocate(self, _cmd, sender);
}

static void (*o_trackMap)(id, SEL, id);
static void r_trackMap(id self, SEL _cmd, id sender) {
    MLog(@"ACTION track_open_map");
    if (o_trackMap) o_trackMap(self, _cmd, sender);
}

static void (*o_trackRedo)(id, SEL, id);
static void r_trackRedo(id self, SEL _cmd, id sender) {
    MLog(@"ACTION track_redo");
    if (o_trackRedo) o_trackRedo(self, _cmd, sender);
}

static void (*o_trackAppear)(id, SEL, BOOL);
static void r_trackAppear(id self, SEL _cmd, BOOL animated) {
    MLog(@"ACTION track_card_appear");
    if (o_trackAppear) o_trackAppear(self, _cmd, animated);
}

static void (*o_locConfirm)(id, SEL);
static void r_locConfirm(id self, SEL _cmd) {
    MLog(@"ACTION location_confirm");
    if (o_locConfirm) o_locConfirm(self, _cmd);
}

static void (*o_locSwitch)(id, SEL, id);
static void r_locSwitch(id self, SEL _cmd, id sender) {
    MLog(@"ACTION location_switch sender=%@", MTrim(sender, 120));
    if (o_locSwitch) o_locSwitch(self, _cmd, sender);
}

// ---------------------------------------------------------------- navigation
static void (*o_present)(id, SEL, id, BOOL, id);
static void r_present(id self, SEL _cmd, id target, BOOL animated, id completion) {
    MLog(@"NAV present from=%@ to=%@ animated=%d",
         NSStringFromClass([self class]), NSStringFromClass([target class]),
         animated ? 1 : 0);
    if (o_present) o_present(self, _cmd, target, animated, completion);
}

static void (*o_push)(id, SEL, id, BOOL);
static void r_push(id self, SEL _cmd, id target, BOOL animated) {
    MLog(@"NAV push from=%@ to=%@ animated=%d",
         NSStringFromClass([self class]), NSStringFromClass([target class]),
         animated ? 1 : 0);
    if (o_push) o_push(self, _cmd, target, animated);
}

static void (*o_pop)(id, SEL, BOOL);
static id r_pop(id self, SEL _cmd, BOOL animated) {
    MLog(@"NAV pop from=%@", NSStringFromClass([self class]));
    return o_pop ? o_pop(self, _cmd, animated) : nil;
}

static void (*o_setSelectedIndex)(id, SEL, unsigned long long);
static void r_setSelectedIndex(id self, SEL _cmd, unsigned long long index) {
    MLog(@"NAV tab_select index=%llu", index);
    if (o_setSelectedIndex) o_setSelectedIndex(self, _cmd, index);
}

static void MInstallMonitorHooks(void) {
    Class cfg = objc_getClass("HushConfig");
    if (!cfg) return;

    MInstallHook("HushConfig", @selector(isEnabled:),
                 (IMP)&r_cfgEnabled, (IMP *)&o_cfgEnabled);
    MInstallHook("HushConfig", @selector(isEnabled:default:),
                 (IMP)&r_cfgEnabledDefault, (IMP *)&o_cfgEnabledDefault);
    MInstallHook("HushConfig", @selector(setEnabled:forKey:),
                 (IMP)&r_cfgSetEnabled, (IMP *)&o_cfgSetEnabled);
    MInstallHook("HushConfig", @selector(setString:forKey:),
                 (IMP)&r_cfgSetString, (IMP *)&o_cfgSetString);
    MInstallHook("HushConfig", @selector(resetToDefaults),
                 (IMP)&r_cfgReset, (IMP *)&o_cfgReset);

    MInstallClassHook("HushLogger", @selector(logLevel:format:),
                      (IMP)&r_hushLog, (IMP *)&o_hushLog);
    MInstallHook("HushSettingsPanel", @selector(openModule:),
                 (IMP)&r_panelOpenModule, (IMP *)&o_panelOpenModule);
    MInstallHook("HushModuleDetailController",
                 @selector(tableView:didSelectRowAtIndexPath:),
                 (IMP)&r_detailSelect, (IMP *)&o_detailSelect);
    MInstallHook("HushSwitchCell", @selector(switchChanged),
                 (IMP)&r_switchChanged, (IMP *)&o_switchChanged);
    MInstallHook("HushFloatBall", @selector(onTap),
                 (IMP)&r_ballTap, (IMP *)&o_ballTap);
    MInstallHook("HushaPhotoViewer", @selector(p_loadHiResAt:),
                 (IMP)&r_photoHiRes, (IMP *)&o_photoHiRes);
    MInstallHook("HushPrivacyAlbumGrantTap", @selector(onGiftLongPress:),
                 (IMP)&r_albumGrant, (IMP *)&o_albumGrant);
    MInstallHook("HushTrackMapCardVC", @selector(hushLocateHere:),
                 (IMP)&r_trackLocate, (IMP *)&o_trackLocate);
    MInstallHook("HushTrackMapCardVC", @selector(hushOpenBigMap:),
                 (IMP)&r_trackMap, (IMP *)&o_trackMap);
    MInstallHook("HushTrackMapCardVC", @selector(hushRedo:),
                 (IMP)&r_trackRedo, (IMP *)&o_trackRedo);
    MInstallHook("HushTrackMapCardVC", @selector(viewDidAppear:),
                 (IMP)&r_trackAppear, (IMP *)&o_trackAppear);
    MInstallHook("HushLocationPickerController", @selector(actConfirm),
                 (IMP)&r_locConfirm, (IMP *)&o_locConfirm);
    MInstallHook("HushLocationPickerController", @selector(hushLocSwitchChanged:),
                 (IMP)&r_locSwitch, (IMP *)&o_locSwitch);

    // Pass-through navigation observation. These are not altered.
    MInstallHook("UIViewController",
                 @selector(presentViewController:animated:completion:),
                 (IMP)&r_present, (IMP *)&o_present);
    MInstallHook("UINavigationController", @selector(pushViewController:animated:),
                 (IMP)&r_push, (IMP *)&o_push);
    MInstallHook("UINavigationController", @selector(popViewControllerAnimated:),
                 (IMP)&r_pop, (IMP *)&o_pop);
    MInstallHook("UITabBarController", @selector(setSelectedIndex:),
                 (IMP)&r_setSelectedIndex, (IMP *)&o_setSelectedIndex);

    MLog(@"BOOT hooks installed config=%@ logger=%@ panel=%@ detail=%@ "
         @"photo=%@ track=%@ nav=1",
         objc_getClass("HushConfig") ? @"ok" : @"missing",
         objc_getClass("HushLogger") ? @"ok" : @"missing",
         objc_getClass("HushSettingsPanel") ? @"ok" : @"missing",
         objc_getClass("HushModuleDetailController") ? @"ok" : @"missing",
         objc_getClass("HushaPhotoViewer") ? @"ok" : @"missing",
         objc_getClass("HushTrackMapCardVC") ? @"ok" : @"missing");
}

__attribute__((constructor))
static void HushMonitorStart(void) {
    @autoreleasepool {
        MOpenLog();
        gReadCounts = [NSMutableDictionary dictionary];
        MLog(@"BOOT HushMonitor loaded pid=%d", getpid());
        MForceAllFeaturesOff();
        MLoadOriginal();

        // Loading is synchronous. Keep retries for classes that register late.
        MInstallMonitorHooks();
        static const double delays[] = { 0.20, 0.60, 1.50, 3.00 };
        for (unsigned i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                MInstallMonitorHooks();
            });
        }
    }
}

