//
//  HushLocationHistoryController.m
//  还原 BluedHush_5.19 的「历史记录 / 收藏夹」列表
//
//  mode 0 = 历史记录（hush_loc_history）
//  mode 1 = 收藏夹（hush_loc_favorites）
//  点一行 → 回填到选点页；左滑删除单条；右上「清空」
//

#import <UIKit/UIKit.h>
#import "HushConfig.h"
#import "HushLocationHistoryController.h"
#import "HushLocationPickerController.h"

static NSString *const kHushLocHistoryKey   = @"hush_loc_history";
static NSString *const kHushLocFavoritesKey = @"hush_loc_favorites";

@interface HushLocationHistoryController ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@end

@implementation HushLocationHistoryController

- (instancetype)initWithMode:(long long)mode {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _mode = mode;
    _items = [NSMutableArray array];
    return self;
}

- (BOOL)hushIsFavorites { return _mode != 0; }

- (NSString *)hushKey { return [self hushIsFavorites] ? kHushLocFavoritesKey : kHushLocHistoryKey; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self hushIsFavorites] ? @"收藏夹" : @"历史记录";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actClearAll)];
    [self hushReload];
}

- (NSArray<NSDictionary *> *)hushItems {
    NSString *json = [[HushConfig shared] stringForKey:[self hushKey]];
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    return [o isKindOfClass:[NSArray class]] ? o : @[];
}

- (void)hushSaveItems:(NSArray<NSDictionary *> *)items {
    NSData *jd = [NSJSONSerialization dataWithJSONObject:(items ?: @[]) options:0 error:NULL];
    if (jd) [[HushConfig shared] setString:[[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]
                                    forKey:[self hushKey]];
}

- (void)hushReload {
    [_items setArray:[self hushItems]];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _items.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (_items.count == 0) return nil;
    return [self hushIsFavorites] ? @"长按可加备注，左滑删除" : @"最近选过的位置（最多 30 条）";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"hush_loc_hist";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *d = _items[ip.row];

    NSString *name = d[@"name"];
    NSString *addr = d[@"addr"];
    double lat = [d[@"lat"] doubleValue];
    double lng = [d[@"lng"] doubleValue];

    c.textLabel.text = name.length ? name : [NSString stringWithFormat:@"%.4f, %.4f", lat, lng];
    c.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];

    NSMutableArray *sub = [NSMutableArray array];
    if (addr.length) [sub addObject:addr];
    [sub addObject:[NSString stringWithFormat:@"%.4f, %.4f", lat, lng]];
    c.detailTextLabel.text = [sub componentsJoinedByString:@" · "];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.numberOfLines = 2;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= _items.count) return;
    NSDictionary *d = _items[ip.row];

    // 找到栈里的选点页回填；没有就新开一个
    HushLocationPickerController *picker = nil;
    for (UIViewController *vc in self.navigationController.viewControllers) {
        if ([vc isKindOfClass:[HushLocationPickerController class]]) { picker = (id)vc; break; }
    }
    if (picker) {
        [picker hushLocHistoryPicked:d];
        [self.navigationController popToViewController:picker animated:YES];
    } else {
        HushLocationPickerController *p = [[HushLocationPickerController alloc] init];
        [self.navigationController pushViewController:p animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [p hushLocHistoryPicked:d];
        });
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"删除"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || ip.row >= self2->_items.count) { done(NO); return; }
        [self2->_items removeObjectAtIndex:ip.row];
        [self2 hushSaveItems:self2->_items];
        [self2.tableView deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *note = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:@"备注"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        __strong typeof(weakSelf) self2 = weakSelf;
        [self2 hushEditNoteAtIndex:ip.row];
        done(YES);
    }];
    note.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[note]];
}

- (void)hushEditNoteAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= _items.count) return;
    NSDictionary *d = _items[idx];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"备注" message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = d[@"name"]; }];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || idx >= self2->_items.count) return;
        NSMutableDictionary *m = [d mutableCopy];
        m[@"name"] = ac.textFields.firstObject.text ?: @"";
        [self2->_items replaceObjectAtIndex:idx withObject:m];
        [self2 hushSaveItems:self2->_items];
        [self2.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:idx inSection:0]]
                               withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)actClearAll {
    if (_items.count == 0) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空"
                                                                message:[self hushIsFavorites] ? @"确定清空收藏夹？" : @"确定清空历史记录？"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self2 = weakSelf;
        [self2->_items removeAllObjects];
        [self2 hushSaveItems:@[]];
        [self2.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

@end
