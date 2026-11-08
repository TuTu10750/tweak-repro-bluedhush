#import "HushTrackMapCardVC.h"
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushTracking.h"
#import "HushVirtualLocation.h"

static NSString *const kHushTrackLocationChangedNotification =
    @"HushLocationDidChangeNotification";

@implementation HushTrackMapCardVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(22, 18, 220, 28)];
    title.text = @"对方位置";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 78, 12, 66, 34);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(hushClose:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    CGFloat mapY = 54.0;
    CGFloat actionH = 56.0;
    _map = [[MKMapView alloc] initWithFrame:CGRectMake(0, mapY,
                                                       self.view.bounds.size.width,
                                                       self.view.bounds.size.height - mapY - actionH)];
    _map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _map.delegate = self;
    [self.view addSubview:_map];

    _chipLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, mapY + 10,
                                                           self.view.bounds.size.width - 28, 34)];
    _chipLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _chipLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    _chipLabel.textColor = [UIColor darkTextColor];
    _chipLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _chipLabel.textAlignment = NSTextAlignmentCenter;
    _chipLabel.layer.cornerRadius = 17;
    _chipLabel.clipsToBounds = YES;
    [self.view addSubview:_chipLabel];

    NSArray *titles = @[@"定位到此", @"空降地图", @"重新解算"];
    NSArray *actions = @[@"hushLocateHere:", @"hushOpenBigMap:", @"hushRedo:"];
    CGFloat gap = 8.0;
    CGFloat bw = (self.view.bounds.size.width - 40.0) / 3.0;
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * (bw + gap),
                             self.view.bounds.size.height - actionH + 8,
                             bw - gap, 42);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        b.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
        b.layer.cornerRadius = 20;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor darkTextColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [b addTarget:self action:NSSelectorFromString(actions[i])
    forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_anno) {
        _anno = [[MKPointAnnotation alloc] init];
        _anno.coordinate = CLLocationCoordinate2DMake(_lat, _lng);
        _anno.title = @"目标位置";
        [_map addAnnotation:_anno];
    }
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(
        CLLocationCoordinate2DMake(_lat, _lng), 1800, 1800);
    [_map setRegion:r animated:YES];
    double meters = _residual * 1000.0;
    _chipLabel.text = [NSString stringWithFormat:
        @"✓ 精确收敛 · 残差 %.0f 米 · %.6f, %.6f", meters, _lat, _lng];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][追踪] 位置卡片已打开 %.6f,%.6f residual=%.3fkm",
        _lat, _lng, _residual]];
}

- (id)hushChipText {
    return _chipLabel.text ?: @"";
}

- (void)hushClose:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)hushLocateHere:(id)sender {
    HushConfig *cfg = [HushConfig shared];
    [cfg setString:[NSString stringWithFormat:@"%.8f", _lat] forKey:@"runtime_custom_lat"];
    [cfg setString:[NSString stringWithFormat:@"%.8f", _lng] forKey:@"runtime_custom_lng"];
    [cfg setEnabled:YES forKey:@"switch_virtual_location"];
    [cfg setEnabled:YES forKey:@"switch_location_sim"];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:HushVirtualLocationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kHushTrackLocationChangedNotification object:nil];
    HushVirtualLocationKickHost();
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][追踪] 定位到此 %.6f,%.6f", _lat, _lng]];

    UIViewController *source = _sourceViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"已定位到目标坐标"
                                                message:@"是否自动刷新距离列表？"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                               style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"自动刷新"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kHushTrackLocationChangedNotification object:nil];
            HushVirtualLocationKickHost();
        }]];
        [source presentViewController:ac animated:YES completion:nil];
    }];
}

- (void)hushOpenBigMap:(id)sender {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"http://maps.apple.com/?ll=%.8f,%.8f&q=目标位置", _lat, _lng]];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)hushRedo:(id)sender {
    UIViewController *source = _sourceViewController;
    long long uid = [_uid longLongValue];
    [self dismissViewControllerAnimated:YES completion:^{
        if (uid > 0) HushTrackRedoForUid(uid, source);
    }];
}

- (id)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) return nil;
    MKMarkerAnnotationView *v =
        (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:@"hush_track_target"];
    if (!v) {
        v = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                reuseIdentifier:@"hush_track_target"];
    }
    v.annotation = annotation;
    v.markerTintColor = [UIColor redColor];
    v.canShowCallout = YES;
    return v;
}

@end
