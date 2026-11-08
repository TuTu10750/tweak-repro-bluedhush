#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "HushRuntime.h"
#import "HushLogger.h"

// BluedHush 5.19 的 HushAlbumHighResolutionURL 实证规则：
// bldimg.com / bldimg.cn 的 !Head.jpg 路径追加 !original.png 才是原图地址。
// 直接拿 UIImageView 的 sd_imageURL 只会得到 192x192 的 !Head.jpg 缩略图。
static NSString *HushPrivacyHighResolutionString(id object) {
    NSString *raw = nil;
    if ([object isKindOfClass:[NSURL class]]) {
        raw = [(NSURL *)object absoluteString];
    } else if ([object isKindOfClass:[NSString class]]) {
        raw = (NSString *)object;
    }
    if (!raw.length) return nil;

    NSURLComponents *components =
        [NSURLComponents componentsWithString:raw];
    if (!components) return raw;

    NSString *host = components.host.lowercaseString;
    NSString *path = components.percentEncodedPath.lowercaseString;
    BOOL imageHost =
        [host isEqualToString:@"www.bldimg.com"] ||
        [host isEqualToString:@"bldimg.com"] ||
        [host isEqualToString:@"www.bldimg.cn"] ||
        [host isEqualToString:@"bldimg.cn"];
    if (imageHost &&
        [path containsString:@"/userfiles/"] &&
        [path hasSuffix:@"!head.jpg"] &&
        ![path containsString:@"!original."]) {
        components.percentEncodedPath =
            [components.percentEncodedPath stringByAppendingString:@"!original.png"];
        NSString *out = components.string;
        if (out.length) return out;
    }
    return raw;
}

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
            if ([v isKindOfClass:[NSURL class]]) {
                NSString *high = HushPrivacyHighResolutionString(v);
                if (high.length) return [NSURL URLWithString:high];
            }
            if ([v isKindOfClass:[NSString class]] && [v length] > 8) {
                NSString *high = HushPrivacyHighResolutionString(v);
                if (high.length) return [NSURL URLWithString:high];
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSURL *HushPrivacyOriginalURLFromCell(id cell) {
    NSArray *modelKeys = @[@"userAlbum", @"_userAlbum", @"album", @"_album",
                           @"photoModel", @"_photoModel", @"model", @"_model"];
    for (NSString *key in modelKeys) {
        @try {
            id model = [cell valueForKey:key];
            if (!model) continue;
            for (NSString *urlKey in @[@"url", @"imageUrl", @"imageURL",
                                        @"picUrl", @"originalUrl", @"originUrl"]) {
                id v = [model valueForKey:urlKey];
                if ([v isKindOfClass:[NSURL class]]) {
                    NSString *high = HushPrivacyHighResolutionString(v);
                    if (high.length) return [NSURL URLWithString:high];
                }
                if ([v isKindOfClass:[NSString class]] && [v length] > 8) {
                    NSString *high = HushPrivacyHighResolutionString(v);
                    if (high.length) return [NSURL URLWithString:high];
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

@interface HushPrivacyPhotoViewer : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *initialImage;
@property (nonatomic, strong) NSURL *remoteURL;
@property (nonatomic, strong) NSArray *urls;
@property (nonatomic, strong) NSArray *fallbackImages;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *counter;
@end

@implementation HushPrivacyPhotoViewer

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 6.0;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _imageView = [[UIImageView alloc] initWithFrame:_scroll.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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

    _counter = [[UILabel alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 82, 50, 64, 30)];
    _counter.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    _counter.textColor = [UIColor whiteColor];
    _counter.textAlignment = NSTextAlignmentCenter;
    _counter.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _counter.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _counter.layer.cornerRadius = 15;
    _counter.clipsToBounds = YES;
    [self.view addSubview:_counter];

    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scroll addGestureRecognizer:doubleTap];

    UISwipeGestureRecognizer *left =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeLeft:)];
    left.direction = UISwipeGestureRecognizerDirectionLeft;
    [_scroll addGestureRecognizer:left];
    UISwipeGestureRecognizer *right =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeRight:)];
    right.direction = UISwipeGestureRecognizerDirectionRight;
    [_scroll addGestureRecognizer:right];
    [self loadIndex:_currentIndex];
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

- (void)swipeLeft:(UISwipeGestureRecognizer *)g {
    if (_currentIndex + 1 >= _urls.count) return;
    [self loadIndex:_currentIndex + 1];
}

- (void)swipeRight:(UISwipeGestureRecognizer *)g {
    if (_currentIndex <= 0) return;
    [self loadIndex:_currentIndex - 1];
}

- (void)loadIndex:(NSInteger)index {
    NSInteger count = MAX(_urls.count, _fallbackImages.count);
    if (count <= 0) return;
    _currentIndex = MIN(MAX(index, 0), count - 1);
    UIImage *fallback = _currentIndex < _fallbackImages.count
                      ? _fallbackImages[_currentIndex] : nil;
    if (![fallback isKindOfClass:[UIImage class]]) fallback = _initialImage;
    id urlObject = _currentIndex < _urls.count ? _urls[_currentIndex] : nil;
    NSURL *url = [urlObject isKindOfClass:[NSURL class]] ? (NSURL *)urlObject : nil;
    _imageView.image = fallback;
    [_scroll setZoomScale:1.0 animated:NO];
    _imageView.frame = _scroll.bounds;
    _counter.text = [NSString stringWithFormat:@"%ld/%ld",
                     (long)(_currentIndex + 1), (long)count];
    if (url && [_imageView respondsToSelector:
                @selector(sd_setImageWithURL:placeholderImage:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            _imageView,
            @selector(sd_setImageWithURL:placeholderImage:),
            url, fallback);
    }
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][隐私相册] 浏览第 %ld/%ld 张 image=%@ remote=%d url=%@",
        (long)(_currentIndex + 1), (long)count,
        fallback ? NSStringFromCGSize(fallback.size) : @"无", url ? 1 : 0,
        url.absoluteString ?: @"无"]];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageView;
}

@end

BOOL HushPrivacyPhotoViewerShowCollection(id collectionView, id indexPath) {
    if (!collectionView || !indexPath) return NO;
    id selected = nil;
    @try { selected = [collectionView cellForItemAtIndexPath:indexPath]; }
    @catch (__unused NSException *e) { selected = nil; }
    if (!selected || ![selected isKindOfClass:[UIView class]]) return NO;

    NSInteger count = 1;
    id ds = nil;
    @try { ds = [collectionView valueForKey:@"dataSource"]; }
    @catch (__unused NSException *e) { ds = nil; }
    if (ds && [ds respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
        @try { count = [ds collectionView:collectionView numberOfItemsInSection:0]; }
        @catch (__unused NSException *e) { count = 1; }
    }
    NSInteger selectedIndex = 0;
    @try { selectedIndex = [(NSIndexPath *)indexPath item]; }
    @catch (__unused NSException *e) { selectedIndex = 0; }

    NSMutableArray *urls = [NSMutableArray array];
    NSMutableArray *images = [NSMutableArray array];
    for (NSInteger i = 0; i < count; i++) {
        id cell = nil;
        @try {
            cell = [collectionView cellForItemAtIndexPath:
                    [NSIndexPath indexPathForItem:i inSection:0]];
        } @catch (__unused NSException *e) { cell = nil; }
        if (!cell) cell = (i == selectedIndex) ? selected : nil;
        UIView *root = nil;
        UIImageView *iv = cell ? HushPrivacyBestImageView((UIView *)cell, &root) : nil;
        NSURL *url = HushPrivacyOriginalURLFromCell(cell);
        if (!url) url = HushPrivacyImageURL(iv);
        [urls addObject:(url ?: (id)[NSNull null])];
        [images addObject:(iv.image ?: (id)[NSNull null])];
    }

    HushPrivacyPhotoViewer *viewer = [[HushPrivacyPhotoViewer alloc] init];
    viewer.urls = urls;
    viewer.fallbackImages = images;
    viewer.currentIndex = selectedIndex;
    UIView *root = nil;
    UIImageView *iv = HushPrivacyBestImageView((UIView *)selected, &root);
    viewer.initialImage = iv.image;

    UIViewController *top = HushVisibleTopViewController();
    if (!top) return NO;
    viewer.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:viewer animated:YES completion:nil];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][隐私相册] 打开原图画廊 cell=%@ index=%ld/%ld",
        NSStringFromClass([selected class]), (long)selectedIndex + 1, (long)count]];
    return YES;
}
