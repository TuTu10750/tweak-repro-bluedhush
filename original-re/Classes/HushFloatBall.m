// Recovered implementation of HushFloatBall (from BluedHush_5.19.dylib).
//
// Original layout (class_ro_t @0x2460.., instanceStart=8, _iconView at the ivar
// offset the compiler loads from 0x246180):
//   +0x08  UIImageView *_iconView
//
// Method map, all verified against the original __text:
//   -initWithFrame:  @0x67360  types = @48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16
//   -dealloc         @0x6767c  types = v16@0:8
//   -refreshIcon     @0x676f4  types = v16@0:8
//   -onTap           @0x67778  types = v16@0:8   -> [HushSettingsPanel open]
//   -onPan:          @0x6778c  types = v24@0:8@16

#import "HushFloatBall.h"
#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushSettingsPanel.h"

// Notification the ball listens on: posted when ball_icon changes.
static NSString *const kHushBallCenterKey = @"runtime_ball_center";

@implementation HushFloatBall

// @0x67360
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // clearColor + user interaction on the container
    [self setBackgroundColor:[UIColor clearColor]];
    [self setUserInteractionEnabled:YES];

    // lazy icon view covering the whole bounds
    UIImageView *icon = [[UIImageView alloc] initWithFrame:[self bounds]];
    _iconView = icon;
    [_iconView setContentMode:UIViewContentModeScaleAspectFit];   // w2 = #1
    [_iconView setUserInteractionEnabled:NO];                     // w2 = #0

    // soft drop shadow under the glyph
    CALayer *layer = [_iconView layer];
    [layer setShadowColor:[[UIColor blackColor] CGColor]];
    [layer setShadowOpacity:0.3f];         // ldr s0,[0x1a8648] = 0x3e99999a
    [layer setShadowRadius:4.0];           // fmov d0,#4.0
    [layer setShadowOffset:CGSizeMake(0.0, 2.0)];

    [self addSubview:_iconView];
    [self refreshIcon];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshIcon)
                                                 name:HushBallIconStyleDidChangeNotification
                                               object:nil];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [self addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self addGestureRecognizer:pan];

    return self;
}

// @0x6767c — ARC owns the super dealloc; only the observation needs tearing down.
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// @0x676f4 : iconView.image = HushBallIconImage(HushBallIconCurrentStyle(), bounds.width)
- (void)refreshIcon {
    CGRect bounds = [self bounds];
    UIImage *img = HushBallIconImage(HushBallIconCurrentStyle(), bounds.size.width);
    [[self iconView] setImage:img];
}

// @0x67778 : tail-call into the settings panel singleton.
- (void)onTap {
    [HushSettingsPanel open];
}

// @0x6778c
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = [self superview];
    CGPoint t = [g translationInView:host];

    CGPoint c = [self center];
    [self setCenter:CGPointMake(c.x + t.x, c.y + t.y)];
    [g setTranslation:CGPointZero inView:host];

    // Persist the resting position once the finger lifts.
    if ([g state] == UIGestureRecognizerStateEnded) {
        [[HushConfig shared] setString:NSStringFromCGPoint([self center])
                                forKey:kHushBallCenterKey];
    }
}

@end
