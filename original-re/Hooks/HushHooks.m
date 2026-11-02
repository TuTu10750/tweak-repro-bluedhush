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

// ---------------------------------------------------------------- install driver
// One slot per target. Installed once, retried only while still MISSING.
#define HUSH_TARGET_COUNT 5

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

    fprintf(stderr, "[Hush] hook %s %s::%s prev=%p types=%s\n",
            r.kind, cls, sel, r.prev, r.types ? r.types : "(none)");
}

void HushInstallHooks(void) {
    static BOOL announced = NO;
    if (!announced) {
        announced = YES;
        fprintf(stderr, "[Hush] HushInstallHooks begin\n");
    }

    // Serialised on the main queue by every caller (ctor runs on the main thread
    // and all four retries are dispatched to it), so s_done needs no lock.
    Class cMsg = hush_resolve_class("GJIMMessageService");
    Class cDB  = hush_resolve_class("GJIMDBService");
    Class cSes = hush_resolve_class("GJIMSessionService");
    Class cApp = hush_resolve_class("AppDelegateModel");

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
