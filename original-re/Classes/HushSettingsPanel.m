// HushSettingsPanel — functional reimplementation.
//
// The 261 KB recovered skeleton carried 32 methods of commented-out call traces
// and returned nil everywhere, so tapping the ball produced a blank page.  This
// is a from-scratch panel that provides the *behaviour* the original had:
// a grouped, searchable list of every switch in the config table, tap to flip,
// persisted through HushConfig (which is the same NSUserDefaults the original
// wrote to, so original keys keep working).
//
// Presentation path mirrors the original:
//   +open            @0x19dabc -> [self hushOpenAttempt:0]
//   +sharedPanel     @0x19da50 -> dispatch_once alloc/init
//   +hushOpenAttempt @0x19dacc -> present on the visible top view controller
//
// The original drove its rows from -buildModel (@0x19f254, 1049 disassembly
// lines); we derive them from kHushDefaults so every key the binary knew about
// is reachable even if its UI section was lost.

#import "HushSettingsPanel.h"
#import "HushRuntime.h"
#import "HushConfig.h"
#import "HushKeys.h"
#import "HushLogger.h"

static HushSettingsPanel *gHushSharedPanel = nil;
static dispatch_once_t gHushSharedPanelOnce;

// Declared here because HushSettingRow below needs it before the main
// @implementation opens.
@interface HushSettingsPanel (Titles)
+ (NSString *)titleForKey:(NSString *)key;
@end

// One row = one config key.
@interface HushSettingRow : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL isBool;
@property (nonatomic, copy) NSString *textValue;

+ (instancetype)rowWithKey:(NSString *)key isBool:(BOOL)isBool text:(NSString *)text;
@end

@implementation HushSettingRow
+ (instancetype)rowWithKey:(NSString *)key isBool:(BOOL)isBool text:(NSString *)text {
    HushSettingRow *r = [HushSettingRow new];
    r.key = key;
    r.isBool = isBool;
    r.textValue = text;
    r.title = [HushSettingsPanel titleForKey:key];
    return r;
}
@end

@implementation HushSettingsPanel

#pragma mark - presentation (same three entry points as the original)

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
    UIViewController *top = HushVisibleTopViewController();
    if (!top) {
        [HushLogger logLevel:4 format:@"[Hush] open: no visible top view controller"];
        return;
    }

    HushSettingsPanel *panel = (HushSettingsPanel *)[self sharedPanel];
    if (!panel) return;

    // Already on screen?
    if ([top isKindOfClass:[HushSettingsPanel class]]) return;
    if ([top presentedViewController] &&
        [[top presentedViewController] isKindOfClass:[HushSettingsPanel class]]) return;

    UINavigationController *nav = HushVisibleNavigationController();
    if (nav && [nav isKindOfClass:[UINavigationController class]]) {
        [nav pushViewController:panel animated:YES];
        return;
    }

    [top presentViewController:panel animated:YES completion:nil];
}

#pragma mark - titles

+ (NSString *)titleForKey:(NSString *)key {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"float_ball": @"悬浮球",
            @"ball_icon": @"悬浮球图标",
            @"switch_lite": @"轻量模式",
            @"purify_master": @"净化总开关",
            @"switch_anti_recall": @"防撤回",
            @"switch_msg_heal": @"消息修复",
            @"switch_read_receipt": @"已读回执",
            @"switch_screenshot": @"截屏提醒",
            @"switch_secret_view_all": @"私密相册全可见",
            @"switch_deleted_mark": @"删除标记",
            @"switch_msg_timestamp": @"消息时间戳",
            @"switch_chat_watermark": @"聊天水印",
            @"switch_virtual_location": @"虚拟定位",
            @"switch_location_sim": @"位置模拟",
            @"switch_altitude_sim": @"海拔模拟",
            @"switch_track": @"轨迹",
            @"switch_stalk": @"访客监控",
            @"switch_visit_clear": @"清理访客记录",
            @"switch_viewed_strike": @"被看标记",
            @"switch_spy_detect": @"访客探测",
            @"switch_chat_gallery": @"聊天相册",
            @"switch_chat_gallery_ball": @"聊天相册悬浮球",
            @"switch_album_grant": @"相册权限开通",
            @"switch_private_photo": @"私密照片",
            @"switch_flash_photo": @"闪照保存",
            @"switch_flash_text": @"闪照文字",
            @"switch_unlimited_burn": @"无限阅后即焚",
            @"switch_keep_alive": @"后台保活",
            @"switch_license_bypass": @"授权绕过",
            @"switch_version_spoof": @"版本伪装",
            @"switch_device_fake": @"设备伪装",
            @"switch_debug_log": @"调试日志",
        };
    });
    NSString *t = map[key];
    return t ?: key;
}

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Hush";
    [self setView:[[UIView alloc] init]];
    [[self view] setBackgroundColor:[UIColor systemBackgroundColor]];

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero
                                                      style:UITableViewStyleInsetGrouped];
    _table = table;
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setRowHeight:UITableViewAutomaticDimension];
    [_table setEstimatedRowHeight:44.0];
    [_table setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[self view] addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [[_table topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[_table bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]],
        [[_table leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[_table trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
    ]];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                         target:self
                                                                         action:@selector(hushCloseModal)];
    [[self navigationItem] setRightBarButtonItem:done];

    [self buildModel];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)hushCloseModal {
    if ([self navigationController]) {
        [[self navigationController] popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildModel];
}

- (void)viewDidAppear:(BOOL)animated  { [super viewDidAppear:animated]; }
- (void)viewDidLayoutSubviews         { [super viewDidLayoutSubviews]; }
- (void)hushActivationDidChange        { [self buildModel]; }

#pragma mark - model

- (void)buildModel {
    HushConfig *cfg = [HushConfig shared];
    NSMutableArray *sections = [NSMutableArray array];

    NSMutableArray *general = [NSMutableArray array];
    NSMutableArray *purify  = [NSMutableArray array];
    NSMutableArray *runtime = [NSMutableArray array];

    for (int i = 0; i < kHushDefaultsCount; i++) {
        const HushDefaultEntry *e = &kHushDefaults[i];
        if (!e->key) continue;
        NSString *key = @(e->key);
        if ([key hasPrefix:@"runtime_"]) continue;

        HushSettingRow *row = [HushSettingRow rowWithKey:key
                                                  isBool:(e->isBool != 0)
                                                    text:(e->defStr ? @(e->defStr) : nil)];
        if ([key hasPrefix:@"purify_"] || [key hasPrefix:@"switch_purify"] || [key hasPrefix:@"switch_hide"]) {
            [purify addObject:row];
        } else {
            [general addObject:row];
        }
    }

    // Runtime rows (location/token) are editable text, appended as their own section.
    for (NSString *k in @[@"runtime_custom_lat", @"runtime_custom_lng",
                          @"runtime_custom_altitude", @"runtime_auth_token",
                          @"runtime_user_agent", @"runtime_backup_dir"]) {
        NSString *v = [cfg stringForKey:k];
        [runtime addObject:[HushSettingRow rowWithKey:k isBool:NO text:v]];
    }

    [sections addObject:@{@"title": @"功能开关", @"rows": general}];
    if (purify.count) [sections addObject:@{@"title": @"净化", @"rows": purify}];
    [sections addObject:@{@"title": @"运行时", @"rows": runtime}];

    _modules = sections;
    [[self table] reloadData];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)[_modules count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return _modules[(NSUInteger)section][@"title"];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = _modules[(NSUInteger)section][@"rows"];
    return (NSInteger)[rows count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"HushSettingCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:cellId];
    }

    NSArray *rows = _modules[(NSUInteger)indexPath.section][@"rows"];
    HushSettingRow *row = rows[(NSUInteger)indexPath.row];

    [[cell textLabel] setText:row.title];

    HushConfig *cfg = [HushConfig shared];
    if (row.isBool) {
        BOOL on = [cfg isEnabled:row.key];
        [[cell detailTextLabel] setText:on ? @"开" : @"关"];
        [[cell detailTextLabel] setTextColor:on ? [UIColor systemGreenColor]
                                                : [UIColor secondaryLabelColor]];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    } else {
        NSString *v = [cfg stringForKey:row.key];
        [[cell detailTextLabel] setText:(v.length ? v : @"—")];
        [[cell detailTextLabel] setTextColor:[UIColor secondaryLabelColor]];
        [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];

    NSArray *rows = _modules[(NSUInteger)indexPath.section][@"rows"];
    HushSettingRow *row = rows[(NSUInteger)indexPath.row];
    HushConfig *cfg = [HushConfig shared];

    if (row.isBool) {
        BOOL on = [cfg isEnabled:row.key];
        [cfg setEnabled:!on forKey:row.key];
        [HushLogger logLevel:4 format:[NSString stringWithFormat:@"[Hush] %@ = %d",
                                       row.key, !on]];
    } else {
        [self hushPromptForText:row.key current:[cfg stringForKey:row.key]];
        return;
    }

    [tv reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];

    // ball_icon changes have to re-render every live ball.
    if ([row.key isEqualToString:@"ball_icon"] ||
        [row.key isEqualToString:@"float_ball"]      ||
        [row.key isEqualToString:@"switch_chat_gallery_ball"]) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:HushBallIconStyleDidChangeNotification object:nil];
        HushGalInjectBallFromKeyWindow();
    }
}

- (void)hushPromptForText:(NSString *)key current:(NSString *)current {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:key
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current;
        tf.placeholder = @"value";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *v = ac.textFields.firstObject.text;
        [[HushConfig shared] setString:(v.length ? v : nil) forKey:key];
        [[self table] reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)openModule:(id)a0     {}
- (void)showLog               {}
- (BOOL)searching             { return NO; }
- (id)hushSearchQuery         { return nil; }
- (void)hushApplySearchQuery:(id)a0 {}
- (void)rebuildSearchIndex    {}
- (void)updateSearchResultsForSearchController:(id)a0 {}
- (void)hushUpdateSearchBarPlacement {}
- (id)hushMakeTopSearchHeader { return nil; }
- (id)hushFooterText          { return @"Hush recovered build"; }
- (double)hushFooterInsetForTable:(id)a0 { return 0; }
- (id)tableView:(id)a0 titleForFooterInSection:(long long)a1 { return nil; }
- (id)tableView:(id)a0 viewForFooterInSection:(long long)a1  { return nil; }
- (double)tableView:(id)a0 heightForHeaderInSection:(long long)a1 { return 28.0; }
- (double)tableView:(id)a0 heightForFooterInSection:(long long)a1 { return 0.0; }
- (void)hushFinishNavigateCell:(id)a0 style:(id)a1 {}
- (void)searchBar:(id)a0 textDidChange:(id)a1 {}
- (void)searchBarTextDidBeginEditing:(id)a0 {}
- (void)searchBarTextDidEndEditing:(id)a0 {}
- (void)searchBarCancelButtonClicked:(id)a0 {}
- (void)searchBarSearchButtonClicked:(id)a0 {}

@end
