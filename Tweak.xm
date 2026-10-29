// BluedHushREA v2 —— BluedHush_5.19.dylib 的行为复现件（按原版二进制逐条对齐）
// 目标: com.danlan.xiaolan (Blued 7.50.3) / iOS 14.0+ / arm64 + arm64e
//
// ============================================================================
// v2 修正说明（全部来自对原版 dylib + 宿主 App 的静态审计，非推测）
//   1) 所有 Hook 的方法签名已按宿主 App 的真实 Type Encoding 逐条对齐：
//        反查工具  _work/hosta.py class <Cls>   /  _work/audit_types.py
//        -[GJIMSessionService p_handlePushPackage:]  real = @24@0:8@16  (返回 id！)
//        -[BDGlobalConfig is_vip]                    real = @16@0:8     (返回 id)
//        -[BDGlobalConfig vip_status/vip_type/is_open_pic_ban_save] real = q16@0:8
//        -[BDGlobalConfig vip_expire_days]           real = @16@0:8
//        -[BDPersonPrivacyAlbumCollectView access_private_photos]
//              / privacy_photos_has_locked            real = i16@0:8
//        -[BDMessageViewController p_screenshotTip/p_screenshotWarning/
//              checkSendScreenshotTip]               real = v16@0:8     (void)
//        -[RecentlyVisitorViewController p_needToBuyVip] real = v16@0:8 (void)
//        -[BluedTabBar setBadgeValue:atItemIndex:]   real = v32@0:8Q16q24
//     v1 把上述 12 条写错（void<->id 等），会让调用者拿到脏寄存器 —— 真机首启
//     `-[PushPackage msgId]` 崩溃即由此暴露。
//   2) PushPackage 的真实字段是 messageId (Q16@0:8)，不是 msgId；
//      Blued 7.50.3 的 PushPackage 没有 msgId（宿主 97 个方法里查无此名）。
//      但存量插件 BluedHook_v0_2_5.dylib 里仍是裸 objc_msgSend(pkg, @selector(msgId))
//      （符号 _objc_msgSend$msgId，方法串带 P11PushPackage），一收到推送就抛
//      unrecognized selector。原版 dylib 的做法是 KVC + @try/@catch（函数 0x3029C
//      HushKeyValue / 0x30370 带 __objc_personality 的 NSDictionary 下标 / valueForKey:），
//      永远不让 selector 抛出去。本文件同时复刻该防御，并给 PushPackage 补上
//      msgId / setMsgId: 访问器（等价 messageId），从根上消掉这个崩溃。
//   3) %ctor 全程 @try/@catch 包裹，任何一步失败只记日志、绝不抛异常，
//      避免初始化污染导致二次启动 Hook 链整体失效。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdlib.h>

#define REA_TAG @"[REA-Test]"

#pragma mark - 安全取值 / 日志

// 复刻原版 HushKeyValue(obj, key)（0x3029C）：字典走下标，其他对象走 KVC，
// 全程 @try/@catch —— 这是原版"绝不因未知 key/selector 抛异常"的核心防御。
static id REAValue(id obj, NSString *key) {
    if (!obj || ![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
    @try {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            return [(NSDictionary *)obj objectForKey:key];
        }
        if ([obj isKindOfClass:[NSArray class]]) return nil;
        if ([obj respondsToSelector:NSSelectorFromString(key)]) {
            return [obj valueForKey:key];
        }
        return [obj valueForKey:key];   // KVC 容器/自定义 getter 场景，异常由 @catch 兜住
    } @catch (NSException *e) {
        return nil;
    }
}

static unsigned long long REAUInt(id obj, NSString *key) {
    id v = REAValue(obj, key);
    if (!v) return 0;
    @try {
        if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
            return [v unsignedLongLongValue];
        }
    } @catch (NSException *e) { }
    return 0;
}

static inline void REALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@ %@", REA_TAG, msg);
}

#pragma mark - 开关中心（等价原版 HushConfig isEnabled:，默认全开）

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

#pragma mark - PushPackage 兼容垫片（消掉 -[PushPackage msgId] 崩溃）

// 真实字段: messageId (Q16@0:8) / setMessageId: (v24@0:8Q16)
static unsigned long long REAMsgIdGetter(id self, SEL _cmd) {
    unsigned long long out = 0;
    @try {
        id v = REAValue(self, @"messageId");
        if ([v respondsToSelector:@selector(unsignedLongLongValue)]) out = [v unsignedLongLongValue];
        else if ([v isKindOfClass:[NSString class]]) out = strtoull([v UTF8String], NULL, 10);
    } @catch (NSException *e) { }
    return out;
}

static void REAMsgIdSetter(id self, SEL _cmd, unsigned long long v) {
    @try {
        if ([self respondsToSelector:NSSelectorFromString(@"setMessageId:")]) {
            [self setValue:@(v) forKey:@"messageId"];
        }
    } @catch (NSException *e) { }
}

// 给缺失 msgId 的宿主类补访问器；类型串与 messageId 完全一致，任何调用方都不会踩坑。
static void REAInstallMsgIdShim(Class cls) {
    if (!cls) return;
    @try {
        SEL g = NSSelectorFromString(@"msgId");
        SEL s = NSSelectorFromString(@"setMsgId:");
        if (!class_getInstanceMethod(cls, g)) {
            class_addMethod(cls, g, (IMP)REAMsgIdGetter, "Q16@0:8");
        }
        if (!class_getInstanceMethod(cls, s)) {
            class_addMethod(cls, s, (IMP)REAMsgIdSetter, "v24@0:8Q16");
        }
        REALog(@"msgId shim installed on %@ (msgId=%@, setMsgId:=%@)",
               NSStringFromClass(cls),
               class_getInstanceMethod(cls, g) ? @"yes" : @"no",
               class_getInstanceMethod(cls, s) ? @"yes" : @"no");
    } @catch (NSException *e) {
        REALog(@"msgId shim failed on %@", NSStringFromClass(cls));
    }
}

static void REAInstallAllShims(void) {
    REAInstallMsgIdShim(objc_getClass("PushPackage"));
    REAInstallMsgIdShim(objc_getClass("REQPackage"));
}

#pragma mark - 1. 消息 / 撤回对抗  switch_anti_recall

%hook GJIMMessageModel

// 原版 0x46F94: flag 关 → %orig；flag 开且原值非 0 → 强制 0
- (int)recallType {
    @try {
        int r = %orig;
        if (REAFlag(@"switch_anti_recall") && r != 0) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"anti-recall recallType %d -> 0", r);
            return 0;
        }
        return r;
    } @catch (NSException *e) { return 0; }
}

// 原版 0x47084: flag 开 → 恒 NO
- (BOOL)isSuperRecallTip {
    @try {
        if (REAFlag(@"switch_anti_recall")) {
            NSLog(@"[REA-Test] 注入成功");
            return NO;
        }
    } @catch (NSException *e) { }
    return %orig;
}

- (void)setRecallType:(int)type {
    @try {
        if (REAFlag(@"switch_anti_recall") && type != 0) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"blocked setRecallType:%d", type);
            return;
        }
    } @catch (NSException *e) { }
    %orig;
}

- (void)setIsSuperRecallTip:(BOOL)tip {
    @try {
        if (REAFlag(@"switch_anti_recall")) { %orig; return; }
    } @catch (NSException *e) { }
    %orig;
}

%end

#pragma mark - 2. 会话服务（推送 / 落库）

%hook GJIMSessionService

// real = @24@0:8@16 —— 必须返回 id，v1 写成 void 会让调用方拿到脏 x0
- (id)p_handlePushPackage:(id)pkg {
    id ret = nil;
    @try {
        if (pkg && ![pkg isKindOfClass:[NSObject class]]) {
            REALog(@"p_handlePushPackage: non-object arg, passthrough");
            return %orig;
        }
        if (REAFlag(@"switch_anti_recall")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"push package intercepted: cls=%@ messageId=%llu msgId=%llu",
                   pkg ? NSStringFromClass([pkg class]) : @"(nil)",
                   REAUInt(pkg, @"messageId"), REAUInt(pkg, @"msgId"));
        }
        ret = %orig;
        // 兜底：原实现若返回异常对象，转成 nil，避免调用方继续踩空
        if (ret && ![ret isKindOfClass:[NSObject class]]) ret = nil;
    } @catch (NSException *e) {
        REALog(@"p_handlePushPackage: exception swallowed: %@", e.reason);
        ret = nil;
    }
    return ret;
}

- (void)addMessage:(id)msg            { @try { %orig; } @catch (NSException *e) { } }
- (void)addMessages:(id)msgs          { @try { %orig; } @catch (NSException *e) { } }
- (void)updateMessage:(id)msg         { @try { %orig; } @catch (NSException *e) { } }

%end

// gji_* 系列在原版里挂在 GJIMMessageService 上（不是 GJIMSessionService）
%hook GJIMMessageService

- (void)deleteMessage:(id)msg {
    @try {
        if (REAFlag(@"switch_anti_recall")) REALog(@"deleteMessage intercepted");
        %orig;
    } @catch (NSException *e) { }
}

- (void)gji_updateMessage:(id)msg {
    @try { %orig; } @catch (NSException *e) { }
}

- (void)gji_insertForMessages:(id)msgs {
    @try { %orig; } @catch (NSException *e) { }
}

%end

%hook GJIMEngine

- (void)p_handleAMessageWithData:(id)data {
    @try { %orig; } @catch (NSException *e) { }
}

- (void)handleingGRPCPrivatePackage:(id)pkg {
    @try {
        if (REAFlag(@"switch_anti_recall") && pkg) {
            REALog(@"grpc package intercepted: cls=%@ messageId=%llu",
                   NSStringFromClass([pkg class]), REAUInt(pkg, @"messageId"));
        }
        %orig;
    } @catch (NSException *e) { }
}

%end

#pragma mark - 3. 聊天视图 / 阅后即焚  switch_flash_photo・switch_flash_text

%hook BDMessageViewController

- (void)setMessages:(id)msgs {
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_flash_text") && [msgs respondsToSelector:@selector(count)]) {
            REALog(@"setMessages count=%lu", (unsigned long)[msgs count]);
        }
        %orig;
    } @catch (NSException *e) { }
}

- (void)p_showDestoryTip:(id)tip {
    @try {
        if (REAFlag(@"switch_flash_photo")) { REALog(@"suppress destroy tip"); return; }
        %orig;
    } @catch (NSException *e) { }
}

// real = v16@0:8（void！v1 声明成 id 是 ABI 错误）
- (void)p_screenshotTip {
    @try {
        if (REAFlag(@"switch_screenshot")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"p_screenshotTip suppressed");
            return;
        }
        %orig;
    } @catch (NSException *e) { }
}

- (void)p_screenshotWarning {
    @try {
        if (REAFlag(@"switch_screenshot")) {
            NSLog(@"[REA-Test] 注入成功");
            REALog(@"p_screenshotWarning suppressed");
            return;
        }
        %orig;
    } @catch (NSException *e) { }
}

- (void)checkSendScreenshotTip {
    @try {
        if (REAFlag(@"switch_screenshot")) return;
        %orig;
    } @catch (NSException *e) { }
}

#pragma mark 3.1 反越狱 / 反模拟器 / 反调试（原版同时打了 BDMessageViewController 与 DLDeviceFingerprint）

- (BOOL)amIJailBroken                        { NSLog(@"[REA-Test] 注入成功"); return NO; }
- (BOOL)amIRunInEmulator                     { NSLog(@"[REA-Test] 注入成功"); return NO; }
- (BOOL)checkDYLD                            { return NO; }
- (BOOL)checkFork                            { return NO; }
- (BOOL)checkExistenceOfSuspiciousFiles      { return NO; }
- (BOOL)checkSuspiciousFilesCanBeOpened      { return NO; }
- (BOOL)checkRestrictedDirectoriesWriteable  { return NO; }
- (BOOL)checkSymbolicLinks                   { return NO; }
- (BOOL)checkURLSchemes                      { return NO; }
- (BOOL)emulatorCheckCompile                 { return NO; }
- (BOOL)emulatorCheckRuntime                 { return NO; }
- (void)performChecks                        { REALog(@"performChecks neutralised"); }
- (void)checkForkWithCompletion:(void (^)(BOOL))done {
    @try {
        if (done) done(NO);
    } @catch (NSException *e) { }
}

%end

%hook DLDeviceFingerprint

- (BOOL)amIJailBroken                        { NSLog(@"[REA-Test] 注入成功"); return NO; }
- (BOOL)amIRunInEmulator                     { return NO; }
- (BOOL)checkDYLD                            { return NO; }
- (BOOL)checkFork                            { return NO; }
- (BOOL)checkExistenceOfSuspiciousFiles      { return NO; }
- (BOOL)checkSuspiciousFilesCanBeOpened      { return NO; }
- (BOOL)checkRestrictedDirectoriesWriteable  { return NO; }
- (BOOL)checkSymbolicLinks                   { return NO; }
- (BOOL)checkURLSchemes                      { return NO; }
- (BOOL)emulatorCheckCompile                 { return NO; }
- (BOOL)emulatorCheckRuntime                 { return NO; }
- (void)performChecks                        { REALog(@"DLDeviceFingerprint performChecks neutralised"); }

%end

%hook NewKeyBoardPhotoView
- (void)resetLoadData { @try { %orig; } @catch (NSException *e) { } }
- (void)actionDes:(id)sender { @try { %orig; } @catch (NSException *e) { } }
%end

%hook NewKeyBoard
- (void)p_showKeyboardStateRecentPhoto { @try { %orig; } @catch (NSException *e) { } }
%end

#pragma mark - 4. 隐私相册  switch_private_photo

%hook BDPersonPrivacyAlbumCollectView

// real = i16@0:8（int，v1 声明成 id 直接返回 @YES 会把指针当 int 传出去）
- (int)access_private_photos {
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_private_photo")) return 1;
    } @catch (NSException *e) { }
    return %orig;
}

- (void)setAccess_private_photos:(int)v {
    @try { if (REAFlag(@"switch_private_photo")) return; %orig; } @catch (NSException *e) { }
}

- (int)privacy_photos_has_locked {
    @try { if (REAFlag(@"switch_private_photo")) return 0; } @catch (NSException *e) { }
    return %orig;
}

- (void)setPrivacy_photos_has_locked:(int)v {
    @try { if (REAFlag(@"switch_private_photo")) return; %orig; } @catch (NSException *e) { }
}

// setHidden:/setAlpha: 继承自 UIView；Logos 的 %hook 里没有 super 上下文，
// 用 objc_msgSendSuper 直接走父类实现，避免递归。
- (void)setHidden:(BOOL)hidden {
    @try {
        if (REAFlag(@"switch_private_photo") && hidden) {
            struct objc_super sp = { self, class_getSuperclass(object_getClass(self)) };
            ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sp, @selector(setHidden:), NO);
            return;
        }
    } @catch (NSException *e) { }
    %orig;
}

- (void)setAlpha:(CGFloat)alpha {
    @try {
        if (REAFlag(@"switch_private_photo") && alpha < 0.99) {
            struct objc_super sp = { self, class_getSuperclass(object_getClass(self)) };
            ((void (*)(struct objc_super *, SEL, CGFloat))objc_msgSendSuper)(&sp, @selector(setAlpha:), 1.0);
            return;
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

#pragma mark - 5. 本地 VIP  switch_local_vip

%hook BDGlobalConfig

// real = @16@0:8 → 必须是 id；返回本地 VIP 判定对象（NSNumber）
- (id)is_vip {
    @try {
        NSLog(@"[REA-Test] 注入成功");
        if (REAFlag(@"switch_local_vip")) return @YES;
    } @catch (NSException *e) { }
    return %orig;
}

// real = q16@0:8
- (NSInteger)vip_status {
    @try { if (REAFlag(@"switch_local_vip")) return 1; } @catch (NSException *e) { }
    return %orig;
}

- (NSInteger)vip_type {
    @try { if (REAFlag(@"switch_local_vip")) return 1; } @catch (NSException *e) { }
    return %orig;
}

// real = @16@0:8
- (id)vip_expire_days {
    @try { if (REAFlag(@"switch_local_vip")) return @(3650); } @catch (NSException *e) { }
    return %orig;
}

// real = q16@0:8
- (NSInteger)is_open_pic_ban_save {
    @try { if (REAFlag(@"switch_watermark")) return 0; } @catch (NSException *e) { }
    return %orig;
}

%end

#pragma mark - 6. 虚拟定位 / 海拔  switch_virtual_location・switch_altitude

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
            }
        } @catch (NSException *e) { }
    });
}

%hook CLLocation

- (CLLocationCoordinate2D)coordinate {
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_virtual_location")) {
        NSLog(@"[REA-Test] 注入成功");
        return CLLocationCoordinate2DMake(gREALat, gREALng);
    }
    return %orig;
}

- (CLLocationDistance)altitude {
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_altitude")) return gREAAlt;
    return %orig;
}

%end

%hook CLLocationManager
- (CLLocation *)location {
    REALoadFakeLocation();
    if (gREAHasFakeCoord && REAFlag(@"switch_virtual_location")) {
        NSLog(@"[REA-Test] 注入成功");
        return [[CLLocation alloc] initWithLatitude:gREALat longitude:gREALng];
    }
    return %orig;
}
%end

#pragma mark - 7. 访客 / 会话列表

%hook RecentlyVisitorViewController

// real = v16@0:8（void）
- (void)p_needToBuyVip {
    @try { if (REAFlag(@"switch_local_vip")) { REALog(@"p_needToBuyVip suppressed"); return; } %orig; }
    @catch (NSException *e) { }
}

%end

%hook BluedTabBar

- (void)setBadgeValue:(unsigned long long)v atItemIndex:(NSInteger)i {
    @try { REALog(@"badge=%llu at %ld", v, (long)i); %orig; } @catch (NSException *e) { }
}

- (void)setCustomImage:(id)img atItemIndex:(NSInteger)i {
    @try { %orig; } @catch (NSException *e) { }
}

%end

#pragma mark - 8. 入口（原版 %ctor = 主安装器 0x434C0；本文件 Hook 由 Logos 在 load 时安装）

%ctor {
    @try {
        NSLog(@"[REA-Test] 注入成功");
        @autoreleasepool {
            REALog(@"BluedHushREA v2 loaded, pid=%d", getpid());

            // 1) 补 PushPackage.msgId（存量插件 BluedHook 的裸 msgSel 依赖它）
            REAInstallAllShims();

            // 2) Hook 链自检：Logos 已按 %hook 安装完毕，这里只做存活清点
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
            REALog(@"hooked-classes alive %lu/%lu: %@",
                   (unsigned long)alive.count, (unsigned long)probe.count,
                   [alive componentsJoinedByString:@","]);
        }
    } @catch (NSException *e) {
        NSLog(@"%@ ctor exception swallowed: %@", REA_TAG, e.reason);
    }
}
