/* ============================================================================
   REAPanel.xm —— 面板渲染层（v16.0-PANEL）

   目标：把 REAPanelSpec.h 里的结构**按原版截图 1:1** 画出来。

   视觉规格（全部来自 13 张原版截图的实测）：
     · 背景 #F2F2F7；分组卡片纯白、圆角 10、左右内缩 16
     · 段标题：13pt 灰 (#6C6C70)，左内缩 32，上方留 22、下方留 7
     · 行：高 ≥74（两行文字），图标 26×26 左内缩 16、标题左内缩 52
     · 标题 17pt Regular；副标题 13pt 灰 (#8E8E93)，最多两行
     · 右附件：UISwitch（onTint #34C759）或动作蓝字 17pt (#007AFF) + chevron
     · 段尾统计：13pt 灰，左内缩 32，形如「已开 3/10 · 开屏、信息流与列表里插的广告」
     · 模块列表行高 76：图标 26、标题 17、副标题「已开 x/y · …」13pt 灰
     · 悬浮球：44 直径、蓝 #0A84FF 实心、白色闪电、右下阴影

   实现取舍：**不用 UITableView**。行高按内容动态测量（副标题可能两行），
   用 UIStackView 直接拼卡片，既避免 cell 复用带来的状态错乱，也让
   「开关改动即时生效」不需要 reloadData。
   ============================================================================ */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "REAPanelSpec.h"

#define REAPanelLog(fmt, ...) NSLog(@"[BLUEDHUSH] [I] [Panel] " fmt, ##__VA_ARGS__)

static UIColor *REAColorBG(void)      { return [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1.0]; }
static UIColor *REAColorCard(void)    { return [UIColor whiteColor]; }
static UIColor *REAColorSub(void)     { return [UIColor colorWithRed:0.557 green:0.557 blue:0.576 alpha:1.0]; }
static UIColor *REAColorBlue(void)    { return [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0]; }
static UIColor *REAColorGreen(void)   { return [UIColor colorWithRed:0.204 green:0.780 blue:0.349 alpha:1.0]; }
static UIColor *REAColorRed(void)     { return [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0]; }
static UIColor *REAColorYellow(void)  { return [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0]; }
static UIColor *REAColorHair(void)    { return [UIColor colorWithWhite:0.0 alpha:0.08]; }

/* ---------------- 配置读写（key 一律来自 spec，禁止现编） ---------------- */

static BOOL REAPrefGet(const char *key) {
    if (key == NULL) return NO;
    @try {
        NSString *k = [NSString stringWithUTF8String:key];
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:k];
        return (v != nil) ? [v boolValue] : NO;
    } @catch (NSException *e) { return NO; }
}

static void REAPrefSet(const char *key, BOOL on) {
    if (key == NULL) return;
    @try {
        NSString *k = [NSString stringWithUTF8String:key];
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:k];
        [[NSUserDefaults standardUserDefaults] synchronize];
        REAPanelLog(@"开关 %@ -> %d", k, (int)on);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"REAFlagChanged"
                                                            object:nil
                                                          userInfo:@{@"key": k, @"on": @(on)}];
    } @catch (NSException *e) { }
}

static UIImage *REAIcon(const char *name, UIColor *tint) {
    if (name == NULL) return nil;
    UIImage *base = [UIImage systemImageNamed:[NSString stringWithUTF8String:name]];
    if (base == nil) base = [UIImage systemImageNamed:@"circle.fill"];
    return [base imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIFont *REAFont(CGFloat size, UIFontWeight w) {
    return [UIFont systemFontOfSize:size weight:w];
}

/* ---------------- 行视图 ---------------- */

@class REAPanelRowView;

typedef void (^REAActionBlock)(NSString *name);

@interface REAPanelRowView : UIView
- (instancetype)initWithRow:(const REARowSpec *)row action:(REAActionBlock)actionBlock;
@property (nonatomic, assign) BOOL on;
- (void)refreshSwitch;
@end

@implementation REAPanelRowView {
    const REARowSpec *_row;
    UILabel   *_title;
    UILabel   *_sub;
    UISwitch  *_sw;
    UILabel   *_act;
    UIImageView *_chev;
    REAActionBlock _actBlock;
}

- (instancetype)initWithRow:(const REARowSpec *)row action:(REAActionBlock)block {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    _row = row;
    _actBlock = [block copy];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UIColor *tint = REAColorBlue();
    if (strcmp(row->icon, "power") == 0 || strcmp(row->icon, "circle.fill") == 0) tint = REAColorYellow();
    if (row->danger) tint = REAColorRed();
    icon.image = REAIcon(row->icon, tint);
    [self addSubview:icon];

    _title = [[UILabel alloc] init];
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    _title.text = [NSString stringWithUTF8String:row->title];
    _title.font = REAFont(17.0, UIFontWeightRegular);
    _title.numberOfLines = 1;
    [self addSubview:_title];

    _sub = [[UILabel alloc] init];
    _sub.translatesAutoresizingMaskIntoConstraints = NO;
    _sub.text = row->subtitle ? [NSString stringWithUTF8String:row->subtitle] : @"";
    _sub.font = REAFont(13.0, UIFontWeightRegular);
    _sub.textColor = REAColorSub();
    _sub.numberOfLines = 0;
    [self addSubview:_sub];

    BOOL isAction = (row->action != NULL);
    if (isAction) {
        _act = [[UILabel alloc] init];
        _act.translatesAutoresizingMaskIntoConstraints = NO;
        _act.text = [NSString stringWithUTF8String:row->action];
        _act.font = REAFont(17.0, UIFontWeightRegular);
        _act.textColor = REAColorBlue();
        [self addSubview:_act];

        _chev = [[UIImageView alloc] initWithImage:REAIcon("chevron.right", [UIColor colorWithWhite:0.78 alpha:1.0])];
        _chev.translatesAutoresizingMaskIntoConstraints = NO;
        _chev.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_chev];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
        [self addGestureRecognizer:tap];
    } else {
        _sw = [[UISwitch alloc] init];
        _sw.translatesAutoresizingMaskIntoConstraints = NO;
        _sw.onTintColor = REAColorGreen();
        _sw.on = REAPrefGet(row->key);
        [_sw addTarget:self action:@selector(onSwitch) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_sw];
        if (row->key == NULL) {
            REAPanelLog(@"未映射：%@（原版二进制无对应 key，本行不落盘）", _title.text);
            _sw.enabled = NO;
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.heightAnchor constraintEqualToConstant:26],
        [_title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:52],
        [_title.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],
        [_sub.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
        [_sub.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:3],
        [_sub.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13],
    ]];
    if (isAction) {
        [NSLayoutConstraint activateConstraints:@[
            [_sub.trailingAnchor constraintLessThanOrEqualToAnchor:_act.leadingAnchor constant:-8],
            [_act.trailingAnchor constraintEqualToAnchor:_chev.leadingAnchor constant:-6],
            [_act.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_chev.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [_chev.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_chev.widthAnchor constraintEqualToConstant:8],
            [_chev.heightAnchor constraintEqualToConstant:13],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [_sub.trailingAnchor constraintLessThanOrEqualToAnchor:_sw.leadingAnchor constant:-8],
            [_sw.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [_sw.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)onSwitch {
    if (_row->key == NULL) { [_sw setOn:NO animated:YES]; return; }
    _on = _sw.isOn;
    REAPrefSet(_row->key, _on);
}

- (void)onTap {
    NSString *name = [NSString stringWithUTF8String:_row->title];
    REAPanelLog(@"动作：%@ -> %@", name, [NSString stringWithUTF8String:_row->action]);
    if (_actBlock) _actBlock(name);
}

- (void)refreshSwitch {
    if (_sw) _sw.on = REAPrefGet(_row->key);
}
@end

/* ---------------- 分组卡片 ---------------- */

static UIView *REAMakeCard(const REASectionSpec *sec, int *onOut, int *totalOut, REAActionBlock block) {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = REAColorCard();
    card.layer.cornerRadius = 10.0;
    card.clipsToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    int on = 0, total = 0;
    for (int i = 0; i < sec->rowCount; i++) {
        const REARowSpec *r = &sec->rows[i];
        if (i > 0) {
            UIView *hair = [[UIView alloc] init];
            hair.translatesAutoresizingMaskIntoConstraints = NO;
            hair.backgroundColor = REAColorHair();
            [stack addArrangedSubview:hair];
            [hair.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [hair.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:52].active = YES;
        }
        REAPanelRowView *row = [[REAPanelRowView alloc] initWithRow:r action:block];
        [stack addArrangedSubview:row];
        if (r->action == NULL) {
            total++;
            if (REAPrefGet(r->key)) on++;
        }
    }
    if (onOut) *onOut = on;
    if (totalOut) *totalOut = total;
    return card;
}

/* ---------------- 详情页（一个模块） ---------------- */

@interface REAModuleVC : UIViewController
@property (nonatomic, assign) const REAModuleSpec *mod;
@end

@implementation REAModuleVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = REAColorBG();
    const REAModuleSpec *m = _mod;
    self.title = m ? [NSString stringWithUTF8String:m->title] : @"BluedHush";

    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.alwaysBounceVertical = YES;
    [self.view addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIStackView *page = [[UIStackView alloc] init];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    page.axis = UILayoutConstraintAxisVertical;
    page.spacing = 0;
    [sv addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.leadingAnchor constraintEqualToAnchor:sv.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:sv.trailingAnchor],
        [page.topAnchor constraintEqualToAnchor:sv.topAnchor constant:8],
        [page.bottomAnchor constraintEqualToAnchor:sv.bottomAnchor constant:-28],
        [page.widthAnchor constraintEqualToAnchor:sv.widthAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    REAActionBlock block = ^(NSString *name) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (self2 == nil) return;
        [self2 runActionNamed:name];
    };

    for (int s = 0; s < m->sectionCount; s++) {
        const REASectionSpec *sec = &m->sections[s];
        if (sec->header) {
            UILabel *h = [[UILabel alloc] init];
            h.text = [[NSString stringWithUTF8String:sec->header] stringByAppendingString:@""];
            h.font = REAFont(13.0, UIFontWeightRegular);
            h.textColor = REAColorSub();
            h.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *wrap = [[UIView alloc] init];
            [wrap addSubview:h];
            [NSLayoutConstraint activateConstraints:@[
                [h.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:32],
                [h.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:22],
                [h.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-7],
            ]];
            [page addArrangedSubview:wrap];
        }

        int on = 0, total = 0;
        UIView *card = REAMakeCard(sec, &on, &total, block);
        UIView *cardWrap = [[UIView alloc] init];
        [cardWrap addSubview:card];
        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:cardWrap.leadingAnchor constant:16],
            [card.trailingAnchor constraintEqualToAnchor:cardWrap.trailingAnchor constant:-16],
            [card.topAnchor constraintEqualToAnchor:cardWrap.topAnchor],
            [card.bottomAnchor constraintEqualToAnchor:cardWrap.bottomAnchor],
        ]];
        [page addArrangedSubview:cardWrap];

        if (sec->footer && sec->counted) {
            NSString *f = [NSString stringWithUTF8String:sec->footer];
            if ([f containsString:@"%d/%d"]) f = [NSString stringWithFormat:f, on, total];
            UILabel *fl = [[UILabel alloc] init];
            fl.text = f;
            fl.font = REAFont(13.0, UIFontWeightRegular);
            fl.textColor = REAColorSub();
            fl.numberOfLines = 0;
            fl.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *wrap = [[UIView alloc] init];
            [wrap addSubview:fl];
            [NSLayoutConstraint activateConstraints:@[
                [fl.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:32],
                [fl.trailingAnchor constraintLessThanOrEqualToAnchor:wrap.trailingAnchor constant:-32],
                [fl.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:7],
                [fl.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6],
            ]];
            [page addArrangedSubview:wrap];
        } else if (sec->footer) {
            UILabel *fl = [[UILabel alloc] init];
            fl.text = [NSString stringWithUTF8String:sec->footer];
            fl.font = REAFont(13.0, UIFontWeightRegular);
            fl.textColor = REAColorSub();
            fl.numberOfLines = 0;
            fl.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *wrap = [[UIView alloc] init];
            [wrap addSubview:fl];
            [NSLayoutConstraint activateConstraints:@[
                [fl.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:32],
                [fl.trailingAnchor constraintLessThanOrEqualToAnchor:wrap.trailingAnchor constant:-32],
                [fl.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:7],
                [fl.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6],
            ]];
            [page addArrangedSubview:wrap];
        }
    }
}

- (void)runActionNamed:(NSString *)name {
    /* 动作行：原版是各自独立的二级页；这里统一落到「待接线」日志，
       不自造行为，避免又出现「只挂 UI 不接底层」。 */
    REAPanelLog(@"动作待接线：%@（模块 %s）", name, _mod->title);
}

@end

/* ---------------- 模块列表页（主面板） ---------------- */

@interface REAPanelRootVC : UIViewController <UISearchResultsUpdating, UISearchControllerDelegate>
@end

@implementation REAPanelRootVC {
    UIScrollView *_sv;
    UIStackView  *_page;
    UISearchController *_search;
    NSString *_filter;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = REAColorBG();
    self.title = @"BluedHush";

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"搜索开关（名字 / 说明）";
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    _sv = [[UIScrollView alloc] init];
    _sv.translatesAutoresizingMaskIntoConstraints = NO;
    _sv.alwaysBounceVertical = YES;
    [self.view addSubview:_sv];
    [NSLayoutConstraint activateConstraints:@[
        [_sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    _page = [[UIStackView alloc] init];
    _page.translatesAutoresizingMaskIntoConstraints = NO;
    _page.axis = UILayoutConstraintAxisVertical;
    _page.spacing = 0;
    [_sv addSubview:_page];
    [NSLayoutConstraint activateConstraints:@[
        [_page.leadingAnchor constraintEqualToAnchor:_sv.leadingAnchor],
        [_page.trailingAnchor constraintEqualToAnchor:_sv.trailingAnchor],
        [_page.topAnchor constraintEqualToAnchor:_sv.topAnchor constant:8],
        [_page.bottomAnchor constraintEqualToAnchor:_sv.bottomAnchor constant:-28],
        [_page.widthAnchor constraintEqualToAnchor:_sv.widthAnchor],
    ]];

    [self rebuild];
}

- (void)rebuild {
    for (UIView *v in [_page.arrangedSubviews copy]) {
        [_page removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    UILabel *h = [[UILabel alloc] init];
    h.text = @"功能模块";
    h.font = REAFont(13.0, UIFontWeightRegular);
    h.textColor = REAColorSub();
    h.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *hw = [[UIView alloc] init];
    [hw addSubview:h];
    [NSLayoutConstraint activateConstraints:@[
        [h.leadingAnchor constraintEqualToAnchor:hw.leadingAnchor constant:32],
        [h.topAnchor constraintEqualToAnchor:hw.topAnchor constant:18],
        [h.bottomAnchor constraintEqualToAnchor:hw.bottomAnchor constant:-7],
    ]];
    [_page addArrangedSubview:hw];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = REAColorCard();
    card.layer.cornerRadius = 10.0;
    card.clipsToBounds = YES;
    UIStackView *rows = [[UIStackView alloc] init];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    [card addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:card.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (int i = 0; i < REA_MODULE_COUNT; i++) {
        const REAModuleSpec *m = &kModules[i];
        int on = 0;
        int total = REAModuleSwitchCount(m, &on);
        NSString *sub = [NSString stringWithFormat:@"已开 %d/%d · %s", on, total, m->subtitle];
        if (_filter.length > 0) {
            NSString *t = [NSString stringWithUTF8String:m->title];
            if (![[t lowercaseString] containsString:[_filter lowercaseString]] &&
                ![[sub lowercaseString] containsString:[_filter lowercaseString]]) continue;
        }
        if (i > 0) {
            UIView *hair = [[UIView alloc] init];
            hair.translatesAutoresizingMaskIntoConstraints = NO;
            hair.backgroundColor = REAColorHair();
            [rows addArrangedSubview:hair];
            [hair.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [hair.leadingAnchor constraintEqualToAnchor:rows.leadingAnchor constant:52].active = YES;
        }
        [rows addArrangedSubview:[self moduleRow:m index:i subtitle:sub]];
    }

    UIView *cw = [[UIView alloc] init];
    [cw addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cw.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cw.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cw.topAnchor],
        [card.bottomAnchor constraintEqualToAnchor:cw.bottomAnchor],
    ]];
    [_page addArrangedSubview:cw];

    UILabel *foot = [[UILabel alloc] init];
    foot.text = @"作者 Tinycca (@Tinycca) · TG @Tinycca · 版本 5.18 · 共 134 项（开关 102 · 动作 32）· 开关改动即时写入（标注「需重启 App」的项请按提示重启）。";
    foot.font = REAFont(13.0, UIFontWeightRegular);
    foot.textColor = REAColorSub();
    foot.numberOfLines = 0;
    foot.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *fw = [[UIView alloc] init];
    [fw addSubview:foot];
    [NSLayoutConstraint activateConstraints:@[
        [foot.leadingAnchor constraintEqualToAnchor:fw.leadingAnchor constant:32],
        [foot.trailingAnchor constraintLessThanOrEqualToAnchor:fw.trailingAnchor constant:-32],
        [foot.topAnchor constraintEqualToAnchor:fw.topAnchor constant:8],
        [foot.bottomAnchor constraintEqualToAnchor:fw.bottomAnchor constant:-8],
    ]];
    [_page addArrangedSubview:fw];
}

- (UIView *)moduleRow:(const REAModuleSpec *)m index:(int)idx subtitle:(NSString *)sub {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = REAIcon(m->icon, REAColorBlue());
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];

    UILabel *t = [[UILabel alloc] init];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.text = [NSString stringWithUTF8String:m->title];
    t.font = REAFont(17.0, UIFontWeightRegular);
    [row addSubview:t];

    UILabel *s = [[UILabel alloc] init];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.text = sub;
    s.font = REAFont(13.0, UIFontWeightRegular);
    s.textColor = REAColorSub();
    s.numberOfLines = 1;
    [row addSubview:s];

    UIImageView *chev = [[UIImageView alloc] initWithImage:REAIcon("chevron.right", [UIColor colorWithWhite:0.78 alpha:1.0])];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:16],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.heightAnchor constraintEqualToConstant:26],
        [t.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:52],
        [t.topAnchor constraintEqualToAnchor:row.topAnchor constant:15],
        [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
        [s.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:3],
        [s.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-15],
        [s.trailingAnchor constraintLessThanOrEqualToAnchor:chev.leadingAnchor constant:-8],
        [chev.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chev.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chev.widthAnchor constraintEqualToConstant:8],
        [chev.heightAnchor constraintEqualToConstant:13],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onModuleTap:)];
    row.tag = 1000 + idx;
    [row addGestureRecognizer:tap];
    return row;
}

- (void)onModuleTap:(UITapGestureRecognizer *)g {
    int idx = (int)g.view.tag - 1000;
    if (idx < 0 || idx >= REA_MODULE_COUNT) return;
    REAModuleVC *vc = [[REAModuleVC alloc] init];
    vc.mod = &kModules[idx];
    REAPanelLog(@"进入模块：%s", kModules[idx].title);
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    _filter = [sc.searchBar.text copy];
    [self rebuild];
}

@end

/* ---------------- 入口 ---------------- */

static UIWindow *REAPanelHostWindow(void) {
    UIWindow *best = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.hidden || w.alpha <= 0.01) continue;
                if (strstr(class_getName(object_getClass(w)), "REAWindow") != NULL) continue;
                if (w.isKeyWindow) return w;
                if (best == nil) best = w;
            }
        }
    }
    if (best == nil) best = [UIApplication sharedApplication].windows.firstObject;
    return best;
}

static UIViewController *REAPanelTopVC(void) {
    UIViewController *vc = REAPanelHostWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
    if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

void REAPanelShowRoot(void) {
    UIViewController *top = REAPanelTopVC();
    if (top == nil) { REAPanelLog(@"没有可用的宿主 VC，放弃打开面板"); return; }
    REAPanelRootVC *root = [[REAPanelRootVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    REAPanelLog(@"打开面板（9 模块 / 134 项）");
    [top presentViewController:nav animated:YES completion:nil];
}
