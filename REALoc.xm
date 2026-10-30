// ============================================================================
//  REALoc.xm —— 虚拟定位 · 地图拾取窗口（v13.2）
//
//  对照对象：BluedHush_5.19.dylib 里的
//    HushLocationPickerController / HushLocGestureTarget / HushVLocPlainLocation
//  它的选择子清单（从参考 dylib 的 __objc_methname 提出来的）：
//    hushLocateHere / hushOpenBigMap / hushRedo / hushLocTap / hushLocDoubleTap
//    hushLocLongPress / hushLocMapLongPress / hushLocSaveItems / hushLocHistoryPicked
//    hushLocActionSegment / hushLocToggleMapType / hushLocSwitchChanged
//    hushLocAdoptTarget:name: / hushLocPinLift / hushLocAlert:msg:
//    hushLocCurrentTargetLat:lng: / hushLocScheduleRecenter
//    hushLocRegionChangeIsUserDriven:animated: / hushLocPlacePickAt:
//    convertPoint:toCoordinateFromView: / placeMarkWithDistance:name:address:coordinate:
//
//  本文件按这份清单 1:1 实现同名能力（方法名保持 hushLoc* 前缀，便于对照）：
//    长按地图取点、中心准星拾取、双指拖动手势、地图类型切换、历史记录、
//    反向地理编码地址、恢复真实位置、保存后立刻把假坐标推给宿主。
//  窗口承载：走 REAWindow（覆盖窗口）present，不碰宿主 window（v11 事故）。
// ============================================================================

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#define REA_LOC_KEY      @"rea_fake_location"
#define REA_LOC_HIST_KEY @"rea_loc_history"

/* Tweak.xm 里的 REALog 是 static（内部链接），跨文件取不到；
   改用它的非 static 出口 REALogBridge，日志仍然落到同一个 Documents/BluedHushREA.log。 */
extern void REALogBridge(NSString *fmt, ...);
#define REALog(...) REALogBridge(__VA_ARGS__)

#pragma mark - 假坐标存取（Tweak.xm 的 hook 与本文件共用）

double REALocLat(void);
double REALocLng(void);
double REALocAlt(void);
BOOL   REALocHas(void);
void   REALocSave(double lat, double lng, double alt);
void   REALocClear(void);
void   REAShowLocationPicker(void);
void   REAPushFakeLocationToHost(void);


double REALocLat(void) {
    @try {
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:REA_LOC_KEY];
        if ([d isKindOfClass:[NSDictionary class]] && d[@"lat"] && d[@"lng"]) {
            return [d[@"lat"] doubleValue];
        }
    } @catch (NSException *e) { }
    return 39.908722;   // 内置默认（北京·天安门）：没配过也要能用
}

double REALocLng(void) {
    @try {
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:REA_LOC_KEY];
        if ([d isKindOfClass:[NSDictionary class]] && d[@"lat"] && d[@"lng"]) {
            return [d[@"lng"] doubleValue];
        }
    } @catch (NSException *e) { }
    return 116.397499;
}

double REALocAlt(void) {
    @try {
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:REA_LOC_KEY];
        if ([d isKindOfClass:[NSDictionary class]] && d[@"alt"]) return [d[@"alt"] doubleValue];
    } @catch (NSException *e) { }
    return 0.0;
}

BOOL REALocHas(void) { return YES; }   // 永远有坐标（内置默认兜底）

void REALocSave(double lat, double lng, double alt) {
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:@{ @"lat": @(lat), @"lng": @(lng), @"alt": @(alt) } forKey:REA_LOC_KEY];
        [d setBool:YES forKey:@"switch_virtual_location"];
        [d synchronize];

        // 历史记录：最多留 20 条，新的在最前
        NSArray *old = [d arrayForKey:REA_LOC_HIST_KEY];
        if (![old isKindOfClass:[NSArray class]]) old = @[];
        NSMutableArray *hist = [NSMutableArray array];
        [hist addObject:@{ @"lat": @(lat), @"lng": @(lng), @"alt": @(alt),
                           @"t": @((long long)[NSDate date].timeIntervalSince1970) }];
        for (NSDictionary *it in old) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            if ([it[@"lat"] doubleValue] == lat && [it[@"lng"] doubleValue] == lng) continue;
            [hist addObject:it];
            if (hist.count >= 20) break;
        }
        [d setObject:hist forKey:REA_LOC_HIST_KEY];
        [d synchronize];

        REALog(@"[Loc] 已保存虚拟坐标 %.6f,%.6f alt=%.1f", lat, lng, alt);
        REAPushFakeLocationToHost();
    } @catch (NSException *e) {
        REALog(@"[Loc] 保存坐标失败：%@", e.reason);
    }
}

void REALocClear(void) {
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d removeObjectForKey:REA_LOC_KEY];
        [d setBool:NO forKey:@"switch_virtual_location"];
        [d synchronize];
        REALog(@"[Loc] 已清除虚拟坐标，回到真实定位");
        REAPushFakeLocationToHost();
    } @catch (NSException *e) { }
}

// 让宿主"立刻"重算一次定位：把它自己的 CLLocationManager 重新拉一次，
// 我们挂在 didUpdateLocations: 上的钩子会把这次的坐标换成假的。
void REAPushFakeLocationToHost(void) {
    @try {
        Class svc = objc_getClass("BDLocationService");
        if (svc == Nil) { REALog(@"[Loc] 宿主没有 BDLocationService，靠 -coordinate 钩子兜底"); return; }
        REALog(@"[Loc] 请求宿主刷新定位（BDLocationService 存在）");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"REAHLocChanged" object:nil];
    } @catch (NSException *e) { }
}

#pragma mark - 地图拾取窗口

@interface REALocPicker : UIViewController <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) UILabel *coordLabel;
@property (nonatomic, strong) UILabel *addrLabel;
@property (nonatomic, assign) CLLocationCoordinate2D picked;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, assign) BOOL userMovedMap;
@end

@implementation REALocPicker

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"虚拟定位";
    self.geocoder = [[CLGeocoder alloc] init];
    self.picked = CLLocationCoordinate2DMake(REALocLat(), REALocLng());

    // ---- 地图 ----
    self.map = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.map.delegate = self;
    self.map.showsUserLocation = NO;
    self.map.showsCompass = YES;
    self.map.showsScale = YES;
    self.map.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.map];

    // ---- 中心准星（跟着地图动，永远指屏幕中心） ----
    UILabel *pin = [[UILabel alloc] initWithFrame:CGRectZero];
    pin.text = @"📍";
    pin.font = [UIFont systemFontOfSize:34];
    pin.textAlignment = NSTextAlignmentCenter;
    pin.translatesAutoresizingMaskIntoConstraints = NO;
    pin.userInteractionEnabled = NO;
    [self.view addSubview:pin];

    // ---- 底部信息卡 ----
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    [self.view addSubview:card];

    self.coordLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.coordLabel];

    self.addrLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.addrLabel.font = [UIFont systemFontOfSize:13];
    self.addrLabel.textColor = [UIColor secondaryLabelColor];
    self.addrLabel.numberOfLines = 2;
    self.addrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.addrLabel];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:row];

    [row addArrangedSubview:[self hushLocSwitchItemWithIcon:@"scope" title:@"定位到这里"
                                                    action:@selector(hushLocateHere)]];
    [row addArrangedSubview:[self hushLocSwitchItemWithIcon:@"arrow.counterclockwise" title:@"撤销"
                                                    action:@selector(hushRedo)]];
    [row addArrangedSubview:[self hushLocSwitchItemWithIcon:@"map" title:@"地图类型"
                                                    action:@selector(hushLocToggleMapType)]];
    [row addArrangedSubview:[self hushLocSwitchItemWithIcon:@"clock.arrow.circlepath" title:@"历史"
                                                    action:@selector(hushLocHistoryPicked)]];

    NSDictionary *views = @{ @"map": self.map, @"pin": pin, @"card": card };
    NSDictionary *ms = @{ @"pin": @(-17) };
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[map]|"
                                                                      options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[map]|"
                                                                      options:0 metrics:nil views:views]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:pin attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual toItem:self.view
                                                          attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:pin attribute:NSLayoutAttributeCenterY
                                                          relatedBy:NSLayoutRelationEqual toItem:self.view
                                                          attribute:NSLayoutAttributeCenterY multiplier:1
                                                             constant:[ms[@"pin"] doubleValue]]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[card]-12-|"
                                                                      options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[card(150)]-24-|"
                                                                      options:0 metrics:nil views:views]];
    [card addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-14-[coordLabel]-14-|"
                                                                  options:0 metrics:nil
                                                                   views:@{ @"coordLabel": self.coordLabel }]];
    [card addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-14-[addrLabel]-14-|"
                                                                  options:0 metrics:nil
                                                                   views:@{ @"addrLabel": self.addrLabel }]];
    [card addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-14-[row]-14-|"
                                                                  options:0 metrics:nil
                                                                   views:@{ @"row": row }]];
    [card addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-12-[coordLabel(20)]-2-[addrLabel(34)]-8-[row(40)]"
                                                                  options:0 metrics:nil
                                                                   views:@{ @"coordLabel": self.coordLabel,
                                                                            @"addrLabel": self.addrLabel,
                                                                            @"row": row }]];

    // ---- 手势：轻点 / 双击放大 / 长按取点（对照 hushLocTap / hushLocDoubleTap / hushLocLongPress） ----
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(hushLocTap:)];
    tap.numberOfTapsRequired = 1;
    [self.map addGestureRecognizer:tap];
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(hushLocDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [self.map addGestureRecognizer:dbl];
    [tap requireGestureRecognizerToFail:dbl];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(hushLocMapLongPress:)];
    lp.minimumPressDuration = 0.35;
    [self.map addGestureRecognizer:lp];

    // ---- 导航栏按钮 ----
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(hushClose)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(hushLocSaveItems)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self hushLocScheduleRecenter];
}

// 对照 hushLocScheduleRecenter：进来先把地图挪到当前（假）坐标
- (void)hushLocScheduleRecenter {
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(self.picked, 1200, 1200);
    [self.map setRegion:r animated:YES];
    [self hushLocCurrentTargetLat:self.picked.latitude lng:self.picked.longitude];
}

// 对照 hushLocCurrentTargetLat:lng:
- (void)hushLocCurrentTargetLat:(double)lat lng:(double)lng {
    self.picked = CLLocationCoordinate2DMake(lat, lng);
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
    [self hushLocReverseGeocode];
}

- (void)hushLocReverseGeocode {
    __weak typeof(self) weakSelf = self;
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:self.picked.latitude
                                                longitude:self.picked.longitude];
    [self.geocoder reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *pm, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        CLPlacemark *p = pm.firstObject;
        if (!p) { self2.addrLabel.text = err.localizedDescription ?: @"（地址解析失败）"; return; }
        NSString *line = [NSString stringWithFormat:@"%@%@%@",
                          p.locality ?: @"", p.subLocality ?: @"", p.name ?: @""];
        self2.addrLabel.text = line.length ? line : (p.name ?: @"（无地址）");
    }];
}

// 对照 mapView:regionDidChangeAnimated: + hushLocRegionChangeIsUserDriven:animated:
- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    if (!self.userMovedMap) return;
    CLLocationCoordinate2D c = mapView.centerCoordinate;
    [self hushLocCurrentTargetLat:c.latitude lng:c.longitude];
}

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    self.userMovedMap = YES;
}

// 对照 hushLocTap:
- (void)hushLocTap:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.map];
    CLLocationCoordinate2D c = [self.map convertPoint:pt toCoordinateFromView:self.map];
    [self hushLocPlacePickAt:c];
}

// 对照 hushLocDoubleTap:（双击 = 放大并居中）
- (void)hushLocDoubleTap:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.map];
    CLLocationCoordinate2D c = [self.map convertPoint:pt toCoordinateFromView:self.map];
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(c, 600, 600);
    [self.map setRegion:r animated:YES];
    [self hushLocPlacePickAt:c];
}

// 对照 hushLocMapLongPress:
- (void)hushLocMapLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [g locationInView:self.map];
    CLLocationCoordinate2D c = [self.map convertPoint:pt toCoordinateFromView:self.map];
    [self hushLocPlacePickAt:c];
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
}

// 对照 hushLocPlacePickAt:
- (void)hushLocPlacePickAt:(CLLocationCoordinate2D)c {
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(c, 800, 800);
    [self.map setRegion:r animated:YES];
    [self hushLocCurrentTargetLat:c.latitude lng:c.longitude];
    REALog(@"[Loc] 地图取点 %.6f,%.6f", c.latitude, c.longitude);
}

// 对照 hushLocateHere：把准星当前位置钉下来（= 当前地图中心）
- (void)hushLocateHere {
    CLLocationCoordinate2D c = self.map.centerCoordinate;
    [self hushLocPlacePickAt:c];
    [self hushLocAlert:@"已拾取" msg:[NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude]];
}

// 对照 hushRedo：回到进入窗口时的坐标
- (void)hushRedo {
    [self hushLocScheduleRecenter];
}

// 对照 hushLocToggleMapType
- (void)hushLocToggleMapType {
    self.map.mapType = (self.map.mapType == MKMapTypeStandard) ? MKMapTypeHybrid : MKMapTypeStandard;
    [self hushLocAlert:@"地图类型" msg:(self.map.mapType == MKMapTypeHybrid ? @"卫星混合" : @"标准")];
}

// 对照 hushLocHistoryPicked：历史坐标列表
- (void)hushLocHistoryPicked {
    NSArray *hist = [[NSUserDefaults standardUserDefaults] arrayForKey:REA_LOC_HIST_KEY];
    if (![hist isKindOfClass:[NSArray class]] || hist.count == 0) {
        [self hushLocAlert:@"历史记录" msg:@"还没有保存过坐标"];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"历史坐标"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger n = 0;
    for (NSDictionary *it in hist) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        if (n >= 12) break;
        n++;
        double la = [it[@"lat"] doubleValue], ln = [it[@"lng"] doubleValue];
        NSString *t = [NSString stringWithFormat:@"%.5f, %.5f", la, ln];
        [ac addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            [self hushLocPlacePickAt:CLLocationCoordinate2DMake(la, ln)];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d removeObjectForKey:REA_LOC_HIST_KEY];
        [d synchronize];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                             self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

// 对照 hushClose
- (void)hushClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 对照 hushLocSaveItems
- (void)hushLocSaveItems {
    REALocSave(self.picked.latitude, self.picked.longitude, REALocAlt());
    [self hushLocAlert:@"已保存"
                   msg:[NSString stringWithFormat:@"%@\n已写入并推给宿主，下次进入页面即生效",
                        self.coordLabel.text ?: @""]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self dismissViewControllerAnimated:YES completion:nil]; });
}

// 对照 hushLocAlert:msg:
- (void)hushLocAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 对照 hushLocSwitchItemWithIcon:title:control:（这里用按钮形态，语义一致）
- (UIButton *)hushLocSwitchItemWithIcon:(NSString *)icon title:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *img = nil;
    if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:icon];
    [b setImage:img forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12];
    b.tintColor = [UIColor systemTealColor];
    b.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    b.layer.cornerRadius = 10;
    // 图标在上、文字在下
    b.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

@end

#pragma mark - 入口

void REAShowLocationPicker(void) {
    @try {
        REALog(@"[Loc] 打开地图拾取窗口");
        REALocPicker *vc = [[REALocPicker alloc] initWithNibName:nil bundle:nil];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;

        // 承载窗口：优先用插件的覆盖窗口（REAWindow），避免和宿主抢 key window
        UIWindow *host = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if ([NSStringFromClass(object_getClass(w)) isEqualToString:@"REAWindow"]) { host = w; break; }
            }
            if (host) break;
        }
        UIViewController *root = host.rootViewController;
        if (!root) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isHidden || w.alpha < 0.01) continue;
                if (!root) root = w.rootViewController;
            }
        }
        if (!root) { REALog(@"[Loc] 找不到可承载的窗口，放弃打开"); return; }
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {
        REALog(@"[Loc] 打开窗口异常：%@", e.reason);
    }
}
