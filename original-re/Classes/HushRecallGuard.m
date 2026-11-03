//
//  HushRecallGuard.m
//  BluedHushRE
//
//  See HushRecallGuard.h.  Two deliberate choices worth spelling out:
//
//  1. Model fields are read through KVC, not through recovered ivar offsets.
//     The reference log prints `type=`, `msgId=`, `status=`, `fromId=`, so the
//     getters exist; KVC also survives the host renaming an ivar.  Every read is
//     guarded by respondsToSelector: and every key list has fallbacks, because a
//     modelling mistake here must not throw inside a message sync.
//
//  2. uid comes from the host's own chat DB file name.  That is where the
//     reference log got it from too (`扫描跳过：聊天库路径未解析（uid=0）`), and it
//     avoids depending on a login-token format we have not fully recovered.
//

#import "HushRecallGuard.h"
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushAntiRevoke.h"
#import "HushRuntime.h"

#import <objc/runtime.h>
#import <limits.h>

#define HUSH_MSG_TYPE_RECALL 55

static long sBlocked = 0;

long HushRecallBlockedCount(void) {
    return sBlocked;
}

#pragma mark - uid

static NSArray<NSString *> *HushRecallUidCandidates(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (docs.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:docs error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        // 100938367DB.sqlite — digits, then "DB", then a sqlite extension.
        if (![n.pathExtension isEqualToString:@"sqlite"]) continue;
        NSString *stem = n.lastPathComponent;
        NSRange r = [stem rangeOfString:@"DB"];
        if (r.location == NSNotFound || r.location == 0) continue;
        NSString *digits = [stem substringToIndex:r.location];
        if (digits.length == 0) continue;
        BOOL allDigits = YES;
        for (NSUInteger i = 0; i < digits.length; i++) {
            unichar c = [digits characterAtIndex:i];
            if (c < '0' || c > '9') { allDigits = NO; break; }
        }
        if (!allDigits) continue;
        [out addObject:digits];
    }
    return out;
}

long long HushRecallCurrentUid(void) {
    static long long sUid = 0;
    static NSTimeInterval sReadAt = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // Cache for 30 s: the DB file appears some time after launch, so a permanent
    // cache would pin the "unknown" answer for the whole session.
    if (sUid != 0 && now - sReadAt < 30.0) return sUid;

    sReadAt = now;
    NSArray *cands = HushRecallUidCandidates();
    if (cands.count != 1) {
        if (cands.count > 1) {
            [HushLogger logLevel:2 format:[NSString stringWithFormat:
                @"[Hush][防撤回] uid 候选 %lu 个（%@），无法唯一确定 → 按 fail-safe 放行不拦",
                (unsigned long)cands.count, [cands componentsJoinedByString:@","]]];
        }
        sUid = 0;
        return 0;
    }
    sUid = [[cands firstObject] longLongValue];
    return sUid;
}

#pragma mark - model probing

static BOOL HushModelHasKey(id model, NSString *key) {
    if (![model isKindOfClass:[NSObject class]]) return NO;
    SEL g = NSSelectorFromString(key);
    if (g && [model respondsToSelector:g]) return YES;
    // KVC-only accessors (`-valueForKey:` backed) are fine too; probe cheaply by
    // asking for the value and checking it is not an NSNull.
    @try {
        id v = [model valueForKey:key];
        return v != nil && v != [NSNull null];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static long long HushModelLongLong(id model, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        if (!HushModelHasKey(model, k)) continue;
        @try {
            id v = [model valueForKey:k];
            if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
        } @catch (__unused NSException *e) {
            continue;
        }
    }
    return LLONG_MIN;
}

static NSArray<NSString *> *HushRecallTypeKeys(void) {
    return @[@"type", @"messageType"];
}

static NSArray<NSString *> *HushRecallFromKeys(void) {
    return @[@"fromId", @"from", @"senderId", @"uid"];
}

static NSArray<NSString *> *HushRecallIdKeys(void) {
    return @[@"msgId", @"messageId", @"msgLocalId"];
}

BOOL HushRecallIsForeignRecall(id model, long long *outMsgId) {
    if (!model) return NO;

    long long type = HushModelLongLong(model, HushRecallTypeKeys());
    if (type != HUSH_MSG_TYPE_RECALL) return NO;

    long long me = HushRecallCurrentUid();
    if (me == 0) return NO;   // unknown login state → fail open, like the original

    long long from = HushModelLongLong(model, HushRecallFromKeys());
    if (from == LLONG_MIN) return NO;   // cannot attribute it → do not touch

    if (outMsgId) {
        long long mid = HushModelLongLong(model, HushRecallIdKeys());
        *outMsgId = (mid == LLONG_MIN) ? 0 : mid;
    }

    if (from == me) {
        // Our own recall: let it through, the reference log does the same.
        return NO;
    }
    return YES;
}


#pragma mark - persistence

static NSArray<NSString *> *HushRecallContentKeys(void) {
    return @[@"messageContent", @"content", @"text"];
}

static NSString *HushRecallModelString(id model, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        if (!HushModelHasKey(model, k)) continue;
        @try {
            id v = [model valueForKey:k];
            if ([v isKindOfClass:[NSString class]]) return v;
            if (v) return [v description];
        } @catch (__unused NSException *e) {
            continue;
        }
    }
    return @"";
}

// Called on every successful block: write the row into our own DB (so a restart
// does not lose it) and dump the hit table right away, because the t1/t4/t12
// reports are long over by the time a user recalls something.
static void HushRecallNoteBlocked(id model, long long mid, const char *where) {
    long long st = HushModelLongLong(model, @[@"sessionType"]);
    long long sid = HushModelLongLong(model, @[@"sessionId"]);
    long long type = HushModelLongLong(model, HushRecallTypeKeys());
    if (st == LLONG_MIN) st = 0;
    if (sid == LLONG_MIN) sid = 0;
    if (type == LLONG_MIN) type = HUSH_MSG_TYPE_RECALL;

    HushAntiRevokeRecordBlocked(st, sid, mid, type,
                                HushRecallModelString(model, HushRecallContentKeys()));
    HushHitDumpNow(where);
}

#pragma mark - entry points used by the hook table

void HushRecallFilterAndForward(id self, SEL _cmd, id msgs,
                                void (*orig)(id, SEL, id)) {
    if (!orig) return;

    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]
        || ![msgs isKindOfClass:[NSArray class]]
        || [(NSArray *)msgs count] == 0) {
        orig(self, _cmd, msgs);
        return;
    }

    NSArray *in = (NSArray *)msgs;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:in.count];

    for (id m in in) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(m, &mid)) {
            sBlocked++;
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 拦截别人撤回 msgId=%lld（不进内存/UI）", mid]];
            HushRecallNoteBlocked(m, mid, "ui-array");
            continue;
        }
        [kept addObject:m];
    }

    if (kept.count == in.count) {          // nothing dropped: untouched path
        orig(self, _cmd, msgs);
        return;
    }
    if (kept.count == 0) return;           // the whole batch was recall packets

    orig(self, _cmd, kept);
}

void HushRecallGuardSingleWrite(id self, SEL _cmd, id model,
                                void (*orig)(id, SEL, id)) {
    if (!orig) return;

    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(model, &mid)) {
            sBlocked++;
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 拦下撤回落库 msgId=%lld（本地记录保持原样）", mid]];
            HushRecallNoteBlocked(model, mid, "db-write");
            return;
        }
    }
    orig(self, _cmd, model);
}

void HushRecallFilterArrayForward(id self, SEL _cmd, id msgs,
                                  unsigned long long updateType,
                                  void (*orig)(id, SEL, id, unsigned long long)) {
    if (!orig) return;

    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]
        || ![msgs isKindOfClass:[NSArray class]]
        || [(NSArray *)msgs count] == 0) {
        orig(self, _cmd, msgs, updateType);
        return;
    }

    NSArray *in = (NSArray *)msgs;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:in.count];
    for (id m in in) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(m, &mid)) {
            sBlocked++;
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 拦截 UI 刷新 updateType=%llu msgId=%lld（不渲染撤回态）",
                updateType, mid]];
            HushRecallNoteBlocked(m, mid, "ui-update");
            continue;
        }
        [kept addObject:m];
    }

    if (kept.count == in.count) { orig(self, _cmd, msgs, updateType); return; }
    if (kept.count == 0) return;
    orig(self, _cmd, kept, updateType);
}

void HushRecallDropSingleForward(id self, SEL _cmd, id model,
                                 void (*orig)(id, SEL, id)) {
    if (!orig) return;

    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(model, &mid)) {
            sBlocked++;
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 拦下新消息入口 msgId=%lld（不进会话列表）", mid]];
            HushRecallNoteBlocked(model, mid, "ui-single");
            return;
        }
    }
    orig(self, _cmd, model);
}
