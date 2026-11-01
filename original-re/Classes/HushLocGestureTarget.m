//
//  HushLocGestureTarget.m
//  还原自 BluedHush_5.19 @ 0x2450d0（class index 27，flags=0x80 instanceSize=8）
//
//  原版把这三个 selector 挂成身边页定位信息条的手势 target：
//    hushLocTap:        点 = 按当前坐标刷新身边列表
//    hushLocDoubleTap:  双击 = 切换模拟开关
//    hushLocLongPress:  长按 = 打开地图选点页
//
//  a0 是 UIGestureRecognizer；如果被直接当 target 传 self，也能吃 nil。
//

#import <UIKit/UIKit.h>
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushRuntime.h"
#import "HushLocGestureTarget.h"

@implementation HushLocGestureTarget

+ (void)hushLocTap:(id)a0 {
    if ([a0 isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *g = (UIGestureRecognizer *)a0;
        if (g.state != UIGestureRecognizerStateEnded && g.state != UIGestureRecognizerStateBegan) return;
    }
    // 按当前（虚拟）坐标刷新身边列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"HushLocationDidChangeNotification" object:nil];
    [HushLogger logLevel:4 format:@"[Loc] tap -> refresh nearby"];
}

+ (void)hushLocDoubleTap:(id)a0 {
    HushConfig *cfg = [HushConfig shared];
    BOOL now = [cfg isEnabled:@"switch_location_sim"];
    [cfg setEnabled:!now forKey:@"switch_location_sim"];
    if (!now) [cfg setEnabled:YES forKey:@"switch_virtual_location"];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:@"[Loc] double tap -> location_sim=%@", now ? @"OFF" : @"ON"]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"HushLocationDidChangeNotification" object:nil];
}

+ (void)hushLocLongPress:(id)a0 {
    if ([a0 isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *g = (UIGestureRecognizer *)a0;
        if (g.state != UIGestureRecognizerStateBegan) return;
    }
    Class picker = NSClassFromString(@"HushLocationPickerController");
    if (!picker) {
        [HushLogger logLevel:1 format:@"[Loc] long press: HushLocationPickerController missing"];
        return;
    }
    UIViewController *top = HushVisibleTopViewController();
    if (!top) {
        [HushLogger logLevel:1 format:@"[Loc] long press: no visible VC"];
        return;
    }
    UIViewController *vc = [[picker alloc] init];
    if (!vc) return;

    UINavigationController *nav = top.navigationController;
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [top presentViewController:vc animated:YES completion:nil];
    }
    [HushLogger logLevel:3 format:@"[Loc] long press -> picker"];
}

@end
