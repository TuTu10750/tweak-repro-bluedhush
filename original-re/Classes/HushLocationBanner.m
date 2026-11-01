//
//  HushLocationBanner.m
//  还原自 BluedHush_5.19 —— 身边页顶部那行定位信息
//
//  原版行为（用户实测描述 + 4_IMG_1200 面板说明）：
//    · 虚拟定位开启后，身边页标题行右侧出现两行小字
//        第 1 行「虚拟定位开」
//        第 2 行  地址 / 坐标
//    · 点一下       → 按该坐标刷新身边列表
//    · 长按         → 打开地图选点页 HushLocationPickerController
//
//  原版没有 HushLocationBanner 这个类，信息条是运行时拼出来的 UILabel，
//  手势 target 是 HushLocGestureTarget。这里用一个独立 UIView 承载，
//  tag 9877，与悬浮球的 9876 区分开。
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "HushConfig.h"
#import "HushRuntime.h"

#import "HushLocationBanner.h"

static const NSInteger kHushLocBannerTag = 9877;

@interface HushLocationBanner ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation HushLocationBanner

+ (instancetype)bannerIn:(UIView *)host {
    if (!host) return nil;
    for (UIView *v in host.subviews) {
        if (v.tag == kHushLocBannerTag && [v isKindOfClass:[HushLocationBanner class]]) {
            return (HushLocationBanner *)v;
        }
    }
    return nil;
}

+ (void)installInto:(UIView *)host {
    if (!host) return;

    HushConfig *cfg = [HushConfig shared];
    BOOL locOn  = [cfg isEnabled:@"switch_location_sim"];
    BOOL vlocOn = [cfg isEnabled:@"switch_virtual_location"];
    BOOL on = locOn || vlocOn;

    HushLocationBanner *existing = [self bannerIn:host];
    if (!on) {
        if (existing) [existing removeFromSuperview];
        return;
    }
    if (existing) {
        // 只在文案真的变了才刷，避免每次布局都写 label
        NSString *want = [self displayTextForConfig:cfg];
        if (![existing.detailLabel.text isEqualToString:want]) [existing refresh];
        return;
    }

    HushLocationBanner *b = [[HushLocationBanner alloc] initWithFrame:CGRectZero];
    b.tag = kHushLocBannerTag;
    [host addSubview:b];

    // 贴父视图右上角（原版贴在标题行「交友 同城」的右侧）
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [b.topAnchor constraintEqualToAnchor:host.topAnchor constant:6.0],
        [b.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-54.0],
        [b.widthAnchor constraintLessThanOrEqualToConstant:200.0],
    ]];

    [b refresh];
    [host bringSubviewToFront:b];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor colorWithRed:0.15 green:0.72 blue:0.42 alpha:1.0];
    _titleLabel.textAlignment = NSTextAlignmentRight;
    _titleLabel.numberOfLines = 1;

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:10.0];
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textAlignment = NSTextAlignmentRight;
    _detailLabel.numberOfLines = 2;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 1.0;
    stack.alignment = UIStackViewAlignmentTrailing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [self addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.45;
    [self addGestureRecognizer:lp];

    return self;
}

+ (NSString *)displayTextForConfig:(HushConfig *)cfg {
    NSString *addr = [cfg stringForKey:@"runtime_loc_address"];
    NSString *name = [cfg stringForKey:@"runtime_loc_name"];
    if (addr.length > 0) return addr;
    if (name.length > 0) return name;
    if ([cfg hasCustomLocation]) {
        return [NSString stringWithFormat:@"%.6f, %.6f", [cfg customLat], [cfg customLng]];
    }
    return @"未选定位置 · 长按选择";
}

- (void)refresh {
    HushConfig *cfg = [HushConfig shared];
    BOOL locOn  = [cfg isEnabled:@"switch_location_sim"];
    BOOL vlocOn = [cfg isEnabled:@"switch_virtual_location"];

    _titleLabel.text = (locOn || vlocOn) ? @"虚拟定位开" : @"虚拟定位关";

    _detailLabel.text = [[self class] displayTextForConfig:cfg];

    // 绝不在这里调 setNeedsLayout：refresh 会在 viewDidLayoutSubviews 的调用链上执行，
    // 让父视图重排等于「布局 → 改布局 → 再布局」无限循环，watchdog 20 秒强杀。
}

- (void)onTap {
    // 原版：点击按当前坐标刷新身边列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"HushLocationDidChangeNotification" object:nil];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    Class picker = NSClassFromString(@"HushLocationPickerController");
    if (!picker) return;

    UIViewController *top = HushVisibleTopViewController();
    if (!top) return;
    UIViewController *vc = [[picker alloc] init];
    if (!vc) return;

    UINavigationController *nav = top.navigationController;
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [top presentViewController:vc animated:YES completion:nil];
    }
}

@end
