//
//  HushActivation.m
//  BluedHushRE
//
//  See HushActivation.h for the recovered shape.  Two things matter here:
//
//  1. The flag is a single BOOL, not a per-key decision.  The original stores
//     it in one byte and every check inlines a load of that byte, so "which
//     feature is locked" is decided solely by membership in the gated set.
//
//  2. `gHushActivationCacheReady` (original @0x259838) has to be sealed before
//     HushConfig starts caching values.  HushConfig.m short-circuits gated keys
//     to NO while it is still NO, which is the same fail-closed order the
//     original boot block used.
//

#import "HushActivation.h"
#import "HushConfig.h"
#import "HushLogger.h"

// Defined in HushConfig.m; set once the activation cache is populated.
extern BOOL gHushActivationCacheReady;

static BOOL sHushActivationActive = YES;   // RE build ships activated
static BOOL sHushActivationInstalled = NO;

// 8 keys under 定位与追踪 + 9 under 限制解放 = the "受限键 17 项" the original
// printed at boot.  `switch_virtual_location` is confirmed by the original log
// ("拦下开关：switch_virtual_location"); the other sixteen are matched by name
// and count, and are listed in the report as derived rather than enumerated.
static NSString * const kGatedTracking[] = {
    @"switch_virtual_location",
    @"switch_location_sim",
    @"switch_altitude_sim",
    @"switch_track",
    @"switch_physical_track",
    @"switch_track_instant",
    @"switch_real_location_mask",
    @"switch_map_avatar_clear",
};

static NSString * const kGatedUnlock[] = {
    @"switch_blacklist_unlock",
    @"switch_fair_exchange",
    @"switch_exchange_unlock",
    @"switch_exchange_peek",
    @"switch_privacy_unlock",
    @"switch_follow_unlock",
    @"switch_visitor_unlock",
    @"switch_private_photo",
    @"switch_local_vip",
};

BOOL HushActivationIsActive(void) {
    return sHushActivationActive;
}

void HushActivationSetActive(BOOL active) {
    sHushActivationActive = active ? YES : NO;
}

NSArray<NSString *> *HushActivationGatedKeys(void) {
    static NSArray *gGated = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [NSMutableArray arrayWithCapacity:17];
        for (size_t i = 0; i < sizeof(kGatedTracking) / sizeof(kGatedTracking[0]); i++) {
            [all addObject:kGatedTracking[i]];
        }
        for (size_t i = 0; i < sizeof(kGatedUnlock) / sizeof(kGatedUnlock[0]); i++) {
            [all addObject:kGatedUnlock[i]];
        }
        gGated = [all copy];
    });
    return gGated;
}

BOOL HushKeyNeedsActivationPair(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    return [HushActivationGatedKeys() containsObject:key];
}

void HushActivationInstall(void) {
    if (sHushActivationInstalled) return;
    sHushActivationInstalled = YES;

    NSUInteger n = HushActivationGatedKeys().count;

    // Seal the cache before anything reads a switch, so gated keys resolve
    // against the final state instead of the fail-closed default.
    gHushActivationCacheReady = YES;

    [HushLogger logLevel:3
                  format:[NSString stringWithFormat:
                          @"[Hush] 授权状态：%@（受限键 %lu 项：定位与追踪 8 + 限制解放 9 / RE 版机制复刻，默认激活）",
                          HushActivationIsActive() ? @"已激活" : @"未激活",
                          (unsigned long)n]];
}
