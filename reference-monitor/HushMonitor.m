// Passive overlay monitor for the original BluedHush plugin.
//
// This monitor deliberately installs no Objective-C hooks and changes no
// feature switches. It only records:
//   * app lifecycle transitions
//   * top-level page / tab transitions at 5 Hz
//   * feature-switch changes by comparing NSUserDefaults at 2 Hz
//   * whether the original plugin and its detailed log are present
//
// The original plugin remains the source of detailed hook logs in Documents/hooo.
// Keeping this monitor outside every host/plugin call path makes it safe to load
// beside an already-injected BluedHush dylib.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>

#import "HushKeys.h"

static FILE *gLogFile = NULL;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gPageLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *gPageContext = nil;
static NSDictionary *gLastFeatureFlags = nil;
static dispatch_source_t gPageTimer = NULL;
static dispatch_source_t gConfigTimer = NULL;
static dispatch_queue_t gConfigQueue = NULL;
static BOOL gStarted = NO;

static NSString *MSafeDescription(id value, NSUInteger limit) {
    if (!value) return @"nil";
    NSString *text = nil;
    @try {
        text = [value isKindOfClass:[NSString class]]
             ? (NSString *)value : [value description];
    } @catch (__unused NSException *exception) {
        text = [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
    }
    if (![text isKindOfClass:[NSString class]]) return @"nil";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    if (text.length > limit) {
        text = [[text substringToIndex:limit] stringByAppendingString:@"..."];
    }
    return text;
}

static NSString *MCachedPageContext(void) {
    NSString *page = nil;
    pthread_mutex_lock(&gPageLock);
    page = [gPageContext copy];
    pthread_mutex_unlock(&gPageLock);
    return page.length ? page : @"page=boot";
}

static void MLog(NSString *format, ...) {
    if (!format.length) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm localTime;
    localtime_r(&tv.tv_sec, &localTime);
    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d:%02d:%02d.%03d",
             localTime.tm_hour, localTime.tm_min, localTime.tm_sec,
             (int)(tv.tv_usec / 1000));

    NSString *line = [NSString stringWithFormat:@"[%@][SafeMonitor][%@] %@",
                      [NSString stringWithUTF8String:stamp],
                      MCachedPageContext(), message];
    const char *utf8 = line.UTF8String ?: "";

    pthread_mutex_lock(&gLogLock);
    if (gLogFile) {
        fprintf(gLogFile, "%s\n", utf8);
        fflush(gLogFile);
    }
    fprintf(stderr, "%s\n", utf8);
    fflush(stderr);
    pthread_mutex_unlock(&gLogLock);
}

static void MOpenLog(void) {
    if (gLogFile) return;
    NSArray *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                            NSUserDomainMask, YES);
    NSString *directory =
        documents.count ? documents.firstObject : NSTemporaryDirectory();
    NSString *path =
        [directory stringByAppendingPathComponent:@"HushMonitor.log"];
    gLogFile = fopen(path.fileSystemRepresentation, "a");
    if (!gLogFile) return;

    fprintf(gLogFile, "\n===== SafeMonitor session =====\n");
    fprintf(gLogFile, "pid=%d bundle=%s\n",
            getpid(), NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "");
    fflush(gLogFile);
}

static UIViewController *MVisibleController(UIViewController *root) {
    UIViewController *controller = root;
    NSInteger guard = 0;
    while (controller && guard++ < 32) {
        UIViewController *next = controller;
        if ([next isKindOfClass:[UINavigationController class]]) {
            UIViewController *top =
                [(UINavigationController *)next topViewController];
            if (top && top != next) next = top;
        } else if ([next isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected =
                [(UITabBarController *)next selectedViewController];
            if (selected && selected != next) next = selected;
        }
        if (next.presentedViewController) next = next.presentedViewController;
        if (next == controller) break;
        controller = next;
    }
    return controller;
}

static UITabBarController *MFindTabController(UIViewController *controller) {
    UIViewController *cursor = controller;
    NSInteger guard = 0;
    while (cursor && guard++ < 24) {
        if ([cursor isKindOfClass:[UITabBarController class]]) {
            return (UITabBarController *)cursor;
        }
        UIViewController *parent = cursor.parentViewController;
        if (!parent && cursor.presentingViewController) {
            parent = cursor.presentingViewController;
        }
        cursor = parent;
    }
    return nil;
}

static NSString *MPageSummary(void) {
    @try {
        UIApplication *application = [UIApplication sharedApplication];
        UIWindow *window = nil;
        for (UIWindow *candidate in application.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (!window) window = application.windows.firstObject;
        UIViewController *visible = MVisibleController(window.rootViewController);
        if (!visible) return @"page=boot";

        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        UIViewController *cursor = window.rootViewController;
        NSInteger guard = 0;
        while (cursor && guard++ < 12) {
            [chain addObject:NSStringFromClass([cursor class]) ?: @"?"];
            UIViewController *next = cursor.presentedViewController;
            if (!next) break;
            cursor = next;
        }

        NSString *tabPart = @"tab=none";
        UITabBarController *tabs = MFindTabController(visible);
        if (tabs) {
            NSUInteger selected = NSUIntegerMax;
            @try {
                selected = (NSUInteger)tabs.selectedIndex;
            } @catch (__unused NSException *exception) {}
            tabPart = [NSString stringWithFormat:@"tab=%lu/%lu",
                       (unsigned long)selected,
                       (unsigned long)tabs.viewControllers.count];
        }

        return [NSString stringWithFormat:
                @"page=%@ %@ chain=%@",
                NSStringFromClass([visible class]) ?: @"?",
                tabPart,
                [chain componentsJoinedByString:@">"]];
    } @catch (__unused NSException *exception) {
        return @"page=<unavailable>";
    }
}

static BOOL MInterestingFeatureKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key hasPrefix:@"switch_"] ||
           [key hasPrefix:@"purify_"] ||
           [key isEqualToString:@"float_ball"] ||
           [key isEqualToString:@"qq_home"];
}

static NSDictionary *MReadFeatureFlags(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, NSNumber *> *flags =
        [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)kHushDefaultsCount];
    for (int index = 0; index < kHushDefaultsCount; index++) {
        const HushDefaultEntry *entry = &kHushDefaults[index];
        if (!entry->key || !entry->isBool) continue;
        NSString *key = [NSString stringWithUTF8String:entry->key];
        if (!MInterestingFeatureKey(key)) continue;
        id value = [defaults objectForKey:key];
        BOOL enabled = [value respondsToSelector:@selector(boolValue)]
                     ? [value boolValue] : NO;
        flags[key] = @(enabled);
    }
    return flags;
}

static NSString *MFlagList(NSArray<NSString *> *keys) {
    return keys.count ? [keys componentsJoinedByString:@","] : @"-";
}

static void MCaptureConfig(NSString *reason) {
    NSDictionary<NSString *, NSNumber *> *current = MReadFeatureFlags();
    if (!gLastFeatureFlags) {
        NSMutableArray<NSString *> *enabled = [NSMutableArray array];
        for (NSString *key in current) {
            if (current[key].boolValue) [enabled addObject:key];
        }
        [enabled sortUsingSelector:@selector(compare:)];
        MLog(@"CONFIG_INITIAL reason=%@ enabled_count=%lu enabled=%@",
             reason ?: @"start", (unsigned long)enabled.count, MFlagList(enabled));
        gLastFeatureFlags = [current copy];
        return;
    }

    NSMutableArray<NSString *> *turnedOn = [NSMutableArray array];
    NSMutableArray<NSString *> *turnedOff = [NSMutableArray array];
    NSMutableSet<NSString *> *allKeys =
        [NSMutableSet setWithArray:current.allKeys];
    [allKeys addObjectsFromArray:gLastFeatureFlags.allKeys];
    for (NSString *key in allKeys) {
        BOOL oldValue = [gLastFeatureFlags[key] boolValue];
        BOOL newValue = [current[key] boolValue];
        if (!oldValue && newValue) [turnedOn addObject:key];
        if (oldValue && !newValue) [turnedOff addObject:key];
    }
    if (!turnedOn.count && !turnedOff.count) return;

    [turnedOn sortUsingSelector:@selector(compare:)];
    [turnedOff sortUsingSelector:@selector(compare:)];
    MLog(@"CONFIG_CHANGE reason=%@ on=%@ off=%@",
         reason ?: @"poll", MFlagList(turnedOn), MFlagList(turnedOff));
    gLastFeatureFlags = [current copy];
}

static void MLogOriginalPluginStatus(void) {
    NSArray *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                            NSUserDomainMask, YES);
    NSString *directory =
        documents.count ? documents.firstObject : NSTemporaryDirectory();
    NSString *originalLog = [directory stringByAppendingPathComponent:@"hooo"];
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:originalLog
                                                         error:NULL];
    unsigned long long size = [attributes fileSize];

    MLog(@"PLUGIN_READY HushConfig=%@ HushLogger=%@ HushSettingsPanel=%@ "
         @"original_log=%@ size=%llu",
         NSClassFromString(@"HushConfig") ? @"yes" : @"no",
         NSClassFromString(@"HushLogger") ? @"yes" : @"no",
         NSClassFromString(@"HushSettingsPanel") ? @"yes" : @"no",
         originalLog,
         size);
}

static void MStartPageSampler(void) {
    if (gPageTimer) return;
    gPageTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_main_queue());
    dispatch_source_set_timer(gPageTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(200 * NSEC_PER_MSEC),
                              (uint64_t)(40 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gPageTimer, ^{
        @autoreleasepool {
            NSString *page = MPageSummary();
            NSString *previous = nil;
            pthread_mutex_lock(&gPageLock);
            previous = [gPageContext copy];
            pthread_mutex_unlock(&gPageLock);
            if ([page isEqualToString:previous]) return;

            pthread_mutex_lock(&gPageLock);
            gPageContext = [page copy];
            pthread_mutex_unlock(&gPageLock);
            MLog(@"PAGE_CHANGE");
        }
    });
    dispatch_resume(gPageTimer);
}

static void MStartConfigSampler(void) {
    if (gConfigTimer) return;
    gConfigQueue = dispatch_queue_create("hush.safe-monitor.config",
                                         DISPATCH_QUEUE_SERIAL);
    gConfigTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          gConfigQueue);
    dispatch_source_set_timer(gConfigTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(500 * NSEC_PER_MSEC),
                              (uint64_t)(100 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gConfigTimer, ^{
        @autoreleasepool {
            MCaptureConfig(@"poll");
        }
    });
    dispatch_resume(gConfigTimer);
}

static void MAppStateChanged(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)object;
    (void)userInfo;
    MLog(@"APP_STATE %@", (__bridge NSString *)name);
}

static void MStartMonitor(void) {
    if (gStarted) return;
    gStarted = YES;
    @autoreleasepool {
        MLog(@"BOOT no-hooks=true no-config-writes=true no-dlopen=true");
        MLogOriginalPluginStatus();
        MCaptureConfig(@"start");
        MStartPageSampler();
        MStartConfigSampler();
    }
}

__attribute__((constructor))
static void HushSafeMonitorStart(void) {
    @autoreleasepool {
        MOpenLog();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(), NULL,
            MAppStateChanged,
            CFSTR("UIApplicationDidFinishLaunchingNotification"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(), NULL,
            MAppStateChanged,
            CFSTR("UIApplicationDidBecomeActiveNotification"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(), NULL,
            MAppStateChanged,
            CFSTR("UIApplicationDidEnterBackgroundNotification"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        MLog(@"CONSTRUCTOR passive-only pid=%d", getpid());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MStartMonitor();
        });
    }
}
