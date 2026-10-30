// BluedHushREA v6 —— 纯 ObjC Runtime Hook 版（零 Logos、零 CydiaSubstrate、非越狱自签 + LiveContainer）
// 目标: com.danlan.xiaolan (Blued 7.50.3) / iOS 14.0+ / arm64 + arm64e
//
// ============================================================================
// v8 变更（真机日志 D:\...\BluedHushREA.log + 屏幕报告实证：ctor 装上 34 条 / MISS 只剩 2）
//   日志关键行：
//     pass[ctor]  ok=34 miss=2 (total ok=34)
//     pass[main+2s] ok=0  miss=2            ← 幂等，说明 ctor 那轮全装上了
//     hook MISS GJIMSessionService -gji_updateMessage:      → 候选: addMessageService:, …
//     hook MISS GJIMSessionService -gji_insertForMessages:  → 候选: addMessageService:, …
//     badge=16 at 2 / badge=3 at 2          ← BluedTabBar Hook 确实在被调用（Hook 引擎是活的）
//
//   静态查证（_work/sel_owner.py，全量扫描宿主 14,839 个类 / 264,012 个方法条目）：
//     · `gji_updateMessage:`     唯一所有者 = **GJIMDBService 的 metaclass**，types = v24@0:8@16，imp 0x101c66634
//     · `gji_insertForMessages:` 唯一所有者 = **GJIMDBService 的 metaclass**，types = v24@0:8@16，imp 0x101c662c4
//     · 实例侧（GJIMSessionService / GJIMMessageService）**都没有** —— v7 挂实例侧，所以必然 2 条 MISS。
//   ① 新增 REAHOOKM()：对 Class 取 object_getClass() 得到 metaclass 再换实现，补上这两个类方法 Hook。
//   ② REASweepAntiTamper 升级为"实例表 + 类方法表"双扫描（REASweepOneClass），
//      这样以后任何"其实是类方法"的选择子也能被自动捞到。
//   ③ 报告里单独说明 12 个反越狱选择子在本版本不存在（原版同样落空），避免被误读成漏 Hook。
//   ④ 触发统计提前到 main+15s（先用后一条 45s 再记一次到文件，不重复弹窗）。
// ============================================================================
// v6 变更（用户 m01177：不闪退了，但"没有任何功能"，且手机里找不到 tmp 日志）
//   a) 日志：`BluedHushREA.log` 改为**多路径同时写**，第一顺位就是 Documents
//      （NSDocumentDirectory），其次 Library/Caches、tmp、/var/mobile/Documents。
//      屏幕报告里会直接显示"实际写入的第一条路径"，一眼能看出到底落在哪。
//   b) 屏幕报告：启动后首轮安装（main queue +2s）结束后弹原生 UIAlertController，
//      显示 装上条数 / 本轮 MISS / 累计 MISS / 四个开关的真实读数 / 日志路径，
//      以及 MISS 明细 —— 每条形如 "类 -选择子 → 候选: xxx, yyy"，候选由
//      REACandidates() 用 ≥5 字符子串相似度在该类**自有**方法里现算，
//      相当于把 7.50.3 改名后的新选择子直接摆到屏幕上，比人工猜快得多。
//      ⚠️ 不在构造函数里弹：+load 阶段既没有 window 也没有 host 类，弹窗必崩；
//      要拿到 MISS 必须等首轮安装跑完（这正是 v5 铁律①的必然结论）。
//   c) 现场盘点：`BluedHushREA-methods.log` 把 18 个探针类的**自有**选择子全量落盘
//      （class_copyMethodList，不触发 +initialize），截图看不清时可离线对齐。
//   d) 报告可用 `defaults write com.danlan.xiaolan rea_show_report -bool NO` 关掉。
// ============================================================================
// v5 修复：真机"打开 App 瞬间闪退"（2026-10-30 09:14:44 崩溃报告实证）
//
//   .ips 关键帧（bug_type 309，EXC_BAD_ACCESS/SIGSEGV KERN_INVALID_ADDRESS at 0x20）：
//       #9  libobjc   class_getInstanceMethod
//       #10 BluedHushREA.dylib + 0x4fd0
//       #11 BluedHushREA.dylib + 0x40b4
//       #12 dyld      load_images        ← 还在 +load 批处理阶段
//       #3  libobjc   CALLING_SOME_+initialize_METHOD
//   崩溃现场（宿主 Blued + 0x5b69f1c）：
//       bl   +0x105af61d8      ; 取某全局对象 → x20
//       ldr  x8, [x20]         ; x8 = 0   ← 该全局 C++/Swift 对象的构造还没跑
//       ldr  x8, [x8, #0x20]   ; 读 0x20  ← 崩在这里
//
//   机理（CONFIRMED）：`class_getInstanceMethod` 会 **触发目标类的 +initialize**。
//   v4 在 +load 阶段就用它做全类扫描（REASweepAntiTamper）并给继承方法兜底
//   （REASwap 的 class_addMethod 分支）→ 提前把 Blued 的 +initialize 拉起来 →
//   其依赖的全局对象尚未构造（首字为 0）→ 解引用 0x20 立刻 SIGSEGV。
//   第一次崩溃发生在 +load 里，所以连日志文件都来不及落盘 —— 与"找不到 .log"完全吻合。
//
//   v5 铁律（本文件后续所有代码都必须遵守）：
//     ① +load / 构造函数里**禁止**任何 Runtime 探测；只许 NSLog + 调度。
//     ② 全文件**禁止**出现 class_getInstanceMethod / class_getClassMethod /
//        任何会向宿主类 objc_msgSend 的调用（都会引爆 +initialize）。
//     ③ 只用不触发 +initialize 的 API：class_copyMethodList（仅 realize）、
//        method_getImplementation / method_setImplementation、class_addMethod、
//        class_respondsToSelector、class_getName、objc_getClass、sel_getName。
//     ④ ~~Hook 安装整体推迟到 App 启动完成之后~~ → **v7 已改回 ctor 同步安装**（见下）。
//        真因是"用错 API"，不是"装得早"：只要不碰 class_getInstanceMethod 就安全。
//     ⑤ 找不到本类自有实现就记 MISS，不再用 class_addMethod 去继承链上兜底。
// ============================================================================
// v7 变更（用户 m01299 三张截图实证：装上 34 条 / MISS 28 / 开关全 1 / 功能全无）
//   诊断：28 条 MISS 里 26 条是 amIJailBroken/checkDYLD 等**本版本已不存在**的反越狱方法
//   （纯噪声），真正的功能 Hook 只有 gji_updateMessage:/gji_insertForMessages: 打错类。
//   所以不是"改名"，是"装晚了"：main+2s 时 App 已把 VIP/私密相册/会话状态按真实值缓存完。
//   ① 首轮安装改回 **ctor 内同步执行**（等价原版 %ctor 时机），仍只用不触发 +initialize 的 API。
//   ② 反越狱不再按"猜的类名"逐个 REASwap（26 条 MISS 的来源），统一交给全类扫描，
//      扫到才改、扫不到不计数。
//   ③ gji_* 两个选择子改挂 GJIMSessionService（截图证明 GJIMMessageService 上没有）。
//   ④ 新增 9 个功能域的**调用计数器** + main+30s 第二张 Alert「触发统计」：
//      全 0 = Hook 从未被调用（入口不对）；非 0 = Hook 在跑，问题在返回值/时机。
// ============================================================================
// v4 相对 v3 的变更（用户实测环境：未越狱 / 个人自签 Esign / 主要在 LiveContainer 内运行）
//   a) 初始化第一行就打印 NSLog(@"[REA-Test] Runtime 注入成功!")，用它判定
//      "dylib 到底有没有被 dyld 加载"，与"Hook 有没有装上"两件事分开归因。
//   b) 全文件不实现任何越狱检测 / 反调试 / ptrace 探测；只把 App 自带的反越狱方法
//      强制返回 NO（纯 bypass，不做环境反查），避免在 LiveContainer 里被自家逻辑判死。
//   c) plist 过滤同时列出 App 与 LiveContainer 的 Bundle/Executable 名。
//   d) workflow 用 dist 暂存 + if-no-files-found: error，产物 zip 不可能再为空。

// ============================================================================
// v3 修复的核心问题（v2 真机"无崩溃也无功能"的根因，静态可证）
//
//   v2 产物 otool -L：
//       /Library/MobileSubstrate/DynamicLibraries/BluedHushREA.dylib   (LC_ID)
//       /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate    (LC_LOAD)
//   —— 两条都是 **rootful 绝对路径，且没有 rpath**。
//
//   而你设备上原版 BluedHush_5.19.dylib 的依赖是：
//       @rpath/CydiaSubstrate.framework/CydiaSubstrate
//       rpath: /var/jb/Library/Frameworks, /var/jb/usr/lib,
//              @loader_path/.jbroot/Library/Frameworks, @loader_path/.jbroot/usr/lib
//   —— 原作者是按 **rootless（/var/jb）** 打包的。
//
//   结论：rootless 设备上不存在 /Library/Frameworks/CydiaSubstrate.framework，
//   dyld 解析依赖失败 → 整个 dylib 静默不加载 → 不闪退、无日志、无功能。
//   首次启动那次 -[PushPackage msgId] 崩溃来自存量插件 BluedHook_v0_2_5.dylib
//   （它内置 _objc_msgSend$msgId），与本插件是否加载无关。
//
// v3 对策：
//   1) 不再引用任何 substrate 符号；Hook 全部用 libobjc 的
//      method_setImplementation / class_addMethod 自装（见 REASwap）。
//   2) 构建期硬门禁：workflow 里 otool -L 一旦看到 CydiaSubstrate 就 fail，
//      这类"静默不加载"不可能再被交付出去。
//   3) 加载痕迹落盘：/var/mobile/Documents/BluedHushREA.log（不可写则落 App 容器 tmp），
//      不依赖 macOS 控制台，手机上直接看文件即可定性。
//   4) msgId 垫片三层提前安装：构造函数 ×2（源码顺序在前者先跑）→ +load，全部幂等。
//
// 说明（不糊弄）：Mach-O 单镜像内真实顺序是
//   C 构造函数(__mod_init_func / __init_offsets) → ObjC +load → main
// 即构造函数最早、+load 在其后。三层都装一遍是为了无论加载器用哪个时机 dlopen，
// 垫片都已在位，而不是靠想当然的"更早"。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#define REA_TAG @"[REA-Test]"

// REAUI.xm（v9 新加）：悬浮球 + 分类菜单 + 开关面板。定义在另一个编译单元里。
extern void REAUIStart(void);

// ============================================================================
#pragma mark - 落盘日志（v6：Documents 优先，多路径同时写，手机上"文件"App 直接能看到）
// ============================================================================

// 可写的日志路径（可能多个）：Documents → Library/Caches → tmp → /var/mobile/Documents
static NSMutableArray<NSString *> *gREATracePaths = nil;

// 只解析目录、不做任何宿主类 Runtime 动作；由 REALog 首次调用时（启动后）才跑。
static void REAPrepareSink(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gREATracePaths = [NSMutableArray array];
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        @try {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            if (docs.length) [dirs addObject:docs];
            NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            if (caches.length) [dirs addObject:caches];
            NSString *tmp = NSTemporaryDirectory();
            if (tmp.length) [dirs addObject:[tmp stringByStandardizingPath]];
            [dirs addObject:@"/var/mobile/Documents"];      // 越狱/rootless 环境顺手写一份
        } @catch (NSException *e) { }

        for (NSString *d in dirs) {
            if (!d.length) continue;
            NSString *p = [d stringByAppendingPathComponent:@"BluedHushREA.log"];
            FILE *f = fopen(p.fileSystemRepresentation, "a");
            if (!f) continue;
            fclose(f);
            BOOL dup = NO;
            for (NSString *old in gREATracePaths) if ([old isEqualToString:p]) { dup = YES; break; }
            if (!dup) [gREATracePaths addObject:p];
        }
    });
}

static NSString *REAPrimaryTracePath(void) {
    REAPrepareSink();
    return gREATracePaths.firstObject ?: @"(无：沙盒目录均不可写)";
}

static void REATraceSink(NSString *line) {
    if (!line) return;
    NSLog(@"%@ %@", REA_TAG, line);
    @try {
        REAPrepareSink();
        NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date].description, line];
        const char *utf8 = stamped.UTF8String;
        for (NSString *p in gREATracePaths) {
            FILE *f = fopen(p.fileSystemRepresentation, "a");
            if (!f) continue;
            fputs(utf8, f);
            fclose(f);
        }
    } @catch (NSException *e) { }
}

static void REALog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        REATraceSink(msg);
    }
}

// ============================================================================
#pragma mark - 自研 Hook 引擎（与 substrate 同语义，零依赖）
// ============================================================================

static int gREAOK = 0, gREAMiss = 0;
static int gREATotalOK = 0;          // 所有轮次累加装上的条数（v7）
static int gREAEarlyOK = 0;          // ctor 早期那一轮装上的条数（v7）

// v7：每个功能域的"被调用次数"——用来区分两种失败：
//   计数全 0 → Hook 根本没被宿主调用（时序/类不对，功能自然全无）
//   计数非 0 → Hook 已在跑，功能差异在语义层（返回值/时机不对）
enum { REAF_AntiRecall = 0, REAF_Feed, REAF_Screenshot, REAF_PrivatePhoto, REAF_LocalVip,
       REAF_Location, REAF_Tabbar, REAF_Keyboard, REAF_Engine, REAF_Count };
static volatile int gREAHits[REAF_Count];
static const char *kREAHitNames[REAF_Count] = {
    "anti_recall", "feed", "screenshot", "private_photo", "local_vip",
    "location", "tabbar", "keyboard", "engine"
};
static inline void REAHit(int idx) {
    if (idx >= 0 && idx < REAF_Count) __sync_fetch_and_add(&gREAHits[idx], 1);
}

// 幂等记账：LiveContainer 里 App 主二进制是 dlopen 进来的，某些类可能晚于本 dylib 的
// 初始化才注册。因此允许"延迟重试安装"：已装过的 (类,选) 直接返回原 IMP，
// 绝不会把我们的 IMP 当成 orig 造成无限递归。
static NSMutableDictionary<NSString *, id> *gREAOrig;   // key -> NSValue(IMP)
static NSMutableSet<NSString *>           *gREADone;
static NSObject                           *gREALock;

// 报告用：本轮命中 / 本轮 MISS（字符串形如 "GJIMMessageModel -recallType"）+ 累计 MISS
static NSMutableArray<NSString *> *gREAOKList;
static NSMutableArray<NSString *> *gREAMissList;
static NSMutableArray<NSString *> *gREAMissAll;

static void REARegistryInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gREAOrig = [NSMutableDictionary dictionary];
        gREADone = [NSMutableSet set];
        gREALock = [[NSObject alloc] init];
        gREAOKList = [NSMutableArray array];
        gREAMissList = [NSMutableArray array];
        gREAMissAll = [NSMutableArray array];
    });
}

static NSString *REAKey(Class cls, const char *selName) {
    // v8：metaclass 与类可能同名（class_getName 对 metaclass 返回同一个类名），
    //     加 M 前缀区分，避免"类方法 Hook"命中"实例方法 Hook"的缓存键。
    BOOL meta = class_isMetaClass(cls);
    return [NSString stringWithFormat:@"%s%s|%s", meta ? "M:" : "", class_getName(cls), selName];
}

// 本类**自有**方法查找：class_copyMethodList 只 realize 类、不触发 +initialize（安全）。
static Method REAOwnedMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    Method found = NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (!list) return NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    free(list);
    return found;
}

// 类内"疑似改名候选"：与目标选择子共享 >=5 字符子串的本类自有方法（用于 7.50.3 改名后重新对齐）。
static NSArray<NSString *> *REACandidates(Class cls, const char *want) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!cls || !want || strlen(want) < 5) return out;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (!list) return out;
    NSString *w = [[NSString stringWithUTF8String:want] lowercaseString];
    for (unsigned int i = 0; i < n && out.count < 4; i++) {
        const char *mn = sel_getName(method_getName(list[i]));
        if (!mn) continue;
        NSString *cand = [NSString stringWithUTF8String:mn];
        if (!cand.length || [cand isEqualToString:[NSString stringWithUTF8String:want]]) continue;
        NSString *lc = cand.lowercaseString;
        BOOL hit = NO;
        for (NSUInteger k = 0; k + 5 <= w.length && !hit; k++) {
            if ([lc containsString:[w substringWithRange:NSMakeRange(k, 5)]]) hit = YES;
        }
        if (hit) [out addObject:cand];
    }
    free(list);
    return out;
}

// 语义对齐 MSHookMessageEx 的"自有方法"分支，但**刻意不做任何会触发 +initialize 的调用**：
//   · class_copyMethodList → 只 realize，不 initialize
//   · method_setImplementation / method_getImplementation → 只改方法表，不 initialize
//   · 绝不调用 class_getInstanceMethod、绝不对宿主类做 objc_msgSend
// 找不到本类自有实现就记 MISS：宁可少打一个 Hook，也不能把宿主的 +initialize 提前引爆。
// —— v5 铁律，见文件头 2026-10-30 .ips 事故。
static IMP REASwap(Class cls, const char *selName, IMP newImp) {
    if (!cls || !selName) { gREAMiss++; return NULL; }
    REARegistryInit();
    SEL sel = sel_registerName(selName);
    NSString *key = REAKey(cls, selName);

    @synchronized (gREALock) {
        id cached = gREAOrig[key];
        if (cached) return (IMP)[cached pointerValue];   // 已装过：返还原 IMP，不重复替换

        Method own = REAOwnedMethod(cls, sel);
        if (!own) {
            gREAMiss++;
            NSString *desc = [NSString stringWithFormat:@"%s %c%s", class_getName(cls),
                                                        class_isMetaClass(cls) ? '+' : '-', selName];
            NSArray<NSString *> *cand = REACandidates(cls, selName);
            if (cand.count) desc = [desc stringByAppendingFormat:@" → 候选: %@", [cand componentsJoinedByString:@", "]];
            [gREAMissList addObject:desc];
            if (![gREAMissAll containsObject:desc]) [gREAMissAll addObject:desc];
            REALog(@"hook MISS %@ (本类无自有实现，跳过以免触发 +initialize)", desc);
            return NULL;
        }
        IMP old = method_getImplementation(own);
        method_setImplementation(own, newImp);
        gREAOK++;
        [gREADone addObject:key];
        [gREAOKList addObject:[NSString stringWithFormat:@"%s %c%s", class_getName(cls),
                                                         class_isMetaClass(cls) ? '+' : '-', selName]];
        gREAOrig[key] = [NSValue valueWithPointer:(void *)old];
        return old;
    }
}

#define REAHOOK(clsName, selStr, fn, origVar) \
    do { origVar = REASwap(objc_getClass(clsName), selStr, (IMP)(fn)); } while (0)

// v8：类方法（metaclass）Hook。
// 证据：宿主二进制 __objc_classlist 全量扫描（14,839 类 / 264,012 个方法条目）后，
//   `gji_updateMessage:` / `gji_insertForMessages:` 的唯一所有者是 **GJIMDBService 的 metaclass**
//   （types 均为 v24@0:8@16，imp 0x101c66634 / 0x101c662c4）；
//   GJIMSessionService / GJIMMessageService 的实例方法表里根本没有它们 —— 这就是 v7 那 2 条 MISS 的真相。
// 对 Class 取 object_getClass() 得到 metaclass，class_copyMethodList(metaclass) 拿到类方法表。
#define REAHOOKM(clsName, selStr, fn, origVar)                                        \
    do {                                                                              \
        Class __rea_c = objc_getClass(clsName);                                       \
        origVar = REASwap(__rea_c ? object_getClass((id)__rea_c) : Nil, selStr,        \
                          (IMP)(fn));                                                 \
    } while (0)

// 原实现调用用显式 typedef，避免可变参数宏把"表达式"当成"类型"
typedef void   (*REA_V_V)(id, SEL);
typedef void   (*REA_V_Id)(id, SEL, id);
typedef void   (*REA_V_I)(id, SEL, int);
typedef void   (*REA_V_B)(id, SEL, BOOL);
typedef void   (*REA_V_D)(id, SEL, double);
typedef void   (*REA_V_ULL_Q)(id, SEL, unsigned long long, NSInteger);
typedef void   (*REA_V_Id_Q)(id, SEL, id, NSInteger);
typedef void   (*REA_V_Blk)(id, SEL, void (^)(BOOL));
typedef id     (*REA_I_V)(id, SEL);
typedef id     (*REA_I_Id)(id, SEL, id);
typedef int    (*REA_I32_V)(id, SEL);
typedef BOOL   (*REA_B_V)(id, SEL);
typedef NSInteger (*REA_Q_V)(id, SEL);
typedef double (*REA_D_V)(id, SEL);
typedef CLLocationCoordinate2D (*REA_Coord_V)(id, SEL);
typedef CLLocation * (*REA_Loc_V)(id, SEL);

// ============================================================================
#pragma mark - 安全取值（复刻原版 HushKeyValue 0x3029C 的 KVC + @try 语义）
// ============================================================================

static id REAValue(id obj, NSString *key) {
    if (!obj || ![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
    @try {
        if ([obj isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)obj objectForKey:key];
        if ([obj isKindOfClass:[NSArray class]]) return nil;
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static unsigned long long REAUInt(id obj, NSString *key) {
    @try {
        id v = REAValue(obj, key);
        if ([v isKindOfClass:[NSNumber class]]) return [v unsignedLongLongValue];
        if ([v isKindOfClass:[NSString class]]) return strtoull([v UTF8String], NULL, 10);
    } @catch (NSException *e) { }
    return 0;
}

// ============================================================================
#pragma mark - 开关中心（等价原版 [[HushConfig shared] isEnabled:]，默认全开）
// ============================================================================

// v9：去掉永久缓存 —— 原版 HushConfig 有 flagCache，但会在 -setEnabled:forKey: 里主动失效；
// 我们的 UI 层要"点一下就生效"，直接每次读 NSUserDefaults（CFPreferences 本身有内存缓存，
// 命中时开销与字典查表同量级），这样面板上的开关改完立刻对 Hook 生效，不必重启 App。
static BOOL REAFlag(NSString *key) {
    if (!key.length) return YES;
    @try {
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        return (v == nil) ? YES : [v boolValue];
    } @catch (NSException *e) {
        return YES;
    }
}

// ============================================================================
#pragma mark - PushPackage / REQPackage 的 msgId 垫片（幂等）
// ============================================================================

// 真实字段: messageId (Q16@0:8) / setMessageId: (v24@0:8Q16)
static unsigned long long REAMsgIdGetter(id self, SEL _cmd) {
    @try {
        id v = REAValue(self, @"messageId");
        if ([v isKindOfClass:[NSNumber class]]) return [v unsignedLongLongValue];
        if ([v isKindOfClass:[NSString class]]) return strtoull([v UTF8String], NULL, 10);
    } @catch (NSException *e) { }
    return 0;
}

static void REAMsgIdSetter(id self, SEL _cmd, unsigned long long v) {
    @try {
        if ([self respondsToSelector:NSSelectorFromString(@"setMessageId:")]) {
            [self setValue:@(v) forKey:@"messageId"];
        }
    } @catch (NSException *e) { }
}

static void REAInstallMsgIdShim(Class cls) {
    if (!cls) return;
    @try {
        SEL g = NSSelectorFromString(@"msgId");
        SEL s = NSSelectorFromString(@"setMsgId:");
        BOOL addedG = NO, addedS = NO;
        // 判存在只用不会触发 +initialize 的 API（class_respondsToSelector 只走方法表）。
        if (!class_respondsToSelector(cls, g)) {
            addedG = class_addMethod(cls, g, (IMP)REAMsgIdGetter, "Q16@0:8");
        }
        if (!class_respondsToSelector(cls, s)) {
            addedS = class_addMethod(cls, s, (IMP)REAMsgIdSetter, "v24@0:8Q16");
        }
        if (addedG || addedS) {
            REALog(@"msgId shim installed on %@ (msgId:%d setMsgId:%d)",
                   NSStringFromClass(cls), (int)addedG, (int)addedS);
        }
    } @catch (NSException *e) {
        REALog(@"msgId shim failed on %@", NSStringFromClass(cls));
    }
}

static void REAInstallAllShims(void) {
    REAInstallMsgIdShim(objc_getClass("PushPackage"));
    REAInstallMsgIdShim(objc_getClass("REQPackage"));
}

// ============================================================================
#pragma mark - 1. 撤回对抗  switch_anti_recall
// ============================================================================

static IMP p_recallType, p_isSuperRecallTip, p_setRecallType, p_setIsSuperRecallTip;

static int rea_recallType(id self, SEL _cmd) {
    REAHit(REAF_AntiRecall);
    @try {
        int r = p_recallType ? ((REA_I32_V)p_recallType)(self, _cmd) : 0;
        if (REAFlag(@"switch_anti_recall") && r != 0) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"anti-recall recallType %d -> 0", r);
            return 0;
        }
        return r;
    } @catch (NSException *e) { return 0; }
}

static BOOL rea_isSuperRecallTip(id self, SEL _cmd) {
    REAHit(REAF_AntiRecall);
    @try {
        if (REAFlag(@"switch_anti_recall")) {
            NSLog(@"[REA-Test] 注入成功");
            return NO;
        }
        return p_isSuperRecallTip ? ((REA_B_V)p_isSuperRecallTip)(self, _cmd) : NO;
    } @catch (NSException *e) { return NO; }
}

static void rea_setRecallType(id self, SEL _cmd, int type) {
    @try {
        if (REAFlag(@"switch_anti_recall") && type != 0) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"blocked setRecallType:%d", type);
            return;
        }
    } @catch (NSException *e) { }
    if (p_setRecallType) ((REA_V_I)p_setRecallType)(self, _cmd, type);
}

static void rea_setIsSuperRecallTip(id self, SEL _cmd, BOOL tip) {
    if (p_setIsSuperRecallTip) ((REA_V_B)p_setIsSuperRecallTip)(self, _cmd, tip);
}

// ============================================================================
#pragma mark - 2. 推送 / 会话（真实签名 @24@0:8@16，必须返回 id）
// ============================================================================

static IMP p_handlePushPackage, p_addMessage, p_addMessages, p_updateMessage;
static IMP p_deleteMessage, p_gji_updateMessage, p_gji_insertForMessages;
static IMP p_handleAMessageWithData, p_handleingGRPCPrivatePackage;

static id rea_handlePushPackage(id self, SEL _cmd, id pkg) {
    REAHit(REAF_Feed);
    @try {
        if (REAFlag(@"switch_anti_recall")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"push package intercepted: cls=%@ messageId=%llu msgId=%llu",
                   pkg ? NSStringFromClass([pkg class]) : @"(nil)",
                   REAUInt(pkg, @"messageId"), REAUInt(pkg, @"msgId"));
        }
    } @catch (NSException *e) { }
    if (!p_handlePushPackage) return nil;
    id ret = nil;
    @try {
        ret = ((REA_I_Id)p_handlePushPackage)(self, _cmd, pkg);
    } @catch (NSException *e) {
        REALog(@"p_handlePushPackage: exception swallowed: %@", e.reason);
        ret = nil;
    }
    return ret;
}

static void rea_addMessage(id self, SEL _cmd, id m)             { if (p_addMessage) ((REA_V_Id)p_addMessage)(self, _cmd, m); }
static void rea_addMessages(id self, SEL _cmd, id m)            { if (p_addMessages) ((REA_V_Id)p_addMessages)(self, _cmd, m); }
static void rea_updateMessage(id self, SEL _cmd, id m)          { if (p_updateMessage) ((REA_V_Id)p_updateMessage)(self, _cmd, m); }

static void rea_deleteMessage(id self, SEL _cmd, id m) {
    @try { if (REAFlag(@"switch_anti_recall")) REALog(@"deleteMessage intercepted"); } @catch (NSException *e) { }
    if (p_deleteMessage) ((REA_V_Id)p_deleteMessage)(self, _cmd, m);
}

static void rea_gji_updateMessage(id self, SEL _cmd, id m)      { if (p_gji_updateMessage) ((REA_V_Id)p_gji_updateMessage)(self, _cmd, m); }
static void rea_gji_insertForMessages(id self, SEL _cmd, id m)  { if (p_gji_insertForMessages) ((REA_V_Id)p_gji_insertForMessages)(self, _cmd, m); }
static void rea_handleAMessageWithData(id self, SEL _cmd, id d) { if (p_handleAMessageWithData) ((REA_V_Id)p_handleAMessageWithData)(self, _cmd, d); }

static void rea_handleGRPCPrivatePackage(id self, SEL _cmd, id pkg) {
    @try {
        if (REAFlag(@"switch_anti_recall") && pkg) {
            REALog(@"grpc package intercepted: cls=%@ messageId=%llu",
                   NSStringFromClass([pkg class]), REAUInt(pkg, @"messageId"));
        }
    } @catch (NSException *e) { }
    if (p_handleingGRPCPrivatePackage) ((REA_V_Id)p_handleingGRPCPrivatePackage)(self, _cmd, pkg);
}

// ============================================================================
#pragma mark - 3. 聊天视图 / 阅后即焚 / 截图提示
// ============================================================================

static IMP p_setMessages, p_showDestoryTip, p_screenshotTip, p_screenshotWarning, p_checkSendScreenshotTip;

static void rea_setMessages(id self, SEL _cmd, id msgs) {
    REAHit(REAF_Feed);
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_flash_text") && [msgs respondsToSelector:@selector(count)]) {
            REALog(@"setMessages count=%lu", (unsigned long)[(NSArray *)msgs count]);
        }
    } @catch (NSException *e) { }
    if (p_setMessages) ((REA_V_Id)p_setMessages)(self, _cmd, msgs);
}

static void rea_showDestoryTip(id self, SEL _cmd, id tip) {
    @try { if (REAFlag(@"switch_flash_photo")) { REALog(@"suppress destroy tip"); return; } } @catch (NSException *e) { }
    if (p_showDestoryTip) ((REA_V_Id)p_showDestoryTip)(self, _cmd, tip);
}

static void rea_screenshotTip(id self, SEL _cmd) {
    REAHit(REAF_Screenshot);
    @try {
        if (REAFlag(@"switch_screenshot")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"p_screenshotTip suppressed");
            return;
        }
    } @catch (NSException *e) { }
    if (p_screenshotTip) ((REA_V_V)p_screenshotTip)(self, _cmd);
}

static void rea_screenshotWarning(id self, SEL _cmd) {
    @try {
        if (REAFlag(@"switch_screenshot")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"p_screenshotWarning suppressed");
            return;
        }
    } @catch (NSException *e) { }
    if (p_screenshotWarning) ((REA_V_V)p_screenshotWarning)(self, _cmd);
}

static void rea_checkSendScreenshotTip(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_screenshot")) return; } @catch (NSException *e) { }
    if (p_checkSendScreenshotTip) ((REA_V_V)p_checkSendScreenshotTip)(self, _cmd);
}

// 反越狱 / 反模拟器：统一返回 NO（BOOL 统一编码 B16@0:8）
static BOOL rea_ret_NO(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
__attribute__((unused)) static void rea_void_nop(id self, SEL _cmd) { (void)self; (void)_cmd; }

static IMP p_forkCompletion;
// v7：不再主动挂这个选择子（带 completion block，粗暴置 NO 会让调用方的 block 永远不回调），
// 保留实现仅作备查，标记 unused 以免编译告警。
__attribute__((unused))
static void rea_checkForkWithCompletion(id self, SEL _cmd, void (^done)(BOOL)) {
    @try { if (done) { done(NO); return; } } @catch (NSException *e) { }
    if (p_forkCompletion) ((REA_V_Blk)p_forkCompletion)(self, _cmd, done);
}

// 全局扫描：这些 selector 在主二进制里查不到（属于 framework 里的同名类），
// 原版逻辑也只能在类真正注册后再打。这里遍历所有已加载类，命中就打一次，
// 保证不管它们来自哪个镜像都能被处置；重复扫描无副作用（已是我们自己的 IMP 就跳过）。
//
// v5：**不再用 class_getInstanceMethod 判存在**（它会触发 +initialize，就是首启闪退的元凶）。
// 改成"每类只复制一次 method list → 与名单字符串比对 → 直接 method_setImplementation"。
static const char *kREAAntiTamperSels[] = {
    "amIJailBroken", "amIRunInEmulator", "checkDYLD", "checkFork",
    "checkExistenceOfSuspiciousFiles", "checkSuspiciousFilesCanBeOpened",
    "checkRestrictedDirectoriesWriteable", "checkSymbolicLinks", "checkURLSchemes",
    "emulatorCheckCompile", "emulatorCheckRuntime", "performChecks", NULL
};
// 扫描单个 Class（或 metaclass）的自有方法表，把命中名单的选择子替换成 rea_ret_NO。
// 只 realize，不 initialize；已是自身 IMP 的跳过（幂等）。
static int REASweepOneClass(Class c, int *hits) {
    if (!c) return 0;
    const char *cn = class_getName(c);
    if (!cn || strncmp(cn, "REA", 3) == 0) return 0;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    if (!list) return 0;
    int touched = 0;
    for (unsigned int k = 0; k < n; k++) {
        const char *mn = sel_getName(method_getName(list[k]));
        if (!mn) continue;
        for (int s = 0; kREAAntiTamperSels[s]; s++) {
            if (strcmp(mn, kREAAntiTamperSels[s]) != 0) continue;
            if (method_getImplementation(list[k]) != (IMP)rea_ret_NO) {
                method_setImplementation(list[k], (IMP)rea_ret_NO);
                gREAOK++;
                if (hits) (*hits)++;
                touched++;
                REALog(@"anti-tamper swept %s -[%s]", cn, mn);
            }
            break;
        }
    }
    free(list);
    return touched;
}

static void REASweepAntiTamper(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!classes) return;
    total = objc_getClassList(classes, total);
    int hits = 0;
    for (int i = 0; i < total; i++) {
        Class c = classes[i];
        // v8：实例方法表 + 类方法表（metaclass）都扫 —— gji_* 就是这么找到真正宿主的。
        REASweepOneClass(c, &hits);
        REASweepOneClass(object_getClass((id)c), &hits);
    }
    free(classes);
    REALog(@"anti-tamper sweep done, hits=%d", hits);
}

// ============================================================================
#pragma mark - 4. 隐私相册  switch_private_photo
// ============================================================================

static IMP p_accessPrivatePhotos, p_setAccessPrivatePhotos;
static IMP p_privacyPhotosLocked, p_setPrivacyPhotosLocked;

static int rea_accessPrivatePhotos(id self, SEL _cmd) {
    REAHit(REAF_PrivatePhoto);
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_private_photo")) return 1;
    } @catch (NSException *e) { }
    return p_accessPrivatePhotos ? ((REA_I32_V)p_accessPrivatePhotos)(self, _cmd) : 0;
}

static void rea_setAccessPrivatePhotos(id self, SEL _cmd, int v) {
    @try { if (REAFlag(@"switch_private_photo")) return; } @catch (NSException *e) { }
    if (p_setAccessPrivatePhotos) ((REA_V_I)p_setAccessPrivatePhotos)(self, _cmd, v);
}

static int rea_privacyPhotosLocked(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_private_photo")) return 0; } @catch (NSException *e) { }
    return p_privacyPhotosLocked ? ((REA_I32_V)p_privacyPhotosLocked)(self, _cmd) : 0;
}

static void rea_setPrivacyPhotosLocked(id self, SEL _cmd, int v) {
    @try { if (REAFlag(@"switch_private_photo")) return; } @catch (NSException *e) { }
    if (p_setPrivacyPhotosLocked) ((REA_V_I)p_setPrivacyPhotosLocked)(self, _cmd, v);
}

// v5：setHidden: / setAlpha: 是 UIView 的**继承**方法，本类并未自有实现。
// 要打它只能走 class_addMethod 兜底，而兜底分支要 class_getInstanceMethod 取编码 —— 那正是
// 首启闪退的元凶；因此这两个 hook 直接删除。隐私相册解锁靠 access_private_photos /
// privacy_photos_has_locked 两个本类自有方法即可，视图显隐由 App 自身逻辑决定。

// ============================================================================
#pragma mark - 5. 本地 VIP  switch_local_vip
// ============================================================================

static IMP p_isVip, p_vipStatus, p_vipType, p_vipExpireDays, p_picBanSave;

static id rea_isVip(id self, SEL _cmd) {
    REAHit(REAF_LocalVip);
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_local_vip")) return @YES;
    } @catch (NSException *e) { }
    return p_isVip ? ((REA_I_V)p_isVip)(self, _cmd) : nil;
}

static NSInteger rea_vipStatus(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_local_vip")) return 1; } @catch (NSException *e) { }
    return p_vipStatus ? ((REA_Q_V)p_vipStatus)(self, _cmd) : 0;
}

static NSInteger rea_vipType(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_local_vip")) return 1; } @catch (NSException *e) { }
    return p_vipType ? ((REA_Q_V)p_vipType)(self, _cmd) : 0;
}

static id rea_vipExpireDays(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_local_vip")) return @(3650); } @catch (NSException *e) { }
    return p_vipExpireDays ? ((REA_I_V)p_vipExpireDays)(self, _cmd) : nil;
}

static NSInteger rea_picBanSave(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_watermark")) return 0; } @catch (NSException *e) { }
    return p_picBanSave ? ((REA_Q_V)p_picBanSave)(self, _cmd) : 0;
}

// ============================================================================
#pragma mark - 6. 虚拟定位  switch_virtual_location / switch_altitude
// ============================================================================

static BOOL gREAHasFakeCoord = NO;
static CLLocationDegrees gREALat = 0.0, gREALng = 0.0;
static CLLocationDistance gREAAlt = 0.0;

static void REALoadFakeLocation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"rea_fake_location"];
            if ([d isKindOfClass:[NSDictionary class]]) {
                gREALat = [d[@"lat"] doubleValue];
                gREALng = [d[@"lng"] doubleValue];
                gREAAlt = [d[@"alt"] doubleValue];
                gREAHasFakeCoord = YES;
                REALog(@"fake location loaded: %.6f,%.6f alt=%.1f", gREALat, gREALng, gREAAlt);
            }
        } @catch (NSException *e) { }
    });
}

static IMP p_coordinate, p_altitude, p_mgrLocation;

static CLLocationCoordinate2D rea_coordinate(id self, SEL _cmd) {
    REAHit(REAF_Location);
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_virtual_location")) {
        NSLog(@"[REA-Test] 注入成功");
        return CLLocationCoordinate2DMake(gREALat, gREALng);
    }
    return p_coordinate ? ((REA_Coord_V)p_coordinate)(self, _cmd) : CLLocationCoordinate2DMake(0, 0);
}

static CLLocationDistance rea_altitude(id self, SEL _cmd) {
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_altitude")) return gREAAlt;
    return p_altitude ? ((REA_D_V)p_altitude)(self, _cmd) : 0.0;
}

static CLLocation *rea_mgrLocation(id self, SEL _cmd) {
    REAHit(REAF_Location);
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_virtual_location")) {
        NSLog(@"[REA-Test] 注入成功");
        return [[CLLocation alloc] initWithLatitude:gREALat longitude:gREALng];
    }
    return p_mgrLocation ? ((REA_Loc_V)p_mgrLocation)(self, _cmd) : nil;
}

// ============================================================================
#pragma mark - 7. 其它埋点
// ============================================================================

static IMP p_needToBuyVip, p_setBadge, p_setCustomImage;
static IMP p_resetLoadData, p_actionDes, p_showRecentPhoto;

static void rea_needToBuyVip(id self, SEL _cmd) {
    @try { if (REAFlag(@"switch_local_vip")) { REALog(@"p_needToBuyVip suppressed"); return; } } @catch (NSException *e) { }
    if (p_needToBuyVip) ((REA_V_V)p_needToBuyVip)(self, _cmd);
}

static void rea_setBadge(id self, SEL _cmd, unsigned long long v, NSInteger i) {
    REAHit(REAF_Tabbar);
    @try { REALog(@"badge=%llu at %ld", v, (long)i); } @catch (NSException *e) { }
    // v9：UI 面板「角标净化」开关 —— 打开就把未读数清零，其它情况原样透传
    if (REAFlag(@"switch_clean_badge")) v = 0;
    if (p_setBadge) ((REA_V_ULL_Q)p_setBadge)(self, _cmd, v, i);
}

static void rea_setCustomImage(id self, SEL _cmd, id img, NSInteger i) {
    if (p_setCustomImage) ((REA_V_Id_Q)p_setCustomImage)(self, _cmd, img, i);
}

static void rea_resetLoadData(id self, SEL _cmd) { if (p_resetLoadData) ((REA_V_V)p_resetLoadData)(self, _cmd); }
static void rea_actionDes(id self, SEL _cmd, id s) { if (p_actionDes) ((REA_V_Id)p_actionDes)(self, _cmd, s); }
static void rea_showRecentPhoto(id self, SEL _cmd) { if (p_showRecentPhoto) ((REA_V_V)p_showRecentPhoto)(self, _cmd); }

// ============================================================================
#pragma mark - Hook 安装表
// ============================================================================

static void REAInstallHooks(void) {
    REAHOOK("GJIMMessageModel", "recallType", rea_recallType, p_recallType);
    REAHOOK("GJIMMessageModel", "isSuperRecallTip", rea_isSuperRecallTip, p_isSuperRecallTip);
    REAHOOK("GJIMMessageModel", "setRecallType:", rea_setRecallType, p_setRecallType);
    REAHOOK("GJIMMessageModel", "setIsSuperRecallTip:", rea_setIsSuperRecallTip, p_setIsSuperRecallTip);

    REAHOOK("GJIMSessionService", "p_handlePushPackage:", rea_handlePushPackage, p_handlePushPackage);
    REAHOOK("GJIMSessionService", "addMessage:", rea_addMessage, p_addMessage);
    REAHOOK("GJIMSessionService", "addMessages:", rea_addMessages, p_addMessages);
    REAHOOK("GJIMSessionService", "updateMessage:", rea_updateMessage, p_updateMessage);
    // v8：静态证实 gji_updateMessage: / gji_insertForMessages: 是 **GJIMDBService 的类方法**
    //     （metaclass 方法表，types = v24@0:8@16）。v7 挂在 GJIMSessionService 实例侧，所以 2 条 MISS。
    REAHOOKM("GJIMDBService", "gji_updateMessage:", rea_gji_updateMessage, p_gji_updateMessage);
    REAHOOKM("GJIMDBService", "gji_insertForMessages:", rea_gji_insertForMessages, p_gji_insertForMessages);

    REAHOOK("GJIMMessageService", "deleteMessage:", rea_deleteMessage, p_deleteMessage);

    REAHOOK("GJIMEngine", "p_handleAMessageWithData:", rea_handleAMessageWithData, p_handleAMessageWithData);
    REAHOOK("GJIMEngine", "handleingGRPCPrivatePackage:", rea_handleGRPCPrivatePackage, p_handleingGRPCPrivatePackage);

    REAHOOK("BDMessageViewController", "setMessages:", rea_setMessages, p_setMessages);
    REAHOOK("BDMessageViewController", "p_showDestoryTip:", rea_showDestoryTip, p_showDestoryTip);
    REAHOOK("BDMessageViewController", "p_screenshotTip", rea_screenshotTip, p_screenshotTip);
    REAHOOK("BDMessageViewController", "p_screenshotWarning", rea_screenshotWarning, p_screenshotWarning);
    REAHOOK("BDMessageViewController", "checkSendScreenshotTip", rea_checkSendScreenshotTip, p_checkSendScreenshotTip);

    // 反越狱 / 反模拟器：
    // v7 起不再按"猜的类名"逐个 REASwap —— 截图实测 BDMessageViewController 与
    // DLDeviceFingerprint 上都没有这些选择子（26 条 MISS 全在这里，纯噪声）。
    // 统一交给 REASweepAntiTamper() 全类扫描：谁真有就改谁，没有就静默跳过、不计 MISS。
    // （checkForkWithCompletion: 带 completion block，扫到也不能粗暴置 NO，故不纳入扫描）

    REAHOOK("BDPersonPrivacyAlbumCollectView", "access_private_photos", rea_accessPrivatePhotos, p_accessPrivatePhotos);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setAccess_private_photos:", rea_setAccessPrivatePhotos, p_setAccessPrivatePhotos);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "privacy_photos_has_locked", rea_privacyPhotosLocked, p_privacyPhotosLocked);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setPrivacy_photos_has_locked:", rea_setPrivacyPhotosLocked, p_setPrivacyPhotosLocked);
    // （setHidden: / setAlpha: 已在 v5 删除，理由见上方注释）

    REAHOOK("BDGlobalConfig", "is_vip", rea_isVip, p_isVip);
    REAHOOK("BDGlobalConfig", "vip_status", rea_vipStatus, p_vipStatus);
    REAHOOK("BDGlobalConfig", "vip_type", rea_vipType, p_vipType);
    REAHOOK("BDGlobalConfig", "vip_expire_days", rea_vipExpireDays, p_vipExpireDays);
    REAHOOK("BDGlobalConfig", "is_open_pic_ban_save", rea_picBanSave, p_picBanSave);

    REAHOOK("CLLocation", "coordinate", rea_coordinate, p_coordinate);
    REAHOOK("CLLocation", "altitude", rea_altitude, p_altitude);
    REAHOOK("CLLocationManager", "location", rea_mgrLocation, p_mgrLocation);

    REAHOOK("RecentlyVisitorViewController", "p_needToBuyVip", rea_needToBuyVip, p_needToBuyVip);
    REAHOOK("BluedTabBar", "setBadgeValue:atItemIndex:", rea_setBadge, p_setBadge);
    REAHOOK("BluedTabBar", "setCustomImage:atItemIndex:", rea_setCustomImage, p_setCustomImage);

    REAHOOK("NewKeyBoardPhotoView", "resetLoadData", rea_resetLoadData, p_resetLoadData);
    REAHOOK("NewKeyBoardPhotoView", "actionDes:", rea_actionDes, p_actionDes);
    REAHOOK("NewKeyBoard", "p_showKeyboardStateRecentPhoto", rea_showRecentPhoto, p_showRecentPhoto);

    // 最后做一次全类扫描，处理"类晚注册 / 类在别的镜像里"的情况
    REASweepAntiTamper();
}

// ============================================================================
#pragma mark - 现场报告（屏幕 Alert + 类方法清单落盘）v6
// ============================================================================

// 需要体检的宿主类（我们自己 hook 的目标 + 关键上下文类）
static NSArray<NSString *> *REAProbeClassNames(void) {
    return @[ @"GJIMMessageModel", @"GJIMSessionService", @"GJIMMessageService", @"GJIMEngine",
              @"BDMessageViewController", @"DLDeviceFingerprint", @"NewKeyBoard",
              @"NewKeyBoardPhotoView", @"BDPersonPrivacyAlbumCollectView", @"BDGlobalConfig",
              @"CLLocationManager", @"CLLocation", @"RecentlyVisitorViewController", @"BluedTabBar",
              @"PushPackage", @"REQPackage", @"GXWatchdog", @"BDChatBasicCell" ];
}

// 把内容写到每个"可写日志目录"下的同名文件（Documents 那份在"文件"App 里能看到）
static void REAWriteSideFile(NSString *fileName, NSString *content) {
    @try {
        REAPrepareSink();
        NSMutableSet<NSString *> *dirs = [NSMutableSet set];
        for (NSString *p in gREATracePaths) [dirs addObject:[p stringByDeletingLastPathComponent]];
        for (NSString *d in dirs) {
            NSString *path = [d stringByAppendingPathComponent:fileName];
            FILE *f = fopen(path.fileSystemRepresentation, "w");
            if (!f) continue;
            fputs(content.UTF8String ?: "", f);
            fclose(f);
            REALog(@"side file written: %@", path);
        }
    } @catch (NSException *e) {
        REALog(@"side file failed: %@ / %@", e.name, e.reason);
    }
}

// dump 目标类的**自有**方法清单（class_copyMethodList，不触发 +initialize），
// 落盘成 BluedHushREA-methods.log：即便屏幕截图看不清，也能靠它离线对齐被改名的选择子。
static void READumpMethodInventory(void) {
    @autoreleasepool {
        NSMutableString *log = [NSMutableString string];
        [log appendFormat:@"# BluedHushREA method inventory\n# %@\n", [NSDate date]];
        [log appendString:@"# 用法：找 '## 类名' 段落里与 MISS 目标名相近的选择子\n"];
        for (NSString *n in REAProbeClassNames()) {
            Class c = objc_getClass(n.UTF8String);
            if (!c) { [log appendFormat:@"\n## %@   (CLASS NOT FOUND)\n", n]; continue; }
            unsigned int cnt = 0;
            Method *list = class_copyMethodList(c, &cnt);
            [log appendFormat:@"\n## %@   own methods=%u\n", n, cnt];
            for (unsigned int i = 0; i < cnt; i++) {
                const char *mn = sel_getName(method_getName(list[i]));
                if (mn) [log appendFormat:@"  -%s\n", mn];
            }
            if (list) free(list);
        }
        REAWriteSideFile(@"BluedHushREA-methods.log", log);
        REALog(@"inventory dumped, %lu classes", (unsigned long)REAProbeClassNames().count);
    }
}

// 顶层可见 VC（只读属性 + 遍历，不触发宿主类 +initialize）
static UIViewController *REATopViewController(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *key = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in app.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { key = w; break; }
                }
                if (key) break;
            }
        }
        if (!key) {
            for (UIWindow *w in app.windows) { if (w.isKeyWindow) { key = w; break; } }
        }
        if (!key) key = app.windows.firstObject;
        UIViewController *vc = key.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
        if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
        return vc;
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL gREAReportShown = NO;
static BOOL gREAHitReportShown = NO;

// 启动早期窗口可能还没建好 → 每 1.5s 重试，最多 8 次；实在没有就只留日志。
static void REATryShowReport(NSString *title, NSString *body, BOOL *shown, int attempt) {
    if (*shown) return;
    @try { if (!REAFlag(@"rea_show_report")) return; } @catch (NSException *e) { }

    UIViewController *top = REATopViewController();
    if (!top) {
        if (attempt >= 8) { REALog(@"report alert skipped: no top view controller"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ REATryShowReport(title, body, shown, attempt + 1); });
        return;
    }
    @try {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
        *shown = YES;
        REALog(@"report alert presented on %@", NSStringFromClass([top class]));
    } @catch (NSException *e) {
        REALog(@"report alert exception: %@ / %@", e.name, e.reason);
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ REATryShowReport(title, body, shown, attempt + 1); });
        }
    }
}

// 组装报告：装上多少 / MISS 多少 / 开关实际读数 / 日志路径 / MISS 清单（含类内候选）
static void REAPublishReport(NSString *tag, int passOK, int passMiss) {
    @autoreleasepool {
        NSArray<NSString *> *missAll = [gREAMissAll copy];
        NSMutableString *body = [NSMutableString string];
        [body appendFormat:@"早期(ctor)装上 %d 条 / 累计装上 %d 条\n本轮(%@) %d 条 / 本轮 MISS %d / 累计 MISS %lu\n\n",
                           gREAEarlyOK, gREATotalOK, tag, passOK, passMiss,
                           (unsigned long)missAll.count];
        [body appendFormat:@"开关(1=YES): anti_recall=%d private_photo=%d local_vip=%d screenshot=%d\n",
                           (int)REAFlag(@"switch_anti_recall"), (int)REAFlag(@"switch_private_photo"),
                           (int)REAFlag(@"switch_local_vip"), (int)REAFlag(@"switch_screenshot")];
        [body appendFormat:@"\n日志: %@\n清单: BluedHushREA-methods.log\n", REAPrimaryTracePath()];

        if (missAll.count == 0) {
            [body appendString:@"\n没有 MISS：目标 Hook 全部装上。功能若无效应查开关与语义，不是名字问题。"];
        } else {
            [body appendString:@"\nMISS（类 -选择子 → 类内候选）:\n"];
            NSUInteger cap = MIN(missAll.count, 40);
            for (NSUInteger i = 0; i < cap; i++) [body appendFormat:@"· %@\n", missAll[i]];
            if (missAll.count > cap) [body appendFormat:@"…余下 %lu 条见日志\n", (unsigned long)(missAll.count - cap)];
        }
        // v8：把"原版同样是 no-op"的选择子单独说明，避免它们被误读成漏 Hook
        [body appendString:@"\n注: amIJailBroken / checkDYLD / checkFork / performChecks 等 12 个反越狱选择子"
                          @"在 7.50.3 全量 14,839 个类里不存在（原版 dylib 挂它们同样落空），不计 MISS。"];

        REALog(@"---- REPORT ----\n%@", body);
        REATryShowReport(@"[REA-Test] Hook 报告", body, &gREAReportShown, 0);
    }
}

// v7：触发统计。装上了 ≠ 被宿主调用过 —— 这张表用来判定到底卡在哪一层。
static void REAPublishHitReport(void) {
    @autoreleasepool {
        NSMutableString *body = [NSMutableString string];
        int total = 0;
        [body appendString:@"Hook 被调用次数：\n"];
        for (int i = 0; i < REAF_Count; i++) {
            int v = gREAHits[i];
            total += v;
            [body appendFormat:@"%s=%d  ", kREAHitNames[i], v];
            if ((i % 3) == 2) [body appendString:@"\n"];
        }
        [body appendFormat:@"\n合计=%d\n\n", total];
        if (total == 0) {
            [body appendString:@"全 0 → 宿主没走这些方法：要么类被另一份实现替换，要么功能走的是别的入口。\n"];
        } else {
            [body appendString:@"非 0 → Hook 已在跑；功能不对属返回值/时机问题，按上面的域定位。\n"];
        }
        REALog(@"---- HIT REPORT ----\n%@", body);
        REATryShowReport(@"[REA-Test] 触发统计", body, &gREAHitReportShown, 0);
    }
}

// ============================================================================
#pragma mark - 安装轮次 + 三层入口（+load 阶段零 Runtime 探测）
// ============================================================================

// 一轮完整安装：msgId 垫片 → 各 Hook → 全类反检测扫描。全部只用不触发 +initialize 的 API。
static void REAInstallPass(NSString *tag, BOOL firstPass) {
    @autoreleasepool {
        @try {
            gREAOK = 0; gREAMiss = 0;
            [gREAOKList removeAllObjects];
            [gREAMissList removeAllObjects];
            REAInstallAllShims();
            REAInstallHooks();
            int passOK = gREAOK, passMiss = gREAMiss;
            gREATotalOK += passOK;
            REALog(@"pass[%@] ok=%d miss=%d (total ok=%d)",
                   tag, passOK, passMiss, gREATotalOK);
            if (passOK > 0) {
                NSLog(@"[REA-Test] 注入成功");
                NSLog(@"[REA-Test] pass %@ hooked %d", tag, passOK);
            } else {
                NSLog(@"[REA-Test] pass %@ hooked 0 (classes not ready?)", tag);
            }

            NSMutableArray *alive = [NSMutableArray array];
            NSArray<NSString *> *probe = REAProbeClassNames();
            for (NSString *n in probe) {
                if (objc_getClass(n.UTF8String)) [alive addObject:n];   // objc_getClass 不触发 +initialize
            }
            REALog(@"classes alive %lu/%lu: %@",
                   (unsigned long)alive.count, (unsigned long)probe.count,
                   [alive componentsJoinedByString:@","]);

            // 首轮：方法清单落盘 + 屏幕上出报告（截图即可看到 MISS 清单）
            if (firstPass) {
                READumpMethodInventory();
                REAPublishReport(tag, passOK, passMiss);
            }
        } @catch (NSException *e) {
            REALog(@"pass[%@] EXCEPTION swallowed: %@ / %@", tag, e.name, e.reason);
        }
    }
}

// 调度（v7）：首轮**同步在 ctor 里装完**，之后再补装。
//
// 为什么改回去：截图实测"装上 34 条 / 开关全 1 / 功能全无"。装上 34 条说明类名与选择子都对，
// 唯一解释就是**装得太晚** —— App 在 main+2s 之前早把 VIP 状态、私密相册开关、会话列表
// 按真实值缓存进内存并建好了 UI，之后再改实现也追不回来。原版 dylib 就是在 %ctor 装的。
//
// 为什么现在敢早装：闪退的 .ips 帧 (#9 class_getInstanceMethod → #3 CALLING_SOME_+initialize_METHOD)
// 证明真因只有"用会触发 +initialize 的 API"。v5 起全文件只用 class_copyMethodList /
// method_setImplementation / class_addMethod / class_respondsToSelector —— 这些只 realize，
// 不 initialize。所以早装安全，"用错 API"才危险。
static void REAScheduleInstall(void) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;

    // ① ctor 内同步装第一轮（静默，不弹窗）：抢在 App 建缓存之前
    REAInstallPass(@"ctor", NO);
    gREAEarlyOK = gREAOK;

    // ② main+2s：幂等再跑一轮（补 ctor 时尚未注册的类）+ 出屏幕报告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        REAInstallPass(@"main+2s", YES);
    });

    // ②b main+1.5s：拉起 UI 层（悬浮球 + 分类菜单），见 REAUI.xm。
    //     必须等启动完成再建窗口：ctor 阶段还没有 UIWindowScene，建窗口必失败。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1.5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        REAUIStart();
    });

    // ③ main+15s：触发统计（回答"Hook 到底有没有被调用"）；main+45s 再记一次到文件（不再弹窗）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        REAPublishHitReport();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        REAPublishHitReport();
    });

    // ④ 后台补装：LiveContainer 里宿主二进制是 dlopen 进来的，个别类可能更晚才注册。
    //    每轮都幂等（REASwap 有记账，sweep 会跳过已是自己的 IMP）。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static const int waits[4] = { 4, 8, 15, 25 };
        for (int i = 0; i < 4; i++) {
            sleep((unsigned)waits[i]);
            REAInstallPass([NSString stringWithFormat:@"bg+%ds", waits[i]], NO);
        }
    });
}

// 最早：dylib 初始化阶段。只 NSLog + 调度（调度内部第一件事就是早期安装）。
__attribute__((constructor))
static void rea_premain(void) {
    NSLog(@"[REA-Test] Runtime 注入成功!");
    REAScheduleInstall();
}

// 等价 Logos %ctor（同一 __mod_init_func 段按源码顺序执行，幂等由 REAScheduleInstall 保证）
__attribute__((constructor))
static void rea_ctor(void) {
    REAScheduleInstall();
}

// 第三层：ObjC +load（在 mod-init 之后，纯冗余保险）
@interface REAEarlyLoader : NSObject
@end

@implementation REAEarlyLoader
+ (void)load {
    NSLog(@"[REA-Test] Runtime 注入成功! (+load)");
    REAScheduleInstall();
}
@end

// ============================================================================
#pragma mark - 供 UI 层（REAUI.xm）调用的桥
//
// 这五个函数是 REAUI.xm 里 extern 声明的入口。之所以走桥而不是把 UI 直接塞进本文件：
//   ① 本文件已经有 1,100+ 行、几千个 hook 定义，再混进 600 行 UIKit 会没法审；
//   ② 桥函数把"UI 想做的事"收敛成 5 个语义动作（读开关 / 日志 / 出报告 / 重装），
//      UI 层因此完全不依赖本文件内部的 static 符号，编译期各自独立、也不会误碰 hook 引擎。
// ============================================================================

void REALogBridge(NSString *fmt, ...) {
    @autoreleasepool {
        if (!fmt) return;
        va_list ap;
        va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        REALog(@"%@", s);
    }
}

BOOL REAFlagBridge(NSString *key) {
    return REAFlag(key);
}

// 手动出报告：清零"已弹过"标记，让用户点一次就出一次
void REAShowHookReportBridge(void) {
    @try {
        gREAReportShown = NO;
        REAPublishReport(@"manual", gREAOK, gREAMiss);
    } @catch (NSException *e) {
        REALog(@"manual hook report failed: %@", e.reason);
    }
}

void REAShowHitReportBridge(void) {
    @try {
        gREAHitReportShown = NO;
        REAPublishHitReport();
    } @catch (NSException *e) {
        REALog(@"manual hit report failed: %@", e.reason);
    }
}

void REAReinstallHooksBridge(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        REAInstallPass(@"manual", NO);
    });
}
