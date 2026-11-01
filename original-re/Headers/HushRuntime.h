// C-level entry points recovered from BluedHush_5.19.dylib.
// The original tweak is NOT an Objective-C class hierarchy: it exports 474
// named C functions under the _Hush* prefix and hooks via MSHookMessageEx.
// This header is the single place where those entry points are declared so
// the class layer can call them exactly like the original did.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma mark - notifications

// Posted whenever ball_icon changes, so every floating ball re-renders.
extern NSString *const HushBallIconStyleDidChangeNotification;

#pragma mark - Ball icon (@0x1956a0 .. @0x195b38)

// g_styles table lives at 0x259808 and holds 6 (@[value, title]) pairs.
FOUNDATION_EXPORT NSUInteger HushBallIconStyleCount(void);
FOUNDATION_EXPORT NSString *HushBallIconStyleValue(NSUInteger idx);   // @0x1956a0
FOUNDATION_EXPORT NSString *HushBallIconStyleTitle(NSUInteger idx);   // @0x1958dc
FOUNDATION_EXPORT NSUInteger HushBallIconStyleFromValue(NSString *v); // @0x195780
FOUNDATION_EXPORT NSArray *HushBallIconStyleAll(void);                // @0x1959bc
FOUNDATION_EXPORT NSUInteger HushBallIconCurrentStyle(void);          // @0x195ab8
FOUNDATION_EXPORT UIImage *HushBallIconImage(NSUInteger style, CGFloat scale); // @0x195b38

#pragma mark - floating ball injection (@0x8492c, @0x85cc0)

FOUNDATION_EXPORT void HushGalInjectBall(id viewController);   // @0x8492c
FOUNDATION_EXPORT void HushGalRemoveBall(void);                // @0x85cc0
// Same injection, but resolves the host window itself instead of taking a VC.
FOUNDATION_EXPORT void HushGalInjectBallFromKeyWindow(void);

#pragma mark - navigation helpers (@0x33fb8, @0x3445c, @0x34548, @0x34930, @0x32d28)

FOUNDATION_EXPORT UIWindow *HushKeyWindow(void);                              // @0x33fb8
FOUNDATION_EXPORT UIViewController *HushTopViewController(void);              // @0x3445c
FOUNDATION_EXPORT UIViewController *HushVisibleTopViewController(void);       // @0x34548
FOUNDATION_EXPORT UINavigationController *HushVisibleNavigationController(void); // @0x34930
FOUNDATION_EXPORT UIView *HushForceVisibleView(UIView *v);                    // @0x32d28

#pragma mark - config gate (@0x120f8, @0x130b8)

FOUNDATION_EXPORT BOOL HushKeyNeedsActivation(NSString *key);
FOUNDATION_EXPORT BOOL HushHostCompatKeyIsInapplicable(NSString *key);
FOUNDATION_EXPORT BOOL gHushActivationCacheReady;
