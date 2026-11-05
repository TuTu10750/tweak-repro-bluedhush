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
#import <QuartzCore/QuartzCore.h>
#import <limits.h>
#import <stdio.h>          // P0-2a 探针：fprintf(stderr) 绕开 NSLog 的 <private>
#import <stdlib.h>         // P0-2a 探针：free(class_copyIvarList(...))

#define HUSH_MSG_TYPE_RECALL 55
// 阅后即焚（闪照/闪文）。v39a 真机日志里它只在影子更新对象上出现过一次
// （TRUTH#7/#8 mid=3），真消息那条还没采到 —— v40 先让探针认得它。
#define HUSH_MSG_TYPE_TIME_LIMITED 282

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

// 直接按 getter 取整数。
//
// -valueForKey: 在 hook 里是颗定时炸弹：撤回包是 gRPC 反序列化出来的对象，
// 未必是普通属性容器，key 不存在就抛 NSUnknownKeyException —— 钩子层抛出去
// 没人接，进程直接 abort。所以先 respondsToSelector: + IMP 直调（宽度按
// method 的返回值 encoding 分派），KVC 只在「没有 getter」时兜底，且 @try 包死。
static long long HushDirectLongLong(id obj, NSString *key) {
    if (!obj || key.length == 0) return LLONG_MIN;
    if (![obj isKindOfClass:[NSObject class]]) return LLONG_MIN;

    SEL g = NSSelectorFromString(key);
    if (!g || ![obj respondsToSelector:g]) return LLONG_MIN;

    Method m = class_getInstanceMethod([obj class], g);
    if (!m) return LLONG_MIN;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return LLONG_MIN;

    char r = *enc;
    while (r == 'r' || r == 'n' || r == 'N' || r == 'o' || r == 'O'
           || r == 'R' || r == 'V' || r == 'A') {
        enc++;
        r = *enc;
    }
    if (r == '\0') return LLONG_MIN;

    IMP imp = method_getImplementation(m);
    if (!imp) return LLONG_MIN;

    @try {
        switch (r) {
            case 'c': return (long long)((char (*)(id, SEL))imp)(obj, g);
            case 'C': return (long long)((unsigned char (*)(id, SEL))imp)(obj, g);
            case 'B': return (long long)((BOOL (*)(id, SEL))imp)(obj, g);
            case 's': return (long long)((short (*)(id, SEL))imp)(obj, g);
            case 'S': return (long long)((unsigned short (*)(id, SEL))imp)(obj, g);
            case 'i': return (long long)((int (*)(id, SEL))imp)(obj, g);
            case 'I': return (long long)((unsigned int (*)(id, SEL))imp)(obj, g);
            case 'l': return (long long)((long (*)(id, SEL))imp)(obj, g);
            case 'L': return (long long)((unsigned long (*)(id, SEL))imp)(obj, g);
            case 'q': return ((long long (*)(id, SEL))imp)(obj, g);
            case 'Q': return (long long)((unsigned long long (*)(id, SEL))imp)(obj, g);
            case 'f': return (long long)((float (*)(id, SEL))imp)(obj, g);
            case 'd': return (long long)((double (*)(id, SEL))imp)(obj, g);
            case '@': {
                id v = ((id (*)(id, SEL))imp)(obj, g);
                if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
                return LLONG_MIN;
            }
            default: return LLONG_MIN;
        }
    } @catch (__unused NSException *e) {
        return LLONG_MIN;
    }
}

static long long HushModelLongLong(id model, NSArray<NSString *> *keys) {
    // 第一轮：getter 直调（不碰 KVC，不会抛）。
    for (NSString *k in keys) {
        long long v = HushDirectLongLong(model, k);
        if (v != LLONG_MIN) return v;
    }
    // 第二轮：只有真的没有 getter 时才走 KVC 兜底。
    for (NSString *k in keys) {
        if (![model isKindOfClass:[NSObject class]]) break;
        @try {
            id v = [model valueForKey:k];
            if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
        } @catch (__unused NSException *e) {
            continue;
        }
    }
    return LLONG_MIN;
}

// v41d（A1）：单键精确取，绝不跨键兜底。
//
// HushModelLongLong 会在 `type` 取不到时悄悄退到 `messageType`，诊断时这层兜底
// 会把两个语义完全不同的字段混成一个数。v41c 日志里 BURN# 的 `type=24` 就是
// 这么来的 —— TRUTH 明细里全量 60 条没有一条 type=24，24 只可能是 messageType。
// 要判断「这个 model 上 type 到底有没有」，必须两个键分开取。
static long long HushModelLLRaw(id model, NSString *key) {
    if (!model || !key) return LLONG_MIN;
    long long v = HushDirectLongLong(model, key);
    if (v != LLONG_MIN) return v;
    if (![model isKindOfClass:[NSObject class]]) return LLONG_MIN;
    @try {
        id o = [model valueForKey:key];
        if ([o respondsToSelector:@selector(longLongValue)]) return [o longLongValue];
    } @catch (__unused NSException *e) {
        return LLONG_MIN;
    }
    return LLONG_MIN;
}

static NSArray<NSString *> *HushRecallTypeKeys(void) {
    return @[@"type", @"messageType"];
}

static NSArray<NSString *> *HushRecallFromKeys(void) {
    return @[@"fromId", @"from", @"senderId", @"uid"];
}

// v40：msgLocalId 从主 ID 链里踢出去。
//
// 上一版把它当兜底，结果宿主的影子更新对象（_shadowUpdatesController 里那批）
// 只有 msgLocalId、msgId 恒 0，于是被当成「真消息」打了出来：v39a 日志里
// TRUTH#1–#16 全是它们（mid=0~7、deleteStatus 恒 1），30 批探针额度被吃掉一半，
// 真消息被挤到 TRUTH#17 之后，还顺带把 deleteStatus 判据带歪。
// 本地自增 ID 只在需要区分「同一 msgId 的不同本地副本」时才用，单独一条链。
static NSArray<NSString *> *HushRecallIdKeys(void) {
    return @[@"msgId", @"messageId"];
}

static NSArray<NSString *> *HushRecallLocalIdKeys(void) {
    return @[@"msgLocalId"];
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

// v41：历史撤回洗白。
//
// 「吞包」只防新消息。聊天记录里早就在的那批 type=55 是宿主自己标的
// （v40 真机日志：type=55 / del=1 / intc=0 共 26 条，mid 4/9/10/11/12/14/15…），
// 每次进聊天页都被渲染成灰色占位条 —— 这就是"历史记录还会变灰"的由来。
// 原内容服务端已经删了，恢复不出来；只能把类型码洗成普通文本、清掉删除标记，
// 让它渲染成正常气泡而不是「对方撤回了一条消息」。
//
// 默认关：洗出来长什么样（content 可能是空串）得先在真机上看一眼再说。
BOOL HushRecallIsIntercepted(long long mid);   // 真定义在下面，这里先用

static void HushHistoricalRecallPurify(id model) {
    if (!model) return;
    // 这个键还没进 kHushToggles（HushModuleMap.h 是 _work/gen_module_map.py 生成的，
    // 手改会被下次重生成冲掉），所以面板里没有它 —— 先默认打开，验过渲染效果再补进面板。
    // 用户在 defaults 里手写 false 也拦得住（isEnabled:default: 优先读存储值）。
    if (![[HushConfig shared] isEnabled:@"switch_recall_history_purify" default:YES]) return;
    long long t = HushModelLongLong(model, HushRecallTypeKeys());
    if (t != HUSH_MSG_TYPE_RECALL) return;
    long long mid = HushModelLongLong(model, HushRecallIdKeys());
    if (mid != LLONG_MIN && mid > 0 && HushRecallIsIntercepted(mid)) return;   // 我们吞过的走另一条还原链
    long long del = HushModelLongLong(model, @[@"deleteStatus"]);
    if (del == LLONG_MIN || del == 0) return;                                  // 已经洗干净了

    // 原类型早就没了：type=55 是宿主在撤回时盖上去的，原始 type 没有留档。
    // 只能从残留字段反推 —— image / destroyUrl 有值就是图，否则按文本处理。
    // (sel_index: GJIMMessageModel 上有 image @16@0:8 / destroyUrl @16@0:8 /
    //  imageType i16@0:8 / autoDestroy B16@0:8，没有 pic_url。)
    NSString *img  = HushModelString(model, @[@"image"]);
    NSString *durl = HushModelString(model, @[@"destroyUrl"]);
    NSString *body = HushModelString(model, @[@"content", @"selectedContent"]);
    BOOL isImage = (img.length > 0 || durl.length > 0);

    // 撤回态的三件套一起清：光改 type 不动 recallType / isSuperRecallTip，
    // 宿主照样可能按撤回气泡排版（v40 日志 TRUTH 里 rc=0 tip=0 是常态，
    // 但那是本机数据；别人的库里这两项可能是 1）。
    HushCallSetNumber(model, @selector(setDeleteStatus:), 0);
    HushCallSetNumber(model, @selector(setStatus:), 0);
    HushCallSetNumber(model, @selector(setRecallType:), 0);
    HushCallSetNumber(model, @selector(setIsSuperRecallTip:), 0);

    long long targetType;
    BOOL filled = NO;
    if (isImage) {
        targetType = 2;                       // 图片：按图渲染，不动正文
        HushCallSetNumber(model, @selector(setType:), targetType);
    } else {
        targetType = 1;                       // 文本
        HushCallSetNumber(model, @selector(setType:), targetType);
        if (body.length == 0) {
            // 正文服务端已删，本地也没留 —— 不塞兜底串就是一个空气泡（高度 0，看着像 bug）
            HushCallSetObject(model, @selector(setContent:), @"[历史消息已防撤回]");
            filled = YES;
        }
    }

    static int n = 0;
    n++;
    if (n <= 10) {
        NSString *line = [NSString stringWithFormat:
            @"[Hush][防撤回] WASH#%d mid=%lld type 55->%lld kind=%@ imgLen=%lu durlLen=%lu "
            @"bodyLen=%lu filled=%d",
            n, mid, targetType, isImage ? @"image" : @"text",
            (unsigned long)img.length, (unsigned long)durl.length,
            (unsigned long)body.length, filled ? 1 : 0];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
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
static const NSInteger kHushBurnTag      = 0x4F3A22;   // v41：「闪照」标记，挂在气泡图上

BOOL HushRecallModelWasIntercepted(id model) {
    if (!model) return NO;
    id v = objc_getAssociatedObject(model, &kHushInterceptedKey);
    if ([v boolValue]) return YES;
    // 包层拦下的那条消息，宿主根本没把它改成撤回态，模型上自然没有关联标记；
    // 只认 msgId 集合，这样 setMessage: 一被调用就能贴上角标。
    long long mid = HushModelLongLong(model, HushRecallIdKeys());
    return HushRecallIsIntercepted(mid);
}

// ===========================================================================
// P0-2b / S4 前置：把「撤回」在模型里的真值挖出来。
//
// 已知字段（sel_index 反查 GJIMMessageModel 的 213 个 selector）：
//   type              Q   55 = 撤回包
//   status            C   疑似 3 = 已撤回（v35 的还原逻辑按 3 兜底）
//   recallType        i   真值未验证
//   deleteStatus      C   真值未验证
//   isSuperRecallTip  B   超级撤回提示
//   闪照标记在 GJIMMessageModelExtra.time_limited_status（i），不在主模型上
//
// 三条通道都打：包层 / 同步（ScanArrayForRecall）/ 写库（RestoreDirtyArray）。
// 只有看到「同一条消息从 type=1&status=0 变成 type=1&status=X」才算抓到真正
// 要洗的目标 —— 那才是全量同步覆盖 push 抹白的机制。
//
// 独立出口（fprintf + HushLogger），不依赖 HushProbeEmit：后者定义在文件后半段，
// 而这里的调用点是写库入口（更靠前）。
// ===========================================================================
static int sTruthDumps = 0;
static int sShadowBatches = 0;   // v40：整批影子的丢弃次数（只报前 3 次，防刷屏）

// HushModelLongLong 拿不到字段时返回 LLONG_MIN。直接 %lld 会打出一串
// -9223372036854775808，看着像真值 —— 必须显式区分「没有这个字段」。
static NSString *HushNumStr(long long v) {
    return (v == LLONG_MIN) ? @"n/a" : [NSString stringWithFormat:@"%lld", v];
}

// 取任意对象字段（不像 HushModelLongLong 那样限定数值）。
static id HushRecallModelObject(id model, NSArray<NSString *> *keys) {
    if (!model) return nil;
    for (NSString *k in keys) {
        if (![model respondsToSelector:NSSelectorFromString(k)]) continue;
        @try {
            id v = [model valueForKey:k];
            if (v && ![v isKindOfClass:[NSNull class]]) return v;
        } @catch (__unused NSException *e) { }
    }
    return nil;
}

// 从 JSON 文本里抠一个整数 key。不做完整解析 —— 只在 msgExtraModel 为 nil 时
// 让探针仍能看到 time_limited_status 的值。找不到就返回 LLONG_MIN，
// 和「字段不存在」保持同一个哨兵，日志里统一显示 n/a。
static long long HushRecallJsonInt(NSString *json, NSString *key) {
    if (json.length == 0 || key.length == 0) return LLONG_MIN;
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange r = [json rangeOfString:needle];
    if (r.location == NSNotFound) return LLONG_MIN;

    NSUInteger i = NSMaxRange(r), n = json.length;
    while (i < n) {
        unichar c = [json characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++; else break;
    }
    if (i >= n || [json characterAtIndex:i] != ':') return LLONG_MIN;
    i++;
    while (i < n) {
        unichar c = [json characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
        else if (c == '\"') { i++; break; }      // 值可能是字符串 "1"
        else break;
    }
    BOOL neg = NO;
    if (i < n && [json characterAtIndex:i] == '-') { neg = YES; i++; }
    long long v = 0; BOOL any = NO;
    while (i < n) {
        unichar c = [json characterAtIndex:i];
        if (c < '0' || c > '9') break;
        v = v * 10 + (long long)(c - '0');
        any = YES; i++;
        if (v > 1000000000LL) break;             // 防溢出，探针不需要精确到那一步
    }
    if (!any) return LLONG_MIN;
    return neg ? -v : v;
}

// 定义在文件后段（:821），这里要用 —— 补上声明，别再靠隐式 int 返回值。
BOOL HushRecallIsIntercepted(long long mid);

static void HushRecallTruthDump(id obj, const char *where) {
    NSArray *arr = nil;
    if ([obj isKindOfClass:[NSArray class]]) arr = (NSArray *)obj;
    else if (obj) arr = @[obj];
    if (!arr || arr.count == 0) return;
    if (sTruthDumps >= 60) return;

    // v40 洗尘：msgId <= 0 的是宿主的影子更新对象，不是真实消息。
    // 它们在 v39a 日志里占了 TRUTH#1–#16（deleteStatus 恒 1、msgId 恒 0），
    // 既烧额度又让判据失灵。这里整批过滤 —— 一条额度都不占，也不进明细。
    NSMutableArray *real = [NSMutableArray arrayWithCapacity:arr.count];
    for (id m in arr) {
        long long mid0 = HushModelLongLong(m, HushRecallIdKeys());
        if (mid0 != LLONG_MIN && mid0 > 0) [real addObject:m];
    }
    if (real.count == 0) {
        if (sShadowBatches < 3) {
            sShadowBatches++;
            NSString *line = [NSString stringWithFormat:
                @"[P0-2b] SHADOW#%d where=%s 整批 %lu 条无 msgId（影子更新对象），整批跳过",
                sShadowBatches, where, (unsigned long)arr.count];
            fprintf(stderr, "%s\n", [line UTF8String]);
            [HushLogger logLevel:2 format:line];
        }
        return;
    }
    arr = real;

    // 判可疑。v40 收窄了判据。
    //
    // 老版把 status / deleteStatus 任意非 0 都算可疑，实测是错的：真消息的
    // status 普遍是 3 或 4（图片/文本的正常态），deleteStatus 又只在影子对象上
    // 是 1 —— 两者一叠加，等于「全都可疑」，判了跟没判一样。
    // 现在只认三件真事：撤回包、阅后即焚、被我们在包层吞过的那条。
    // 最后一条最要紧：它 status 仍是 0、type 仍是 1，光看字段永远不像撤回，
    // 只能靠 msgId 命中已拦截集合认出来。
    BOOL suspicious = NO;
    for (id m in arr) {
        long long t   = HushModelLongLong(m, HushRecallTypeKeys());
        long long rt  = HushModelLongLong(m, @[@"recallType"]);
        long long mid = HushModelLongLong(m, HushRecallIdKeys());
        if (t == HUSH_MSG_TYPE_RECALL
            || t == HUSH_MSG_TYPE_TIME_LIMITED
            || (rt != LLONG_MIN && rt != 0)
            || (mid != LLONG_MIN && mid > 0 && HushRecallIsIntercepted(mid))) {
            suspicious = YES;
            break;
        }
    }
    // 前两批无条件打：建立「正常消息长什么样」的基线。之后只打可疑批次。
    if (!suspicious && sTruthDumps >= 2) return;

    sTruthDumps++;

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:
        @"[P0-2b] TRUTH#%d where=%s arr=%lu suspicious=%d",
        sTruthDumps, where, (unsigned long)arr.count, suspicious ? 1 : 0]];

    NSUInteger lim = arr.count < 8 ? arr.count : 8;
    for (NSUInteger i = 0; i < lim; i++) {
        id m = arr[i];
        long long mid  = HushModelLongLong(m, HushRecallIdKeys());
        long long lid  = HushModelLongLong(m, HushRecallLocalIdKeys());
        long long t    = HushModelLongLong(m, HushRecallTypeKeys());
        // v41d（A4）：type 与 messageType 分开打原值，不兜底。
        // 光看兜底后的 t 无法判断「这个 model 上到底有没有 type」，
        // v41c 的 type=24 就是这么被误读成「普通图片类型」的。
        long long tr   = HushModelLLRaw(m, @"type");
        long long mt   = HushModelLLRaw(m, @"messageType");
        long long s    = HushModelLongLong(m, @[@"status"]);
        long long rt   = HushModelLongLong(m, @[@"recallType"]);
        long long ds   = HushModelLongLong(m, @[@"deleteStatus"]);
        long long st   = HushModelLongLong(m, @[@"isSuperRecallTip"]);
        long long sid  = HushModelLongLong(m, @[@"sessionId"]);
        long long from = HushModelLongLong(m, HushRecallFromKeys());
        long long ui   = HushModelLongLong(m, @[@"uiType"]);
        long long face = HushModelLongLong(m, @[@"o_face_status"]);
        long long exOv = HushModelLongLong(m, @[@"isExchangeOvertime"]);
        long long pt   = HushModelLongLong(m, @[@"promptType"]);
        BOOL intc      = (mid != LLONG_MIN && mid > 0 && HushRecallIsIntercepted(mid));

        // ---- 三层降级取闪照真值 ----
        // - msgExtraModel：宿主自己解析好的 GJIMMessageModelExtra
        //    （sel_index 确认它只有 5 个 selector：time_limited_status /
        //      time_limited_msg_read_time / gji_msgExtraModelDict + 两个 setter）
        // - msgExtra：没解析时的原始对象
        // - gji_msgExtraStr：JSON 字符串，直接从文本里抠 key
        id extraObj = HushRecallModelObject(m, @[@"msgExtraModel"]);
        id extraRaw = extraObj ? nil : HushRecallModelObject(m, @[@"msgExtra"]);

        NSString *extraStr = HushRecallModelString(m, @[@"gji_msgExtraStr"]);
        if (extraStr.length == 0 && extraRaw) {
            // msgExtra 可能是原始 dict / protobuf 对象 —— description 总比丢掉强。
            extraStr = [extraRaw isKindOfClass:[NSString class]]
                     ? (NSString *)extraRaw : [extraRaw description];
        }

        long long tls  = extraObj ? HushModelLongLong(extraObj, @[@"time_limited_status"])        : LLONG_MIN;
        long long tlrt = extraObj ? HushModelLongLong(extraObj, @[@"time_limited_msg_read_time"]) : LLONG_MIN;
        if (tls  == LLONG_MIN && extraStr.length) tls  = HushRecallJsonInt(extraStr, @"time_limited_status");
        if (tlrt == LLONG_MIN && extraStr.length) tlrt = HushRecallJsonInt(extraStr, @"time_limited_msg_read_time");

        [lines addObject:[NSString stringWithFormat:
            @"[P0-2b]   m[%lu] %@ mid=%@ lid=%@ sid=%@ from=%@ type=%@ "
            @"tr=%@ mt=%@ status=%@ "
            @"rc=%@ del=%@ tip=%@ ui=%@ face=%@ exOv=%@ pt=%@ "
            @"tls=%@ tlrt=%@ intc=%d exObj=%@ exLen=%lu",
            (unsigned long)i,
            NSStringFromClass([m class]),
            HushNumStr(mid), HushNumStr(lid), HushNumStr(sid), HushNumStr(from),
            HushNumStr(t), HushNumStr(tr), HushNumStr(mt), HushNumStr(s),

            HushNumStr(rt), HushNumStr(ds), HushNumStr(st),
            HushNumStr(ui), HushNumStr(face), HushNumStr(exOv), HushNumStr(pt),
            HushNumStr(tls), HushNumStr(tlrt),
            intc ? 1 : 0,
            extraObj ? NSStringFromClass([extraObj class]) : (extraRaw ? @"raw" : @"nil"),
            (unsigned long)extraStr.length]];

        // extra 原文单独一行：闪照标记可能藏在后半段，所以不再只截 120 字符。
        // 只在「有值」或「本批第一条」时打，控制体积。
        BOOL wantRaw = (extraStr.length > 0) && (tls != LLONG_MIN || i == 0);
        if (wantRaw) {
            NSString *show = extraStr;
            if (show.length > 400) show = [show substringToIndex:400];
            [lines addObject:[NSString stringWithFormat:
                @"[P0-2b]     m[%lu] extra=%@", (unsigned long)i, show]];
        }
    }

    if (arr.count > lim) {
        [lines addObject:[NSString stringWithFormat:
            @"[P0-2b]   …（本批共 %lu 条，只打前 %lu）",
            (unsigned long)arr.count, (unsigned long)lim]];
    }

    for (NSString *line in lines) {
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

// v37 摸底：把同步批次里的撤回消息数出来（不改数组、不改返回值）。
//
// 推送腿已经吞掉撤回包，但断网期间对方撤回、之后登录同步，宿主会走
// GJIMMessageService -p_handleSyncRangeMessages:syncType: 把历史消息重新灌进来 ——
// 那条 55 完全不经过 GJIMEngine 的包入口。先看它到底带不带 55，再决定要不要拦。
int HushRecallScanArrayForRecall(id arr) {
    if (![arr isKindOfClass:[NSArray class]]) return 0;
    HushRecallTruthDump(arr, "sync");       // P0-2b：同步通道真值
    int n = 0;
    for (id m in (NSArray *)arr) {
        long long t = HushModelLongLong(m, HushRecallTypeKeys());
        if (t != HUSH_MSG_TYPE_RECALL) continue;
        long long mid = HushModelLongLong(m, HushRecallIdKeys());
        n++;
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][防撤回] 同步通道里出现撤回消息 msgId=%lld（绕过包层吞包）", mid]];
    }
    return n;
}

// 锚点取值的统一入口：respondsToSelector 先挡、KVC 再兜 try。
// 只接受 UIView —— 有些 cell 的同名 getter 返回 NSNumber/NSString，不能当锚点。
static UIView *HushRecallViewByGetter(id obj, NSString *sel) {
    if (!obj || sel.length == 0) return nil;
    if (![obj respondsToSelector:NSSelectorFromString(sel)]) return nil;
    @try {
        id v = [obj valueForKey:sel];
        if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
    } @catch (__unused NSException *e) { }
    return nil;
}

// 角标锚点。原版锚在 imageContentView(150x200)，挂载层是 Cell 本身 ——
// 挂在 Cell 上而不是 contentView 上，才不会吃 contentView 的 clipsToBounds。
//
// v39 修的 bug：旧实现只找 imageContentView，而 sel_index 反查全库，
// 这个 selector 只存在于三个图片类：
//     BDChatRecentImageNewCell / BDMsgBigImageCell / BDChatImageCell
// 文本 cell（BDChatTextAndFaceCellPrivateOther）根本没有 —— 于是锚点恒为 nil，
// 调用方兜底贴 (8,4)，正好落在头像上方。真机上看到「角标飞到左边」就是这个。
//
// 现在的优先级链（每个名字都在 sel_index 里核对过是真的 selector）：
//     bubble            BDChatTextAndFaceCell(PrivateOther) —— 文本 / 文本+闪照的气泡本体
//     imageContentView  BDChatRecentImageNewCell / BDMsgBigImageCell / BDChatImageCell
//     bubbleView        BDDestoryChatCell 系 —— 独立闪照、视频
//     bubbleImgView     同上，气泡底图
// 全落空才走类名子树扫描，再落空交回调用方兜底。
static UIView *HushRecallAnchorView(id cell, UIView *host, NSString **outName) {
    NSString *cands[4] = { @"bubble", @"imageContentView",
                           @"bubbleView", @"bubbleImgView" };
    for (int i = 0; i < 4; i++) {
        UIView *v = HushRecallViewByGetter(cell, cands[i]);
        if (v && v != host) {
            if (outName) *outName = cands[i];
            return v;
        }
    }

    // 退一步：子树里按类名找 *BubbleView* / *imageContentView*（上限 60 个节点）
    NSMutableArray *stack = [NSMutableArray arrayWithObject:host];
    int guard = 0;
    while (stack.count > 0 && guard++ < 60) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        NSString *cn = NSStringFromClass([v class]);
        if ([cn rangeOfString:@"BubbleView"].location != NSNotFound
            || [cn rangeOfString:@"imageContentView"].location != NSNotFound) {
            if (outName) *outName = @"subview-scan";
            return v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// ===========================================================================
// v41：闪照 / 闪文解锁
// ===========================================================================
//
// 真值（v40 真机日志 21:30:54）：type=282 就是阅后即焚，跟 time_limited_status
// 没有关系 —— 那条消息 extra 里 tls=0 / tlrt=0，类型码照样是 282。宿主认的是
// 类型码 + Cell 类：BDDestoryChatCell（含 *PrivateOther 子类）负责渲染遮罩
// 「点击查看」，点开走 -showAutoDestroyImage: 再起倒计时销毁。
//
// 所以洗白不能靠改文案，得把遮罩摘掉、把倒计时掐死。
// sel_index 确认以下 ivar 全部挂在 BDDestoryChatCell 上（51 个 selector）：
//   destoryCellMaskView / destoryIconBtn / destoryAlterLab / bubbleImgView
// 注意 BDDestoryChatCellPrivateOther 自己 0 个 selector、全部继承 —— 不同子类的
// ivar 集合并不一致（_timer 只在 BDChatTextAndFaceCell 上），裸 valueForKey: 会抛
// NSUnknownKeyException 直接把 App 打死，所以每个取值都包 @try。

static id HushSafeKVC(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void HushHideView(id obj, BOOL hide) {
    if (![obj isKindOfClass:[UIView class]]) return;
    ((UIView *)obj).hidden = hide;
}

// v41: 闪照解锁总闸。
//
// 面板里「闪照转照片 / 闪文转普通消息」这两个键（switch_flash_photo /
// switch_flash_text）此前**一处读取都没有** —— 纯死键，点了没反应。这里接上：
// 两个都是「闪照变可反复查看」，任意一个开着就放行（用户开哪个说明他要那个）。
// 默认都是 NO，所以关着的时候行为跟原版一致，不会偷偷改宿主渲染。
static BOOL HushFlashUnlockOn(void) {
    HushConfig *c = [HushConfig shared];
    return [c isEnabled:@"switch_flash_photo"] || [c isEnabled:@"switch_flash_text"];
}

// v41d（A3）：「直接拆遮罩」是临时手段，不是解法，这里把它挂到独立开关后面
// 并默认关。
//
// v41c 真机事实：用户点白板「毫无反应，没放大也没卡死」。原因是
// HushAutoDestroyUnlock 把 _destoryIconBtn（就是那个「点击查看」按钮）也
// hidden 了 —— hidden 的 UIView 不参与 hitTest，触摸事件被整层吃掉。
// 拆遮罩不等于解锁，是把入口连同出口一起拆了。
//
// 所以这一步默认关：先让宿主恢复原状（点击能正常走），靠 A2 的点击回调探针
// 定位真正入口，再决定洗白的落点。switch_flash_thumb 是面板里既有的键，
// 此前同样是死键（全仓零读取）。
// v42：strip 的语义此前是反的 —— 开关一开就拆遮罩，结果拆出一块没有图的死
// 白板（v41d 真机实证：mask=y img=y 但模型上没有任何 URL；更糟的是
// _destoryIconBtn 被一起 hidden，点击入口也没了，所以「点了毫无反应」）。
//
// 正确语义：拆遮罩的唯一目的是「看图」，所以只有确实拿得到图时才拆：
//   - 模型上已有 image / destroyUrl / pic_url —— 拆了立刻能渲染
// 拿不到就返回 NO，保持宿主原样（「点击查看」按钮在），把入口留给点击探针。
// 本轮还没有任何一条闪照拿到过 URL（v41c/v41d 的 extra 全是空 URL），
// 所以这里事实上恒为 NO —— 这是预期行为，不是没生效。
static BOOL HushFlashStripOn(id model) {
    if (![[HushConfig shared] isEnabled:@"switch_flash_thumb"]) return NO;
    if (!model) return NO;
    return HushModelString(model, @[@"image", @"destroyUrl", @"pic_url", @"picUrl"]) != nil;
}

void HushAutoDestroyUnlock(id cell, id model) {
    if (!cell) return;

    // 三道闸，任意一道过就算闪照：
    //   - model.type == 282（宿主对新消息偶尔会用这个类型码）
    //   - cell 是 BDDestoryChatCell 子类（已销毁 / 待点开态）
    //   - cell 自己 respondsToSelector:isMask 且值为 YES（列表里被遮罩挡住的态，
    //     BDChatImageCell 系就是这样画的 —— 日志里 20 条 TAG 全是 BDChatImageCell*
    //     和 BDChatTextAndFaceCell*，一条 BDDestoryChatCell 都没有）
    // 三处都要认：宿主用哪个类渲染闪照是它自己的实现细节，只认一个必漏。
    long long t = model ? HushModelLongLong(model, HushRecallTypeKeys()) : LLONG_MIN;
    BOOL byType = (t == HUSH_MSG_TYPE_TIME_LIMITED);
    BOOL byCell = NO;
    Class dc = NSClassFromString(@"BDDestoryChatCell");
    if (dc && [cell isKindOfClass:dc]) byCell = YES;
    BOOL byMask = NO;
    if ([cell respondsToSelector:NSSelectorFromString(@"isMask")]) {
        id mv = HushSafeKVC(cell, @"isMask");
        if ([mv isKindOfClass:[NSNumber class]] && [mv boolValue]) byMask = YES;
    }
    if (!byType && !byCell && !byMask) return;

    BOOL unlockOn = HushFlashUnlockOn();
    BOOL strip    = HushFlashStripOn(model);

    // v41d（A1）：BURN# 提到闸门之后、开关之前 —— 只要命中就无条件打。
    //
    // v41c 版把日志放在函数末尾，前面任何一步提前 return（比如 img 不是 UIView）
    // 都会把它吞掉；而且它打的是「兜底后」的 type，看不出 type 与 messageType
    // 到底哪个有值 —— 用户就是靠那个 24 推出了错误的洗白目标类型。
    static int burnLogs = 0;
    burnLogs++;
    if (burnLogs <= 12 || (burnLogs % 10) == 0) {
        long long tRaw  = model ? HushModelLLRaw(model, @"type")        : LLONG_MIN;
        long long mtRaw = model ? HushModelLLRaw(model, @"messageType") : LLONG_MIN;
        // v42：BURN# 补 mid。此前 13 条 BURN 只能靠时间戳猜对应哪条消息，
        // 结果把「同一 mid 的两份 model 实例（282 与 24）」误读成「宿主改写 type」。
        long long midRaw = model ? HushModelLongLong(model, HushRecallIdKeys()) : LLONG_MIN;
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] BURN#%d cell=%@ cls=%@ mid=%@ t=%@ mt=%@ mix=%@ by=%@ "
            @"unlock=%d strip=%d mask=%@ img=%@ timer=%@",
            burnLogs,
            NSStringFromClass([cell class]),
            model ? NSStringFromClass([model class]) : @"nil",
            HushNumStr(midRaw),
            HushNumStr(tRaw), HushNumStr(mtRaw), HushNumStr(t),
            byType ? @"type282" : (byCell ? @"destoryCell" : @"isMask"),
            unlockOn ? 1 : 0, strip ? 1 : 0,
            HushSafeKVC(cell, @"_destoryCellMaskView") ? @"y" : @"n",
            HushSafeKVC(cell, @"_bubbleImgView") ? @"y" : @"n",
            HushSafeKVC(cell, @"_timer") ? @"y" : @"n"];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }

    if (!unlockOn) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            [HushLogger logLevel:2 format:
                @"[Hush][闪照] 命中闪照（type=282 / DestoryCell / isMask），但「闪照转照片 / "
                @"闪文转普通消息」都关着，不解锁（去面板打开任一项后重进会话）"];
        }
        return;
    }

    // 1. 倒计时。文本闪文在 BDChatTextAndFaceCell 上叫 _timer；
    //    图片闪照走 BDDestoryChatCell 的 videoPlayManager 那套。取不到就算了。
    id timer = HushSafeKVC(cell, @"_timer");
    if ([timer isKindOfClass:[NSTimer class]]) {
        [(NSTimer *)timer invalidate];
        @try { [cell setValue:nil forKey:@"_timer"]; }
        @catch (__unused NSException *e) {}
    }

    // 2. 拆遮罩 —— 只在 switch_flash_thumb 开着时才做（v41d 默认关）。
    //
    // 这里 set 了 hidden 的三样，少一样都不行：
    //   _destoryCellMaskView  半透明黑罩，盖在图上面
    //   _destoryIconBtn       就是「点击查看」那个按钮 —— **hidden 它的同时把
    //                         整颗 cell 的点击入口也拆了**，用户点下去毫无反应，
    //                         没放大也没卡死（v41c 真机原话）。这是 v41d 把它
    //                         关掉的直接原因。
    //   _destoryAlterLab      「点击查看闪照」那行提示文字
    // 顺序上先拿 img 再隐藏，因为 _bubbleImgView 拿不到时后面挂标要早退。
    if (!strip) return;

    id img = HushSafeKVC(cell, @"_bubbleImgView");
    HushHideView(HushSafeKVC(cell, @"_destoryCellMaskView"), YES);
    HushHideView(HushSafeKVC(cell, @"_destoryIconBtn"),      YES);
    HushHideView(HushSafeKVC(cell, @"_destoryAlterLab"),    YES);
    HushHideView(img, NO);

    // 3. 挂个「闪照」小标，让它自己说明身份 —— 否则用户会当普通图片看。
    if (![img isKindOfClass:[UIView class]]) return;
    UIView *container = (UIView *)img;
    UILabel *mark = nil;
    @try { mark = (UILabel *)[container viewWithTag:kHushBurnTag]; }
    @catch (__unused NSException *e) { mark = nil; }
    if (!mark) {
        mark = [[UILabel alloc] initWithFrame:CGRectZero];
        mark.tag = kHushBurnTag;
        mark.text = @"闪照";
        mark.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
        mark.textColor = [UIColor whiteColor];
        mark.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        mark.textAlignment = NSTextAlignmentCenter;
        mark.layer.cornerRadius = 3.0;
        mark.clipsToBounds = YES;
        mark.userInteractionEnabled = NO;
        [container addSubview:mark];
    }
    [mark sizeToFit];
    CGRect mf = mark.frame;
    mf.size.width  += 6.0;
    mf.size.height += 2.0;
    mf.origin.x = 4.0;
    mf.origin.y = 4.0;
    mark.frame = mf;
    mark.hidden = NO;
}

// v41: showAutoDestroyImage: 放行之后收尾。
//
// 「我让你展示，但我剥夺你销毁的权力」：%orig 必须走 —— 它负责真正解析/解密图片、
// 把内容铺到 _bubbleImgView 上。但它在内部会顺手起自己的销毁流程（重挂遮罩、
// 重开倒计时、把图换回模糊占位）。所以这里在 %orig 之后再把销毁面拆一遍。
//
// 不判 model 类型：这条 hook 只挂在 BDDestoryChatCell 上，能进来就说明是闪照。
// v40 日志确认 BDDestoryChatCellPrivateOther 自己 0 个 selector、51 个全继承父类，
// 所以 _destoryCellMaskView 等 KVC 会落到父类 ivar —— 但仍然每个都要 @try 兜。
void HushAutoDestroyKeepAlive(id cell) {
    if (!cell) return;
    if (!HushFlashUnlockOn()) return;   // 开关关着就让它正常销毁，别偷偷改宿主行为

    // v42：strip 现在要求「确实拿得到图」才拆，所以得先把 model 取出来。
    // showAutoDestroyImage: 是点开之后才调的，此刻 cell 上已经挂好 message。
    if (!HushFlashStripOn(HushSafeKVC(cell, @"message"))) return;

    id timer = HushSafeKVC(cell, @"_timer");
    if ([timer isKindOfClass:[NSTimer class]]) {
        [(NSTimer *)timer invalidate];
        @try { [cell setValue:nil forKey:@"_timer"]; }
        @catch (__unused NSException *e) {}
    }

    HushHideView(HushSafeKVC(cell, @"_destoryCellMaskView"), YES);
    HushHideView(HushSafeKVC(cell, @"_destoryIconBtn"),      YES);
    HushHideView(HushSafeKVC(cell, @"_destoryAlterLab"),    YES);
    HushHideView(HushSafeKVC(cell, @"_bubbleImgView"),       NO);

    static int keepLogs = 0;
    keepLogs++;
    if (keepLogs <= 10 || (keepLogs % 10) == 0) {
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] KEEP#%d cell=%@ mask=%@ img=%@ timer=%@（orig 已展示，销毁面已拆）",
            keepLogs, NSStringFromClass([cell class]),
            HushSafeKVC(cell, @"_destoryCellMaskView") ? @"y" : @"n",
            HushSafeKVC(cell, @"_bubbleImgView") ? @"y" : @"n",
            timer ? @"y" : @"n"];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

// 贴「已拦截」角标：挂 Cell 本身，锚气泡内侧左上角，9pt Medium 深灰字、无底色。
//
// v40 把底色 #407EFD + 白色粗体 10 号去掉了 —— 那是从原版抄来的常量，贴到浅色
// 气泡上像一块牌子，而且亮蓝比宿主自己的任何 UI 都跳。现在只留文字，靠字号和
// 灰度融进气泡。
//
// 挂载层刻意留在 Cell 上（而不是直接 addSubview 到气泡里）：
//   - viewWithTag: 的 owner 唯一，Cell 复用时不会叠出第二个标签；
//   - 不吃气泡自身的 clipsToBounds —— 气泡圆角 + masksToBounds 会把角标切掉；
//   - 宿主内部重建气泡视图时标签不受牵连。
// 锚点只用来算坐标：convertRect:toView:host 会跨层级换算，气泡藏在 contentView
// 里几层都不影响结果。
void HushRecallDecorateCell(id cell, id model) {
    if (!cell) return;
    UIView *host = [cell isKindOfClass:[UIView class]] ? (UIView *)cell : nil;
    if (!host) return;

    // P0-2b：屏幕上一出现就必中 —— 这是唯一 100% 拿得到活体 GJIMMessageModel 的
    // 入口。包层（HandlePrivatePackage）只有 PushPackage 没有模型；写库层
    // （dealMessage:array:）和同步层（p_handleSyncRangeMessages:syncType:）在
    // 「撤回包被吞、宿主完全不知情」时压根不会触发 —— v39 真机日志已证实两者
    // 的 hit 计数为 0，TRUTH# 一条都打不出来。
    HushRecallTruthDump(model, "ui");

    // v41：闪照先解锁，再走角标逻辑。
    // 放在 -ModelWasIntercepted 判断之前 —— 闪照不需要被我们拦截过，只要它是
    // type=282 就该洗白；如果放到后面，未被拦截的闪照永远进不来。
    HushAutoDestroyUnlock(cell, model);

    UILabel *tag = nil;
    @try { tag = (UILabel *)[host viewWithTag:kHushInterceptTag]; }
    @catch (__unused NSException *e) { tag = nil; }

    if (!HushRecallModelWasIntercepted(model)) {
        if (tag && !tag.hidden) tag.hidden = YES;   // 复用到普通消息时收起来
        return;
    }

    if (!tag) {
        tag = [[UILabel alloc] initWithFrame:CGRectZero];
        tag.tag = kHushInterceptTag;
        tag.text = @"已拦截";
        // v40：跟原生气泡一个调子。宿主自己极少用系统色，亮橙在气泡里尤其扎眼；
        // 改成无背景 + 9pt Medium 深灰字，看起来像气泡自带的角标而不是外挂。
        tag.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightMedium];
        tag.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        tag.backgroundColor = [UIColor clearColor];
        tag.textAlignment = NSTextAlignmentCenter;
        tag.userInteractionEnabled = NO;
        [tag sizeToFit];
        CGRect tf = tag.frame;
        tf.size.width += 2.0;   // 无背景，只留一点呼吸位，不给边框
        tf.size.height += 1.0;
        tag.frame = tf;
        [host addSubview:tag];
    } else if (tag.superview != host) {
        // 老版本可能把标签挂到了气泡上；统一收回 Cell，避免复用后两处各留一个。
        [tag removeFromSuperview];
        [host addSubview:tag];
    }

    // v40：锚点拿不到就不贴 —— 这是「角标飞到左上角」的唯一解。
    //
    // setMessage: 先在 BDChatBasicCell 基类上跑一遍，此时 Cell 还没被子类化，
    // BDChatTextAndFaceCellPrivateOther / BDChatImageCellPrivateOther 的锚点一个都
    // 拿不到。老版在这里兜底 (8,4)，画出来正好压在头像上方 —— v39a 日志
    // TAG#1 cell=BDChatBasicCell anchor=nil ok=0 tagFrame=(8.0,4.0,...) 就是它。
    // 宿主随后换成真子类重设 message，那一次锚点就有了，角标自然会贴对。
    NSString *anchorName = @"-";
    UIView *anchor = HushRecallAnchorView(cell, host, &anchorName);
    if (!anchor || anchor == host) {
        tag.hidden = YES;
        return;
    }

    tag.hidden = NO;
    CGRect a = [anchor convertRect:anchor.bounds toView:host];
    CGRect f = tag.frame;
    // v41：贴气泡最内侧左上角，内缩 6pt（v40 是 4pt）。
    // _bubbleImgView 是九宫格拉伸的 UIImageView，它的 bounds 比肉眼看到的气泡
    // 多出一圈透明边距 / 阴影，4pt 正好卡在视觉边缘上 —— 真机截图里看着「飞」。
    // 再往里推 2pt 就落在气泡可视区里了。
    // 相对气泡本身定位，不依赖 Cell 整宽，所以对方在左、己方在右两种气泡都成立。
    f.origin.x = CGRectGetMinX(a) + 6.0;
    f.origin.y = CGRectGetMinY(a) + 6.0;

    // 夹在 Cell 自身边界内，避免贴到屏幕外
    CGRect b = host.bounds;
    if (f.origin.x < 0.0) f.origin.x = 0.0;
    if (f.origin.y < 0.0) f.origin.y = 0.0;
    if (CGRectGetMaxX(f) > b.size.width) f.origin.x = b.size.width - f.size.width;
    if (CGRectGetMaxY(f) > b.size.height) f.origin.y = b.size.height - f.size.height;
    tag.frame = f;
    [host bringSubviewToFront:tag];

    // 角标一直是黑盒：贴没贴、贴哪、锚点拿到没，只能靠肉眼。这里一次打全。
    // 出口用 fprintf + HushLogger 而不是 HushProbeEmit —— 后者定义在本文件后半段，
    // 这里的调用点更靠前，直接调会撞未声明。
    static int tagLogs = 0;
    tagLogs++;
    if (tagLogs <= 20 || (tagLogs % 10) == 0) {
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] TAG#%d cell=%@ anchor=%@ name=%@ ok=%d "
            @"anchorRect=(%.1f,%.1f,%.1f,%.1f) tagFrame=(%.1f,%.1f,%.1f,%.1f) "
            @"cellH=%.1f",
            tagLogs,
            NSStringFromClass([cell class]),
            anchor ? NSStringFromClass([anchor class]) : @"nil",
            anchorName,
            anchor ? 1 : 0,
            (double)a.origin.x, (double)a.origin.y,
            (double)a.size.width, (double)a.size.height,
            (double)f.origin.x, (double)f.origin.y,
            (double)f.size.width, (double)f.size.height,
            (double)b.size.height];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

// 写库前还原：数组形态的写入口（GJIMDBService -dealMessage:array:）也照顾到。
void HushRecallRestoreDirtyArray(id obj) {
    if (!obj) return;
    HushRecallTruthDump(obj, "db-write");   // P0-2b：写库入口真值
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id m in (NSArray *)obj) {
            HushRestoreDirtyInPlace(m);
            HushHistoricalRecallPurify(m);   // v41：历史 55 洗白（switch_recall_history_purify 控制）
        }
        return;
    }
    HushRestoreDirtyInPlace(obj);
    HushHistoricalRecallPurify(obj);
}

#pragma mark - 包层：在数据流源头吞掉撤回包（v36）

// 原版的做法（hooo1 对照日志 23:39:10，同一毫秒四行）：
//
//   GJIMEngine.handleingGRPCPrivatePackage PushPackage messageType=55 type=0 messageId=75 …
//   [Chat] 撤回通知到达 type=55（普通撤回）
//   [Chat][防撤回] ★ 已提示拦截（Toast）msgId=75
//   [Chat] 已拦截撤回（吞掉 type=55 推送包）msgId=75 sessionId=… from=…
//
// 它既不写库、也不改 updateMessages: 的数组，而是在「宿主还没解析出模型」的入口
// 直接不往下传。宿主从此完全不知道发生过撤回：内存列表、本地库、行 diff 全是
// 原样，所以既不需要退出重进，也不会出现空白气泡。
//
// 这一层取代了 v34/v35 的「改 type + 拦 p_updateMessage」，那两条腿留在代码里
// 只作为 A/B 诊断（switch_ar_db_block / switch_ar_ui_block 现已默认关闭）。

static NSMutableSet *sInterceptedIds = nil;
static NSLock *sInterceptedLock = nil;
static BOOL sPackageShapeLogged = NO;

static NSLock *HushInterceptLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sInterceptedLock = [[NSLock alloc] init]; });
    return sInterceptedLock;
}

void HushRecallMarkIntercepted(long long mid) {
    if (mid <= 0) return;
    NSLock *l = HushInterceptLock();
    [l lock];
    if (!sInterceptedIds) sInterceptedIds = [[NSMutableSet alloc] init];
    [sInterceptedIds addObject:@(mid)];
    [l unlock];
}

BOOL HushRecallIsIntercepted(long long mid) {
    if (mid <= 0) return NO;
    NSLock *l = HushInterceptLock();
    [l lock];
    BOOL hit = [sInterceptedIds containsObject:@(mid)];
    [l unlock];
    return hit;
}

// PushPackage 是 protobuf 生成的类，字段名以原版日志的打印为准：
// `PushPackage messageType=2 type=0 messageId=75 sess=<len=8,…> from=<len=8,…> extra{…}`。
// 注意 type 与 messageType 是两个不同字段 —— 撤回看的是 messageType。
static NSArray<NSString *> *HushPktTypeKeys(void) { return @[@"messageType", @"type"]; }
static NSArray<NSString *> *HushPktFromKeys(void) { return @[@"from", @"fromId", @"senderId", @"uid"]; }
static NSArray<NSString *> *HushPktIdKeys(void)   { return @[@"messageId", @"msgId", @"msgLocalId"]; }
static NSArray<NSString *> *HushPktSessKeys(void) { return @[@"sess", @"sessionId", @"to"]; }

// 首次见到包对象时把它到底有哪些字段打一次。原版没告诉我们类名与字段布局，
// 这一行是「下一个版本该按哪个 key 读」的唯一依据。
static void HushPktLogShapeOnce(id pkg) {
    if (sPackageShapeLogged || !pkg) return;
    sPackageShapeLogged = YES;
    NSMutableString *keys = [NSMutableString string];
    NSArray *probe = @[@"messageType", @"type", @"messageId", @"msgId", @"from",
                       @"fromId", @"sess", @"sessionId", @"extra", @"status",
                       @"recallType", @"is_super_recall", @"content"];
    for (NSString *k in probe) {
        [keys appendFormat:@"%@=%@ ", k, HushModelHasKey(pkg, k) ? @"y" : @"n"];
    }
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][防撤回] 包对象形状 %@ | %@", NSStringFromClass([pkg class]), keys]];
}

#pragma mark - 包层：提示与气泡刷新

static UIWindow *HushRecallKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in [app windows]) { if (w.isKeyWindow) return w; }
    NSArray *all = [app windows];
    return all.count > 0 ? (UIWindow *)[all firstObject] : nil;
}

// 一条轻提示（原版是 Toast）。只用 UIKit 最小集，全部包在 @try 里：提示失败
// 绝不能连累消息链路。
static void HushRecallToast(NSString *text) {
    if (text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = HushRecallKeyWindow();
            if (!win) return;

            UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
            lab.text = text;
            lab.font = [UIFont boldSystemFontOfSize:13.0];
            lab.textColor = [UIColor whiteColor];
            lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
            lab.textAlignment = NSTextAlignmentCenter;
            lab.numberOfLines = 1;
            lab.layer.cornerRadius = 14.0;
            lab.layer.masksToBounds = YES;
            [lab sizeToFit];
            CGRect f = lab.frame;
            f.size.width += 28.0;
            f.size.height = 28.0;
            f.origin.x = (win.bounds.size.width - f.size.width) / 2.0;
            f.origin.y = win.bounds.size.height * 0.22;
            lab.frame = f;
            lab.alpha = 0.0;
            [win addSubview:lab];
            [UIView animateWithDuration:0.18 animations:^{ lab.alpha = 1.0; }
                             completion:^(BOOL done) {
                [UIView animateWithDuration:0.35 delay:1.1 options:0 animations:^{
                    lab.alpha = 0.0;
                } completion:^(BOOL d2) { [lab removeFromSuperview]; }];
            }];
        } @catch (__unused NSException *e) { }
    });
}

// ===========================================================================
// P0-2b：只认聊天表
//
// v38 真机证据（20:15:25.812）：
//   [P0-2a] TABLE cls=UITableView cells=9
//   [P0-2a] CELL BDSessionCell getter=0 setter=0 imp=nil
// 旧实现在 6 层父链全落空后，从 rootVC.view 起做限深 BFS，返回「第一个碰到的
// UITableView」—— 那是会话列表的裸 UITableView。它的 cell 是 BDSessionCell，
// 没有 message，所以 painted 恒为 0；更糟的是在别人的表上 reloadRowsAtIndexPaths
// 会撞宿主的批量 update（该表 ivar 里有 _currentUpdate / _updateCount）。
//
// 真值（sel_index 121653 条反查）：
//   LiveMessagesView          : tableView / setTableView:  ← 唯一持有聊天表的容器；
//                               它是 UIView，不在 VC 父链上，所以父链永远找不到它
//   BDMessageTableView        : 6 个 selector（reloadData 等）—— 聊天表本体
//   PrivateChatViewController : 385 个 selector 里没有 tableView getter
//
// 定位顺序：LiveMessagesView(类名 + tableView) → BDMessageTableView(严格类名)。
// 任何一步都不再返回裸 UITableView —— 宁可 nil，也不在别人的表上动手。
// ===========================================================================

static Class HushMsgTableClass(void) {
    static Class c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"BDMessageTableView"); });
    return c;
}

static Class HushLiveMsgsClass(void) {
    static Class c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"LiveMessagesView"); });
    return c;
}

// 收口：接受任意 id，只放行「确实是聊天表」的那一个。
// BDMessageTableView 类不存在时（宿主改名 / 懒加载未触发）退化为普通 UITable-
// View 判断 —— 那是已知的降级，会被调用方日志标记出来。
static UITableView *HushAsMsgTable(id t) {
    if (!t) return nil;
    if (![t isKindOfClass:[UITableView class]]) return nil;
    Class mc = HushMsgTableClass();
    if (mc && ![t isKindOfClass:mc]) return nil;
    return (UITableView *)t;
}

// 限深限节点捞 LiveMessagesView 实例。缓存不存在的类 → 直接空数组。
static NSArray<UIView *> *HushFindLiveMessagesViews(UIView *root, int maxDepth, int maxNodes) {
    NSMutableArray *out = [NSMutableArray array];
    Class lv = HushLiveMsgsClass();
    if (!root || !lv) return out;

    NSMutableArray *layer = [NSMutableArray arrayWithObject:root];
    int seen = 0;
    BOOL stop = NO;
    for (int d = 0; d <= maxDepth && layer.count > 0 && !stop; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *v in layer) {
            if (seen >= maxNodes) { stop = YES; break; }
            seen++;
            if ([v isKindOfClass:lv]) [out addObject:v];
            [next addObjectsFromArray:v.subviews];
        }
        layer = next;
    }
    return out;
}

// 限深限节点捞 BDMessageTableView。
static UITableView *HushFindMsgTable(UIView *root, int maxDepth, int maxNodes) {
    Class mc = HushMsgTableClass();
    if (!root || !mc) return nil;

    NSMutableArray *layer = [NSMutableArray arrayWithObject:root];
    int seen = 0;
    BOOL stop = NO;
    for (int d = 0; d <= maxDepth && layer.count > 0 && !stop; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *v in layer) {
            if (seen >= maxNodes) { stop = YES; break; }
            seen++;
            if ([v isKindOfClass:mc]) return (UITableView *)v;
            [next addObjectsFromArray:v.subviews];
        }
        layer = next;
    }
    return nil;
}

// LiveMessagesView.tableView，且必须过 HushAsMsgTable 的类校验。
static UITableView *HushTableFromLiveView(UIView *lv) {
    if (!lv) return nil;
    id t = nil;
    if ([lv respondsToSelector:NSSelectorFromString(@"tableView")]) {
        @try { t = [lv valueForKey:@"tableView"]; } @catch (__unused NSException *e) { t = nil; }
    }
    if (!t) {
        Ivar iv = class_getInstanceVariable([lv class], "_tableView");
        if (iv) t = object_getIvar(lv, iv);
    }
    return HushAsMsgTable(t);
}

static UIViewController *HushRecallTopViewController(void) {
    UIWindow *win = HushRecallKeyWindow();
    UIViewController *vc = win.rootViewController;
    while (vc && vc.presentedViewController) vc = vc.presentedViewController;

    for (int i = 0; i < 6 && vc; i++) {
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *t = (UITabBarController *)vc;
            vc = t.selectedViewController ?: [[t viewControllers] firstObject];
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *n = (UINavigationController *)vc;
            vc = n.topViewController ?: [[n viewControllers] lastObject];
            continue;
        }
        if ([vc isKindOfClass:[UISplitViewController class]]) {
            UISplitViewController *sp = (UISplitViewController *)vc;
            vc = [[sp viewControllers] lastObject];
            continue;
        }
        NSArray *kids = [vc childViewControllers];
        if (kids.count == 0) break;
        vc = [kids lastObject];
    }
    return vc;
}

// 当前聊天页的表。四段式：
//   ① 父链 6 层，每层先试 VC 自己的 tableView 属性 / _tableView ivar；
//   ② 同一层 VC 的子视图中找 LiveMessagesView，取它的 tableView；
//   ③ 同一层 VC 的子视图中直接找 BDMessageTableView（深度 6）；
//   ④ 整个 keyWindow（浮层 / 二级容器）再扫一遍。
// 全部落空返回 nil —— 绝不再兜到「第一个 UITableView」。
static UITableView *HushRecallChatTable(void) {
    UIViewController *top = HushRecallTopViewController();
    UIWindow *win = HushRecallKeyWindow();

    UIViewController *vc = top;
    for (int i = 0; i < 6 && vc; i++, vc = [vc parentViewController]) {
        @try {
            if ([vc respondsToSelector:NSSelectorFromString(@"tableView")]) {
                UITableView *t = HushAsMsgTable([vc valueForKey:@"tableView"]);
                if (t) return t;
            }
        } @catch (__unused NSException *e) { }

        Ivar iv = class_getInstanceVariable([vc class], "_tableView");
        if (iv) {
            UITableView *t = HushAsMsgTable(object_getIvar(vc, iv));
            if (t) return t;
        }

        UIView *rv = [vc view];
        for (UIView *lv in HushFindLiveMessagesViews(rv, 4, 400)) {
            UITableView *t = HushTableFromLiveView(lv);
            if (t) return t;
        }

        UITableView *t3 = HushFindMsgTable(rv, 6, 600);
        if (t3) return t3;
    }

    if (win) {
        for (UIView *lv in HushFindLiveMessagesViews(win, 6, 800)) {
            UITableView *t = HushTableFromLiveView(lv);
            if (t) return t;
        }
        UITableView *t = HushFindMsgTable(win, 8, 1500);
        if (t) return t;
    }

    return nil;
}

#pragma mark - P0-2a 探针（临时，出结论后收敛成 P0-2b）

// 直调 getter，完全不碰 KVC。
// KVC 的 valueForKey: 在 cell 的 message 是 weak / 返回非 NSObject 包装 /
// ivar 名与属性名不一致时会抛或返回 nil，而原代码用 @catch 吞掉异常后就
// 得到 painted=0 —— 这正是这次要证伪的假设。
static id HushProbeGet(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    IMP imp = [obj methodForSelector:s];
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(obj, s);
}

// 探针统一出口：stderr 给控制台明文，HushLogger 给磁盘。
// iOS 会把 NSLog 的每个格式参数替换成 <private>，NSLog 等于废的。
// level 2(W) 而非 3(I)：loadLevelFromConfig 在关日志时把 gHushLogLevel 压到 3，
// level 3 刚好卡在边界，2 更稳，且 E/W/I 会立刻 flush 出 64KB 缓冲。
static void HushProbeEmit(NSString *s) {
    if (![s length]) return;
    fprintf(stderr, "%s\n", [s UTF8String]);
    [HushLogger logLevel:2 format:s];
}

// 动态扫 ivar。不硬编码 _isInBatchUpdate —— 这个名字在不同 iOS / 宿主版本
// 之间会变（_inBatchUpdate / _updateCount / _batchUpdateDepth / _animating）。
static NSString *HushProbeIvars(Class cls) {
    if (!cls) return @"<nil class>";

    NSMutableArray *hits = [NSMutableArray array];
    NSMutableArray *all  = [NSMutableArray array];
    unsigned int total = 0;

    // 扫自己 + 最多两层父类。子类常把 ivar 全放在父类上 ——
    // BDDestoryChatCellPrivateOther 自家 0 个，全在 BDDestoryChatCell（51 个 selector）。
    // 只看自己那一层会打出 <no ivars>，等于什么都没看到。
    Class cur = cls;
    for (int depth = 0; depth < 3 && cur && cur != [NSObject class]; depth++) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cur, &n);
        if (ivs) {
            for (unsigned int i = 0; i < n && total < 60; i++, total++) {
                const char *nm = ivar_getName(ivs[i]);
                const char *tp = ivar_getTypeEncoding(ivs[i]);
                NSString *name = nm ? [NSString stringWithUTF8String:nm] : @"?";
                [all addObject:[NSString stringWithFormat:@"%@:%s", name, tp ? tp : "?"]];
                NSString *low = [name lowercaseString];
                if ([low containsString:@"batch"] || [low containsString:@"update"] ||
                    [low containsString:@"anim"]) {
                    [hits addObject:name];
                }
            }
            free(ivs);
        }
        cur = [cur superclass];
    }

    if (total == 0) return @"<no ivars>";

    return [NSString stringWithFormat:@"{batch/update=%@ total=%u} %@%@",
            [hits count] ? [hits componentsJoinedByString:@","] : @"-",
            total,
            [all componentsJoinedByString:@" "],
            total >= 60 ? @" …" : @""];
}

static NSString *HushProbeScene(UIWindow *win) {
    if (!win) return @"no-window";
    NSString *act = @"pre-iOS13";
    if (@available(iOS 13.0, *)) {
        UIWindowScene *sc = win.windowScene;
        if (!sc) {
            act = @"windowScene=nil";
        } else {
            switch (sc.activationState) {
                case UISceneActivationStateForegroundActive:   act = @"fgActive";   break;
                case UISceneActivationStateForegroundInactive: act = @"fgInactive"; break;
                case UISceneActivationStateBackground:         act = @"bg";         break;
                case UISceneActivationStateUnattached:         act = @"unattached"; break;
                default:                                       act = @"unknown";    break;
            }
        }
    }
    return [NSString stringWithFormat:@"%@ hidden=%d alpha=%.2f level=%.0f",
            act, (int)win.hidden, (double)win.alpha, (double)win.windowLevel];
}

// 视图树摘要：类名 + 每层节点数 + 有没有 UITableView / BDMessageTableView /
// LiveMessagesView。深度与节点双限，避免一屏几十个 view 把日志撑爆。
// 标记：<T>=UITableView  <MT>=BDMessageTableView  <LV>=LiveMessagesView
static NSString *HushProbeViewTree(UIView *root, int maxDepth, int maxNodes) {
    if (!root) return @"<nil view>";
    Class mc = HushMsgTableClass();
    Class lv = HushLiveMsgsClass();

    NSMutableString *sb = [NSMutableString string];
    NSMutableArray *layer = [NSMutableArray arrayWithObject:root];
    int seen = 0, tables = 0, msgTables = 0, lives = 0, deepest = 0;
    BOOL stop = NO;

    for (int d = 0; d <= maxDepth && layer.count > 0 && !stop; d++) {
        NSMutableArray *next = [NSMutableArray array];
        [sb appendFormat:@"\n        d%d:", d];
        for (UIView *v in layer) {
            if (seen >= maxNodes) { [sb appendString:@" …"]; stop = YES; break; }
            seen++;
            NSString *cn = NSStringFromClass([v class]);
            BOOL isT = [v isKindOfClass:[UITableView class]];
            BOOL isM = mc ? [v isKindOfClass:mc] : NO;
            BOOL isL = lv ? [v isKindOfClass:lv] : NO;
            if (isT) tables++;
            if (isM) msgTables++;
            if (isL) lives++;
            if (d > deepest) deepest = d;
            [sb appendFormat:@" %@%@%@%@", cn,
                isT ? @"<T>" : @"", isM ? @"<MT>" : @"", isL ? @"<LV>" : @""];
            [next addObjectsFromArray:v.subviews];
        }
        layer = next;
    }

    return [NSString stringWithFormat:
        @"(nodes=%d deepest=%d tables=%d msgTables=%d live=%d)%@",
        seen, deepest, tables, msgTables, lives, sb];
}

// 拿不到聊天表时的全方位诊断。前 3 次全打，之后每 20 次一次 ——
// 没有它，Q1「人在聊天页却返回 nil」永远只能靠猜。
static void HushProbeChatTableMiss(void) {
    static int n = 0;
    n++;
    // 新定位链在「不在聊天页」时也会返回 nil（旧实现在那种情况返回错的表），
    // 所以 nil 会变成常态而非异常 —— 必须限总量，否则一晚上几万行树 dump。
    if (n > 40) return;                      // 总上限
    if (n > 3 && (n % 5) != 0) return;       // 前 3 次全打，之后每 5 次一次

    UIViewController *top = HushRecallTopViewController();
    UIWindow *win = HushRecallKeyWindow();
    UIViewController *rootVC = [win rootViewController];

    NSMutableArray *chain = [NSMutableArray array];
    for (UIViewController *v = top; v && chain.count < 8; v = [v parentViewController]) {
        [chain addObject:NSStringFromClass([v class])];
    }

    NSMutableString *perVC = [NSMutableString string];
    for (UIViewController *v = top; v; v = [v parentViewController]) {
        UIView *rv = [v view];
        NSUInteger nLive = [HushFindLiveMessagesViews(rv, 6, 600) count];
        NSUInteger nMsg  = HushFindMsgTable(rv, 6, 600) ? 1 : 0;
        [perVC appendFormat:@" %@(msgTbl=%lu live=%lu)",
            NSStringFromClass([v class]), (unsigned long)nMsg, (unsigned long)nLive];
    }

    HushProbeEmit([NSString stringWithFormat:
        @"[P0-2b] NIL#%d top=%@ chain=[%@] win=%@ scene=[%@] msgTableCls=%@ liveCls=%@",
        n,
        top ? NSStringFromClass([top class]) : @"<nil>",
        [chain componentsJoinedByString:@" > "],
        win ? NSStringFromClass([win class]) : @"<nil>",
        HushProbeScene(win),
        HushMsgTableClass() ? NSStringFromClass(HushMsgTableClass()) : @"<NSClassFromString=nil>",
        HushLiveMsgsClass() ? NSStringFromClass(HushLiveMsgsClass()) : @"<NSClassFromString=nil>"]);

    HushProbeEmit([NSString stringWithFormat:@"[P0-2b] NIL#%d perVC:%@", n, perVC]);

    if (top) {
        HushProbeEmit([NSString stringWithFormat:@"[P0-2b] NIL#%d topVC.view-tree %@",
            n, HushProbeViewTree([top view], 6, 160)]);
    }

    if (rootVC && [rootVC view] && [rootVC view] != [top view]) {
        HushProbeEmit([NSString stringWithFormat:@"[P0-2b] NIL#%d rootVC(%@).view-tree %@",
            n, NSStringFromClass([rootVC class]),
            HushProbeViewTree([rootVC view], 8, 260)]);
    }
}

static void HushRecallDecorateVisibleCells(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UITableView *table = HushRecallChatTable();
            if (!table || !table.window) {
                [HushLogger logLevel:2 format:
                    @"[Hush][防撤回] 找不到聊天表（可能已离开聊天页），本轮不贴角标"];
                // P0-2b：nil 分支必须留证 —— 否则「人在聊天页却返回 nil」只能靠猜。
                HushProbeChatTableMiss();
                return;
            }

            NSArray *cells = [table visibleCells];
            NSArray *vis   = [table indexPathsForVisibleRows];
            UIWindow *win  = table.window;

            // 整表快照，只打一次。dispatch_once 放在 window 判空之后 ——
            // 否则第一次巡检时不在聊天页就会把 once 白白吃掉，探针永远打不出来。
            static dispatch_once_t onceTable;
            dispatch_once(&onceTable, ^{
                HushProbeEmit([NSString stringWithFormat:
                    @"[P0-2a] TABLE cls=%@ win=%@ scene=[%@] sections=%ld "
                    @"visRows=%lu cells=%lu off=%.1f adj=%.1f",
                    NSStringFromClass([table class]),
                    NSStringFromClass([win class]),
                    HushProbeScene(win),
                    (long)[table numberOfSections],
                    (unsigned long)[vis count],
                    (unsigned long)[cells count],
                    (double)table.contentOffset.y,
                    (double)table.contentInset.top]);
                HushProbeEmit([NSString stringWithFormat:
                    @"[P0-2a] TABLE-IVARS %@", HushProbeIvars([table class])]);
            });

            // 按 cell 类名逐个 dump，每类一次。一屏里通常混着文本 cell、
            // 系统 cell、时间分隔 cell —— 只有逐类看才知道 painted=0 是
            // 「某一类没有 message getter」还是「全部都没有」。
            static NSMutableSet *seen = nil;   // 只在主队列访问，无需加锁
            if (!seen) seen = [NSMutableSet set];

            NSUInteger paintedKVC = 0, paintedIMP = 0;

            for (UITableViewCell *c in cells) {
                Class cc = [c class];
                NSString *cname = NSStringFromClass(cc);

                if (![seen containsObject:cname]) {
                    [seen addObject:cname];

                    BOOL hasGet = [c respondsToSelector:NSSelectorFromString(@"message")];
                    BOOL hasSet = [c respondsToSelector:NSSelectorFromString(@"setMessage:")];

                    id kvc = nil;
                    NSString *kvcErr = @"-";
                    @try {
                        if (hasGet) kvc = [c valueForKey:@"message"];
                    } @catch (NSException *e) {
                        kvcErr = e.name ?: @"exception";
                    }
                    id impVal = hasGet ? HushProbeGet(c, @"message") : nil;

                    HushProbeEmit([NSString stringWithFormat:
                        @"[P0-2a] CELL %@ super=%@ getter=%d setter=%d "
                        @"kvc=%@(err=%@) imp=%@ idx=%@",
                        cname,
                        NSStringFromClass([cc superclass]),
                        (int)hasGet, (int)hasSet,
                        kvc    ? NSStringFromClass([kvc class])    : @"nil",
                        kvcErr,
                        impVal ? NSStringFromClass([impVal class]) : @"nil",
                        [table indexPathForCell:c]]);
                    HushProbeEmit([NSString stringWithFormat:
                        @"[P0-2a] CELL-IVARS %@ %@", cname, HushProbeIvars(cc)]);
                }

                // 两条取值路径并行统计，直接对比命中率
                @try {
                    if ([c respondsToSelector:NSSelectorFromString(@"message")]) {
                        if ([c valueForKey:@"message"]) paintedKVC++;
                    }
                } @catch (__unused NSException *e) { }

                id m = HushProbeGet(c, @"message");
                if (m) {
                    paintedIMP++;
                    HushRecallDecorateCell(c, m);
                }
            }

            // 每批汇总，节流 5 次。reloadRowsAtIndexPaths 已删除：原 :814-818
            // 那段本来就是冗余的第二次重画（:799 的遍历已经画完），且与宿主
            // 批量 updateType 撞车会 "Invalid update" 崩。
            static int summaries = 0;
            if (summaries < 5) {
                summaries++;
                HushProbeEmit([NSString stringWithFormat:
                    @"[P0-2a] SUMMARY#%d cells=%lu painted_kvc=%lu painted_imp=%lu",
                    summaries,
                    (unsigned long)[cells count],
                    (unsigned long)paintedKVC,
                    (unsigned long)paintedIMP]);
            }

        } @catch (__unused NSException *e) {
            [HushLogger logLevel:2 format:
                @"[Hush][防撤回] 巡检聊天表时异常，已忽略（不影响消息本身）"];
        }
    });
}

#pragma mark - 包层入口

BOOL HushRecallHandlePrivatePackage(id self, SEL _cmd, id pkg, void (*orig)(id, SEL, id)) {
    (void)self; (void)_cmd; (void)orig;

    if (!pkg) return NO;
    HushPktLogShapeOnce(pkg);

    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]) return NO;
    if (![[HushConfig shared] isEnabled:@"switch_ar_packet_block"]) return NO;

    long long t = HushModelLongLong(pkg, HushPktTypeKeys());
    if (t != HUSH_MSG_TYPE_RECALL) return NO;       // 只处理撤回包，其它一律放行

    long long mid  = HushModelLongLong(pkg, HushPktIdKeys());
    long long from = HushModelLongLong(pkg, HushPktFromKeys());
    long long sid  = HushModelLongLong(pkg, HushPktSessKeys());
    long long me   = HushRecallCurrentUid();

    // 与自己撤回 / 登录态未知同一条口径：拿不准就放行（原版也是这么写的：
    // `撤回包来自自己（from=100938367），放行` / `登录态不可用（me=0），按 fail-safe 放行不拦`）。
    if (me == 0) {
        [HushLogger logLevel:2 format:
            @"[Hush][防撤回] 收到撤回包但登录态未知（me=0）→ fail-safe 放行不吞"];
        return NO;
    }
    if (from == me) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][防撤回] 撤回包来自自己（from=%lld），放行", from]];
        return NO;
    }
    if (mid <= 0) {
        [HushLogger logLevel:2 format:
            @"[Hush][防撤回] 撤回包读不到 messageId → 无法记账，放行"];
        return NO;
    }

    // 命中缓存 → 仍然吞掉，但不再记账、不再弹 Toast、不再重画。
    // 实测证据：msgId=15 在 20:14:44 与 20:15:25 各来一次（间隔 41 秒）。
    if (HushRecallIsIntercepted(mid)) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][防撤回] 命中缓存，跳过重推 msgId=%lld sessionId=%lld（仍吞，不弹窗不重画）",
            mid, sid]];
        return YES;                                  // 仍然不调 orig
    }

    sBlocked++;
    HushRecallMarkIntercepted(mid);
    HushAntiRevokeRecordBlocked(sid, 0, mid, HUSH_MSG_TYPE_RECALL, @"");
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][防撤回] ★ 吞掉撤回包 msgId=%lld sessionId=%lld from=%lld（宿主不知情，消息原样保留）",
        mid, sid, from]];
    if ([[HushConfig shared] isEnabled:@"switch_ar_toast"]) {
        HushRecallToast(@"已拦截一条撤回");
    }
    HushRecallDecorateVisibleCells();
    return YES;                                      // 关键：不调 orig
}

// 探针：宿主自己也有一个「这条包要不要拦」的判断（GJIMEngine -p_checkIfNeedBlockPackage:）。
// 只记录、不改返回值 —— 先看它平时判什么，再决定下一版能不能借它。
void HushRecallProbeBlockDecision(id pkg, BOOL verdict) {
    if (!pkg) return;
    long long t = HushModelLongLong(pkg, HushPktTypeKeys());
    long long mid = HushModelLongLong(pkg, HushPktIdKeys());
    static int n = 0;
    n++;
    if (!verdict && t != HUSH_MSG_TYPE_RECALL && n > 5) return;   // 正常包不刷屏
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][防撤回] 宿主自负判断 p_checkIfNeedBlockPackage → %d（type=%lld msgId=%lld，第 %d 次）",
        verdict ? 1 : 0, t, mid, n]];
}

#pragma mark - 四个入口

// addMessages:（内存）
void HushRecallFilterAndForward(id self, SEL _cmd, id msgs,
                                void (*orig)(id, SEL, id)) {
    if (!orig) return;

    // v37：包层吞包开着（默认开）时这条老腿完全让路。宿主根本收不到撤回包，
    // 这里再改类型只会制造第二套状态 —— 保留实现仅为排障时手动开回去。
    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]
        || [[HushConfig shared] isEnabled:@"switch_ar_packet_block"]
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
    // v37：包层吞包开着时 DB 腿不作主 —— 宿主压根不会发起把消息写成撤回态的写库。
    BOOL packetLeg = [[HushConfig shared] isEnabled:@"switch_ar_packet_block"];

    if (on && blockDb && !packetLeg) {
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
        || [[HushConfig shared] isEnabled:@"switch_ar_packet_block"]
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
        && [[HushConfig shared] isEnabled:@"switch_ar_ui_block"]
        && ![[HushConfig shared] isEnabled:@"switch_ar_packet_block"]) {
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
