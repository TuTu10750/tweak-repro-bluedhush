// BluedHushREA v6 —— 纯 ObjC Runtime Hook 版（零 Logos、零 CydiaSubstrate、非越狱自签 + LiveContainer）
// 目标: com.danlan.xiaolan (Blued 7.50.3) / iOS 14.0+ / arm64 + arm64e
//
// ============================================================================
// v8 变更（真机日志 Documents/BluedHushREA.log + 屏幕报告实证：ctor 装上 34 条 / MISS 只剩 2）
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
    // 开关：switch_hide_live_tab / switch_hide_discover_tab（底栏隐藏类，默认关）
    // 两个开关都关 → 完全等价原实现，直接放行（Hook 处于禁用态）
    if (!REAFlag(@"switch_hide_live_tab") && !REAFlag(@"switch_hide_discover_tab")) {
        if (p_setCustomImage) ((REA_V_Id_Q)p_setCustomImage)(self, _cmd, img, i);
        return;
    }
    @try {
        if (p_setCustomImage) ((REA_V_Id_Q)p_setCustomImage)(self, _cmd, img, i);
        REAHit(REAF_Tabbar);
        REALog(@"tab custom image index=%ld", (long)i);
    } @catch (NSException *e) {
        REALog(@"setCustomImage exception: %@", e.reason);
    }
}

static void rea_resetLoadData(id self, SEL _cmd) {
    // 开关：switch_flash_photo（闪照转照片）；关闭时原样放行
    if (!REAFlag(@"switch_flash_photo")) {
        if (p_resetLoadData) ((REA_V_V)p_resetLoadData)(self, _cmd);
        return;
    }
    @try {
        if (p_resetLoadData) ((REA_V_V)p_resetLoadData)(self, _cmd);
        REAHit(REAF_Keyboard);
        REALog(@"flash photo panel resetLoadData passthrough");
    } @catch (NSException *e) {
        REALog(@"resetLoadData exception: %@", e.reason);
    }
}

static void rea_actionDes(id self, SEL _cmd, id s) {
    // 开关：switch_flash_text（闪文转普通消息）
    if (!REAFlag(@"switch_flash_text")) {
        if (p_actionDes) ((REA_V_Id)p_actionDes)(self, _cmd, s);
        return;
    }
    @try {
        if (p_actionDes) ((REA_V_Id)p_actionDes)(self, _cmd, s);
        REAHit(REAF_Keyboard);
        REALog(@"flash text action reached: %@", s);
    } @catch (NSException *e) {
        REALog(@"actionDes exception: %@", e.reason);
    }
}

static void rea_showRecentPhoto(id self, SEL _cmd) {
    // 开关：switch_flash_photo（键盘最近照片区，闪照相关入口）
    if (!REAFlag(@"switch_flash_photo")) {
        if (p_showRecentPhoto) ((REA_V_V)p_showRecentPhoto)(self, _cmd);
        return;
    }
    @try {
        if (p_showRecentPhoto) ((REA_V_V)p_showRecentPhoto)(self, _cmd);
        REAHit(REAF_Keyboard);
        REALog(@"recent photo panel opened");
    } @catch (NSException *e) {
        REALog(@"showRecentPhoto exception: %@", e.reason);
    }
}

// ============================================================================
static void REAInstallSettingsEntry(void);

// v12 净化引擎（定义在「设置页入口」之后；这里先声明，设置页钩子要用它做 purify_set_items）
static void REAInstallPurify(void);
static BOOL PShouldTrimSettingCell(id cell, NSIndexPath *ip);
static BOOL PIsTrimmedRow(NSIndexPath *ip);

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

    // 宿主「设置」页右上角注入「助手」按钮（v11）。与上面 36 条功能 Hook 完全独立：
    // 这一步只加一个 UI 入口，装不上也不影响任何 Hook。
    REAInstallSettingsEntry();

    // v12 净化引擎：广告位 / 入口 / 提示条 / 打码（净化中心第一批 39 条锚点 + 视图级兜底）
    REAInstallPurify();
}

// ============================================================================
#pragma mark - 宿主「设置」页入口（v12：真·列表 Cell 注入）
//
// 需求（Bug 2）：Blued「我的 → 设置」页的列表里要**长出一行「插件设置」**，点它打开面板。
//
// 原版 dylib 实证（_work/analysis/hooks_full.txt 334-340）：
//   原版对 BDSettingViewController 挂了 6 条 Hook：
//     viewDidLoad / viewWillAppear: / viewDidAppear: / viewDidDisappear:
//     tableView:cellForRowAtIndexPath: / tableView:heightForRowAtIndexPath:
//   其中 cellForRow 会按一串关键词给行加标记（rangeOfString: 命中后调 0x1237C4 改 cell），
//   heightForRow 同理 —— 说明原版走的是"宿主设置页 + 自己塞行"这条路，
//   而不是另开一个设置界面。所以本版也照这条路做，但**不依赖宿主内部数据模型**：
//   行数是数据源层 +1，多出来的那一行由我们自己出 cell / 高度 / 点击。
//
// 宿主实证（_work/analysis/host_index.json，14,839 个类全量）：
//   BDSettingViewController 自有方法里就有 onAuthority:/onSafeAccount:/onPrivate:/
//   onLiveSetting:/onNormal:/onAboutBlued:/switchAccount:/onLogout:/tableView:heightForRowAtIndexPath:，
//   确实是「我的 → 设置」这一页；但 numberOfRowsInSection / cellForRow / didSelect
//   这三个数据源方法**不在它自己的方法表里**（在父类上）。
//   所以安装时先沿 superclass 链找真正的所有者，再对所有者 REASwap —— 全程只用
//   class_copyMethodList / class_getSuperclass / method_getName，绝不碰
//   class_getInstanceMethod（铁律见文件头 v5 事故说明），不会提前引爆宿主 +initialize。
// ============================================================================

extern void REAOpenPanel(void);
extern BOOL REAOverlayPanelVisible(void);

/* 备用入口按钮的点击 Target（也是 v11 就有的，这里保留） */
@interface REAEntryTarget : NSObject
+ (instancetype)shared;
- (void)tap:(id)sender;
@end

@implementation REAEntryTarget

+ (instancetype)shared {
    static REAEntryTarget *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [REAEntryTarget new]; });
    return s;
}

- (void)tap:(id)sender {
    NSLog(@"[REA-Test] 注入成功");
    REALog(@"settings entry tapped -> open panel");
    REAOpenPanel();
}

@end

typedef NSInteger (*REA_TV_Rows)(id, SEL, UITableView *, NSInteger);
typedef UITableViewCell *(*REA_TV_Cell)(id, SEL, UITableView *, NSIndexPath *);
typedef void (*REA_TV_Select)(id, SEL, UITableView *, NSIndexPath *);
typedef double (*REA_TV_Height)(id, SEL, UITableView *, NSIndexPath *);

static REA_TV_Rows    p_settingRows    = NULL;
static REA_TV_Cell    p_settingCell    = NULL;
static REA_TV_Select  p_settingSelect  = NULL;
static REA_TV_Height  p_settingHeight  = NULL;
static REA_V_B         p_settingsWillAppear = NULL;   /* 备用入口：导航栏按钮 */

/* 入口行固定插在**第 0 组末尾**：宿主其它行下标全部不变，
   我们的行永远取 row == 宿主该组原行数，不会和宿主任何一行撞号。 */
static BOOL gREASettingsEntryOn = YES;
static NSInteger const kREASettingsEntrySection = 0;

static BOOL REAIsSettingVC(id self)
{
    Class c = objc_getClass("BDSettingViewController");
    return (c != Nil) && [self isKindOfClass:c];
}

/* 沿 superclass 链找**真正持有**该 selector 的类（只读方法表，不 initialize）。 */
static Class REAOwnerClass(Class cls, SEL sel)
{
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        BOOL found = NO;
        if (ms != NULL) {
            for (unsigned int i = 0; i < n; i++) {
                if (method_getName(ms[i]) == sel) { found = YES; break; }
            }
            free(ms);
        }
        if (found) return c;
    }
    return Nil;
}

static NSInteger REASettingBaseRows(id self, UITableView *tv)
{
    if (p_settingRows == NULL) return 0;
    return p_settingRows(self, sel_registerName("tableView:numberOfRowsInSection:"),
                         tv, kREASettingsEntrySection);
}

static UITableViewCell *REASettingsEntryCell(UITableView *tv)
{
    static NSString *rid = @"rea-settings-entry";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:rid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = @"插件设置";
    cell.textLabel.textColor = [UIColor labelColor];
    if (@available(iOS 13.0, *)) {
        cell.imageView.image = [UIImage systemImageNamed:@"bolt.horizontal.circle.fill"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    }
    return cell;
}

static NSInteger rea_settingsRows(id self, SEL _cmd, UITableView *tv, NSInteger section)
{
    NSInteger base = p_settingRows ? p_settingRows(self, _cmd, tv, section) : 0;
    if (!gREASettingsEntryOn) return base;
    if (!REAIsSettingVC(self)) return base;
    if (section != kREASettingsEntrySection) return base;
    return base + 1;
}

/* 我们的行是否成立：三个数据源 Hook 必须都在（rows 装不上时宿主根本没多出这一行，
   绝不能让 row==0 之类的下标被我们抢走）。 */
static BOOL REAIsOurEntryRow(id self, UITableView *tv, NSIndexPath *ip)
{
    if (!gREASettingsEntryOn) return NO;
    if (p_settingRows == NULL) return NO;
    if (!REAIsSettingVC(self)) return NO;
    if (ip.section != kREASettingsEntrySection) return NO;
    return ip.row == REASettingBaseRows(self, tv);
}

static UITableViewCell *rea_settingsCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip)
{
    if (REAIsOurEntryRow(self, tv, ip)) {
        return REASettingsEntryCell(tv);
    }
    if (p_settingCell == NULL) return nil;
    UITableViewCell *cell = p_settingCell(self, _cmd, tv, ip);
    @try { PShouldTrimSettingCell(cell, ip); }   // purify_set_items：命中白名单行 → 隐藏
    @catch (NSException *e) { }
    return cell;
}

static double rea_settingsHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip)
{
    if (REAIsOurEntryRow(self, tv, ip)) {
        return 56.0;
    }
    if (PIsTrimmedRow(ip)) return 0.0;          // purify_set_items：已判定精简的行
    if (p_settingHeight == NULL) return 44.0;
    return p_settingHeight(self, _cmd, tv, ip);
}

static void rea_settingsSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip)
{
    if (REAIsOurEntryRow(self, tv, ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        REALog(@"[SettingsEntry] 点击「插件设置」→ 打开面板");
        REAOpenPanel();
        return;
    }
    if (p_settingSelect) p_settingSelect(self, _cmd, tv, ip);
}

/* 备用入口（原 v11 方案）：万一某版宿主的设置页不走 BDSettingViewController，
   至少还有一个导航栏「助手」按钮。视图出现时重新挂一次，防被宿主覆盖。 */
static void REAAddSettingsNavButton(id self)
{
    if (self == nil) return;
    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;

    UIBarButtonItem *cur = vc.navigationItem.rightBarButtonItem;
    if (cur != nil && [cur.customView isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)cur.customView titleForState:UIControlStateNormal];
        if ([t isEqualToString:@"助手"]) return;
    }
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"助手" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 6, 4, 6);
    [btn sizeToFit];
    [btn addTarget:[REAEntryTarget shared]
            action:@selector(tap:)
  forControlEvents:UIControlEventTouchUpInside];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:btn];
}

static void rea_settingsWillAppear(id self, SEL _cmd, BOOL animated)
{
    if (p_settingsWillAppear) p_settingsWillAppear(self, _cmd, animated);
    @try { REAAddSettingsNavButton(self); }
    @catch (NSException *e) { REALog(@"settings nav button exception: %@", e.reason); }
}

// ============================================================================
#pragma mark - 净化引擎（v12）：广告位 / 入口 / 提示条的真实拦截
//
// 证据链（全部来自对宿主 7.50.3 主二进制的静态还原，不是猜的）：
//   · 宿主 14,839 个类、264,012 条方法条目已完整解析（_work/analysis/host_index.json），
//     下面每条锚点的「类 + 选择子 + 类型编码」都从这张表里取，签名与宿主完全一致。
//   · 开屏：AppDelegateModel(isNeedShowSplashAd / showSplashAd: / getSplashAdForColdLaunch)、
//     BDIndexPageCoversManager 的 8 个 show*Splash 变体、BDGDTSplashAdManager / BDKSSplashAdManager、
//     BDADX_Blued_Splash_Image_ViewController、BDADXBaseSplashAdManager，
//     外加聚合广告层总闸 ABUSplashAd -showInWindow:(Block)。
//   · 信息流：ABUDrawAdView / ABUNativeAdView 的 -loadAdData / -play，
//     与快手模板 cell 的 -startLoadWithAdModel:originModel:containVC:isNeedRefresh:。
//   · 身边 / 我的：BDNearbyDataAdapter 的 -setAdmsArray: / -setOriginUserAdsArray: 直接喂空数组；
//     BDNearbyBannerCell / BDMineBannerCell 的 -configerBanner: 直接跳过。
//   · 横幅 / 悬浮层 / 安全条 / 打码：BDGlobalBannerView、BDGlobalBannerMatchView、
//     BDIndexPageCoversManager 漂浮层两个入口、BDNearbyFloatingLayerModel -images、
//     BDChatSafeTipCell -setupData、BDMessageSafetyTipView -getSafetyTipViewHeight、
//     BDBlurredLabel -setBlurRadius:、BDMapBlurBaseView -applyBlurRadius:、
//     BDPrivacyAlbumCell -showMaskViewOrNot:。
//   · 剩下的"某类入口 / 浮层"，用**视图级净化器**兜底：hook UIView -didMoveToSuperview，
//     按真实类名模式（kPViewRules）把命中的视图隐藏，日志里能看到具体类名与 key。
//
// 语义：开关关 → 原实现照常（绝不影响宿主）；开关开 → 拦截 / 传空值 / 隐藏，并写日志。
// ============================================================================

// 选择子 -> 开关 key 的映射在下面的 kPInstall 安装表里（行内自带 key），
// trampoline 通过 PRowFor(self, _cmd) 由「self 的类链 + 选择子」定位到那一行再取 key。

// 每次读 NSUserDefaults（REAFlag 语义），保证面板点一下立刻生效。
static inline BOOL POn(const char *key) {
    if (!key) return NO;
    @try { return REAFlag([NSString stringWithUTF8String:key]); } @catch (NSException *e) { return NO; }
}

// ---- 安装表 ----
typedef struct { const char *cls; const char *sel; const char *kind; const char *key; } PInstall;
static const PInstall kPInstall[] = {
    { "AppDelegateModel", "isNeedShowSplashAd", "PK_B0", "purify_splash_ad" },   // purify_splash_ad
    { "AppDelegateModel", "showSplashAd:", "PK_VB", "purify_splash_ad" },   // purify_splash_ad
    { "AppDelegateModel", "getSplashAdForColdLaunch", "PK_V0", "purify_splash_ad" },   // purify_splash_ad
    { "AppDelegateModel", "p_getSplashAdvertisementForColdLaunch", "PK_V0", "purify_splash_ad" },   // purify_splash_ad
    { "BDGDTSplashAdManager", "showGDTSplash", "PK_V0", "purify_splash_ad" },   // purify_splash_ad
    { "BDKSSplashAdManager", "showKSSplash", "PK_V0", "purify_splash_ad" },   // purify_splash_ad
    { "BDADX_Blued_Splash_Image_ViewController", "presentBluedSplashImageViewController", "PK_V0", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "showSplashAd:currentWinAdModel:isColdLaunch:finished:", "PK_VSPLASH_A", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "showSplashAd_Adx:currentWinAdModel:isColdLaunch:finished:", "PK_VSPLASH_A", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "showSplashAd_Normal:isColdLaunch:finished:", "PK_VSPLASH_B", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "p_showGDTSplash:isColdLaunch:finished:", "PK_VSPLASH_B", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "p_showKSSplash:isColdLaunch:finished:", "PK_VSPLASH_B", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "p_showPangleSplash:isColdLaunch:finished:", "PK_VSPLASH_B", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "p_showBluedImageSplash:currentWinAdModel:isColdLaunch:finished:", "PK_VSPLASH_A", "purify_splash_ad" },   // purify_splash_ad
    { "BDIndexPageCoversManager", "p_showBluedVideoSplash:currentWinAdModel:isColdLaunch:finished:", "PK_VSPLASH_A", "purify_splash_ad" },   // purify_splash_ad
    { "BDADXBaseSplashAdManager", "assembleSplashContainerView:needRemoveHandler:", "PK_O2O", "purify_splash_ad" },   // purify_splash_ad
    { "ABUSplashAd", "showInWindow:", "PK_B1O", "purify_splash_ad" },   // purify_splash_ad
    { "ABUSplashAd", "showInWindowWithBlock:", "PK_B1O", "purify_splash_ad" },   // purify_splash_ad
    { "BDSplashVideoAdViewController", "presentInViewController:", "PK_V1O", "purify_splash_ad" },   // purify_splash_ad
    { "ABUDrawAdView", "loadAdData", "PK_V0", "purify_feed_ad" },   // purify_feed_ad
    { "ABUNativeAdView", "loadAdData", "PK_V0", "purify_feed_ad" },   // purify_feed_ad
    { "ABUNativeAdView", "play", "PK_V0", "purify_feed_ad" },   // purify_feed_ad
    { "BDKSTemplateExpressFeedAdBaseTableViewCell", "startLoadWithAdModel:originModel:containVC:isNeedRefresh:", "PK_V3OB", "purify_feed_ad" },   // purify_feed_ad
    { "BDKSSelfExpressNativeAdBaseTableViewCell", "startLoadWithAdModel:originModel:containVC:isNeedRefresh:", "PK_V3OB", "purify_feed_ad" },   // purify_feed_ad
    { "BDNearbyDataAdapter", "setAdmsArray:", "PK_ARR1O", "purify_nearby_ad" },   // purify_nearby_ad
    { "BDNearbyDataAdapter", "setOriginUserAdsArray:", "PK_ARR1O", "purify_nearby_ad" },   // purify_nearby_ad
    { "BDNearbyBannerCell", "configerBanner:", "PK_V1O", "purify_nearby_ad" },   // purify_nearby_ad
    { "BDGlobalBannerView", "showNsnofyView", "PK_V0", "purify_banner" },   // purify_banner
    { "BDGlobalBannerMatchView", "setBannerModel:messageModel:", "PK_V2O", "purify_banner" },   // purify_banner
    { "ABUBannerAd", "loadAdData", "PK_V0", "purify_banner" },   // purify_banner
    { "BDIndexPageCoversManager", "p_showFloatingLayerAds:image:finished:", "PK_V3O", "purify_float_layer" },   // purify_float_layer
    { "BDIndexPageCoversManager", "showFloatingLayerAfterNearbyPageShown", "PK_B0", "purify_float_layer" },   // purify_float_layer
    { "BDNearbyFloatingLayerModel", "images", "PK_O0", "purify_float_layer" },   // purify_float_layer
    { "BDMineBannerCell", "configerBanner:", "PK_V1O", "purify_mine_ad" },   // purify_mine_ad
    { "BDChatSafeTipCell", "setupData", "PK_V0", "purify_safe_tip" },   // purify_safe_tip
    { "BDMessageSafetyTipView", "getSafetyTipViewHeight", "PK_D0", "purify_safe_tip" },   // purify_safe_tip
    { "BDBlurredLabel", "setBlurRadius:", "PK_VD", "purify_blur_label" },   // purify_blur_label
    { "BDMapBlurBaseView", "applyBlurRadius:", "PK_VD", "purify_blur_label" },   // purify_blur_label
    { "BDPrivacyAlbumCell", "showMaskViewOrNot:", "PK_VB", "purify_sensitive" },   // purify_sensitive
    { "BDMessageViewController", "showChatRiskTip", "PK_V0", "purify_sensitive_alert" },   // purify_sensitive_alert
    { "BDSessionViewController", "p_ifShowRiskAlert", "PK_V0", "purify_sensitive_alert" },   // purify_sensitive_alert
    { "PrivateChatViewController", "showRiskUserTips:", "PK_V1O", "purify_sensitive_alert" },   // purify_sensitive_alert
    { "PrivateChatViewController", "riskTipsRequest", "PK_V0", "purify_sensitive_alert" },   // purify_sensitive_alert
    { "BDCallWorkFlowManager", "callStateRequest", "PK_O0", "purify_block_call" },   // purify_block_call
    { "BDCallWorkFlowManager", "callOpenRequest", "PK_O0", "purify_block_call" },   // purify_block_call
    { "BDCallWorkFlowManager", "callRequesting", "PK_B0", "purify_block_call" },   // purify_block_call
    { "BDVisitorTopView", "isShowCall", "PK_B0", "purify_block_call" },   // purify_block_call
    { "BDNearbyCallListView", "showCallAlert", "PK_V0", "purify_block_call" },   // purify_block_call
    { "BDTavernChatingViewController", "joinVoiceRoom", "PK_V0", "purify_block_voice" },   // purify_block_voice
    { "BDTavernChatingViewController", "p_showVoiceMatchPopoverView", "PK_V0", "purify_block_voice" },   // purify_block_voice
    { "BDTavernChatingViewController", "p_startVoiceForwardIfNeeded", "PK_V0", "purify_block_voice" },   // purify_block_voice
    { "UserVisitorData", "is_ads", "PK_I0", "purify_visitor_ad" },   // purify_visitor_ad
    { "NSURLSession", "dataTaskWithRequest:completionHandler:", "PK_DTASK2", NULL },   // 网络级：命中 kPHostRules 的 host 才切
    { "NSURLSession", "dataTaskWithRequest:", "PK_DTASK1", NULL },   // 网络级：命中 kPHostRules 的 host 才切
    { "NSMutableURLRequest", "setURL:", "PK_SETURL", NULL },   // 网络级：命中 kPHostRules 的 host 才切
    { "UIView", "didMoveToSuperview", "PK_VIEW", NULL },   // 视图级净化器（兜底）
};

#define P_ROW_COUNT (sizeof(kPInstall) / sizeof(kPInstall[0]))

// 行 -> 真正被改写的类 + 该类的原 IMP。装的时候填，之后只读。
// 不直接用 gREAOrig：那张表的键是"REASwap 传入的类名 + 选择子"，
// 而 trampoline 里拿到的 self 可能是子类实例（例如 UIView 的 -didMoveToSuperview
// 会收到 UILabel/UIImageView 实例），键对不上就会把原实现整个跳过。
static Class gPRowClass[P_ROW_COUNT];
static IMP   gPRowOld  [P_ROW_COUNT];

// 按「self 的继承链（由内向外）+ 选择子」定位安装行。
// 由内向外保证：同名选择子被父子两个类各挂一条时，命中离 self 最近的那条
// （例如 loadAdData 同时挂在 ABUDrawAdView 与 ABUNativeAdView）。
static NSInteger PRowFor(id self, SEL sel) {
    Class c = object_getClass(self);
    const char *s = sel_getName(sel);

    static Class gMemoCls; static const char *gMemoSel; static NSInteger gMemoRow;
    if (gMemoCls == c && gMemoSel == s) return gMemoRow;

    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (size_t i = 0; i < P_ROW_COUNT; i++) {
            if (gPRowClass[i] != k) continue;
            if (kPInstall[i].sel == NULL || strcmp(kPInstall[i].sel, s) != 0) continue;
            gMemoCls = c; gMemoSel = s; gMemoRow = (NSInteger)i;
            return (NSInteger)i;
        }
    }
    return -1;
}

static const char *PKeyFor(id self, SEL sel) {
    NSInteger r = PRowFor(self, sel);
    return (r >= 0) ? kPInstall[r].key : NULL;
}

// 取原实现
static IMP POld(id self, SEL sel) {
    NSInteger r = PRowFor(self, sel);
    return (r >= 0) ? gPRowOld[r] : NULL;
}

static void PLogHit(id self, SEL sel, const char *key, const char *what) {
    REALog(@"[Purify] %s %s -%s → %s", what, class_getName(object_getClass(self)),
           sel_getName(sel), key ? key : "?");
}


// ---- trampoline：每种签名一个函数，按 _cmd 决定"拦"还是"放" ----
static void PK_V0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL))o)(self, _cmd);
}

static void PK_VB(id self, SEL _cmd, BOOL a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, a);
}

static void PK_VQ(id self, SEL _cmd, NSInteger a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, NSInteger))o)(self, _cmd, a);
}

static void PK_VD(id self, SEL _cmd, double a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, double))o)(self, _cmd, a);
}

static void PK_V1O(id self, SEL _cmd, id a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a);
}

static void PK_V2O(id self, SEL _cmd, id a, id b) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, b);
}

static void PK_V3O(id self, SEL _cmd, id a, id b, id c) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd); if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a, b, c);
}

static void PK_V3OB(id self, SEL _cmd, id a, id b, id c, BOOL d) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "拦截"); return; }
    IMP o = POld(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id, BOOL))o)(self, _cmd, a, b, c, d);
}

// 开屏状态机：拦掉广告后必须把 finished(YES) 推进，否则开屏流程会卡在 loading
static void PK_VSPLASH_A(id self, SEL _cmd, id ad, id win, BOOL cold, id finished) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) {
        PLogHit(self, _cmd, k, "拦截（推进状态机）");
        if (finished) { void (^blk)(BOOL) = (void (^)(BOOL))finished; @try { blk(YES); } @catch (NSException *e) { } }
        return;
    }
    IMP o = POld(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, BOOL, id))o)(self, _cmd, ad, win, cold, finished);
}

static void PK_VSPLASH_B(id self, SEL _cmd, id ad, BOOL cold, id finished) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) {
        PLogHit(self, _cmd, k, "拦截（推进状态机）");
        if (finished) { void (^blk)(BOOL) = (void (^)(BOOL))finished; @try { blk(YES); } @catch (NSException *e) { } }
        return;
    }
    IMP o = POld(self, _cmd);
    if (o) ((void (*)(id, SEL, id, BOOL, id))o)(self, _cmd, ad, cold, finished);
}

static BOOL PK_B0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 NO"); return NO; }
    IMP o = POld(self, _cmd);
    return o ? ((BOOL (*)(id, SEL))o)(self, _cmd) : NO;
}

static BOOL PK_B1O(id self, SEL _cmd, id a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 NO"); return NO; }
    IMP o = POld(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, id))o)(self, _cmd, a) : NO;
}

static BOOL PK_B2O(id self, SEL _cmd, id a, id b) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 NO"); return NO; }
    IMP o = POld(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, id, id))o)(self, _cmd, a, b) : NO;
}

static id PK_O0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 nil"); return nil; }
    IMP o = POld(self, _cmd);
    return o ? ((id (*)(id, SEL))o)(self, _cmd) : nil;
}

static id PK_O1O(id self, SEL _cmd, id a) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 nil"); return nil; }
    IMP o = POld(self, _cmd);
    return o ? ((id (*)(id, SEL, id))o)(self, _cmd, a) : nil;
}

static id PK_O2O(id self, SEL _cmd, id a, id b) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 nil"); return nil; }
    IMP o = POld(self, _cmd);
    return o ? ((id (*)(id, SEL, id, id))o)(self, _cmd, a, b) : nil;
}

static double PK_D0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 0"); return 0.0; }
    IMP o = POld(self, _cmd);
    return o ? ((double (*)(id, SEL))o)(self, _cmd) : 0.0;
}

static int PK_I0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 0"); return 0; }
    IMP o = POld(self, _cmd);
    return o ? ((int (*)(id, SEL))o)(self, _cmd) : 0;
}

static long long PK_Q0(id self, SEL _cmd) {
    const char *k = PKeyFor(self, _cmd);
    if (k && POn(k)) { PLogHit(self, _cmd, k, "改判 0"); return 0; }
    IMP o = POld(self, _cmd);
    return o ? ((long long (*)(id, SEL))o)(self, _cmd) : 0;
}

// ---- 网络级拦截：命中黑名单 host 的请求直接换成"死地址"，等于切断该服务器 ----
// 语音房服务器 voice.blued.cn 就是这么切的（开关 purify_block_voice）。
// 抓两处：NSURLSession 建任务（覆盖 AFN / 系统会话）与 NSMutableURLRequest 改 URL（覆盖自建请求）。
typedef struct { const char *key; const char *hostSuffix; } PHostRule;
static const PHostRule kPHostRules[] = {
    { "purify_block_voice", "voice.blued.cn" },
};

static BOOL PShouldBlockHost(NSURL *url) {
    if (url == nil) return NO;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    for (size_t i = 0; i < sizeof(kPHostRules) / sizeof(kPHostRules[0]); i++) {
        if (!POn(kPHostRules[i].key)) continue;
        if ([host hasSuffix:@(kPHostRules[i].hostSuffix)]) return YES;
    }
    return NO;
}

static NSURLRequest *PDeadRequest(void) {
    static NSURLRequest *dead = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 127.0.0.1:9 是 discard 端口，必然拒连 → 请求立刻失败，服务器收不到任何字节
        dead = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:9/blocked-by-hush"]];
    });
    return dead;
}

static id PK_DTASK2(id self, SEL _cmd, NSURLRequest *req, id handler) {
    IMP o = POld(self, _cmd);
    if (PShouldBlockHost(req.URL)) {
        REALog(@"[Purify] 切断请求 %@%@（key=purify_block_voice）", req.URL.host, req.URL.path);
        req = PDeadRequest();
    }
    return o ? ((id (*)(id, SEL, id, id))o)(self, _cmd, req, handler) : nil;
}

static id PK_DTASK1(id self, SEL _cmd, NSURLRequest *req) {
    IMP o = POld(self, _cmd);
    if (PShouldBlockHost(req.URL)) {
        REALog(@"[Purify] 切断请求 %@%@（key=purify_block_voice）", req.URL.host, req.URL.path);
        req = PDeadRequest();
    }
    return o ? ((id (*)(id, SEL, id))o)(self, _cmd, req) : nil;
}

static void PK_SETURL(id self, SEL _cmd, NSURL *url) {
    IMP o = POld(self, _cmd);
    if (PShouldBlockHost(url)) {
        REALog(@"[Purify] 改写 URL %@（key=purify_block_voice）", url.host);
        NSURLRequest *dr = PDeadRequest();
        url = dr.URL;
    }
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, url);
}

// 空数组版：广告模型数组直接喂空，宿主数据源里就再没有广告条目
static void PK_ARR1O(id self, SEL _cmd, id a) {
    const char *k = PKeyFor(self, _cmd);
    IMP o = POld(self, _cmd);
    if (k && POn(k)) {
        PLogHit(self, _cmd, k, "喂空数组");
        if (o) ((void (*)(id, SEL, id))o)(self, _cmd, @[]);
        return;
    }
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a);
}

// ---- 视图级净化器：按类名模式隐藏广告 / 入口视图（兜底所有没被上面点名的实现） ----
typedef struct { const char *key; const char *needle; } PViewRule;
static const PViewRule kPViewRules[] = {
    { "purify_splash_ad", "SplashAd" },
    { "purify_splash_ad", "SplashImage" },
    { "purify_splash_ad", "SplashVideo" },
    { "purify_splash_ad", "SplashContainer" },
    { "purify_splash_ad", "ADXSplash" },
    { "purify_banner", "Banner" },
    { "purify_banner", "Nsnofy" },
    { "purify_svg_ad", "SVGA" },
    { "purify_svg_ad", "SvgFloat" },
    { "purify_float_layer", "FloatingLayer" },
    { "purify_float_layer", "FloatLayer" },
    { "purify_float_layer", "FloatAd" },
    { "purify_mine_vip", "MineVipOperate" },
    { "purify_mine_vip", "MineVipCard" },
    { "purify_live_entry", "LiveServiceCollection" },
    { "purify_live_entry", "LiveEntryView" },
    { "purify_live_entry", "LiveEntryCell" },
    { "purify_map_guide", "MapGuide" },
    { "purify_map_guide", "GuideCard" },
    { "purify_map_guide", "GuideView" },
    { "purify_welcome_pop", "WelcomeReward" },
    { "purify_welcome_pop", "WelcomePop" },
    { "purify_welcome_pop", "RewardPopView" },
    { "purify_follow_card", "FollowCard" },
    { "purify_follow_card", "FollowGuide" },
    { "purify_follow_card", "FollowTipView" },
    { "purify_call_header", "CallHeader" },
    { "purify_call_header", "CallEntry" },
    { "purify_call_header", "VoiceCallEntry" },
    { "purify_session_card", "SessionCard" },
    { "purify_session_card", "SessionTopCard" },
    { "purify_session_card", "SessionHeaderCard" },
    { "purify_new_nav_tag", "NewTag" },
    { "purify_new_nav_tag", "RedDot" },
    { "purify_new_nav_tag", "RedPoint" },
    { "purify_new_nav_tag", "HotTag" },
    { "purify_new_nav_tag", "PromoteTag" },
    { "purify_passby_tip", "Passby" },
    { "purify_passby_tip", "PassBy" },
    { "purify_passby_tip", "MetByChance" },
    { "purify_chat_emoji", "BigEmoji" },
    { "purify_chat_emoji", "EmojiAnimation" },
    { "purify_match_emoji_bar", "MatchEmoji" },
    { "purify_match_emoji_bar", "EmojiBar" },
    { "purify_match_emoji_bar", "ExpressionBar" },
    { "purify_sensitive", "PrivacyAlbumMask" },
    { "purify_sensitive", "SensitiveMask" },
};

// 类名 -> 规则下标缓存（不存在 = 未判定；>=0 命中第 i 条；-1 永不命中）
static NSMutableDictionary<NSString *, NSNumber *> *gPViewCache;

static BOOL PViewShouldHide(Class cls, const char **hitKey) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPViewCache = [NSMutableDictionary dictionary]; });
    NSString *name = @(class_getName(cls));
    if (!name.length) return NO;
    if ([name hasPrefix:@"_"]) name = [name substringFromIndex:1];

    NSNumber *cached = nil;
    @synchronized (gPViewCache) { cached = gPViewCache[name]; }
    if (cached) {
        NSInteger idx = cached.integerValue;
        if (idx < 0) return NO;
        if (POn(kPViewRules[idx].key)) { if (hitKey) *hitKey = kPViewRules[idx].key; return YES; }
        return NO;
    }

    NSString *lower = name.lowercaseString;
    for (size_t i = 0; i < sizeof(kPViewRules) / sizeof(kPViewRules[0]); i++) {
        NSString *needle = @(kPViewRules[i].needle).lowercaseString;
        if ([lower containsString:needle]) {
            @synchronized (gPViewCache) { gPViewCache[name] = @((NSInteger)i); }
            if (POn(kPViewRules[i].key)) { if (hitKey) *hitKey = kPViewRules[i].key; return YES; }
            return NO;
        }
    }
    @synchronized (gPViewCache) { gPViewCache[name] = @((NSInteger)-1); }
    return NO;
}

static void rea_viewDidMoveToSuperview(id self, SEL _cmd) {
    IMP o = POld(self, _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);

    @try {
        if (![self isKindOfClass:[UIView class]]) return;
        UIView *v = (UIView *)self;
        const char *key = NULL;
        if (!PViewShouldHide(object_getClass(self), &key)) return;
        if (v.hidden && v.alpha == 0.0) return;      // 已处理过，别每次重复干活
        v.hidden = YES;
        v.alpha = 0.0;
        CGRect f = v.frame;
        if (f.size.height > 0.5) { f.size.height = 0.5; v.frame = f; }
        REALog(@"[Purify] 视图净化：%@ → key=%s", NSStringFromClass(object_getClass(self)),
               key ? key : "?");
    } @catch (NSException *e) { }
}

// ---- 设置页精简（purify_set_items） ----
// 宿主设置页的行由它的数据源生成，我们不动数据源（动了下标会错位），
// 而是在 cellForRow / heightForRow 两处把命中行压成 0 高度并隐藏 —— 视觉上整行消失。
static NSArray<NSString *> *PWeightlessSettingTitles(void) {
    static NSArray<NSString *> *arr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        arr = @[ @"认证", @"实名", @"直播", @"扫一扫", @"青少年", @"青少年模式",
                 @"账号安全", @"隐私设置", @"帮助与反馈", @"关于", @"清除缓存" ];
    });
    return arr;
}

static NSMutableSet<NSString *> *gPTrimmedRows;   // "section-row" 集合

static BOOL PShouldTrimSettingCell(id cell, NSIndexPath *ip) {
    if (!POn("purify_set_items")) return NO;
    @try {
        if (![cell isKindOfClass:[UITableViewCell class]]) return NO;
        UITableViewCell *c = (UITableViewCell *)cell;
        NSString *text = c.textLabel.text;
        if (!text.length) return NO;
        for (NSString *needle in PWeightlessSettingTitles()) {
            if ([text containsString:needle]) {
                if (!gPTrimmedRows) gPTrimmedRows = [NSMutableSet set];
                if (ip) [gPTrimmedRows addObject:[NSString stringWithFormat:@"%ld-%ld",
                                                  (long)ip.section, (long)ip.row]];
                c.hidden = YES;
                c.alpha = 0.0;
                return YES;
            }
        }
    } @catch (NSException *e) { }
    return NO;
}

static BOOL PIsTrimmedRow(NSIndexPath *ip) {
    if (!POn("purify_set_items") || !gPTrimmedRows || !ip) return NO;
    return [gPTrimmedRows containsObject:[NSString stringWithFormat:@"%ld-%ld",
                                          (long)ip.section, (long)ip.row]];
}

static IMP PImpForKind(const char *kind) {
    if (!kind) return NULL;
    if (strcmp(kind, "PK_V0") == 0) return (IMP)PK_V0;
    if (strcmp(kind, "PK_VB") == 0) return (IMP)PK_VB;
    if (strcmp(kind, "PK_VQ") == 0) return (IMP)PK_VQ;
    if (strcmp(kind, "PK_VD") == 0) return (IMP)PK_VD;
    if (strcmp(kind, "PK_V1O") == 0) return (IMP)PK_V1O;
    if (strcmp(kind, "PK_V2O") == 0) return (IMP)PK_V2O;
    if (strcmp(kind, "PK_V3O") == 0) return (IMP)PK_V3O;
    if (strcmp(kind, "PK_V3OB") == 0) return (IMP)PK_V3OB;
    if (strcmp(kind, "PK_VSPLASH_A") == 0) return (IMP)PK_VSPLASH_A;
    if (strcmp(kind, "PK_VSPLASH_B") == 0) return (IMP)PK_VSPLASH_B;
    if (strcmp(kind, "PK_B0") == 0) return (IMP)PK_B0;
    if (strcmp(kind, "PK_B1O") == 0) return (IMP)PK_B1O;
    if (strcmp(kind, "PK_B2O") == 0) return (IMP)PK_B2O;
    if (strcmp(kind, "PK_O0") == 0) return (IMP)PK_O0;
    if (strcmp(kind, "PK_O1O") == 0) return (IMP)PK_O1O;
    if (strcmp(kind, "PK_O2O") == 0) return (IMP)PK_O2O;
    if (strcmp(kind, "PK_D0") == 0) return (IMP)PK_D0;
    if (strcmp(kind, "PK_I0") == 0) return (IMP)PK_I0;
    if (strcmp(kind, "PK_Q0") == 0) return (IMP)PK_Q0;
    if (strcmp(kind, "PK_DTASK2") == 0) return (IMP)PK_DTASK2;
    if (strcmp(kind, "PK_DTASK1") == 0) return (IMP)PK_DTASK1;
    if (strcmp(kind, "PK_SETURL") == 0) return (IMP)PK_SETURL;
    if (strcmp(kind, "PK_ARR1O") == 0) return (IMP)PK_ARR1O;
    if (strcmp(kind, "PK_VIEW") == 0) return (IMP)rea_viewDidMoveToSuperview;
    return NULL;
}

// 安装：先求"真正持有该选择子的类"（可能是父类），再 REASwap，
// 并把「被改写的类 + 原 IMP」写进行表，供 POld 沿继承链取回。
static void REAInstallPurify(void) {
    @autoreleasepool {
        int ok = 0, miss = 0;
        for (size_t i = 0; i < P_ROW_COUNT; i++) {
            const PInstall *p = &kPInstall[i];
            Class cls = objc_getClass(p->cls);
            if (cls == Nil) { miss++; REALog(@"[Purify] 宿主无类 %s（跳过）", p->cls); continue; }

            SEL sel = sel_registerName(p->sel);
            Class owner = REAOwnerClass(cls, sel);
            if (owner == Nil) {
                miss++;
                REALog(@"[Purify] %s 整条继承链都没有 -%s（跳过）", p->cls, p->sel);
                continue;
            }
            IMP imp = PImpForKind(p->kind);
            if (!imp) { miss++; continue; }

            IMP old = REASwap(owner, p->sel, imp);
            if (old) {
                gPRowClass[i] = owner;
                gPRowOld[i]   = old;
                ok++;
            } else {
                miss++;
            }
        }
        REALog(@"[Purify] 锚点安装：ok=%d miss=%d（共 %zu 条，含视图净化器）", ok, miss, (size_t)P_ROW_COUNT);
    }
}

static void REAInstallSettingsEntry(void)
{
    @try {
        Class vc = objc_getClass("BDSettingViewController");
        if (vc == Nil) {
            REALog(@"[SettingsEntry] 宿主没有 BDSettingViewController，只装导航栏备用入口");
        } else {
            SEL sRows   = sel_registerName("tableView:numberOfRowsInSection:");
            SEL sCell   = sel_registerName("tableView:cellForRowAtIndexPath:");
            SEL sSelect = sel_registerName("tableView:didSelectRowAtIndexPath:");
            SEL sHeight = sel_registerName("tableView:heightForRowAtIndexPath:");

            Class cRows   = REAOwnerClass(vc, sRows);
            Class cCell   = REAOwnerClass(vc, sCell);
            Class cSelect = REAOwnerClass(vc, sSelect);
            Class cHeight = REAOwnerClass(vc, sHeight);

            if (cRows != Nil && p_settingRows == NULL) {
                p_settingRows = (REA_TV_Rows)REASwap(cRows,
                    "tableView:numberOfRowsInSection:", (IMP)rea_settingsRows);
            }
            if (cCell != Nil && p_settingCell == NULL) {
                p_settingCell = (REA_TV_Cell)REASwap(cCell,
                    "tableView:cellForRowAtIndexPath:", (IMP)rea_settingsCell);
            }
            if (cSelect != Nil && p_settingSelect == NULL) {
                p_settingSelect = (REA_TV_Select)REASwap(cSelect,
                    "tableView:didSelectRowAtIndexPath:", (IMP)rea_settingsSelect);
            }
            if (cHeight != Nil && p_settingHeight == NULL) {
                p_settingHeight = (REA_TV_Height)REASwap(cHeight,
                    "tableView:heightForRowAtIndexPath:", (IMP)rea_settingsHeight);
            }

            REALog(@"[SettingsEntry] rowsOwner=%s cellOwner=%s selectOwner=%s heightOwner=%s",
                   cRows ? class_getName(cRows) : "(无)",
                   cCell ? class_getName(cCell) : "(无)",
                   cSelect ? class_getName(cSelect) : "(无)",
                   cHeight ? class_getName(cHeight) : "(无)");
            REALog(@"[SettingsEntry] 安装结果 rows=%@ cell=%@ select=%@ height=%@",
                   p_settingRows ? @"ok" : @"miss", p_settingCell ? @"ok" : @"miss",
                   p_settingSelect ? @"ok" : @"miss", p_settingHeight ? @"ok" : @"miss");
        }

        /* 备用：原 v11 的两个隐私设置页导航栏按钮（幂等） */
        Class c1 = objc_getClass("BDPrivacySettingViewController");
        if (c1 != Nil && p_settingsWillAppear == NULL) {
            p_settingsWillAppear = (REA_V_B)REASwap(c1, "viewWillAppear:",
                                                    (IMP)rea_settingsWillAppear);
        }
    } @catch (NSException *e) {
        REALog(@"[SettingsEntry] install exception: %@", e.reason);
    }
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

    // ②b main+0.2s：拉起 UI 层（悬浮球 + 分类菜单），见 REAUI.xm。
    //     REAUIStart 内部自带 0.5s × 40 次重试：窗口一出现立即挂球，等同"极早期"。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
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
