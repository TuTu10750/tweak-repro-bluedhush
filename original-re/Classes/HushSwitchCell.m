// Recovered from BluedHush_5.19.dylib @ 0x24a5d0 (HushSwitchCell)
// A table cell with a leading SF Symbol, two text lines and a trailing UISwitch.
#import "HushSwitchCell.h"

@implementation HushSwitchCell

@synthesize sw = _sw;
@synthesize onToggle = _onToggle;

- (id)initWithStyle:(long long)a0 reuseIdentifier:(id)a1 {
    self = [super initWithStyle:(UITableViewCellStyle)a0 reuseIdentifier:a1];
    if (!self) return nil;

    _sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    _sw.onTintColor = [UIColor systemGreenColor];
    [_sw addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
    self.accessoryView = _sw;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    return self;
}

- (void)configureTitle:(id)a0 subtitle:(id)a1 icon:(id)a2 effect:(long long)a3 on:(BOOL)a4 {
    if (@available(iOS 14.0, *)) {
        UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
        cfg.text = a0;
        cfg.secondaryText = a1;
        cfg.textProperties.numberOfLines = 0;
        cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cfg.secondaryTextProperties.numberOfLines = 0;
        if ([a2 length]) {
            UIImage *img = [UIImage systemImageNamed:a2];
            if (img) cfg.image = img;
        }
        self.contentConfiguration = cfg;
    } else {
        self.textLabel.text = a0;
        self.textLabel.numberOfLines = 0;
        self.detailTextLabel.text = a1;
        self.detailTextLabel.numberOfLines = 0;
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        if ([a2 length]) {
            UIImage *img = [UIImage systemImageNamed:a2];
            if (img) self.imageView.image = img;
        }
    }

    // effect != 0 -> the change needs an app restart
    if (a3 != 0) {
        UILabel *badge = [[UILabel alloc] init];
        badge.text = @" 重启 ";
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        badge.textColor = [UIColor systemOrangeColor];
        badge.layer.cornerRadius = 4.0;
        badge.layer.borderWidth = 0.5;
        badge.layer.borderColor = [UIColor systemOrangeColor].CGColor;
        badge.clipsToBounds = YES;
        [badge sizeToFit];
        self.accessoryView = nil;
        UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _sw.bounds.size.width + badge.bounds.size.width + 8.0,
                                                                MAX(_sw.bounds.size.height, badge.bounds.size.height))];
        badge.center = CGPointMake(badge.bounds.size.width / 2.0, wrap.bounds.size.height / 2.0);
        _sw.center = CGPointMake(badge.bounds.size.width + 8.0 + _sw.bounds.size.width / 2.0, wrap.bounds.size.height / 2.0);
        [wrap addSubview:badge];
        [wrap addSubview:_sw];
        self.accessoryView = wrap;
    } else {
        self.accessoryView = _sw;
    }

    [_sw setOn:a4 animated:NO];
}

- (void)switchChanged {
    if (_onToggle) _onToggle(_sw.isOn);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _onToggle = nil;
    self.accessoryView = _sw;
}

@end
