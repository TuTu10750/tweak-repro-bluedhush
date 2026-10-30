// ============================================================================
//  REALoc.xm —— 虚拟定位 · 地图选点窗口（v14.0 原版 1:1 复刻）
//
//  权威依据：IPA 内 Payload/Blued.app/Frameworks/BluedHush_5.19.dylib
//  （2,719,216 B，sha256 前缀 67ca70c5c274c2c0）的 __objc_classlist / __objc_methname。
//  提取结论见 docs/ORIGINAL-REVERSE.md。原版这一块的类与方法清单是：
//
//    HushLocationPickerController  48 个实例方法、31 个 ivar（父类 UIViewController）
//    HushLocGestureTarget          3 个类方法（tap / doubleTap / longPress）
//    HushVLocPlainLocation         CLLocation 子类，重写 -coordinate，属性 hushPlainCoord
//    HushLocationHistoryController 14 个方法（历史 / 收藏的列表页）
//
//  本文件按上面的清单**同名同签名**重建，方法体按原版日志里出现过的事实实现：
//    [LocPicker] 长按 → 蓝点落在 %.6f,%.6f（镜头不动；保存以此点为准）
//    [LocPicker] 地图类型 → %@
//    [LocPicker] 选中搜索结果：%@ (%.6f,%.6f)
//    [LocPicker] 搜索地名：… / 搜索无结果：%@（err=%@）
//    [LocPicker] 海拔模拟 → … / 海拔已保存：%.2f 米
//    [LocPicker] 已收藏当前位置：%@（收藏夹共 %lu 条）
//    [LocPicker] 手动输入的位置
//    [LocPicker] 离开搜索点 %.0f 米 → 摘掉地名「%@」
//    [LocPicker] 首次对准 → %.6f,%.6f
//    [LocStatus] 地址反查完成：%@ / 虚拟定位已打开 / 虚拟定位已关闭
//
//  对外只暴露 5 个 C 函数（REAUI.xm 与 Tweak.xm 依赖），其余全部是原版同名 ObjC 类。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

// Tweak.xm 的 REALog 是 static；跨文件走它的非 static 出口
extern void REALogBridge(NSString *fmt, ...);
#define HL(...) REALogBridge(__VA_ARGS__)

// ---- 偏好键（与 Tweak.xm / REAUI.xm 共用同一份，改名会立刻失联）----
#define HL_KEY_LOC      @"rea_fake_location"     // {lat,lng,alt} 当前生效坐标
#define HL_KEY_HIST     @"rea_loc_history"       // [{lat,lng,alt,t,name}] 历史，最多 20
#define HL_KEY_FAV      @"rea_loc_favs"          // [{lat,lng,alt,name}] 收藏
#define HL_KEY_SWITCH   @"switch_virtual_location"
#define HL_KEY_ALT_SW   @"switch_altitude"
#define HL_KEY_MAPTYPE  @"rea_loc_maptype"       // 0 标准 1 卫星 2 混合
#define HL_HIST_MAX     20

#pragma mark - 1. 假坐标的读写（Tweak.xm 的钩子也读这几个键）

double REALocLat(void);
double REALocLng(void);
double REALocAlt(void);
BOOL   REALocHas(void);
void   REALocSaveNamed(double lat, double lng, double alt, NSString *name);
void   REALocSave(double lat, double lng, double alt);
void   REALocClear(void);
void   REAShowLocationPicker(void);
void   REAPushFakeLocationToHost(void);

static NSDictionary *HLCurrentDict(void) {
    @try {
        id d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:HL_KEY_LOC];
        if ([d isKindOfClass:[NSDictionary class]] && d[@"lat"] && d[@"lng"]) return d;
    } @catch (NSException *e) { }
    return nil;
}

double REALocLat(void) {
    NSDictionary *d = HLCurrentDict();
    return d ? [d[@"lat"] doubleValue] : 39.908722;      // 内置默认（北京·天安门）
}
double REALocLng(void) {
    NSDictionary *d = HLCurrentDict();
    return d ? [d[@"lng"] doubleValue] : 116.397499;
}
double REALocAlt(void) {
    NSDictionary *d = HLCurrentDict();
    return (d && d[@"alt"]) ? [d[@"alt"] doubleValue] : 0.0;
}
BOOL REALocHas(void) { return HLCurrentDict() != nil; }

void REALocSaveNamed(double lat, double lng, double alt, NSString *name) {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *cur = [NSMutableDictionary dictionary];
        cur[@"lat"] = @(lat);
        cur[@"lng"] = @(lng);
        cur[@"alt"] = @(alt);
        if (name.length) cur[@"name"] = name;
        [u setObject:cur forKey:HL_KEY_LOC];
        [u setBool:YES forKey:HL_KEY_SWITCH];
        [u setBool:(alt != 0.0) forKey:HL_KEY_ALT_SW];

        // 历史：新的在最前，同坐标去重，最多 20 条
        NSArray *old = [u arrayForKey:HL_KEY_HIST];
        if (![old isKindOfClass:[NSArray class]]) old = @[];
        NSMutableArray *hist = [NSMutableArray array];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"lat"] = @(lat);
        row[@"lng"] = @(lng);
        row[@"alt"] = @(alt);
        row[@"t"] = @((long long)[NSDate date].timeIntervalSince1970);
        if (name.length) row[@"name"] = name;
        [hist addObject:row];
        for (id it in old) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            if ([it[@"lat"] doubleValue] == lat && [it[@"lng"] doubleValue] == lng) continue;
            [hist addObject:it];
            if ((NSInteger)hist.count >= HL_HIST_MAX) break;
        }
        [u setObject:hist forKey:HL_KEY_HIST];
        [u synchronize];
        HL(@"[Loc] 已保存虚拟坐标 %.6f,%.6f alt=%.1f name=%@", lat, lng, alt, name.length ? name : @"(无)");
        REAPushFakeLocationToHost();
    } @catch (NSException *e) {
        HL(@"[Loc] 保存坐标失败：%@", e.reason);
    }
}

void REALocSave(double lat, double lng, double alt) { REALocSaveNamed(lat, lng, alt, nil); }

void REALocClear(void) {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u removeObjectForKey:HL_KEY_LOC];
        [u setBool:NO forKey:HL_KEY_SWITCH];
        [u synchronize];
        HL(@"[LocStatus] 关闭虚拟定位（坐标已清除，回到真实定位）");
        REAPushFakeLocationToHost();
    } @catch (NSException *e) { }
}

// 让宿主立刻重算一次定位：它自己的 CLLocationManager 拉一次，
// Tweak.xm 挂在 didUpdateLocations: / latitude / longitude 上的钩子会把值换成假的。
void REAPushFakeLocationToHost(void) {
    @try {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"REAHLocChanged" object:nil];
        Class svc = objc_getClass("BDLocationService");
        if (svc == Nil) { HL(@"[Loc] 宿主无 BDLocationService，靠 -coordinate 兜底"); return; }
        HL(@"[Loc] 已请求宿主刷新定位（BDLocationService 在，钩子会改写）");
    } @catch (NSException *e) { }
}

#pragma mark - 2. HushVLocPlainLocation：伪装成"真实定位"的 CLLocation 子类
//
// 原版为什么不直接改宿主坐标？因为宿主会把 CLLocation 往上报给服务端 / SDK，
// 有些 SDK 会校验 timestamp / horizontalAccuracy / speed 这些字段。
// 继承 CLLocation 只重写 -coordinate，等于「除了经纬度，其它一切保持真实」，
// 是这套方案里最不容易被识破的形态。我们 1:1 照做。

@interface HushVLocPlainLocation : CLLocation
@property (nonatomic, assign) CLLocationCoordinate2D hushPlainCoord;
@end

@implementation HushVLocPlainLocation
@synthesize hushPlainCoord = _hushPlainCoord;
- (CLLocationCoordinate2D)coordinate { return _hushPlainCoord; }
- (CLLocationCoordinate2D)hushPlainCoord { return _hushPlainCoord; }
- (void)setHushPlainCoord:(CLLocationCoordinate2D)c { _hushPlainCoord = c; }
@end


#pragma mark - 3. HushLocGestureTarget：手势转发器
//
// 原版把 UIGestureRecognizer 的 target 指向这个类方法（而不是 self），
// 好处是 picker 释放后手势即使残留也不会给已释放对象发消息。
// 我们用关联对象把 picker 挂上去，保持同样的解耦。

// 手势转发器看不懂 picker 的具体类型（它在文件后半段才定义），
// 用协议声明"我要调哪几个方法"，比 performSelector 更安全（参数类型不会被当指针传错）。
@protocol HLPickerGestureSink <NSObject>
- (void)hushLocPinLift:(BOOL)lift;
- (void)hushLocScheduleRecenter:(int)times;
- (void)hushLocMapLongPress:(UIGestureRecognizer *)g;
@end

@interface HushLocGestureTarget : NSObject
+ (void)hushLocTap:(id)sender;
+ (void)hushLocDoubleTap:(id)sender;
+ (void)hushLocLongPress:(id)sender;
@end

static const void *kHLPickerRefKey = &kHLPickerRefKey;

@implementation HushLocGestureTarget

+ (UIViewController *)hush_loc_pickerFor:(UIGestureRecognizer *)g {
    UIView *v = g.view;
    while (v) {
        id p = objc_getAssociatedObject(v, kHLPickerRefKey);
        if ([p isKindOfClass:[UIViewController class]]) return p;
        v = v.superview;
    }
    return nil;
}

+ (void)hushLocTap:(id)sender {
    UIGestureRecognizer *g = (UIGestureRecognizer *)sender;
    id picker = [self hush_loc_pickerFor:g];
    if (!picker) return;
    CGPoint pt = [g locationInView:g.view];
    HL(@"[LocPicker] 单击地图 (%.0f,%.0f)", pt.x, pt.y);
    id<HLPickerGestureSink> sink = picker;
    if ([sink respondsToSelector:@selector(hushLocPinLift:)]) [sink hushLocPinLift:YES];
}

+ (void)hushLocDoubleTap:(id)sender {
    UIGestureRecognizer *g = (UIGestureRecognizer *)sender;
    id picker = [self hush_loc_pickerFor:g];
    if (!picker) return;
    HL(@"[LocPicker] 双击地图 → 以当前准星为中心放大");
    id<HLPickerGestureSink> sink = picker;
    if ([sink respondsToSelector:@selector(hushLocScheduleRecenter:)]) [sink hushLocScheduleRecenter:1];
}

+ (void)hushLocLongPress:(id)sender {
    UIGestureRecognizer *g = (UIGestureRecognizer *)sender;
    id picker = [self hush_loc_pickerFor:g];
    if (!picker) return;
    id<HLPickerGestureSink> sink = picker;
    if ([sink respondsToSelector:@selector(hushLocMapLongPress:)]) [sink hushLocMapLongPress:g];
}
@end

#pragma mark - 4. HushLocationHistoryController：历史 / 收藏夹
//
// 原版：左上角「收藏」进收藏夹，动作段「历史」进历史；两页共用这一个控制器，
// 靠 mode 区分；左滑删除单条、导航栏右侧「清除」清空。

typedef void (^HLPickBlock)(NSDictionary *item);

@interface HushLocationHistoryController : UITableViewController
@property (nonatomic, assign) BOOL isFav;          // YES 收藏夹 / NO 历史
@property (nonatomic, copy)   HLPickBlock onPick;
- (instancetype)initWithFavorites:(BOOL)fav;
@end

@interface HushLocationHistoryController ()
- (NSString *)hl_key;
- (NSString *)hl_title;
- (void)hl_reload;
- (void)actClose;
- (void)actClearAll;
@end

@implementation HushLocationHistoryController {
    NSMutableArray *_rows;
}

- (instancetype)initWithFavorites:(BOOL)fav {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _isFav = fav;
        _rows = [NSMutableArray array];
    }
    return self;
}

- (NSString *)hl_key { return _isFav ? HL_KEY_FAV : HL_KEY_HIST; }
- (NSString *)hl_title { return _isFav ? @"坐标收藏夹" : @"历史"; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self hl_title];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actClose)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清除" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(actClearAll)];
    self.tableView.rowHeight = 58.0;
    [self hl_reload];
    HL(@"[LocPicker] %@ 打开（%lu 条）", [self hl_title], (unsigned long)_rows.count);
}

- (void)hl_reload {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:[self hl_key]];
    [_rows setArray:[a isKindOfClass:[NSArray class]] ? a : @[]];
    [self.tableView reloadData];
}

- (void)actClose { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)actClearAll {
    NSString *msg = _isFav ? @"确定要清空收藏夹吗？" : @"确定要删除所有历史记录吗？";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:(_isFav ? @"确认清空" : @"确认清除")
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u removeObjectForKey:[self hl_key]];
        [u synchronize];
        [self hl_reload];
        HL(@"[LocPicker] %@已清空", [self hl_title]);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ---- UITableViewDataSource ----
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (_rows.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:tv.bounds];
        empty.text = _isFav ? @"还没有收藏的坐标\n（在选点页点左上角「收藏」即可）" : @"(已清空)";
        empty.numberOfLines = 0;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.textColor = [UIColor secondaryLabelColor];
        tv.backgroundView = empty;
        return 0;
    }
    tv.backgroundView = nil;
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"hl.cell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *it = (_rows.count > (NSUInteger)ip.row) ? _rows[ip.row] : nil;
    if (![it isKindOfClass:[NSDictionary class]]) return cell;
    double lat = [it[@"lat"] doubleValue], lng = [it[@"lng"] doubleValue];
    NSString *name = it[@"name"];
    cell.textLabel.text = name.length ? name : [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[it[@"t"] doubleValue]];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm";
    NSString *when = it[@"t"] ? [f stringFromDate:d] : @"保存时间：未知";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.6f, %.6f · %@", lat, lng, when];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_rows.count <= (NSUInteger)ip.row) return;
    NSDictionary *it = _rows[ip.row];
    if (![it isKindOfClass:[NSDictionary class]]) return;
    HL(@"[LocPicker] 历史已选：%.6f,%.6f", [it[@"lat"] doubleValue], [it[@"lng"] doubleValue]);
    if (self.onPick) self.onPick(it);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    __weak typeof(self) ws = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        __strong typeof(ws) self = ws;
        if (!self || self->_rows.count <= (NSUInteger)ip.row) { done(NO); return; }
        [self->_rows removeObjectAtIndex:ip.row];
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:self->_rows forKey:[self hl_key]];
        [u synchronize];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        HL(@"[LocPicker] 历史已删除 1 条（余 %lu）", (unsigned long)self->_rows.count);
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

#pragma mark - 5. HushLocationPickerController
//
// 48 个方法与 31 个 ivar 全部按原版命名。UI 结构与原版日志一致：
//   顶部搜索框 → 地图（正中准星，镜头动、准星不动）→ 底部信息卡
//   信息卡：坐标 / 海拔 / 地址 三行 + 动作段（收藏 / 收藏夹 / 历史 / 输入坐标）
//           + 两个开关（虚拟定位 / 海拔模拟）+ 主按钮（保存）
//   导航：左「取消」右「完成」，右上角另有地图类型按钮；左下 MKUserTrackingButton

@interface HushLocationPickerController : UIViewController
    <MKMapViewDelegate, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate,
     CLLocationManagerDelegate, UIGestureRecognizerDelegate>
@end

// 私有方法前置声明：Clang 不会自动看到同实现体内后定义的方法（-Werror 会拦住）
@interface HushLocationPickerController ()
- (void)hl_buildMap;
- (void)hl_buildSearch;
- (void)hl_buildInfoCard;
- (UILabel *)hl_labelWithFont:(UIFont *)font;
- (void)hl_buildGestures;
- (void)hl_applySavedMapType;
- (void)hl_refreshLabelsForCoord:(CLLocationCoordinate2D)c animated:(BOOL)animated;
- (void)hl_resolveAddressFor:(CLLocationCoordinate2D)c;
- (void)hl_recenterTick;
- (void)hl_debouncedSearch;
- (void)hl_pushListFavorites:(BOOL)fav;
@end

@implementation HushLocationPickerController {
    // ---- 与原名二进制逐项对应的 ivar 清单（顺序不重要，名字必须一致）----
    MKMapView *_map;
    MKPointAnnotation *_pickAnno;
    UIImageView *_centerPin;
    BOOL _didInitialAim;
    BOOL _everAppeared;
    CLLocationCoordinate2D _lastAimCoord;
    BOOL _hasAimCoord;
    UIView *_infoCard;
    UILabel *_coordLabel;
    UILabel *_altitudeLabel;
    UILabel *_addrLabel;
    UISearchBar *_searchBar;
    UISegmentedControl *_actionControl;
    UISwitch *_locationSwitch;
    UISwitch *_altitudeSwitch;
    UIButton *_confirmButton;
    MKUserTrackingButton *_trackingButton;
    UIButton *_mapTypeButton;
    UITableView *_resultTable;
    NSLayoutConstraint *_resultHeight;
    NSArray *_results;
    MKLocalSearch *_search;
    int _searchToken;
    BOOL _suppressSearch;
    NSString *_centerAddr;
    int _addrToken;
    BOOL _confirming;
    BOOL _userTouched;
    NSString *_nameHint;
    CLLocationCoordinate2D _nameHintCoord;
    CLLocationManager *_authAsker;

    CLGeocoder *_geocoder;
    NSMutableArray *_segTitles;
    BOOL _mapDragging;
    NSTimer *_recenterTimer;
    int _recenterLeft;
    CLLocationCoordinate2D _pickCoord;
    BOOL _hasPick;
}

#pragma mark 5.1 生命周期

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _results = @[];
        _hasPick = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"定位";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actClose)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(actConfirm)];

    [self hl_buildMap];
    [self hl_buildSearch];
    [self hl_buildInfoCard];
    [self hl_buildGestures];

    _geocoder = [[CLGeocoder alloc] init];
    _authAsker = [[CLLocationManager alloc] init];
    _authAsker.delegate = self;

    // 关联到地图：手势转发器沿 superview 链找 picker
    objc_setAssociatedObject(_map, kHLPickerRefKey, self, OBJC_ASSOCIATION_ASSIGN);

    HL(@"[LocPicker] 打开选点页：当前坐标 %.6f,%.6f（hasCustom=%d）",
       REALocLat(), REALocLng(), (int)REALocHas());
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _everAppeared = YES;
    if (!_didInitialAim) {
        [self hushLocInitialAim];
        _didInitialAim = YES;
    }
    [self hushLocRecenterCheck];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_recenterTimer invalidate];
    _recenterTimer = nil;
    _searchToken++;
    _addrToken++;
}

- (void)dealloc {
    [_recenterTimer invalidate];
    _recenterTimer = nil;
    HL(@"[LocPicker] 释放");
}

#pragma mark 5.2 搭 UI

- (void)hl_buildMap {
    _map = [[MKMapView alloc] initWithFrame:CGRectZero];
    _map.translatesAutoresizingMaskIntoConstraints = NO;
    _map.delegate = self;
    _map.showsUserLocation = NO;      // 假定位时不要画用户蓝点，避免自相矛盾
    _map.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAll];
    [self.view addSubview:_map];

    _centerPin = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"plus.viewfinder"
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:34
                                                                                weight:UIImageSymbolWeightRegular]]];
    _centerPin.translatesAutoresizingMaskIntoConstraints = NO;
    _centerPin.tintColor = [UIColor systemBlueColor];
    _centerPin.contentMode = UIViewContentModeCenter;
    _centerPin.userInteractionEnabled = NO;
    [self.view addSubview:_centerPin];

    _mapTypeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _mapTypeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_mapTypeButton setImage:[UIImage systemImageNamed:@"map"] forState:UIControlStateNormal];
    _mapTypeButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _mapTypeButton.layer.cornerRadius = 8.0;
    [_mapTypeButton addTarget:self action:@selector(hushLocToggleMapType:)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_mapTypeButton];

    _trackingButton = [MKUserTrackingButton userTrackingButtonWithMapView:_map];
    if (_trackingButton) {
        _trackingButton.translatesAutoresizingMaskIntoConstraints = NO;
        _trackingButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _trackingButton.layer.cornerRadius = 8.0;
        [self.view addSubview:_trackingButton];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_map.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_centerPin.centerXAnchor constraintEqualToAnchor:_map.centerXAnchor],
        [_centerPin.centerYAnchor constraintEqualToAnchor:_map.centerYAnchor],
        [_centerPin.widthAnchor constraintEqualToConstant:44],
        [_centerPin.heightAnchor constraintEqualToConstant:44],

        [_mapTypeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_mapTypeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_mapTypeButton.widthAnchor constraintEqualToConstant:40],
        [_mapTypeButton.heightAnchor constraintEqualToConstant:40],
    ]];
    if (_trackingButton) {
        [NSLayoutConstraint activateConstraints:@[
            [_trackingButton.topAnchor constraintEqualToAnchor:_mapTypeButton.bottomAnchor constant:8],
            [_trackingButton.trailingAnchor constraintEqualToAnchor:_mapTypeButton.trailingAnchor],
            [_trackingButton.widthAnchor constraintEqualToConstant:40],
            [_trackingButton.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    [self hl_applySavedMapType];
}

- (void)hl_buildSearch {
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.placeholder = @"搜索地名：";
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.showsCancelButton = YES;
    [self.view addSubview:_searchBar];
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
    ]];
}

- (void)hl_buildInfoCard {
    _infoCard = [[UIView alloc] initWithFrame:CGRectZero];
    _infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    _infoCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _infoCard.layer.cornerRadius = 14.0;
    _infoCard.layer.masksToBounds = YES;
    [self.view addSubview:_infoCard];

    _coordLabel = [self hl_labelWithFont:[UIFont monospacedDigitSystemFontOfSize:15
                                                                           weight:UIFontWeightSemibold]];
    _altitudeLabel = [self hl_labelWithFont:[UIFont systemFontOfSize:13]];
    _addrLabel = [self hl_labelWithFont:[UIFont systemFontOfSize:13]];
    _addrLabel.textColor = [UIColor secondaryLabelColor];
    _addrLabel.text = @"… · 正在解析地址…";

    _actionControl = [[UISegmentedControl alloc] initWithItems:@[@"收藏", @"收藏夹", @"历史", @"输入坐标"]];
    _actionControl.translatesAutoresizingMaskIntoConstraints = NO;
    _actionControl.selectedSegmentIndex = UISegmentedControlNoSegment;
    [_actionControl addTarget:self action:@selector(hushLocActionSegment:)
             forControlEvents:UIControlEventValueChanged];

    _locationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _locationSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:HL_KEY_SWITCH];
    [_locationSwitch addTarget:self action:@selector(hushLocSwitchChanged:)
              forControlEvents:UIControlEventValueChanged];

    _altitudeSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _altitudeSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:HL_KEY_ALT_SW];
    [_altitudeSwitch addTarget:self action:@selector(hushLocSwitchChanged:)
              forControlEvents:UIControlEventValueChanged];

    UIView *locRow = [self hushLocSwitchItemWithIcon:@"location.fill"
                                               title:@"虚拟定位"
                                             control:_locationSwitch];
    UIView *altRow = [self hushLocSwitchItemWithIcon:@"arrow.up.and.down"
                                               title:@"海拔模拟"
                                             control:_altitudeSwitch];

    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_confirmButton setTitle:@"保存并使用这个位置" forState:UIControlStateNormal];
    _confirmButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_confirmButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _confirmButton.backgroundColor = [UIColor systemBlueColor];
    _confirmButton.layer.cornerRadius = 10.0;
    [_confirmButton addTarget:self action:@selector(actConfirm)
             forControlEvents:UIControlEventTouchUpInside];

    _resultTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _resultTable.translatesAutoresizingMaskIntoConstraints = NO;
    _resultTable.dataSource = self;
    _resultTable.delegate = self;
    _resultTable.rowHeight = 48.0;
    _resultTable.hidden = YES;
    _resultTable.backgroundColor = [UIColor clearColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[_coordLabel, _altitudeLabel, _addrLabel, _actionControl, locRow, altRow, _confirmButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    [_infoCard addSubview:stack];
    [self.view addSubview:_resultTable];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_infoCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_infoCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_infoCard.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],

        [stack.topAnchor constraintEqualToAnchor:_infoCard.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:_infoCard.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:_infoCard.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:_infoCard.bottomAnchor constant:-12],

        [_actionControl.heightAnchor constraintEqualToConstant:32],
        [_confirmButton.heightAnchor constraintEqualToConstant:44],

        [_resultTable.leadingAnchor constraintEqualToAnchor:_infoCard.leadingAnchor],
        [_resultTable.trailingAnchor constraintEqualToAnchor:_infoCard.trailingAnchor],
        [_resultTable.bottomAnchor constraintEqualToAnchor:_infoCard.topAnchor constant:-8],
    ]];
    _resultHeight = [_resultTable.heightAnchor constraintEqualToConstant:0];
    _resultHeight.active = YES;

    [self hl_refreshLabelsForCoord:[self hushLocEffectiveCoord] animated:NO];
}

- (UILabel *)hl_labelWithFont:(UIFont *)font {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = font;
    l.numberOfLines = 2;
    return l;
}

- (void)hl_buildGestures {
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[HushLocGestureTarget class] action:@selector(hushLocLongPress:)];
    lp.minimumPressDuration = 0.35;
    lp.delegate = self;
    [_map addGestureRecognizer:lp];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:[HushLocGestureTarget class] action:@selector(hushLocTap:)];
    tap.delegate = self;
    [_map addGestureRecognizer:tap];

    UITapGestureRecognizer *dtap = [[UITapGestureRecognizer alloc]
        initWithTarget:[HushLocGestureTarget class] action:@selector(hushLocDoubleTap:)];
    dtap.numberOfTapsRequired = 2;
    dtap.delegate = self;
    [_map addGestureRecognizer:dtap];
    [tap requireGestureRecognizerToFail:dtap];
}

#pragma mark 5.3 地图 / 坐标

- (CLLocationCoordinate2D)hushLocEffectiveCoord {
    if (_hasPick) return _pickCoord;
    return CLLocationCoordinate2DMake(REALocLat(), REALocLng());
}

- (void)moveTo:(CLLocationCoordinate2D)c spanMeters:(double)span animated:(BOOL)animated {
    MKCoordinateRegion r = MKCoordinateRegionMakeWithDistance(c, MAX(span, 200.0), MAX(span, 200.0));
    [_map setRegion:r animated:animated];
}

- (void)hushLocInitialAim {
    CLLocationCoordinate2D c = [self hushLocEffectiveCoord];
    [self moveTo:c spanMeters:1200 animated:NO];
    _lastAimCoord = c;
    _hasAimCoord = YES;
    HL(@"[LocPicker] 首次对准 → %.6f,%.6f", c.latitude, c.longitude);
}

- (void)hushLocPlacePickAt:(CLLocationCoordinate2D)c {
    _pickCoord = c;
    _hasPick = YES;
    if (_pickAnno) [_map removeAnnotation:_pickAnno];
    _pickAnno = [[MKPointAnnotation alloc] init];
    _pickAnno.coordinate = c;
    _pickAnno.title = @"已标记";
    [_map addAnnotation:_pickAnno];
    HL(@"[LocPicker] 长按 → 蓝点落在 %.6f,%.6f（镜头不动；保存以此点为准）", c.latitude, c.longitude);
    [self hl_refreshLabelsForCoord:c animated:YES];
}

- (void)hushLocClearPick {
    _hasPick = NO;
    if (_pickAnno) { [_map removeAnnotation:_pickAnno]; _pickAnno = nil; }
    HL(@"[LocPicker] 已清除标记");
    [self hl_refreshLabelsForCoord:[self hushLocEffectiveCoord] animated:YES];
}

- (void)hushLocPinLift:(BOOL)lift {
    _centerPin.transform = lift ? CGAffineTransformMakeTranslation(0, -6) : CGAffineTransformIdentity;
}

- (void)hushLocAdoptTarget:(CLLocationCoordinate2D)c name:(NSString *)name {
    [self hushLocPlacePickAt:c];
    [self moveTo:c spanMeters:800 animated:YES];
    if (name.length) {
        _nameHint = name;
        _nameHintCoord = c;
        HL(@"[LocPicker] 采用目标点 %@（%.6f,%.6f）", name, c.latitude, c.longitude);
    }
}

- (void)hushLocMapLongPress:(UIGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [g locationInView:_map];
    CLLocationCoordinate2D c = [_map convertPoint:pt toCoordinateFromView:_map];
    _userTouched = YES;
    [self hushLocPlacePickAt:c];
}

- (void)refreshCenter:(BOOL)animated {
    CLLocationCoordinate2D c = _map.centerCoordinate;
    [self hl_refreshLabelsForCoord:(_hasPick ? _pickCoord : c) animated:animated];
}

- (void)mapView:(MKMapView *)mv regionWillChangeAnimated:(BOOL)animated {
    _mapDragging = YES;
}

- (void)mapView:(MKMapView *)mv regionDidChangeAnimated:(BOOL)animated {
    _mapDragging = NO;
    if (_suppressSearch) return;
    if ([self hushLocRegionChangeIsUserDriven:mv animated:animated]) {
        _centerPin.transform = CGAffineTransformIdentity;
    }
    [self refreshCenter:animated];
    [self dropNameHintIfFar];
}

- (BOOL)hushLocRegionChangeIsUserDriven:(MKMapView *)mv animated:(BOOL)animated {
    return _mapDragging || (!animated && _everAppeared);
}

- (MKAnnotationView *)mapView:(MKMapView *)mv viewForAnnotation:(id<MKAnnotation>)anno {
    if ([anno isKindOfClass:[MKUserLocation class]]) return nil;
    static NSString *aid = @"hl.pin";
    MKMarkerAnnotationView *v = (MKMarkerAnnotationView *)[mv dequeueReusableAnnotationViewWithIdentifier:aid];
    if (!v) {
        v = [[MKMarkerAnnotationView alloc] initWithAnnotation:anno reuseIdentifier:aid];
        v.canShowCallout = YES;
    }
    v.annotation = anno;
    return v;
}

- (void)mapView:(MKMapView *)mv didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views {
    for (MKAnnotationView *v in views) {
        if (![v.annotation isKindOfClass:[MKPointAnnotation class]]) continue;
        v.transform = CGAffineTransformMakeTranslation(0, -12);
        [UIView animateWithDuration:0.22 animations:^{ v.transform = CGAffineTransformIdentity; }];
    }
}

- (void)dropNameHintIfFar {
    if (!_nameHint.length || !_hasAimCoord) return;
    CLLocation *a = [[CLLocation alloc] initWithLatitude:_nameHintCoord.latitude
                                              longitude:_nameHintCoord.longitude];
    CLLocation *b = [[CLLocation alloc] initWithLatitude:_map.centerCoordinate.latitude
                                              longitude:_map.centerCoordinate.longitude];
    CLLocationDistance d = [a distanceFromLocation:b];
    if (d > 300.0) {
        HL(@"[LocPicker] 离开搜索点 %.0f 米 → 摘掉地名「%@」", d, _nameHint);
        _nameHint = nil;
    }
}

- (void)hushLocScheduleRecenter:(int)times {
    [_recenterTimer invalidate];
    _recenterLeft = MAX(times, 1);
    _recenterTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                      target:self
                                                    selector:@selector(hl_recenterTick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)hl_recenterTick {
    if (_recenterLeft-- <= 0) { [_recenterTimer invalidate]; _recenterTimer = nil; return; }
    [self refreshCenter:YES];
}

- (void)hushLocRecenterCheck {
    if (!_map) return;
    MKCoordinateRegion r = _map.region;
    if (!(r.span.latitudeDelta > 0)) [self hushLocInitialAim];
}

- (void)hushLocAimIfPossible {
    if (_hasPick) { [self moveTo:_pickCoord spanMeters:600 animated:YES]; return; }
    [self moveTo:[self hushLocEffectiveCoord] spanMeters:1200 animated:YES];
}

- (BOOL)hushLocCurrentTargetLat:(double *)lat lng:(double *)lng {
    if (!_hasPick) return NO;
    if (lat) *lat = _pickCoord.latitude;
    if (lng) *lng = _pickCoord.longitude;
    return YES;
}

- (void)hushLocCheckLocationAuthorization {
    CLAuthorizationStatus st = _authAsker.authorizationStatus;
    if (st == kCLAuthorizationStatusNotDetermined) {
        [_authAsker requestWhenInUseAuthorization];
    } else if (st == kCLAuthorizationStatusDenied || st == kCLAuthorizationStatusRestricted) {
        HL(@"[LocPicker] 定位权限未授予（status=%d），选点不受影响（本页只需地图）", (int)st);
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m {
    HL(@"[LocPicker] 定位权限变化 → %d", (int)m.authorizationStatus);
}

#pragma mark 5.4 地址 / 标签

- (void)hl_refreshLabelsForCoord:(CLLocationCoordinate2D)c animated:(BOOL)animated {
    _coordLabel.text = [NSString stringWithFormat:@"📍 纬度: %.6f\n📍 经度: %.6f", c.latitude, c.longitude];
    BOOL altOn = _altitudeSwitch.isOn;
    double alt = REALocAlt();
    _altitudeLabel.text = altOn
        ? [NSString stringWithFormat:@"海拔: %.2f米", alt]
        : @"海拔：未启用（打开「海拔模拟」后生效）";
    _nameHintCoord = c;
    [self hl_resolveAddressFor:c];
}

- (void)hl_resolveAddressFor:(CLLocationCoordinate2D)c {
    int token = ++_addrToken;
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    __weak typeof(self) ws = self;
    [_geocoder reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *err) {
        __strong typeof(ws) self = ws;
        if (!self || token != self->_addrToken) return;
        if (err || marks.count == 0) {
            self->_addrLabel.text = [NSString stringWithFormat:@"%.6f, %.6f · 地址解析失败，仍可保存坐标",
                                     c.latitude, c.longitude];
            HL(@"[LocStatus] 地址反查失败：%@", err.localizedDescription ?: @"(空)");
            return;
        }
        CLPlacemark *m = marks.firstObject;
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *s in @[m.country ?: @"", m.administrativeArea ?: @"",
                             m.locality ?: @"", m.subLocality ?: @"",
                             m.thoroughfare ?: @"", m.name ?: @""]) {
            if (s.length) [parts addObject:s];
        }
        NSString *addr = [parts componentsJoinedByString:@" "];
        if (!addr.length) addr = @"(无名)";
        self->_centerAddr = addr;
        self->_addrLabel.text = [NSString stringWithFormat:@"%@ · %@", addr,
            self->_nameHint.length ? self->_nameHint : @"已定位"];
        HL(@"[LocStatus] 地址反查完成：%@", addr);
    }];
}

- (void)hushLocSwitchChanged:(UISwitch *)sw {
    if (sw == _locationSwitch) {
        BOOL on = sw.isOn;
        if (on && !REALocHas()) {
            // 原版语义：没选过点就拒绝开启
            sw.on = NO;
            HL(@"[LocStatus] 拒绝开启：尚未设置位置（hasCustomLocation=NO）");
            [self hushLocAlert:@"未选择位置" msg:@"请先在地图上选择位置再打开虚拟定位"];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:HL_KEY_SWITCH];
        [[NSUserDefaults standardUserDefaults] synchronize];
        HL(on ? @"[LocStatus] 虚拟定位已打开" : @"[LocStatus] 关闭虚拟定位");
        REAPushFakeLocationToHost();
    } else if (sw == _altitudeSwitch) {
        BOOL on = sw.isOn;
        if (on && REALocAlt() == 0.0) {
            sw.on = NO;
            HL(@"[LocPicker] 海拔模拟被拒：尚未设置海拔");
            [self hushLocAlert:@"开关未设置海拔" msg:@"请先设置海拔高度"];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:HL_KEY_ALT_SW];
        [[NSUserDefaults standardUserDefaults] synchronize];
        HL(@"[LocPicker] 海拔模拟 → %@", on ? @"开" : @"关");
        [self refreshCenter:NO];
    }
}

- (UIView *)hushLocSwitchLabelWithText:(NSString *)text icon:(NSString *)icon {
    UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = [UIColor systemBlueColor];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
    lb.translatesAutoresizingMaskIntoConstraints = NO;
    lb.text = text;
    lb.font = [UIFont systemFontOfSize:14];
    [box addSubview:iv];
    [box addSubview:lb];
    [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:18],
        [iv.heightAnchor constraintEqualToConstant:18],
        [lb.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
        [lb.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [lb.topAnchor constraintEqualToAnchor:box.topAnchor],
        [lb.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [box.heightAnchor constraintGreaterThanOrEqualToConstant:20],
    ]];
    return box;
}

- (UIView *)hushLocSwitchItemWithIcon:(NSString *)icon title:(NSString *)title control:(UIView *)ctl {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *lab = [self hushLocSwitchLabelWithText:title icon:icon];
    ctl.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:lab];
    [row addSubview:ctl];
    [NSLayoutConstraint activateConstraints:@[
        [lab.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lab.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [ctl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [ctl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [lab.trailingAnchor constraintLessThanOrEqualToAnchor:ctl.leadingAnchor constant:-8],
        [row.heightAnchor constraintEqualToConstant:34],
    ]];
    return row;
}

#pragma mark 5.5 搜索

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    if (_suppressSearch) return;
    NSString *q = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) { [self clearSearchResults]; return; }
    _searchToken++;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hl_debouncedSearch) object:nil];
    [self performSelector:@selector(hl_debouncedSearch) withObject:nil afterDelay:0.45];
}

- (void)hl_debouncedSearch {
    NSString *q = _searchBar.text;
    if (q.length) [self runSearch:q];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
    NSString *q = sb.text;
    if (q.length) [self runSearch:q];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = nil;
    [sb resignFirstResponder];
    [self clearSearchResults];
}

- (void)clearSearchResults {
    _searchToken++;
    [_search cancel];
    _search = nil;
    _results = @[];
    [_resultTable reloadData];
    _resultTable.hidden = YES;
    _resultHeight.constant = 0;
    HL(@"[LocPicker] 搜索已取消");
}

- (void)runSearch:(NSString *)q {
    int token = ++_searchToken;
    HL(@"[LocPicker] 搜索地名：%@", q);
    _addrLabel.text = [NSString stringWithFormat:@"正在搜索「%@」…", q];

    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery = q;
    req.region = _map.region;

    __weak typeof(self) ws = self;
    MKLocalSearch *s = [[MKLocalSearch alloc] initWithRequest:req];
    _search = s;
    [s startWithCompletionHandler:^(MKLocalSearchResponse *_Nullable resp, NSError *_Nullable err) {
        __strong typeof(ws) self = ws;
        if (!self || token != self->_searchToken) return;
        if (err || resp.mapItems.count == 0) {
            self->_results = @[];
            [self->_resultTable reloadData];
            self->_resultTable.hidden = YES;
            self->_resultHeight.constant = 0;
            self->_addrLabel.text = @"未能找到匹配的位置";
            HL(@"[LocPicker] 搜索无结果：%@（err=%@）", q, err.localizedDescription ?: @"空");
            return;
        }
        self->_results = resp.mapItems;
        [self->_resultTable reloadData];
        self->_resultTable.hidden = NO;
        NSUInteger n = MIN(self->_results.count, (NSUInteger)5);
        self->_resultHeight.constant = 48.0 * (CGFloat)n;
        self->_addrLabel.text = [NSString stringWithFormat:@"搜索结果 %lu 条 · 点一条即定位",
                                 (unsigned long)self->_results.count];
        HL(@"[LocPicker] 搜索结果 %lu 条", (unsigned long)self->_results.count);
    }];
}

// ---- 搜索结果表 ----
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (tv != _resultTable) return 0;
    return (NSInteger)_results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (tv != _resultTable || _results.count <= (NSUInteger)ip.row) return [[UITableViewCell alloc] init];
    static NSString *cid = @"hl.result";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    MKMapItem *it = _results[ip.row];
    cell.textLabel.text = it.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    CLLocationCoordinate2D c = it.placemark.coordinate;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (tv != _resultTable || _results.count <= (NSUInteger)ip.row) return;
    MKMapItem *it = _results[ip.row];
    CLLocationCoordinate2D c = it.placemark.coordinate;
    HL(@"[LocPicker] 选中搜索结果：%@ (%.6f,%.6f)", it.name, c.latitude, c.longitude);
    _suppressSearch = YES;
    _nameHint = it.name;
    _nameHintCoord = c;
    [self hushLocAdoptTarget:c name:it.name];
    _suppressSearch = NO;
    [self clearSearchResults];
    [_searchBar resignFirstResponder];
}

#pragma mark 5.6 动作

- (void)hushLocActionSegment:(UISegmentedControl *)seg {
    NSInteger i = seg.selectedSegmentIndex;
    seg.selectedSegmentIndex = UISegmentedControlNoSegment;
    switch (i) {
        case 0: [self actAddFav];        break;
        case 1: [self actFavListPage];   break;
        case 2: [self actHistory];       break;
        case 3: [self actInputCoord];    break;
        default: break;
    }
}

- (void)hushLocToggleMapType:(id)sender {
    NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:HL_KEY_MAPTYPE];
    t = (t + 1) % 3;
    [[NSUserDefaults standardUserDefaults] setInteger:t forKey:HL_KEY_MAPTYPE];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self hl_applySavedMapType];
    HL(@"[LocPicker] 地图类型 → %@", t == 0 ? @"标准" : (t == 1 ? @"卫星" : @"混合"));
}

- (void)hl_applySavedMapType {
    NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:HL_KEY_MAPTYPE];
    _map.mapType = (t == 1) ? MKMapTypeHybrid : (t == 2 ? MKMapTypeSatellite : MKMapTypeStandard);
}

- (void)actAddFav {
    if (!_hasPick) {
        HL(@"[LocPicker] 未选择位置");
        [self hushLocAlert:@"未选择位置" msg:@"请先在地图上选择位置再收藏"];
        return;
    }
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        NSArray *old = [u arrayForKey:HL_KEY_FAV];
        NSMutableArray *favs = [NSMutableArray arrayWithArray:
            [old isKindOfClass:[NSArray class]] ? old : @[]];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"lat"] = @(_pickCoord.latitude);
        row[@"lng"] = @(_pickCoord.longitude);
        row[@"alt"] = @(REALocAlt());
        row[@"t"] = @((long long)[NSDate date].timeIntervalSince1970);
        NSString *name = _nameHint.length ? _nameHint : _centerAddr;
        if (name.length) row[@"name"] = name;
        [favs insertObject:row atIndex:0];
        [u setObject:favs forKey:HL_KEY_FAV];
        [u synchronize];
        HL(@"[LocPicker] 已收藏当前位置：%@（收藏夹共 %lu 条）",
           name.length ? name : @"(无名称)", (unsigned long)favs.count);
        [self hushLocAlert:@"已加入坐标收藏夹"
                       msg:[NSString stringWithFormat:@"%@（共 %lu 条）",
                            name.length ? name : @"当前位置", (unsigned long)favs.count]];
    } @catch (NSException *e) {
        HL(@"[LocPicker] 收藏失败：%@", e.reason);
    }
}

- (void)actFavListPage {
    [self hl_pushListFavorites:YES];
}

- (void)actHistory {
    [self hl_pushListFavorites:NO];
}

- (void)hl_pushListFavorites:(BOOL)fav {
    HushLocationHistoryController *vc = [[HushLocationHistoryController alloc] initWithFavorites:fav];
    __weak typeof(self) ws = self;
    vc.onPick = ^(NSDictionary *it) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake([it[@"lat"] doubleValue],
                                                             [it[@"lng"] doubleValue]);
        [self hushLocAdoptTarget:c name:it[@"name"]];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)hushLocHistoryPicked:(NSDictionary *)item {
    if (![item isKindOfClass:[NSDictionary class]]) return;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake([item[@"lat"] doubleValue],
                                                         [item[@"lng"] doubleValue]);
    [self hushLocAdoptTarget:c name:item[@"name"]];
}

- (void)actInputCoord {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"手动输入坐标"
                                                               message:@"纬度 -90 ~ 90，经度 -180 ~ 180"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"纬度";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"经度";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        double lat = [ac.textFields.firstObject.text doubleValue];
        double lng = [ac.textFields.lastObject.text doubleValue];
        if (!(lat >= -90.0 && lat <= 90.0)) {
            [self hushLocAlert:@"输入无效" msg:@"纬度范围：-90 ~ 90"];
            return;
        }
        if (!(lng >= -180.0 && lng <= 180.0)) {
            [self hushLocAlert:@"输入无效" msg:@"经度范围：-180 ~ 180"];
            return;
        }
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lng);
        self->_nameHint = @"手动输入的位置";
        self->_nameHintCoord = c;
        [self hushLocPlacePickAt:c];
        [self moveTo:c spanMeters:800 animated:YES];
        HL(@"[LocPicker] 手动输入的位置 %.6f,%.6f", lat, lng);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)actInputAltitude {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"海拔模拟"
                                                               message:@"可以是负值（例如 -30）"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"海拔（米）";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        double cur = REALocAlt();
        if (cur != 0.0) tf.text = [NSString stringWithFormat:@"%.1f", cur];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        NSString *raw = ac.textFields.firstObject.text;
        NSScanner *sc = [NSScanner scannerWithString:raw ?: @""];
        double v = 0.0;
        if (![sc scanDouble:&v] || raw.length == 0) {
            [self hushLocAlert:@"输入无效" msg:@"请输入正确的海拔高度（可以是负值）"];
            return;
        }
        CLLocationCoordinate2D c = [self hushLocEffectiveCoord];
        REALocSave(c.latitude, c.longitude, v);
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:HL_KEY_ALT_SW];
        [[NSUserDefaults standardUserDefaults] synchronize];
        self->_altitudeSwitch.on = YES;
        [self refreshCenter:NO];
        HL(@"[LocPicker] 海拔已保存：%.2f 米", v);
        [self hushLocAlert:@"海拔已保存"
                       msg:[NSString stringWithFormat:@"已成功保存海拔高度：%.2f 米", v]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)actConfirm {
    if (_confirming) return;
    CLLocationCoordinate2D c = [self hushLocEffectiveCoord];
    if (!_hasPick && !_nameHint.length) {
        // 没有蓝点也没有搜索城市：以准星所在位置为准（原版行为）
        c = _map.centerCoordinate;
    }
    _confirming = YES;
    NSString *name = _nameHint.length ? _nameHint : _centerAddr;
    REALocSaveNamed(c.latitude, c.longitude, REALocAlt(), name);
    HL(@"[LocPicker] 保存并生效：%.6f,%.6f（%@）", c.latitude, c.longitude, name.length ? name : @"无名称");
    [self dismissViewControllerAnimated:YES completion:^{
        HL(@"[LocPicker] 已返回宿主");
    }];
}

- (void)actClose {
    HL(@"[LocPicker] 取消（未保存）");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)hushLocAlert:(NSString *)title msg:(NSString *)msg {
    [self hushLocAlertPresent:title msg:msg on:nil];
}

- (void)hushLocAlertPresent:(NSString *)title msg:(NSString *)msg on:(void (^)(void))then {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) { if (then) then(); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark 5.7 手势代理（让地图自己也能拖）

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    return YES;
}

@end

#pragma mark - 6. 对外入口

UIViewController *HLTopViewController(void) {
    UIWindow *host = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.windowLevel != UIWindowLevelNormal) continue;
            if (!w.rootViewController) continue;
            host = w;
            break;
        }
        if (host) break;
    }
    if (!host) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.rootViewController && !w.hidden) { host = w; break; }
        }
    }
    UIViewController *vc = host.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).topViewController ?: vc;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    }
    return vc;
}

void REAShowLocationPicker(void) {
    @try {
        UIViewController *top = HLTopViewController();
        if (!top) {
            HL(@"[LocPicker] 没有可用顶层控制器，选点页打不开");
            return;
        }
        HushLocationPickerController *picker = [[HushLocationPickerController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [top presentViewController:nav animated:YES completion:^{
            HL(@"[LocPicker] 选点页已呈现（host=%@）", NSStringFromClass([top class]));
        }];
    } @catch (NSException *e) {
        HL(@"[LocPicker] 打开异常：%@", e.reason);
    }
}
