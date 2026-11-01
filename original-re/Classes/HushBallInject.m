// Entry point that actually puts the floating ball on screen.
//
// The original calls _HushGalInjectBall from inside _HushGalNicknameRequeryIfDue
// (@0x6e6b8, bl sites 0x6fab8 / 0x6fb58) — i.e. it piggybacks on a periodic
// "refresh the home page" pass rather than on a view lifecycle hook.
//
// _HushGalInjectBall itself (0x8492c, 453 insns) is:
//     cfg = [HushConfig shared];
//     if (!vc || ![cfg isEnabled:...]) return;
//     UIView *host = [vc view];
//     if (!host) return;
//     HushFloatBall *ball = [host viewWithTag:9876];
//     if (ball) { [ball setHidden:NO]; [host bringSubviewToFront:ball]; g_ball = ball; return; }
//     ... create at bounds-derived centre ...

#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushFloatBall.h"

// Tag the original stamped on the ball view (mov w2, #0x2694).
static const NSInteger kHushBallTag = 9876;

// Global ball slot (@0x257980).  Kept so repeated injections reuse one view.
static HushFloatBall *gHushBall = nil;

static UIWindow *HushCurrentKeyWindow(void) {
    UIWindow *kw = HushKeyWindow();
    if (kw) return kw;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static void HushInjectBallIntoView(UIView *host) {
    if (!host) return;
    if (CGRectGetWidth([host bounds]) < 1.0 || CGRectGetHeight([host bounds]) < 1.0) return;

    HushFloatBall *ball = (HushFloatBall *)[host viewWithTag:kHushBallTag];
    if (ball) {
        [ball setHidden:NO];
        [host bringSubviewToFront:ball];
        gHushBall = ball;
        return;
    }

    // If a previous round attached the ball to a different host, detach it first
    // so we never end up with two.
    if (gHushBall && gHushBall.superview && gHushBall.superview != host) {
        [gHushBall removeFromSuperview];
        gHushBall = nil;
    }

    CGFloat side = 56.0;
    CGFloat x = CGRectGetWidth([host bounds]) - side - 12.0;
    CGFloat y = CGRectGetHeight([host bounds]) * 0.30;
    if (y < 90.0) y = 90.0;          // keep it below the status/nav bar area
    CGRect frame = CGRectMake(x, y, side, side);

    HushFloatBall *newBall = [[HushFloatBall alloc] initWithFrame:frame];
    if (!newBall) return;
    [newBall setTag:kHushBallTag];
    [host addSubview:newBall];
    [host bringSubviewToFront:newBall];
    gHushBall = newBall;
}

void HushGalInjectBall(id viewController) {
    if (!viewController) return;
    if (![[HushConfig shared] isEnabled:@"float_ball"]) return;

    UIView *host = nil;
    if ([viewController respondsToSelector:@selector(view)]) {
        host = [viewController view];
    } else if ([viewController isKindOfClass:[UIView class]]) {
        host = (UIView *)viewController;
    }
    HushInjectBallIntoView(host);
}

void HushGalInjectBallFromKeyWindow(void) {
    // float_ball defaults to YES in the original registerDefaults table, so the
    // ball shows up on a fresh install.  switch_chat_gallery_ball is a separate,
    // default-OFF switch for the in-chat album button.
    if (![[HushConfig shared] isEnabled:@"float_ball"]) return;

    // 1) the deepest visible controller owns the view the user is looking at
    UIViewController *top = HushVisibleTopViewController();
    if (top && top.isViewLoaded) {
        HushInjectBallIntoView(top.view);
        if (gHushBall) return;
    }

    // 2) key window's root controller
    UIWindow *key = HushCurrentKeyWindow();
    if (key && key.rootViewController && key.rootViewController.isViewLoaded) {
        HushInjectBallIntoView(key.rootViewController.view);
        if (gHushBall) return;
    }

    // 3) the window itself as a last resort
    if (key) HushInjectBallIntoView(key);
}

BOOL HushBallIsPresent(void) {
    if (gHushBall && gHushBall.superview && !gHushBall.hidden) return YES;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            UIView *v = [w viewWithTag:kHushBallTag];
            if (v && v.window && !v.hidden) return YES;
        }
    }
    return NO;
}

void HushGalRemoveBall(void) {
    if (gHushBall) {
        [gHushBall removeFromSuperview];
        gHushBall = nil;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            UIView *v = [w viewWithTag:kHushBallTag];
            if (v) [v removeFromSuperview];
        }
    }
}
