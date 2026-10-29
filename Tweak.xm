// BluedHushREA v3 —— 自研 Hook 引擎版（彻底去掉 CydiaSubstrate 硬依赖）
// 目标: com.danlan.xiaolan (Blued 7.50.3) / iOS 14.0+ / arm64 + arm64e
//
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

#define REA_TAG @"[REA-Test]"

// ============================================================================
#pragma mark - 落盘日志（手机上 cat 就能定性）
// ============================================================================

static NSString *gREATracePath = nil;

static void REATraceSink(NSString *line) {
    if (!line) return;
    NSLog(@"%@ %@", REA_TAG, line);
    @try {
        if (!gREATracePath) {
            NSArray<NSString *> *cands = @[
                @"/var/mobile/Documents/BluedHushREA.log",
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"BluedHushREA.log"]
            ];
            for (NSString *p in cands) {
                FILE *f = fopen(p.UTF8String, "a");
                if (f) { fclose(f); gREATracePath = p; break; }
            }
        }
        if (gREATracePath) {
            FILE *f = fopen(gREATracePath.UTF8String, "a");
            if (f) {
                fputs(line.UTF8String, f);
                fputc('\n', f);
                fclose(f);
            }
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
#pragma mark - 自研 Hook 引擎（等价 MSHookMessageEx 语义，零 substrate 依赖）
// ============================================================================

static int gREAOK = 0, gREAMiss = 0;

// 语义与 MSHookMessageEx 一致：
//   · 类自己拥有该方法 → method_setImplementation
//   · 只有父类实现     → class_addMethod 到本类（只影响本类，orig 指向父类实现）
// 返回原实现；调用 orig(self, _cmd, ...) 走原逻辑，不会递归。
static IMP REASwap(Class cls, const char *selName, IMP newImp) {
    if (!cls || !selName) { gREAMiss++; return NULL; }
    SEL sel = sel_registerName(selName);

    Method own = NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (list) {
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(list[i]) == sel) { own = list[i]; break; }
        }
        free(list);
    }

    if (own) {
        IMP old = method_getImplementation(own);
        method_setImplementation(own, newImp);
        gREAOK++;
        return old;
    }

    Method inh = class_getInstanceMethod(cls, sel);
    if (!inh) {
        gREAMiss++;
        REALog(@"hook MISS %s %s (方法不存在)", class_getName(cls), selName);
        return NULL;
    }
    IMP old = method_getImplementation(inh);
    class_addMethod(cls, sel, newImp, method_getTypeEncoding(inh));
    gREAOK++;
    return old;
}

#define REAHOOK(clsName, selStr, fn, origVar) \
    do { origVar = REASwap(objc_getClass(clsName), selStr, (IMP)(fn)); } while (0)

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

static BOOL REAFlag(NSString *key) {
    static NSMutableDictionary<NSString *, NSNumber *> *gCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gCache = [NSMutableDictionary dictionary]; });
    @try {
        @synchronized (gCache) {
            NSNumber *cached = gCache[key];
            if (cached) return cached.boolValue;
            id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
            BOOL on = (v == nil) ? YES : [v boolValue];
            gCache[key] = @(on);
            return on;
        }
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
        if (!class_getInstanceMethod(cls, g)) {
            addedG = class_addMethod(cls, g, (IMP)REAMsgIdGetter, "Q16@0:8");
        }
        if (!class_getInstanceMethod(cls, s)) {
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
static void rea_void_nop(id self, SEL _cmd) { (void)self; (void)_cmd; }

static IMP p_forkCompletion;
static void rea_checkForkWithCompletion(id self, SEL _cmd, void (^done)(BOOL)) {
    @try { if (done) { done(NO); return; } } @catch (NSException *e) { }
    if (p_forkCompletion) ((REA_V_Blk)p_forkCompletion)(self, _cmd, done);
}

// ============================================================================
#pragma mark - 4. 隐私相册  switch_private_photo
// ============================================================================

static IMP p_accessPrivatePhotos, p_setAccessPrivatePhotos;
static IMP p_privacyPhotosLocked, p_setPrivacyPhotosLocked;
static IMP p_albumSetHidden, p_albumSetAlpha;

static int rea_accessPrivatePhotos(id self, SEL _cmd) {
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

// setHidden:/setAlpha: 继承自 UIView —— 引擎把新 IMP 装到本类、orig 指向 UIView 实现，
// 这里直接调 orig 即可，既不需要 super 也不会递归。
static void rea_albumSetHidden(id self, SEL _cmd, BOOL hidden) {
    @try {
        if (REAFlag(@"switch_private_photo") && hidden) {
            if (p_albumSetHidden) ((REA_V_B)p_albumSetHidden)(self, _cmd, NO);
            return;
        }
    } @catch (NSException *e) { }
    if (p_albumSetHidden) ((REA_V_B)p_albumSetHidden)(self, _cmd, hidden);
}

static void rea_albumSetAlpha(id self, SEL _cmd, CGFloat alpha) {
    @try {
        if (REAFlag(@"switch_private_photo") && alpha < 0.99) {
            if (p_albumSetAlpha) ((REA_V_D)p_albumSetAlpha)(self, _cmd, 1.0);
            return;
        }
    } @catch (NSException *e) { }
    if (p_albumSetAlpha) ((REA_V_D)p_albumSetAlpha)(self, _cmd, alpha);
}

// ============================================================================
#pragma mark - 5. 本地 VIP  switch_local_vip
// ============================================================================

static IMP p_isVip, p_vipStatus, p_vipType, p_vipExpireDays, p_picBanSave;

static id rea_isVip(id self, SEL _cmd) {
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
    @try { REALog(@"badge=%llu at %ld", v, (long)i); } @catch (NSException *e) { }
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

    REAHOOK("GJIMMessageService", "deleteMessage:", rea_deleteMessage, p_deleteMessage);
    REAHOOK("GJIMMessageService", "gji_updateMessage:", rea_gji_updateMessage, p_gji_updateMessage);
    REAHOOK("GJIMMessageService", "gji_insertForMessages:", rea_gji_insertForMessages, p_gji_insertForMessages);

    REAHOOK("GJIMEngine", "p_handleAMessageWithData:", rea_handleAMessageWithData, p_handleAMessageWithData);
    REAHOOK("GJIMEngine", "handleingGRPCPrivatePackage:", rea_handleGRPCPrivatePackage, p_handleingGRPCPrivatePackage);

    REAHOOK("BDMessageViewController", "setMessages:", rea_setMessages, p_setMessages);
    REAHOOK("BDMessageViewController", "p_showDestoryTip:", rea_showDestoryTip, p_showDestoryTip);
    REAHOOK("BDMessageViewController", "p_screenshotTip", rea_screenshotTip, p_screenshotTip);
    REAHOOK("BDMessageViewController", "p_screenshotWarning", rea_screenshotWarning, p_screenshotWarning);
    REAHOOK("BDMessageViewController", "checkSendScreenshotTip", rea_checkSendScreenshotTip, p_checkSendScreenshotTip);

    // 反越狱 / 反模拟器（主二进制里可能不存在，MISS 属预期，不影响其它 Hook）
    const char *jbSels[] = {
        "amIJailBroken", "amIRunInEmulator", "checkDYLD", "checkFork",
        "checkExistenceOfSuspiciousFiles", "checkSuspiciousFilesCanBeOpened",
        "checkRestrictedDirectoriesWriteable", "checkSymbolicLinks", "checkURLSchemes",
        "emulatorCheckCompile", "emulatorCheckRuntime", NULL
    };
    const char *hosts[] = { "BDMessageViewController", "DLDeviceFingerprint", NULL };
    for (int h = 0; hosts[h]; h++) {
        Class c = objc_getClass(hosts[h]);
        if (!c) continue;
        for (int i = 0; jbSels[i]; i++) REASwap(c, jbSels[i], (IMP)rea_ret_NO);
        REASwap(c, "performChecks", (IMP)rea_void_nop);
        p_forkCompletion = REASwap(c, "checkForkWithCompletion:", (IMP)rea_checkForkWithCompletion);
    }

    REAHOOK("BDPersonPrivacyAlbumCollectView", "access_private_photos", rea_accessPrivatePhotos, p_accessPrivatePhotos);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setAccess_private_photos:", rea_setAccessPrivatePhotos, p_setAccessPrivatePhotos);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "privacy_photos_has_locked", rea_privacyPhotosLocked, p_privacyPhotosLocked);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setPrivacy_photos_has_locked:", rea_setPrivacyPhotosLocked, p_setPrivacyPhotosLocked);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setHidden:", rea_albumSetHidden, p_albumSetHidden);
    REAHOOK("BDPersonPrivacyAlbumCollectView", "setAlpha:", rea_albumSetAlpha, p_albumSetAlpha);

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
}

// ============================================================================
#pragma mark - 三层入口（constructor(101) → ctor → +load，全部幂等）
// ============================================================================

static void REABoot(NSString *stage) {
    // 幂等：三次入口只真正装一次，否则第二次会把我们自己的 IMP 当成 orig，造成递归
    static BOOL done = NO;
    if (done) {
        REALog(@"stage %@ skipped (already booted)", stage);
        return;
    }
    done = YES;
    // 第一行日志：只要这一行进控制台，就证明 dylib 已被 dyld 正常加载并跑到了初始化
    NSLog(@"[REA-Test] Runtime 注入成功!");
    @autoreleasepool {
        @try {
            REALog(@"---- stage %@ | pid=%d uid=%d ----", stage, getpid(), getuid());
            REAInstallAllShims();
            REAInstallHooks();
            REALog(@"hooks installed ok=%d miss=%d", gREAOK, gREAMiss);
            REALog(@"trace file: %@", gREATracePath ?: @"(none, NSLog only)");

            NSArray<NSString *> *probe = @[
                @"GJIMMessageModel", @"GJIMSessionService", @"GJIMMessageService", @"GJIMEngine",
                @"BDMessageViewController", @"DLDeviceFingerprint", @"NewKeyBoard",
                @"NewKeyBoardPhotoView", @"BDPersonPrivacyAlbumCollectView", @"BDGlobalConfig",
                @"CLLocationManager", @"CLLocation", @"RecentlyVisitorViewController", @"BluedTabBar",
                @"PushPackage"
            ];
            NSMutableArray *alive = [NSMutableArray array];
            for (NSString *n in probe) {
                if (objc_getClass(n.UTF8String)) [alive addObject:n];
            }
            REALog(@"classes alive %lu/%lu: %@",
                   (unsigned long)alive.count, (unsigned long)probe.count,
                   [alive componentsJoinedByString:@","]);
            NSLog(@"[REA-Test] 注入成功");
        } @catch (NSException *e) {
            REALog(@"BOOT EXCEPTION swallowed: %@ / %@", e.name, e.reason);
        }
    }
}

// 最早：dylib 初始化阶段。这里刻意不用 constructor(priority)（Darwin 上优先级语义不可靠），
// 而是靠"同一 __mod_init_func 段内按源码顺序执行"来保证 premain 先于 ctor。
__attribute__((constructor))
static void rea_premain(void) {
    REABoot(@"premain(ctor-first)");
}

// 等价 Logos %ctor
__attribute__((constructor))
static void rea_ctor(void) {
    REABoot(@"ctor(default)");
}

// 第三层：ObjC +load（在 mod-init 之后，纯冗余保险，幂等）
@interface REAEarlyLoader : NSObject
@end

@implementation REAEarlyLoader
+ (void)load {
    REABoot(@"+load");
}
@end
