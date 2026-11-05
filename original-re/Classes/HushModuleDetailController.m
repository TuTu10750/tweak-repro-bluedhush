// Recovered from BluedHush_5.19.dylib @ 0x24ca70 (HushModuleDetailController)
// Second-level page: renders HushModuleSection[] -> HushSwitchItem / HushActionItem rows.
#import "HushModuleDetailController.h"
#import "HushModuleSection.h"
#import "HushSwitchItem.h"
#import "HushActionItem.h"
#import "HushSwitchCell.h"
#import "HushConfig.h"
#import "HushKeys.h"
#import "HushModuleMap.h"

static const HushToggleEntry *HushEntryForKey(NSString *key) {
    if (![key length]) return NULL;
    const char *k = [key UTF8String];
    for (int i = 0; i < kHushToggleCount; i++) {
        if (strcmp(kHushToggles[i].key, k) == 0) return &kHushToggles[i];
    }
    return NULL;
}

// Keys whose change only takes effect after a relaunch.
static BOOL HushKeyNeedsRestart(NSString *key) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"switch_lite", @"switch_capture_ssl", @"switch_rewrite_host",
            @"switch_version_spoof", @"switch_device_fake", @"switch_device_empty",
            @"switch_device_intercept", @"switch_bypass_jailbreak",
            @"switch_keep_alive", @"switch_bugly_off", @"switch_no_data_collect",
        ]];
    });
    return [s containsObject:key];
}

@implementation HushModuleDetailController

@synthesize moduleTitle = _moduleTitle;
@synthesize sections = _sections;
@synthesize moduleFooter = _moduleFooter;

- (id)initWithTitle:(id)a0 sections:(id)a1 footer:(id)a2 {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _moduleTitle = [a0 copy];
    _sections = [a1 copy];
    _moduleFooter = [a2 copy];
    self.title = _moduleTitle;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // v38: 与面板同构的自激源，一并砍掉。原先在 object:nil 上收全局 defaults
    // 通知，宿主任何一次写档（登录态、埋点、缓存）都会让本页在主线程整表
    // reloadData —— 停在这个页面时就是肉眼可见的卡。
    // 改为只在进来时刷一次；本页的数据是构造时传入的快照，不需要外部驱动。
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)a0 {
    [super viewWillAppear:a0];
    [self.tableView reloadData];
}

#pragma mark - table

- (long long)numberOfSectionsInTableView:(id)a0 {
    return (long long)[_sections count];
}

- (long long)tableView:(id)a0 numberOfRowsInSection:(long long)a1 {
    if (a1 < 0 || a1 >= (long long)[_sections count]) return 0;
    HushModuleSection *sec = _sections[(NSUInteger)a1];
    return (long long)[sec.items count];
}

- (id)tableView:(id)a0 titleForHeaderInSection:(long long)a1 {
    if (a1 < 0 || a1 >= (long long)[_sections count]) return nil;
    HushModuleSection *sec = _sections[(NSUInteger)a1];
    return [sec.title length] ? sec.title : nil;
}

- (id)tableView:(id)a0 titleForFooterInSection:(long long)a1 {
    if (a1 < 0 || a1 >= (long long)[_sections count]) return nil;
    HushModuleSection *sec = _sections[(NSUInteger)a1];
    return [sec.subtitle length] ? sec.subtitle : nil;
}

- (id)tableView:(id)a0 cellForRowAtIndexPath:(id)a1 {
    NSIndexPath *ip = (NSIndexPath *)a1;
    if (ip.section < 0 || ip.section >= (long long)[_sections count]) return [[UITableViewCell alloc] init];
    HushModuleSection *sec = _sections[(NSUInteger)ip.section];
    if (ip.row < 0 || ip.row >= (long long)[sec.items count]) return [[UITableViewCell alloc] init];
    id item = sec.items[(NSUInteger)ip.row];

    HushConfig *cfg = [HushConfig shared];

    if ([item isKindOfClass:[HushSwitchItem class]]) {
        HushSwitchItem *si = (HushSwitchItem *)item;
        const HushToggleEntry *e = HushEntryForKey(si.key);
        BOOL isBool = (e ? e->isBool : NO);   // keys outside kHushToggles are text values

        if (isBool) {
            HushSwitchCell *cell = [a0 dequeueReusableCellWithIdentifier:@"sw"];
            if (!cell) cell = [[HushSwitchCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"sw"];
            BOOL on = [cfg isEnabled:si.key default:(e ? e->defBool : NO)];
            NSString *sub = si.subtitle;
            if (HushKeyNeedsRestart(si.key)) {
                sub = [sub length] ? [sub stringByAppendingString:@"  ·  需重启"] : @"需重启 App 生效";
            }
            [cell configureTitle:si.title subtitle:sub icon:si.icon effect:0 on:on];
            __weak typeof(self) weakSelf = self;
            cell.onToggle = ^(BOOL v) {
                [cfg setEnabled:v forKey:si.key];
                if ([si.key isEqualToString:@"ball_icon"] || [si.key isEqualToString:@"float_ball"]) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"HushBallIconStyleDidChangeNotification" object:nil];
                }
                (void)weakSelf;
            };
            return cell;
        }

        // string-valued row: show the current value on the right
        UITableViewCell *cell = [a0 dequeueReusableCellWithIdentifier:@"txt"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"txt"];
        cell.textLabel.text = si.title;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = si.subtitle;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        if ([si.icon length]) {
            UIImage *img = [UIImage systemImageNamed:si.icon];
            if (img) cell.imageView.image = img;
        }
        NSString *cur = [cfg stringForKey:si.key];
        if (![cur length] && e && e->defStr) cur = [NSString stringWithUTF8String:e->defStr];
        cell.accessoryView = [self hushAccessoryWithText:(cur ?: @"未设置") style:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if ([item isKindOfClass:[HushActionItem class]]) {
        HushActionItem *ai = (HushActionItem *)item;
        UITableViewCell *cell = [a0 dequeueReusableCellWithIdentifier:@"act"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"act"];
        cell.textLabel.text = ai.title;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = ai.subtitle;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        if ([ai.icon length]) {
            UIImage *img = [UIImage systemImageNamed:ai.icon];
            if (img) cell.imageView.image = img;
        }
        cell.accessoryView = [self hushAccessoryWithText:ai.actionLabel style:nil];
        return cell;
    }

    UITableViewCell *cell = [a0 dequeueReusableCellWithIdentifier:@"plain"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"plain"];
    cell.textLabel.text = [item description];
    return cell;
}

- (id)hushAccessoryWithText:(id)a0 style:(id)a1 {
    UILabel *l = [[UILabel alloc] init];
    l.text = a0;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    l.textAlignment = NSTextAlignmentRight;
    l.numberOfLines = 1;
    [l sizeToFit];
    CGFloat maxW = 170.0;
    if (l.bounds.size.width > maxW) {
        l.frame = CGRectMake(0, 0, maxW, l.bounds.size.height);
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7;
    }
    return l;
}

- (void)tableView:(id)a0 didSelectRowAtIndexPath:(id)a1 {
    NSIndexPath *ip = (NSIndexPath *)a1;
    [a0 deselectRowAtIndexPath:a1 animated:YES];
    if (ip.section < 0 || ip.section >= (long long)[_sections count]) return;
    HushModuleSection *sec = _sections[(NSUInteger)ip.section];
    if (ip.row < 0 || ip.row >= (long long)[sec.items count]) return;
    id item = sec.items[(NSUInteger)ip.row];
    HushConfig *cfg = [HushConfig shared];

    if ([item isKindOfClass:[HushSwitchItem class]]) {
        HushSwitchItem *si = (HushSwitchItem *)item;
        const HushToggleEntry *e = HushEntryForKey(si.key);
        BOOL isBool = (e ? e->isBool : NO);   // keys outside kHushToggles are text values

        if (isBool) {
            if ([si.key isEqualToString:@"switch_legacy_auto_import"]) {
                [self hushConfirmLegacyAutoImportToggle:si section:ip.section];
                return;
            }
            BOOL on = [cfg isEnabled:si.key default:(e ? e->defBool : NO)];
            [cfg setEnabled:!on forKey:si.key];
            [a0 reloadRowsAtIndexPaths:@[a1] withRowAnimation:UITableViewRowAnimationNone];
            return;
        }

        // string row -> prompt
        NSString *cur = [cfg stringForKey:si.key];
        if (![cur length] && e && e->defStr) cur = [NSString stringWithUTF8String:e->defStr];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:si.title
                                                                   message:si.subtitle
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.placeholder = @"留空则清除";
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NSString *v = ac.textFields.firstObject.text;
            [cfg setString:([v length] ? v : nil) forKey:si.key];
            if ([si.key isEqualToString:@"ball_icon"]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"HushBallIconStyleDidChangeNotification" object:nil];
            }
            [weakSelf.tableView reloadData];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if ([item isKindOfClass:[HushActionItem class]]) {
        HushActionItem *ai = (HushActionItem *)item;
        if (ai.handler) {
            void (^h)(void) = ai.handler;
            h();
            [a0 reloadRowsAtIndexPaths:@[a1] withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

- (void)hushConfirmLegacyAutoImportToggle:(id)a0 section:(long long)a1 {
    HushSwitchItem *si = (HushSwitchItem *)a0;
    HushConfig *cfg = [HushConfig shared];
    BOOL on = [cfg isEnabled:si.key default:NO];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"旧版自动导入"
                         message:@"开启后会把旧版插件目录里的数据导入到当前沙箱，过程只读源目录、不删除任何原文件。是否继续？"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:(on ? @"关闭" : @"开启") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [cfg setEnabled:!on forKey:si.key];
        [weakSelf.tableView reloadData];
        [weakSelf hushRefreshFooterForSection:a1];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)hushRefreshFooterForSection:(long long)a0 {
    if (a0 < 0 || a0 >= (long long)[_sections count]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
        }];
    });
}

@end
