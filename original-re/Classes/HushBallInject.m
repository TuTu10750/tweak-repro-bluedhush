// Entry point that actually puts the floating ball on screen.
//
// The original calls _HushGalInjectBall from inside _HushGalNicknameRequeryIfDue
// (@0x6e6b8, bl sites 0x6fab8 / 0x6fb58) — i.e. it piggybacks on a periodic
// "refresh the home page" pass rather than on a view lifecycle hook.  We do the
// same thing without depending on any host class name: watch for the app
// becoming active and inject into the key window.
//
// _HushGalInjectBall itself (0x8492c, 453 insns) is:
//     cfg = [HushConfig shared];
//     if (!vc || ![cfg isEnabled:@"switch_chat_gallery_ball"]) return;
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

static void HushInjectBallIntoView(UIView *host) {
    if (!host) return;

    HushFloatBall *ball = (HushFloatBall *)[host viewWithTag:kHushBallTag];
    if (ball) {
        [ball setHidden:NO];
        [host bringSubviewToFront:ball];
        gHushBall = ball;
        return;
    }

    CGRect bounds = [host bounds];
    if (CGRectGetWidth(bounds) < 1.0 || CGRectGetHeight(bounds) < 1.0) return;

    // Original default placement: right edge, ~30% down.
    CGFloat side = 56.0;
    CGFloat x = CGRectGetWidth(bounds) - side - 12.0;
    CGFloat y = CGRectGetHeight(bounds) * 0.30;
    CGRect frame = CGRectMake(x, y, side, side);

    HushFloatBall *newBall = [[HushFloatBall alloc] initWithFrame:frame];
    if (!newBall) return;
    [newBall setTag:kHushBallTag];
    [host addSubview:newBall];
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

    UIWindow *key = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) {
        id app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(keyWindow)]) key = [app keyWindow];
    }
    if (!key) return;

    HushInjectBallIntoView(key);
}

void HushGalRemoveBall(void) {
    if (!gHushBall) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                UIView *v = [w viewWithTag:kHushBallTag];
                if (v) { [v removeFromSuperview]; gHushBall = nil; }
            }
        }
        return;
    }
    [gHushBall removeFromSuperview];
    gHushBall = nil;
}
