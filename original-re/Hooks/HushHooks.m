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
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) {
        // Keep the message alive: hand the host an empty "to delete" set.
        return nil;
    }
    return o_filterDeleted ? o_filterDeleted(self, _cmd, a0) : nil;
}

// 2. GJIMDBService -dealMessage:array:   (v32@0:8@16@24) — the write path into sqlite
static void (*o_dealMessage)(id, SEL, id, id);
static void r_dealMessage(id self, SEL _cmd, id a0, id a1) {
    HushHit("GJIMDBService", "dealMessage:array:");
    if (o_dealMessage) o_dealMessage(self, _cmd, a0, a1);
}

// 3. GJIMSessionService -clearSessionAndMessageWithToken:   (v24@0:8@16)
//    NOTE: this is the "delete the whole session" path, not the per-message
//    recall path. It is here to keep the session list intact, nothing more.
static void (*o_clearSessionAndMessage)(id, SEL, id);
static void r_clearSessionAndMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMSessionService", "clearSessionAndMessageWithToken:");
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) return;
    if (o_clearSessionAndMessage) o_clearSessionAndMessage(self, _cmd, a0);
}

// 4. GJIMMessageService -deleteMessage:   (v24@0:8@16) — the actual recall path
static void (*o_deleteMessage)(id, SEL, id);
static void r_deleteMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "deleteMessage:");
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) return;
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

// 13. PrivateChatViewController -layoutSubviews     UIViewController has no
//     layoutSubviews, so this is expected added unless the class is a view.
static void (*o_chatLayout)(id, SEL);
static void r_chatLayout(id self, SEL _cmd) {
    HushHit("PrivateChatViewController", "layoutSubviews");
    if (o_chatLayout) o_chatLayout(self, _cmd);
}

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

// ---------------------------------------------------------------- install driver
// One slot per target. Installed once, retried only while still MISSING.
#define HUSH_TARGET_COUNT 21

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
        SEL s = sel_registerName("layoutSubviews");
        hush_installed r = hush_install_impl(cChat, s, (IMP)&r_chatLayout, "v16@0:8");
        if (strcmp(r.kind, "MISSING") != 0) o_chatLayout = (void (*)(id, SEL))r.prev;
        hush_report(12, "PrivateChatViewController", "layoutSubviews", r);
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
