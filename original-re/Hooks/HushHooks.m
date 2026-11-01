// HushHooks.m — table-driven hook layer (road B, first 5 targets)
//
// Design notes (this file is MRC: -fno-objc-arc):
//   1. Classes are resolved at RUNTIME via objc_getClass, with NSClassFromString
//      as the Swift-mangled fallback ("Blued.BDCustomMenuView").
//      Never bake a class pointer at +load time: Swift classes register late.
//   2. The method's type encoding is read from the live Method
//      (method_getTypeEncoding). It is never hardcoded, so a static-analysis
//      miss cannot produce a wrong signature.
//   3. Installation goes through class_replaceMethod(Class, SEL, IMP, types),
//      which works even when the host never exposed the selector to
//      class_getInstanceMethod at ctor time.
//   4. Bumping a counter only: if the class is absent we count MISSING and move
//      on — we never install a replacement that no caller can reach.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushLogger.h"

extern void HushHit(const char *cls, const char *sel);

// ---------------------------------------------------------------- counters
int gHushHooksTotal   = 0;
int gHushHooksOwn     = 0;
int gHushHooksInherit = 0;
int gHushHooksMissing = 0;
int gHushHooksNoTypes = 0;

// Resolve a class the two ways the host actually needs.
static Class hush_resolve_class(const char *name) {
    if (!name || !*name) return Nil;
    Class c = objc_getClass(name);
    if (c) return c;
    // Swift: "Blued.BDCustomMenuView" is exposed as "_TtC5Blued16BDCustomMenuView"
    NSString *ns = [NSString stringWithUTF8String:name];
    if (!ns) return Nil;
    c = NSClassFromString(ns);
    if (c) return c;
    if ([ns rangeOfString:@"."].location != NSNotFound) {
        // try the bare last component
        NSString *tail = [ns componentsSeparatedByString:@"."].lastObject;
        if (tail.length) c = NSClassFromString(tail);
    }
    return c;
}

// ---------------------------------------------------------------- targets
// 1. GJIMMessageService -p_filterDeletedMessages:
static id (*o_filterDeleted)(id, SEL, id);
static id r_filterDeleted(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "p_filterDeletedMessages:");
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) {
        // Keep the message alive: hand the host an empty "to delete" set.
        return nil;
    }
    return o_filterDeleted ? o_filterDeleted(self, _cmd, a0) : nil;
}

// 2. GJIMDBService -dealMessage:array:   (the write path into sqlite)
static void (*o_dealMessage)(id, SEL, id, id);
static void r_dealMessage(id self, SEL _cmd, id a0, id a1) {
    HushHit("GJIMDBService", "dealMessage:array:");
    if (o_dealMessage) o_dealMessage(self, _cmd, a0, a1);
}

// 3. GJIMSessionService -clearSessionAndMessageWithToken:
static void (*o_clearSessionAndMessage)(id, SEL, id);
static void r_clearSessionAndMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMSessionService", "clearSessionAndMessageWithToken:");
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) return;
    if (o_clearSessionAndMessage) o_clearSessionAndMessage(self, _cmd, a0);
}

// 4. GJIMMessageService -deleteMessage:
static void (*o_deleteMessage)(id, SEL, id);
static void r_deleteMessage(id self, SEL _cmd, id a0) {
    HushHit("GJIMMessageService", "deleteMessage:");
    if ([[HushConfig shared] isEnabled:@"switch_anti_recall"]) return;
    if (o_deleteMessage) o_deleteMessage(self, _cmd, a0);
}

// 5. AppDelegateModel -removeAllSplashAdViews:   (control group: known to fire)
static void (*o_removeAllSplash)(id, SEL, long long);
static void r_removeAllSplash(id self, SEL _cmd, long long a0) {
    HushHit("AppDelegateModel", "removeAllSplashAdViews:");
    if (o_removeAllSplash) o_removeAllSplash(self, _cmd, a0);
}

// ---------------------------------------------------------------- install
void HushInstallHooks(void) {
    fprintf(stderr, "[Hush] HushInstallHooks begin\n");


    // Each install: capture the previous IMP with class_replaceMethod's return.
    gHushHooksTotal = 0;
    {
        const char *T = NULL;
        Class c = hush_resolve_class("GJIMMessageService");
        SEL s = sel_registerName("p_filterDeletedMessages:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        T = m ? method_getTypeEncoding(m) : NULL;
        IMP prev = c ? class_replaceMethod(c, s, (IMP)&r_filterDeleted, T) : NULL;
        o_filterDeleted = (id (*)(id, SEL, id))prev;
        gHushHooksTotal++;
        if (!c) gHushHooksMissing++; else if (prev) gHushHooksInherit++; else gHushHooksOwn++;
        fprintf(stderr, "[Hush] hook %s GJIMMessageService::p_filterDeletedMessages: prev=%p types=%s\n",
                c ? (prev ? "inherit" : "own") : "MISSING", prev, T ? T : "(none)");
    }
    {
        Class c = hush_resolve_class("GJIMDBService");
        SEL s = sel_registerName("dealMessage:array:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        const char *T = m ? method_getTypeEncoding(m) : NULL;
        IMP prev = c ? class_replaceMethod(c, s, (IMP)&r_dealMessage, T) : NULL;
        o_dealMessage = (void (*)(id, SEL, id, id))prev;
        gHushHooksTotal++;
        if (!c) gHushHooksMissing++; else if (prev) gHushHooksInherit++; else gHushHooksOwn++;
        fprintf(stderr, "[Hush] hook %s GJIMDBService::dealMessage:array: prev=%p types=%s\n",
                c ? (prev ? "inherit" : "own") : "MISSING", prev, T ? T : "(none)");
    }
    {
        Class c = hush_resolve_class("GJIMSessionService");
        SEL s = sel_registerName("clearSessionAndMessageWithToken:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        const char *T = m ? method_getTypeEncoding(m) : NULL;
        IMP prev = c ? class_replaceMethod(c, s, (IMP)&r_clearSessionAndMessage, T) : NULL;
        o_clearSessionAndMessage = (void (*)(id, SEL, id))prev;
        gHushHooksTotal++;
        if (!c) gHushHooksMissing++; else if (prev) gHushHooksInherit++; else gHushHooksOwn++;
        fprintf(stderr, "[Hush] hook %s GJIMSessionService::clearSessionAndMessageWithToken: prev=%p types=%s\n",
                c ? (prev ? "inherit" : "own") : "MISSING", prev, T ? T : "(none)");
    }
    {
        Class c = hush_resolve_class("GJIMMessageService");
        SEL s = sel_registerName("deleteMessage:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        const char *T = m ? method_getTypeEncoding(m) : NULL;
        IMP prev = c ? class_replaceMethod(c, s, (IMP)&r_deleteMessage, T) : NULL;
        o_deleteMessage = (void (*)(id, SEL, id))prev;
        gHushHooksTotal++;
        if (!c) gHushHooksMissing++; else if (prev) gHushHooksInherit++; else gHushHooksOwn++;
        fprintf(stderr, "[Hush] hook %s GJIMMessageService::deleteMessage: prev=%p types=%s\n",
                c ? (prev ? "inherit" : "own") : "MISSING", prev, T ? T : "(none)");
    }
    {
        Class c = hush_resolve_class("AppDelegateModel");
        SEL s = sel_registerName("removeAllSplashAdViews:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        const char *T = m ? method_getTypeEncoding(m) : NULL;
        IMP prev = c ? class_replaceMethod(c, s, (IMP)&r_removeAllSplash, T) : NULL;
        o_removeAllSplash = (void (*)(id, SEL, long long))prev;
        gHushHooksTotal++;
        if (!c) gHushHooksMissing++; else if (prev) gHushHooksInherit++; else gHushHooksOwn++;
        fprintf(stderr, "[Hush] hook %s AppDelegateModel::removeAllSplashAdViews: prev=%p types=%s\n",
                c ? (prev ? "inherit" : "own") : "MISSING", prev, T ? T : "(none)");
    }

    fprintf(stderr, "[Hush] hooks(min): total=%d own=%d inherited=%d missing=%d no-types=%d\n",
            gHushHooksTotal, gHushHooksOwn, gHushHooksInherit, gHushHooksMissing, gHushHooksNoTypes);
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush] hooks(min): total=%d own=%d inherited=%d missing=%d no-types=%d",
        gHushHooksTotal, gHushHooksOwn, gHushHooksInherit, gHushHooksMissing, gHushHooksNoTypes]];
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
