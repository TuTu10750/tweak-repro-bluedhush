// Navigation helpers recovered from BluedHush_5.19.dylib.
//
// These five C functions are what every panel-opening path in the original
// goes through, so they have to exist before HushSettingsPanel can present
// itself.  Recovered shapes:
//
//   _HushTopViewController            @0x3445c (236 B)
//       w = <key window>; vc = [w rootViewController]; if (!vc) return nil;
//       while ((n = [vc presentedViewController])) vc = n;   // walk presentation chain
//       return vc;
//
//   _HushForceVisibleView             @0x32d28 (172 B)
//       if (!v) return nil;
//       if (![v isKindOfClass:[UIView class]]) return v;
//       if ([v isHidden]) [v setHidden:NO];
//       if ([v alpha] < 1.0) [v setAlpha:1.0];
//       return v;
//
//   _HushVisibleTopViewController     @0x34548 (1000 B)
//       walks rootViewController / presentedViewController / childViewControllers
//       (reverseObjectEnumerator) and prefers the last child whose isViewLoaded
//       and whose view.window is non-nil.
//
//   _HushVisibleNavigationController  @0x34930 (1568 B)
//       same walk, returning the first UINavigationController reached.

#import "HushRuntime.h"

UIWindow *HushKeyWindow(void) {
    UIWindow *key = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }

    if (!key) {
        id app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(keyWindow)]) {
            key = [app keyWindow];
        }
        if (!key) {
            for (UIWindow *w in [app windows]) {
                if (w.isKeyWindow) { key = w; break; }
            }
        }
    }
    return key;
}

UIViewController *HushTopViewController(void) {
    UIWindow *w = HushKeyWindow();
    if (!w) return nil;

    UIViewController *vc = [w rootViewController];
    if (!vc) return nil;

    // Follow the presentation chain to its tip.
    UIViewController *next = nil;
    while ((next = [vc presentedViewController]) != nil) {
        vc = next;
    }
    return vc;
}

// Depth-first, last-child-wins walk.  The original iterates
// [childViewControllers reverseObjectEnumerator], so the topmost child wins.
static UIViewController *HushDeepestVisible(UIViewController *vc, int depth) {
    if (!vc || depth > 12) return nil;

    NSArray *children = [vc childViewControllers];
    for (UIViewController *child in [children reverseObjectEnumerator]) {
        UIViewController *deep = HushDeepestVisible(child, depth + 1);
        if (deep) return deep;
    }

    if ([vc isViewLoaded] && [vc view] && [[vc view] window]) return vc;
    return nil;
}

UIViewController *HushVisibleTopViewController(void) {
    UIWindow *w = HushKeyWindow();
    if (!w) return nil;

    UIViewController *root = [w rootViewController];
    if (!root) return nil;

    UIViewController *vc = root;
    UIViewController *next = nil;
    while ((next = [vc presentedViewController]) != nil) {
        vc = next;
    }

    UIViewController *deep = HushDeepestVisible(vc, 0);
    if (deep) return deep;

    if ([vc isViewLoaded] && [vc view] && [[vc view] window]) return vc;
    return vc;
}

// Walk children for a UINavigationController, preferring the visible one.
static UINavigationController *HushFindNav(UIViewController *vc, int depth) {
    if (!vc || depth > 12) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController *)vc;

    for (UIViewController *child in [vc childViewControllers]) {
        UINavigationController *nav = HushFindNav(child, depth + 1);
        if (nav) return nav;
    }
    return nil;
}

UINavigationController *HushVisibleNavigationController(void) {
    UIWindow *w = HushKeyWindow();
    if (!w) return nil;

    UIViewController *vc = [w rootViewController];
    if (!vc) return nil;

    UIViewController *next = nil;
    while ((next = [vc presentedViewController]) != nil) {
        vc = next;
    }

    UINavigationController *nav = HushFindNav(vc, 0);
    if (nav) return nav;

    if ([vc isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)vc;
    }
    if ([vc navigationController]) return [vc navigationController];
    return nil;
}

UIView *HushForceVisibleView(UIView *v) {
    if (!v) return nil;
    if (![v isKindOfClass:[UIView class]]) return v;

    if ([v isHidden]) [v setHidden:NO];
    if ([v alpha] < 1.0) [v setAlpha:1.0];
    return v;
}
