// Recovered from BluedHush_5.19.dylib @ 0x24b8f4 (HushAuthorFooterView)
// Root-page footer: a selectable UITextView so author links (@ handled in-text) stay tappable.
#import "HushAuthorFooterView.h"

@implementation HushAuthorFooterView

- (id)initWithReuseIdentifier:(id)a0 {
    self = [super initWithReuseIdentifier:a0];
    if (!self) return nil;

    self.contentView.backgroundColor = [UIColor clearColor];

    _tv = [[UITextView alloc] initWithFrame:CGRectZero];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.editable = NO;
    _tv.selectable = YES;
    _tv.scrollEnabled = NO;
    _tv.backgroundColor = [UIColor clearColor];
    _tv.textContainerInset = UIEdgeInsetsZero;
    _tv.textContainer.lineFragmentPadding = 0.0;
    _tv.delegate = self;
    [self.contentView addSubview:_tv];

    _lead = [NSLayoutConstraint constraintWithItem:_tv attribute:NSLayoutAttributeLeading
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:self.contentView attribute:NSLayoutAttributeLeading
                                        multiplier:1.0 constant:16.0];
    _trail = [NSLayoutConstraint constraintWithItem:_tv attribute:NSLayoutAttributeTrailing
                                          relatedBy:NSLayoutRelationEqual
                                             toItem:self.contentView attribute:NSLayoutAttributeTrailing
                                         multiplier:1.0 constant:-16.0];
    [self.contentView addConstraints:@[_lead, _trail,
        [NSLayoutConstraint constraintWithItem:_tv attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.contentView attribute:NSLayoutAttributeTop
                                    multiplier:1.0 constant:8.0],
        [NSLayoutConstraint constraintWithItem:_tv attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.contentView attribute:NSLayoutAttributeBottom
                                    multiplier:1.0 constant:-8.0]]];

    return self;
}

- (void)configureText:(id)a0 inset:(double)a1 tint:(id)a2 {
    _lead.constant = a1;
    _trail.constant = -a1;
    _tv.tintColor = a2 ?: [UIColor systemBlueColor];

    if ([a0 isKindOfClass:[NSAttributedString class]]) {
        _tv.attributedText = a0;
        return;
    }

    NSString *text = [a0 isKindOfClass:[NSString class]] ? a0 : @"";
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineSpacing = 3.0;

    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: [UIColor tertiaryLabelColor],
        NSParagraphStyleAttributeName: ps,
    }];

    // auto-link anything that looks like @handle or a URL
    NSArray<NSString *> *patterns = @[
        @"(@[A-Za-z0-9_]{2,32})",
        @"(https?://[^\\s]+)",
        @"(t\\.me/[A-Za-z0-9_]+)",
    ];
    for (NSString *pat in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:NULL];
        if (!re) continue;
        [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                          usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
            if (!m) return;
            NSRange r = m.range;
            if (r.location == NSNotFound || NSMaxRange(r) > text.length) return;
            NSString *token = [text substringWithRange:r];
            NSString *url;
            if ([token hasPrefix:@"http"]) url = token;
            else if ([token hasPrefix:@"t.me/"]) url = [@"https://" stringByAppendingString:token];
            else url = [@"https://t.me/" stringByAppendingString:[token substringFromIndex:1]];
            [att addAttribute:NSLinkAttributeName value:url range:r];
            [att addAttribute:NSForegroundColorAttributeName value:(a2 ?: [UIColor systemBlueColor]) range:r];
        }];
    }

    _tv.attributedText = att;
}

- (BOOL)textView:(id)a0 shouldInteractWithURL:(id)a1 inRange:(NSRange)a2 interaction:(long long)a3 {
    if ([[UIApplication sharedApplication] canOpenURL:a1]) {
        [[UIApplication sharedApplication] openURL:a1 options:@{} completionHandler:nil];
    }
    return NO;
}

@end
