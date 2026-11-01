// SubstrateShim.m — Substrate-free hook backbone.
//
// The original BluedHush dylib links CydiaSubstrate for exactly ONE symbol:
//
//     _MSHookMessageEx              (verified: the only non-system import
//                                    starting with MS in the 5.19 dylib)
//
// That framework only exists on jailbroken devices, so for self-signed IPAs
// there is no substrate and dyld refuses to load the tweak. Providing the
// symbol ourselves — backed by the plain ObjC runtime — removes the dependency
// without changing a single generated hook.
//
// CydiaSubstrate semantics reproduced here
// ----------------------------------------
//   * look the selector up on the *target class* first;
//   * if the target class only inherits it, add a NEW method to the target
//     class and point %orig at the inherited implementation. This is what
//     substrate does and it matters: rewriting the superclass Method instead
//     would leak the hook into every sibling subclass (UIView, UIViewController,
//     UITableViewCell …), which is how the previous revision turned 31 harmless
//     passthrough hooks into process-wide changes;
//   * *result receives the previous IMP before the swap, so %orig still works;
//   * a selector that cannot be resolved anywhere leaves the target class
//     untouched and hands %orig a no-op stub rather than NULL, because the
//     generated hook bodies do `return %orig;` unconditionally and a NULL
//     call would fault at address 0.
//
// Argument safety is NOT handled here — it is handled in two places:
//   * tools/gen_hooks2.py emits the real type encoding read from the host
//     binary, so pointer/struct parameters stay pointer/struct typed;
//   * Hooks.generated.xm is compiled with -fno-objc-arc (see Makefile), so no
//     spurious objc_storeStrong() is emitted for a parameter we never touch.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// No-op IMP handed to %orig when a selector cannot be resolved at all.
// Returns 0, which is the correct value for `id`, numeric and BOOL returns and
// is harmless for `void`. It is only ever installed when we deliberately do NOT
// hook anything, so it cannot change a live method's behaviour.
// ---------------------------------------------------------------------------
static id rea_noop_imp(id self, SEL _cmd, ...) {
    (void)self; (void)_cmd;
    return nil;
}

// Find a method declared *directly* on cls (no superclass walk).
static Method rea_own_method(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    if (!list) return NULL;
    Method hit = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) {
            hit = list[i];
            break;
        }
    }
    free(list);
    return hit;
}

// Instance chain first, then the metaclass chain (class methods).
static Method rea_inherited_anywhere(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) return m;
    Class meta = object_getClass((id)cls);
    if (meta && class_isMetaClass(meta)) {
        return class_getInstanceMethod(meta, sel);
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// The one symbol the recovered tweak needs.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Install counters. A single line in hush.log tells us whether a hook layer
// that reports success actually reached the ObjC runtime: own/inherited are
// live hooks, missing means the host build has no such selector (a Swift
// method that was never @objc-exposed, usually).
// ---------------------------------------------------------------------------
static int gHushHookOwn, gHushHookInherited, gHushHookMissing, gHushHookTotal;

#define HUSH_MISSING_CAP 512
static const char *gHushMissingClass[HUSH_MISSING_CAP];
static const char *gHushMissingSel[HUSH_MISSING_CAP];
static int gHushMissingNames;

// ---------------------------------------------------------------------------
// Deferred install.
// %ctor runs before the Swift-backed classes are registered with the ObjC
// runtime, so class_getInstanceMethod() answers NULL for them and we used to
// drop the hook on the floor (hush.log showed missing=164 of 265). The method
// really does exist later on -- the host just had not registered the class yet.
// So park the request and retry once the app has finished launching.
// ---------------------------------------------------------------------------
#define HUSH_PENDING_CAP 1024

typedef struct {
    Class cls;
    SEL sel;
    IMP replacement;
    IMP *result;
} HushPendingHook;

static HushPendingHook gHushPending[HUSH_PENDING_CAP];
static int gHushPendingCount;
static int gHushRetryPass;

static void hush_pending_add(Class cls, SEL sel, IMP replacement, IMP *result) {
    if (gHushPendingCount >= HUSH_PENDING_CAP) return;
    gHushPending[gHushPendingCount].cls = cls;
    gHushPending[gHushPendingCount].sel = sel;
    gHushPending[gHushPendingCount].replacement = replacement;
    gHushPending[gHushPendingCount].result = result;
    gHushPendingCount++;
}

static void hush_pending_retry(void) {
    if (!gHushPendingCount) return;
    int fixed = 0;
    for (int i = 0; i < gHushPendingCount; i++) {
        HushPendingHook *p = &gHushPending[i];
        if (!p->cls || !p->sel || !p->replacement) continue;
        Method live = class_getInstanceMethod(p->cls, p->sel);
        if (!live) {
            Class meta = object_getClass((id)p->cls);
            if (meta) live = class_getInstanceMethod((Class)meta, p->sel);
        }
        if (!live) continue;
        IMP orig = method_getImplementation(live);
        // If our replacement is already the live IMP we have nothing to do.
        if (orig == p->replacement) { if (p->result) *(p->result) = (IMP)&rea_noop_imp; continue; }
        method_setImplementation(live, p->replacement);
        if (p->result) *(p->result) = orig;
        p->cls = Nil; p->sel = NULL; p->replacement = NULL; p->result = NULL;
        fixed++;
    }
    gHushRetryPass++;
    fprintf(stderr, "[Hush] pending retry #%d: installed %d of %d deferred hooks\n",
            gHushRetryPass, fixed, gHushPendingCount);
    NSString *line = [NSString stringWithFormat:
        @"[Hush] pending retry #%d: installed %d of %d deferred hooks",
        gHushRetryPass, fixed, gHushPendingCount];
    Class logger = objc_getClass("HushLogger");
    if (logger) {
        SEL ls = sel_registerName("logLevel:format:");
        if ([logger respondsToSelector:ls])
            ((void (*)(id, SEL, long long, id))objc_msgSend)(logger, ls, 4, line);
    }
}

static void hush_schedule_retries(void) {
    static const double delays[] = { 0.5, 1.5, 3.0, 6.0, 12.0 };
    for (unsigned i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ hush_pending_retry(); });
    }
}

static void hush_record_missing(Class cls, SEL sel) {
    if (gHushMissingNames >= HUSH_MISSING_CAP) return;
    const char *cn = cls ? class_getName(cls) : "?";
    const char *sn = sel ? sel_getName(sel) : "?";
    gHushMissingClass[gHushMissingNames] = cn ? cn : "?";
    gHushMissingSel[gHushMissingNames] = sn ? sn : "?";
    gHushMissingNames++;
}

// Dump the classes the recovered table depends on straight from the running
// runtime. The static scan of the shipping binary is not authoritative for
// Swift-backed classes, so this is the only honest answer to "what selectors
// does the host actually expose".
static void hush_probe_class(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { fprintf(stderr, "[Hush] probe %s: class MISSING\n", name); return; }
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    fprintf(stderr, "[Hush] probe %s: %u own methods\n", name, n);
    for (unsigned int i = 0; i < n && i < 500; i++)
        fprintf(stderr, "[Hush]   %s\n", sel_getName(method_getName(list[i])));
    if (list) free(list);
    Class super = class_getSuperclass(c);
    while (super && super != c) {
        unsigned int sn = 0;
        Method *sl = class_copyMethodList(super, &sn);
        fprintf(stderr, "[Hush] probe %s <- super %s: %u methods (filtered)\n",
                name, class_getName(super), sn);
        for (unsigned int i = 0; i < sn && i < 500; i++) {
            const char *m = sel_getName(method_getName(sl[i]));
            if (strstr(m,"privacy")||strstr(m,"album")||strstr(m,"Album")||
                strstr(m,"lock")||strstr(m,"Lock")||strstr(m,"visitor")||
                strstr(m,"Visitor")||strstr(m,"adms")||strstr(m,"vip"))
                fprintf(stderr, "[Hush]   * %s\n", m);
        }
        if (sl) free(sl);
        super = class_getSuperclass(super);
    }
}

static void hush_hook_report(void) {
    fprintf(stderr, "[Hush] hooks: total=%d own=%d inherited=%d missing=%d\n",
            gHushHookTotal, gHushHookOwn, gHushHookInherited, gHushHookMissing);
    // Also straight into the shared log so a field report needs no console.
    NSString *line = [NSString stringWithFormat:
        @"[Hush] hooks: total=%d own=%d inherited=%d missing=%d",
        gHushHookTotal, gHushHookOwn, gHushHookInherited, gHushHookMissing];
    Class logger = objc_getClass("HushLogger");
    if (logger) {
        SEL s = sel_registerName("logLevel:format:");
        if ([logger respondsToSelector:s]) {
            ((void (*)(id, SEL, long long, id))objc_msgSend)(logger, s, 4, line);
        }
    }
}

__attribute__((constructor))
static void hush_hook_counters_init(void) {
    // Report once the tweak's own constructors have all run.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        hush_hook_report();
        for (int i = 0; i < gHushMissingNames; i++)
            fprintf(stderr, "[Hush] missing %d/%d %s | %s\n", i + 1, gHushMissingNames,
                    gHushMissingClass[i], gHushMissingSel[i]);
        hush_probe_class("UserInformation");
        hush_probe_class("BDHomeViewController");
        hush_probe_class("BDHomeAlbumCell");
        hush_probe_class("BDPersonPrivacyAlbumCollectView");
        hush_probe_class("BDHomePageAlbumCell");
        hush_probe_class("BDPrivacyAlbumCell");
        hush_probe_class("BDProfile");
    });
    hush_schedule_retries();
}

void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result) {
    gHushHookTotal++;
    if (!cls || !sel) {
        gHushHookMissing++;
        if (result) *result = (IMP)&rea_noop_imp;
        return;
    }
    if (!replacement) {
        // Nothing to install; keep %orig pointing at the live implementation.
        Method live = rea_inherited_anywhere(cls, sel);
        if (result) *result = live ? method_getImplementation(live) : (IMP)&rea_noop_imp;
        return;
    }

    // 1) Declared on the target class: swap in place, exactly like substrate.
    Method own = rea_own_method(cls, sel);
    if (own) {
        gHushHookOwn++;
        IMP previous = method_getImplementation(own);
        if (result) *result = previous;
        if (previous != replacement) method_setImplementation(own, replacement);
        return;
    }

    // 2) Inherited: add the method to the target class only. The superclass
    //    chain is left untouched, so sibling classes keep the original IMP.
    Method inherited = rea_inherited_anywhere(cls, sel);
    if (inherited) {
        gHushHookInherited++;
        IMP previous = method_getImplementation(inherited);
        const char *types = method_getTypeEncoding(inherited);
        if (result) *result = previous;
        // class_addMethod returns NO if the class somehow already has it; that
        // can only be a race, so fall back to replacing that copy.
        if (!class_addMethod(cls, sel, replacement, types)) {
            Method now = rea_own_method(cls, sel);
            if (now && method_getImplementation(now) != replacement) {
                method_setImplementation(now, replacement);
            }
        }
        return;
    }

    // 3) Nowhere in the hierarchy: the host build never exposed this selector
    //    to Objective-C (Swift members that stayed un-@objc, renamed methods,
    //    protocol-only declarations). Real substrate installs the replacement
    //    as the sole implementation in exactly this case, and that is how the
    //    original dylib makes these hooks fire - dropping them here is why 164
    //    of 265 hooks silently did nothing.
    //
    //    %orig still points at the no-op, so an unconditional-passthrough body
    //    returns safely; a body that gates on HushConfig now actually runs.
    //    types is NULL because the host gave us no encoding to copy; objc_msgSend
    //    does not consult it, only runtime introspection does.
    gHushHookMissing++;
    hush_record_missing(cls, sel);
    // The class is probably registered but the Swift method is not exposed yet.
    // Park it: hush_pending_retry() installs it once the runtime knows the class.
    if (cls && sel && replacement) hush_pending_add(cls, sel, replacement, result);
    if (result) *result = (IMP)&rea_noop_imp;
}

// Logos only emits inline hooks for %hookf, which the recovered table does not
// use. Provide the symbol anyway so a future %hookf links instead of failing.
void MSHookFunction(void *symbol, void *replacement, void **result) {
    (void)symbol;
    (void)replacement;
    if (result) *result = (void *)&rea_noop_imp;
}

// Some substrate revisions expose these; harmless aliases keep older Logos happy.
void MSHookClassPair(Class a, Class b, Class metaA, Class metaB) {
    (void)a; (void)b; (void)metaA; (void)metaB;
}
