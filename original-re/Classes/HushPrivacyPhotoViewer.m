#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "HushRuntime.h"
#import "HushLogger.h"

static UIImageView *HushPrivacyBestImageView(UIView *view, UIView **outRoot) {
    UIImageView *best = nil;
    CGFloat bestArea = -1.0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:view];
    NSInteger guard = 0;
    while (stack.count && guard++ < 180) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            if (iv.image) {
                CGFloat area = iv.bounds.size.width * iv.bounds.size.height;
                if (area > bestArea) {
                    bestArea = area;
                    best = iv;
                    if (outRoot) *outRoot = v;
                }
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

static NSURL *HushPrivacyImageURL(UIImageView *iv) {
    if (!iv) return nil;
    NSArray *keys = @[@"sd_imageURL", @"imageURL", @"url"];
    for (NSString *key in keys) {
        @try {
            id v = [iv valueForKey:key];
            if ([v isKindOfClass:[NSURL class]]) return (NSURL *)v;
            if ([v isKindOfClass:[NSString class]] && [v length] > 8) {
                return [NSURL URLWithString:v];
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

@interface HushPrivacyPhotoViewer : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *initialImage;
@property (nonatomic, strong) NSURL *remoteURL;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation HushPrivacyPhotoViewer

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 4.0;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _imageView = [[UIImageView alloc] initWithFrame:_scroll.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _imageView.image = _initialImage;
    [_scroll addSubview:_imageView];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(12, 44, 44, 44);
    close.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    close.layer.cornerRadius = 22;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightLight];
    [close addTarget:self action:@selector(close:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scroll addGestureRecognizer:doubleTap];

    if (_remoteURL && [_imageView respondsToSelector:
                        @selector(sd_setImageWithURL:placeholderImage:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            _imageView,
            @selector(sd_setImageWithURL:placeholderImage:),
            _remoteURL, _initialImage);
    }
}

- (void)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doubleTap:(UITapGestureRecognizer *)g {
    if (_scroll.zoomScale > 1.01) {
        [_scroll setZoomScale:1.0 animated:YES];
        return;
    }
    CGPoint p = [g locationInView:_imageView];
    CGFloat w = _scroll.bounds.size.width / 2.5;
    CGFloat h = _scroll.bounds.size.height / 2.5;
    CGRect r = CGRectMake(p.x - w / 2, p.y - h / 2, w, h);
    [_scroll zoomToRect:r animated:YES];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageView;
}

@end

BOOL HushPrivacyPhotoViewerShowCell(id cell) {
    if (!cell || ![cell isKindOfClass:[UIView class]]) return NO;
    UIView *root = nil;
    UIImageView *iv = HushPrivacyBestImageView((UIView *)cell, &root);
    NSURL *url = HushPrivacyImageURL(iv);
    if (!iv.image && !url) return NO;

    UIViewController *top = HushVisibleTopViewController();
    if (!top) return NO;
    HushPrivacyPhotoViewer *viewer = [[HushPrivacyPhotoViewer alloc] init];
    viewer.initialImage = iv.image;
    viewer.remoteURL = url;
    viewer.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:viewer animated:YES completion:nil];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][隐私相册] 直接打开全屏照片 cell=%@ image=%@ remote=%d",
        NSStringFromClass([cell class]),
        iv.image ? NSStringFromCGSize(iv.image.size) : @"无",
        url ? 1 : 0]];
    return YES;
}
