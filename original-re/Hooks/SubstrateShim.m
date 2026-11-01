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
                   dispatch_get_main_queue(), ^{ hush_hook_report(); });
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

    // 3) Nowhere to be found (host dropped the selector this build). Do not
    //    invent one: hand %orig the stub so the passthrough body cannot fault.
    gHushHookMissing++;
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
