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
#import <UIKit/UIKit.h>
#import <limits.h>

#define HUSH_MSG_TYPE_RECALL 55

static long sBlocked = 0;

// 关联对象 key：被我们改造过（type 55 → 1）的消息会挂上它，Cell 的 setMessage:
// 据此决定要不要贴「已拦截」。声明放在最前面，neutralize 里要用。
static char kHushInterceptedKey;

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

// ===========================================================================
// v30：从「过滤/提前返回」改成「原地或副本改造 + 无条件调 %orig」
//
// v28 的死锁证据链：只拦 DB（v27）页面正常；一旦加上 updateMessages:updateType:
// 的过滤并在批次被抽空时不调 %orig，主线程在同一秒停摆，连我们紧接着要打的
// hit event: 都没有 —— 宿主在这条链上等这次调用把状态推进完，我们提前返回
// 等于把它的状态机悬住。
//
// 所以这里立三条规矩，任何一条都不许破：
//   R1 数组长度/顺序/指针一个都不动（改造只替换元素，不删元素）；
//   R2 %orig 无条件调用，参数原样；
//   R3 改造失败（模型没有 setter）→ 完全放行，宁可漏拦也不挂死。
//
// 防污染：优先复制一份再改（宿主 DB 拿到的是原对象，不会被写脏）；模型不支持
// copy 就原地改，并在 p_updateMessage: 的放行分支里把字段还原成 55/3 —— 那条
// 腿的写库本来就被我们拦着，宿主读不到撤回态，还原只是防止我们自己把 type=1
// 泄漏进它的库。
// ===========================================================================

#pragma mark - 数值 setter 调用（按真实 type encoding 分派）

// 传参宽度必须跟 method 的 encoding 一致，否则 ABI 会读错寄存器。
// GJIMMessageModel: setType: v24@0:8Q16 / setStatus: v20@0:8C16 —— 一个是 Q
// 一个是 C，用 KVC 会做隐式转换，直接按 IMP 调才稳。
static char HushArgTypeChar(const char *enc) {
    if (!enc) return 0;
    int idx = 0;
    const char *p = enc;
    while (*p) {
        char c = *p;
        if (c == 'r' || c == 'n' || c == 'N' || c == 'o' || c == 'O'
            || c == 'R' || c == 'V' || c == 'A') { p++; continue; }
        if (idx == 3) return c;
        idx++;
        p++;
        while (*p >= '0' && *p <= '9') p++;
    }
    return 0;
}

static BOOL HushCallSetNumber(id obj, SEL sel, long long v) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return NO;
    Method m = class_getInstanceMethod([obj class], sel);
    if (!m) return NO;
    char t = HushArgTypeChar(method_getTypeEncoding(m));
    IMP imp = method_getImplementation(m);
    if (!imp) return NO;
    switch (t) {
        case 'c': ((void (*)(id, SEL, signed char))imp)(obj, sel, (signed char)v);      return YES;
        case 'C': ((void (*)(id, SEL, unsigned char))imp)(obj, sel, (unsigned char)v);  return YES;
        case 's': ((void (*)(id, SEL, short))imp)(obj, sel, (short)v);                  return YES;
        case 'S': ((void (*)(id, SEL, unsigned short))imp)(obj, sel, (unsigned short)v);return YES;
        case 'i': ((void (*)(id, SEL, int))imp)(obj, sel, (int)v);                      return YES;
        case 'I': ((void (*)(id, SEL, unsigned int))imp)(obj, sel, (unsigned int)v);    return YES;
        case 'l': ((void (*)(id, SEL, long))imp)(obj, sel, (long)v);                    return YES;
        case 'L': ((void (*)(id, SEL, unsigned long))imp)(obj, sel, (unsigned long)v);  return YES;
        case 'q': ((void (*)(id, SEL, long long))imp)(obj, sel, v);                     return YES;
        case 'Q': ((void (*)(id, SEL, unsigned long long))imp)(obj, sel, (unsigned long long)v); return YES;
        case 'B': ((void (*)(id, SEL, BOOL))imp)(obj, sel, v != 0);                     return YES;
        case 'f': ((void (*)(id, SEL, float))imp)(obj, sel, (float)v);                  return YES;
        case 'd': ((void (*)(id, SEL, double))imp)(obj, sel, (double)v);                return YES;
        default: return NO;
    }
}

// 对象 setter（setContent: 之类）。只有当参数编码真的是 '@' 才发，
// 避免把 nil 塞进非对象参数（v31 之前 KVC 乱塞 nil 就是这个坑的邻居）。
static BOOL HushCallSetObject(id obj, SEL sel, id value) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return NO;
    Method m = class_getInstanceMethod([obj class], sel);
    if (!m) return NO;
    if (HushArgTypeChar(method_getTypeEncoding(m)) != '@') return NO;
    IMP imp = method_getImplementation(m);
    if (!imp) return NO;
    ((void (*)(id, SEL, id))imp)(obj, sel, value);
    return YES;
}

static NSString *HushModelString(id model, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        if (!HushModelHasKey(model, k)) continue;
        @try {
            id v = [model valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (__unused NSException *e) { continue; }
    }
    return nil;
}

#pragma mark - 原地改动的登记（供 p_updateMessage: 放行分支还原）

static NSMapTable *HushDirtyTable(void) {
    static NSMapTable *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // key 弱引用（模型归宿主所有），value 强引用一份原始字段。
        t = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)
                                  valueOptions:NSPointerFunctionsStrongMemory];
    });
    return t;
}

static NSLock *HushDirtyLock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

static void HushMarkDirtyInPlace(id model, long long type, long long status,
                                 BOOL contentFilled, NSString *origContent) {
    if (!model) return;
    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    rec[@"type"] = @(type);
    rec[@"status"] = @(status);
    rec[@"filled"] = @(contentFilled);
    if (contentFilled) rec[@"content"] = origContent ?: @"";
    [HushDirtyLock() lock];
    [HushDirtyTable() setObject:rec forKey:model];
    [HushDirtyLock() unlock];
}

static void HushRestoreDirtyInPlace(id model) {
    if (!model) return;
    [HushDirtyLock() lock];
    NSDictionary *orig = [HushDirtyTable() objectForKey:model];
    [HushDirtyTable() removeObjectForKey:model];
    [HushDirtyLock() unlock];
    if (!orig) return;
    long long t = [orig[@"type"] longLongValue];
    long long s = [orig[@"status"] longLongValue];
    HushCallSetNumber(model, @selector(setType:), (t == LLONG_MIN ? HUSH_MSG_TYPE_RECALL : t));
    HushCallSetNumber(model, @selector(setStatus:), (s == LLONG_MIN ? 3 : s));
    // 正文也要还原：占位符只该出现在界面上，不能跟着这条消息落进宿主库
    // （否则用户重启后看到自己的消息变成「对方试图撤回…」，那是数据污染）。
    if ([orig[@"filled"] boolValue]) {
        NSString *c = orig[@"content"];
        HushCallSetObject(model, @selector(setContent:), c.length ? c : @"");
    }
    [HushLogger logLevel:4 format:@"[Hush][防撤回] 放行前已把原地改造的字段（type/status/content）还原，防写入宿主库"];
}

#pragma mark - 改造一个撤回包

static long sNeutralized = 0;

// 返回要交给 %orig 的对象；改造不了就原样返回（R3）。
static id HushRecallNeutralize(id model, long long mid, const char *where) {
    if (!model) return model;

    HushCrumb("neutralize:probe");
    long long t = HushModelLongLong(model, HushRecallTypeKeys());
    long long s = HushModelLongLong(model, @[@"status"]);
    if (t == LLONG_MIN) t = HUSH_MSG_TYPE_RECALL;
    if (s == LLONG_MIN) s = 3;

    // v35：一律原地改。
    //
    // v34 是「copy 一份改副本、再把数组里的指针换成副本」，出发点是不让宿主落库
    // 那条腿看到被改过的字段。实测代价太大：宿主不认数组里换掉的指针，它自己的
    // 数据源与行 diff 仍然拿着原对象（type=55 / status=3），于是界面上那一行照样
    // 被抹掉 —— 日志里 db-write 拦住了、ui-update 也打印了「改造」（数量不变 6），
    // 屏幕上却还是消失。
    //
    // 原地改之后，宿主手里的对象本身就是 type=1，行 diff 找不到「撤回」，行不再
    // 消失。落库污染改由「写库前还原」兜住：HushRestoreDirtyInPlace 会在
    // -p_updateMessage: 放行前把 type / status / content 还原成宿主原值。
    //
    // 顺序也是安全的：hooo1 的实测顺序是 p_updateMessage → addMessages →
    // updateMessages，落库永远发生在 UI 改造之前，所以还原不会把已经画好的气泡
    // 改回撤回态。
    id target = model;
    BOOL isolated = NO;

    // 55 → 1（普通文本），status 3（已撤回）→ 0，让宿主按普通气泡渲染。
    BOOL ok = HushCallSetNumber(target, @selector(setType:), 1);
    HushCallSetNumber(target, @selector(setStatus:), 0);

    // 空白气泡：撤回包自己不带正文（正文在宿主库里那条原消息上，靠撤回态的
    // 排版逻辑去取）。我们把撤回态抹掉之后，宿主就没有理由再去取正文了，
    // 于是渲染成一条什么都没有的气泡。这里补一句占位说明；
    // 只有原本就没有正文时才补，正常消息不受影响。
    BOOL filled = NO;
    NSString *body = HushModelString(model, @[@"content", @"messageContent", @"text"]);
    NSString *bodyForRestore = body;
    if (body.length == 0) {
        filled = HushCallSetObject(target, @selector(setContent:),
                                   @"[对方试图撤回一条消息，已被拦截]");
        if (!filled) bodyForRestore = nil;
    }

    if (!ok) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            [HushLogger logLevel:2 format:
                @"[Hush][防撤回] 该模型没有可用的 setType:，退回「完全放行」防止挂死"];
        }
        if (isolated) { /* 副本没改成，没用上，直接丢 */ }
        return model;
    }

    HushMarkDirtyInPlace(target, t, s, filled, bodyForRestore);
    // 给气泡打标记：Cell 的 setMessage: 会查这个关联对象，命中就贴「已拦截」。
    objc_setAssociatedObject(target, &kHushInterceptedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sNeutralized++;
    // 注意别用 %s 传中文：%s 走的是 C 字符串，日志里会变成乱码
    // （v31 的「ÂâØÊú¨ÈöîÁ¶ª」就是这么来的），中文一律 %@。
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][防撤回] 改造 type=55→1 msgId=%lld 入口=%s 方式=%@ 补正文=%d",
        mid, where, isolated ? @"副本隔离" : @"原地改+落库前还原", filled ? 1 : 0]];
    return target;
}

static NSUInteger HushNeutralizeCount(void) { return (NSUInteger)sNeutralized; }

#pragma mark - 气泡标记

static const NSInteger kHushInterceptTag = 0x4F3A21;   // 魔数，便于 viewWithTag: 找回

BOOL HushRecallModelWasIntercepted(id model) {
    if (!model) return NO;
    id v = objc_getAssociatedObject(model, &kHushInterceptedKey);
    return [v boolValue];
}

// 在 cell 内容区左上角贴一枚「已拦截」。位置用 frame 写死：气泡自身的 x 会随
// 左右消息变化，跟着气泡摆会把标签推到屏幕外，这里只求「一眼能看见」。
void HushRecallDecorateCell(id cell, id model) {
    if (!cell) return;
    UIView *content = nil;
    @try {
        if ([cell respondsToSelector:@selector(contentView)]) content = [cell contentView];
    } @catch (__unused NSException *e) { content = nil; }
    if (!content) return;

    UILabel *tag = nil;
    @try { tag = (UILabel *)[content viewWithTag:kHushInterceptTag]; }
    @catch (__unused NSException *e) { tag = nil; }

    if (!HushRecallModelWasIntercepted(model)) {
        if (tag && !tag.hidden) tag.hidden = YES;   // 复用到普通消息时收起来
        return;
    }

    if (!tag) {
        tag = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 4.0, 0.0, 0.0)];
        tag.tag = kHushInterceptTag;
        tag.text = @"已拦截";
        tag.font = [UIFont boldSystemFontOfSize:10.0];
        tag.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.1 alpha:1.0];
        tag.backgroundColor = [UIColor clearColor];
        tag.userInteractionEnabled = NO;
        [tag sizeToFit];
        [content addSubview:tag];
    }
    tag.hidden = NO;
    CGRect f = tag.frame;
    f.origin.x = 8.0;
    f.origin.y = 4.0;
    tag.frame = f;
    [content bringSubviewToFront:tag];
}

// 写库前还原：数组形态的写入口（GJIMDBService -dealMessage:array:）也照顾到。
void HushRecallRestoreDirtyArray(id obj) {
    if (!obj) return;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id m in (NSArray *)obj) HushRestoreDirtyInPlace(m);
        return;
    }
    HushRestoreDirtyInPlace(obj);
}

#pragma mark - 四个入口

// addMessages:（内存）
void HushRecallFilterAndForward(id self, SEL _cmd, id msgs,
                                void (*orig)(id, SEL, id)) {
    if (!orig) return;

    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]
        || ![msgs isKindOfClass:[NSArray class]]
        || [(NSArray *)msgs count] == 0) {
        orig(self, _cmd, msgs);            // R2
        return;
    }

    NSArray *in = (NSArray *)msgs;
    NSUInteger n = in.count;
    BOOL hit = NO;

    // 先扫一遍判断有没有要改造的：没有就原样直传（绝大多数调用走这条路）。
    for (id m in in) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(m, &mid)) { hit = YES; break; }
    }
    if (!hit) { orig(self, _cmd, msgs); return; }   // R2

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];   // R1：长度不变
    for (id m in in) {
        long long mid = 0;
        if (!HushRecallIsForeignRecall(m, &mid)) { [out addObject:m]; continue; }
        sBlocked++;
        id repl = HushRecallNeutralize(m, mid, "addMessages:");
        [out addObject:(repl ?: m)];
        HushRecallNoteBlocked(m, mid, "mem-array");       // 原始对象记账
    }

    HushCrumb("mem-array:orig");
    orig(self, _cmd, out);                 // R2：一定调用，长度与入参一致
}

// p_updateMessage:（落库）—— v27 已实测这条路「拦掉不调 orig」不会卡，
// 但按用户要求仍把「拦」与「改」分开：拦的时候不 call orig，放行时先还原字段。
void HushRecallGuardSingleWrite(id self, SEL _cmd, id model,
                                void (*orig)(id, SEL, id)) {
    if (!orig) return;

    BOOL on = [[HushConfig shared] isEnabled:@"switch_anti_recall"];
    BOOL blockDb = [[HushConfig shared] isEnabled:@"switch_ar_db_block"];

    if (on && blockDb) {
        long long mid = 0;
        HushCrumb("db:probe");
        if (HushRecallIsForeignRecall(model, &mid)) {
            sBlocked++;
            HushCrumb("db:record");
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 拦下撤回落库 msgId=%lld（本地记录保持原样）", mid]];
            HushRecallNoteBlocked(model, mid, "db-write");
            return;                        // 拦写：不调 orig（v27 验证安全）
        }
    }

    // 放行：如果这个对象被我们在 UI 腿上原地改造过，先把字段还原成 55/3，
    // 免得宿主把我们写进去的 type=1 落进它自己的库。
    if (on) HushRestoreDirtyInPlace(model);
    orig(self, _cmd, model);               // R2
}

// updateMessages:updateType:（UI 批次）—— v28 就死在这条上，重点改造对象。
void HushRecallFilterArrayForward(id self, SEL _cmd, id msgs,
                                  unsigned long long updateType,
                                  void (*orig)(id, SEL, id, unsigned long long)) {
    if (!orig) return;

    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]
        || ![[HushConfig shared] isEnabled:@"switch_ar_ui_block"]
        || ![msgs isKindOfClass:[NSArray class]]
        || [(NSArray *)msgs count] == 0) {
        orig(self, _cmd, msgs, updateType);            // R2
        return;
    }

    NSArray *in = (NSArray *)msgs;
    NSUInteger n = in.count;
    BOOL hit = NO;
    for (id m in in) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(m, &mid)) { hit = YES; break; }
    }
    if (!hit) { orig(self, _cmd, msgs, updateType); return; }   // R2

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];  // R1
    for (id m in in) {
        long long mid = 0;
        if (!HushRecallIsForeignRecall(m, &mid)) { [out addObject:m]; continue; }
        sBlocked++;
        id repl = HushRecallNeutralize(m, mid, "ui-update");
        [out addObject:(repl ?: m)];
        // 记账放在调 orig 之前：万一宿主在这条链上仍然挂住，hit event: 已经落了。
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][防撤回] UI 批次改造 updateType=%llu msgId=%lld（数量不变 %lu，累计改造 %lu）",
            updateType, mid, (unsigned long)n, (unsigned long)HushNeutralizeCount()]];
        HushRecallNoteBlocked(m, mid, "ui-update");
    }

    HushCrumb("ui-update:orig");
    orig(self, _cmd, out, updateType);     // R2：长度与 updateType 都原样
}

// receiveNewMessage:（单条进会话）
void HushRecallDropSingleForward(id self, SEL _cmd, id model,
                                 void (*orig)(id, SEL, id)) {
    if (!orig) return;

    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]
        && [[HushConfig shared] isEnabled:@"switch_ar_ui_block"]) {
        long long mid = 0;
        if (HushRecallIsForeignRecall(model, &mid)) {
            sBlocked++;
            id repl = HushRecallNeutralize(model, mid, "receiveNewMessage:");
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush][防撤回] 单条改造 msgId=%lld（照常进会话，不渲染撤回态）", mid]];
            HushRecallNoteBlocked(model, mid, "ui-single");
            HushCrumb("ui-single:orig");
            orig(self, _cmd, repl ?: model);          // R2
            return;
        }
    }
    orig(self, _cmd, model);                          // R2
}
