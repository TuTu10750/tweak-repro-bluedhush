// Ball-icon module, recovered from BluedHush_5.19.dylib.
//
// The original table is built inside the block at 0x209040 (invoke 0x1967e4)
// and cached in the static at 0x259808; each row is a two-element array
// @[value, title].  The six rows were read straight out of the __cfstring
// objects at 0x20bd98 / 0x22df98 .. and 0x22df78 / 0x22dfb8 ..
//
// _HushBallIconImage @0x195b38 is 24812 bytes of CoreGraphics vector drawing:
//   UIGraphicsImageRenderer(size:(scale,scale)) + imageWithActions:(block @0x195c28)
// The drawing block is ~4.5 KB of BezierPath construction per style.  Rather
// than transliterate 1100 instructions we redraw each style with the same
// geometry vocabulary and the same 50pt default canvas the original used
// (fcsel d8, d0, 50.0, hi), which keeps the layout and hitbox identical.

#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushLogger.h"

NSString *const HushBallIconStyleDidChangeNotification = @"HushBallIconStyleDidChangeNotification";

static NSArray<NSArray<NSString *> *> *gHushBallStyles = nil;
static dispatch_once_t gHushBallStylesOnce;

// @0x1956a0 / @0x1958dc / @0x195780 / @0x1959bc all share this table build.
static NSArray<NSArray<NSString *> *> *HushBallStyles(void) {
    dispatch_once(&gHushBallStylesOnce, ^{
        gHushBallStyles = @[
            @[@"bubble_bolt", @"\u6c14\u6ce1\u95ea\u7535"],
            @[@"sparkle",     @"\u661f\u8292"],
            @[@"rider",       @"\u9a91\u624b\u5f69\u8679\u65d7"],
            @[@"fish",        @"\u54b8\u9c7c"],
            @[@"blued_mark",  @"Blued \u6c34\u5370"],
            @[@"blued_label", @"\u75d2\u4e86\u8d34\u7bb1"],
        ];
    });
    return gHushBallStyles;
}

NSUInteger HushBallIconStyleCount(void) { return HushBallStyles().count; }

// @0x1956a0: idx<0 || idx>=count -> 0 ; return g_styles[idx][0]
NSString *HushBallIconStyleValue(NSUInteger idx) {
    NSArray *all = HushBallStyles();
    if (idx >= all.count) idx = 0;
    return all[idx][0];
}

// @0x1958dc: same guard, returns g_styles[idx][1]
NSString *HushBallIconStyleTitle(NSUInteger idx) {
    NSArray *all = HushBallStyles();
    if (idx >= all.count) idx = 0;
    return all[idx][1];
}

// @0x195780: empty -> 0 ; linear scan with isEqualToString:, default 0
NSUInteger HushBallIconStyleFromValue(NSString *v) {
    if ([v length] == 0) return 0;
    NSArray *all = HushBallStyles();
    for (NSUInteger i = 0; i < all.count; i++) {
        if ([all[i][0] isEqualToString:v]) return i;
    }
    return 0;
}

// @0x1959bc: mutable array of @(i) for every style
NSArray *HushBallIconStyleAll(void) {
    NSArray *all = HushBallStyles();
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < all.count; i++) {
        [out addObject:[NSNumber numberWithUnsignedInteger:i]];
    }
    return out;
}

// @0x195ab8: [[HushConfig shared] stringForKey:@"ball_icon"] -> FromValue
NSUInteger HushBallIconCurrentStyle(void) {
    NSString *v = [[HushConfig shared] stringForKey:@"ball_icon"];
    return HushBallIconStyleFromValue(v);
}

static void HushDrawStar(CGContextRef c, CGPoint ctr, CGFloat r, NSUInteger points) {
    CGContextMoveToPoint(c, ctr.x, ctr.y - r);
    for (NSUInteger i = 1; i <= points * 2; i++) {
        CGFloat rr = (i % 2) ? r : r * 0.45;
        CGFloat a  = -M_PI_2 + (CGFloat)i * M_PI / (CGFloat)points;
        CGContextAddLineToPoint(c, ctr.x + cos(a) * rr, ctr.y + sin(a) * rr);
    }
    CGContextClosePath(c);
}

// @0x195b38.  Same contract: (style, scale) -> a square image of side `scale`,
// where scale <= 0 falls back to the original's 50.0.
UIImage *HushBallIconImage(NSUInteger style, CGFloat scale) {
    if (scale <= 0) scale = 50.0;
    NSArray *all = HushBallStyles();
    if (style >= all.count) style = 0;

    CGSize size = CGSizeMake(scale, scale);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat s = scale;
        CGRect box = CGRectMake(s * 0.06, s * 0.06, s * 0.88, s * 0.88);
        CGPoint ctr = CGPointMake(s * 0.5, s * 0.5);

        // Shared chrome: a soft white disc so the glyph reads on any wallpaper.
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:0.92].CGColor);
        CGContextFillEllipseInRect(c, box);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.0 alpha:0.10].CGColor);
        CGContextSetLineWidth(c, MAX(1.0, s * 0.02));
        CGContextStrokeEllipseInRect(c, box);

        switch (style) {
            case 0: { // bubble_bolt — speech bubble with a bolt inside
                UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(box, s * 0.16, s * 0.20)
                                                                cornerRadius:s * 0.14];
                [p moveToPoint:CGPointMake(s * 0.36, s * 0.66)];
                [p addLineToPoint:CGPointMake(s * 0.44, s * 0.82)];
                [p addLineToPoint:CGPointMake(s * 0.52, s * 0.66)];
                [p closePath];
                [[UIColor colorWithRed:0.10 green:0.55 blue:1.00 alpha:1.0] setFill];
                [p fill];
                UIBezierPath *bolt = [UIBezierPath bezierPath];
                [bolt moveToPoint:CGPointMake(s * 0.53, s * 0.28)];
                [bolt addLineToPoint:CGPointMake(s * 0.42, s * 0.52)];
                [bolt addLineToPoint:CGPointMake(s * 0.50, s * 0.52)];
                [bolt addLineToPoint:CGPointMake(s * 0.46, s * 0.72)];
                [bolt addLineToPoint:CGPointMake(s * 0.59, s * 0.46)];
                [bolt addLineToPoint:CGPointMake(s * 0.51, s * 0.46)];
                [bolt closePath];
                [[UIColor whiteColor] setFill];
                [bolt fill];
            } break;

            case 1: { // sparkle — four-point star plus two satellites
                CGContextSetFillColorWithColor(c, [UIColor colorWithRed:1.00 green:0.72 blue:0.16 alpha:1.0].CGColor);
                HushDrawStar(c, ctr, s * 0.30, 4);
                CGContextFillPath(c);
                CGContextSetFillColorWithColor(c, [UIColor colorWithRed:1.00 green:0.86 blue:0.45 alpha:1.0].CGColor);
                HushDrawStar(c, CGPointMake(s * 0.74, s * 0.26), s * 0.11, 4);
                CGContextFillPath(c);
                HushDrawStar(c, CGPointMake(s * 0.24, s * 0.74), s * 0.08, 4);
                CGContextFillPath(c);
            } break;

            case 2: { // rider — rainbow stripes with a flag pole
                NSArray<UIColor *> *rainbow = @[
                    [UIColor colorWithRed:0.91 green:0.30 blue:0.24 alpha:1.0],
                    [UIColor colorWithRed:0.96 green:0.62 blue:0.15 alpha:1.0],
                    [UIColor colorWithRed:0.98 green:0.85 blue:0.20 alpha:1.0],
                    [UIColor colorWithRed:0.30 green:0.72 blue:0.36 alpha:1.0],
                    [UIColor colorWithRed:0.25 green:0.52 blue:0.90 alpha:1.0],
                    [UIColor colorWithRed:0.55 green:0.35 blue:0.78 alpha:1.0],
                ];
                CGFloat stripeH = (s * 0.52) / rainbow.count;
                for (NSUInteger i = 0; i < rainbow.count; i++) {
                    CGRect sr = CGRectMake(s * 0.24, s * 0.24 + stripeH * i, s * 0.52, stripeH);
                    CGContextSetFillColorWithColor(c, rainbow[i].CGColor);
                    CGContextFillRect(c, sr);
                }
                CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.25 alpha:1.0].CGColor);
                CGContextFillRect(c, CGRectMake(s * 0.20, s * 0.20, s * 0.035, s * 0.60));
            } break;

            case 3: { // fish — a simple fish silhouette
                CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.36 green:0.62 blue:0.78 alpha:1.0].CGColor);
                CGContextFillEllipseInRect(c, CGRectMake(s * 0.20, s * 0.36, s * 0.46, s * 0.28));
                CGContextMoveToPoint(c, s * 0.66, s * 0.50);
                CGContextAddLineToPoint(c, s * 0.82, s * 0.36);
                CGContextAddLineToPoint(c, s * 0.82, s * 0.64);
                CGContextClosePath(c);
                CGContextFillPath(c);
                CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
                CGContextFillEllipseInRect(c, CGRectMake(s * 0.28, s * 0.44, s * 0.06, s * 0.06));
                CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.1 alpha:1.0].CGColor);
                CGContextFillEllipseInRect(c, CGRectMake(s * 0.295, s * 0.455, s * 0.03, s * 0.03));
            } break;

            case 4: { // blued_mark — the Blued drop mark
                UIBezierPath *drop = [UIBezierPath bezierPath];
                [drop moveToPoint:CGPointMake(s * 0.50, s * 0.22)];
                [drop addCurveToPoint:CGPointMake(s * 0.72, s * 0.56)
                        controlPoint1:CGPointMake(s * 0.62, s * 0.34)
                        controlPoint2:CGPointMake(s * 0.72, s * 0.44)];
                [drop addArcWithCenter:ctr radius:s * 0.22
                           startAngle:0 endAngle:M_PI clockwise:YES];
                [drop addCurveToPoint:CGPointMake(s * 0.50, s * 0.22)
                        controlPoint1:CGPointMake(s * 0.28, s * 0.44)
                        controlPoint2:CGPointMake(s * 0.38, s * 0.34)];
                [drop closePath];
                [[UIColor colorWithRed:0.12 green:0.56 blue:0.98 alpha:1.0] setFill];
                [drop fill];
            } break;

            default: { // 5 blued_label — a tag/label shape
                UIBezierPath *tag = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(box, s * 0.18, s * 0.26)
                                                                  cornerRadius:s * 0.10];
                [[UIColor colorWithRed:0.98 green:0.55 blue:0.20 alpha:1.0] setFill];
                [tag fill];
                CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
                CGContextFillEllipseInRect(c, CGRectMake(s * 0.28, s * 0.46, s * 0.08, s * 0.08));
            } break;
        }
    }];
    return img;
}
