//
//  HushLocationPickerController.m
//  还原 BluedHush_5.19 的「选择位置」页（0_IMG_1275 那张）
//
//  版式对齐原版：
//    导航栏  左「收藏」  中「选择位置」  右「取消」
//    搜索框  「搜索地址或地点」
//    分段    「输入位置 | 输入海拔 | 历史记录 | 收藏夹」
//    地图    MKMapView + 居中大头针
//    信息卡  「位置: lat, lng / 海拔: x 米 / 地址」
//    底部    「位置模拟」开关  「海拔模拟」开关  「确认位置」大按钮
//    提示    「拖动地图或拖动大头针选定位置…」
//
//  确认后写入 HushConfig 的 runtime_custom_lat / lng / altitude /
//  runtime_loc_name / runtime_loc_address，并打开 switch_location_sim。
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushRuntime.h"
#import "HushLocationPickerController.h"
#import "HushLocationHistoryController.h"

static NSString *const kHushLocHistoryKey   = @"hush_loc_history";
static NSString *const kHushLocFavoritesKey = @"hush_loc_favorites";

@interface HushLocationPickerController () <MKMapViewDelegate, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *savedResults;
@end

@implementation HushLocationPickerController

#pragma mark - 生命周期

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _savedResults = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"选择位置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"收藏" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actFavListPage)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actClose)];

    [self hushBuildMap];
    [self hushBuildSearchBar];
    [self hushBuildActionControl];
    [self hushBuildInfoCard];
    [self hushBuildResultTable];
    [self hushBuildBottomBar];

    [self hushLocInitialAim];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _everAppeared = YES;
    [self hushLocRecenterCheck];
}

- (void)dealloc {
    _map.delegate = nil;
    _searchBar.delegate = nil;
    _resultTable.dataSource = nil;
    _resultTable.delegate = nil;
}

#pragma mark - 建视图

- (void)hushBuildMap {
    _map = [[MKMapView alloc] initWithFrame:CGRectZero];
    _map.delegate = self;
    _map.showsUserLocation = NO;
    _map.showsCompass = YES;
    _map.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAll];
    _map.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_map];

    [NSLayoutConstraint activateConstraints:@[
        [_map.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // 居中大头针：做成图片视图，随地图平移到中心
    UIImage *pin = [UIImage systemImageNamed:@"mappin.circle.fill"];
    _centerPin = [[UIImageView alloc] initWithImage:pin];
    _centerPin.tintColor = [UIColor systemRedColor];
    _centerPin.contentMode = UIViewContentModeScaleAspectFit;
    _centerPin.translatesAutoresizingMaskIntoConstraints = NO;
    _centerPin.userInteractionEnabled = NO;
    [self.view addSubview:_centerPin];
    [NSLayoutConstraint activateConstraints:@[
        [_centerPin.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_centerPin.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_centerPin.widthAnchor constraintEqualToConstant:34],
        [_centerPin.heightAnchor constraintEqualToConstant:34],
    ]];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hushLocMapLongPress:)];
    lp.minimumPressDuration = 0.5;
    [_map addGestureRecognizer:lp];
}

- (void)hushBuildSearchBar {
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.placeholder = @"搜索地址或地点";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_searchBar];
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_searchBar.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)hushBuildActionControl {
    _actionControl = [[UISegmentedControl alloc] initWithItems:@[@"输入位置", @"输入海拔", @"历史记录", @"收藏夹"]];
    _actionControl.selectedSegmentIndex = 0;
    [_actionControl addTarget:self action:@selector(hushLocActionSegment:) forControlEvents:UIControlEventValueChanged];
    _actionControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_actionControl];
    [NSLayoutConstraint activateConstraints:@[
        [_actionControl.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:4],
        [_actionControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_actionControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_actionControl.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)hushBuildInfoCard {
    _infoCard = [[UIView alloc] initWithFrame:CGRectZero];
    _infoCard.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.92];
    _infoCard.layer.cornerRadius = 10.0;
    _infoCard.layer.masksToBounds = YES;
    _infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_infoCard];

    _coordLabel = [self hushLocLabelWithSize:15.0 weight:UIFontWeightSemibold color:[UIColor labelColor]];
    _altitudeLabel = [self hushLocLabelWithSize:11.0 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]];
    _addrLabel = [self hushLocLabelWithSize:11.0 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]];
    _addrLabel.numberOfLines = 2;

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[_coordLabel, _altitudeLabel, _addrLabel]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 2.0;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [_infoCard addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:_infoCard.topAnchor constant:10],
        [st.bottomAnchor constraintEqualToAnchor:_infoCard.bottomAnchor constant:-10],
        [st.leadingAnchor constraintEqualToAnchor:_infoCard.leadingAnchor constant:12],
        [st.trailingAnchor constraintEqualToAnchor:_infoCard.trailingAnchor constant:-12],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [_infoCard.topAnchor constraintEqualToAnchor:_actionControl.bottomAnchor constant:8],
        [_infoCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_infoCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
}

- (UILabel *)hushLocLabelWithSize:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = c;
    return l;
}

- (void)hushBuildResultTable {
    _resultTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _resultTable.dataSource = self;
    _resultTable.delegate = self;
    _resultTable.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.96];
    _resultTable.layer.cornerRadius = 10.0;
    _resultTable.hidden = YES;
    _resultTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_resultTable];
    _resultHeight = [_resultTable.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        _resultHeight,
        [_resultTable.topAnchor constraintEqualToAnchor:_infoCard.bottomAnchor constant:6],
        [_resultTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_resultTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
}

- (void)hushBuildBottomBar {
    UISwitch *loc = [[UISwitch alloc] init];
    loc.onTintColor = [UIColor systemGreenColor];
    loc.on = [[HushConfig shared] isEnabled:@"switch_location_sim"];
    [loc addTarget:self action:@selector(hushLocSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    _locationSwitch = loc;

    UISwitch *alt = [[UISwitch alloc] init];
    alt.onTintColor = [UIColor systemGreenColor];
    alt.on = [[HushConfig shared] isEnabled:@"switch_altitude_sim"];
    [alt addTarget:self action:@selector(hushLocSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    _altitudeSwitch = alt;

    UIView *locItem = [self hushLocSwitchItemWithIcon:@"location.fill" title:@"位置模拟" control:loc];
    UIView *altItem = [self hushLocSwitchItemWithIcon:@"arrow.up.and.down" title:@"海拔模拟" control:alt];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[locItem, altItem]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8.0;

    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_confirmButton setTitle:@"确认位置" forState:UIControlStateNormal];
    [_confirmButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _confirmButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _confirmButton.backgroundColor = [UIColor systemBlueColor];
    _confirmButton.layer.cornerRadius = 22.0;
    [_confirmButton addTarget:self action:@selector(actConfirm) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [self hushLocLabelWithSize:10.5 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]];
    hint.text = @"拖动地图或拖动大头针选定位置（蓝点=所选点，打开「位置模拟」即按它生效）；点击「确认位置」存进历史";
    hint.numberOfLines = 2;
    hint.textAlignment = NSTextAlignmentCenter;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[row, hint, _confirmButton]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 8.0;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.94];
    [self.view addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [col.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [_confirmButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (UIView *)hushLocSwitchItemWithIcon:(NSString *)symbol title:(NSString *)title control:(UISwitch *)sw {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = [UIColor systemBlueColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:16].active = YES;
    [icon.heightAnchor constraintEqualToConstant:16].active = YES;

    UILabel *lab = [self hushLocLabelWithSize:12.5 weight:UIFontWeightMedium color:[UIColor labelColor]];
    lab.text = title;

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[icon, lab, sw]];
    st.axis = UILayoutConstraintAxisHorizontal;
    st.spacing = 6.0;
    st.alignment = UIStackViewAlignmentCenter;
    return st;
}

#pragma mark - 初始定位 / 刷新

- (CLLocationCoordinate2D)hushLocEffectiveCoord {
    HushConfig *cfg = [HushConfig shared];
    if ([cfg hasCustomLocation]) {
        CLLocationCoordinate2D c;
        c.latitude = [cfg customLat];
        c.longitude = [cfg customLng];
        if (CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0.0 && c.longitude == 0.0)) return c;
    }
    _map.showsUserLocation = YES;
    return _map.userLocation.coordinate;
}

- (void)hushLocInitialAim {
    HushConfig *cfg = [HushConfig shared];
    if ([cfg hasCustomLocation]) {
        [self moveTo:[self hushLocEffectiveCoord] spanMeters:600 animated:NO];
        _didInitialAim = YES;
    } else {
        CLLocationManager *lm = [[CLLocationManager alloc] init];
        _authAsker = lm;
        [lm requestWhenInUseAuthorization];
    }
}

- (void)hushLocRecenterCheck {
    if (_didInitialAim) return;
    CLLocationCoordinate2D c = [self hushLocEffectiveCoord];
    if (CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0.0 && c.longitude == 0.0)) {
        [self moveTo:c spanMeters:600 animated:NO];
        _didInitialAim = YES;
    } else {
        [self hushLocScheduleRecenter:0.6];
    }
}

- (void)hushLocScheduleRecenter:(double)delay {
    if (_didInitialAim || delay <= 0) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2->_didInitialAim) return;
        [self2 hushLocRecenterCheck];
    });
}

- (void)moveTo:(CLLocationCoordinate2D)c spanMeters:(double)span animated:(BOOL)animated {
    if (!CLLocationCoordinate2DIsValid(c)) return;
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(c, span, span);
    [_map setRegion:r animated:animated];
    _lastAimCoord = c;
    _hasAimCoord = YES;
    [self refreshCenter:c];
}

- (void)refreshCenter:(CLLocationCoordinate2D)c {
    if (!CLLocationCoordinate2DIsValid(c)) return;
    if (!_pickAnno) {
        _pickAnno = [[MKPointAnnotation alloc] init];
        [_map addAnnotation:_pickAnno];
    }
    _pickAnno.coordinate = c;

    HushConfig *cfg = [HushConfig shared];
    double alt = [cfg isEnabled:@"switch_altitude_sim"] ? [cfg customAltitude] : 0.0;
    _coordLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f", c.latitude, c.longitude];
    _altitudeLabel.text = [NSString stringWithFormat:@"海拔: %.2f米", alt];

    NSString *saved = [cfg stringForKey:@"runtime_loc_address"];
    if (saved.length > 0 && _lastAimCoord.latitude == c.latitude && _lastAimCoord.longitude == c.longitude) {
        _addrLabel.text = saved;
        return;
    }
    [self hushLocReverseGeocode:c];
}

- (void)hushLocReverseGeocode:(CLLocationCoordinate2D)c {
    _addrLabel.text = @"解析地址中…";
    int token = ++_addrToken;
    CLGeocoder *gc = [[CLGeocoder alloc] init];
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    __weak typeof(self) weakSelf = self;
    [gc reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || token != self2->_addrToken) return;
        CLPlacemark *p = marks.firstObject;
        if (p) {
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *s in @[p.country ?: @"", p.administrativeArea ?: @"", p.locality ?: @"",
                                  p.subLocality ?: @"", p.thoroughfare ?: @"", p.name ?: @""]) {
                if (s.length && ![parts containsObject:s]) [parts addObject:s];
            }
            NSString *line = [parts componentsJoinedByString:@""];
            self2->_centerAddr = line;
            self2->_addrLabel.text = line.length ? line : @"（未取到地址）";
        } else {
            self2->_addrLabel.text = @"（未取到地址）";
        }
    }];
}

#pragma mark - 地图回调

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    if (![self hushLocRegionChangeIsUserDriven:animated]) return;
    _userTouched = YES;
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    CLLocationCoordinate2D c = mapView.centerCoordinate;
    if (_userTouched) {
        [self hushLocPinLift:YES];
        _hasAimCoord = YES;
    }
    [self refreshCenter:c];
}

- (BOOL)hushLocRegionChangeIsUserDriven:(BOOL)animated {
    return !_suppressSearch;
}

- (void)hushLocPinLift:(BOOL)lift {
    CGFloat dy = lift ? -22.0 : 0.0;
    [UIView animateWithDuration:0.18 animations:^{
        self->_centerPin.transform = CGAffineTransformMakeTranslation(0, dy);
    }];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)anno {
    if ([anno isKindOfClass:[MKUserLocation class]]) return nil;
    static NSString *reuse = @"hush_pick_anno";
    MKMarkerAnnotationView *v = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:reuse];
    if (!v) {
        v = [[MKMarkerAnnotationView alloc] initWithAnnotation:anno reuseIdentifier:reuse];
        v.canShowCallout = NO;
    }
    v.markerTintColor = [UIColor systemRedColor];
    v.annotation = anno;
    return v;
}

- (void)mapView:(MKMapView *)mapView didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views {
    for (MKAnnotationView *v in views) {
        if ([v.annotation isKindOfClass:[MKUserLocation class]]) continue;
        v.hidden = YES;   // 居中大头针已经代表选点，避免双针
    }
}

- (void)hushLocMapLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [g locationInView:_map];
    CLLocationCoordinate2D c = [_map convertPoint:pt toCoordinateFromView:_map];
    [self hushLocPlacePickAt:c];
    _userTouched = YES;
}

- (void)hushLocPlacePickAt:(CLLocationCoordinate2D)c {
    if (!CLLocationCoordinate2DIsValid(c)) return;
    [self moveTo:c spanMeters:400 animated:YES];
}

#pragma mark - 搜索

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    if (text.length < 2) { [self clearSearchResults]; return; }
    [self runSearch:text];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
    if (sb.text.length) [self runSearch:sb.text];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = @"";
    [sb resignFirstResponder];
    [self clearSearchResults];
}

- (void)runSearch:(NSString *)q {
    int token = ++_searchToken;
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery = q;
    req.region = _map.region;
    _search = [[MKLocalSearch alloc] initWithRequest:req];

    __weak typeof(self) weakSelf = self;
    [_search startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || token != self2->_searchToken) return;
        NSMutableArray *rows = [NSMutableArray array];
        for (MKMapItem *item in resp.mapItems) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"name"] = item.name ?: @"";
            d[@"lat"] = @(item.placemark.coordinate.latitude);
            d[@"lng"] = @(item.placemark.coordinate.longitude);
            NSString *addr = item.placemark.title ?: @"";
            d[@"addr"] = addr;
            [rows addObject:d];
            if (rows.count >= 20) break;
        }
        self2->_results = rows;
        [self2->_resultTable reloadData];
        self2->_resultTable.hidden = (rows.count == 0);
        [self2->_resultHeight setActive:NO];
        self2->_resultHeight = [self2->_resultTable.heightAnchor constraintEqualToConstant:MIN(44.0 * rows.count, 220.0)];
        self2->_resultHeight.active = YES;
    }];
}

- (void)clearSearchResults {
    _searchToken++;
    _results = @[];
    [_resultTable reloadData];
    _resultTable.hidden = YES;
    [_resultHeight setActive:NO];
    _resultHeight = [_resultTable.heightAnchor constraintEqualToConstant:0];
    _resultHeight.active = YES;
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"hush_loc_result";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *d = _results[ip.row];
    c.textLabel.text = d[@"name"];
    c.detailTextLabel.text = d[@"addr"];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = _results[ip.row];
    CLLocationCoordinate2D c;
    c.latitude = [d[@"lat"] doubleValue];
    c.longitude = [d[@"lng"] doubleValue];
    _nameHint = d[@"name"];
    _nameHintCoord = c;
    [self hushLocPlacePickAt:c];
    [self clearSearchResults];
    _searchBar.text = @"";
}

#pragma mark - 分段 / 开关

- (void)hushLocActionSegment:(UISegmentedControl *)sc {
    switch (sc.selectedSegmentIndex) {
        case 0: [self actInputCoord]; break;
        case 1: [self actInputAltitude]; break;
        case 2: [self actHistory]; break;
        case 3: [self actFavListPage]; break;
        default: break;
    }
    sc.selectedSegmentIndex = 0;
}

- (void)hushLocSwitchChanged:(UISwitch *)sw {
    HushConfig *cfg = [HushConfig shared];
    if (sw == _locationSwitch) {
        [cfg setEnabled:sw.isOn forKey:@"switch_location_sim"];
        if (sw.isOn) [cfg setEnabled:YES forKey:@"switch_virtual_location"];
    } else if (sw == _altitudeSwitch) {
        [cfg setEnabled:sw.isOn forKey:@"switch_altitude_sim"];
    }
}

- (void)hushLocToggleMapType {
    _map.mapType = (_map.mapType == MKMapTypeStandard) ? MKMapTypeHybrid : MKMapTypeStandard;
}

#pragma mark - 动作

- (void)actInputCoord {
    CLLocationCoordinate2D c = _map.centerCoordinate;
    NSString *def = [NSString stringWithFormat:@"%.4f,%.4f", c.latitude, c.longitude];
    [self hushLocAlert:@"输入位置" msg:@"格式：纬度,经度（如 34.8006,114.3102）" def:def on:^(NSString *text) {
        NSArray *parts = [text componentsSeparatedByString:@","];
        if (parts.count < 2) { [self hushLocAlert:@"格式不对" msg:@"请用 纬度,经度" def:text on:nil]; return; }
        CLLocationCoordinate2D nc;
        nc.latitude = [parts[0] doubleValue];
        nc.longitude = [parts[1] doubleValue];
        if (!CLLocationCoordinate2DIsValid(nc)) { [self hushLocAlert:@"坐标非法" msg:@"超出经纬度范围" def:text on:nil]; return; }
        [self hushLocPlacePickAt:nc];
    }];
}

- (void)actInputAltitude {
    double cur = [[HushConfig shared] customAltitude];
    [self hushLocAlert:@"输入海拔" msg:@"单位米" def:[NSString stringWithFormat:@"%.2f", cur] on:^(NSString *text) {
        [[HushConfig shared] setCustomAltitude:[text doubleValue]];
        [self refreshCenter:self->_map.centerCoordinate];
    }];
}

- (void)actHistory {
    Class cls = NSClassFromString(@"HushLocationHistoryController");
    if (!cls) return;
    UIViewController *vc = [(HushLocationHistoryController *)[cls alloc] initWithMode:0];
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

- (void)actFavListPage {
    Class cls = NSClassFromString(@"HushLocationHistoryController");
    if (!cls) return;
    UIViewController *vc = [(HushLocationHistoryController *)[cls alloc] initWithMode:1];
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

- (void)actAddFav {
    CLLocationCoordinate2D c = _map.centerCoordinate;
    [self hushLocSaveTo:kHushLocFavoritesKey coord:c name:_nameHint addr:_centerAddr];
    [self hushLocAlert:@"已收藏" msg:_centerAddr ?: @"已加入收藏夹" def:nil on:nil];
}

- (void)actClose {
    if (self.navigationController.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)actConfirm {
    CLLocationCoordinate2D c = _map.centerCoordinate;
    if (!CLLocationCoordinate2DIsValid(c)) {
        [self hushLocAlert:@"选点无效" msg:@"请拖动地图重新选点" def:nil on:nil];
        return;
    }
    _confirming = YES;

    HushConfig *cfg = [HushConfig shared];
    [cfg setCustomLat:c.latitude lng:c.longitude];
    NSString *addr = _centerAddr.length ? _centerAddr : _addrLabel.text;
    if (addr.length) [cfg setString:addr forKey:@"runtime_loc_address"];
    if (_nameHint.length) [cfg setString:_nameHint forKey:@"runtime_loc_name"];
    [cfg setEnabled:_locationSwitch.isOn forKey:@"switch_location_sim"];
    [cfg setEnabled:_altitudeSwitch.isOn forKey:@"switch_altitude_sim"];
    if (_locationSwitch.isOn) [cfg setEnabled:YES forKey:@"switch_virtual_location"];

    [self hushLocSaveTo:kHushLocHistoryKey coord:c name:_nameHint addr:addr];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"HushLocationDidChangeNotification" object:nil];
    [HushLogger logLevel:3 format:[NSString stringWithFormat:@"[Loc] 确认位置 %.6f,%.6f", c.latitude, c.longitude]];

    [self actClose];
}

#pragma mark - 历史 / 收藏

- (NSArray<NSDictionary *> *)hushItemsForKey:(NSString *)key {
    NSString *json = [[HushConfig shared] stringForKey:key];
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    return [o isKindOfClass:[NSArray class]] ? o : @[];
}

- (void)hushLocSaveTo:(NSString *)key coord:(CLLocationCoordinate2D)c name:(NSString *)name addr:(NSString *)addr {
    NSMutableArray *arr = [[self hushItemsForKey:key] mutableCopy] ?: [NSMutableArray array];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"lat"] = @(c.latitude);
    d[@"lng"] = @(c.longitude);
    d[@"name"] = name ?: @"";
    d[@"addr"] = addr ?: @"";
    d[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    [arr insertObject:d atIndex:0];
    while (arr.count > 30) [arr removeLastObject];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
    if (jd) [[HushConfig shared] setString:[[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] forKey:key];
}

#pragma mark - 弹窗

- (void)hushLocAlert:(NSString *)title msg:(NSString *)msg def:(NSString *)def on:(void (^)(NSString *))on {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (on) {
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = def; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            on(ac.textFields.firstObject.text ?: @"");
        }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    }
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)hushLocAlertPresent:(NSString *)title msg:(NSString *)msg on:(void (^)(void))on {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (on) on();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)hushLocCheckLocationAuthorization {
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied) {
        [self hushLocAlertPresent:@"定位未授权" msg:@"请在系统设置里允许 Blued 使用位置" on:nil];
    }
}

- (void)hushLocAdoptTarget:(CLLocationCoordinate2D)c name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(c)) return;
    _nameHint = name;
    [self hushLocPlacePickAt:c];
}

- (void)hushLocClearPick {
    if (_pickAnno) { [_map removeAnnotation:_pickAnno]; _pickAnno = nil; }
    _hasAimCoord = NO;
}

- (void)hushLocCurrentTargetLat:(double)lat lng:(double)lng {
    HushConfig *cfg = [HushConfig shared];
    [cfg setCustomLat:lat lng:lng];
}

- (void)hushLocAimIfPossible {
    if (_hasAimCoord) return;
    CLLocationCoordinate2D c = [self hushLocEffectiveCoord];
    if (CLLocationCoordinate2DIsValid(c)) [self hushLocPlacePickAt:c];
}

- (void)dropNameHintIfFar {
    if (!_nameHint) return;
    CLLocation *a = [[CLLocation alloc] initWithLatitude:_nameHintCoord.latitude longitude:_nameHintCoord.longitude];
    CLLocation *b = [[CLLocation alloc] initWithLatitude:_map.centerCoordinate.latitude longitude:_map.centerCoordinate.longitude];
    if (a && b && [a distanceFromLocation:b] > 3000.0) {
        _nameHint = nil;
        _nameHintCoord = kCLLocationCoordinate2DInvalid;
    }
}

- (void)hushLocHistoryPicked:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return;
    CLLocationCoordinate2D c;
    c.latitude = [d[@"lat"] doubleValue];
    c.longitude = [d[@"lng"] doubleValue];
    _nameHint = d[@"name"];
    _centerAddr = d[@"addr"];
    [self hushLocPlacePickAt:c];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _suppressSearch = YES;
}

@end
