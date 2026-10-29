// BluedHushREA —— BluedHush_5.19.dylib 的行为复现件
// 目标: com.danlan.xiaolan (Blued 7.50.3) / iOS 14.0+ / arm64 + arm64e
//
// 本文件由静态逆向结果生成:
//   1) Hook 目标 = 从 LC_DYLD_CHAINED_FIXUPS + __objc_methlist(relative) 解出的 557 处
//      _MSHookMessageEx 调用点中的高价值子集(代号见 docs/STAGE2_核心逻辑逆向报告.md)
//   2) 开关体系 = [[HushConfig shared] isEnabled:@"switch_xxx"] 的等价实现(默认全开)
//   3) 关键 Hook 处固定输出  NSLog(@"[REA-Test] 注入成功");

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#define REA_SWITCH_PREFIX @"switch_"

static NSString *const kREALogTag = @"[REA-Test]";

#pragma mark - 开关中心（等价于 HushConfig）

// 原插件: [[HushConfig shared] isEnabled:@"switch_anti_recall"]（CFString 常量表 0x200C38..0x200E28）
// 复现件: 读同一批键名，未设置时默认 YES（即全部功能开启）
static BOOL REAFlag(NSString *key) {
    static NSMutableDictionary<NSString *, NSNumber *> *gCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCache = [NSMutableDictionary dictionary];
    });
    @synchronized (gCache) {
        NSNumber *cached = gCache[key];
        if (cached) return cached.boolValue;
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        BOOL on = (v == nil) ? YES : [v boolValue];
        gCache[key] = @(on);
        return on;
    }
}

static inline void REALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@ %@", kREALogTag, msg);
}

#pragma mark - 1. 消息 / 撤回对抗  switch_anti_recall

%hook GJIMMessageModel

// 0x46F94: flag && orig!=0 → 强制 0
- (NSInteger)recallType {
    NSInteger r = %orig;
    if (REAFlag(@"switch_anti_recall") && r != 0) {
        NSLog(@"[REA-Test] 注入成功");
        REALog(@"anti-recall recallType %ld -> 0", (long)r);
        return 0;
    }
    return r;
}

// 0x47084: flag → 恒 NO
- (BOOL)isSuperRecallTip {
    if (REAFlag(@"switch_anti_recall")) {
        NSLog(@"[REA-Test] 注入成功");
        return NO;
    }
    return %orig;
}

- (void)setRecallType:(NSInteger)type {
    if (REAFlag(@"switch_anti_recall")) {
        NSLog(@"[REA-Test] 注入成功");
        REALog(@"blocked setRecallType:%ld", (long)type);
        return;
    }
    %orig;
}

- (void)setIsSuperRecallTip:(BOOL)tip {
    if (REAFlag(@"switch_anti_recall")) { %orig; return; }
    %orig;
}

%end

%hook GJIMSessionService

- (void)p_handlePushPackage:(id)pkg {
    if (REAFlag(@"switch_anti_recall")) REALog(@"push package intercepted");
    %orig;
}

- (void)addMessage:(id)msg            { %orig; }
- (void)addMessages:(id)msgs          { %orig; }
- (void)updateMessage:(id)msg         { %orig; }
- (void)gji_updateMessage:(id)msg     { %orig; }
- (void)gji_insertForMessages:(id)m   { %orig; }

%end

%hook GJIMMessageService
- (void)deleteMessage:(id)msg {
    if (REAFlag(@"switch_anti_recall")) REALog(@"deleteMessage intercepted");
    %orig;
}
%end

%hook GJIMEngine
- (void)p_handleAMessageWithData:(id)data { %orig; }
- (void)handleingGRPCPrivatePackage:(id)pkg { %orig; }
%end

#pragma mark - 2. 聊天视图 / 阅后即焚  switch_flash_photo・switch_flash_text

%hook BDMessageViewController

- (void)setMessages:(id)msgs {
    NSLog(@"[REA-Test] 注入成功");
    if (REAFlag(@"switch_flash_text")) REALog(@"setMessages count=%lu", (unsigned long)[msgs count]);
    %orig;
}

- (void)p_showDestoryTip:(id)tip {
    if (REAFlag(@"switch_flash_photo")) { REALog(@"suppress destroy tip"); return; }
    %orig;
}

// 截图提示三连（0x4B2E0 / 0x4B1FC / 0x4B3C4）
- (id)p_screenshotTip {
    if (REAFlag(@"switch_screenshot")) { NSLog(@"[REA-Test] 注入成功"); return nil; }
    return %orig;
}

- (id)p_screenshotWarning {
    if (REAFlag(@"switch_screenshot")) { NSLog(@"[REA-Test] 注入成功"); return nil; }
    return %orig;
}

- (BOOL)checkSendScreenshotTip {
    if (REAFlag(@"switch_screenshot")) return NO;
    return %orig;
}

%end

%hook NewKeyBoardPhotoView
- (void)resetLoadData { %orig; }
- (void)actionDes:(id)sender { %orig; }
%end

%hook NewKeyBoard
- (void)p_showKeyboardStateRecentPhoto { %orig; }
%end

#pragma mark - 3. 隐私相册  switch_private_photo

%hook BDPersonPrivacyAlbumCollectView

- (id)access_private_photos {
    NSLog(@"[REA-Test] 注入成功");
    if (REAFlag(@"switch_private_photo")) return @YES;
    return %orig;
}

- (void)setAccess_private_photos:(id)v { %orig; }

- (BOOL)privacy_photos_has_locked {
    if (REAFlag(@"switch_private_photo")) return NO;
    return %orig;
}

- (void)setPrivacy_photos_has_locked:(BOOL)v {
    if (REAFlag(@"switch_private_photo")) { return; }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (REAFlag(@"switch_private_photo")) {
        [super setHidden:NO];
        return;
    }
    %orig;
}

- (void)setAlpha:(CGFloat)alpha {
    if (REAFlag(@"switch_private_photo")) { [super setAlpha:1.0]; return; }
    %orig;
}

%end

#pragma mark - 4. 本地 VIP  switch_local_vip

%hook BDGlobalConfig

- (BOOL)is_vip {
    NSLog(@"[REA-Test] 注入成功");
    if (REAFlag(@"switch_local_vip")) return YES;
    return %orig;
}

- (id)vip_status {
    if (REAFlag(@"switch_local_vip")) return @1;
    return %orig;
}

- (id)vip_type {
    if (REAFlag(@"switch_local_vip")) return @1;
    return %orig;
}

- (NSInteger)vip_expire_days {
    if (REAFlag(@"switch_local_vip")) return 3650;
    return %orig;
}

// 存图限制 / 水印  switch_watermark
- (BOOL)is_open_pic_ban_save {
    if (REAFlag(@"switch_watermark")) return NO;
    return %orig;
}

%end

#pragma mark - 5. 反越狱 / 反模拟器 / 反调试（BDMessageViewController 12 连打）

%hook BDMessageViewController

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
- (void)checkForkWithCompletion:(id)done     { if (done) { ((void (^)(BOOL))done)(NO); } }

%end

#pragma mark - 6. 虚拟定位 / 海拔  switch_virtual_location・switch_altitude

static BOOL gREAHasFakeCoord = NO;
static CLLocationDegrees gREALat = 0.0, gREALng = 0.0;
static CLLocationDistance gREAAlt = 0.0;

static void REALoadFakeLocation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"rea_fake_location"];
        if (d) {
            gREALat = [d[@"lat"] doubleValue];
            gREALng = [d[@"lng"] doubleValue];
            gREAAlt = [d[@"alt"] doubleValue];
            gREAHasFakeCoord = YES;
        }
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
- (BOOL)p_needToBuyVip {
    if (REAFlag(@"switch_local_vip")) return NO;
    return %orig;
}
%end

%hook BluedTabBar
- (void)setBadgeValue:(id)v atItemIndex:(NSInteger)i { %orig; }
- (void)setCustomImage:(id)img atItemIndex:(NSInteger)i { %orig; }
%end

#pragma mark - 8. 入口

%ctor {
    @autoreleasepool {
        NSLog(@"[REA-Test] 注入成功");
        REALog(@"BluedHushREA loaded, pid=%d, image=%p", getpid(), (void *)&REAFlag);

        // 运行时清点：原插件 557 个 Hook 点分布在 ~90 个宿主类上，这里打印存活情况
        NSArray<NSString *> *probe = @[
            @"GJIMMessageModel", @"GJIMSessionService", @"GJIMMessageService", @"GJIMEngine",
            @"BDMessageViewController", @"NewKeyBoard", @"NewKeyBoardPhotoView",
            @"BDPersonPrivacyAlbumCollectView", @"BDGlobalConfig", @"CLLocationManager",
            @"CLLocation", @"RecentlyVisitorViewController", @"BluedTabBar", @"DLDeviceFingerprint"
        ];
        NSMutableArray *alive = [NSMutableArray array];
        for (NSString *n in probe) {
            if (objc_getClass(n.UTF8String)) [alive addObject:n];
        }
        REALog(@"hooked-classes alive %lu/%lu: %@",
               (unsigned long)alive.count, (unsigned long)probe.count,
               [alive componentsJoinedByString:@","]);
    }
}
