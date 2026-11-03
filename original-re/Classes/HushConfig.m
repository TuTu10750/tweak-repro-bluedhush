// HushConfig — full reimplementation of BluedHush_5.19 HushConfig (class @0x244888)
//
// Everything below was recovered from the original dylib:
//   +shared            @0xe290
//   -init              @0xe2fc
//   -hush_clearFlagCache @0xe3fc
//   -prewarmFlagCache  @0xe470
//   -isEnabled:default: @0xe8e4
//   -registerDefaults  @0xfb68
//   -hasCustomLocation @0xf3f0   -customLat @0xf448   -customLng @0xf4c4
//   -setCustomLat:lng: @0xf540   -customAltitude @0xf618  -setCustomAltitude: @0xf690
//   -authToken @0xf700  -userAgent @0xf774  -backupDir @0xf7e8
//   -defaults @0xf8e8  -flagCache @0xf8fc  -prefsSnapshot @0xf910
//
// The 130 registered defaults live in Headers/HushKeys.h and were extracted from
// the dictionaryWithObjects:forKeys:count: site at 0x1114c (count = 0x82).
//
// The previous scaffolding returned nil from -init and from all three property
// getters, which is precisely why every recovered feature was dead: +shared
// produced nil and every config read silently failed.

#import "HushConfig.h"
#import "HushActivation.h"
#import "HushKeys.h"
#import "HushLogger.h"
#import <objc/runtime.h>
#import <sqlite3.h>

#pragma mark - C-level helpers from the original __text

// @0x130b8 — true when a key must not be honoured until activation has run.
// The original builds a lazily-cached NSSet once (block @0x201530) from
// _HushActivationGatedKeys and does [set containsObject:key].  The set is now
// populated with the 17 recovered keys (see HushActivation.m) instead of being
// empty: the RE build is activated by default, so membership alone changes
// nothing — but the mechanism is the original one, and flipping
// HushActivationSetActive(NO) reproduces the shipped gate exactly.
BOOL HushKeyNeedsActivation(NSString *key) {
    if ([key length] == 0) return NO;
    return HushKeyNeedsActivationPair(key);
}

// @0x120f8 — true when the host build makes a key meaningless.
// The original filters a literal array through a predicate at 0x11810 before
// building the set (block @0x201280). No key is inapplicable on 7.50.3 yet.
BOOL HushHostCompatKeyIsInapplicable(NSString *key) {
    if ([key length] == 0) return NO;
    static NSSet *gInapplicable = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        gInapplicable = [set copy];
    });
    if (!gInapplicable) return NO;
    return [gInapplicable containsObject:key];
}

// @0x259838 — byte set once the activation cache has been populated.
// Exposed by the original as a plain global; HushLicense flips it.
BOOL gHushActivationCacheReady = NO;

// Membership test for the 27-key purify family (set built at 0x116c4 from the
// 23 literal cfstrings at 0x20b698..0x20b9d8, plus the four purify_master
// dependants). Any purify_* key inherits purify_master's value as its default.
static BOOL HushKeyIsInPurifyGroup(NSString *key) {
    static NSSet *gPurify = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:kHushPurifyGroupCount];
        for (int i = 0; i < kHushPurifyGroupCount; i++) {
            if (kHushPurifyGroup[i]) [a addObject:kHushPurifyGroup[i]];
        }
        gPurify = [NSSet setWithArray:a];
    });
    return [gPurify containsObject:key];
}

#pragma mark -

static HushConfig *gHushShared = nil;
static dispatch_once_t gHushSharedOnce;

@implementation HushConfig

// @0xe290
+ (id)shared {
    dispatch_once(&gHushSharedOnce, ^{
        gHushShared = [[HushConfig alloc] init];
    });
    return gHushShared;
}

// @0xe2fc
- (id)init {
    self = [super init];
    if (self == nil) return nil;

    _defaults = [NSUserDefaults standardUserDefaults];
    _flagCache = [NSMutableDictionary dictionary];
    [self registerDefaults];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(hush_clearFlagCache)
                                                name:NSUserDefaultsDidChangeNotification
                                              object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// @0xe3fc
- (void)hush_clearFlagCache {
    @synchronized (self) {
        [_flagCache removeAllObjects];
    }
}

// @0xfb68 — builds the 130-entry defaults dictionary and hands it to
// NSUserDefaults -registerDefaults: in one shot.
- (void)registerDefaults {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)kHushDefaultsCount];
    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *e = &kHushDefaults[i];
        if (!e->key) continue;
        NSString *k = @(e->key);
        if (!k) continue;
        if (e->isBool) {
            dict[k] = @(e->defBool != 0);
        } else if (e->defStr) {
            dict[k] = @(e->defStr);
        }
    }
    [_defaults registerDefaults:dict];
}

// @0xe470
- (void)prewarmFlagCache {
    NSDictionary *snapshot = [_defaults dictionaryRepresentation];

    @synchronized (self) {
        self.prefsSnapshot = snapshot;
    }

    // Walk the registered defaults so every switch is materialised exactly once
    // against one consistent snapshot instead of hammering NSUserDefaults.
    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *e = &kHushDefaults[i];
        if (!e->key) continue;
        NSString *k = @(e->key);
        if (!k) continue;

        BOOL def;
        if (e->isBool) {
            def = (e->defBool != 0);
        } else {
            id v = snapshot[k];
            def = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
        }
        [self isEnabled:k default:def];
    }

    @synchronized (self) {
        self.prefsSnapshot = nil;
    }

    [HushLogger logLevel:4 format:[NSString stringWithFormat:@"[Config] 开关缓存预热完成（%d 键，单次快照）", kHushDefaultsCount]];
}

// @0xe8e4
- (BOOL)isEnabled:(id)key default:(BOOL)def {
    if ([key length] == 0) return def;

    if (!gHushActivationCacheReady) {
        if (HushKeyNeedsActivation(key)) return NO;
    }

    // The original's toggle interceptor (@0x1c14c) tested membership first and
    // the activation byte second; the byte read is inlined there rather than a
    // call to _HushActivationIsActive. Same order here.
    if (HushKeyNeedsActivation(key) && !HushActivationIsActive()) return NO;

    @synchronized (self) {
        NSNumber *cached = _flagCache[key];
        if (cached) return [cached boolValue];
    }

    if (HushHostCompatKeyIsInapplicable(key)) {
        @synchronized (self) {
            _flagCache[key] = @NO;
        }
        return NO;
    }

    NSDictionary *snap = _prefsSnapshot;

    if (HushKeyIsInPurifyGroup(key)) {
        id v = snap ? snap[@"purify_master"] : nil;
        if (!v) v = [_defaults objectForKey:@"purify_master"];
        if (v && [v respondsToSelector:@selector(boolValue)]) {
            def = [v boolValue];
        }
    } else {
        id v = snap ? snap[key] : nil;
        if (!v) v = [_defaults objectForKey:key];
        if (!v) v = [_defaults objectForKey:key];
        if (v && [v respondsToSelector:@selector(boolValue)]) {
            def = [v boolValue];
        }
    }

    @synchronized (self) {
        _flagCache[key] = @(def);
    }
    return def;
}

// @0xe7xx — thin wrapper
- (BOOL)isEnabled:(id)a0 {
    return [self isEnabled:a0 default:NO];
}

- (void)setEnabled:(BOOL)a0 forKey:(id)a1 {
    if (!a1) return;
    [_defaults setBool:a0 forKey:a1];
    [_defaults synchronize];
    @synchronized (self) {
        _flagCache[a1] = @(a0);
    }
    // 「日志等级」是唯一一个必须立刻反映到运行时的开关：面板是通用渲染，
    // 点一下只走 setEnabled:forKey:，从不经过 +persistLevel:，于是 gHushLogLevel
    // 停着不动 —— 开关能点能存，但一行日志都不变。这里回灌一次补上反方向。
    if ([a1 isKindOfClass:[NSString class]] && [a1 isEqualToString:@"switch_debug_log"]) {
        [HushLogger setLevel:(a0 ? 5 : 3)];
    }
}

- (id)stringForKey:(id)a0 {
    if (!a0) return nil;
    id v = [_defaults objectForKey:a0];
    if ([v isKindOfClass:[NSString class]]) return v;
    if (v && [v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

- (void)setString:(id)a0 forKey:(id)a1 {
    if ([a1 length] == 0) return;
    if (a0) {
        [_defaults setObject:a0 forKey:a1];
    } else {
        [_defaults removeObjectForKey:a1];
    }
    [_defaults synchronize];
}

// @0xf0b4
- (id)snapshot {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *e = &kHushDefaults[i];
        if (!e->key) continue;
        NSString *k = @(e->key);
        if (!k) continue;
        out[k] = @([self isEnabled:k default:(e->isBool ? (e->defBool != 0) : NO)]);
    }
    return out;
}

- (void)resetToDefaults {
    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *e = &kHushDefaults[i];
        if (!e->key) continue;
        NSString *k = @(e->key);
        if (k) [_defaults removeObjectForKey:k];
    }
    [_defaults synchronize];
    [self hush_clearFlagCache];
}

// @0xf3f0
- (BOOL)hasCustomLocation {
    return [[self stringForKey:@"runtime_custom_lat"] length] != 0;
}

// @0xf448
- (double)customLat {
    NSString *s = [self stringForKey:@"runtime_custom_lat"];
    return [s length] ? [s doubleValue] : 0.0;
}

// @0xf4c4
- (double)customLng {
    NSString *s = [self stringForKey:@"runtime_custom_lng"];
    return [s length] ? [s doubleValue] : 0.0;
}

// @0xf540
- (void)setCustomLat:(double)a0 lng:(double)a1 {
    [self setString:[NSString stringWithFormat:@"%.6f", a0] forKey:@"runtime_custom_lat"];
    [self setString:[NSString stringWithFormat:@"%.6f", a1] forKey:@"runtime_custom_lng"];
}

// @0xf618
- (double)customAltitude {
    NSString *s = [self stringForKey:@"runtime_custom_altitude"];
    return [s length] ? [s doubleValue] : 0.0;
}

// @0xf690
- (void)setCustomAltitude:(double)a0 {
    [self setString:[NSString stringWithFormat:@"%.2f", a0] forKey:@"runtime_custom_altitude"];
}

// @0xf700
- (id)authToken {
    NSString *s = [self stringForKey:@"runtime_auth_token"];
    return [s length] ? s : nil;
}

- (void)setAuthToken:(id)a0 {
    [self setString:a0 forKey:@"runtime_auth_token"];
}

// @0xf774
- (id)userAgent {
    NSString *s = [self stringForKey:@"runtime_user_agent"];
    return [s length] ? s : nil;
}

- (void)setUserAgent:(id)a0 {
    [self setString:a0 forKey:@"runtime_user_agent"];
}

// @0xf7e8
- (id)backupDir {
    NSString *s = [self stringForKey:@"runtime_backup_dir"];
    if ([s length]) return s;

    NSString *base = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count]) base = [paths firstObject];
    if (!base) base = NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"bluedbackups"];
}

// @0xf8e8 / @0xf8fc / @0xf910

@end
