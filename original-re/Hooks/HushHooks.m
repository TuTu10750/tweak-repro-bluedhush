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
static void (*o_sessionAddMessages)(id, SEL, id);
static void r_sessionAddMessages(id self, SEL _cmd, id a0) {
    HushHit("GJIMSessionService", "addMessages:");
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

static id (*o_getSplashCold)(id, SEL);
static id r_getSplashCold(id self, SEL _cmd) {
    HushHit("AppDelegateModel", "getSplashAdForColdLaunch");
    if (HushSplashPurifyOn()) return nil;      // 冷启动拿不到广告，自然不会展示
    return o_getSplashCold ? o_getSplashCold(self, _cmd) : nil;
}

static id (*o_pGetSplashCold)(id, SEL);
static id r_pGetSplashCold(id self, SEL _cmd) {
    HushHit("AppDelegateModel", "p_getSplashAdvertisementForColdLaunch");
    if (HushSplashPurifyOn()) return nil;
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

// ---------------------------------------------------------------- install driver
// One slot per target. Installed once, retried only while still MISSING.
#define HUSH_TARGET_COUNT 38

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
