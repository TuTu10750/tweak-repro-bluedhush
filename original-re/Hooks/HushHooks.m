// HushHooks.m — table-driven hook layer (road B, first 5 targets)
//
// This file is MRC (-fno-objc-arc). Every hook body is a passthrough, but under
// ARC the compiler would still emit objc_storeStrong() for object-typed
// parameters — the canonical crash is BDNetworkAgent -sessionTaskForRequest:error:
// whose `error:` is `NSError **` (encoding ^@): that spurious retain reads a
// bogus isa and dies at 0x20. MRC sidesteps it for every hook whose signature we
// could not resolve.
//
// Design notes:
//   1. Classes resolve at RUNTIME, never at +load: Swift classes register late.
//      Resolution order matches how the ObjC runtime actually names things:
//        objc_getClass(name)  →  NSClassFromString(name)
//        → if name has no dot:  NSClassFromString("Blued." + name)   [Swift]
//        → if name has a dot:   strip to the tail, objc_getClass / NSClassFromString
//   2. Type encodings come from the live Method (method_getTypeEncoding). A
//      hardcoded encoding cannot survive a host rebuild; the only exception is
//      the `class_addMethod` fallback for a selector the host does not have at
//      all (that one is never called, so the value only has to be safe).
//   3. Installation NEVER trusts class_replaceMethod's return value as "the old
//      IMP". Per the runtime source, when the class has no entry for the
//      selector, class_replaceMethod degrades to class_addMethod and returns the
//      NEW imp — assigning that to orig produces infinite recursion (stack
//      overflow on the first call, with the crash pointing at our own
//      replacement, which reads like "the hook installed fine but crashes").
//      So we install in three explicit branches:
//        own       — entry is in this class's method list: method_setImplementation
//        inherit   — only a superclass has it: class_addMethod on this class,
//                    orig = the superclass IMP
//        added     — nobody has it: class_addMethod, orig = NULL (body guards)
//   4. Installation is idempotent per target. The ctor plus four delayed retries
//      exist because Swift / dynamically loaded IM frameworks register after our
//      ctor; without a "done" latch the second pass would method_setImplementation
//      our own replacement and make orig == repl — the same recursion as above.
//   5. Every replacement stamps HushHit() on entry, so "did the host ever reach
//      this override" is answerable from a log alone, no debugger.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <dispatch/dispatch.h>
#import <CommonCrypto/CommonCrypto.h>

#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushRecallGuard.h"

extern void HushHit(const char *cls, const char *sel);

// ---------------------------------------------------------------- counters
int gHushHooksTotal    = 0;
int gHushHooksOwn      = 0;
int gHushHooksInherit  = 0;
int gHushHooksMissing  = 0;
int gHushHooksNoTypes  = 0;
int gHushHooksAdded    = 0;
int gHushHooksSkipped  = 0;

// ---------------------------------------------------------------- class resolve
// Order matters. A bare Swift name only resolves through the module-qualified
// form ("Blued.BDCustomMenuView"), never the reverse: objc_getClass("BDCustomMenuView")
// is nil because the runtime name carries the module prefix (or the _TtC mangling).
static Class hush_resolve_class(const char *name) {
    if (!name || !*name) return Nil;

    Class c = objc_getClass(name);
    if (c) return c;

    NSString *n = [NSString stringWithUTF8String:name];
    if (!n) return Nil;

    c = NSClassFromString(n);
    if (c) return c;

    const char *dot = strchr(name, '.');
    if (!dot) {
        // No module prefix: this is most likely a Swift class the log printed bare.
        c = NSClassFromString([@"Blued." stringByAppendingString:n]);
        if (c) return c;
        return Nil;
    }

    // Prefixed name: an ObjC class the log happened to print as "Blued.Foo".
    const char *tail = strrchr(name, '.') + 1;
    if (*tail) {
        c = objc_getClass(tail);
        if (c) return c;
        c = NSClassFromString([NSString stringWithUTF8String:tail]);
        if (c) return c;
    }
    return Nil;
}

// 22/23: the two nodes the reference log says actually carry a recall packet.
// Both forward instead of swallowing the call — see HushRecallGuard.m.
extern void HushSetSessionService(id svc);
static void (*o_sessionAddMessages)(id, SEL, id);
static void r_sessionAddMessages(id self, SEL _cmd, id a0) {
    HushHit("GJIMSessionService", "addMessages:");
    // v55 B：GJIMSessionService 没有 sharedInstance（sel_index 全表核实），
    // 落库要用它的 -updateMessage:，只能在这里把 self 抓下来缓存。
    if (self) HushSetSessionService(self);
    HushRecallFilterAndForward(self, _cmd, a0, o_sessionAddMessages);
}

static void (*o_dbUpdateMessage)(id, SEL, id);
static void r_dbUpdateMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMDBService", "p_updateMessage:");
    HushRecallGuardSingleWrite(self, _cmd, a0, o_dbUpdateMessage);
}


// 24/25: the UI leg. hooo1 shows the recall reaching the table view through
//   ChatVC.receiveNewMessage  /  ChatVC.updateMessages updateType=1 NSArray(4)
// v27 proved the DB write is blocked and the row survives in sqlite, yet the open
// chat page still hid the message — the in-memory model is what the table renders,
// so it has to be filtered here too.
static void (*o_chatUpdateMessages)(id, SEL, id, unsigned long long);
static void r_chatUpdateMessages(id self, SEL _cmd, id a0, unsigned long long a1) {
    HushHit("PrivateChatViewController", "updateMessages:updateType:");
    HushRecallFilterArrayForward(self, _cmd, a0, a1, o_chatUpdateMessages);
}

static void (*o_msgVCReceiveNewMessage)(id, SEL, id);
static void r_msgVCReceiveNewMessage(id self, SEL _cmd, id a0) {
    HushHit("BDMessageViewController", "receiveNewMessage:");
    HushRecallDropSingleForward(self, _cmd, a0, o_msgVCReceiveNewMessage);
}

// 26: chat cell — 「已拦截」badge.
// hooo1 never shows a badge because the original's recall path was different; the
// badge is our own affordance, so the rule is: only models WE neutralised
// (associated flag) get it, and every other message hides it on reuse.
static void (*o_cellSetMessage)(id, SEL, id);
static void r_cellSetMessage(id self, SEL _cmd, id a0) {
    HushHit("BDChatBasicCell", "setMessage:");
    if (o_cellSetMessage) o_cellSetMessage(self, _cmd, a0);
    HushRecallDecorateCell(self, a0);
}

// 27-29: splash ad. removeAllSplashAdViews: alone only removes the views that are
// already on screen; the cold-launch query and the present call still run, so the
// ad flashes on fast networks. Short-circuit both, gated by purify_splash_ad.
static BOOL HushSplashPurifyOn(void) {
    return [[HushConfig shared] isEnabled:@"purify_splash_ad"];
}

static void (*o_showSplashAd)(id, SEL, BOOL);
static void r_showSplashAd(id self, SEL _cmd, BOOL a0) {
    HushHit("AppDelegateModel", "showSplashAd:");
    if (HushSplashPurifyOn()) return;          // 不展示开屏
    if (o_showSplashAd) o_showSplashAd(self, _cmd, a0);
}

// v40: hasNoneSplashShow — 开屏盖板的「是否需要展示」总闸。
//
// 前面那两个 cold-launch *query* 只能拿掉广告数据，宿主拿不到数据后仍会走自己的
// 兜底路径（默认启动图 / 品牌页），所以「卡 logo」没被真正解决。这个方法在
// BDIndexPageCoversManager 上，sel_index 确认签名是 `B16@0:8`（无参、BOOL 返回），
// 语义就是「有没有一个不需要放 ad 的开屏」。恒 YES = 告诉宿主「别铺盖板了，直接
// 进主页」，比我方在 showSplashAd: 里吞要早一整层 —— 盖板根本没被创建。
//
// 纯 getter，无副作用，关掉配置就走原版。
static BOOL (*o_hasNoneSplashShow)(id, SEL);
static BOOL r_hasNoneSplashShow(id self, SEL _cmd) {
    HushHit("BDIndexPageCoversManager", "hasNoneSplashShow");
    if (HushSplashPurifyOn()) return YES;
    return o_hasNoneSplashShow ? o_hasNoneSplashShow(self, _cmd) : NO;
}

// v39 fix: the two cold-launch *queries* must pass through.
//
// They used to return nil when purify_splash_ad was on. purify_* keys inherit
// purify_master's value (HushConfig.m:201), and purify_master defaults to 1 —
// so in practice both getters always returned nil. The host takes that nil and
// keeps waiting on it during launch, which is exactly the "stuck on the logo"
// symptom reported on device (hush.log 20:41–20:42, watchdog silent, so it was
// never a main-thread block).
//
// Suppressing *presentation* is safe — showSplashAd: returns void and nobody
// waits for a callback — so the purify switch now only guards r_showSplashAd.
// removeAllSplashAdViews: stays hooked on its own to clean up any leftover view.
static id (*o_getSplashCold)(id, SEL);
static id r_getSplashCold(id self, SEL _cmd) {
    HushHit("AppDelegateModel", "getSplashAdForColdLaunch");
    return o_getSplashCold ? o_getSplashCold(self, _cmd) : nil;
}

static id (*o_pGetSplashCold)(id, SEL);
static id r_pGetSplashCold(id self, SEL _cmd) {
    HushHit("AppDelegateModel", "p_getSplashAdvertisementForColdLaunch");
    return o_pGetSplashCold ? o_pGetSplashCold(self, _cmd) : nil;
}

// 30-35: privacy album. The host gates the album on three int flags on
// UserInformation; the getters are the read side every caller goes through, so
// forcing 0 there unlocks it. Setters are swallowed too — otherwise the host
// re-writes 1 the moment it re-syncs the profile and the album locks again.
static BOOL HushPrivacyUnlockOn(void) {
    return [[HushConfig shared] isEnabled:@"switch_private_photo"];
}

static int (*o_isLocked)(id, SEL);
static int r_isLocked(id self, SEL _cmd) {
    HushHit("UserInformation", "is_locked");
    if (HushPrivacyUnlockOn()) return 0;
    return o_isLocked ? o_isLocked(self, _cmd) : 0;
}

static int (*o_privPhotoLocked)(id, SEL);
static int r_privPhotoLocked(id self, SEL _cmd) {
    HushHit("UserInformation", "privacy_photos_has_locked");
    if (HushPrivacyUnlockOn()) return 0;
    return o_privPhotoLocked ? o_privPhotoLocked(self, _cmd) : 0;
}

static int (*o_albumBanSave)(id, SEL);
static int r_albumBanSave(id self, SEL _cmd) {
    HushHit("UserInformation", "album_ban_save");
    if (HushPrivacyUnlockOn()) return 0;
    return o_albumBanSave ? o_albumBanSave(self, _cmd) : 0;
}

static void (*o_setIsLocked)(id, SEL, int);
static void r_setIsLocked(id self, SEL _cmd, int a0) {
    HushHit("UserInformation", "setIs_locked:");
    if (HushPrivacyUnlockOn()) return;         // 不接受宿主写回 1
    if (o_setIsLocked) o_setIsLocked(self, _cmd, a0);
}

static void (*o_setPrivPhotoLocked)(id, SEL, int);
static void r_setPrivPhotoLocked(id self, SEL _cmd, int a0) {
    HushHit("UserInformation", "setPrivacy_photos_has_locked:");
    if (HushPrivacyUnlockOn()) return;
    if (o_setPrivPhotoLocked) o_setPrivPhotoLocked(self, _cmd, a0);
}

static void (*o_setAlbumBanSave)(id, SEL, int);
static void r_setAlbumBanSave(id self, SEL _cmd, int a0) {
    HushHit("UserInformation", "setAlbum_ban_save:");
    if (HushPrivacyUnlockOn()) return;
    if (o_setAlbumBanSave) o_setAlbumBanSave(self, _cmd, a0);
}

// 35: probe only — 同步通道。推送腿吞包之后，断网期间发生的撤回只可能从
// GJIMMessageService -p_handleSyncRangeMessages:syncType: 进来。这里只数不改：
// 数到 0 说明同步包不带撤回，数到 >0 就是下一版要拦的第二个投递口。
static void (*o_syncRange)(id, SEL, id, unsigned long long);
static void r_syncRange(id self, SEL _cmd, id a0, unsigned long long a1) {
    HushHit("GJIMMessageService", "p_handleSyncRangeMessages:syncType:");
    int n = HushRecallScanArrayForRecall(a0);
    if (n > 0) {
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush][防撤回] 同步批次 syncType=%llu 带 %d 条撤回（第二个投递口）",
            a1, n]];
    }
    if (o_syncRange) o_syncRange(self, _cmd, a0, a1);
}

// v37: the BDMessageTableView -deleteRowsAtIndexPaths: probe is gone.
// The reference log never deletes a row for a recall (it swallows the gRPC
// packet, so the data source never changes), and a probe that only counts hits
// has no lawful veto. Deleted per review; re-add only with an actual fix.
//
// ---------------------------------------------------------------- install
typedef struct {
    IMP         prev;
    const char *kind;    // own | inherit | added | MISSING
    const char *types;
} hush_installed;

// Find the entry in THIS class's method list only (class_getInstanceMethod walks
// the superclass chain, which is exactly what we must not treat as "own").
static Method hush_own_method(Class c, SEL sel) {
    unsigned int n = 0;
    Method found = NULL;
    Method *list = class_copyMethodList(c, &n);
    if (list) {
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(list[i]) == sel) { found = list[i]; break; }
        }
        free(list);
    }
    return found;
}

static hush_installed hush_install_impl(Class c, SEL sel, IMP repl,
                                       const char *fallbackTypes) {
    hush_installed r = { NULL, "MISSING", NULL };
    if (!c) return r;

    // ---- branch 1: this class owns the selector
    Method own = hush_own_method(c, sel);
    if (own) {
        r.types = method_getTypeEncoding(own);
        r.prev  = method_setImplementation(own, repl);   // real old IMP
        r.kind  = "own";
        return r;
    }

    // ---- branch 2: a superclass owns it; override it here
    Method inh = class_getInstanceMethod(c, sel);
    if (inh) {
        r.types = method_getTypeEncoding(inh);
        IMP parent = method_getImplementation(inh);
        if (class_addMethod(c, sel, repl, r.types)) {
            r.prev = parent;                             // real parent IMP
            r.kind = "inherit";
            return r;
        }
        // Already present but not in copyMethodList (racy load): replace, and
        // only accept the return value if it is genuinely a different IMP.
        IMP old = class_replaceMethod(c, sel, repl, r.types);
        r.prev = (old && old != repl) ? old : NULL;
        r.kind = r.prev ? "inherit" : "own-noorig";
        return r;
    }

    // ---- branch 3: nobody has it. Add it so the host *could* call it; orig
    // stays NULL and every body guards on that.
    r.types = fallbackTypes;
    if (class_addMethod(c, sel, repl, fallbackTypes)) {
        r.kind = "added";
        return r;
    }
    return r;                                            // MISSING
}

// ---------------------------------------------------------------- targets
// 1. GJIMMessageService -p_filterDeletedMessages:   (@24@0:8@16)
static id (*o_filterDeleted)(id, SEL, id);
static id r_filterDeleted(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "p_filterDeletedMessages:");
    // PASSTHROUGH. Returning nil here used to look like "keep everything", but
    // the selector name says it FILTERS: the host expects the filtered array
    // back and iterates it. Handing back nil emptied the message list instead
    // of preserving it -- the private chat showed no history and a sent message
    // never appeared, while the send itself succeeded. Recall protection lives
    // in the poller (HushAntiRevoke.m); a hook may only observe until the hit
    // table proves which node actually carries the recall.
    return o_filterDeleted ? o_filterDeleted(self, _cmd, a0) : nil;
}

// 2. GJIMDBService -dealMessage:array:   (v32@0:8@16@24) — the write path into sqlite
static void (*o_dealMessage)(id, SEL, id, id);
static void r_dealMessage(id self, SEL _cmd, id a0, id a1) {
    HushHit("GJIMDBService", "dealMessage:array:");
    // v35 起 UI 腿是原地改：宿主手里那个对象此刻可能是 type=1 / 补过占位正文。
    // 这条是写库入口之一，落库前把被我们改过的字段还原，否则占位文案会进库。
    HushRecallRestoreDirtyArray(a1);
    if (o_dealMessage) o_dealMessage(self, _cmd, a0, a1);
}

// 3. GJIMSessionService -clearSessionAndMessageWithToken:   (v24@0:8@16)
//    NOTE: this is the "delete the whole session" path, not the per-message
//    recall path. It is here to keep the session list intact, nothing more.
static void (*o_clearSessionAndMessage)(id, SEL, id);
static void r_clearSessionAndMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMSessionService", "clearSessionAndMessageWithToken:");
    // PASSTHROUGH: see r_deleteMessage.
    if (o_clearSessionAndMessage) o_clearSessionAndMessage(self, _cmd, a0);
}

// 4. GJIMMessageService -deleteMessage:   (v24@0:8@16) — the actual recall path
static void (*o_deleteMessage)(id, SEL, id);
static void r_deleteMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "deleteMessage:");
    // PASSTHROUGH for now: swallowing the call leaves the host's own message
    // list and DB out of sync, which is the same "sent but invisible" symptom.
    if (o_deleteMessage) o_deleteMessage(self, _cmd, a0);
}

// 5. AppDelegateModel -removeAllSplashAdViews:   (v24@0:8q16)
//    Control group: the log proves the original reached this one.
static void (*o_removeAllSplash)(id, SEL, long long);
static void r_removeAllSplash(id self, SEL _cmd, long long a0) {
    HushHit("AppDelegateModel", "removeAllSplashAdViews:");
    if (o_removeAllSplash) o_removeAllSplash(self, _cmd, a0);
}


// ---------------------------------------------------------------- B1 expansion
// 6. BluedTabBar -p_changeItemStateAtIndex:   (v24@0:8Q16)
static void (*o_changeItemState)(id, SEL, unsigned long long);
static void r_changeItemState(id self, SEL _cmd, unsigned long long a0) {
    HushHit("BluedTabBar", "p_changeItemStateAtIndex:");
    if (o_changeItemState) o_changeItemState(self, _cmd, a0);
}

// 7. BluedTabBar -selectItemAtIndex:   (v24@0:8q16)
static void (*o_selectItem)(id, SEL, long long);
static void r_selectItem(id self, SEL _cmd, long long a0) {
    HushHit("BluedTabBar", "selectItemAtIndex:");
    if (o_selectItem) o_selectItem(self, _cmd, a0);
}

// 8. BluedTabBar -selectItemAtIndex:subIndex:   (v32@0:8q16q24)
static void (*o_selectItemSub)(id, SEL, long long, long long);
static void r_selectItemSub(id self, SEL _cmd, long long a0, long long a1) {
    HushHit("BluedTabBar", "selectItemAtIndex:subIndex:");
    if (o_selectItemSub) o_selectItemSub(self, _cmd, a0, a1);
}

// 9. BluedTabBar -setDynamicImgView:   (v24@0:8@16)
static void (*o_setDynamicImg)(id, SEL, id);
static void r_setDynamicImg(id self, SEL _cmd, id a0) {
    HushHit("BluedTabBar", "setDynamicImgView:");
    if (o_setDynamicImg) o_setDynamicImg(self, _cmd, a0);
}

// 10. Blued.BDCustomMenuView -hideMenu     host owners: only BDLongPressMenuView
//     and LynxTextView, so this one is expected to land on added (prev NULL).
static void (*o_menuHide)(id, SEL);
static void r_menuHide(id self, SEL _cmd) {
    HushHit("Blued.BDCustomMenuView", "hideMenu");
    if (o_menuHide) o_menuHide(self, _cmd);
}

// 11. Blued.BDCustomMenuView -layoutSubviews     UIView owns it, the Swift class
//     is not among the 421 host implementors -> this is the inherit probe.
static void (*o_menuLayout)(id, SEL);
static void r_menuLayout(id self, SEL _cmd) {
    HushHit("Blued.BDCustomMenuView", "layoutSubviews");
    if (o_menuLayout) o_menuLayout(self, _cmd);
}

// 12. Blued.BDCustomMenuView -reloadData     inherit if the class is a table
//     view, otherwise added.
static void (*o_menuReload)(id, SEL);
static void r_menuReload(id self, SEL _cmd) {
    HushHit("Blued.BDCustomMenuView", "reloadData");
    if (o_menuReload) o_menuReload(self, _cmd);
}

// 13. PrivateChatViewController -layoutSubviews   *** REMOVED IN v26 ***
//     This target landed on the `added` branch: the controller has no method of
//     its own and UIViewController never implements layoutSubviews, so
//     class_addMethod() put a stub on the controller itself. That stub sits in
//     front of nothing useful but it does shadow the lookup for every subclass
//     instance that walks the chain looking for a layout hook. Removing it is
//     the only way to tell whether the empty private-chat list was caused by
//     this install or by the recall probes. Slot 12 is kept (marked done) so the
//     per-target indices of every later probe stay stable.

// 14. PrivateChatViewController -viewDidAppear:   (v20@0:8B16, BOOL argument)
static void (*o_chatViewDidAppear)(id, SEL, BOOL);
static void r_chatViewDidAppear(id self, SEL _cmd, BOOL a0) {
    HushHit("PrivateChatViewController", "viewDidAppear:");
    if (o_chatViewDidAppear) o_chatViewDidAppear(self, _cmd, a0);
}

// ---------------------------------------------------------------- P0 expansion
// The recall data flow, in the order the host walks it:
//   deleteMessage:                              ← action entry  (target 4, already own)
//     → p_filterDeletedMessages:                ← post-recall filter (target 1, already own)
//     → p_findLeakMessageIdsWithMessages:needAddMsg:   ← find leaked ids
//     → p_sortAndUniqMessages:descend:          ← re-sort after removal
//     → updateMessage: / addMessages: / clearMessages  ← the three write paths
// Fetch side, to see whether a fetch still carries the deleted rows:
//   fetchMessagesWithStartMsgId:endMsgId:isTempChat:
//   fetchMoreMessagesFromMessage:isTempChat:isDown:
// Every one of these is a pure passthrough probe: it stamps HushHit and calls
// through. Behaviour changes only after the hit table tells us which node the
// host actually walks on recall.
static id (*o_findLeakIds)(id, SEL, id, BOOL);
static id r_findLeakIds(id self, SEL _cmd, id a0, BOOL a1) {
    HushHit("GJIMMessageService", "p_findLeakMessageIdsWithMessages:needAddMsg:");
    return o_findLeakIds ? o_findLeakIds(self, _cmd, a0, a1) : nil;
}

static id (*o_sortUniq)(id, SEL, id, BOOL);
static id r_sortUniq(id self, SEL _cmd, id a0, BOOL a1) {
    HushHit("GJIMMessageService", "p_sortAndUniqMessages:descend:");
    return o_sortUniq ? o_sortUniq(self, _cmd, a0, a1) : nil;
}

static void (*o_updateMessage)(id, SEL, id);
static void r_updateMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "updateMessage:");
    if (o_updateMessage) o_updateMessage(self, _cmd, a0);
}

static void (*o_addMessages)(id, SEL, id);
static void r_addMessages(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "addMessages:");
    if (o_addMessages) o_addMessages(self, _cmd, a0);
}

static void (*o_clearMessages)(id, SEL);
static void r_clearMessages(id self, SEL _cmd) {
    HushHit("GJIMMessageService", "clearMessages");
    if (o_clearMessages) o_clearMessages(self, _cmd);
}

static void (*o_fetchFrom)(id, SEL, unsigned long long, unsigned long long, BOOL);
static void r_fetchFrom(id self, SEL _cmd, unsigned long long a0, unsigned long long a1, BOOL a2) {
    HushHit("GJIMMessageService", "fetchMessagesWithStartMsgId:endMsgId:isTempChat:");
    if (o_fetchFrom) o_fetchFrom(self, _cmd, a0, a1, a2);
}

static void (*o_fetchMore)(id, SEL, id, BOOL, BOOL);
static void r_fetchMore(id self, SEL _cmd, id a0, BOOL a1, BOOL a2) {
    HushHit("GJIMMessageService", "fetchMoreMessagesFromMessage:isTempChat:isDown:");
    if (o_fetchMore) o_fetchMore(self, _cmd, a0, a1, a2);
}

// 37: the packet entry — where the reference log actually kills a recall.
//   GJIMEngine.handleingGRPCPrivatePackage PushPackage messageType=55 … messageId=75
//   [Chat] 已拦截撤回（吞掉 type=55 推送包）msgId=75
// Swallowing here means the host never builds a model, never writes SQLite and
// never touches the table diff, which is why the reference needs no re-enter and
// shows no blank bubble. One owner only (`GJIMEngine`), encoding `v24@0:8@16`.
static void (*o_engineGRPCPrivate)(id, SEL, id);
static void r_engineGRPCPrivate(id self, SEL _cmd, id a0) {
    HushHit("GJIMEngine", "handleingGRPCPrivatePackage:");
    if (HushRecallHandlePrivatePackage(self, _cmd, a0, o_engineGRPCPrivate)) {
        return;                                  // 吞掉：不调 orig
    }
    if (o_engineGRPCPrivate) o_engineGRPCPrivate(self, _cmd, a0);
}

// 38: probe only — the host's own "should this package be blocked" gate.
// Returning its value untouched; we only want to know what it decides in practice
// before borrowing it in a later version.
static BOOL (*o_checkBlockPkg)(id, SEL, id);
static BOOL r_checkBlockPkg(id self, SEL _cmd, id a0) {
    HushHit("GJIMEngine", "p_checkIfNeedBlockPackage:");
    BOOL r = o_checkBlockPkg ? o_checkBlockPkg(self, _cmd, a0) : NO;
    HushRecallProbeBlockDecision(a0, r);
    return r;
}

// v41 的 BDDestoryChatCell -showAutoDestroyImage: 探针已删（v43）。
// v42 真机日志里 KEEP# 一次都没出，说明点击根本不走 cell 这条，
// 真正的中转站是 BDMessageViewController 那条（下面这个，已实证 VCKEEP#1）。

// BDMessageViewController 上也有一个同名 showAutoDestroyImage:（sel_index:
// 598 个 selector，同列还有 destoryImageCell:clickMsg: / destroyBigImageCell:
// clickMessage: / mainTableView）。它是「点开闪照 → 全屏展示」这一跳的入口。
// self 是 VC 不是 cell，拿不到 _destoryCellMaskView 那套 ivar，所以这里只留痕、
// 不拆销毁面 —— 它的作用就是回答一个问题：点开闪照到底走没走这条路。
// v45 P2：点击时截获的 mid。
//
// BDAutoDestoryImageViewController 身上没有 mid ivar，只有 targetUid + msgTime
// （sel_index: targetUid @16@0:8 / msgTime Q16@0:8）。v44 想靠「DecorateCell 填池
// + uid/时间戳反查」，但 DecorateCell 的判据写死在 type==282、实际 model 是 24，
// 池子永远是空的，所以 BURNSTART# 的 mid 恒为 n/a。
//
// 真正稳的落点是点击入口本身：BDMessageViewController -showAutoDestroyImage: 的
// 参数就是 BDDestoryChatCell，而 cell 上挂着 message（GJIMMessageModel），
// msgId / sendTime 全在里面。这条 hook 实测有 VCKEEP#1 触发，不是死路。
static long long gHushLastClickMsgId = 0;
static long long gHushLastClickTs    = 0;

static void (*o_msgVCShowAuto)(id, SEL, id);
static void r_msgVCShowAuto(id self, SEL _cmd, id a0) {
    HushHit("BDMessageViewController", "showAutoDestroyImage:");
    if (o_msgVCShowAuto) o_msgVCShowAuto(self, _cmd, a0);

    // v45 P2：从 cell.message 里抠 mid + sendTime，存成全局给
    // BDAutoDestoryImageViewController 的 startLoadingResource 用。
    long long mid = 0, ts = 0;
    if (a0) {
        id msg = nil;
        @try { msg = [a0 valueForKey:@"message"]; }
        @catch (__unused NSException *e) { msg = nil; }
        if (msg) {
            for (NSString *k in @[ @"msgId", @"messageId" ]) {
                @try {
                    id v = [msg valueForKey:k];
                    if ([v isKindOfClass:[NSNumber class]]) {
                        long long x = [(NSNumber *)v longLongValue];
                        if (x > 0) { mid = x; break; }
                    }
                } @catch (__unused NSException *e) {}
            }
            @try {
                id v = [msg valueForKey:@"sendTime"];
                if ([v isKindOfClass:[NSNumber class]]) ts = [(NSNumber *)v longLongValue];
            } @catch (__unused NSException *e) {}
        }
    }
    if (mid > 0) {
        gHushLastClickMsgId = mid;
        gHushLastClickTs    = ts;
    }

    static int n = 0;
    n++;
    if (n <= 10 || (n % 10) == 0) {
        // HushLogger 的 logLevel:format: 只收一个拼好的 NSString，不是 printf。
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] VCKEEP#%d vc=%@ arg=%@ mid=%lld ts=%lld",
            n, NSStringFromClass([self class]), NSStringFromClass([a0 class]), mid, ts];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

// v41d（A2）：点开闪照到底走哪条路？
//
// v41c 真机事实：用户点白板「毫无反应，没放大也没卡死」，而 KEEP# 与
// VCKEEP# 都是 0 —— 两个 showAutoDestroyImage: 一次都没被调用。说明点击
// 在更外层就被接走了（或者被我们 hidden 掉的 _destoryIconBtn 吃掉了，
// 这正是 HushAutoDestroyUnlock 现在默认不拆遮罩的原因）。
//
// BDMessageViewController 上跟「点开闪照」直接相关的双参方法只有这两个
// （sel_index 实证 598 个 selector 里的 v32@0:8@16@24）：
//   -destoryImageCell:clickMsg:
//   -destroyBigImageCell:clickMessage:
// 这里只留痕、不改行为，目的就是看哪个亮。哪个亮就在哪个里做洗白。
static void (*o_destoryClick)(id, SEL, id, id);
static void r_destoryClick(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDMessageViewController", "destoryImageCell:clickMsg:");
    if (o_destoryClick) o_destoryClick(self, _cmd, a0, a1);
    static int n = 0;
    n++;
    if (n <= 10 || (n % 10) == 0) {
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] CLICK#%d which=destoryImage cell=%@ msg=%@",
            n,
            a0 ? NSStringFromClass([a0 class]) : @"nil",
            a1 ? NSStringFromClass([a1 class]) : @"nil"];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

static void (*o_destroyBigClick)(id, SEL, id, id);
static void r_destroyBigClick(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDMessageViewController", "destroyBigImageCell:clickMessage:");
    if (o_destroyBigClick) o_destroyBigClick(self, _cmd, a0, a1);
    static int n = 0;
    n++;
    if (n <= 10 || (n % 10) == 0) {
        NSString *line = [NSString stringWithFormat:
            @"[P0-2b] CLICK#%d which=destroyBigImage cell=%@ msg=%@",
            n,
            a0 ? NSStringFromClass([a0 class]) : @"nil",
            a1 ? NSStringFromClass([a1 class]) : @"nil"];
        fprintf(stderr, "%s\n", [line UTF8String]);
        [HushLogger logLevel:2 format:line];
    }
}

// ---------------------------------------------------------------- v42 点击探针
//
// v41d 真机事实：用户点白板「毫无反应」，而 VC 上那两个双参方法
// （destoryImageCell:clickMsg: / destroyBigImageCell:clickMessage:）一次都没被
// 调用，KEEP# 与 VCKEEP# 也全是 0。说明点击要么在 cell 内部就被 action 接走，
// 要么走的是 VC 上别的分支。
//
// 所以这一版把五个候选一次性全挂上，只留痕不改行为：
//   cell 层：BDDestoryChatCell -playBtnTapped  （51 个 selector 里唯一无参 action）
//            BDChatBasicCell   -clickTipBtn
//   VC   层：-markImageReadCell:clickMsg:   （标记已读，闪照点开最可能走这条）
//            -warnImageCell:clickMsg:
//            -showBigImageCell:clickMsg:
// 哪个 CLICK# 亮，洗白就写在哪。
#define HUSH_CLICK0(slot, which, o_var, cls_name, sel_name)                        \
    static void (*o_var)(id, SEL);                                                 \
    static void r_##slot(id self, SEL _cmd) {                                      \
        HushHit(cls_name, sel_name);                                               \
        if (o_var) o_var(self, _cmd);                                              \
        static int n = 0;                                                          \
        n++;                                                                       \
        if (n <= 10 || (n % 10) == 0) {                                            \
            NSString *line = [NSString stringWithFormat:                            \
                @"[P0-2b] CLICK#%d which=" which @" cell=%@", n,                    \
                NSStringFromClass([self class])];                                   \
            fprintf(stderr, "%s\n", [line UTF8String]);                            \
            [HushLogger logLevel:2 format:line];                                   \
        }                                                                          \
    }

#define HUSH_CLICK2(slot, which, o_var, cls_name, sel_name)                        \
    static void (*o_var)(id, SEL, id, id);                                         \
    static void r_##slot(id self, SEL _cmd, id a0, id a1) {                        \
        HushHit(cls_name, sel_name);                                               \
        if (o_var) o_var(self, _cmd, a0, a1);                                      \
        static int n = 0;                                                          \
        n++;                                                                       \
        if (n <= 10 || (n % 10) == 0) {                                            \
            NSString *line = [NSString stringWithFormat:                            \
                @"[P0-2b] CLICK#%d which=" which @" cell=%@ msg=%@", n,             \
                a0 ? NSStringFromClass([a0 class]) : @"nil",                        \
                a1 ? NSStringFromClass([a1 class]) : @"nil"];                       \
            fprintf(stderr, "%s\n", [line UTF8String]);                            \
            [HushLogger logLevel:2 format:line];                                   \
        }                                                                          \
    }

HUSH_CLICK2(markReadClick, "markImageRead", o_markReadClick,
            "BDMessageViewController", "markImageReadCell:clickMsg:")
HUSH_CLICK2(warnClick, "warnImage", o_warnClick,
            "BDMessageViewController", "warnImageCell:clickMsg:")
HUSH_CLICK2(showBigClick, "showBigImage", o_showBigClick,
            "BDMessageViewController", "showBigImageCell:clickMsg:")
// v42 真机判决：playBtnTapped / clickTipBtn / BDDestoryChatCell::showAutoDestroyImage:
// 三个探针 CLICK# 与 KEEP# 双双为 0 —— 点击根本不走它们。已删。

// ---------------------------------------------------------------- v43 阅后即焚
//
// v42 真机日志把整条链钉死了：点开闪照只产生一条 VCKEEP#1
// （BDMessageViewController -showAutoDestroyImage:，参数是 cell），
// 随后 94 秒零业务网络请求。你说的「按住屏幕阅读 / 松手即销毁」
// 出自 BDAutoDestoryImageViewController（sel_index 109 个 selector）：
//
//   touchesBegan:withEvent:        ← 「按住」
//   startLoadingResource
//   requestServerUrl:compelete:    ← 向服务器要地址（gRPC，不是 NSURLSession）
//   setImageURL:needDecryption:    ← 拿到的是【密文】
//   loadImage
//   countDown                      ← 15 秒倒计时
//   touchesEnded:withEvent:        ← 「松手」
//   finishReview → clearCache      ← 清盘
//
// 所以 NSURLSession 一条都抓不到。真正的 URL 在 setImageURL: 的第一个参数上。
//
// 两条铁律（用户点名）：
//   - 破坏性动作（拦松手、拦倒计时、拦 clearCache）全在 switch_flash_keep 后面，默认关
//   - 不在 touchesEnded: 里截图（视频层/GL 层会全黑）；要抢救就走 clearCache 拷文件
// v44 P2：BDAutoDestoryImageViewController 身上没有 mid，只有 targetUid 与
// msgTime（sel_index: targetUid @16@0:8 / msgTime Q16@0:8）。
// 所以维护一个「最近见过的 type=282 消息」环形池，靠 uid + 时间戳反查。
// model 上的时间字段是 sendTime（I16@0:8，unsigned int）。
//
// 反查窗口取 ±8 秒：BURNSTART# 的 msgTime=1793886935，
// 而 imageURL 里的时间戳段是 1793886933 —— 差 2 秒，不能再紧了。
static NSMutableArray *sFlashRecent = nil;

// 锁对象：MRC 下 @synchronized(nil) 不锁，必须给个真实对象。
static NSObject *HushFlashLockObj(void) {
    static NSObject *o = nil;
    if (!o) o = [[NSObject alloc] init];
    return o;
}

// HushNumStr 是 HushRecallGuard.m 里的 static，这边拿不到，写个本地版。
static NSString *HushBurnNum(long long v) {
    if (v == LLONG_MIN) return @"n/a";
    return [NSString stringWithFormat:@"%lld", v];
}

void HushFlashRemember(long long mid, long long from, long long ts) {
    if (mid <= 0) return;
    @synchronized (HushFlashLockObj()) {
        if (!sFlashRecent) sFlashRecent = [[NSMutableArray alloc] init];
        for (NSDictionary *d in sFlashRecent) {
            if ([[d objectForKey:@"mid"] longLongValue] == mid) return;
        }
        [sFlashRecent addObject:@{ @"mid":  @(mid),
                                   @"from": @(from),
                                   @"ts":   @(ts) }];
        while (sFlashRecent.count > 24) [sFlashRecent removeObjectAtIndex:0];
    }
}

static long long HushFlashLookupMid(long long uid, long long ts) {
    if (uid <= 0 || ts <= 0) return LLONG_MIN;
    @synchronized (HushFlashLockObj()) {
        long long best = LLONG_MIN;
        long long bestDelta = LLONG_MAX;
        for (NSDictionary *d in sFlashRecent) {
            long long f = [[d objectForKey:@"from"] longLongValue];
            if (f != uid) continue;
            long long t = [[d objectForKey:@"ts"] longLongValue];
            long long delta = t > ts ? (t - ts) : (ts - t);
            if (delta <= 8 && delta < bestDelta) {
                bestDelta = delta;
                best = [[d objectForKey:@"mid"] longLongValue];
            }
        }
        return best;
    }
}

static BOOL HushFlashKeepOn(void) {
    // v49 A：switch_flash_keep 从来没有进过面板。
    // HushModuleMap.h 是 _work/gen_module_map.py 生成的（文件头 DO NOT EDIT），
    // 这一版只往 HushKeys.h 加了键，没重新跑生成器 —— 面板上根本看不到这个开关，
    // 用户无论怎么点都开不了，isEnabled: 永远走 defBool=0。
    // v48 日志 BURNTEND#1 keep=0 就是铁证：用户以为开着，实际是死的。
    // 现在让它跟随「闪照转照片」：开了闪照解锁就等于开了防销毁。
    // v52：再接一个「闪文转普通消息」。v51 真机日志里 unlock=1（说明闪照逻辑
    // 认了）但 ESCAPEARM# / BURNTEND# / BURNEXIT# 全是 0 条 —— 因为用户开的是
    // 「闪文转普通消息」，而这里只 OR 了 switch_flash_keep 与 switch_flash_photo，
    // keep 一直是 NO，防销毁 A1/A2/A3 整段都是死代码。三个都 OR 上，谁开都算。
    if ([[HushConfig shared] isEnabled:@"switch_flash_keep"])  return YES;
    if ([[HushConfig shared] isEnabled:@"switch_flash_photo"]) return YES;
    return [[HushConfig shared] isEnabled:@"switch_flash_text"];
}

// v52 A：敏感确认框的闸门。
// 用户拍板：宁可宽，不要漏。开了「敏感内容优化」就拦；就算没开，
// 只要开了「闪照转照片」或「闪文转普通消息」，同样拦 —— 因为这说明
// 他就是想把闪照当普通图看，那个「系统检测到当前内容可能敏感」的
// 二次确认框纯属添堵。
static BOOL HushPornBlockOn(void) {
    if ([[HushConfig shared] isEnabled:@"purify_sensitive"])   return YES;
    if ([[HushConfig shared] isEnabled:@"switch_flash_photo"]) return YES;
    return [[HushConfig shared] isEnabled:@"switch_flash_text"];
}

static void HushBurnNote(NSString *line) {
    if (!line) return;
    fprintf(stderr, "%s\n", [line UTF8String]);
    [HushLogger logLevel:2 format:line];
}

// 打一个字符串字段，nil / 空串直接跳过 —— 日志里全是 text=(null) 没法看。
static void HushBurnAppend(NSMutableString *out, id obj, NSString *key) {
    if (!out || !obj) return;
    id v = nil;
    @try { v = [obj valueForKey:key]; } @catch (__unused NSException *e) { return; }
    if (!v) return;
    NSString *s = nil;
    if ([v isKindOfClass:[NSString class]])      s = (NSString *)v;
    else if ([v isKindOfClass:[NSURL class]])    s = [(NSURL *)v absoluteString];
    else if ([v isKindOfClass:[NSNumber class]]) s = [(NSNumber *)v stringValue];
    if (s.length == 0) return;
    [out appendFormat:@" %@=%@", key, s];
}

// 把这个 VC 身上所有带 url/path/dir/file 字样的 ivar 挖出来。
// sel_index 已证实这些字段真实存在：imageURL / videoURL / videoDir /
// videoOutputPath / webServicePort / targetUid / msgTime。
static NSString *HushBurnState(id self) {
    if (!self) return @"nil";
    NSMutableString *out = [NSMutableString stringWithFormat:@"cls=%@",
                            NSStringFromClass([self class])];
    NSArray *keys = @[ @"imageURL", @"videoURL", @"videoDir", @"videoOutputPath",
                       @"webServicePort", @"targetUid", @"msgTime",
                       @"isExchangePhoto", @"isFromSelf", @"isVertify" ];
    for (NSString *k in keys) HushBurnAppend(out, self, k);
    // 兜底：类里将来加了新字段也不至于漏。最多扫 120 个 ivar。
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([self class], &n);
    if (ivars) {
        int shown = 0;
        for (unsigned int i = 0; i < n && shown < 120; i++) {
            const char *nm = ivar_getName(ivars[i]);
            if (!nm) continue;
            NSString *ns = [NSString stringWithUTF8String:nm];
            if (!ns) continue;
            NSString *low = [ns lowercaseString];
            if ([low rangeOfString:@"url"].location == NSNotFound &&
                [low rangeOfString:@"path"].location == NSNotFound &&
                [low rangeOfString:@"dir"].location == NSNotFound &&
                [low rangeOfString:@"file"].location == NSNotFound) continue;
            // 上面 keys 已经打过的跳过
            NSString *bare = [ns hasPrefix:@"_"] ? [ns substringFromIndex:1] : ns;
            if ([keys containsObject:bare]) continue;
            HushBurnAppend(out, self, bare);
            shown++;
        }
        free(ivars);
    }
    // v44 P2：用 targetUid + msgTime 反查这条闪照属于哪个 mid。
    // 这里不能用 HushModelLongLong —— 它是 HushRecallGuard.m 里的 static，这边拿不到。
    long long uid = 0, mts = 0;
    @try {
        id v1 = [self valueForKey:@"targetUid"];
        id v2 = [self valueForKey:@"msgTime"];
        if ([v1 isKindOfClass:[NSNumber class]]) uid = [(NSNumber *)v1 longLongValue];
        if ([v2 isKindOfClass:[NSNumber class]]) mts = [(NSNumber *)v2 longLongValue];
    } @catch (__unused NSException *e) {}
    long long m2  = HushFlashLookupMid(uid, mts);
    [out appendFormat:@" mid=%@", HushBurnNum(m2)];
    // v45 P2：点击时截获的 mid，比 uid+时间戳反查稳得多
    [out appendFormat:@" gMid=%lld", gHushLastClickMsgId];
    return out;
}

#define HUSH_BURN_DIR  @"bluedbackups/burn"
static NSString *HushBurnDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.count ? [paths objectAtIndex:0] : nil;
    if (!doc) return nil;
    NSString *d = [doc stringByAppendingPathComponent:HUSH_BURN_DIR];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return d;
}

// clearCache / finishReview 之前把本地落盘的东西抢下来。
// 只拷单个文件与一层目录内容，绝不递归整个沙盒 —— 那是自杀。
static void HushBurnSalvage(id self) {
    NSString *dst = HushBurnDir();
    if (!dst) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *srcs = [NSMutableArray array];
    for (NSString *k in @[ @"videoDir", @"videoOutputPath", @"imageURL", @"videoURL" ]) {
        id v = nil;
        @try { v = [self valueForKey:k]; } @catch (__unused NSException *e) { continue; }
        if ([v isKindOfClass:[NSURL class]]) v = [(NSURL *)v path];
        // 只处理本地路径；http(s) 交给 setImageURL 那条线
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v hasPrefix:@"/"]) {
            [srcs addObject:v];
        }
    }
    int copied = 0;
    for (NSString *src in srcs) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir]) continue;
        NSArray *items = isDir ? [fm contentsOfDirectoryAtPath:src error:NULL]
                               : @[ src ];
        for (NSString *it in items) {
            NSString *full = isDir ? [src stringByAppendingPathComponent:it] : it;
            NSString *to = [dst stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%d_%@", copied, [full lastPathComponent]]];
            if ([fm fileExistsAtPath:to]) continue;
            if ([fm copyItemAtPath:full toPath:to error:NULL]) copied++;
            if (copied >= 12) break;
        }
        if (copied >= 12) break;
    }
    HushBurnNote([NSString stringWithFormat:
        @"[P0-2b] SALVAGE src=%lu copied=%d dir=%@",
        (unsigned long)srcs.count, copied, dst]);
}

// ---- v45：mid -> 本地原图 的映射表
//
// 持久化到 Documents/bluedbackups/burn/map.json。
// 不放 NSUserDefaults —— 那是 HushConfig 的地盘（_flagCache 会搅），而且
// 闪照映射是纯数据，跟配置无关。
static NSMutableDictionary *sFlashMap = nil;

static NSObject *HushFlashMapLock(void) {
    static NSObject *o = nil;
    if (!o) o = [[NSObject alloc] init];
    return o;
}

static NSString *HushFlashMapFile(void) {
    NSString *d = HushBurnDir();
    if (!d) return nil;
    return [d stringByAppendingPathComponent:@"map.json"];
}

static void HushFlashMapLoad(void) {
    if (sFlashMap) return;
    sFlashMap = [[NSMutableDictionary alloc] init];
    NSString *f = HushFlashMapFile();
    if (!f) return;
    NSData *d = [NSData dataWithContentsOfFile:f];
    if (!d || d.length == 0) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [sFlashMap addEntriesFromDictionary:(NSDictionary *)obj];
    }
}

static void HushFlashMapFlush(void) {
    NSString *f = HushFlashMapFile();
    if (!f || !sFlashMap) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:sFlashMap options:0 error:NULL];
    if (d) [d writeToFile:f atomically:YES];
}

// v53 P1：只存文件名，不存绝对路径。
//
// v52 真机翻车就是因为这里把 <sandbox>/Documents/bluedbackups/burn/23.jpg
// 整条塞进了 map.json。iOS 每次冷启动都给 App 换一个新的沙盒 UUID：
//   /var/mobile/Containers/Data/Application/0A04AD63-.../Documents/...
//   /var/mobile/Containers/Data/Application/4DAE7F83-.../Documents/...
// 重启后那条绝对路径必然不存在 —— fileExistsAtPath 返回 NO，
// HushBurnApplyImage 静默 return，一条 BURNPAINT# 都打不出来。
//
// 现在只存 "23.jpg"，读的时候用当时的 NSHomeDirectory() 重新拼，
// 沙盒怎么变都对得上。
static void HushFlashMapSet(long long mid, NSString *url, NSString *path) {
    if (mid <= 0 || url.length == 0) return;
    @synchronized (HushFlashMapLock()) {
        HushFlashMapLoad();
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        [e setObject:url forKey:@"url"];
        if (path.length) [e setObject:[path lastPathComponent] forKey:@"path"];
        [e setObject:@((long long)[[NSDate date] timeIntervalSince1970]) forKey:@"at"];
        [sFlashMap setObject:e forKey:[NSString stringWithFormat:@"%lld", mid]];
        HushFlashMapFlush();
    }
}

// 给 HushRecallGuard.m 的 HushBurnApplyImage 查本地图。
//
// v53 P1：返回值一律用「当前沙盒」重新拼，永远指向真实存在的那个 Documents。
// v52 之前存的是绝对路径，冷启动后必然失效 —— 详见 HushFlashMapSet 的注释。
// 兼容处理：老 map.json 里躺着绝对路径的条目，取 lastPathComponent 重拼即可，
// 不需要迁移逻辑、不需要清库。
NSString *HushFlashMapPath(long long mid) {
    if (mid <= 0) return nil;
    @synchronized (HushFlashMapLock()) {
        HushFlashMapLoad();
        NSDictionary *e = [sFlashMap objectForKey:[NSString stringWithFormat:@"%lld", mid]];
        if (![e isKindOfClass:[NSDictionary class]]) return nil;
        id p = [(NSDictionary *)e objectForKey:@"path"];
        if (![p isKindOfClass:[NSString class]] || [(NSString *)p length] == 0) return nil;

        NSString *name = (NSString *)p;
        if ([name isAbsolutePath]) {
            // 旧数据（或将来手滑写进绝对路径）：只留文件名
            name = [name lastPathComponent];
        }
        NSString *dir = HushBurnDir();
        if (dir.length == 0 || name.length == 0) return nil;
        return [dir stringByAppendingPathComponent:name];
    }
}

// v45 P3 补丁 B：下载 + 落盘全放后台队列，文件名固定 <mid>.jpg ——
// 同一张图不论点开多少次只存一份，不会堆几十个重复大文件。
// v48 A：HushRecallGuard.m 里导出（非 static）。
// 之所以要跨文件调：HushRecallChatTable 与 HushModelLongLong 都是 Guard 内的
// static，Hooks 这边拿不到；把「找表 + 比对 mid + 铺图」整段搬进 Guard，
// 这里只传一个 mid。
extern void HushBurnRefreshVisible(long long mid, NSString *url);
extern void HushSetSessionService(id svc);

// ── v54 P2：SDImageCache 注入 ─────────────────────────────────────────────
// 旧版插件日志实证：它的文件名是 32 位十六进制 = URL 的 MD5
//   [Chat][回填] 命中：msg=… url=<len=136> → 523f8c4631a8245f47dcd8633be7d584.jpg
//   [Chat][回填] 已注入宿主图片缓存 1 个槽（key 尾=<len=136>）
// 也就是说它把「完整 URL 字符串」当 key 塞进图片缓存，宿主之后自己
// 走 sd_setImageWithURL: 时直接命中，CDN 是 200 还是 403 都无关。
// sel_index 实证宿主用的是 SDWebImage：
//   SDImageCache  storeImage:forKey:toDisk:completion:  v44@0:8@16@24B32@?36
//   SDImageCache  storeImage:forKey:completion:         v40@0:8@16@24@?32
//   SDImageCache  storeImageToMemory:forKey:            v32@0:8@16@24
//   SDAnimatedImageView  sd_setImageWithURL:             v24@0:8@16
// BDAnimatedImageView 继承自 SDAnimatedImageView（ivar dump 实证）。
static NSString *HushFlashMD5(NSString *s) {
    if (s.length == 0) return nil;
    const char *c = [s UTF8String];
    if (!c) return nil;
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", d[i]];
    return out;
}

static void HushInjectImageCache(NSString *urlString, NSString *path) {
    if (urlString.length == 0 || path.length == 0) return;
    Class c = objc_getClass("SDImageCache");
    if (!c) {
        HushBurnNote(@"[P0-2b] CACHEINJECT# skip（找不到 SDImageCache）");
        return;
    }
    id cache = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedImageCache));
    if (!cache) {
        HushBurnNote(@"[P0-2b] CACHEINJECT# skip（sharedImageCache=nil）");
        return;
    }
    UIImage *im = [UIImage imageWithContentsOfFile:path];
    if (!im) {
        HushBurnNote(@"[P0-2b] CACHEINJECT# skip（读不出图）");
        return;
    }
    // 先塞内存 + 磁盘。SDWebImage 5 的默认 key 就是 url.absoluteString。
    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
        cache, @selector(storeImage:forKey:toDisk:completion:),
        im, urlString, YES, nil);
    // 老版本 SDK 只有两参版本，补一发（重复写无害）。
    if ([cache respondsToSelector:@selector(storeImage:forKey:completion:)]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            cache, @selector(storeImage:forKey:completion:), im, urlString, nil);
    }
    HushBurnNote([NSString stringWithFormat:
        @"[P0-2b] CACHEINJECT# ok key=%@ size=%.0fx%.0f",
        urlString, im.size.width, im.size.height]);
}

static void HushFlashDownload(long long mid, NSString *url) {
    if (mid <= 0 || url.length == 0) return;
    NSString *dir = HushBurnDir();
    if (!dir) return;
    // v54 P2：文件名改成 URL 的 MD5（对齐旧版插件），同一张图换条消息也认得出；
    // 取不到 MD5 才退回 mid.jpg。
    NSString *h = HushFlashMD5(url);
    NSString *fname = h.length ? [h stringByAppendingPathExtension:@"jpg"]
                               : [NSString stringWithFormat:@"%lld.jpg", mid];
    NSString *dst = [dir stringByAppendingPathComponent:fname];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dst]) {
        HushFlashMapSet(mid, url, dst);   // 已下过，直接登记
        HushInjectImageCache(url, dst);   // 已下过也要注入（换账号/清过缓存）
        // v48 A：图已经在盘上，立即把可见 cell 铺一遍。
        // 调用点（r_burnStartLoad）在主线程，不用切队列。
        HushBurnRefreshVisible(mid, url);
        return;
    }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:u];
        NSUInteger len = data.length;
        if (!data || len < 1024) {
            HushBurnNote([NSString stringWithFormat:
                @"[P0-2b] BURNDL#fail mid=%lld bytes=%lu", mid, (unsigned long)len]);
            return;
        }
        if ([data writeToFile:dst atomically:YES]) {
            HushFlashMapSet(mid, url, dst);
            HushBurnNote([NSString stringWithFormat:
                @"[P0-2b] BURNDL#ok mid=%lld bytes=%lu file=%@",
                mid, (unsigned long)len, [dst lastPathComponent]]);
            // v54 P2：写盘即注入宿主图片缓存 —— 宿主之后自己渲染这张图
            // 时直接命中，不存在 CDN 403/过期的问题。
            HushInjectImageCache(url, dst);
            // v48 A：写盘成功即刻回主线程铺图。
            // v47 真机 mid=23 就是死在这里 —— 图下完了，但宿主不重绘，
            // 铺图入口永远等不到。
            dispatch_async(dispatch_get_main_queue(), ^{
                HushBurnRefreshVisible(mid, url);
            });
        } else {
            HushBurnNote([NSString stringWithFormat:
                @"[P0-2b] BURNDL#write-fail mid=%lld", mid]);
        }
    });
}

// ---- slot 39: setImageURL:needDecryption:   ← 本轮的命门
static void (*o_burnSetImageURL)(id, SEL, id, BOOL);
static void r_burnSetImageURL(id self, SEL _cmd, id url, BOOL needDec) {
    HushHit("BDAutoDestoryImageViewController", "setImageURL:needDecryption:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *u = nil;
        @try {
            if ([url isKindOfClass:[NSURL class]])   u = [(NSURL *)url absoluteString];
            else if ([url isKindOfClass:[NSString class]]) u = (NSString *)url;
            else if (url) u = [url description];
        } @catch (__unused NSException *e) {}
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNURL#%d url=%@ needDec=%d %@",
            n, u ? u : @"nil", (int)needDec, HushBurnState(self)]);
    }
    if (o_burnSetImageURL) o_burnSetImageURL(self, _cmd, url, needDec);
}

// ---- slot 43: setVideoURL:needDecryption:
static void (*o_burnSetVideoURL)(id, SEL, id, BOOL);
static void r_burnSetVideoURL(id self, SEL _cmd, id url, BOOL needDec) {
    HushHit("BDAutoDestoryImageViewController", "setVideoURL:needDecryption:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *u = nil;
        @try {
            if ([url isKindOfClass:[NSURL class]])   u = [(NSURL *)url absoluteString];
            else if ([url isKindOfClass:[NSString class]]) u = (NSString *)url;
            else if (url) u = [url description];
        } @catch (__unused NSException *e) {}
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNVID#%d url=%@ needDec=%d %@",
            n, u ? u : @"nil", (int)needDec, HushBurnState(self)]);
    }
    if (o_burnSetVideoURL) o_burnSetVideoURL(self, _cmd, url, needDec);
}

// ---- slot 44: requestServerUrl:compelete:
//
// block 签名未知，包一层转发会崩（MRC 下变参 block 无法安全复制）。
// 这里只留痕 + dump self 状态 —— 地址最终一定会走 setImageURL:，那条够了。
static void (*o_burnRequestUrl)(id, SEL, id, id);
static void r_burnRequestUrl(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDAutoDestoryImageViewController", "requestServerUrl:compelete:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *s0 = nil;
        @try { s0 = a0 ? [a0 description] : nil; } @catch (__unused NSException *e) {}
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNREQ#%d arg=%@ blk=%@ %@",
            n, s0 ? s0 : @"nil",
            a1 ? NSStringFromClass([a1 class]) : @"nil",
            HushBurnState(self)]);
    }
    if (o_burnRequestUrl) o_burnRequestUrl(self, _cmd, a0, a1);
}

// ---- slot 50: loadImage
static void (*o_burnLoadImage)(id, SEL);
static void r_burnLoadImage(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "loadImage");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNLOAD#%d %@", n, HushBurnState(self)]);
    }
    if (o_burnLoadImage) o_burnLoadImage(self, _cmd);
}

// ---- slot 51: startLoadingResource
static void (*o_burnStartLoad)(id, SEL);
static void r_burnStartLoad(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "startLoadingResource");

    // ---- v45 P3：在这里抢明文 URL ----
    //
    // v44 实测：setImageURL: 收到的是 162 字节 AES 密文
    // （BURNSETURL#1 url=RUV+iJmKj0...），但 imageURL 这个 getter 返回的是
    // https://burn-chatfiles.bldimg.cn/... 明文。解密发生在 getter 里 ——
    // 宿主自己解好了，不用碰那块硬骨头。
    NSString *u = nil;
    @try {
        id v = [self valueForKey:@"imageURL"];
        if ([v isKindOfClass:[NSURL class]])         u = [(NSURL *)v absoluteString];
        else if ([v isKindOfClass:[NSString class]]) u = (NSString *)v;
    } @catch (__unused NSException *e) { u = nil; }

    // mid 优先用点击时截获的那个（v45 P2）；截不到再退回 uid+时间戳反查。
    long long mid = gHushLastClickMsgId;
    if (mid <= 0) {
        long long uid = 0, mt = 0;
        @try {
            id v = [self valueForKey:@"targetUid"];
            if ([v isKindOfClass:[NSNumber class]]) uid = [(NSNumber *)v longLongValue];
            v = [self valueForKey:@"msgTime"];
            if ([v isKindOfClass:[NSNumber class]]) mt = [(NSNumber *)v longLongValue];
        } @catch (__unused NSException *e) {}
        if (uid != 0 && mt != 0) mid = HushFlashLookupMid(uid, mt);
    }

    if (mid > 0 && u.length >= 8) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNGRAB mid=%lld url=%@", mid, u]);
        HushFlashDownload(mid, u);
    } else {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNGRAB miss mid=%lld urlLen=%lu",
            mid, (unsigned long)u.length]);
    }

    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNSTART#%d %@", n, HushBurnState(self)]);
    }
    if (o_burnStartLoad) o_burnStartLoad(self, _cmd);
}

// ---- slot 52: countDown   （switch_flash_keep 开则停表）
static void (*o_burnCountDown)(id, SEL);
static void r_burnCountDown(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "countDown");
    if (HushFlashKeepOn()) {
        static int n = 0;
        n++;
        if (n <= 10 || (n % 10) == 0) {
            HushBurnNote([NSString stringWithFormat:
                @"[P0-2b] BURNSTOP#%d countDown 已拦，倒计时不跑", n]);
        }
        return;
    }
    if (o_burnCountDown) o_burnCountDown(self, _cmd);
}

// ---- slot 53: clearCache （switch_flash_keep 开则先抢救文件）
static void (*o_burnClearCache)(id, SEL);
static void r_burnClearCache(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "clearCache");
    if (HushFlashKeepOn()) HushBurnSalvage(self);
    if (o_burnClearCache) o_burnClearCache(self, _cmd);
}

// ---- slot 54: finishReview （switch_flash_keep 开则不结束）
static void (*o_burnFinishReview)(id, SEL);
static void r_burnFinishReview(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "finishReview");
    if (HushFlashKeepOn()) {
        HushBurnSalvage(self);
        static int n = 0;
        n++;
        if (n <= 10 || (n % 10) == 0) {
            HushBurnNote([NSString stringWithFormat:
                @"[P0-2b] BURNKEEP#%d finishReview 已拦，不销毁 %@", n, HushBurnState(self)]);
        }
        return;
    }
    if (o_burnFinishReview) o_burnFinishReview(self, _cmd);
}

// ---- v51 A：逃生口集合 ----
// keep 开时我们把 touchesEnded / exitAction / popBack / finishVideo 全部掐死，
// 全屏页就出不去了。所以挂一个双击手势：双击时把这个 VC 记进 sEscapeVcs，
// 之后所有拦截点看到自己在集合里就放行。
//
// 为什么不用「关开关」的方式：HushConfig 是持久化配置，双击一下就把全局开关
// 关掉，下次进聊天页防销毁也跟着失效了。必须只作用于当前这个 VC 实例。
static NSMutableSet *sEscapeVcs = nil;
static NSLock       *sEscapeLock = nil;

static void HushEscapeMark(id vc) {
    if (!vc) return;
    @synchronized ([NSLock class]) {
        if (!sEscapeVcs) { sEscapeVcs = [[NSMutableSet alloc] init]; }
        if (!sEscapeLock) { sEscapeLock = [[NSLock alloc] init]; }
        [sEscapeVcs addObject:[NSValue valueWithNonretainedObject:vc]];
    }
}

static BOOL HushEscapeAsked(id vc) {
    if (!vc) return NO;
    @synchronized ([NSLock class]) {
        if (!sEscapeVcs) return NO;
        return [sEscapeVcs containsObject:[NSValue valueWithNonretainedObject:vc]];
    }
}

// keep 开着 且 用户没双击 → 拦住
static BOOL HushGuardBlock(id vc) {
    if (!HushFlashKeepOn()) return NO;
    if (HushEscapeAsked(vc)) return NO;
    return YES;
}

// 双击handler：先登记逃生，再走宿主自己的退出路径。
// exitAction / popBack / finishVideo 三个都可能，按 respondsToSelector 依次试。
static void HushEscapeAction(id self, SEL _cmd) {
    HushEscapeMark(self);
    HushBurnNote([NSString stringWithFormat:
        @"[P0-2b] ESCAPE# 双击逃生已放行 cls=%@", NSStringFromClass([self class])]);
    if ([self respondsToSelector:NSSelectorFromString(@"exitAction")]) {
        ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"exitAction"));
    } else if ([self respondsToSelector:NSSelectorFromString(@"popBack")]) {
        ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"popBack"));
    } else if ([self respondsToSelector:NSSelectorFromString(@"finishVideo")]) {
        ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"finishVideo"));
    }
}

// ---- v51 A1: slot 55 touchesEnded:withEvent:  （keep 开 + 未逃生 → 吞掉）----
static void (*o_burnTouchesEnded)(id, SEL, id, id);
static void r_burnTouchesEnded(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDAutoDestoryImageViewController", "touchesEnded:withEvent:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNTEND#%d keep=%d blocked=%d %@",
            n, (int)HushFlashKeepOn(), (int)HushGuardBlock(self), HushBurnState(self)]);
    }
    // v51：v50 这里是「只留痕然后照调 orig」—— 松手后宿主内部的销毁逻辑照跑，
    // 日志里 BURNKEEP# 明明拦住了 finishReview，人还是被踢出去，就是这条没拦住。
    if (HushGuardBlock(self)) return;
    if (o_burnTouchesEnded) o_burnTouchesEnded(self, _cmd, a0, a1);
}

// ---- v51 A3: slot 63 touchesCancelled:withEvent:  （系统手势打断时也走销毁）----
static void (*o_burnTouchesCancelled)(id, SEL, id, id);
static void r_burnTouchesCancelled(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDAutoDestoryImageViewController", "touchesCancelled:withEvent:");
    static int n = 0;
    n++;
    if (n <= 10) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNCANCEL#%d keep=%d blocked=%d",
            n, (int)HushFlashKeepOn(), (int)HushGuardBlock(self)]);
    }
    if (HushGuardBlock(self)) return;
    if (o_burnTouchesCancelled) o_burnTouchesCancelled(self, _cmd, a0, a1);
}

// ---- v51 A2: slot 64/65/66 —— 三条退出路径全拦 ----
static void (*o_burnExit)(id, SEL);
static void r_burnExit(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "exitAction");
    static int n = 0;
    n++;
    if (n <= 10) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNEXIT#%d which=exitAction blocked=%d",
            n, (int)HushGuardBlock(self)]);
    }
    if (HushGuardBlock(self)) return;
    if (o_burnExit) o_burnExit(self, _cmd);
}

static void (*o_burnPopBack)(id, SEL);
static void r_burnPopBack(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "popBack");
    static int n = 0;
    n++;
    if (n <= 10) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNEXIT#%d which=popBack blocked=%d",
            n, (int)HushGuardBlock(self)]);
    }
    if (HushGuardBlock(self)) return;
    if (o_burnPopBack) o_burnPopBack(self, _cmd);
}

static void (*o_burnFinishVideo)(id, SEL);
static void r_burnFinishVideo(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "finishVideo");
    static int n = 0;
    n++;
    if (n <= 10) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNEXIT#%d which=finishVideo blocked=%d",
            n, (int)HushGuardBlock(self)]);
    }
    if (HushGuardBlock(self)) return;
    if (o_burnFinishVideo) o_burnFinishVideo(self, _cmd);
}

// ---- v51 A 逃生口: slot 67 viewDidLoad —— 挂双击手势 ----
static void (*o_burnViewDidLoad)(id, SEL);
static void r_burnViewDidLoad(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "viewDidLoad");
    if (o_burnViewDidLoad) o_burnViewDidLoad(self, _cmd);
    if (!HushFlashKeepOn()) return;
    @try {
        Class c = [self class];
        SEL escape = NSSelectorFromString(@"hush_escapeAction");
        if (!class_getInstanceMethod(c, escape)) {
            class_addMethod(c, escape, (IMP)&HushEscapeAction, "v16@0:8");
        }
        UIViewController *vc = (UIViewController *)self;
        UIView *v = vc.view;
        if (!v) return;
        // 去重：viewDidLoad 可能被调多次
        for (UIGestureRecognizer *g in [v gestureRecognizers]) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]]
                && ((UITapGestureRecognizer *)g).numberOfTapsRequired == 2) return;
        }
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:escape];
        tap.numberOfTapsRequired = 2;
        tap.cancelsTouchesInView = NO;   // 不吃 touches，避免和「按住查看」打架
        [v addGestureRecognizer:tap];
        [tap release];
        HushBurnNote(@"[P0-2b] ESCAPEARM# 双击逃生口已挂上");
    } @catch (__unused NSException *e) {}
}


// ---- slot 56: initWithFileType:sources:   ← 最上游的一站
//
// sources 里很可能直接装着 imageURL / msgId / 解密 key（用户的判断）。
// 这里只读不写：把整个描述打出来，长度截 1200 字符防止刷爆日志。
static id (*o_burnInit)(id, SEL, unsigned long long, id);
static id r_burnInit(id self, SEL _cmd, unsigned long long ft, id sources) {
    HushHit("BDAutoDestoryImageViewController", "initWithFileType:sources:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *s = nil;
        @try { s = sources ? [sources description] : nil; } @catch (__unused NSException *e) {}
        if (s.length > 1200) s = [s substringToIndex:1200];
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNINIT#%d fileType=%llu sources=%@",
            n, ft, s ? s : @"nil"]);
    }
    if (o_burnInit) return o_burnInit(self, _cmd, ft, sources);
    return nil;
}

// ---- slot 57: setImageURL:（单参）  ← v44 实测：这才是真赋值点
//
// v43 只挂了双参 setImageURL:needDecryption:，BURNURL# 一条都没出，
// 但 BURNSTART# 打出来的 imageURL 已经有值 —— 说明赋值走的是这条。
static void (*o_burnSetImageURL1)(id, SEL, id);
static void r_burnSetImageURL1(id self, SEL _cmd, id url) {
    HushHit("BDAutoDestoryImageViewController", "setImageURL:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *u = nil;
        @try {
            if ([url isKindOfClass:[NSURL class]])         u = [(NSURL *)url absoluteString];
            else if ([url isKindOfClass:[NSString class]]) u = (NSString *)url;
            else if (url)                                  u = [url description];
        } @catch (__unused NSException *e) {}
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNSETURL#%d url=%@ %@",
            n, u ? u : @"nil", HushBurnState(self)]);
    }
    if (o_burnSetImageURL1) o_burnSetImageURL1(self, _cmd, url);
}

// ---- slot 58: setVideoURL:（单参）
static void (*o_burnSetVideoURL1)(id, SEL, id);
static void r_burnSetVideoURL1(id self, SEL _cmd, id url) {
    HushHit("BDAutoDestoryImageViewController", "setVideoURL:");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        NSString *u = nil;
        @try {
            if ([url isKindOfClass:[NSURL class]])         u = [(NSURL *)url absoluteString];
            else if ([url isKindOfClass:[NSString class]]) u = (NSString *)url;
            else if (url)                                  u = [url description];
        } @catch (__unused NSException *e) {}
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNSETVID#%d url=%@ %@",
            n, u ? u : @"nil", HushBurnState(self)]);
    }
    if (o_burnSetVideoURL1) o_burnSetVideoURL1(self, _cmd, url);
}

// ---- slot 59: p_handleWebServer   ← 8999 那台本地服务的处理入口
//
// v44 真机日志：webServicePort=8999。WKWebView 向 127.0.0.1:8999 要图，
// 服务内部再用自己的 HTTP 栈去 COS 拉 —— 这就是 NSURLSession 一条都抓不到的原因。
// 这里只留痕，看它被调用时的状态（含 imageURL / videoOutputPath / videoDir）。
static void (*o_burnWebServer)(id, SEL);
static void r_burnWebServer(id self, SEL _cmd) {
    HushHit("BDAutoDestoryImageViewController", "p_handleWebServer");
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] BURNWS#%d %@", n, HushBurnState(self)]);
    }
    if (o_burnWebServer) o_burnWebServer(self, _cmd);
}

// ---- v49 D: slot 60 —— 全屏页的图被换掉时能看到 ----
// 用户 m03034 的观察：按住能看图（8999 端口拉到 1080x2340 原图），
// 松手立刻变成「包含敏感内容」。switch_flash_keep 开着也没用，
// 说明宿主不走 finishReview/touchesEnded 那条，而是直接把 contentImage 抹了。
// 这里挂 setContentImage: 看它到底传了什么进来。
// keep 开 + 传进来的是小尺寸图（占位图通常 < 200pt）→ 拒绝替换。
static void (*o_burnSetContentImage)(id, SEL, id);
static void r_burnSetContentImage(id self, SEL _cmd, id img) {
    HushHit("BDAutoDestoryImageViewController", "setContentImage:");

    int keep = (int)HushFlashKeepOn();
    CGFloat w = -1.0, h = -1.0;
    if ([img isKindOfClass:[UIImage class]]) {
        w = ((UIImage *)img).size.width;
        h = ((UIImage *)img).size.height;
    }
    static int n = 0;
    n++;
    if (n <= 12 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] CONTENTIMG#%d cls=%@ size=%.0fx%.0f keep=%d",
            n, img ? NSStringFromClass([img class]) : @"nil", w, h, keep]);
    }
    if (keep && [img isKindOfClass:[UIImage class]]
        && w > 0.0 && w < 200.0 && h < 200.0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] CONTENTBLOCK#%d 拒绝用 %.0fx%.0f 的小图替换原图（keep 已开）",
            n, w, h]);
        return;
    }
    if (o_burnSetContentImage) o_burnSetContentImage(self, _cmd, img);
}

// ---- v49 D / v51 B: slot 61/62 —— 敏感判定 ----
// v50 真机日志（19:57:07.931 / 19:57:09.383）抓到了这两个方法被真实调用：
//   PORN#1 which=alert → VCKEEP#1 → PORN#1 which=deal → BURNINIT#1
// 也就是说「系统检测到当前内容可能敏感，可点击取消后进行举报。确认查看吗？」
// 这个弹框来自 alert；用户点确认后才走 deal，再实例化全屏页。
// v51：keep 开着时把 alert 整个掐掉，点开闪照不再弹确认。
static void (*o_pornAlert)(id, SEL, id, id);
static void r_pornAlert(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDMessageViewController", "p_showPornAlertForReceiveAutoDestroy:message:");
    static int n = 0;
    n++;
    // v52：闸门换成 HushPornBlockOn()（purify_sensitive || flash_photo || flash_text）。
    // v51 用的是 HushFlashKeepOn()，用户开「闪文转普通消息」时它是 NO，拦不住。
    BOOL block = HushPornBlockOn();
    if (n <= 10 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] PORN#%d which=alert cell=%@ msg=%@ block=%d",
            n, a0 ? NSStringFromClass([a0 class]) : @"nil",
            a1 ? NSStringFromClass([a1 class]) : @"nil", (int)block]);
    }
    if (block) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] PORNBLOCK#%d 已拦截敏感确认框，直接放行（净化/闪照已开）", n]);
        return;
    }
    if (o_pornAlert) o_pornAlert(self, _cmd, a0, a1);
}

static void (*o_pornDeal)(id, SEL, id, id);
static void r_pornDeal(id self, SEL _cmd, id a0, id a1) {
    HushHit("BDMessageViewController", "p_dealWithReceivedAutoDestroyAfterIdentifyPorn:message:");
    static int n = 0;
    n++;
    // v52：deal 也要拦。v51 只拦了 alert，真机日志里 PORN#1 which=deal
    // 是唯一的入口（alert 早被点过「确认」了），结果一路走到实例化全屏页。
    // 拦 deal 的语义是：服务器哪怕判了敏感，本地也不做任何销毁/特殊处理，
    // 让图片按普通路径完整渲染。
    BOOL block = HushPornBlockOn();
    if (n <= 10 || (n % 10) == 0) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] PORN#%d which=deal cell=%@ msg=%@ block=%d",
            n, a0 ? NSStringFromClass([a0 class]) : @"nil",
            a1 ? NSStringFromClass([a1 class]) : @"nil", (int)block]);
    }
    if (block) {
        HushBurnNote([NSString stringWithFormat:
            @"[P0-2b] PORNBLOCK#%d which=deal 已拦截敏感处理，直接放行", n]);
        return;
    }
    if (o_pornDeal) o_pornDeal(self, _cmd, a0, a1);
}

// ---------------------------------------------------------------- v42 网络探针
//
// 闪照的图片 URL 不在模型里 —— v41c 与 v41d 两份真机日志里，type=282 的
// extra 只有 played / playedBefore / time_limited_status / matchAnimationType，
// 一个 URL 都没有。宿主是**点击之后**才去拉图，所以只能在网络层截。
//
// NSURLSession 是 App 全部网络出口，是绝对的性能热路径。三条硬规矩：
//   - 过滤只用 NSString rangeOfString，不建字典、不拼日志、不额外分配
//   - 不命中的请求立刻原样转发，连一个 NSString 都不拼
//   - 命中的也只是在 completionHandler 里落盘，绝不阻塞调用方线程
//
// 只认闪照/销毁相关的路径词。别把整个 App 的流量记下来 —— 那是自杀。
typedef void (^HushNetHandler)(NSData *, NSURLResponse *, NSError *);

static NSString *HushNetURLString(id req) {
    if (!req) return nil;
    @try {
        id url = [req valueForKey:@"URL"];
        if ([url isKindOfClass:[NSURL class]]) return [(NSURL *)url absoluteString];
        if ([url isKindOfClass:[NSString class]]) return (NSString *)url;
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *HushNetURLOf(id url) {
    if (!url) return nil;
    @try {
        if ([url isKindOfClass:[NSURL class]]) return [(NSURL *)url absoluteString];
        if ([url isKindOfClass:[NSString class]]) return (NSString *)url;
    } @catch (__unused NSException *e) {}
    return nil;
}

static BOOL HushFlashNetWanted(NSString *u) {
    if (u.length < 8 || u.length > 2048) return NO;
    if ([u rangeOfString:@"cheat"].location        != NSNotFound) return YES;
    if ([u rangeOfString:@"destroy"].location      != NSNotFound) return YES;
    if ([u rangeOfString:@"burn"].location         != NSNotFound) return YES;
    if ([u rangeOfString:@"secret"].location       != NSNotFound) return YES;
    if ([u rangeOfString:@"time_limited"].location != NSNotFound) return YES;
    return NO;
}

static void HushNetNote(int seq, NSString *phase, NSString *url, NSData *data, NSURLResponse *resp) {
    NSString *mime = @"?";
    @try {
        NSString *m = [resp MIMEType];
        if ([m isKindOfClass:[NSString class]] && m.length) mime = m;
    } @catch (__unused NSException *e) {}
    NSString *line = [NSString stringWithFormat:
        @"[P0-2b] NET#%d %@ url=%@ bytes=%lu mime=%@",
        seq, phase, url ? url : @"(nil)", (unsigned long)(data ? data.length : 0), mime];
    fprintf(stderr, "%s\n", [line UTF8String]);
    [HushLogger logLevel:2 format:line];
}

// 落盘只做一件最小的事：给后续离线分析留一份原始响应体。
// 不解析、不转码、不猜格式 —— 服务端到底回 JSON 还是二进制流，看文件头就知道。
static void HushNetSave(int seq, NSData *data) {
    if (data.length == 0 || data.length > (8 * 1024 * 1024)) return;
    @try {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count == 0) return;
        NSString *dir = [[docs objectAtIndex:0] stringByAppendingPathComponent:@"bluedbackups/images"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        NSString *name = [NSString stringWithFormat:@"net_%d_%lu.bin", seq, (unsigned long)data.length];
        [data writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    } @catch (__unused NSException *e) {}
}

// MRC：栈上的 block 传给别人之前必须搬到堆上，否则 dataTask 还没跑完它就没了。
static HushNetHandler HushNetWrap(int seq, NSString *url, NSURLRequest *req,
                                  HushNetHandler handler) {
    (void)req;
    HushNetHandler raw = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length > 0 && !err) {
            HushNetNote(seq, @"resp", url, data, resp);
            HushNetSave(seq, data);
        } else if (err) {
            HushNetNote(seq, @"err", url, nil, nil);
        }
        if (handler) handler(data, resp, err);   // 必须原样回调，绝不能吞
    };
    return [[raw copy] autorelease];
}

static id (*o_dataTaskReq)(id, SEL, id, HushNetHandler);
static id r_dataTaskReq(id self, SEL _cmd, id req, HushNetHandler handler) {
    NSString *u = HushNetURLString(req);
    if (!HushFlashNetWanted(u)) {
        if (!o_dataTaskReq) return nil;
        return o_dataTaskReq(self, _cmd, req, handler);
    }
    static int seq = 0;
    int my = ++seq;
    HushNetNote(my, @"req", u, nil, nil);
    NSURLRequest *r = (NSURLRequest *)req;
    return o_dataTaskReq ? o_dataTaskReq(self, _cmd, req, HushNetWrap(my, u, r, handler)) : nil;
}

static id (*o_dataTaskURL)(id, SEL, id, HushNetHandler);
static id r_dataTaskURL(id self, SEL _cmd, id url, HushNetHandler handler) {
    NSString *u = HushNetURLOf(url);
    if (!HushFlashNetWanted(u)) {
        if (!o_dataTaskURL) return nil;
        return o_dataTaskURL(self, _cmd, url, handler);
    }
    static int seq = 0;
    int my = ++seq;
    HushNetNote(my, @"req", u, nil, nil);
    return o_dataTaskURL ? o_dataTaskURL(self, _cmd, url, HushNetWrap(my, u, nil, handler)) : nil;
}

// ---------------------------------------------------------------- install driver
// One slot per target. Installed once, retried only while still MISSING.
#define HUSH_TARGET_COUNT 68

static BOOL s_done[HUSH_TARGET_COUNT];

static void hush_report(int idx, const char *cls, const char *sel,
                        hush_installed r) {
    if (s_done[idx]) {
        gHushHooksSkipped++;
        return;
    }
    gHushHooksTotal++;
    if (r.prev) {
        if (strcmp(r.kind, "own") == 0)          gHushHooksOwn++;
        else                                    gHushHooksInherit++;
    } else if (strcmp(r.kind, "added") == 0) {
        gHushHooksAdded++;
    } else if (strcmp(r.kind, "own-noorig") == 0) {
        gHushHooksOwn++;
    } else {
        gHushHooksMissing++;
    }
    if (!r.types) gHushHooksNoTypes++;

    // MISSING means the class itself never resolved — keep retrying it.
    // Every other outcome is final for this process.
    if (strcmp(r.kind, "MISSING") != 0) s_done[idx] = YES;

    // stderr goes nowhere on iOS: it is not forwarded to the device log and it is
    // not part of HushLogger's file, which is the artefact the verification
    // table is read from. Mirror everything through the logger at info level so
    // `prev=` survives with switch_debug_log off.
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush] hook %s %s::%s prev=%p types=%s",
        r.kind, cls, sel, r.prev, r.types ? r.types : "(none)"]];
}

void HushInstallHooks(void) {
    static BOOL announced = NO;
    if (!announced) {
        announced = YES;
        fprintf(stderr, "[Hush] HushInstallHooks begin\n");
        [HushLogger logLevel:3 format:@"[Hush] HushInstallHooks begin"];
    }

    // Serialised on the main queue by every caller (ctor runs on the main thread
    // and all four retries are dispatched to it), so s_done needs no lock.
    Class cMsg = hush_resolve_class("GJIMMessageService");
    Class cDB  = hush_resolve_class("GJIMDBService");
    Class cSes = hush_resolve_class("GJIMSessionService");
    Class cApp = hush_resolve_class("AppDelegateModel");
    Class cTab  = hush_resolve_class("BluedTabBar");
    Class cMenu = hush_resolve_class("BDCustomMenuView");
    Class cChat = hush_resolve_class("PrivateChatViewController");
    Class cMsgVC = hush_resolve_class("BDMessageViewController");
    Class cCell  = hush_resolve_class("BDChatBasicCell");
    Class cUser  = hush_resolve_class("UserInformation");
    Class cEngine = hush_resolve_class("GJIMEngine");
    Class cCovers = hush_resolve_class("BDIndexPageCoversManager");
    // v43：阅后即焚的全屏查看页 —— 「按住屏幕阅读 / 松手销毁」的真身。
    // 原来那个 BDDestoryChatCell 变量已随死探针一起删除（v42 实测零命中）。
    Class cBurn = hush_resolve_class("BDAutoDestoryImageViewController");
    // v42：NSURLSession 是系统类，hush_resolve_class 先走 objc_getClass 就够了
    // （Swift 那两条拼 "Blued." 的分支只对宿主自己的类有意义，走不到这里）。
    Class cNetSession = hush_resolve_class("NSURLSession");

    if (!s_done[0]) {
        SEL s = sel_registerName("p_filterDeletedMessages:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_filterDeleted, "@24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_filterDeleted = (id (*)(id, SEL, id))r.prev;
        hush_report(0, "GJIMMessageService", "p_filterDeletedMessages:", r);
    }
    if (!s_done[1]) {
        SEL s = sel_registerName("dealMessage:array:");
        hush_installed r = hush_install_impl(cDB, s, (IMP)&r_dealMessage, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_dealMessage = (void (*)(id, SEL, id, id))r.prev;
        hush_report(1, "GJIMDBService", "dealMessage:array:", r);
    }
    if (!s_done[2]) {
        SEL s = sel_registerName("clearSessionAndMessageWithToken:");
        hush_installed r = hush_install_impl(cSes, s, (IMP)&r_clearSessionAndMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_clearSessionAndMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(2, "GJIMSessionService", "clearSessionAndMessageWithToken:", r);
    }
    if (!s_done[3]) {
        SEL s = sel_registerName("deleteMessage:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_deleteMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_deleteMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(3, "GJIMMessageService", "deleteMessage:", r);
    }
    if (!s_done[4]) {
        SEL s = sel_registerName("removeAllSplashAdViews:");
        hush_installed r = hush_install_impl(cApp, s, (IMP)&r_removeAllSplash, "v24@0:8q16");
        if (strcmp(r.kind, "MISSING") != 0) o_removeAllSplash = (void (*)(id, SEL, long long))r.prev;
        hush_report(4, "AppDelegateModel", "removeAllSplashAdViews:", r);
    }


    if (!s_done[5]) {
        SEL s = sel_registerName("p_changeItemStateAtIndex:");
        hush_installed r = hush_install_impl(cTab, s, (IMP)&r_changeItemState, "v24@0:8Q16");
        if (strcmp(r.kind, "MISSING") != 0) o_changeItemState = (void (*)(id, SEL, unsigned long long))r.prev;
        hush_report(5, "BluedTabBar", "p_changeItemStateAtIndex:", r);
    }
    if (!s_done[6]) {
        SEL s = sel_registerName("selectItemAtIndex:");
        hush_installed r = hush_install_impl(cTab, s, (IMP)&r_selectItem, "v24@0:8q16");
        if (strcmp(r.kind, "MISSING") != 0) o_selectItem = (void (*)(id, SEL, long long))r.prev;
        hush_report(6, "BluedTabBar", "selectItemAtIndex:", r);
    }
    if (!s_done[7]) {
        SEL s = sel_registerName("selectItemAtIndex:subIndex:");
        hush_installed r = hush_install_impl(cTab, s, (IMP)&r_selectItemSub, "v32@0:8q16q24");
        if (strcmp(r.kind, "MISSING") != 0) o_selectItemSub = (void (*)(id, SEL, long long, long long))r.prev;
        hush_report(7, "BluedTabBar", "selectItemAtIndex:subIndex:", r);
    }
    if (!s_done[8]) {
        SEL s = sel_registerName("setDynamicImgView:");
        hush_installed r = hush_install_impl(cTab, s, (IMP)&r_setDynamicImg, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_setDynamicImg = (void (*)(id, SEL, id))r.prev;
        hush_report(8, "BluedTabBar", "setDynamicImgView:", r);
    }
    if (!s_done[9]) {
        SEL s = sel_registerName("hideMenu");
        hush_installed r = hush_install_impl(cMenu, s, (IMP)&r_menuHide, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_menuHide = (void (*)(id, SEL))r.prev;
        hush_report(9, "Blued.BDCustomMenuView", "hideMenu", r);
    }
    if (!s_done[10]) {
        SEL s = sel_registerName("layoutSubviews");
        hush_installed r = hush_install_impl(cMenu, s, (IMP)&r_menuLayout, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_menuLayout = (void (*)(id, SEL))r.prev;
        hush_report(10, "Blued.BDCustomMenuView", "layoutSubviews", r);
    }
    if (!s_done[11]) {
        SEL s = sel_registerName("reloadData");
        hush_installed r = hush_install_impl(cMenu, s, (IMP)&r_menuReload, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_menuReload = (void (*)(id, SEL))r.prev;
        hush_report(11, "Blued.BDCustomMenuView", "reloadData", r);
    }
    if (!s_done[12]) {
        // REMOVED IN v26: see the slot-13 comment above. Marking it done keeps
        // the "still pending retry" counter at zero and lets the table report
        // total=20 instead of waiting forever on a probe that no longer runs.
        s_done[12] = YES;
    }
    if (!s_done[13]) {
        SEL s = sel_registerName("viewDidAppear:");
        hush_installed r = hush_install_impl(cChat, s, (IMP)&r_chatViewDidAppear, "v20@0:8B16");
        if (strcmp(r.kind, "MISSING") != 0) o_chatViewDidAppear = (void (*)(id, SEL, BOOL))r.prev;
        hush_report(13, "PrivateChatViewController", "viewDidAppear:", r);
    }

    // ---- P0: recall data flow (7 new probes on GJIMMessageService) -------------
    if (!s_done[14]) {
        SEL s = sel_registerName("p_findLeakMessageIdsWithMessages:needAddMsg:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_findLeakIds, "@28@0:8@16B24");
        if (strcmp(r.kind, "MISSING") != 0) o_findLeakIds = (id (*)(id, SEL, id, BOOL))r.prev;
        hush_report(14, "GJIMMessageService", "p_findLeakMessageIdsWithMessages:needAddMsg:", r);
    }
    if (!s_done[15]) {
        SEL s = sel_registerName("p_sortAndUniqMessages:descend:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_sortUniq, "@28@0:8@16B24");
        if (strcmp(r.kind, "MISSING") != 0) o_sortUniq = (id (*)(id, SEL, id, BOOL))r.prev;
        hush_report(15, "GJIMMessageService", "p_sortAndUniqMessages:descend:", r);
    }
    if (!s_done[16]) {
        SEL s = sel_registerName("updateMessage:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_updateMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_updateMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(16, "GJIMMessageService", "updateMessage:", r);
    }
    if (!s_done[17]) {
        SEL s = sel_registerName("addMessages:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_addMessages, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_addMessages = (void (*)(id, SEL, id))r.prev;
        hush_report(17, "GJIMMessageService", "addMessages:", r);
    }
    if (!s_done[18]) {
        SEL s = sel_registerName("clearMessages");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_clearMessages, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_clearMessages = (void (*)(id, SEL))r.prev;
        hush_report(18, "GJIMMessageService", "clearMessages", r);
    }
    if (!s_done[19]) {
        SEL s = sel_registerName("fetchMessagesWithStartMsgId:endMsgId:isTempChat:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_fetchFrom, "v36@0:8Q16Q24B32");
        if (strcmp(r.kind, "MISSING") != 0) o_fetchFrom = (void (*)(id, SEL, unsigned long long, unsigned long long, BOOL))r.prev;
        hush_report(19, "GJIMMessageService", "fetchMessagesWithStartMsgId:endMsgId:isTempChat:", r);
    }
    if (!s_done[20]) {
        SEL s = sel_registerName("fetchMoreMessagesFromMessage:isTempChat:isDown:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_fetchMore, "v32@0:8@16B24B28");
        if (strcmp(r.kind, "MISSING") != 0) o_fetchMore = (void (*)(id, SEL, id, BOOL, BOOL))r.prev;
        hush_report(20, "GJIMMessageService", "fetchMoreMessagesFromMessage:isTempChat:isDown:", r);
    }
    if (!s_done[21]) {
        SEL s = sel_registerName("addMessages:");
        hush_installed r = hush_install_impl(cSes, s, (IMP)&r_sessionAddMessages, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_sessionAddMessages = (void (*)(id, SEL, id))r.prev;
        hush_report(21, "GJIMSessionService", "addMessages:", r);
    }
    if (!s_done[22]) {
        SEL s = sel_registerName("p_updateMessage:");
        hush_installed r = hush_install_impl(cDB, s, (IMP)&r_dbUpdateMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_dbUpdateMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(22, "GJIMDBService", "p_updateMessage:", r);
    }
    if (!s_done[23]) {
        SEL s = sel_registerName("updateMessages:updateType:");
        hush_installed r = hush_install_impl(cChat, s, (IMP)&r_chatUpdateMessages, "v32@0:8@16Q24");
        if (strcmp(r.kind, "MISSING") != 0) o_chatUpdateMessages = (void (*)(id, SEL, id, unsigned long long))r.prev;
        hush_report(23, "PrivateChatViewController", "updateMessages:updateType:", r);
    }
    if (!s_done[24]) {
        SEL s = sel_registerName("receiveNewMessage:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_msgVCReceiveNewMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_msgVCReceiveNewMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(24, "BDMessageViewController", "receiveNewMessage:", r);
    }

    if (!s_done[35]) {
        SEL s = sel_registerName("p_handleSyncRangeMessages:syncType:");
        hush_installed r = hush_install_impl(cMsg, s, (IMP)&r_syncRange, "v32@0:8@16Q24");
        if (strcmp(r.kind, "MISSING") != 0) o_syncRange = (void (*)(id, SEL, id, unsigned long long))r.prev;
        hush_report(35, "GJIMMessageService", "p_handleSyncRangeMessages:syncType:", r);
    }

    // ---- v35: badge / splash / privacy album
    if (!s_done[25]) {
        SEL s = sel_registerName("setMessage:");
        hush_installed r = hush_install_impl(cCell, s, (IMP)&r_cellSetMessage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_cellSetMessage = (void (*)(id, SEL, id))r.prev;
        hush_report(25, "BDChatBasicCell", "setMessage:", r);
    }
    if (!s_done[26]) {
        SEL s = sel_registerName("showSplashAd:");
        hush_installed r = hush_install_impl(cApp, s, (IMP)&r_showSplashAd, "v20@0:8B16");
        if (strcmp(r.kind, "MISSING") != 0) o_showSplashAd = (void (*)(id, SEL, BOOL))r.prev;
        hush_report(26, "AppDelegateModel", "showSplashAd:", r);
    }
    if (!s_done[27]) {
        SEL s = sel_registerName("getSplashAdForColdLaunch");
        hush_installed r = hush_install_impl(cApp, s, (IMP)&r_getSplashCold, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_getSplashCold = (id (*)(id, SEL))r.prev;
        hush_report(27, "AppDelegateModel", "getSplashAdForColdLaunch", r);
    }
    if (!s_done[28]) {
        SEL s = sel_registerName("p_getSplashAdvertisementForColdLaunch");
        hush_installed r = hush_install_impl(cApp, s, (IMP)&r_pGetSplashCold, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_pGetSplashCold = (id (*)(id, SEL))r.prev;
        hush_report(28, "AppDelegateModel", "p_getSplashAdvertisementForColdLaunch", r);
    }
    if (!s_done[38]) {
        SEL s = sel_registerName("hasNoneSplashShow");
        hush_installed r = hush_install_impl(cCovers, s, (IMP)&r_hasNoneSplashShow, "B16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_hasNoneSplashShow = (BOOL (*)(id, SEL))r.prev;
        hush_report(38, "BDIndexPageCoversManager", "hasNoneSplashShow", r);
    }
    if (!s_done[39]) {
        SEL s = sel_registerName("setImageURL:needDecryption:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnSetImageURL, "v28@0:8@16B24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnSetImageURL = (void (*)(id, SEL, id, BOOL))r.prev;
        hush_report(39, "BDAutoDestoryImageViewController", "setImageURL:needDecryption:", r);
    }
    if (!s_done[40]) {
        SEL s = sel_registerName("showAutoDestroyImage:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_msgVCShowAuto, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_msgVCShowAuto = (void (*)(id, SEL, id))r.prev;
        hush_report(40, "BDMessageViewController", "showAutoDestroyImage:", r);
    }
    if (!s_done[41]) {
        SEL s = sel_registerName("destoryImageCell:clickMsg:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_destoryClick, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_destoryClick = (void (*)(id, SEL, id, id))r.prev;
        hush_report(41, "BDMessageViewController", "destoryImageCell:clickMsg:", r);
    }
    if (!s_done[42]) {
        SEL s = sel_registerName("destroyBigImageCell:clickMessage:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_destroyBigClick, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_destroyBigClick = (void (*)(id, SEL, id, id))r.prev;
        hush_report(42, "BDMessageViewController", "destroyBigImageCell:clickMessage:", r);
    }
    if (!s_done[43]) {
        SEL s = sel_registerName("setVideoURL:needDecryption:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnSetVideoURL, "v28@0:8@16B24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnSetVideoURL = (void (*)(id, SEL, id, BOOL))r.prev;
        hush_report(43, "BDAutoDestoryImageViewController", "setVideoURL:needDecryption:", r);
    }
    if (!s_done[44]) {
        SEL s = sel_registerName("requestServerUrl:compelete:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnRequestUrl, "v32@0:8@16@?24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnRequestUrl = (void (*)(id, SEL, id, id))r.prev;
        hush_report(44, "BDAutoDestoryImageViewController", "requestServerUrl:compelete:", r);
    }
    if (!s_done[45]) {
        SEL s = sel_registerName("markImageReadCell:clickMsg:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_markReadClick, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_markReadClick = (void (*)(id, SEL, id, id))r.prev;
        hush_report(45, "BDMessageViewController", "markImageReadCell:clickMsg:", r);
    }
    if (!s_done[46]) {
        SEL s = sel_registerName("warnImageCell:clickMsg:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_warnClick, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_warnClick = (void (*)(id, SEL, id, id))r.prev;
        hush_report(46, "BDMessageViewController", "warnImageCell:clickMsg:", r);
    }
    if (!s_done[47]) {
        SEL s = sel_registerName("showBigImageCell:clickMsg:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_showBigClick, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_showBigClick = (void (*)(id, SEL, id, id))r.prev;
        hush_report(47, "BDMessageViewController", "showBigImageCell:clickMsg:", r);
    }
    if (!s_done[48]) {
        SEL s = sel_registerName("dataTaskWithRequest:completionHandler:");
        hush_installed r = hush_install_impl(cNetSession, s, (IMP)&r_dataTaskReq, "@32@0:8@16@?24");
        if (strcmp(r.kind, "MISSING") != 0) o_dataTaskReq = (id (*)(id, SEL, id, HushNetHandler))r.prev;
        hush_report(48, "NSURLSession", "dataTaskWithRequest:completionHandler:", r);
    }
    if (!s_done[49]) {
        SEL s = sel_registerName("dataTaskWithURL:completionHandler:");
        hush_installed r = hush_install_impl(cNetSession, s, (IMP)&r_dataTaskURL, "@32@0:8@16@?24");
        if (strcmp(r.kind, "MISSING") != 0) o_dataTaskURL = (id (*)(id, SEL, id, HushNetHandler))r.prev;
        hush_report(49, "NSURLSession", "dataTaskWithURL:completionHandler:", r);
    }
    // ---- v43：阅后即焚查看页的加载 / 销毁四个面
    if (!s_done[50]) {
        SEL s = sel_registerName("loadImage");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnLoadImage, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnLoadImage = (void (*)(id, SEL))r.prev;
        hush_report(50, "BDAutoDestoryImageViewController", "loadImage", r);
    }
    if (!s_done[51]) {
        SEL s = sel_registerName("startLoadingResource");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnStartLoad, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnStartLoad = (void (*)(id, SEL))r.prev;
        hush_report(51, "BDAutoDestoryImageViewController", "startLoadingResource", r);
    }
    if (!s_done[52]) {
        SEL s = sel_registerName("countDown");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnCountDown, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnCountDown = (void (*)(id, SEL))r.prev;
        hush_report(52, "BDAutoDestoryImageViewController", "countDown", r);
    }
    if (!s_done[53]) {
        SEL s = sel_registerName("clearCache");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnClearCache, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnClearCache = (void (*)(id, SEL))r.prev;
        hush_report(53, "BDAutoDestoryImageViewController", "clearCache", r);
    }
    if (!s_done[54]) {
        SEL s = sel_registerName("finishReview");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnFinishReview, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnFinishReview = (void (*)(id, SEL))r.prev;
        hush_report(54, "BDAutoDestoryImageViewController", "finishReview", r);
    }
    if (!s_done[55]) {
        SEL s = sel_registerName("touchesEnded:withEvent:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnTouchesEnded, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnTouchesEnded = (void (*)(id, SEL, id, id))r.prev;
        hush_report(55, "BDAutoDestoryImageViewController", "touchesEnded:withEvent:", r);
    }
    if (!s_done[56]) {
        SEL s = sel_registerName("initWithFileType:sources:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnInit, "@32@0:8Q16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnInit = (id (*)(id, SEL, unsigned long long, id))r.prev;
        hush_report(56, "BDAutoDestoryImageViewController", "initWithFileType:sources:", r);
    }
    if (!s_done[57]) {
        SEL s = sel_registerName("setImageURL:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnSetImageURL1, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_burnSetImageURL1 = (void (*)(id, SEL, id))r.prev;
        hush_report(57, "BDAutoDestoryImageViewController", "setImageURL:", r);
    }
    if (!s_done[58]) {
        SEL s = sel_registerName("setVideoURL:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnSetVideoURL1, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_burnSetVideoURL1 = (void (*)(id, SEL, id))r.prev;
        hush_report(58, "BDAutoDestoryImageViewController", "setVideoURL:", r);
    }
    if (!s_done[59]) {
        SEL s = sel_registerName("p_handleWebServer");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnWebServer, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnWebServer = (void (*)(id, SEL))r.prev;
        hush_report(59, "BDAutoDestoryImageViewController", "p_handleWebServer", r);
    }
    if (!s_done[60]) {
        SEL s = sel_registerName("setContentImage:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnSetContentImage, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_burnSetContentImage = (void (*)(id, SEL, id))r.prev;
        hush_report(60, "BDAutoDestoryImageViewController", "setContentImage:", r);
    }
    if (!s_done[61]) {
        SEL s = sel_registerName("p_showPornAlertForReceiveAutoDestroy:message:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_pornAlert, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_pornAlert = (void (*)(id, SEL, id, id))r.prev;
        hush_report(61, "BDMessageViewController", "p_showPornAlertForReceiveAutoDestroy:message:", r);
    }
    if (!s_done[62]) {
        SEL s = sel_registerName("p_dealWithReceivedAutoDestroyAfterIdentifyPorn:message:");
        hush_installed r = hush_install_impl(cMsgVC, s, (IMP)&r_pornDeal, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_pornDeal = (void (*)(id, SEL, id, id))r.prev;
        hush_report(62, "BDMessageViewController", "p_dealWithReceivedAutoDestroyAfterIdentifyPorn:message:", r);
    }
    // ---- v51 A2/A3：三条退出路径 + 触摸取消 + 双击逃生口 ----
    if (!s_done[63]) {
        SEL s = sel_registerName("touchesCancelled:withEvent:");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnTouchesCancelled, "v32@0:8@16@24");
        if (strcmp(r.kind, "MISSING") != 0) o_burnTouchesCancelled = (void (*)(id, SEL, id, id))r.prev;
        hush_report(63, "BDAutoDestoryImageViewController", "touchesCancelled:withEvent:", r);
    }
    if (!s_done[64]) {
        SEL s = sel_registerName("exitAction");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnExit, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnExit = (void (*)(id, SEL))r.prev;
        hush_report(64, "BDAutoDestoryImageViewController", "exitAction", r);
    }
    if (!s_done[65]) {
        SEL s = sel_registerName("popBack");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnPopBack, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnPopBack = (void (*)(id, SEL))r.prev;
        hush_report(65, "BDAutoDestoryImageViewController", "popBack", r);
    }
    if (!s_done[66]) {
        SEL s = sel_registerName("finishVideo");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnFinishVideo, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnFinishVideo = (void (*)(id, SEL))r.prev;
        hush_report(66, "BDAutoDestoryImageViewController", "finishVideo", r);
    }
    if (!s_done[67]) {
        SEL s = sel_registerName("viewDidLoad");
        hush_installed r = hush_install_impl(cBurn, s, (IMP)&r_burnViewDidLoad, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_burnViewDidLoad = (void (*)(id, SEL))r.prev;
        hush_report(67, "BDAutoDestoryImageViewController", "viewDidLoad", r);
    }
    if (!s_done[29]) {
        SEL s = sel_registerName("is_locked");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_isLocked, "i16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_isLocked = (int (*)(id, SEL))r.prev;
        hush_report(29, "UserInformation", "is_locked", r);
    }
    if (!s_done[30]) {
        SEL s = sel_registerName("privacy_photos_has_locked");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_privPhotoLocked, "i16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_privPhotoLocked = (int (*)(id, SEL))r.prev;
        hush_report(30, "UserInformation", "privacy_photos_has_locked", r);
    }
    if (!s_done[31]) {
        SEL s = sel_registerName("album_ban_save");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_albumBanSave, "i16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_albumBanSave = (int (*)(id, SEL))r.prev;
        hush_report(31, "UserInformation", "album_ban_save", r);
    }
    if (!s_done[32]) {
        SEL s = sel_registerName("setIs_locked:");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_setIsLocked, "v20@0:8i16");
        if (strcmp(r.kind, "MISSING") != 0) o_setIsLocked = (void (*)(id, SEL, int))r.prev;
        hush_report(32, "UserInformation", "setIs_locked:", r);
    }
    if (!s_done[33]) {
        SEL s = sel_registerName("setPrivacy_photos_has_locked:");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_setPrivPhotoLocked, "v20@0:8i16");
        if (strcmp(r.kind, "MISSING") != 0) o_setPrivPhotoLocked = (void (*)(id, SEL, int))r.prev;
        hush_report(33, "UserInformation", "setPrivacy_photos_has_locked:", r);
    }
    if (!s_done[34]) {
        SEL s = sel_registerName("setAlbum_ban_save:");
        hush_installed r = hush_install_impl(cUser, s, (IMP)&r_setAlbumBanSave, "v20@0:8i16");
        if (strcmp(r.kind, "MISSING") != 0) o_setAlbumBanSave = (void (*)(id, SEL, int))r.prev;
        hush_report(34, "UserInformation", "setAlbum_ban_save:", r);
    }


    // ---- v36: the packet layer (the place the reference log actually blocks)
    if (!s_done[36]) {
        SEL s = sel_registerName("handleingGRPCPrivatePackage:");
        hush_installed r = hush_install_impl(cEngine, s, (IMP)&r_engineGRPCPrivate, "v24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_engineGRPCPrivate = (void (*)(id, SEL, id))r.prev;
        hush_report(36, "GJIMEngine", "handleingGRPCPrivatePackage:", r);
    }
    if (!s_done[37]) {
        SEL s = sel_registerName("p_checkIfNeedBlockPackage:");
        hush_installed r = hush_install_impl(cEngine, s, (IMP)&r_checkBlockPkg, "B24@0:8@16");
        if (strcmp(r.kind, "MISSING") != 0) o_checkBlockPkg = (BOOL (*)(id, SEL, id))r.prev;
        hush_report(37, "GJIMEngine", "p_checkIfNeedBlockPackage:", r);
    }

    // Only summarise once every target has reached a final state, so the line the
    // verification table greps for is not printed three times with half the data.
    int pending = 0;
    for (int i = 0; i < HUSH_TARGET_COUNT; i++) if (!s_done[i]) pending++;
    if (pending == 0) {
        static BOOL summarised = NO;
        if (!summarised) {
            summarised = YES;
            fprintf(stderr, "[Hush] hooks(min): total=%d own=%d inherited=%d added=%d missing=%d no-types=%d\n",
                    gHushHooksTotal, gHushHooksOwn, gHushHooksInherit,
                    gHushHooksAdded, gHushHooksMissing, gHushHooksNoTypes);
            [HushLogger logLevel:3 format:[NSString stringWithFormat:
                @"[Hush] hooks(min): total=%d own=%d inherited=%d added=%d missing=%d no-types=%d",
                gHushHooksTotal, gHushHooksOwn, gHushHooksInherit,
                gHushHooksAdded, gHushHooksMissing, gHushHooksNoTypes]];
        }
    } else {
        fprintf(stderr, "[Hush] hooks(min): %d still pending retry\n", pending);
        [HushLogger logLevel:3 format:[NSString stringWithFormat:
            @"[Hush] hooks(min): %d still pending retry (round done)", pending]];
    }
}

// Retry a few times: Swift classes and dynamically loaded IM frameworks
// register after our ctor.
__attribute__((constructor)) static void hush_hooks_schedule(void) {
    static const double delays[] = { 0.4, 1.2, 2.5, 5.0 };
    for (unsigned i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HushInstallHooks();
        });
    }
}
