// Recovered from BluedHush_5.19.dylib @ 0x245fa8 (class index 75, flags=0x184 instanceSize=72)
// Root settings page: 9 module cards -> HushModuleDetailController, plus global search and author footer.
#import "HushSettingsPanel.h"
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushModuleEntry.h"
#import "HushModuleSection.h"
#import "HushSwitchItem.h"
#import "HushActionItem.h"
#import "HushSwitchCell.h"
#import "HushModuleDetailController.h"
#import "HushAuthorFooterView.h"
#import "HushRuntime.h"
#import "HushModuleMap.h"
#import "HushKeys.h"

static HushSettingsPanel *gHushSharedPanel = nil;
static dispatch_once_t gHushSharedPanelOnce;

@interface HushSettingsPanel (Icons)
+ (UIColor *)hushColorForModule:(NSInteger)m;
+ (UIImage *)hushIcon:(NSString *)symbol module:(NSInteger)m;
@end

@implementation HushSettingsPanel

@synthesize table = _table;
@synthesize modules = _modules;
@synthesize searchCtl = _searchCtl;
@synthesize searchIndex = _searchIndex;
@synthesize searchResults = _searchResults;
@synthesize hushTopSearchBar = _hushTopSearchBar;
@synthesize hushFooterInsetX = _hushFooterInsetX;
@synthesize pendingScrollTop = _pendingScrollTop;

#pragma mark - singleton / entry

+ (id)sharedPanel {
    dispatch_once(&gHushSharedPanelOnce, ^{
        gHushSharedPanel = [[HushSettingsPanel alloc] init];
    });
    return gHushSharedPanel;
}

+ (void)open {
    [self hushOpenAttempt:0];
}

+ (void)hushOpenAttempt:(long long)a0 {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = HushVisibleTopViewController();
        if (!top) {
            if (a0 < 6) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [HushSettingsPanel hushOpenAttempt:a0 + 1];
                });
            }
            return;
        }

        HushSettingsPanel *panel = [HushSettingsPanel sharedPanel];
        // already showing?
        UIViewController *probe = top;
        while (probe) {
            if ([probe isKindOfClass:[HushSettingsPanel class]]) return;
            probe = probe.presentedViewController ?: probe.parentViewController;
        }

        UINavigationController *nav = HushVisibleNavigationController();
        if (!nav) nav = top.navigationController;

        if (nav) {
            panel.hidesBottomBarWhenPushed = YES;
            [nav pushViewController:panel animated:YES];
            return;
        }

        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:panel];
        wrap.modalPresentationStyle = UIModalPresentationFullScreen;
        [top presentViewController:wrap animated:YES completion:nil];
    });
}

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"BluedHush";
    _hushFooterInsetX = 20.0;

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 68.0;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_table];

    [self.view addConstraints:@[
        [NSLayoutConstraint constraintWithItem:_table attribute:NSLayoutAttributeLeading
                                     relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeading
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:_table attribute:NSLayoutAttributeTrailing
                                     relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTrailing
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:_table attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTop
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:_table attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom
                                    multiplier:1.0 constant:0.0],
    ]];

    _table.tableHeaderView = [self hushMakeTopSearchHeader];

    if (self.presentingViewController || self.navigationController.presentingViewController) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(hushCloseModal)];
    }
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.text.magnifyingglass"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showLog)];

    [self buildModel];
    [self rebuildSearchIndex];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hushActivationDidChange)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)hushActivationDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self buildModel];
        [_table reloadData];
    });
}

- (void)viewWillAppear:(BOOL)a0 {
    [super viewWillAppear:a0];
    [self buildModel];
    [_table reloadData];
}

- (void)viewDidAppear:(BOOL)a0 {
    [super viewDidAppear:a0];
    if (_pendingScrollTop) {
        _pendingScrollTop = NO;
        [_table setContentOffset:CGPointZero animated:NO];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self hushUpdateSearchBarPlacement];
}

- (void)hushCloseModal {
    if (self.navigationController.presentingViewController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)showLog {
    __weak typeof(self) weakSelf = self;
    NSString *logPath = [[HushConfig shared] backupDir];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"诊断"
                                                               message:(logPath ?: @"未设置备份目录")
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [UIPasteboard generalPasteboard].string = logPath ?: @"";
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新注入悬浮球" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        HushGalRemoveBall();
        HushGalInjectBallFromKeyWindow();
        (void)weakSelf;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - model

#pragma mark - module icons

// 原版模块列表每行左边是一个彩色圆角方块 + 白色符号，不是纯色 SF Symbol
+ (UIColor *)hushColorForModule:(NSInteger)m {
    static NSArray<UIColor *> *cols = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cols = @[
            [UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1.0],  // 净化中心 紫
            [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1.0],  // 聊天增强 绿
            [UIColor colorWithRed:0.98 green:0.62 blue:0.20 alpha:1.0],  // 隐私与特权 橙
            [UIColor colorWithRed:0.20 green:0.55 blue:0.98 alpha:1.0],  // 定位与追踪 蓝
            [UIColor colorWithRed:0.45 green:0.55 blue:0.65 alpha:1.0],  // 自动化与筛选 灰蓝
            [UIColor colorWithRed:0.15 green:0.70 blue:0.72 alpha:1.0],  // 视奸与访问 青
            [UIColor colorWithRed:0.98 green:0.75 blue:0.20 alpha:1.0],  // 照片与相册 金
            [UIColor colorWithRed:0.98 green:0.42 blue:0.58 alpha:1.0],  // 入口与手势 粉
            [UIColor colorWithRed:0.30 green:0.68 blue:0.50 alpha:1.0],  // 风控与设备 墨绿
        ];
    });
    if (m < 0 || m >= (NSInteger)cols.count) return cols[0];
    return cols[(NSUInteger)m];
}

+ (UIImage *)hushIcon:(NSString *)symbol module:(NSInteger)m {
    CGFloat side = 29.0;
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                                           cornerRadius:7.0];
        [[self hushColorForModule:m] setFill];
        [box fill];

        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIFontWeightSemibold];
        UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        glyph = [glyph imageWithTintColor:[UIColor whiteColor]
                            renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (!glyph) return;
        CGSize gs = glyph.size;
        [glyph drawInRect:CGRectMake((side - gs.width) / 2.0, (side - gs.height) / 2.0,
                                     gs.width, gs.height)];
    }];
}

- (void)buildModel {
    // Prove at runtime what the panel is actually about to render. If this line
    // shows mojibake the generator is at fault; if it shows correct Chinese the
    // strings were fine and the bad glyphs came from somewhere else.
    // %s 在 NSString stringWithFormat: 里按系统编码解释 C 字符串，UTF-8 中文会被
    // 拆成一堆 Latin-1 字符（日志里就是 ÊÇ¨ÊµÆÁêÉ…）。必须先转成 NSString 再用 %@。
    if (kHushToggleCount >= 2) {
        NSString *k0 = [NSString stringWithUTF8String:kHushToggles[0].key];
        NSString *t0 = [NSString stringWithUTF8String:kHushToggles[0].title];
        NSString *k1 = [NSString stringWithUTF8String:kHushToggles[1].key];
        NSString *t1 = [NSString stringWithUTF8String:kHushToggles[1].title];
        [HushLogger logLevel:4 format:[NSString stringWithFormat:
            @"[Panel] title check: %@=%@ | %@=%@", k0, t0, k1, t1]];
    }


    HushConfig *cfg = [HushConfig shared];
    NSMutableArray<HushModuleEntry *> *mods = [NSMutableArray arrayWithCapacity:kHushModuleCount];
    NSMutableArray<NSMutableArray<id> *> *buckets = [NSMutableArray arrayWithCapacity:kHushModuleCount];
    for (int m = 0; m < kHushModuleCount; m++) [buckets addObject:[NSMutableArray array]];

    for (int i = 0; i < kHushToggleCount; i++) {
        const HushToggleEntry *e = &kHushToggles[i];
        if (e->module < 0 || e->module >= kHushModuleCount) continue;
        // 原版把生效方式拼在说明前面：「立即生效 · 首页「交友」右侧入口显隐…」
        // 这两段文案是中文，必须走 stringWithUTF8String:；用 %s 交给
        // stringWithFormat: 会被当成本地编码解释，面板里整行变乱码（v31 之前
        // 那批「菜单中文乱码」就是这么来的）。
        NSString *effText  = e->effect ? [NSString stringWithUTF8String:e->effect] : @"";
        NSString *descText = e->desc   ? [NSString stringWithUTF8String:e->desc]   : @"";
        NSString *sub = [effText length] ? [NSString stringWithFormat:@"%@ · %@", effText, descText]
                                         : descText;
        HushSwitchItem *it = [HushSwitchItem key:[NSString stringWithUTF8String:e->key]
                                           title:[NSString stringWithUTF8String:e->title]
                                        subtitle:sub
                                            icon:nil
                                          effect:0];
        [buckets[(NSUInteger)e->module] addObject:it];
    }

    // virtual-location coordinates are free-text runtime values, not switches
    if (kHushModuleCount > 3) {
        NSArray<NSArray<NSString *> *> *runtimeRows = @[
            @[@"runtime_custom_lat",      @"虚拟纬度", @"CLLocation 返回该纬度；留空则用真实定位"],
            @[@"runtime_custom_lng",      @"虚拟经度", @"与纬度成对填写，范围 -180 ~ 180"],
            @[@"runtime_custom_altitude", @"虚拟海拔", @"配合「海拔模拟」开关生效，单位米"],
        ];
        for (NSArray<NSString *> *r in runtimeRows) {
            [buckets[3] addObject:[HushSwitchItem key:r[0] title:r[1] subtitle:r[2]]];
        }

        // v33: 快捷预设。手输坐标差一位就落到「坐标越界，拒绝使用」，交付自检时
        // 太容易吵。这三个按钮直接写 runtime_custom_lat / lng，写完面板会自己
        // reload（本文件的 buildModel 监听 NSUserDefaultsDidChangeNotification）。
        NSArray<NSArray<NSString *> *> *vlocPresets = @[
            @[@"深圳", @"22.547917", @"114.124485", @"与真实位置重合，仅作对照基准"],
            @[@"上海", @"31.266600", @"121.501900", @"人民广场一带"],
            @[@"北京", @"39.904200", @"116.407400", @"天安门一带"],
        ];
        for (NSArray<NSString *> *p in vlocPresets) {
            NSString *name = p[0], *latS = p[1], *lngS = p[2], *note = p[3];
            HushActionItem *act = [HushActionItem
                title:[NSString stringWithFormat:@"预设定位：%@", name]
             subtitle:[NSString stringWithFormat:@"%@, %@ · %@", latS, lngS, note]
            actionLabel:@"写入"
                handler:^{
                    HushConfig *c = [HushConfig shared];
                    [c setString:latS forKey:@"runtime_custom_lat"];
                    [c setString:lngS forKey:@"runtime_custom_lng"];
                    [HushLogger logLevel:3 format:[NSString stringWithFormat:
                        @"[Panel][VLoc] 预设写入 %@ → lat=%@ lng=%@", name, latS, lngS]];
                }];
            [buckets[3] addObject:act];
        }
        [buckets[3] addObject:[HushActionItem
            title:@"恢复真实定位"
         subtitle:@"清空经纬度；下一轮 GPS 回调即为真实坐标，不需要重启"
        actionLabel:@"清空"
            handler:^{
                HushConfig *c = [HushConfig shared];
                [c setString:nil forKey:@"runtime_custom_lat"];
                [c setString:nil forKey:@"runtime_custom_lng"];
                [HushLogger logLevel:3 format:@"[Panel][VLoc] 已清空虚拟坐标，交给真实 GPS"];
            }]];
    }

    for (int m = 0; m < kHushModuleCount; m++) {
        const HushModuleMeta *meta = &kHushModules[m];
        HushModuleEntry *entry = [[HushModuleEntry alloc] init];
        entry.title = [NSString stringWithUTF8String:meta->name];
        entry.icon = [NSString stringWithUTF8String:meta->symbol];
        entry.subtitle = [NSString stringWithUTF8String:meta->summary];
        entry.footer = [NSString stringWithUTF8String:(meta->footer ? meta->footer : "")];

        NSArray<HushSwitchItem *> *items = buckets[(NSUInteger)m];

        // count how many of this module's switches are ON
        NSUInteger onCount = 0;
        for (HushSwitchItem *it in items) {
            const HushToggleEntry *e = NULL;
            const char *k = [it.key UTF8String];
            for (int i = 0; i < kHushToggleCount; i++) {
                if (strcmp(kHushToggles[i].key, k) == 0) { e = &kHushToggles[i]; break; }
            }
            if (!e || !e->isBool) continue;
            if ([cfg isEnabled:it.key default:e->defBool]) onCount++;
        }

        NSUInteger boolTotal = 0;
        for (HushSwitchItem *it in items) {
            for (int i = 0; i < kHushToggleCount; i++) {
                if (strcmp(kHushToggles[i].key, [it.key UTF8String]) == 0) {
                    if (kHushToggles[i].isBool) boolTotal++;
                    break;
                }
            }
        }

        // 原版一级页副标题：有开关的模块写「已开 14/35 · 关键词」，
        // 纯动作模块（没有布尔项）写「1 个操作 · 关键词」。
        NSString *sum = [NSString stringWithUTF8String:meta->summary];
        if (boolTotal > 0) {
            entry.subtitle = [NSString stringWithFormat:@"已开 %lu/%lu · %@",
                              (unsigned long)onCount, (unsigned long)boolTotal, sum];
        } else {
            entry.subtitle = [NSString stringWithFormat:@"%lu 个操作 · %@",
                              (unsigned long)items.count, sum];
        }

        entry.sections = [self hushSectionsForModule:m items:items];
        entry.items = items;

        [mods addObject:entry];
    }

    _modules = mods;
}

- (NSArray<HushModuleSection *> *)hushSectionsForModule:(int)m items:(NSArray<HushSwitchItem *> *)items {
    if (m != 0) {
        // modules 1..8: a single section keyed by the module name
        NSString *name = [NSString stringWithUTF8String:kHushModules[m].name];
        return @[[HushModuleSection title:name icon:nil
                                 subtitle:[NSString stringWithFormat:@"共 %lu 项，改动即时写入", (unsigned long)[items count]]
                                    items:items]];
    }

    // module 0 (净化中心) is big: split into three semantic sections
    NSMutableArray<HushSwitchItem *> *purify = [NSMutableArray array];
    NSMutableArray<HushSwitchItem *> *ui = [NSMutableArray array];
    NSMutableArray<HushSwitchItem *> *net = [NSMutableArray array];

    for (HushSwitchItem *it in items) {
        NSString *k = it.key;
        if ([k isEqualToString:@"purify_master"]) { [purify insertObject:it atIndex:0]; }
        else if ([k hasPrefix:@"purify_"]) { [purify addObject:it]; }
        else if ([k isEqualToString:@"switch_block_live_request"] || [k isEqualToString:@"switch_no_data_collect"]) { [net addObject:it]; }
        else { [ui addObject:it]; }
    }

    NSMutableArray<HushModuleSection *> *out = [NSMutableArray array];
    if ([purify count]) {
        [out addObject:[HushModuleSection title:@"广告净化" icon:@"sparkles"
                                       subtitle:@"跟随「净化总开关」，关掉总开关后下面各项全部失效"
                                          items:purify]];
    }
    if ([ui count]) {
        [out addObject:[HushModuleSection title:@"界面净化" icon:@"rectangle.3.group"
                                       subtitle:@"隐藏入口、标签与推广卡片"
                                          items:ui]];
    }
    if ([net count]) {
        [out addObject:[HushModuleSection title:@"网络与采集" icon:@"antenna.radiowaves.left.and.right"
                                       subtitle:@"拦截直播请求与本地数据采集"
                                          items:net]];
    }
    return out;
}

#pragma mark - search

- (void)rebuildSearchIndex {
    NSMutableArray *idx = [NSMutableArray array];
    for (HushModuleEntry *mod in _modules) {
        for (HushSwitchItem *it in mod.items) {
            [idx addObject:@[it, mod.title ?: @""]];
        }
    }
    _searchIndex = idx;
}

- (id)hushMakeTopSearchHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 52)];
    header.backgroundColor = [UIColor clearColor];

    _hushTopSearchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _hushTopSearchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _hushTopSearchBar.placeholder = @"搜索开关（名字 / 说明）";
    _hushTopSearchBar.searchBarStyle = UISearchBarStyleMinimal;
    _hushTopSearchBar.delegate = self;
    _hushTopSearchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [header addSubview:_hushTopSearchBar];

    [header addConstraints:@[
        [NSLayoutConstraint constraintWithItem:_hushTopSearchBar attribute:NSLayoutAttributeLeading
                                     relatedBy:NSLayoutRelationEqual toItem:header attribute:NSLayoutAttributeLeading
                                    multiplier:1.0 constant:8.0],
        [NSLayoutConstraint constraintWithItem:_hushTopSearchBar attribute:NSLayoutAttributeTrailing
                                     relatedBy:NSLayoutRelationEqual toItem:header attribute:NSLayoutAttributeTrailing
                                    multiplier:1.0 constant:-8.0],
        [NSLayoutConstraint constraintWithItem:_hushTopSearchBar attribute:NSLayoutAttributeCenterY
                                     relatedBy:NSLayoutRelationEqual toItem:header attribute:NSLayoutAttributeCenterY
                                    multiplier:1.0 constant:0.0],
    ]];
    return header;
}

- (void)hushUpdateSearchBarPlacement {
    UIView *header = _table.tableHeaderView;
    if (!header) return;
    CGFloat w = _table.bounds.size.width;
    CGFloat h = 52.0;
    if (fabs(header.frame.size.width - w) > 0.5 || fabs(header.frame.size.height - h) > 0.5) {
        header.frame = CGRectMake(0, 0, w, h);
        _table.tableHeaderView = header;
    }
}

- (BOOL)searching {
    return [[self hushSearchQuery] length] > 0;
}

- (id)hushSearchQuery {
    return [_hushTopSearchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
}

- (void)hushApplySearchQuery:(id)a0 {
    NSString *q = [(a0 ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![q length]) {
        _searchResults = nil;
    } else {
        NSMutableArray *hits = [NSMutableArray array];
        for (NSArray *pair in _searchIndex) {
            HushSwitchItem *it = pair[0];
            NSString *mod = pair[1];
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@",
                             it.key ?: @"", it.title ?: @"", it.subtitle ?: @"", mod];
            if ([hay rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:pair];
            }
        }
        _searchResults = hits;
    }
    [_table reloadData];
}

- (void)updateSearchResultsForSearchController:(id)a0 {
    if (_searchCtl) [self hushApplySearchQuery:_searchCtl.searchBar.text];
}

- (void)searchBar:(id)a0 textDidChange:(id)a1 {
    [self hushApplySearchQuery:a1];
}

- (void)searchBarTextDidBeginEditing:(id)a0 {
    UISearchBar *sb = (UISearchBar *)a0;
    [self hushApplySearchQuery:sb.text];
}

- (void)searchBarTextDidEndEditing:(id)a0 {
    UISearchBar *sb = (UISearchBar *)a0;
    [self hushApplySearchQuery:sb.text];
}

- (void)searchBarCancelButtonClicked:(id)a0 {
    UISearchBar *sb = (UISearchBar *)a0;
    sb.text = @"";
    [a0 resignFirstResponder];
    [self hushApplySearchQuery:@""];
}

- (void)searchBarSearchButtonClicked:(id)a0 {
    UISearchBar *sb = (UISearchBar *)a0;
    [a0 resignFirstResponder];
    [self hushApplySearchQuery:sb.text];
}

#pragma mark - navigation

- (void)openModule:(id)a0 {
    HushModuleEntry *mod = a0;
    if (![mod isKindOfClass:[HushModuleEntry class]]) return;

    HushModuleDetailController *detail =
        [[HushModuleDetailController alloc] initWithTitle:mod.title
                                                 sections:(mod.sections ?: @[])
                                                   footer:mod.footer];
    UINavigationController *nav = self.navigationController;
    if (nav) {
        detail.hidesBottomBarWhenPushed = YES;
        [nav pushViewController:detail animated:YES];
    } else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:detail];
        [self presentViewController:wrap animated:YES completion:nil];
    }
}

#pragma mark - table datasource / delegate

- (long long)numberOfSectionsInTableView:(id)a0 {
    return 1;
}

- (id)tableView:(id)a0 titleForHeaderInSection:(long long)a1 {
    return [self searching] ? @"搜索结果" : @"功能模块";
}

- (double)tableView:(id)a0 heightForHeaderInSection:(long long)a1 {
    return 34.0;
}

- (id)tableView:(id)a0 titleForFooterInSection:(long long)a1 {
    return nil;
}

- (double)tableView:(id)a0 heightForFooterInSection:(long long)a1 {
    return [self searching] ? 0.01 : UITableViewAutomaticDimension;
}

- (id)tableView:(id)a0 viewForFooterInSection:(long long)a1 {
    if ([self searching]) return nil;
    HushAuthorFooterView *fv = [a0 dequeueReusableHeaderFooterViewWithIdentifier:@"author"];
    if (!fv) fv = [[HushAuthorFooterView alloc] initWithReuseIdentifier:@"author"];
    [fv configureText:[self hushFooterText]
                inset:[self hushFooterInsetForTable:a0]
                 tint:[UIColor systemBlueColor]];
    return fv;
}

- (double)hushFooterInsetForTable:(id)a0 {
    return _hushFooterInsetX;
}

- (id)hushFooterText {
    NSUInteger bools = 0, texts = 0;
    for (int i = 0; i < kHushToggleCount; i++) {
        if (kHushToggles[i].isBool) bools++; else texts++;
    }
    return [NSString stringWithFormat:
            @"作者 Tinycca (@Tinycca) · TG @Tinycca\n"
             "版本 5.19 · 共 %d 项（开关 %lu · 文本 %lu）\n"
             "开关改动即时写入（标注「需重启 App」的项请按提示重启）",
            kHushToggleCount, (unsigned long)bools, (unsigned long)texts];
}

- (long long)tableView:(id)a0 numberOfRowsInSection:(long long)a1 {
    return [self searching] ? (long long)[_searchResults count] : (long long)[_modules count];
}

- (id)tableView:(id)a0 cellForRowAtIndexPath:(id)a1 {
    NSIndexPath *ip = (NSIndexPath *)a1;
    HushConfig *cfg = [HushConfig shared];

    if ([self searching]) {
        UITableViewCell *cell = [a0 dequeueReusableCellWithIdentifier:@"hit"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hit"];
        NSArray *pair = _searchResults[(NSUInteger)ip.row];
        HushSwitchItem *it = pair[0];
        cell.textLabel.text = it.title;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", pair[1], it.key];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        BOOL isBool = NO, on = NO;
        for (int i = 0; i < kHushToggleCount; i++) {
            if (strcmp(kHushToggles[i].key, [it.key UTF8String]) == 0) {
                isBool = kHushToggles[i].isBool;
                if (isBool) on = [cfg isEnabled:it.key default:kHushToggles[i].defBool];
                break;
            }
        }
        if (!isBool) {
            NSString *cur = [cfg stringForKey:it.key];
            cell.accessoryView = [self hushMiniLabel:([cur length] ? cur : @"未设置")];
        } else {
            cell.accessoryView = [self hushMiniLabel:(on ? @"开" : @"关")];
        }
        return cell;
    }

    HushModuleEntry *mod = _modules[(NSUInteger)ip.row];
    UITableViewCell *cell = [a0 dequeueReusableCellWithIdentifier:@"mod"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"mod"];
    if (@available(iOS 14.0, *)) {
        UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
        c.text = mod.title;
        c.secondaryText = mod.subtitle;
        c.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        c.secondaryTextProperties.numberOfLines = 2;
        // 原版是彩色圆角方块，不是纯色符号
        UIImage *img = [HushSettingsPanel hushIcon:(mod.icon ?: @"circle") module:(NSInteger)ip.row];
        if (img) c.image = img;
        cell.contentConfiguration = c;
    } else {
        cell.textLabel.text = mod.title;
        cell.detailTextLabel.text = mod.subtitle;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 2;
        UIImage *img = [UIImage systemImageNamed:(mod.icon ?: @"circle")];
        if (img) cell.imageView.image = img;
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (id)hushMiniLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    [l sizeToFit];
    return l;
}

- (void)hushFinishNavigateCell:(id)a0 style:(id)a1 {
    UITableViewCell *cell = a0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

- (void)tableView:(id)a0 didSelectRowAtIndexPath:(id)a1 {
    NSIndexPath *ip = (NSIndexPath *)a1;
    [a0 deselectRowAtIndexPath:a1 animated:YES];

    if ([self searching]) {
        // jump into the owning module and highlight the row
        NSArray *pair = _searchResults[(NSUInteger)ip.row];
        HushSwitchItem *it = pair[0];
        NSString *modName = pair[1];
        for (HushModuleEntry *mod in _modules) {
            if ([mod.title isEqualToString:modName]) {
                [self openModule:mod];
                break;
            }
        }
        (void)it;
        return;
    }

    if (ip.row < 0 || ip.row >= (long long)[_modules count]) return;
    [self openModule:_modules[(NSUInteger)ip.row]];
}

@end
